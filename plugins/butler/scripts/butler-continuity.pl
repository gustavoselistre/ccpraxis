#!/usr/bin/env perl
# butler-continuity.pl -- the one command for Decision 1's arm and disarm
# triggers (package 04 of blueprint hook-continuity-remake).
#
#   butler-continuity on      [--role driver|reporter]
#   butler-continuity off     [--reason '<2+ words>'] [--token <8 hex>]
#   butler-continuity silence  --reason '<2+ words>'  [--token <8 hex>]
#   butler-continuity status
#   butler-continuity ask      --text '<question>'
#
# Contract: .ccpraxis-local-data/blueprints/hook-continuity-remake/specs/
# 04-continuity-command-spec.md. Architecture: docs/hook-architecture.md
# ("BpHook core API", "Command binding: tickets and stop tokens").
#
# NO SESSION SELECTOR. This command never reads the caller's environment for
# a session identity; it learns its session only from a hook-written ticket
# (see BpHook::take_ticket) or, when a Stop denial minted one, a one-shot
# token passed with --token. Additive only (Decision 19): the old continuity
# CLI, the old registry and every live hook are untouched by this file.
use strict;
use warnings;
use FindBin qw($Bin);
use JSON::PP ();
use POSIX qw(strftime);

require "$Bin/BpHook.pm"
    unless grep { m{(?:^|/)BpHook\.pm$} } keys %INC;
require "$Bin/BpContinuityLease.pm"
    unless grep { m{(?:^|/)BpContinuityLease\.pm$} } keys %INC;
require "$Bin/BpProjectRoot.pm"
    unless grep { m{(?:^|/)BpProjectRoot\.pm$} } keys %INC;

my $USAGE = q{usage: butler-continuity on [--role driver|reporter] | off [--reason '<why>'] [--token T] | silence --reason '<why>' [--token T] | status | ask --text '<question>'};

sub _bytes {
    my ($s) = @_;
    return '' unless defined $s;
    my $v = "$s";
    if (utf8::is_utf8($v)) { utf8::encode($v) }
    return $v;
}

sub out {
    my (@lines) = @_;
    binmode(STDOUT, ':raw');
    for my $l (@lines) { print STDOUT _bytes($l) }
}

sub refuse {
    my ($msg) = @_;
    binmode(STDERR, ':raw');
    print STDERR _bytes("butler-continuity: $msg") . "\n";
    exit 1;
}

sub usage_die {
    binmode(STDERR, ':raw');
    print STDERR "butler-continuity: $USAGE\n";
    exit 1;
}

sub iso_now { return strftime('%Y-%m-%dT%H:%M:%SZ', gmtime()) }

sub word_count {
    my ($s) = @_;
    return 0 unless defined $s;
    my @w = grep { length } split /\s+/, $s;
    return scalar @w;
}

# sanitize_text($s) -- R4-L-reason (redteam LOW-2) / M1 (review). Strips C0/
# C1 control bytes, ANSI OSC/CSI escape sequences, and Unicode zero-width or
# other invisible ("format") characters; flattens any remaining newline,
# CR or tab run to a single space. Used both to validate a reason (so a
# reason that is invisible-only is refused, not silently accepted) and to
# sanitise what actually gets stored or printed, since BpHook::log_reason's
# own flatten only folds \t\r\n and status reads fields straight off disk
# (which a caller other than this command, e.g. BpHook::disarm called
# directly, can populate with anything).
sub sanitize_text {
    my ($raw) = @_;
    return '' unless defined $raw;
    my $s = $raw;
    { local $@; eval { utf8::decode($s) } }    # best effort; raw bytes on failure
    $s =~ s/\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)?//g;   # OSC ... BEL|ST
    $s =~ s/\x1b\[[0-9;?]*[ -~]//g;                    # CSI ... final byte
    $s =~ s/[\r\n\t]+/ /g;
    $s =~ s/\p{Cc}//g;                                  # remaining C0/C1 controls
    $s =~ s/\p{Cf}//g;                                  # zero-width / invisible format chars
    $s =~ s/\s+/ /g;
    $s =~ s/^\s+|\s+$//g;
    return $s;
}

# visible_word_count($s) -- word count over sanitize_text($s), counting only
# runs of \p{L}/\p{N}. Stricter than word_count() above (which the core's
# _word_count mirrors), so nothing this command accepts can ever be a reason
# BpHook::set_silence would refuse.
sub visible_word_count {
    my ($s) = @_;
    return 0 unless defined $s;
    my $san = sanitize_text($s);
    my @w = ($san =~ /[\p{L}\p{N}]+/g);
    return scalar @w;
}

sub read_json_file {
    my ($path) = @_;
    open(my $fh, '<:raw', $path) or return undef;
    local $/;
    my $c = <$fh>;
    close $fh;
    return eval { JSON::PP->new->utf8->decode($c) };
}

# project_of($cwd) -- the parent directory of BpHook::data_dir({cwd=>$cwd}),
# or '-' when that is undef.
sub project_of {
    my ($cwd) = @_;
    return '-' unless defined $cwd && length $cwd;
    my $dd = BpHook::data_dir({ cwd => $cwd });
    return '-' unless defined $dd;
    (my $proj = $dd) =~ s{/\.ccpraxis-local-data/?$}{};
    return (defined $proj && length $proj) ? $proj : '-';
}

sub lease_sync {
    return if $ENV{CCPRAXIS_NO_WAKELOCK};
    my $ldir = BpContinuityLease::legacy_dir();
    return unless defined $ldir;
    my $ok = eval { BpContinuityLease::converge($ldir); 1 };
    unless ($ok) {
        my $err = $@ || 'unknown error';
        $err =~ s/\r?\n.*$//s;
        binmode(STDERR, ':raw');
        print STDERR _bytes("butler-continuity: warning: wake-lock not updated ($err).") . "\n";
    }
}

# ---------------------------------------------------------------------------
# parse argv
# ---------------------------------------------------------------------------
my @argv0 = @ARGV;    # the untouched copy, ticket key material
my @args  = @ARGV;

my $verb = shift @args;
usage_die() unless defined $verb && $verb =~ /^(?:on|off|silence|status|ask)$/;

my %allowed = (
    on      => { role => 1 },
    off     => { reason => 1, token => 1 },
    silence => { reason => 1, token => 1 },
    status  => {},
    ask     => { text => 1 },
);

my %flags;
while (@args) {
    my $a = shift @args;
    if ($a =~ /^--([A-Za-z][A-Za-z0-9_-]*)$/) {
        my $name = $1;
        usage_die() unless $allowed{$verb}{$name};
        usage_die() if exists $flags{$name};
        $flags{$name} = @args ? shift(@args) : undef;
    }
    else {
        usage_die();    # a stray positional word
    }
}

# ---------------------------------------------------------------------------
# Step 1: validation. Nothing is consumed or written.
# ---------------------------------------------------------------------------
if ($verb eq 'off' || $verb eq 'silence') {
    if (exists $flags{reason}) {
        if (!defined $flags{reason} || visible_word_count($flags{reason}) < 2) {
            refuse("--reason needs at least two words saying why.");
        }
    }
    elsif ($verb eq 'silence') {
        refuse("--reason needs at least two words saying why.");
    }
}

if (exists $flags{token}) {
    if (!defined $flags{token} || $flags{token} !~ /^[0-9a-f]{8}$/) {
        refuse("--token takes the 8-character token from the stop message.");
    }
}

if (exists $flags{role}) {
    if (!defined $flags{role} || ($flags{role} ne 'driver' && $flags{role} ne 'reporter')) {
        refuse("--role takes driver or reporter.");
    }
}

if ($verb eq 'ask') {
    if (!defined $flags{text} || !length $flags{text}) {
        refuse("ask needs --text '<question>'.");
    }
}

# ---------------------------------------------------------------------------
# Step 2: coordinator (Decision 25).
# ---------------------------------------------------------------------------
if (defined $ENV{BP_LEDGER} && length $ENV{BP_LEDGER}) {
    if ($verb eq 'off' || $verb eq 'silence') {
        refuse("a coordinator cannot turn continuity off; it stops when its ledger is terminal.");
    }
    if ($verb eq 'on') {
        out("continuity is on by construction for a coordinator; nothing to do.\n");
        exit 0;
    }
    # status and ask run normally.
}

# ---------------------------------------------------------------------------
# Step 3: state root (every verb except ask).
# ---------------------------------------------------------------------------
my $ROOT;
if ($verb ne 'ask') {
    $ROOT = BpHook::state_dir();
    unless (defined $ROOT) {
        refuse("no continuity state directory (set HOME, or an absolute BUTLER_STATE_DIR).");
    }
}

# ---------------------------------------------------------------------------
# Step 4: binding (on, off, silence, status).
# ---------------------------------------------------------------------------
my ($SID, $AID, $OPERATOR_TICKET, $PROJECT, $TRANSCRIPT_PATH);

if ($verb eq 'on' || $verb eq 'off' || $verb eq 'silence' || $verb eq 'status') {
    my $t = BpHook::take_ticket('butler-continuity', \@argv0);

    if (ref $t eq 'HASH') {
        $SID              = $t->{session_id};
        $AID              = $t->{agent_id};
        $OPERATOR_TICKET  = (JSON::PP::is_bool($t->{operator}) && $t->{operator}) ? 1 : 0;
        $TRANSCRIPT_PATH  = $t->{transcript_path};
        $PROJECT          = project_of($t->{cwd});

        if (exists $flags{token} && defined $flags{token}) {
            my $s2 = BpHook::take_stop_token($flags{token});    # always consumed when given
            if (defined $s2 && $s2 ne $SID) {
                refuse("the --token belongs to another session.");
            }
        }
    }
    elsif (exists $flags{token} && defined $flags{token} && ($verb eq 'off' || $verb eq 'silence')) {
        my $s2 = BpHook::take_stop_token($flags{token});
        if (defined $s2) {
            $SID             = $s2;
            $AID             = undef;
            $OPERATOR_TICKET = 0;
            $PROJECT         = '-';
        }
        else {
            _refuse_binding();
        }
    }
    else {
        _refuse_binding();
    }

    if (($verb eq 'on' || $verb eq 'off' || $verb eq 'silence') && defined $AID) {
        refuse("only the main session changes continuity; a subagent may not.");
    }
}

sub _refuse_binding {
    if ($verb eq 'on') {
        refuse("no session binding for on; run it again as a plain Bash tool call.");
    }
    elsif ($verb eq 'status') {
        refuse("no session binding for status; run it again as a plain Bash tool call.");
    }
    else {
        refuse("no session binding; use the --token from the stop message, or quote arguments in single quotes.");
    }
}

# ---------------------------------------------------------------------------
# Step 5: verbs.
# ---------------------------------------------------------------------------
my $S8 = defined $SID ? substr($SID, 0, 8) : '?';

if ($verb eq 'on') {
    my $role = $flags{role} // 'manual';
    my $ok = BpHook::arm($SID, role => $role, by => 'on', transcript_path => $TRANSCRIPT_PATH);
    unless ($ok) {
        refuse("could not write continuity state (" . (BpHook::last_error() // '') . ").");
    }
    out("continuity on for session $S8 (role $role).\n");
    lease_sync();
    exit 0;
}

if ($verb eq 'off') {
    my $actor = $OPERATOR_TICKET ? 'operator' : 'agent';
    my $reason;
    if (exists $flags{reason}) {
        $reason = sanitize_text($flags{reason});
    }
    elsif ($actor eq 'operator') {
        $reason = '(operator)';
    }
    else {
        refuse("off needs --reason '<why>' unless the operator typed /butler:continuity off.");
    }

    my $was_armed = BpHook::is_armed($SID);
    my $ok = BpHook::disarm($SID, actor => $actor, reason => $reason);
    unless ($ok) {
        refuse("could not write continuity state (" . (BpHook::last_error() // '') . ").");
    }
    my $logged = BpHook::log_reason($SID, $actor, 'off', $reason, $PROJECT);

    my $note = $was_armed ? '' : '; was not armed';
    out("continuity off for session $S8 (actor $actor$note); reason logged.\n");
    unless ($logged) {
        binmode(STDERR, ':raw');
        print STDERR "butler-continuity: warning: reason log not written.\n";
    }
    lease_sync();
    exit 0;
}

if ($verb eq 'silence') {
    unless (BpHook::is_armed($SID)) {
        out("continuity is off for this session; nothing to silence.\n");
        exit 0;
    }
    my $reason = sanitize_text($flags{reason});
    my $ok = BpHook::set_silence($SID, reason => $reason);
    unless ($ok) {
        refuse("could not write continuity state (" . (BpHook::last_error() // '') . ").");
    }
    BpHook::log_reason($SID, 'agent', 'silence', $reason, $PROJECT);
    out("continuity silenced for one stop of session $S8; reason logged.\n");
    exit 0;
}

if ($verb eq 'status') {
    my @lines;

    if (defined $ENV{BP_LEDGER} && length $ENV{BP_LEDGER}) {
        push @lines, "session $S8: armed (coordinator)";
    }
    elsif (-e "$ROOT/armed/$SID") {
        my $d = read_json_file("$ROOT/armed/$SID");
        my $role = (ref $d eq 'HASH' && defined $d->{role} && length $d->{role}) ? sanitize_text($d->{role}) : 'unknown';
        my $at   = (ref $d eq 'HASH' && defined $d->{at}   && length $d->{at})   ? sanitize_text($d->{at})   : 'unknown';
        $role = 'unknown' unless length $role;
        $at   = 'unknown' unless length $at;
        push @lines, "session $S8: armed (role $role, since $at)";
    }
    elsif (-e "$ROOT/off/$SID") {
        my $d = read_json_file("$ROOT/off/$SID");
        my $actor  = (ref $d eq 'HASH' && defined $d->{actor}  && length $d->{actor})  ? sanitize_text($d->{actor})  : 'unknown';
        my $at     = (ref $d eq 'HASH' && defined $d->{at}     && length $d->{at})     ? sanitize_text($d->{at})     : 'unknown';
        my $reason = (ref $d eq 'HASH' && defined $d->{reason} && length $d->{reason}) ? sanitize_text($d->{reason}) : 'unknown';
        $actor  = 'unknown' unless length $actor;
        $at     = 'unknown' unless length $at;
        $reason = 'unknown' unless length $reason;
        push @lines, "session $S8: off (by $actor at $at): $reason";
    }
    else {
        push @lines, "session $S8: not armed";
    }

    my $h = BpHook::holder($SID);
    if (defined $h && BpHook::holder_live($SID, {})) {
        my $items = (ref $h->{items} eq 'ARRAY')
            ? sanitize_text(join(', ', @{ $h->{items} }))
            : '';
        my $ddl = BpHook::local_utc_hhmm($h->{deadline});
        $ddl = 'unknown' unless defined $ddl;
        push @lines, sprintf('holder: running until %s; still running: %s', $ddl, $items);
    }
    else {
        push @lines, 'holder: none';
    }

    if (-e "$ROOT/silence/$SID") {
        my $d = read_json_file("$ROOT/silence/$SID");
        my $reason = (ref $d eq 'HASH' && defined $d->{reason} && length $d->{reason}) ? sanitize_text($d->{reason}) : 'unknown';
        $reason = 'unknown' unless length $reason;
        push @lines, "silence: one stop pending: $reason";
    }

    my $wl;
    if ($ENV{CCPRAXIS_NO_WAKELOCK}) {
        $wl = 'disabled';
    }
    else {
        my $ldir = BpContinuityLease::legacy_dir();
        # R4-L-tasklist (review m3): status "starts no process" (spec
        # SS2.2). BpContinuityLease::state()'s default pid_alive probe runs
        # `tasklist` on Windows; substituting kill(0, ...) keeps the same
        # shape of answer without ever spawning anything.
        $wl = defined $ldir
            ? BpContinuityLease::state($ldir, pid_alive => sub { kill(0, $_[0]) ? 1 : 0 })
            : 'released';
    }
    push @lines, "wake-lock: $wl";

    out(join("\n", @lines) . "\n");
    exit 0;
}

if ($verb eq 'ask') {
    my $text = $flags{text};
    $text =~ s/[\r\n]+/ /g;

    my $root = BpProjectRoot::resolve();
    my $dir  = "$root/.ccpraxis-local-data/.subagent-guard";
    my $path = "$dir/questions.md";
    unless (-d $dir) {
        eval { require File::Path; File::Path::make_path($dir) };
    }

    my $ok = 0;
    if (open(my $fh, '>>', $path)) {
        $ok = print {$fh} '- [' . iso_now() . "] $text\n";
        $ok &&= close($fh);
    }
    unless ($ok) {
        refuse("cannot write $path");
    }

    my $n = 0;
    if (open(my $rfh, '<', $path)) {
        while (my $l = <$rfh>) { $n++ if $l =~ /^\s*-\s/ }
        close $rfh;
    }
    out("queued ($n waiting): $path\n");
    exit 0;
}

usage_die();
