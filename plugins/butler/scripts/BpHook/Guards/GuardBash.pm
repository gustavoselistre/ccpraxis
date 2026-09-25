# BpHook::Guards::GuardBash -- the merged Bash PreToolUse guard (package 14
# of blueprint hook-continuity-remake), successor to the old separate
# headless-background, judge-checks and validation-interlock Bash guards,
# now merged into hooks/guard-bash.sh.
#
# Contract: .ccpraxis-local-data/blueprints/hook-continuity-remake/specs/
# 14-guards-remake-spec.md sec 3.1. Architecture:
# plugins/butler/docs/hook-architecture.md ("guard-bash" successor row).
#
# run($p, @args) never calls exit, never dies on purpose, never spawns a
# process (no system/exec/backtick/qx/pipe-open). Prints only through
# BpHook::deny(@lines). Never re-parses the payload (BpHook::parse_count()
# is unchanged by run()). Session facts come only from the core
# (BpHook::session_id/agent_id/role/is_armed/data_dir) -- no drive-solo/
# continuity/run-state/current.json file is read directly, no
# $CLAUDE_CODE_SESSION_ID is read (Decision 3). Fail direction after the
# wrapper's prefilter: open (return 0) on any internal ambiguity, except
# where a rule below says otherwise (none do, in this successor).
package BpHook::Guards::GuardBash;
use strict;
use warnings;
use JSON::PP ();
use File::Basename qw(dirname basename);
use Cwd ();

my $SELF_DIR;
{
    my $f = __FILE__;
    $f = Cwd::abs_path($f) // $f;
    $SELF_DIR = dirname($f);
}
require "$SELF_DIR/../../BpHook.pm"
    unless grep { m{(?:^|/)BpHook\.pm$} } keys %INC;
require "$SELF_DIR/Common.pm"
    unless grep { m{(?:^|/)Guards/Common\.pm$} } keys %INC;
require "$SELF_DIR/Shell.pm"
    unless grep { m{(?:^|/)Guards/Shell\.pm$} } keys %INC;

my $TUID_NAME_RE = qr/^[A-Za-z0-9_-]{1,128}$/;

# ---------------------------------------------------------------------------
# small helpers, local to this module.
# ---------------------------------------------------------------------------

sub _is_true_json {
    my ($v) = @_;
    return 0 unless defined $v;
    return $v ? 1 : 0 if ref $v;
    return ($v eq 'true' || $v eq '1') ? 1 : 0;
}

sub _digits_or_default {
    my ($v, $default) = @_;
    return $default unless defined $v && length $v;
    return $default unless $v =~ /^[0-9]+$/;
    return $v + 0;
}

sub _sanitize {
    my ($s, $max) = @_;
    return '' unless defined $s;
    (my $v = $s) =~ s/[^A-Za-z0-9_-]//g;
    return substr($v, 0, $max);
}

sub _read_bytes {
    my ($path) = @_;
    open(my $fh, '<:raw', $path) or return undef;
    local $/;
    my $c = <$fh>;
    close $fh;
    return $c;
}

# marker mtime freshness. $policy is 'fresh' (future or unreadable mtime
# counts as fresh, spec 2.5 -- own/driver markers) or 'stale' (future or
# unreadable mtime counts as stale, spec 3.1(b)/GB-10 -- the tree-wide
# interlock, so a foreign marker with clock-skewed or unknown mtime never
# wedges the whole tree). $stale_min is the already-normalised positive
# integer.
sub _fresh_mtime {
    my ($path, $stale_min, $policy) = @_;
    $policy = 'fresh' unless defined $policy;
    my @st = stat($path);
    if (!@st) {
        return $policy eq 'stale' ? 0 : 1; # unreadable
    }
    my $mtime = $st[9];
    if (!defined $mtime) {
        return $policy eq 'stale' ? 0 : 1;
    }
    my $now = time();
    if ($mtime > $now) {
        return $policy eq 'stale' ? 0 : 1; # future mtime
    }
    my $age_min = ($now - $mtime) / 60;
    return 1 if $age_min < $stale_min;
    return 0;
}

sub _stale_min {
    my $v = $ENV{CCPRAXIS_VALIDATION_STALE_MIN};
    return _digits_or_default($v, 180) > 0 ? _digits_or_default($v, 180) : 180;
}

# ---------------------------------------------------------------------------
# MATCH_TEXT / anchor computation shared by GB-a and GB-c (spec sec 3.1
# "MATCH_TEXT and anchor class").
# ---------------------------------------------------------------------------
sub _match_text_and_reason {
    my ($cmd) = @_;
    my $max = _digits_or_default($ENV{BP_GUARD_MAX_STRIP_BYTES}, 8000);
    $max = 8000 unless $max > 0;
    if (length($cmd) <= $max) {
        # m8: reuse Common's shared shell/eval/heredoc-into-shell detector
        # instead of an inline copy of just the "-c" half.
        if (BpHook::Guards::Common::is_shell_or_eval_invocation($cmd)) {
            return ($cmd, 'shellword');
        }
        if (BpHook::Guards::Common::line_match(qr/\x60|\$\(/, $cmd)) {
            return ($cmd, 'carrier');
        }
        my $stripped = BpHook::Guards::Shell::strip_noise($cmd);
        if (defined $stripped && length $stripped) {
            return ($stripped, 'plain');
        }
    }
    return ($cmd, 'plain');
}

sub _anchor_for {
    my ($reason) = @_;
    return '(^|[;&|\s\'"\x60({])' if $reason eq 'shellword';
    return '(^|[;&|\s\x60({])'    if $reason eq 'carrier';
    return '(^|[;&|\s({])';
}

# ---------------------------------------------------------------------------
# GB-a -- coordinator denials. BP_LEDGER non-empty, any BP_ROLE.
# ---------------------------------------------------------------------------
sub _gb_a {
    my ($p, $cmd) = @_;
    return undef unless defined $ENV{BP_LEDGER} && length $ENV{BP_LEDGER};

    my ($match_text, $reason) = _match_text_and_reason($cmd);
    my $A = _anchor_for($reason);
    my $GITOPT = BpHook::Guards::Common::git_opt_re();
    my $cmd_line = 'Command: ' . BpHook::Guards::Common::echo_cmd($cmd);

    # 1: git working-tree / history mutations.
    if (BpHook::Guards::Common::line_match(
            qr/${A}git[[:space:]]+${GITOPT}(checkout|switch|restore|reset|clean|rebase|merge|commit|push)\b/,
            $match_text))
    {
        return [
            'BLOCKED: git working-tree/history mutations are reserved for the orchestrator. Coordinators and workers change files only via Edit/Write.',
            $cmd_line,
        ];
    }

    # 2: git stash (list/show excepted). The negative lookahead is checked
    # against the SAME occurrence, not the whole command (redteam M3), so
    # "git stash list && git stash pop" still denies on the pop.
    if (BpHook::Guards::Common::line_match(
            qr/${A}git[[:space:]]+${GITOPT}stash\b(?![[:space:]]+(list|show)\b)/, $match_text))
    {
        return [
            'BLOCKED: git stash mutations are forbidden in coordinator sessions (list/show are fine).',
            $cmd_line,
        ];
    }

    # 3: rm -rf outside the allowed roots.
    if (BpHook::Guards::Common::line_match(qr/${A}rm[[:space:]]+-[a-zA-Z]*r[a-zA-Z]*f/, $match_text)
        || BpHook::Guards::Common::line_match(qr/${A}rm[[:space:]]+-[a-zA-Z]*f[a-zA-Z]*r/, $match_text))
    {
        my $bp_dir = $ENV{BP_DIR};
        my $exempt = (index($match_text, '/tmp/') >= 0)
            || (index($match_text, 'integration_test/screenshots') >= 0)
            || (defined $bp_dir && length $bp_dir && index($match_text, $bp_dir) >= 0);
        unless ($exempt) {
            return [
                'BLOCKED: rm -rf is only allowed under /tmp, the blueprint dir, or the test screenshot dir; record unexpected state in the ledger instead.',
                $cmd_line,
            ];
        }
    }

    # 4: deploys / publishing.
    if (BpHook::Guards::Common::line_match(qr/${A}firebase[[:space:]]+deploy\b/, $match_text)
        || BpHook::Guards::Common::line_match(qr/${A}gcloud[[:space:]][^;|&]*deploy\b/, $match_text)
        || BpHook::Guards::Common::line_match(qr/${A}npm[[:space:]]+publish\b/, $match_text))
    {
        return [
            'BLOCKED: deploys and publishing never happen from coordinator sessions (CI-only by project policy).',
            $cmd_line,
        ];
    }

    # 5: BP_BASH_EXTRA_DENY.
    my $extra = $ENV{BP_BASH_EXTRA_DENY};
    if (defined $extra && length $extra) {
        my $compiled = eval { qr/$extra/ };
        if (defined $compiled && BpHook::Guards::Common::line_match($compiled, $match_text)) {
            return [
                'BLOCKED: the command matches the BP_BASH_EXTRA_DENY policy.',
                $cmd_line,
            ];
        }
    }

    return undef;
}

# ---------------------------------------------------------------------------
# GB-b -- headless background. BP_LEDGER non-empty.
# ---------------------------------------------------------------------------
sub _gb_b {
    my ($p, $cmd, $ti) = @_;
    return undef unless defined $ENV{BP_LEDGER} && length $ENV{BP_LEDGER};
    return undef unless ref $ti eq 'HASH' && _is_true_json($ti->{run_in_background});
    return undef if defined BpHook::sole_invocation($cmd, 'butler-hold');

    my $role = $ENV{BP_ROLE};
    my $who;
    if (!defined $role || $role eq '' || $role eq 'coordinator') {
        $who = 'coordinator';
    }
    else {
        $who = "\x60" . _sanitize($role, 32) . "\x60";
    }
    return [
        "BLOCKED: run_in_background is forbidden in a headless $who: ending the turn ends the process, so its notification never arrives.",
        'Run it in the foreground and wait for the result in this turn; only a command that is exactly one butler-hold call may run in the background.',
    ];
}

# ---------------------------------------------------------------------------
# GB-c -- judge checks. BP_LEDGER non-empty, BP_ROLE eq harvest-judge.
# ---------------------------------------------------------------------------
sub _gb_c {
    my ($p, $cmd) = @_;
    return undef unless defined $ENV{BP_LEDGER} && length $ENV{BP_LEDGER};
    my $role = $ENV{BP_ROLE};
    return undef unless defined $role && $role eq 'harvest-judge';

    my ($match_text, undef) = _match_text_and_reason($cmd);
    my $plain_anchor = _anchor_for('plain');
    if (BpHook::Guards::Common::line_match(
            qr/${plain_anchor}([^\s;&|]*\/)?(pnpm|npm|yarn)[[:space:]]+(run[[:space:]]+)?(lint|build|test)\b/,
            $match_text))
    {
        return [
            'BLOCKED: harvest judges verify a declared checks: entry from its recorded evidence, never by re-running it.',
            'Command: ' . BpHook::Guards::Common::echo_cmd($cmd),
        ];
    }
    return undef;
}

# ---------------------------------------------------------------------------
# GB-d -- validation interlock.
# ---------------------------------------------------------------------------
my $VALIDATION_RE = qr/
    (^|[;&|\s'"\x60(])(pnpm|npm|yarn)[[:space:]]+(run[[:space:]]+)?(test|build|lint)\b
  | (^|[;&|\s'"\x60(])npx[[:space:]]+(vitest|jest|mocha|playwright)\b
  | (^|[;&|\s'"\x60(])(pytest|prove)\b
  | (^|[;&|\s'"\x60(])(go|cargo|flutter|dart)[[:space:]]+(test|analyze)\b
  | (^|[;&|\s'"\x60(])perl[[:space:]]+(-[^[:space:]]+[[:space:]]+)*([^\s;&|]*\/)?run-tests\.pl\b
  | (^|[;&|])[[:space:]]*([^\s;&|]*\/)?run-tests\.pl\b
  | (^|[;&|\s'"\x60(])perl[[:space:]]+(-[^[:space:]]+[[:space:]]+)*\S*\.t\b
/x;

# redteam M1: command substitution ($(...)), a bare subshell ((...)), and a
# shell/eval in command position (bash -c '...') each hide the real
# validation command from strip_noise's quote/heredoc blanking, so those
# three shapes must be matched against the RAW command, exactly like
# GuardBash's own GB-a shellword/carrier escape (spec sec 3.1).
#
# 24-interlock-scope B-8/B-9/B-10: the raw-vs-stripped decision now probes
# the STRIPPED text for a backtick/$(/bare-paren, not the raw command, so a
# quoted argument (e.g. ledger note text) that merely contains one of those
# characters does not switch matching to the raw command. Two triggers still
# force raw matching: is_shell_or_eval_invocation on the raw command
# (unchanged), and a raw command that carries "<<" together with a backtick
# or "$(" (an unquoted heredoc body still expands at shell level even though
# strip_noise blanks it).
sub _validation_shaped {
    my ($cmd) = @_;
    my $vtext;
    my $stripped = BpHook::Guards::Shell::strip_noise($cmd);
    my $probe = (defined $stripped && length $stripped) ? $stripped : $cmd;
    if (BpHook::Guards::Common::is_shell_or_eval_invocation($cmd)
        || BpHook::Guards::Common::line_match(qr/\x60|\$\(|\(/, $probe)
        || (BpHook::Guards::Common::line_match(qr/<</, $cmd)
            && BpHook::Guards::Common::line_match(qr/\x60|\$\(/, $cmd)))
    {
        $vtext = $cmd;
    }
    else {
        $vtext = $probe;
    }
    $vtext = _neutralize_perl_syntax_checks($vtext);
    $vtext =~ s/\\\n/ /g;
    return BpHook::Guards::Common::line_match($VALIDATION_RE, $vtext);
}

# 24-interlock-scope B-7: a perl invocation carrying a syntax-check flag
# (an option token, between "perl" and its script operand, matching
# ^-[wWXtT]*c[wWXtT]*$) is never validation-shaped. Judged per invocation --
# "perl -c a.t && perl b.t" is still validation-shaped through its second
# invocation, because the neutralisation only blanks the ONE matched perl
# invocation that carries the flag.
my $PERL_INVOCATION_RE = qr/(^|[;&|])([\x20\t]*)perl\b((?:[\x20\t]+[^\s;&|]+)*)/m;

sub _neutralize_perl_syntax_checks {
    my ($text) = @_;
    return $text unless defined $text && length $text;
    my $out = $text;
    $out =~ s{$PERL_INVOCATION_RE}{
        my ($sep, $ws, $rest) = ($1, $2, $3);
        my $has_c = 0;
        for my $tok (split /[\x20\t]+/, $rest) {
            next unless length $tok;
            last unless $tok =~ /^-/;
            if ($tok =~ /^-[wWXtT]*c[wWXtT]*$/) { $has_c = 1; last }
        }
        $has_c
            ? ($sep . (' ' x (length($ws) + length('perl') + length($rest))))
            : ($sep . $ws . 'perl' . $rest);
    }ge;
    return $out;
}

# tree-wide scan (b), shared by the coordinator and driver branches.
sub _tree_check {
    my ($p, $cmd, $data, $root, $self, $stale_min) = @_;
    return undef unless defined $data && length $data && -d $data;
    return undef unless defined $root && length $root && -d $root;

    if (defined $ENV{CCPRAXIS_TREE_INTERLOCK_OFF} && $ENV{CCPRAXIS_TREE_INTERLOCK_OFF} eq '1') {
        return undef;
    }
    my $hatch = "$data/.tree-interlock-off";
    if (-e $hatch) {
        my $ttl = _digits_or_default($ENV{CCPRAXIS_TREE_INTERLOCK_OFF_TTL_MIN}, 60);
        $ttl = 60 unless $ttl > 0;
        $ttl = 1440 if $ttl > 1440;
        my @st = stat($hatch);
        my $honoured = 1;
        if (@st && defined $st[9]) {
            my $mtime = $st[9];
            my $now = time();
            if ($mtime <= $now) {
                my $age_min = ($now - $mtime) / 60;
                $honoured = ($age_min < $ttl) ? 1 : 0;
            }
            else {
                $honoured = 0; # future-dated hatch: not honoured
            }
        }
        if ($honoured) {
            return undef;
        }
        unlink($hatch);
    }

    opendir(my $dh, $root) or return undef;
    my @subdirs = sort grep { $_ ne '.' && $_ ne '..' } readdir($dh);
    closedir $dh;

    my @candidates;
    for my $sub (@subdirs) {
        my $rundir = "$root/$sub/runs";
        next unless -d $rundir;
        opendir(my $rdh, $rundir) or next;
        my @files = sort grep { /\.active-worker$/ } readdir($rdh);
        closedir $rdh;
        for my $f (@files) {
            push @candidates, "$rundir/$f";
        }
    }
    @candidates = sort @candidates;

    my $n = 0;
    for my $c (@candidates) {
        next if defined $self && $c eq $self;
        next unless -f $c;
        $n++;
        return undef if $n > 32;
        next unless _fresh_mtime($c, $stale_min, 'stale');
        my $content = _read_bytes($c);
        next unless defined $content && length $content;
        my $role = BpHook::Guards::Common::is_writer($content);
        next unless defined $role;
        my $pkg = basename($c);
        $pkg =~ s/\.active-worker$//;
        my $bpname = basename(dirname(dirname($c)));
        return [
            $role,
            _sanitize($bpname, 64),
            _sanitize($pkg, 64),
        ];
    }
    return undef;
}

# ---------------------------------------------------------------------------
# 24-interlock-scope Decision 85/92 -- write-set overlap (mirrors
# bp-ledger.pl's _widen_ws_prefixes/_widen_prefix_related exactly, AC-15) and
# binding resolution (spec sec 2.2). Pure/private helpers plus the one
# public entry point.
# ---------------------------------------------------------------------------
sub _widen_ws_prefixes {
    my ($paths) = @_;
    my @out;
    return @out unless ref $paths eq 'ARRAY';
    for my $p (@$paths) {
        next unless defined $p && !ref($p) && length $p;
        (my $q = $p) =~ s/\*.*$//;
        $q =~ s{/+$}{};
        push @out, $q;
    }
    return @out;
}

sub _widen_ws_is_ci {
    return ($^O =~ /^(?:msys|MSWin32|cygwin|darwin)$/) ? 1 : 0;
}

sub _widen_ws_fold {
    my ($s) = @_;
    return $s unless _widen_ws_is_ci();
    (my $v = $s) =~ tr/A-Z/a-z/;
    return $v;
}

sub _widen_prefix_related {
    my ($a, $b) = @_;
    $a = _widen_ws_fold($a);
    $b = _widen_ws_fold($b);
    return 1 if $a eq $b;
    return 1 if $a eq '' || $b eq '';
    return 1 if index("$b/", "$a/") == 0;
    return 1 if index("$a/", "$b/") == 0;
    return 0;
}

# write_sets_overlap(\@ws_a, \@ws_b) -> 1 | 0. Pure: never touches the
# filesystem, never dies. A non-arrayref argument counts as an empty list.
sub write_sets_overlap {
    my ($ws_a, $ws_b) = @_;
    my @pa = _widen_ws_prefixes($ws_a);
    my @pb = _widen_ws_prefixes($ws_b);
    for my $x (@pa) {
        for my $y (@pb) {
            return 1 if _widen_prefix_related($x, $y);
        }
    }
    return 0;
}

sub _valid_member_name {
    my ($v) = @_;
    return 0 unless defined $v && !ref($v) && length $v;
    return 0 unless $v =~ /^[A-Za-z0-9][A-Za-z0-9._-]{0,119}$/;
    return 0 if index($v, '..') >= 0;
    return 1;
}

# _resolve_binding($data_n, $tuid) -> { blueprint, package, write_set =>
# [entries] } | undef. Spec sec 2.2. Never dies; any parse/read failure is
# an undef (conservative fallback upstream).
sub _resolve_binding {
    my ($data_n, $tuid) = @_;
    return undef unless defined $tuid && $tuid =~ $TUID_NAME_RE;
    my $braw = _read_bytes("$data_n/.drive-solo/bindings/$tuid.json");
    return undef unless defined $braw && length $braw;
    my $rec = eval { JSON::PP->new->utf8->decode($braw) };
    return undef unless ref $rec eq 'HASH';
    my ($bp, $pkg) = ($rec->{blueprint}, $rec->{package});
    return undef unless _valid_member_name($bp) && _valid_member_name($pkg);

    my $lraw = _read_bytes("$data_n/blueprints/$bp/packages/$pkg.md");
    return undef unless defined $lraw && length $lraw;
    my @lines = split /\n/, $lraw;
    return undef unless @lines;
    (my $first = $lines[0]) =~ s/[ \t\r]+$//;
    return undef unless $first eq '---';

    my $ws_val;
    for my $i (1 .. $#lines) {
        (my $l = $lines[$i]) =~ s/\r$//;
        last if $l eq '---';
        if (!defined $ws_val && $l =~ /^write_set:[\x20\t]*(.*?)[\x20\t]*$/) {
            $ws_val = $1;
        }
    }
    return undef unless defined $ws_val;
    my @ws = grep { length } split /:/, $ws_val;
    return undef unless @ws;
    return { blueprint => $bp, package => $pkg, write_set => \@ws };
}

sub _gb_d {
    my ($p, $cmd) = @_;
    return undef unless _validation_shaped($cmd);

    my $stale_min = _stale_min();
    my $cmd_line = 'Not run: ' . BpHook::Guards::Common::echo_cmd($cmd)
        . "; retry when the worker returns (marker ages out after $stale_min min).";
    my $tree_cmd_line = 'Not run: ' . BpHook::Guards::Common::echo_cmd($cmd)
        . "; retry when that worker returns (marker ages out after $stale_min min).";

    my $ledger = $ENV{BP_LEDGER};
    my $bp_dir = $ENV{BP_DIR};

    if (defined $ledger && length $ledger && defined $bp_dir && length $bp_dir) {
        # coordinator branch
        my $pkg = (defined $ENV{BP_PACKAGE} && length $ENV{BP_PACKAGE}) ? $ENV{BP_PACKAGE} : 'pkg';
        (my $bp_dir_n = $bp_dir) =~ tr{\\}{/};
        $bp_dir_n =~ s{/+$}{};
        my $marker = "$bp_dir_n/runs/$pkg.active-worker";
        if (-f $marker) {
            my $content = _read_bytes($marker);
            if (defined $content && length $content) {
                my $role = BpHook::Guards::Common::is_writer($content);
                if (defined $role && _fresh_mtime($marker, $stale_min)) {
                    return [
                        "BLOCKED (validation interlock): a write-capable worker ($role) is in flight; running this now can report a false red.",
                        $cmd_line,
                    ];
                }
            }
        }

        my $parent = dirname($bp_dir_n);
        if (basename($parent) eq 'blueprints') {
            my $root = $parent;
            my $self = "$root/" . basename($bp_dir_n) . "/runs/$pkg.active-worker";
            my $data = dirname($root);
            my $found = _tree_check($p, $cmd, $data, $root, $self, $stale_min);
            if (defined $found) {
                my ($role, $bpname, $pkgname) = @$found;
                return [
                    "BLOCKED (tree interlock): $role of blueprint $bpname package $pkgname is mid-edit in this working tree; this run could report a false red.",
                    $tree_cmd_line,
                ];
            }
        }
        return undef;
    }

    if (!defined $ledger || !length $ledger) {
        my $role = BpHook::role($p);
        if ($role eq 'driver') {
            my $data = BpHook::data_dir($p);
            return undef unless defined $data && length $data;
            (my $data_n = $data) =~ tr{\\}{/};
            $data_n =~ s{/+$}{};
            my $workers_dir = "$data_n/.drive-solo/workers";
            if (-d $workers_dir) {
                my $sid = BpHook::session_id($p);
                my $aid = BpHook::agent_id($p);
                my $own_binding;
                my $caller_ws;    # defined only when the caller's own
                                  # write set resolved -- write-set scoping
                                  # (Decision 85) applies only then.
                if (defined $aid) {
                    $own_binding = BpHook::Guards::Common::subagent_tool_use_id($p);
                    return undef unless defined $own_binding; # fail open: cannot tell subagent apart
                    my $caller_resolved = _resolve_binding($data_n, $own_binding);
                    $caller_ws = $caller_resolved->{write_set} if defined $caller_resolved;
                }
                opendir(my $wdh, $workers_dir);
                if ($wdh) {
                    my @names = sort grep { $_ =~ $TUID_NAME_RE } readdir($wdh);
                    closedir $wdh;
                    my $seen = 0;
                    for my $name (@names) {
                        my $full = "$workers_dir/$name";
                        next unless -f $full;
                        $seen++;
                        last if $seen > 32;
                        next if defined $own_binding && $name eq $own_binding;
                        my $content = _read_bytes($full);
                        next unless defined $content && length $content;
                        my $data_rec = eval { JSON::PP->new->utf8->decode($content) };
                        next unless ref $data_rec eq 'HASH';
                        next unless defined $data_rec->{session_id} && defined $sid
                            && $data_rec->{session_id} eq $sid;
                        my $role_writer = BpHook::Guards::Common::is_writer($data_rec->{subagent_type});
                        next unless defined $role_writer;
                        next unless _fresh_mtime($full, $stale_min);

                        if (defined $caller_ws) {
                            # write-set-scoped subagent (B-3/B-4/B-5/B-6).
                            my $w_resolved = _resolve_binding($data_n, $name);
                            if (!defined $w_resolved) {
                                # B-5: the other worker's footprint is
                                # unknown -- conservative fallback deny.
                                return [
                                    "BLOCKED (validation interlock): a write-capable worker ($role_writer) is in flight; running this now can report a false red.",
                                    $cmd_line,
                                ];
                            }
                            if (write_sets_overlap($caller_ws, $w_resolved->{write_set})) {
                                my $bpname  = _sanitize($w_resolved->{blueprint}, 64);
                                my $pkgname = _sanitize($w_resolved->{package}, 64);
                                return [
                                    "BLOCKED (validation interlock): package $pkgname of blueprint $bpname has a write-capable worker ($role_writer) in flight whose write set overlaps yours; this run could report a false red.",
                                    $cmd_line,
                                ];
                            }
                            next; # B-4 disjoint: scan continues past this record.
                        }

                        # B-1 (driver main thread) / B-3 (own binding
                        # unresolvable): today's session-wide behaviour.
                        return [
                            "BLOCKED (validation interlock): a write-capable worker ($role_writer) is in flight; running this now can report a false red.",
                            $cmd_line,
                        ];
                    }
                }
            }

            my $root = "$data_n/blueprints";
            my $found = _tree_check($p, $cmd, $data_n, $root, undef, $stale_min);
            if (defined $found) {
                my ($rl, $bpname, $pkgname) = @$found;
                return [
                    "BLOCKED (tree interlock): $rl of blueprint $bpname package $pkgname is mid-edit in this working tree; this run could report a false red.",
                    $tree_cmd_line,
                ];
            }
            return undef;
        }
    }

    return undef;
}

# ---------------------------------------------------------------------------
# run($p, @args) -> 0 | 2.
# ---------------------------------------------------------------------------
sub run {
    my ($p, @args) = @_;
    $p = {} unless ref $p eq 'HASH';
    return 0 unless defined $p->{tool_name} && $p->{tool_name} eq 'Bash';
    my $ti = $p->{tool_input};
    return 0 unless ref $ti eq 'HASH';
    my $cmd = $ti->{command};
    return 0 unless defined $cmd && !ref($cmd) && length $cmd;

    for my $rule (\&_gb_a, \&_gb_b, \&_gb_c, \&_gb_d) {
        my $lines = eval { $rule->($p, $cmd, $ti) };
        if (defined $lines) {
            my @fitted = map { BpHook::Guards::Common::fit($_) } @$lines;
            return BpHook::deny(@fitted);
        }
    }
    return 0;
}

1;
