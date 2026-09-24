#!/usr/bin/env perl
# butler-hold.pl -- the one continuity holder (package 05 of blueprint
# hook-continuity-remake).
#
#   butler-hold [--token <8hex>] <item> [<item> ...]
#
# Contract: .ccpraxis-local-data/blueprints/hook-continuity-remake/specs/
# 05-holder-spec.md. Architecture: docs/hook-architecture.md ("Holder
# protocol", "BpHook core API", "Command binding").
#
# One command, one or more work items, a fixed 50-minute deadline, no
# duration argument of any kind. The process that becomes the holder never
# spawns a child of its own: it is the background task's own process for as
# long as it runs, so its own pid is what a live check ever needs to see
# (bug 20260922-211901-2cad). Re-invocation while a holder is alive merges
# items and pushes the deadline forward under a lock, then exits at once
# (bug 20260922-213451-6382, stacked holders).
#
# NO SESSION SELECTOR. This command never reads the caller's environment for
# a session identity; it learns its session only from a hook-written ticket
# (BpHook::take_ticket) or, when a Stop denial minted one, a one-shot token
# passed with --token. Additive only (Decision 19): nothing else changes.
use strict;
use warnings;
use FindBin qw($Bin);
use JSON::PP ();
use Digest::SHA qw(sha1_hex);
use Fcntl qw(:flock);
use File::Basename qw(dirname);
use Time::HiRes qw(sleep time);

# Signals and the top-level eval are installed before any other work (spec
# 2.8, review M1, red-team M4): a die anywhere below, including a failed
# require of BpHook.pm, prints one stdout line and exits nonzero, and a
# TERM/INT/HUP before the loop is not the default action.
our $SIGNALLED = 0;
$SIG{TERM} = sub { $SIGNALLED = 1 };
$SIG{INT}  = sub { $SIGNALLED = 1 };
$SIG{HUP}  = sub { $SIGNALLED = 1 };

# The require, and everything that can die, happens inside main() (below),
# which runs under the top-level eval at the bottom of this file.

use constant HOLD_DEFAULT => 3000;
use constant TICK_DEFAULT => 30;
use constant TAIL_BYTES   => 8 * 1024 * 1024;

my $ITEM_RE = qr/\A[A-Za-z0-9_-]{1,64}\z/;

# ---------------------------------------------------------------------------
# small helpers
# ---------------------------------------------------------------------------

sub out_line {
    my ($line) = @_;
    print STDOUT $line . "\n";
    return;
}

sub refuse {
    my ($msg) = @_;
    out_line("butler-hold: $msg");
    exit 1;
}

sub sid8_of { return substr($_[0], 0, 8) }

sub to_bytes_path {
    my ($s) = @_;
    return undef unless defined $s;
    my $v = "$s";
    if (utf8::is_utf8($v)) { utf8::encode($v) }
    $v =~ s{\\}{/}g;
    return $v;
}

sub hhmm_of {
    my ($epoch) = @_;
    my @t = gmtime($epoch);
    return sprintf('%02d:%02dZ', $t[2], $t[1]);
}

sub iso_of {
    my ($epoch) = @_;
    my @t = gmtime($epoch);
    return sprintf('%04d-%02d-%02dT%02d:%02d:%02dZ', $t[5] + 1900, $t[4] + 1, $t[3], $t[2], $t[1], $t[0]);
}

sub read_bytes_file {
    my ($p) = @_;
    return undef unless defined $p;
    open(my $fh, '<:raw', $p) or return undef;
    local $/;
    my $c = <$fh>;
    close $fh;
    return $c;
}

sub read_json_file {
    my ($p) = @_;
    my $raw = read_bytes_file($p);
    return undef unless defined $raw;
    return eval { JSON::PP->new->utf8->decode($raw) };
}

# ------------------------------------------------------------- test seam ----

sub _is_abs_path {
    my ($p) = @_;
    return 0 unless defined $p && length $p;
    return 1 if $p =~ m{^/};
    return 1 if $p =~ m{^[A-Za-z]:[\\/]};
    return 0;
}

sub _test_mode_enabled {
    my $m = $ENV{BUTLER_HOLD_TEST_MODE};
    return 0 unless defined $m && $m eq '1';
    return 0 unless _is_abs_path($ENV{BUTLER_STATE_DIR});
    return 1;
}

sub hold_seconds {
    return HOLD_DEFAULT unless _test_mode_enabled();
    my $v = $ENV{BUTLER_HOLD_TEST_SECONDS};
    return HOLD_DEFAULT unless defined $v && $v =~ /^[0-9]+$/;
    return HOLD_DEFAULT if $v < 1 || $v > 3000;
    return $v + 0;
}

sub tick_seconds {
    return TICK_DEFAULT unless _test_mode_enabled();
    my $v = $ENV{BUTLER_HOLD_TEST_TICK};
    return TICK_DEFAULT unless defined $v && $v =~ /^[0-9]+(?:\.[0-9]+)?$/;
    return TICK_DEFAULT if $v < 0.01 || $v > 30;
    return $v + 0;
}

# --------------------------------------------------------- record writing ---

my $LAST_WRITE_ERR;

sub write_record_atomic {
    my ($path, $data) = @_;
    my $dir = $path;
    $dir =~ s{/[^/]*$}{};
    my $json = eval { JSON::PP->new->utf8->canonical->encode($data) };
    unless (defined $json) { $LAST_WRITE_ERR = 'encode failed'; return 0 }
    for my $attempt (1 .. 5) {
        my $tmp = "$dir/.holdtmp.$$." . $attempt;
        if (open(my $fh, '>:raw', $tmp)) {
            print {$fh} $json;
            my $closed = close($fh);
            if ($closed && rename($tmp, $path)) { return 1 }
            $LAST_WRITE_ERR = "$!";
            unlink $tmp;
        }
        else {
            $LAST_WRITE_ERR = "$!";
        }
        sleep(0.02) if $attempt < 5;
    }
    return 0;
}

# --------------------------------------------------------------- pid/fp -----

sub compute_fp {
    my $c = read_bytes_file("/proc/$$/cmdline");
    return (defined $c && length $c) ? sha1_hex($c) : '';
}

sub proc_alive {
    my ($pid, $fp) = @_;
    return 0 unless defined $pid && "$pid" =~ /^[1-9][0-9]{0,9}$/;
    if (defined $fp && length $fp && -r '/proc/self/cmdline') {
        my $cmdline = read_bytes_file("/proc/$pid/cmdline");
        return 0 unless defined $cmdline && length $cmdline;
        return sha1_hex($cmdline) eq $fp ? 1 : 0;
    }
    return kill(0, $pid) ? 1 : 0;
}

sub resolve_self_task_id {
    # Red-team H1: a holder must never be able to hold its own background
    # task, which would silence the gate for as long as it re-invokes
    # itself. This process's own background-task id, if any, is the
    # basename of its own stdout redirect target -- resolved the same way
    # the spec resolves any other item's output file (2.7).
    my $link = readlink("/proc/$$/fd/1");
    return undef unless defined $link && length $link;
    $link =~ s{\\}{/}g;
    return undef unless $link =~ m{([^/]+)\.output$};
    return $1;
}

sub rand_token {
    my $bytes;
    if (open(my $fh, '<:raw', '/dev/urandom')) {
        read($fh, $bytes, 8);
        close $fh;
    }
    if (defined $bytes && length($bytes) == 8) {
        return lc(unpack('H*', $bytes));
    }
    return substr(sha1_hex(time() . $$ . rand()), 0, 16);
}

# ------------------------------------------------------------- evidence -----

sub read_tail {
    my ($path) = @_;
    return undef unless defined $path && length $path;
    my $p = to_bytes_path($path);
    return undef unless -f $p;
    open(my $fh, '<:raw', $p) or return undef;
    my $size = -s $fh;
    if (defined $size && $size > TAIL_BYTES) {
        seek($fh, $size - TAIL_BYTES, 0);
    }
    local $/;
    my $data = <$fh>;
    close $fh;
    return $data;
}

sub finished_status_in_tail {
    my ($tail, $id) = @_;
    return undef unless defined $tail && length $tail;
    my $open_tag = "<task-id>$id</task-id>";
    my $last;
    for my $line (split /\n/, $tail) {
        my $pos = index($line, $open_tag);
        next if $pos < 0;
        my $window_end = $pos + length($open_tag) + 2000;
        $window_end = length($line) if $window_end > length($line);
        my $window = substr($line, $pos, $window_end - $pos);
        if ($window =~ /<status>([^<]*)<\/status>/) {
            $last = $1;
        }
    }
    return $last;
}

sub resolve_output_path_in_tail {
    # A linear index()-based scan (red-team H2 / review m3): the previous
    # lazy regex backtracked from every '/' in the tail, which cost minutes
    # to hours on a tail with a long slash-heavy run (base64 image data).
    # This walks forward with index(), then bounds each candidate's
    # backward extraction by the nearest quote/angle-bracket/whitespace, so
    # the whole scan is O(length of tail) with no backtracking.
    my ($tail, $id) = @_;
    return undef unless defined $tail && length $tail;
    my $marker = "$id.output";
    my $mlen   = length $marker;
    my $tlen   = length $tail;
    my $found;
    my $pos = 0;
    while (1) {
        my $idx = index($tail, $marker, $pos);
        last if $idx < 0;
        $pos = $idx + 1;
        next if $idx == 0;
        my $anchor = substr($tail, $idx - 1, 1);
        next unless $anchor eq '/' || $anchor eq '\\';
        my $left = $idx - 1;
        while ($left > 0) {
            my $c = substr($tail, $left - 1, 1);
            last if $c eq '"' || $c eq '<' || $c eq '>' || $c =~ /\s/;
            $left--;
        }
        my $cand = substr($tail, $left, $idx + $mlen - $left);
        next unless $cand =~ m{^(?:[A-Za-z]:|/)};
        $found = $cand;    # keep the last hit, as the old scan did
    }
    return undef unless defined $found;
    $found =~ s/\\\\/\\/g;
    $found =~ s/\\/\//g;
    return undef unless -e $found;
    # Decode once (review M2): the tail was read ':raw', so a non-ASCII
    # path here is still raw UTF-8 bytes. Mark it as characters now, so the
    # canonical JSON encoder (utf8 mode) emits it once, not twice.
    utf8::decode($found);
    return $found;
}

# item_status($record, $id, $tail) -> {status=>'finished'|'running'|'unknown', mtime=>epoch?}
sub item_status {
    my ($record, $id, $tail) = @_;
    $tail = read_tail($record->{transcript_path}) unless defined $tail;

    if (defined $tail) {
        my $st = finished_status_in_tail($tail, $id);
        if (defined $st && $st ne 'running') {
            return { status => 'finished' };
        }
    }

    my $tp  = $record->{transcript_path};
    my $sid = $record->{session_id};
    my @candidates;
    if (defined $tp && length $tp) {
        (my $tpn = $tp) =~ s{\\}{/}g;
        my $sdir = dirname($tpn) . "/$sid";
        push @candidates, "$sdir/subagents/agent-$id.jsonl";
        push @candidates, "$sdir/subagents/agent-$id.meta.json";
    }
    my $outputs = (ref $record->{outputs} eq 'HASH') ? $record->{outputs} : {};
    push @candidates, $outputs->{$id} if defined $outputs->{$id};

    for my $c (@candidates) {
        next unless defined $c;
        my $cb = to_bytes_path($c);
        if (defined $cb && -e $cb) {
            my $mt = (stat($cb))[9];
            return { status => 'running', mtime => $mt } if defined $mt;
        }
    }

    my $found_now = defined $tail ? resolve_output_path_in_tail($tail, $id) : undef;
    if (defined $found_now) {
        my $cb = to_bytes_path($found_now);
        if (defined $cb && -e $cb) {
            my $mt = (stat($cb))[9];
            return { status => 'running', mtime => $mt } if defined $mt;
        }
    }

    return { status => 'unknown' };
}

sub all_finished {
    my ($record) = @_;
    my $items = (ref $record->{items} eq 'ARRAY') ? $record->{items} : [];
    return 0 unless @$items;
    my $tail = read_tail($record->{transcript_path});
    for my $id (@$items) {
        my $st = item_status($record, $id, $tail);
        return 0 unless $st->{status} eq 'finished';
    }
    return 1;
}

sub resolved_outputs_for {
    my ($tail, @ids) = @_;
    my %out;
    return \%out unless defined $tail;
    for my $id (@ids) {
        my $op = resolve_output_path_in_tail($tail, $id);
        $out{$id} = $op if defined $op;
    }
    return \%out;
}

# ---------------------------------------------------------------------------
# main -- everything below runs inside the top-level eval at the end of
# this file (spec 2.8, review M1). A die anywhere in here, including a
# failed require of BpHook.pm, is caught there; `exit` is not eval-caught
# and keeps every existing exit code below exactly as it is.
# ---------------------------------------------------------------------------

sub main {

require "$Bin/BpHook.pm"
    unless grep { m{(?:^|/)BpHook\.pm$} } keys %INC;

$| = 1;
binmode(STDOUT, ':raw');
$SIG{__WARN__} = sub { };

# ---------------------------------------------------------------------------
# argv parsing (by hand -- no option-parsing module of any kind)
# ---------------------------------------------------------------------------

my @ARGV_RAW = @ARGV;

my ($token_val, $token_seen) = (undef, 0);
my @item_words;
{
    my @a = @ARGV;
    while (@a) {
        my $w = shift @a;
        if ($w eq '--token') {
            refuse('takes ids only, plus --token from a stop message; the hold is always 50 minutes.')
                if $token_seen;
            $token_seen = 1;
            $token_val = shift @a;
            next;
        }
        if ($w =~ /^-/) {
            refuse('takes ids only, plus --token from a stop message; the hold is always 50 minutes.');
        }
        push @item_words, $w;
    }
}

if ($token_seen) {
    unless (defined $token_val && $token_val =~ /^[0-9a-f]{8}$/) {
        refuse('--token takes the 8-character token from the stop message.');
    }
}

refuse('name at least one subagent or background task id.') unless @item_words;

my (@ITEMS, %seen_item);
for my $w (@item_words) {
    my $id = $w;
    if ($id =~ /^agent-(.*)$/s) { $id = $1 }
    refuse("ids are letters, digits, '-' and '_' only.") unless $id =~ $ITEM_RE;
    next if $seen_item{$id}++;
    push @ITEMS, $id;
}

# Red-team H1: a holder can never hold its own background task. Checked
# for every become and every extend, before anything is read or written.
my $SELF_TASK_ID = resolve_self_task_id();
if (defined $SELF_TASK_ID && grep { $_ eq $SELF_TASK_ID } @ITEMS) {
    refuse('a holder cannot hold itself.');
}

# ---------------------------------------------------------------------------
# step 2: state root
# ---------------------------------------------------------------------------

my $ROOT = BpHook::state_dir();
refuse('no continuity state directory (set HOME, or an absolute BUTLER_STATE_DIR).')
    unless defined $ROOT;

# ---------------------------------------------------------------------------
# step 3: binding
# ---------------------------------------------------------------------------

my ($SID, $AID, $BIND_TP, $BACKGROUND);

# R6-M5 (red-team MEDIUM-5, Decision 51): for a ticket-bound call, whether
# the --token's ownership gets CHECKED is deferred past the point where we
# would refuse a foreground BECOME -- otherwise take_stop_token's one-shot
# consumption burns the escape before the caller ever learns the call was
# refused (the token would never be usable by a later, correct, background
# retry). $DEFERRED_TOKEN_CHECK is resolved once is_alive/BACKGROUND are
# both known, below.
my $DEFERRED_TOKEN_CHECK = 0;

my $ticket = BpHook::take_ticket('butler-hold', \@ARGV_RAW);

if (ref $ticket eq 'HASH') {
    $SID        = $ticket->{session_id};
    $AID        = $ticket->{agent_id};
    $BIND_TP    = $ticket->{transcript_path};
    $BACKGROUND = ($ticket->{background} ? 1 : 0);
    $DEFERRED_TOKEN_CHECK = 1 if $token_seen;
}
elsif (!defined $ticket || $ticket eq 'ambiguous') {
    if ($token_seen) {
        my $s2 = BpHook::take_stop_token($token_val);
        if (defined $s2) {
            $SID        = $s2;
            $AID        = undef;
            $BIND_TP    = undef;
            $BACKGROUND = 1;
        }
        else {
            refuse('no session binding; use the --token from the stop message, or quote ids plainly.');
        }
    }
    else {
        refuse('no session binding; use the --token from the stop message, or quote ids plainly.');
    }
}
else {
    refuse('no session binding; use the --token from the stop message, or quote ids plainly.');
}

if (defined $AID) {
    refuse('only the main session holds; a subagent may not.');
}

my $SID8 = sid8_of($SID);

# ---------------------------------------------------------------------------
# step 4: become or extend, under the lock
# ---------------------------------------------------------------------------

my $HOLDER_DIR = "$ROOT/holder";
eval { require File::Path; File::Path::make_path($HOLDER_DIR) };

my $LOCK_PATH = "$HOLDER_DIR/$SID.lock";
my $RECORD_PATH = "$HOLDER_DIR/$SID.json";

sub take_lock_or_refuse {
    my ($lock_path) = @_;
    my $lockfh;
    unless (open($lockfh, '>>', $lock_path)) {
        refuse('holder state is busy; run it again.');
    }
    my $got = 0;
    eval {
        local $SIG{ALRM} = sub { die "bp-hold-lock-timeout\n" };
        alarm(10);
        $got = flock($lockfh, LOCK_EX);
        alarm(0);
    };
    alarm(0);
    unless ($got) {
        close $lockfh;
        refuse('holder state is busy; run it again.');
    }
    return $lockfh;
}

sub unlock_and_close {
    my ($lockfh) = @_;
    flock($lockfh, LOCK_UN);
    close $lockfh;
    return;
}

sub armed_transcript_path {
    my ($root, $sid) = @_;
    my $data = read_json_file("$root/armed/$sid");
    return (ref $data eq 'HASH' && defined $data->{transcript_path} && length $data->{transcript_path})
        ? $data->{transcript_path}
        : undef;
}

sub resolve_transcript_path {
    my ($bind_tp, $existing, $root, $sid) = @_;
    return $bind_tp if defined $bind_tp && length $bind_tp;
    if (ref $existing eq 'HASH' && defined $existing->{transcript_path} && length $existing->{transcript_path}) {
        return $existing->{transcript_path};
    }
    return armed_transcript_path($root, $sid);
}

my $HOLD = hold_seconds();
my $TICK = tick_seconds();

# Red-team H2 / review m3: the tail read and output-path resolution run
# BEFORE the holder lock is taken at all, so a slow scan (even the linear
# one above, on a very large tail) never holds `holder/<sid>.lock` and
# never stalls a concurrent extend, a concurrent become, or this holder's
# own tick. A quick unlocked peek at the existing record is enough to pick
# the transcript path; the authoritative record is re-read under the lock
# below before anything is decided or written.
my $peek        = BpHook::holder($SID);
my $peek_tp     = resolve_transcript_path($BIND_TP, $peek, $ROOT, $SID);
my $peek_tail   = defined $peek_tp ? read_tail($peek_tp) : undef;
my $peek_outputs = resolved_outputs_for($peek_tail, @ITEMS);

sub take_off_check_or_end {
    # Review m1: `off` (BpHook::disarm) and this become/extend must
    # serialise on the SAME lock, or an off that completes between this
    # process's read of the (now-absent) record and its write can be
    # resurrected. `disarm` takes `armlock/<sid>` for its whole
    # unlink-and-write-off-record critical section, so taking that same
    # lock here, and holding it across our own write, closes the window
    # from this side without touching package 04's files.
    my ($root, $sid) = @_;
    my $almfh = BpHook::_open_armlock($root, $sid);
    unless ($almfh) {
        return (undef, 0);
    }
    unless (BpHook::_flock_with_timeout($almfh, 10)) {
        close $almfh;
        return (undef, 0);
    }
    return ($almfh, 1);
}

my $lockfh = take_lock_or_refuse($LOCK_PATH);
my ($almfh, $almok) = take_off_check_or_end($ROOT, $SID);
unless ($almok) {
    unlock_and_close($lockfh);
    refuse('holder state is busy; run it again.');
}
if (BpHook::latest_is_off($SID)) {
    flock($almfh, LOCK_UN);
    close $almfh;
    unlock_and_close($lockfh);
    out_line('continuity is off; holder ended.');
    exit 0;
}

my $existing = BpHook::holder($SID);
my $is_alive = (ref $existing eq 'HASH') ? proc_alive($existing->{pid}, $existing->{fp}) : 0;

# R6-M5: resolve the deferred ticket-bound --token check now -- but only
# once we know this call will NOT be refused for lacking run_in_background
# (is_alive, so it will EXTEND; or already BACKGROUND, so it may BECOME).
# On the about-to-be-refused foreground/no-holder path the token is left
# completely untouched, so it survives for a later, correct, retry.
if ($DEFERRED_TOKEN_CHECK && ($is_alive || $BACKGROUND)) {
    my $s2 = BpHook::take_stop_token($token_val);
    if (defined $s2 && $s2 ne $SID) {
        flock($almfh, LOCK_UN);
        close $almfh;
        unlock_and_close($lockfh);
        refuse('the --token belongs to another session.');
    }
}

if ($is_alive) {
    # -------------------------------------------------------------- EXTEND
    my @merged = @{ (ref $existing->{items} eq 'ARRAY') ? $existing->{items} : [] };
    my %have = map { $_ => 1 } @merged;
    my @new_ids;
    for my $id (@ITEMS) {
        next if $have{$id};
        push @merged, $id;
        $have{$id} = 1;
        push @new_ids, $id;
    }

    my $want_deadline = int(time()) + $HOLD;
    my $new_deadline = ($existing->{deadline} // 0);
    $new_deadline = $want_deadline if $want_deadline > $new_deadline;

    my $tp = resolve_transcript_path($BIND_TP, $existing, $ROOT, $SID);

    my $outputs = (ref $existing->{outputs} eq 'HASH') ? { %{ $existing->{outputs} } } : {};
    for my $id (@new_ids) {
        next if defined $outputs->{$id};
        $outputs->{$id} = $peek_outputs->{$id} if defined $peek_outputs->{$id};
    }

    my $rec = {
        session_id      => $SID,
        token           => $existing->{token},
        pid             => $existing->{pid},
        fp              => $existing->{fp},
        items           => \@merged,
        outputs         => $outputs,
        started_at      => $existing->{started_at},
        deadline        => $new_deadline,
        transcript_path => $tp,
    };

    # Written before the record becomes visible (review M5): the
    # accountability line must never be observable-after-the-fact as
    # missing just because a reader raced the record's own appearance.
    BpHook::log_reason($SID, 'butler-hold', 'extend', join(', ', @merged));
    my $ok = write_record_atomic($RECORD_PATH, $rec);
    flock($almfh, LOCK_UN);
    close $almfh;
    unlock_and_close($lockfh);
    unless ($ok) {
        refuse('could not write the holder record (' . ($LAST_WRITE_ERR // 'unknown') . ').');
    }
    out_line(sprintf('extended holder of session %s until %s: %s', $SID8, hhmm_of($new_deadline), join(', ', @merged)));
    exit 0;
}

# ------------------------------------------------------------------- BECOME
unless ($BACKGROUND) {
    flock($almfh, LOCK_UN);
    close $almfh;
    unlock_and_close($lockfh);
    refuse('start it with run_in_background: true.');
}

my $tp = resolve_transcript_path($BIND_TP, $existing, $ROOT, $SID);
my $token = rand_token();
my $fp = compute_fp();
my $now = int(time());
my $outputs = { %$peek_outputs };

my $rec = {
    session_id      => $SID,
    token           => $token,
    pid             => $$,
    fp              => $fp,
    items           => \@ITEMS,
    outputs         => $outputs,
    started_at      => $now,
    deadline        => $now + $HOLD,
    transcript_path => $tp,
};

BpHook::log_reason($SID, 'butler-hold', 'hold', join(', ', @ITEMS));
my $ok = write_record_atomic($RECORD_PATH, $rec);
flock($almfh, LOCK_UN);
close $almfh;
unlock_and_close($lockfh);
unless ($ok) {
    refuse('could not write the holder record (' . ($LAST_WRITE_ERR // 'unknown') . ').');
}
out_line(sprintf('holding session %s until %s: %s', $SID8, hhmm_of($rec->{deadline}), join(', ', @ITEMS)));

# ---------------------------------------------------------------------------
# the wait loop -- this process is the held work's own watcher, start to end.
# $SIGNALLED is the `our` variable whose handlers were installed at the very
# top of this file, before any other work (spec 2.8, review M1).
# ---------------------------------------------------------------------------

sub end_report {
    my ($header, $record, $code) = @_;
    $code //= 0;
    my @lines = ($header);
    my @items = (ref $record->{items} eq 'ARRAY') ? @{ $record->{items} } : ();
    my $tail = read_tail($record->{transcript_path});
    for my $id (@items) {
        my $st = item_status($record, $id, $tail);
        if ($st->{status} eq 'finished') {
            push @lines, "$id finished";
        }
        elsif ($st->{status} eq 'running') {
            push @lines, "$id still running (last activity " . iso_of($st->{mtime}) . ")";
        }
        else {
            push @lines, "$id unknown";
        }
    }
    print STDOUT join("\n", @lines) . "\n";
    exit $code;
}

sub sleep_watching_signal {
    my ($secs) = @_;
    my $remaining = $secs;
    my $chunk = 0.05;
    while ($remaining > 0 && !$SIGNALLED) {
        my $s = $remaining < $chunk ? $remaining : $chunk;
        sleep($s);
        $remaining -= $s;
    }
    return;
}

my $known_deadline = $rec->{deadline};
my $last_valid = $rec;

while (1) {
    my $t0 = time();
    my $remaining_to_deadline = $known_deadline - $t0;
    my $sleep_for = $remaining_to_deadline > $TICK ? $TICK
                  : ($remaining_to_deadline < 0.01 ? 0.01 : $remaining_to_deadline);
    sleep_watching_signal($sleep_for);

    if ($SIGNALLED) {
        end_report('hold ended: killed.', $last_valid, 143);
    }

    my $rp = BpHook::holder($SID);
    if (ref($rp) ne 'HASH') {
        end_report('continuity is off; holder ended.', $last_valid, 0);
    }
    if (!defined $rp->{token} || $rp->{token} ne $token) {
        end_report('hold ended: superseded.', $rp, 0);
    }
    $known_deadline = $rp->{deadline};
    $last_valid = $rp;

    my $t1 = time();
    my $finished_now = all_finished($rp);
    if ($t1 >= $rp->{deadline} || $finished_now) {
        my $lfh2;
        my $locked2 = 0;
        if (open($lfh2, '>>', $LOCK_PATH)) {
            eval {
                local $SIG{ALRM} = sub { die "bp-hold-lock-timeout\n" };
                alarm(10);
                $locked2 = flock($lfh2, LOCK_EX);
                alarm(0);
            };
            alarm(0);
        }
        unless ($locked2) {
            close $lfh2 if $lfh2;
            next;
        }

        my $rp2 = BpHook::holder($SID);
        if (ref($rp2) ne 'HASH') {
            unlock_and_close($lfh2);
            end_report('continuity is off; holder ended.', $last_valid, 0);
        }
        if (!defined $rp2->{token} || $rp2->{token} ne $token) {
            unlock_and_close($lfh2);
            end_report('hold ended: superseded.', $rp2, 0);
        }

        my $t2 = time();
        my $finished2 = all_finished($rp2);
        if ($t2 < $rp2->{deadline} && !$finished2) {
            unlock_and_close($lfh2);
            $known_deadline = $rp2->{deadline};
            $last_valid = $rp2;
            next;
        }

        unlink($RECORD_PATH);
        unlock_and_close($lfh2);
        end_report(
            ($t2 >= $rp2->{deadline})
                ? "hold ended at the deadline for session $SID8."
                : "hold ended: every held item finished (session $SID8).",
            $rp2,
            0,
        );
    }
}

return;

}    # sub main

# ---------------------------------------------------------------------------
# spec 2.8 / review M1: the whole program runs inside eval. `exit` (used by
# every refusal, `end_report`, and every extend/become success path above)
# is not caught by eval and leaves the process at once with its own exit
# code, so this only ever fires for an unforeseen `die`.
# ---------------------------------------------------------------------------
my $MAIN_OK = eval { main(); 1 };
unless ($MAIN_OK) {
    print STDOUT "butler-hold: internal error.\n";
    exit 1;
}
exit 0;
