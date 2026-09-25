# BpHook::Guards::WaitShapeGuard -- PreToolUse wait/poll pathology guard
# (package 14 of blueprint hook-continuity-remake), successor to the old
# separate wait-shape and repeat-detector guards, now merged into
# hooks/wait-shape-guard.sh.
#
# Contract: .ccpraxis-local-data/blueprints/hook-continuity-remake/specs/
# 14-guards-remake-spec.md sec 3.7 (this successor's own contract), sec 2.3
# (Common::fit/echo_cmd/line_match) and sec 2.6 (message conventions).
# Architecture: plugins/butler/docs/hook-architecture.md
# ("wait-shape-guard" successor row).
#
# run($p, @args) never calls exit, never dies on purpose, never spawns a
# process (no system/exec/backtick/qx/pipe-open). Prints only through
# BpHook::deny(@lines) (budget: 2 lines). Every infrastructure failure
# (unreadable/non-regular state path, bad payload, unparseable numbers,
# failed write) allows -- never a deny.
package BpHook::Guards::WaitShapeGuard;
use strict;
use warnings;
use JSON::PP ();
use Digest::SHA ();
use File::Basename qw(dirname);
use B qw(svref_2object SVp_POK);
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

my $DASH = chr(0x2014);
my $PFX  = "WAIT-SHAPE-GUARD: BLOCKED $DASH ";

my $LOOP_RE    = qr/(^|[^A-Za-z0-9_-])(while|until|for)[[:space:]]/;
my $SLEEP_RE   = qr/(^|[^A-Za-z0-9_-])sleep[[:space:]]+[0-9]/;
my $PIPE_RE    = qr/\|[[:space:]]*(tail|head)([[:space:]][^;&|]*)?[;&]+[^;&|]*\$\?/;
my $TASKOUT_RE = qr/tasks\/[A-Za-z0-9_-]+\.output/;

# ---------------------------------------------------------------------------
# small local helpers.
# ---------------------------------------------------------------------------
sub _is_plain_string {
    my ($v) = @_;
    return 0 unless defined $v;
    return 0 if ref $v;
    my $flags = svref_2object(\$v)->FLAGS;
    return ($flags & SVp_POK()) ? 1 : 0;
}

sub _token {
    my ($raw) = @_;
    $raw = '' unless defined $raw && !ref($raw);
    (my $t = $raw) =~ s/[^A-Za-z0-9_-]/_/g;
    $t = substr($t, 0, 16);
    return length($t) ? $t : 'nosid';
}

sub _config_int {
    my ($raw, $default, $min) = @_;
    return $default unless defined $raw && !ref($raw) && $raw =~ /^[0-9]+$/;
    return ($raw >= $min) ? ($raw + 0) : $default;
}

sub _read_bytes {
    my ($path) = @_;
    open(my $fh, '<:raw', $path) or return undef;
    local $/;
    my $c = <$fh>;
    close $fh;
    return $c;
}

sub _write_bytes_atomic {
    my ($path, $bytes) = @_;
    my $dir = $path;
    $dir =~ s{/[^/]*\z}{};
    unless (-d $dir) { eval { require File::Path; File::Path::make_path($dir) } }
    return 0 unless -d $dir;
    my $tmp = "$path.tmp.$$";
    open(my $fh, '>:raw', $tmp) or return 0;
    my $ok = print {$fh} $bytes;
    $ok &&= close($fh);
    unless ($ok) { unlink $tmp; return 0 }
    return 1 if rename($tmp, $path);
    unlink $tmp;
    return 0;
}

# ---------------------------------------------------------------------------
# echo_cmd wrapper (spec 2.3, defined in Common.pm already).
# ---------------------------------------------------------------------------
sub _echo_cmd { return BpHook::Guards::Common::echo_cmd($_[0]) }

# ===========================================================================
# Repeat detector.
# ===========================================================================

# _repeat_action_of(RAW) -> nudge | deny | off.
sub _repeat_action_of {
    my ($raw) = @_;
    $raw = '' unless defined $raw;
    return 'nudge' if $raw eq '' || $raw eq 'nudge';
    return 'deny'  if $raw eq 'deny';
    return 'off';
}

# _scrub($v) -- pure recursive whitespace-collapse/truncate of every string
# reachable inside $v (spec 3.7's canonical-JSON hash input), mirroring
# bp_repeat_hash's jq "scrub" walk. Non-string scalars (numbers, booleans,
# undef) pass through unchanged.
sub _scrub {
    my ($v) = @_;
    if (ref $v eq 'HASH') {
        my %h;
        $h{$_} = _scrub($v->{$_}) for keys %$v;
        return \%h;
    }
    if (ref $v eq 'ARRAY') {
        return [ map { _scrub($_) } @$v ];
    }
    return $v unless _is_plain_string($v);
    my $s = $v;
    my $len = length($s);
    if ($len > 2048) {
        my $head = substr($s, 0, 2048);
        $head =~ s/\s+/ /g;
        return $head . '#' . $len;
    }
    $s =~ s/\s+/ /g;
    $s =~ s/^ //;
    $s =~ s/ $//;
    return $s;
}

sub _repeat_hash {
    my ($tool_name, $tool_input) = @_;
    my $ti = (ref $tool_input eq 'HASH') ? $tool_input : {};
    my $scrubbed = eval { _scrub([$tool_name, $ti]) };
    return undef unless defined $scrubbed;
    my $json = eval { JSON::PP->new->canonical->utf8->encode($scrubbed) };
    return undef unless defined $json;
    my $hex = eval { Digest::SHA::sha1_hex($json) };
    return $hex;
}

# _repeat_runlen(HASH, NOW, WINSECS, \@lines) -> (RUNLEN, FIRED). @lines are
# TS\tHASH\tFIRED strings, oldest first (file order).
sub _repeat_runlen {
    my ($hash, $now, $winsecs, $lines) = @_;
    my $runlen = 1;
    my $fired = 0;
    my $prevts = $now;
    for my $line (reverse @$lines) {
        next unless defined $line && $line =~ /^([0-9]+)\t([^\t]+)\t([01])$/;
        my ($ts, $h, $f) = ($1, $2, $3);
        last unless $h eq $hash;
        if ($winsecs > 0) {
            last if ($prevts - $ts) > $winsecs;
        }
        $runlen++;
        $fired = 1 if $f eq '1';
        $prevts = $ts;
    }
    return ($runlen, $fired);
}

sub _repeat_verdict {
    my ($runlen, $fired, $thresh, $action) = @_;
    return 'pass' if $action eq 'off';
    if ($action eq 'deny') {
        return ($runlen >= $thresh) ? 'fire' : 'pass';
    }
    if ($action eq 'nudge') {
        return 'pass' unless $runlen >= $thresh;
        return ($fired == 1) ? 'pass' : 'fire';
    }
    return 'pass';
}

sub _msg_repeat {
    my ($runlen, $tool, $mode) = @_;
    my $l2 = ($mode eq 'nudge')
        ? "This fires once per run: change approach, inspect the output you have, or record the blocker under '## Next action' and stop."
        : "Every further identical call is blocked: change approach, inspect the output you have, or record the blocker under '## Next action' and stop.";
    return (
        "REPEAT-GUARD: identical call #$runlen in a row to $tool (arguments hashed identically); a retry is unlikely to give a different result.",
        $l2,
    );
}

# _run_repeat_detector($p, $tool, $ti) -> 1 (fired, caller must deny+return),
# 0 (did not fire, caller continues to wait-shape rules). Never dies.
sub _run_repeat_detector {
    my ($p, $tool, $ti) = @_;
    my $bp_dir = $ENV{BP_DIR};
    return (0, undef) unless defined $bp_dir && length $bp_dir;
    return (0, undef) unless defined $tool && length $tool;

    my $exempt_re = $ENV{BP_REPEAT_EXEMPT_TOOLS};
    $exempt_re = '^(BashOutput|KillShell|Monitor|TaskGet|TaskList|TaskOutput)$'
        unless defined $exempt_re && length $exempt_re;
    my $exempt = eval { $tool =~ /$exempt_re/ ? 1 : 0 };
    $exempt = 0 unless defined $exempt;
    return (0, undef) if $exempt;

    my $action = _repeat_action_of($ENV{BP_REPEAT_ACTION});
    return (0, undef) if $action eq 'off';

    my $hash = _repeat_hash($tool, $ti);
    return (0, undef) unless defined $hash && length $hash;

    my $sid = $p->{session_id};
    $sid = undef unless defined $sid && !ref($sid);
    # redteam M5: subagents share their parent's session_id, so keying on
    # session_id alone folds every sibling's calls into one shared run
    # counter. Fold agent_id into the token too (main for the driver/
    # coordinator's own calls) so each caller gets its own run.
    my $aid = $p->{agent_id};
    $aid = undef unless defined $aid && !ref($aid) && length($aid) && $aid ne '?';
    my $token = _token($sid) . '-' . _token(defined $aid ? $aid : 'main');

    (my $bpdir_fs = $bp_dir) =~ tr{\\}{/};
    $bpdir_fs =~ s{/+\z}{};
    my $pkg = $ENV{BP_PACKAGE};
    $pkg = 'pkg' unless defined $pkg && length $pkg;
    my $file = "$bpdir_fs/runs/$pkg.repeat-$token.log";

    if (-e $file && !-f $file) { return (0, undef) }

    my $thresh = _config_int($ENV{BP_REPEAT_THRESHOLD}, 4, 2);
    my $win    = _config_int($ENV{BP_REPEAT_WINDOW}, 64, 1);
    my $secs   = _config_int($ENV{BP_REPEAT_WINDOW_SECONDS}, 300, 0);
    my $now = time();

    my @oldlines;
    if (-f $file) {
        my $raw = _read_bytes($file);
        if (defined $raw) {
            @oldlines = grep { /^[0-9]+\t[^\t]+\t[01]$/ } split /\n/, $raw;
        }
    }

    my ($runlen, $fired) = _repeat_runlen($hash, $now, $secs, \@oldlines);
    my $verdict = _repeat_verdict($runlen, $fired, $thresh, $action);

    my $newfired = ($fired == 1 || $verdict eq 'fire') ? 1 : 0;
    push @oldlines, "$now\t$hash\t$newfired";

    my $retain = ($thresh > $win) ? $thresh : $win;
    my $total = scalar @oldlines;
    my $start = ($total > $retain) ? ($total - $retain) : 0;
    my @keep = @oldlines[$start .. $total - 1];
    my $ok = _write_bytes_atomic($file, join("\n", @keep) . "\n");
    return (0, undef) unless $ok;

    return (0, undef) unless $verdict eq 'fire';
    return (1, [ $runlen, $tool, ($action eq 'deny' ? 'deny' : 'nudge') ]);
}

# ===========================================================================
# Wait-shape rules.
# ===========================================================================

sub _match_text_for_bash {
    my ($cmd) = @_;
    my $max = $ENV{BP_GUARD_MAX_STRIP_BYTES};
    $max = (defined $max && $max =~ /^[0-9]+$/) ? $max + 0 : 8000;
    if (length($cmd) <= $max) {
        my $stripped = eval { BpHook::Guards::Shell::strip_noise($cmd) };
        return $stripped if defined $stripped && length $stripped;
    }
    return $cmd;
}

sub _msg_r1 {
    my ($cmd) = @_;
    return (
        $PFX . "wait-loop: a while/until/for loop with sleep polls; run the work in the FOREGROUND or await the notification.",
        "Or record what you wait for under '## Next action' and stop. Command: " . _echo_cmd($cmd),
    );
}
sub _msg_r3b {
    my ($cmd) = @_;
    return (
        $PFX . "task-output-poll: sleeping while probing tasks/<id>.output reads a subagent's full stream; wait for its report file instead.",
        "Or record what you wait for under '## Next action' and stop. Command: " . _echo_cmd($cmd),
    );
}
sub _msg_r2 {
    my ($cmd) = @_;
    return (
        $PFX . 'false-green-pipe: $? after | tail/head is tail\'s status, not the command\'s; use cmd > /tmp/out.txt 2>&1; echo "exit=$?"',
        'or out=$(cmd 2>&1); rc=$?. Command: ' . _echo_cmd($cmd),
    );
}
sub _msg_taskpoll {
    my ($count, $idt, $win) = @_;
    return (
        $PFX . "task-output-poll: TaskOutput call #$count against task $idt within $win seconds; this is polling one target.",
        "Stop polling: wait for its report file, or record what you wait for under '## Next action' and stop.",
    );
}

sub _run_bash_rules {
    my ($ti) = @_;
    my $cmd = (ref $ti eq 'HASH' && defined $ti->{command} && !ref($ti->{command})) ? $ti->{command} : undef;
    return 0 unless defined $cmd && length $cmd;

    my $match_text = _match_text_for_bash($cmd);

    # R1 (wait-loop): when a shell or eval sits in command position it
    # re-interprets its own quoted argument, so R1 must match against the
    # RAW command in that case -- otherwise a real while/until/for + sleep
    # hidden inside a `bash -c '...'` single-quoted string is invisible to
    # the quote-stripped match_text (Common::strip_noise blanks quoted
    # content). This mirrors GuardBash's own shellword/RAW fallback (spec
    # sec 3.1), via the shared Common::is_shell_or_eval_invocation helper.
    my $r1_text = BpHook::Guards::Common::is_shell_or_eval_invocation($cmd)
        ? $cmd
        : $match_text;

    if (BpHook::Guards::Common::line_match($LOOP_RE, $r1_text)
        && BpHook::Guards::Common::line_match($SLEEP_RE, $r1_text))
    {
        return BpHook::deny(_msg_r1($cmd));
    }
    if (BpHook::Guards::Common::line_match($TASKOUT_RE, $match_text)
        && BpHook::Guards::Common::line_match($SLEEP_RE, $match_text))
    {
        return BpHook::deny(_msg_r3b($cmd));
    }
    # R2 (false-green pipe): $? is live shell expansion even inside double
    # quotes ("echo \"EXIT=$?\"" still expands at runtime), so R2 must match
    # PIPE_RE against the RAW command, never the quote-stripped match_text
    # (which blanks the literal "$?" text sitting inside those quotes).
    # Newlines are flattened to ';' so a pipe-then-tail on one line and the
    # later "$?" read on the next still join into one PIPE_RE match.
    (my $flat_raw = $cmd) =~ tr/\n\r/;;/;
    if (BpHook::Guards::Common::line_match($PIPE_RE, $flat_raw)) {
        return BpHook::deny(_msg_r2($cmd));
    }
    return 0;
}

sub _run_taskoutput_rules {
    my ($p, $ti) = @_;
    my $bp_dir = $ENV{BP_DIR};
    return 0 unless defined $bp_dir && length $bp_dir;

    my $id;
    for my $k (qw(task_id taskId id)) {
        if (ref $ti eq 'HASH' && defined $ti->{$k} && !ref($ti->{$k}) && length($ti->{$k})) {
            $id = $ti->{$k};
            last;
        }
    }
    return 0 unless defined $id;

    my $idt = _token($id);
    my $sid = $p->{session_id};
    $sid = undef unless defined $sid && !ref($sid);
    my $token = _token($sid);

    (my $bpdir_fs = $bp_dir) =~ tr{\\}{/};
    $bpdir_fs =~ s{/+\z}{};
    my $pkg = $ENV{BP_PACKAGE};
    $pkg = 'pkg' unless defined $pkg && length $pkg;
    my $file = "$bpdir_fs/runs/$pkg.taskpoll-$token.log";

    if (-e $file && !-f $file) { return 0 }

    my $thresh = _config_int($ENV{BP_WAITSHAPE_TASKPOLL_THRESHOLD}, 6, 2);
    my $win    = _config_int($ENV{BP_WAITSHAPE_TASKPOLL_WINDOW_SECONDS}, 600, 0);
    my $now = time();

    my @oldlines;
    if (-f $file) {
        my $raw = _read_bytes($file);
        if (defined $raw) {
            @oldlines = grep { /^[0-9]+\t[^\t]+$/ } split /\n/, $raw;
        }
    }

    my $count = 1;
    for my $line (@oldlines) {
        next unless $line =~ /^([0-9]+)\t([^\t]+)$/;
        my ($ts, $tok) = ($1, $2);
        next unless $tok eq $idt;
        if ($win > 0) {
            next unless ($now - $ts) <= $win;
        }
        $count++;
    }

    push @oldlines, "$now\t$idt";
    my $retain = 256;
    my $total = scalar @oldlines;
    my $start = ($total > $retain) ? ($total - $retain) : 0;
    my @keep = @oldlines[$start .. $total - 1];
    my $ok = _write_bytes_atomic($file, join("\n", @keep) . "\n");
    return 0 unless $ok;

    return 0 unless $count >= $thresh;
    return BpHook::deny(_msg_taskpoll($count, $idt, $win));
}

# ---------------------------------------------------------------------------
# run($p, @args) -> 0 | 2.
# ---------------------------------------------------------------------------
sub run {
    my ($p, @args) = @_;
    $p = {} unless ref $p eq 'HASH';

    my $tool = $p->{tool_name};
    $tool = undef unless defined $tool && !ref($tool);

    my $ti = (ref $p->{tool_input} eq 'HASH') ? $p->{tool_input} : {};

    my ($fired, $info) = eval { _run_repeat_detector($p, $tool, $ti) };
    if ($fired) {
        my ($runlen, $ttool, $mode) = @$info;
        return BpHook::deny(_msg_repeat($runlen, $ttool, $mode));
    }

    my $ws_action = $ENV{BP_WAITSHAPE_ACTION};
    return 0 if defined $ws_action && $ws_action eq 'off';

    return 0 unless defined $tool;

    if ($tool eq 'Bash') {
        return eval { _run_bash_rules($ti) } // 0;
    }
    if ($tool eq 'TaskOutput') {
        return eval { _run_taskoutput_rules($p, $ti) } // 0;
    }
    return 0;
}

1;
