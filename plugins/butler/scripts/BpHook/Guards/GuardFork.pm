# BpHook::Guards::GuardFork -- the fork-refusal PreToolUse guard (package 19
# of blueprint hook-continuity-remake, Decision 64 as carried by Decision 90).
#
# Contract: .ccpraxis-local-data/blueprints/hook-continuity-remake/specs/
# 19-fork-guard-spec.md sec 2.3. Architecture:
# plugins/butler/docs/hook-architecture.md ("guard-fork.sh" rows).
#
# Denies every Agent/Task dispatch whose tool_input.subagent_type is the
# literal string "fork", everywhere but for the next fork dispatch of a
# session holding a one-shot token minted by butler-fork-ok. Ticket writing
# for a real butler-fork-ok invocation moved to ContinuityOffCheck.pm
# (package 28, Decision 105); this module writes no ticket for any payload.
#
# run($p, @args) never calls exit, never dies on purpose, never spawns a
# process, and never re-parses the payload (BpHook::parse_count() is
# unchanged by run()). Prints only through BpHook::deny(@lines).
package BpHook::Guards::GuardFork;
use strict;
use warnings;
use JSON::PP ();
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

# ---------------------------------------------------------------------------
# small local aliases -- the real implementations live in BpHook.pm; this
# module carries no ticket code of its own (review m6).
# ---------------------------------------------------------------------------
sub _is_plain_string { return BpHook::_is_plain_string(@_); }
sub _iso_now { return BpHook::_iso_now(@_); }

# ---------------------------------------------------------------------------
# deny_lines() -- the exact 2.3.2 text, 3 lines, each at most 160 characters.
# ---------------------------------------------------------------------------
sub deny_lines {
    return (
        q{Fork refused: a fork inherits this whole conversation and the parent's identity, and an agent that forked instead of dispatching once broke things.},
        q{Launch a fresh, context-free subagent (for example general-purpose) with a self-contained prompt instead.},
        q{If a fork is truly needed, first run: butler-fork-ok --reason '<why a fresh subagent will not do>' (allows one fork).},
    );
}

# ---------------------------------------------------------------------------
# valid_reason($r) -- 2.3.3: at least two whitespace-separated words AND at
# least 10 non-whitespace characters.
# ---------------------------------------------------------------------------
sub valid_reason {
    my ($r) = @_;
    return 0 unless defined $r && !ref($r) && _is_plain_string($r);
    $r = BpHook::_decode_maybe($r);
    my @words = grep { length } split /\s+/, $r;
    return 0 if scalar(@words) < 2;
    (my $nospace = $r) =~ s/\s+//g;
    return 0 if length($nospace) < 10;
    return 1;
}

# ---------------------------------------------------------------------------
# record_token($sid, $reason) -- 2.3.4. Atomically (over)writes
# $S/fork-ok/<sid>.json. Returns 1/0.
# ---------------------------------------------------------------------------
sub record_token {
    my ($sid, $reason) = @_;
    return 0 unless defined $sid && $sid =~ /\A[A-Za-z0-9_-]{1,128}\z/;
    return 0 unless valid_reason($reason);
    my $root = BpHook::state_dir();
    return 0 unless defined $root;
    my $cut = BpHook::_decode_maybe($reason);
    $cut = substr($cut, 0, 300);
    return 0 unless valid_reason($cut);
    my $rec = {
        at         => _iso_now(),
        reason     => $cut,
        session_id => $sid,
    };
    return BpHook::_write_json_atomic("$root/fork-ok/$sid.json", $rec);
}

# ---------------------------------------------------------------------------
# take_token($sid) -- 2.3.4. Renames the token to a unique claimed name,
# always unlinks it, and returns 1 iff it parsed as a hash whose session_id
# matches $sid and whose reason is valid.
# ---------------------------------------------------------------------------
sub take_token {
    my ($sid) = @_;
    return 0 unless defined $sid && $sid =~ /\A[A-Za-z0-9_-]{1,128}\z/;
    my $root = BpHook::state_dir();
    return 0 unless defined $root;
    my $path = "$root/fork-ok/$sid.json";
    return 0 unless -f $path;
    my $claimed = "$path.taken.$$";
    return 0 unless rename($path, $claimed);
    my $data;
    if (open(my $fh, '<:raw', $claimed)) {
        local $/;
        my $raw = <$fh>;
        close $fh;
        $data = eval { JSON::PP->new->utf8->decode($raw) };
    }
    unlink $claimed;
    return 0 unless ref $data eq 'HASH';
    return 0 unless defined $data->{session_id} && $data->{session_id} eq $sid;
    return 0 unless valid_reason($data->{reason});
    return 1;
}

# ---------------------------------------------------------------------------
# run($p, @args) -> 0 | 2.
# ---------------------------------------------------------------------------
sub run {
    my ($p, @args) = @_;
    return 0 unless BpHook::payload_ok();
    $p = {} unless ref $p eq 'HASH';

    my $event = $p->{hook_event_name};
    return 0 if defined $event && !ref($event) && $event ne 'PreToolUse';

    my $t = $p->{tool_name};
    return 0 unless _is_plain_string($t);

    if ($t eq 'Agent' || $t eq 'Task') {
        my $ti = $p->{tool_input};
        return 0 unless ref $ti eq 'HASH';
        my $st = $ti->{subagent_type};
        return 0 unless _is_plain_string($st) && $st eq 'fork';
        my $sid = BpHook::session_id($p);
        return 0 unless defined $sid;
        return 0 if take_token($sid);
        return BpHook::deny(deny_lines());
    }

    return 0;
}

1;
