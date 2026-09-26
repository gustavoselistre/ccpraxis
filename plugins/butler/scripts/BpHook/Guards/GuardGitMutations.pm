# BpHook::Guards::GuardGitMutations -- denies git working-tree/history
# mutations (git stash; git checkout/switch/restore/reset/clean) in every
# session, plus a second, run-scoped registration (package 14 of blueprint
# hook-continuity-remake), successor to guard-git-mutations.sh (both of its
# registrations).
#
# Contract: .ccpraxis-local-data/blueprints/hook-continuity-remake/specs/
# 14-guards-remake-spec.md sec 3.2. Architecture:
# plugins/butler/docs/hook-architecture.md ("guard-git-mutations" successor
# row).
#
# run($p, @args) never calls exit, never dies on purpose, never spawns a
# process (no system/exec/backtick/qx/pipe-open). Prints only through
# BpHook::deny(@lines). Never re-parses the payload (BpHook::parse_count()
# is unchanged by run()). Session facts come only from the core
# (BpHook::session_id/is_armed) -- no drive-solo/continuity/run-state/
# current.json file is read directly, no $CLAUDE_CODE_SESSION_ID is read
# (Decision 3). Fail direction: open (return 0) on any internal ambiguity.
package BpHook::Guards::GuardGitMutations;
use strict;
use warnings;
use File::Basename qw(dirname);
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

my $MASK_MAX = 8192;

# Odd-punctuation heredoc delimiter (line 294 of the source hook), and the
# "unquoted heredoc opener" check (source line 246). Both operate per-line
# (grep -E semantics), against the RAW command.
my $UNQUOTED_HD_OPENER_RE = qr/<<-?[ \t]*([^'"]|$)/;
my $ODD_HD_DELIM_RE = qr/<<-?[ \t]*([^A-Za-z0-9_'" \t]|'[A-Za-z0-9_]*[^A-Za-z0-9_']|"[A-Za-z0-9_]*[^A-Za-z0-9_"]|[A-Za-z0-9_]*[^A-Za-z0-9_'" \t])/;

my $SHELLWORD_WORD_RE = qr/
    (^|[;&|\s])(bash|sh|zsh|ksh|dash|eval|xargs)([\s]|$)
  | (^|[;&|\s])(perl|ruby|node)[\s]+-e([\s]|$)
  | (^|[;&|\s])(python|python3)[\s]+-c([\s]|$)
/x;

# ---------------------------------------------------------------------------
# _git_scan_target($cmd) -> ($scan, $raw_kind). Faithful port of
# git_scan_target() in plugins/butler/hooks/guard-git-mutations.sh (lines
# 97-453), operating on Perl characters instead of bash's byte string, with
# BpHook::Guards::Shell::strip_noise standing in for bp_strip_shell_noise.
# ---------------------------------------------------------------------------
sub _git_scan_target {
    my ($cmd) = @_;
    my $len = length($cmd);

    # 1. Over-long command: raw fallback without even walking it.
    if ($len > $MASK_MAX) {
        return ($cmd, 'toolong');
    }

    my $has_bs   = (index($cmd, "\\") >= 0) ? 1 : 0;
    my $has_hash = (index($cmd, '#') >= 0)  ? 1 : 0;
    my $has_hd   = (index($cmd, '<<') >= 0) ? 1 : 0;

    my $go_to_walk = 1;
    if ($has_bs) {
        if ($has_hash || $has_hd) {
            return ($cmd, 'escape');
        }
        (my $bs_probe = $cmd) =~ s/\\\n//g;
        if (index($bs_probe, "\\") >= 0) {
            return ($cmd, 'escape');
        }
        # every backslash is a line continuation -> fall through
    }
    elsif ($has_hash) {
        if (!$has_hd) {
            return ($cmd, 'escape');
        }
        if (BpHook::Guards::Common::line_match($UNQUOTED_HD_OPENER_RE, $cmd)) {
            return ($cmd, 'escape');
        }
        # falls through to the heredoc branch, carrying G2
    }

    if ($has_hd) {
        if (index($cmd, "\r") >= 0) {
            return ($cmd, 'escape');
        }
        if (BpHook::Guards::Common::line_match($ODD_HD_DELIM_RE, $cmd)) {
            return ($cmd, 'escape');
        }
        my $hd_stripped = BpHook::Guards::Shell::strip_noise($cmd);
        if (!defined $hd_stripped || !length $hd_stripped) {
            return ($cmd, 'escape');
        }
        if ($has_hash) {
            (my $hashed_cmd = $cmd) =~ s/#/q/g;
            my $hd_alt = BpHook::Guards::Shell::strip_noise($hashed_cmd);
            if (!defined $hd_alt || !length $hd_alt) {
                return ($cmd, 'escape');
            }
            (my $a = $hd_stripped) =~ s/[^ ]/x/g;
            (my $b = $hd_alt) =~ s/[^ ]/x/g;
            if ($a ne $b) {
                return ($cmd, 'escape');
            }
        }
        if (BpHook::Guards::Common::line_match(qr/\x60|\$\(/, $hd_stripped)) {
            return ($cmd, 'carrier');
        }
        if (BpHook::Guards::Common::line_match($SHELLWORD_WORD_RE, $hd_stripped)) {
            return ($cmd, 'shellword');
        }
        return ($hd_stripped, 'heredoc');
    }

    # 5. The three-state quote walk.
    my @chars = split //, $cmd, -1;
    my $n = scalar @chars;
    my $state = 'NONE'; # NONE | SINGLE | DOUBLE
    my $carrier = 0;
    my $out = '';
    my ($qbuf, $qhaswhite, $qadjacent) = ('', 0, 0);
    my $adj_re = qr/(^|[;&|\s({])git[\s]+$/;
    my $i = 0;
    while ($i < $n) {
        my $c = $chars[$i];
        if ($state eq 'NONE') {
            if ($c eq "'") {
                $state = 'SINGLE'; $qbuf = ''; $qhaswhite = 0;
                $qadjacent = ($out =~ $adj_re) ? 1 : 0;
            }
            elsif ($c eq '"') {
                $state = 'DOUBLE'; $qbuf = ''; $qhaswhite = 0;
                $qadjacent = ($out =~ $adj_re) ? 1 : 0;
            }
            elsif ($c eq "\x60") {
                $carrier = 1; $out .= "\x60";
            }
            elsif ($c eq '$') {
                my $next = ($i + 1 < $n) ? $chars[$i + 1] : '';
                $carrier = 1 if $next eq '(';
                $out .= '$';
            }
            else {
                $out .= $c;
            }
        }
        elsif ($state eq 'SINGLE') {
            if ($c eq "'") {
                $state = 'NONE';
                if ($qhaswhite == 0 && $qadjacent == 1) {
                    $out .= $qbuf;
                }
                else {
                    $out .= "'" . ($qbuf =~ s/./X/gr) . "'";
                }
            }
            elsif ($c eq ' ' || $c eq "\t" || $c eq "\n") {
                $qhaswhite = 1; $qbuf .= $c;
            }
            else {
                $qbuf .= $c;
            }
        }
        elsif ($state eq 'DOUBLE') {
            if ($c eq '"') {
                $state = 'NONE';
                if ($qhaswhite == 0 && $qadjacent == 1) {
                    $out .= $qbuf;
                }
                else {
                    $out .= '"' . ($qbuf =~ s/./X/gr) . '"';
                }
            }
            elsif ($c eq "\x60") {
                $carrier = 1; $qbuf .= $c;
            }
            elsif ($c eq '$') {
                my $next = ($i + 1 < $n) ? $chars[$i + 1] : '';
                $carrier = 1 if $next eq '(';
                $qbuf .= $c;
            }
            elsif ($c eq ' ' || $c eq "\t" || $c eq "\n") {
                $qhaswhite = 1; $qbuf .= $c;
            }
            else {
                $qbuf .= $c;
            }
        }
        $i++;
    }

    # 2. Unbalanced quoting.
    if ($state ne 'NONE') {
        return ($cmd, 'unbalanced');
    }
    # 3. An unquoted backtick or $( anywhere.
    if ($carrier) {
        return ($cmd, 'carrier');
    }
    # 4. shell/eval/xargs/perl|ruby|node -e/python -c in command position.
    (my $out_nc = $out) =~ s/\\\n//g;
    if (BpHook::Guards::Common::line_match($SHELLWORD_WORD_RE, $out_nc)) {
        return ($cmd, 'shellword');
    }

    return ($out, 'masked');
}

sub _anchor_for {
    my ($reason) = @_;
    return '(^|[;&|\s\'"\x60({])' if $reason eq 'shellword';
    return '(^|[;&|\s\x60({])'    if $reason eq 'carrier';
    return '(^|[;&|\s({])';
}

# ---------------------------------------------------------------------------
# run($p, @args) -> 0 | 2.
# ---------------------------------------------------------------------------
sub run {
    my ($p, @args) = @_;
    $p = {} unless ref $p eq 'HASH';
    return 0 unless BpHook::payload_ok();

    if (grep { $_ eq '--only-during-butler-run' } @args) {
        my $ledger = $ENV{BP_LEDGER};
        my $applies = (defined $ledger && length $ledger)
            || BpHook::is_armed(BpHook::session_id($p));
        return 0 unless $applies;
    }

    my $ti = $p->{tool_input};
    return 0 unless ref $ti eq 'HASH';
    my $cmd = $ti->{command};
    return 0 unless defined $cmd && !ref($cmd) && length $cmd;

    my ($scan, $raw_kind) = _git_scan_target($cmd);
    my $anchor = _anchor_for($raw_kind);
    my $cmd_line = 'Command: ' . BpHook::Guards::Common::echo_cmd($cmd);

    my $gitopt = BpHook::Guards::Common::git_opt_re();
    # redteam H2 ("git -C <dir>"/"git -c k=v" past the flags-only group) and
    # M3 (the list/show exemption checked against the whole scan instead of
    # the matched occurrence) both apply here, mirroring GuardBash's fix.
    my $stash_re = qr/${anchor}git[\s]+${gitopt}stash\b(?![\s]+(list|show)\b)/;
    my $mut_re   = qr/${anchor}git[\s]+${gitopt}(checkout|switch|restore|reset|clean)\b/;

    if (BpHook::Guards::Common::line_match($stash_re, $scan))
    {
        return BpHook::deny(
            BpHook::Guards::Common::fit(
                q{BLOCKED: git stash is forbidden: it silently removes uncommitted work; use 'git diff' to inspect ('git stash list/show' are allowed).}
            ),
            BpHook::Guards::Common::fit($cmd_line),
        );
    }

    if (BpHook::Guards::Common::line_match($mut_re, $scan)) {
        return BpHook::deny(
            BpHook::Guards::Common::fit(
                'BLOCKED: git checkout/switch/restore/reset/clean are forbidden: each can discard uncommitted work; change files only via Edit/Write.'
            ),
            BpHook::Guards::Common::fit($cmd_line),
        );
    }

    # Package 35 / Decision 117: a subagent payload (agent_id present) is
    # denied every git verb that mutates the index, refs or history, or
    # talks to a remote -- the driver's own verdicts (above) are unchanged
    # for everyone, including the driver, which never reaches this block.
    if (defined BpHook::agent_id($p)) {
        if (_subagent_git_index_mutation($scan, $anchor, $gitopt)) {
            return BpHook::deny(
                BpHook::Guards::Common::fit(
                    'BLOCKED: a subagent cannot change the git index, refs or history, or talk to a remote; the driver owns git.'
                ),
                BpHook::Guards::Common::fit($cmd_line),
            );
        }
    }

    return 0;
}

# ---------------------------------------------------------------------------
# _subagent_git_index_mutation($scan, $anchor, $gitopt) -> true iff some
# line of $scan invokes a Decision-117/118 mutating git verb. $scan is the
# already-masked command (quotes/heredoc/backtick-handled by
# _git_scan_target). Operates per-line, grep -E semantics, mirroring the
# rest of this module. Every occurrence on a line is inspected (package
# 35 fix-batch M1), not just the first, so a chained good-faith sequence
# such as "git apply --check p && git apply --index p" is still denied on
# its second invocation even though its first is read-only.
# ---------------------------------------------------------------------------
sub _subagent_git_index_mutation {
    my ($scan, $anchor, $gitopt) = @_;

    # Verbs denied unconditionally, in any form: straightforward
    # index/ref/history mutators with no read-only sense. The boundary is
    # (?![-\w]), not \b, so a hyphenated plumbing verb that never touches
    # the index/refs/history is not swept in: merge-file, merge-tree,
    # merge-base, commit-tree, commit-graph (fix-batch S1).
    my $bare_re = qr/${anchor}git[\s]+${gitopt}(add|rm|mv|commit|update-index|update-ref|read-tree|merge|rebase|cherry-pick|revert|am|push|pull|fetch|stage|bisect|gc|prune|repack|filter-branch|replace)(?![-\w])/;
    return 1 if BpHook::Guards::Common::line_match($bare_re, $scan);

    # Verbs whose own arguments decide the verdict (Decision 118). Every
    # occurrence on the line is walked (while (...) =~ /$re/g), not just
    # the leftmost -- fix-batch M1. $anchor carries its own capture group
    # (group 1), so each verb's "rest of the invocation" capture is group 2.
    my @qualified = (
        [qr/${anchor}git[\s]+${gitopt}apply(?![-\w])([^;&|)\n]*)/,         \&_apply_rest_is_mutating],
        [qr/${anchor}git[\s]+${gitopt}branch(?![-\w])([^;&|)\n]*)/,        \&_branch_rest_is_mutating],
        [qr/${anchor}git[\s]+${gitopt}tag(?![-\w])([^;&|)\n]*)/,           \&_tag_rest_is_mutating],
        [qr/${anchor}git[\s]+${gitopt}notes(?![-\w])([^;&|)\n]*)/,         \&_notes_rest_is_mutating],
        [qr/${anchor}git[\s]+${gitopt}worktree(?![-\w])([^;&|)\n]*)/,      \&_worktree_rest_is_mutating],
        [qr/${anchor}git[\s]+${gitopt}submodule(?![-\w])([^;&|)\n]*)/,     \&_submodule_rest_is_mutating],
        [qr/${anchor}git[\s]+${gitopt}remote(?![-\w])([^;&|)\n]*)/,        \&_remote_rest_is_mutating],
        [qr/${anchor}git[\s]+${gitopt}config(?![-\w])([^;&|)\n]*)/,        \&_config_rest_is_mutating],
        [qr/${anchor}git[\s]+${gitopt}symbolic-ref(?![-\w])([^;&|)\n]*)/,  \&_symbolic_ref_rest_is_mutating],
        [qr/${anchor}git[\s]+${gitopt}reflog(?![-\w])([^;&|)\n]*)/,        \&_reflog_rest_is_mutating],
    );
    for my $line (split /\n/, $scan) {
        for my $q (@qualified) {
            my ($re, $classifier) = @$q;
            while ($line =~ /$re/g) {
                my $rest = defined $2 ? $2 : '';
                return 1 if $classifier->($rest);
            }
        }
    }

    return 0;
}

# ---------------------------------------------------------------------------
# _strip_redirects($rest) -> $rest with shell redirection tokens (and their
# targets, whether attached or space-separated) removed, so a redirect is
# never mistaken for a positional argument (fix-batch M2 point 1). Order
# matters: the fd-duplication and &> forms are stripped before the plain
# ">"/">>" form, which would otherwise eat into them.
# ---------------------------------------------------------------------------
sub _strip_redirects {
    my ($rest) = @_;
    return '' unless defined $rest;
    $rest =~ s/\d*>&\d+//g;       # 2>&1, >&2 -- no filename target
    $rest =~ s/&>\s*\S*//g;       # &>file, &> file
    $rest =~ s/\d*>>?\s*\S*//g;   # >file, >>file, 2>/dev/null, > out.txt
    $rest =~ s/<\s*\S*//g;        # <file
    return $rest;
}

# ---------------------------------------------------------------------------
# Per-verb qualifier classifiers. Each takes the raw text following the
# verb (up to the next shell separator) and returns true iff that
# invocation mutates the index, refs, history or a remote per Decision 118.
# ---------------------------------------------------------------------------

sub _apply_rest_is_mutating {
    my ($rest) = @_;
    return 0 unless defined $rest && length $rest;
    return 1 if $rest =~ /(?:^|\s)(?:--cached|--index)(?:\s|=|$)/;
    return 1 if $rest =~ /(?:^|\s)(?:-3|--3way)(?:\s|$)/;
    return 0;
}

sub _branch_rest_is_mutating {
    my ($rest) = @_;
    $rest = _strip_redirects($rest);
    return 0 unless defined $rest && length $rest;

    my $mutating_re    = qr/^(?:-d|-D|--delete|-m|-M|--move|-c|-C|--copy|-f|--force|-u|--set-upstream-to(?:=.*)?|--unset-upstream|--edit-description|-t|--track|--no-track|--create-reflog)$/;
    my $list_flag_re   = qr/^(?:-a|--all|-r|--remotes|-l|--list|-v|-vv|--verbose|--show-current)$/;
    my $list_eq_re     = qr/^(?:--sort=.*|--format=.*)$/;
    my $ref_arg_flag_re = qr/^(?:--contains|--no-contains|--merged|--no-merged|--points-at)$/; # takes a ref argument

    my @tokens = grep { length } split /\s+/, $rest;
    my $list_mode = 0;
    while (@tokens) {
        my $tok = shift @tokens;
        return 1 if $tok =~ $mutating_re;
        if ($tok =~ $list_flag_re || $tok =~ $list_eq_re) {
            $list_mode = 1;
            next;
        }
        if ($tok =~ $ref_arg_flag_re) {
            $list_mode = 1;
            shift @tokens if @tokens && $tokens[0] !~ /^-/;
            next;
        }
        if ($tok =~ /^-/) {
            # An unrecognised flag: fail open on the flag itself (fix-batch
            # M2 point 3) -- but it does not, by itself, license a
            # positional branch-name argument that follows.
            next;
        }
        # A positional token: a glob pattern once a listing flag has put us
        # in list mode (e.g. "branch --list 'feat*'"), otherwise a branch
        # name to create/rename onto.
        return 1 unless $list_mode;
    }
    return 0;
}

sub _tag_rest_is_mutating {
    my ($rest) = @_;
    my @tokens = grep { length } split /\s+/, (defined $rest ? $rest : '');
    return 0 unless @tokens; # bare "git tag" -- listing form, allow
    return 0 if $tokens[0] =~ /^(?:-l|--list)$/;
    return 1;
}

sub _notes_rest_is_mutating {
    my ($rest) = @_;
    my @tokens = grep { length } split /\s+/, (defined $rest ? $rest : '');
    return 1 unless @tokens; # no subcommand -- not one of the two allowed forms
    return 0 if $tokens[0] =~ /^(?:list|show)$/;
    return 1;
}

sub _worktree_rest_is_mutating {
    my ($rest) = @_;
    my @tokens = grep { length } split /\s+/, (defined $rest ? $rest : '');
    return 0 unless @tokens; # bare "git worktree" lists worktrees
    return 0 if $tokens[0] eq 'list';
    return 1;
}

sub _submodule_rest_is_mutating {
    my ($rest) = @_;
    my @tokens = grep { length } split /\s+/, (defined $rest ? $rest : '');
    return 0 unless @tokens; # bare "git submodule" -- status-like listing
    return 0 if $tokens[0] eq 'status';
    return 1;
}

sub _remote_rest_is_mutating {
    my ($rest) = @_;
    my @tokens = grep { length } split /\s+/, (defined $rest ? $rest : '');
    return 0 unless @tokens; # bare "git remote" -- allow
    my $i = 0;
    $i++ if $tokens[0] eq '-v'; # "git remote -v" stays a listing form
    return 0 unless exists $tokens[$i]; # nothing after -v -- allow
    return 0 if $tokens[$i] =~ /^(?:show|get-url)$/;
    return 1;
}

sub _config_rest_is_mutating {
    my ($rest) = @_;
    my @tokens = grep { length } split /\s+/, (defined $rest ? $rest : '');
    return 0 unless @tokens; # bare "git config" -- allow (not a write)
    my $deny_flag_re = qr/^(?:--unset(?:-all)?|--add|--replace-all|--rename-section|--remove-section|-e|--edit)$/;
    my $positional_count = 0;
    for my $tok (@tokens) {
        return 1 if $tok =~ $deny_flag_re;
        $positional_count++ unless $tok =~ /^-/;
    }
    return 1 if $positional_count >= 2; # "config <key> <value>" write form
    return 0;
}

sub _symbolic_ref_rest_is_mutating {
    my ($rest) = @_;
    my @tokens = grep { length } split /\s+/, (defined $rest ? $rest : '');
    return 0 unless @tokens; # bare invocation -- read attempt, allow
    my $positional_count = 0;
    for my $tok (@tokens) {
        return 1 if $tok =~ /^(?:-d|--delete)$/;
        $positional_count++ unless $tok =~ /^-/;
    }
    return 1 if $positional_count >= 2; # a write (ref + new target)
    return 0;
}

sub _reflog_rest_is_mutating {
    my ($rest) = @_;
    my @tokens = grep { length } split /\s+/, (defined $rest ? $rest : '');
    return 0 unless @tokens; # bare "git reflog" -- allow
    return 0 if $tokens[0] eq 'show';
    return 1;
}

1;
