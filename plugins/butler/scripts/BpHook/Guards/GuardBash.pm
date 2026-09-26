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
    # NIT-4 (24-interlock-scope-review): keep '.', which _valid_member_name
    # allows in a package/blueprint name -- stripping it mangled the name
    # shown in the deny text.
    (my $v = $s) =~ s/[^A-Za-z0-9_.-]//g;
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
#
# 24-interlock-scope-review M-2: an interpreter eval (perl/node/python
# invoked with -e, -E or -c) hides its real payload from strip_noise's own
# quote blanking exactly like the shell -c escape above, so it forces raw
# matching too.
my $INTERP_EVAL_RE = qr/(^|[;&|\s])(perl|node|python3?)[[:space:]]+(-[^\s]+[[:space:]]+)*-[A-Za-z]*[eEc]\b/;

# 34-runner-redirect-operands sec 2.2 -- a shell/interpreter/eval word
# anywhere in a command's non-body text means the heredoc body(ies) may be
# consumed as a real script (stdin, a pipe after the terminator, or a
# captured-then-eval'd copy), so blanking is disabled for the whole command
# (D2, deliberately coarse/global -- spec sec 2.2).
my $SHELLISH_RE = qr/(^|[;&|\s(\x60'"])(?:[^\s;&|'"]*\/)?
                     (?:(?:ba|z|k|da|fi)?sh|pwsh|powershell|perl|node|python3?|ruby|eval|source|\.)
                     (?=[\s;&|)'"]|$)/x;

# 34-runner-redirect-operands review M-1 -- the D2-widening half of
# $SHELLISH_RE: a plain interpreter-runs-a-file mention (perl/node/python/
# ruby with a script argument) does not widen the window on its own (that
# is Decision 114's still-valid case, AC-21/23); eval/source/./a bare shell
# DOES, because it can consume a heredoc body as a script.
my $SHELLISH_NARROW_RE = qr/(^|[;&|\s(\x60'"])(?:[^\s;&|'"]*\/)?
                     (?:(?:ba|z|k|da|fi)?sh|pwsh|powershell|eval|source|\.)
                     (?=[\s;&|)'"]|$)/x;

# A command-text line that ends in a pipe/&&/||  -- or has more '(' than
# ')' -- leaves its statement open past that line, so whatever consumes a
# heredoc's body may sit on a LATER line than its own terminator
# (`cat <<'EOF' |` ... `EOF` ... `bash`; `x=$(cat <<'EOF'` ... `EOF` ...
# `); eval "$x"`). Checked only up to the last terminator (review M-1).
my $LINE_LEFT_OPEN_RE = qr/(?:\|\||&&|\|&|\|)[ \t]*$/;

# REDIR_OP -- spec sec 2.1 "REDIRECT DROP". Alternatives listed longest
# first within each digit-optional/no-digit group so a token like "&>>" is
# never partially matched as "&>" with a stray ">" left over.
my $REDIR_OP = qr/^(?:[0-9]*(?:<<<|<<-|>>|>\||>&|<<|<&|<>|>|<)|&>>|&>)/;

# OPENER (spec sec 2.2, narrowed by 34-runner-redirect-operands review M-2)
# -- the heredoc-word alternatives are tried quoted-forms-first
# (single/double/backslash all -> quoted=1), then the bare form
# (quoted=0); the lookahead after the word requires end-of-line,
# whitespace, or one of ; & | < > ). The quoted/backslash WORD class is
# [A-Za-z0-9_]+, matching Shell::strip_noise's own delimiter grammar
# exactly (not the wider [A-Za-z0-9_.-]+ the spec originally gave) -- a
# delimiter strip_noise cannot parse (e.g. <<'END-DOC') must stay
# unrecognised here too, or its body silently falls back to today's
# (safe) behaviour instead of a phantom blank (M-2).
my $HEREDOC_OPENER_RE = qr/^<<(-)?[ \t]*
    (?:'([A-Za-z0-9_]+)'
      |"([A-Za-z0-9_]+)"
      |\\([A-Za-z0-9_]+)
      |([A-Za-z_][A-Za-z0-9_]*))
    (?=[\s;&|<>)]|$)/x;

# _drop_redirects(@tok) -> @kept -- spec sec 2.1 "REDIRECT DROP". Pure,
# private. Walks tokens left to right; a token that IS (wholly or partly) a
# redirect operator drops itself, and drops the next token too when the
# operator consumed the whole token (its target is then a separate token).
sub _drop_redirects {
    my (@tok) = @_;
    my @kept;
    my $i = 0;
    while ($i < @tok) {
        my $t = $tok[$i];
        if ($t =~ $REDIR_OP) {
            my $rest = substr($t, length($&));
            $i += ($rest eq '') ? 2 : 1;
            next;
        }
        push @kept, $t;
        $i++;
    }
    return @kept;
}

# _try_heredoc_opener($line, $pos) -> ($newpos, \%opener) | (undef, undef).
# Pure, private. $line must have "<<" at $pos.
sub _try_heredoc_opener {
    my ($line, $pos) = @_;
    my $rest = substr($line, $pos);
    if ($rest =~ $HEREDOC_OPENER_RE) {
        my $dash = $1 ? 1 : 0;
        my ($word, $quoted);
        if    (defined $2) { $word = $2; $quoted = 1; }
        elsif (defined $3) { $word = $3; $quoted = 1; }
        elsif (defined $4) { $word = $4; $quoted = 1; }
        elsif (defined $5) { $word = $5; $quoted = 0; }
        return ($pos + length($&), { word => $word, dash => $dash, quoted => $quoted });
    }
    return (undef, undef);
}

# _blank_data_heredocs_impl($cmd) -> $text. May die (caught by the
# _blank_data_heredocs wrapper); pure otherwise, never touches the
# filesystem. Implements the scanner/OPENER/data-heredoc rules of spec
# sec 2.2 exactly.
sub _blank_data_heredocs_impl {
    my ($cmd) = @_;
    my @lines = split /\n/, $cmd, -1;
    my $n = scalar @lines;
    my @is_body = (0) x $n;
    my @recorded;
    my $quote = 'none';
    my @pending;
    my $i = 0;
    my $abort = 0;

    OUTER: while ($i < $n) {
        my $line = $lines[$i];
        my $len = length($line);
        my $pos = 0;
        LINE: while ($pos < $len) {
            my $c = substr($line, $pos, 1);
            if ($quote eq 'squote') {
                $quote = 'none' if $c eq "'";
                $pos++;
                next LINE;
            }
            if ($quote eq 'dquote') {
                if ($c eq '\\') { $pos += 2; next LINE; }
                $quote = 'none' if $c eq '"';
                $pos++;
                next LINE;
            }
            # quote eq 'none'
            if ($c eq "'") { $quote = 'squote'; $pos++; next LINE; }
            if ($c eq '"') { $quote = 'dquote'; $pos++; next LINE; }
            if ($c eq '\\') {
                if ($pos == $len - 1) {
                    if (@pending) { $abort = 1; last LINE; }
                    $pos++;
                    next LINE;
                }
                $pos += 2;
                next LINE;
            }
            if ($c eq '#') {
                my $prev = $pos == 0 ? '' : substr($line, $pos - 1, 1);
                if ($pos == 0 || $prev =~ /[;&|\s(]/) {
                    $pos = $len;
                    next LINE;
                }
                $pos++;
                next LINE;
            }
            if (substr($line, $pos, 3) eq '<<<') {
                $pos += 3;
                next LINE;
            }
            if (substr($line, $pos, 2) eq '<<') {
                my ($newpos, $opener) = _try_heredoc_opener($line, $pos);
                if (defined $opener) {
                    push @pending, $opener;
                    $pos = $newpos;
                    next LINE;
                }
                # S-3 fail-safe: this "<<"/"<<-" LOOKED like it was trying
                # to open a heredoc (quote, backslash, or word character
                # right after it) but no valid opener parsed (e.g.
                # <<E"OF", <<'END DOC', <<"$X", <<'EOF'x). Silently skipping
                # 2 chars and continuing to scan the intended body as
                # ordinary command lines risks a later, unrelated line
                # being read as a phantom terminator and blanking real
                # command text -- abort instead (review S-3).
                my $probe = substr($line, $pos + 2);
                $probe =~ s/^-//;
                $probe =~ s/^[ \t]*//;
                if ($probe =~ /^['"\\]/ || $probe =~ /^[A-Za-z0-9_]/) {
                    $abort = 1;
                    last LINE;
                }
                $pos += 2;
                next LINE;
            }
            $pos++;
        }
        last OUTER if $abort;
        $i++;
        if (@pending && $quote eq 'none') {
            my $cursor = $i;
            for my $h (@pending) {
                my $body_start = $cursor;
                my $term_idx;
                for (my $j = $cursor; $j < $n; $j++) {
                    my $term = $lines[$j];
                    $term =~ s/^\t+// if $h->{dash};
                    if ($term eq $h->{word}) { $term_idx = $j; last; }
                }
                if (!defined $term_idx) { $abort = 1; last; }
                for my $k ($body_start .. $term_idx - 1) { $is_body[$k] = 1; }
                push @recorded, { %$h, body_start => $body_start, body_end => $term_idx };
                $cursor = $term_idx + 1;
            }
            $i = $cursor unless $abort;
        }
        last OUTER if $abort;
    }
    $abort = 1 if $quote ne 'none' || @pending;

    return $cmd unless @recorded;

    # D2 (global): no line of the command text (every line that is not a
    # recorded body line) may match $SHELLISH_RE. Decision 115 (review
    # M-1) supersedes Decision 114's plain terminator-bounded window: that
    # bound assumed nothing after the last terminator can consume a
    # heredoc body, which is false for `eval`/`source`/`.`/a shell word, an
    # interpreter's -e/-E/-c, or a statement left open across the
    # terminator (a trailing pipe/&&/||, or an unbalanced paren) --
    # `x=$(cat <<'EOF' ... EOF); eval "$x"` and `cat <<'EOF' | ... EOF
    # bash` both still run the body. The window widens to the WHOLE
    # command when either of those holds; otherwise it stays bounded to
    # the last terminator (keeps AC-21/23 -- a plain, unrelated
    # `perl scripts/run-tests.pl <file>` line after the heredoc closes
    # does not widen).
    my $last_term = 0;
    for my $h (@recorded) { $last_term = $h->{body_end} if $h->{body_end} > $last_term; }

    my $widen = 0;
    for my $li (0 .. $n - 1) {
        next if $is_body[$li];
        if ($lines[$li] =~ $SHELLISH_NARROW_RE
            || BpHook::Guards::Common::line_match($INTERP_EVAL_RE, $lines[$li]))
        {
            $widen = 1;
            last;
        }
    }
    if (!$widen) {
        for my $li (0 .. $last_term) {
            next if $is_body[$li];
            my $l = $lines[$li];
            my $opens  = () = $l =~ /\(/g;
            my $closes = () = $l =~ /\)/g;
            if ($l =~ $LINE_LEFT_OPEN_RE || $opens > $closes) {
                $widen = 1;
                last;
            }
        }
    }
    my $d2_end = $widen ? ($n - 1) : $last_term;
    for my $li (0 .. $d2_end) {
        next if $is_body[$li];
        return $cmd if $lines[$li] =~ $SHELLISH_RE;
    }

    my @out = @lines;
    for my $h (@recorded) {
        my $body = join("\n", @lines[$h->{body_start} .. $h->{body_end} - 1]);
        my $has_backtick_or_sub = ($body =~ /\x60|\$\(/) ? 1 : 0;
        next unless $h->{quoted} || !$has_backtick_or_sub; # D1
        for my $k ($h->{body_start} .. $h->{body_end} - 1) { $out[$k] = ''; }
    }
    return join("\n", @out);
}

# 34-runner-redirect-operands review S-2 -- one heredoc scan per command,
# reused across the (up to) two callers within one guard invocation
# (_validation_shaped and _is_full_sweep_runner commonly share the same
# $cmd). Bounded to a handful of entries: one hook process only ever
# blanks a small, fixed number of distinct command strings (never
# unbounded, since it exits after run()).
my %BLANK_CACHE;

# Above this many bytes the per-character scan cost is not worth paying;
# skip blanking and treat the whole command as command text (fails safe --
# the pre-package-34 behaviour for any input this large).
my $BLANK_MAX_BYTES = 65536;

# _blank_data_heredocs($cmd) -> $text. Spec sec 2.2. Never dies: any
# internal error returns $cmd unchanged. undef -> undef, '' -> ''.
sub _blank_data_heredocs {
    my ($cmd) = @_;
    return $cmd unless defined $cmd;
    return $cmd if index($cmd, '<<') < 0; # fast path
    return $cmd if length($cmd) > $BLANK_MAX_BYTES; # S-2 size cap
    return $BLANK_CACHE{$cmd} if exists $BLANK_CACHE{$cmd};
    my $out = eval { _blank_data_heredocs_impl($cmd) };
    $out = $cmd unless defined $out;
    %BLANK_CACHE = () if scalar(keys %BLANK_CACHE) > 8;
    $BLANK_CACHE{$cmd} = $out;
    return $out;
}

sub _validation_shaped {
    my ($cmd) = @_;
    my $H = _blank_data_heredocs($cmd);
    my $vtext;
    # 24-interlock-scope-review S-3: cap the strip_noise walk the same way
    # GB-a's own _match_text_and_reason does; over the cap, match raw (the
    # conservative direction and the pre-24 behaviour for paren-bearing
    # text).
    my $max = _digits_or_default($ENV{BP_GUARD_MAX_STRIP_BYTES}, 8000);
    $max = 8000 unless $max > 0;
    if (length($cmd) > $max) {
        $vtext = $H;
    }
    else {
        my $stripped = BpHook::Guards::Shell::strip_noise($cmd);
        my $probe = (defined $stripped && length $stripped) ? $stripped : $H;
        if (BpHook::Guards::Common::is_shell_or_eval_invocation($H)
            || BpHook::Guards::Common::line_match(qr/\x60|\$\(|\(/, $probe)
            || (BpHook::Guards::Common::line_match(qr/<</, $H)
                && BpHook::Guards::Common::line_match(qr/\x60|\$\(/, $H))
            || BpHook::Guards::Common::line_match($INTERP_EVAL_RE, $H)
            # 34-runner-redirect-operands review M-1: _blank_data_heredocs
            # left a "<<" heredoc UNBLANKED (D1/D2 said its body is real
            # command text, e.g. a body piped into a shell with no
            # backtick/$( of its own) -- Shell::strip_noise does not know
            # about D1/D2 and unconditionally blanks a quoted heredoc's
            # body, so trusting $probe here would silently lose exactly
            # the text D2 says must stay live. Match raw instead.
            || (index($H, '<<') >= 0 && $H eq $cmd))
        {
            $vtext = $H;
        }
        else {
            $vtext = $probe;
        }
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
        # 24-interlock-scope-review M-1: a command substitution, backtick or
        # process substitution among $rest's operands still runs a real
        # command at shell level even though the outer "perl -c ..." itself
        # never executes its script -- never blank those operands away.
        $has_c = 0 if $rest =~ /\x60|\$\(|[<>]\(/;
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

# _read_ledger_write_set($data_n, $bp, $pkg) -> \@entries | undef. The
# ledger-read half of _resolve_binding, split out so the caller can memoise
# it by "$bp/$pkg" (24-interlock-scope-review S-2) -- two workers bound to
# the same package must not read the same ledger file twice in one run.
sub _read_ledger_write_set {
    my ($data_n, $bp, $pkg) = @_;
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
    return \@ws;
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

    my $ws = _read_ledger_write_set($data_n, $bp, $pkg);
    return undef unless defined $ws;
    return { blueprint => $bp, package => $pkg, write_set => $ws };
}

# _resolve_binding_cached($data_n, $tuid, \%ledger_cache) -> same shape as
# _resolve_binding(), but the ledger half is memoised in %ledger_cache
# (keyed "$bp/$pkg") across the calls made within one _gb_d invocation
# (24-interlock-scope-review S-2 -- "cached per run call ... by ledger
# path").
sub _resolve_binding_cached {
    my ($data_n, $tuid, $ledger_cache) = @_;
    return undef unless defined $tuid && $tuid =~ $TUID_NAME_RE;
    my $braw = _read_bytes("$data_n/.drive-solo/bindings/$tuid.json");
    return undef unless defined $braw && length $braw;
    my $rec = eval { JSON::PP->new->utf8->decode($braw) };
    return undef unless ref $rec eq 'HASH';
    my ($bp, $pkg) = ($rec->{blueprint}, $rec->{package});
    return undef unless _valid_member_name($bp) && _valid_member_name($pkg);

    my $key = "$bp/$pkg";
    my $ws;
    if (exists $ledger_cache->{$key}) {
        $ws = $ledger_cache->{$key};
    }
    else {
        $ws = _read_ledger_write_set($data_n, $bp, $pkg);
        $ledger_cache->{$key} = $ws;
    }
    return undef unless defined $ws;
    return { blueprint => $bp, package => $pkg, write_set => $ws };
}

# ---------------------------------------------------------------------------
# 29-driver-validation-scope -- the driver's opt-in BP_VALIDATE_LEDGER=<path>
# scoping (spec sec 2.1/2.2). The name is read only from the command text
# (BpHook::_tokenize_words), never from the hook process's own %ENV.
# ---------------------------------------------------------------------------
sub _fold_path {
    my ($s) = @_;
    return '' unless defined $s;
    (my $v = $s) =~ tr{\\}{/};
    $v =~ s{/+$}{};
    if ($v =~ m{^/([A-Za-z])/(.*)$}) {
        $v = "$1:/$2";
    }
    $v = lc($v) if _widen_ws_is_ci();
    return $v;
}

# _named_validation_ledger($cmd) -> ($state, $value). $state is one of
# 'absent', 'value', 'bad'. Never dies (spec 2.1: "on any internal failure
# it returns ('bad', undef)").
sub _named_validation_ledger {
    my ($cmd) = @_;
    my @r = eval {
        return ('bad', undef) unless defined $cmd && length $cmd;
        (my $trimmed = $cmd) =~ s/^[\x20\t]+//;
        my $words = BpHook::_tokenize_words($trimmed);
        return ('bad', undef) unless ref $words eq 'ARRAY';
        my @prefix;
        for my $w (@$words) {
            last unless ref $w eq 'HASH' && defined $w->{raw}
                && $w->{raw} =~ /^[A-Za-z_][A-Za-z0-9_]*=/;
            push @prefix, $w;
        }
        my @matches = grep { index($_->{raw}, 'BP_VALIDATE_LEDGER=') == 0 } @prefix;
        return ('absent', undef) if @matches == 0;
        return ('bad', undef) if @matches > 1;
        my $mw = $matches[0];
        return ('bad', undef) unless defined $mw->{literal};
        my $value = substr($mw->{literal}, length('BP_VALIDATE_LEDGER='));
        return ('bad', undef) unless length($value);
        return ('bad', undef) if $value =~ /[\s;&|<>()]/;
        return ('value', $value);
    };
    return ('bad', undef) if $@;
    return @r;
}

# _resolve_named_ledger($data_n, $value, \%ledger_cache) -> { blueprint,
# package, write_set } | undef. Spec sec 2.2. Never dies.
sub _resolve_named_ledger {
    my ($data_n, $value, $ledger_cache) = @_;
    my $r = eval {
        return undef unless defined $data_n && length $data_n;
        return undef unless defined $value && length $value;
        (my $v = $value) =~ tr{\\}{/};
        $v =~ s{^\./}{};
        return undef unless $v =~ m{^(.+)/blueprints/([^/]+)/packages/([^/]+)\.md$};
        my ($prefix, $bp, $pkg) = ($1, $2, $3);
        return undef unless _valid_member_name($bp) && _valid_member_name($pkg);

        my $fp = _fold_path($prefix);
        return undef
            unless $fp eq _fold_path(basename($data_n)) || $fp eq _fold_path($data_n);

        my $iraw = _read_bytes("$data_n/.drive-solo/inflight.json");
        return undef unless defined $iraw && length $iraw;
        my $idata = eval { JSON::PP->new->utf8->decode($iraw) };
        return undef unless ref $idata eq 'HASH' && ref $idata->{packages} eq 'ARRAY';
        my $found = 0;
        for my $e (@{ $idata->{packages} }) {
            next unless ref $e eq 'HASH';
            if (defined $e->{blueprint} && defined $e->{package}
                && $e->{blueprint} eq $bp && $e->{package} eq $pkg)
            {
                $found = 1;
                last;
            }
        }
        return undef unless $found;

        my $key = "$bp/$pkg";
        my $ws;
        if (exists $ledger_cache->{$key}) {
            $ws = $ledger_cache->{$key};
        }
        else {
            $ws = _read_ledger_write_set($data_n, $bp, $pkg);
            $ledger_cache->{$key} = $ws;
        }
        return undef unless defined $ws;
        return { blueprint => $bp, package => $pkg, write_set => $ws };
    };
    return undef if $@;
    return $r;
}

# _is_full_sweep_runner($cmd) -> true iff ANY run-tests.pl invocation, in
# any separator-delimited segment on any line, invokes it with no path
# operand, with --fast, or with two-or-more path operands
# (24-interlock-scope-review S-1; 34-runner-redirect-operands DC6/spec
# sec 2.1 -- every invocation is classified, on the heredoc-blanked text,
# with redirects already dropped). Write-set scoping approximates what a
# run WRITES; a full or multi-plugin sweep also READS every other
# in-flight worker's half-written files, so it is denied by presence of
# any live writer alone, regardless of write-set overlap.
my $RUNNER_SEPARATOR_RE = qr/(?:;|(?<![<>])&(?!>)|(?<!>)\|)/;


# 34-runner-redirect-operands review M-3 -- a redirect glued directly onto
# the runner token (no space: "run-tests.pl&>log", "run-tests.pl>log",
# "run-tests.pl>|log") must be split off BEFORE _drop_redirects runs, or it
# survives as the runner token's own trailing text and is unshifted back
# into @tail afterwards, uncoupled from the drop -- which then always
# fail-opens it into a single-operand (never full-sweep) reading no matter
# what the operator is.
sub _split_glued_redirect {
    my (@tok) = @_;
    my @out;
    for my $t (@tok) {
        if ($t =~ m{^(.*(?:^|/)run-tests\.pl)([<>&|].*)$}) {
            my ($head, $tail) = ($1, $2);
            if ($tail =~ $REDIR_OP) {
                push @out, $head, $tail;
                next;
            }
        }
        push @out, $t;
    }
    return @out;
}

sub _is_full_sweep_runner {
    my ($cmd) = @_;
    return 0 unless defined $cmd;
    return 0 if index($cmd, 'run-tests.pl') < 0; # fast path: one index call
    my $text = _blank_data_heredocs($cmd);
    $text =~ s/\\\n/ /g;
    for my $line (split /\n/, $text) {
        for my $seg (split $RUNNER_SEPARATOR_RE, $line) {
            next unless defined $seg;
            my @tok = grep { length } split /\s+/, $seg;
            @tok = _split_glued_redirect(@tok);
            my @kept = _drop_redirects(@tok);
            my $k;
            for my $idx (0 .. $#kept) {
                if ($kept[$idx] =~ m{(?:^|/)run-tests\.pl\b}) { $k = $idx; last; }
            }
            next unless defined $k;
            my @tail = @kept[$k + 1 .. $#kept];
            my $rem;
            if ($kept[$k] =~ m{(?:^|/)run-tests\.pl(.*)$}) { $rem = $1; }
            unshift @tail, $rem if defined $rem && length $rem;
            return 1 if grep { /^--fast\b/ } @tail;
            my @args = grep { $_ !~ /^--?/ } @tail;
            return 1 if @args == 0 || @args >= 2;
        }
    }
    return 0;
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
                if (defined $aid) {
                    $own_binding = BpHook::Guards::Common::subagent_tool_use_id($p);
                    return undef unless defined $own_binding; # fail open: cannot tell subagent apart
                }
                opendir(my $wdh, $workers_dir);
                if ($wdh) {
                    my @names = sort grep { $_ =~ $TUID_NAME_RE } readdir($wdh);
                    closedir $wdh;
                    my $seen = 0;
                    my %ledger_ws_cache; # "$bp/$pkg" -> \@entries|undef, memoised for this call (S-2).
                    my $caller_ws;        # defined only when the caller's own
                                          # write set resolved -- write-set scoping
                                          # (Decision 85) applies only then.
                    my $caller_ws_tried = 0; # resolve the caller's own binding
                                              # lazily, only once a live writer
                                              # is actually found (S-2).
                    my $full_sweep;
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

                        # S-2: only now, with a live writer confirmed, pay
                        # for resolving the caller's own binding -- and only
                        # once per call.
                        if (!$caller_ws_tried) {
                            if (defined $own_binding) {
                                $caller_ws_tried = 1;
                                my $caller_resolved = _resolve_binding_cached($data_n, $own_binding, \%ledger_ws_cache);
                                $caller_ws = $caller_resolved->{write_set} if defined $caller_resolved;
                                $full_sweep = _is_full_sweep_runner($cmd) if defined $caller_ws;
                            }
                            elsif (!defined $aid) {
                                # 29-driver-validation-scope: the driver main
                                # thread has no binding of its own, but may
                                # opt in to the same scoping via a leading
                                # BP_VALIDATE_LEDGER=<ledger> on the command.
                                $caller_ws_tried = 1;
                                my ($st, $val) = _named_validation_ledger($cmd);
                                if ($st eq 'value') {
                                    my $r = _resolve_named_ledger($data_n, $val, \%ledger_ws_cache);
                                    $caller_ws = $r->{write_set} if defined $r;
                                }
                                $full_sweep = _is_full_sweep_runner($cmd) if defined $caller_ws;
                            }
                        }

                        if (defined $caller_ws) {
                            # write-set-scoped subagent (B-3/B-4/B-5/B-6).
                            my $w_resolved = _resolve_binding_cached($data_n, $name, \%ledger_ws_cache);
                            if (!defined $w_resolved) {
                                # B-5: the other worker's footprint is
                                # unknown -- conservative fallback deny.
                                return [
                                    "BLOCKED (validation interlock): a write-capable worker ($role_writer) is in flight; running this now can report a false red.",
                                    $cmd_line,
                                ];
                            }
                            # 34-runner-redirect-operands sec 2.4: overlap
                            # wins over the full-sweep text when both are
                            # true against the same writer (keeps today's
                            # output for every case where the overlap claim
                            # is true).
                            if (write_sets_overlap($caller_ws, $w_resolved->{write_set})) {
                                my $bpname  = _sanitize($w_resolved->{blueprint}, 64);
                                my $pkgname = _sanitize($w_resolved->{package}, 64);
                                return [
                                    "BLOCKED (validation interlock): package $pkgname of blueprint $bpname has a write-capable worker ($role_writer) in flight whose write set overlaps yours; this run could report a false red.",
                                    $cmd_line,
                                ];
                            }
                            # S-1: a full/multi-plugin sweep reads every
                            # in-flight worker's files regardless of write-set
                            # overlap, so it is denied by mere presence of a
                            # live writer.
                            if ($full_sweep) {
                                my $bpname  = _sanitize($w_resolved->{blueprint}, 64);
                                my $pkgname = _sanitize($w_resolved->{package}, 64);
                                return [
                                    'BLOCKED (validation interlock): a multi-file or full sweep reads every in-flight worker\'s files, so it is denied while any write-capable worker is live.',
                                    "Live writer: $role_writer, package $pkgname of blueprint $bpname. Name exactly one test file to get write-set scoping instead.",
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
