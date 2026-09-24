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

    return 0;
}

1;
