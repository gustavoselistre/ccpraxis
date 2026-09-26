#!/usr/bin/env perl
# platform: any
# Oracle for blueprint sandbox-session-ux, package 07-host-session-fork
# (specs/07-host-session-fork-spec.md, Decisions 1-7, 12, 14, 15, 16, 26,
# 28-31, and Decision 32 which OVERRIDES the spec's failure-path wording:
# a failed fork shows its error and returns to the picker on BOTH paths --
# it never falls through to a new session on its own).
#
# Written BLIND to the eventual SessionFork.pm / select-session.pl /
# launcher.pl / tui/LaunchScreens.pm implementation of THIS package's new
# surfaces (host_sessions_dir, encode_project_path, new_uuid, is_uuid,
# fork_session, read_provenance, short_id, --host-sessions-dir, --fork,
# origin/badges, the host: item-id prefix, the badges-aware cache key) --
# derived only from the spec's contracts (S2), observable behaviours (S3)
# and numbered acceptance criteria (S4).
#
# TODAY'S EXPECTED STATE: plugins/sandbox/scripts/SessionFork.pm does not
# exist at all. select-session.pl has no --host-sessions-dir/--fork/origin/
# badge support. tui/LaunchScreens.pm's session_pick_model always uses item
# id "$uuid" (never "host:$uuid") and _card_cache_key ignores badges.
# launcher.pl has no SessionFork wiring. Every group below is therefore
# expected to go RED. criterion() turns a die (missing sub/module) into one
# explicit failing assertion, so one absent function cannot take the whole
# file down and every criterion still gets to run independently.
#
# Fixture rules (Decision 15): every path lives under a File::Temp dir.
# HOME/USERPROFILE/CLAUDE_CONFIG_DIR are localised to temp dirs around every
# spawned select-session.pl. Transcripts are wholly synthetic -- invented
# UUIDs, invented Windows-shaped paths, invented message text -- and this
# file NEVER reads or names the real ~/.claude, the real
# C--Development-ccpraxis encoding, or a real user name. The non-ASCII
# fixture (AC-15 / done criterion 5) uses invented names "Zoe" with a
# combining/精 accent -- concretely "Zo\x{eb}" (Zoe with diaeresis, UTF-8
# bytes) for the host side and "S\x{e3}o" (Sao with a tilde) for the sandbox
# side, never the operator's own name.
#
# NEVER spawns launcher.pl, podman or claude. launcher.pl is read as SOURCE
# TEXT ONLY (AC-25), the same convention launcher-screens.t's AC-W group
# uses. No real ~/.claude is ever opened for read or write.

use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use File::Temp qw(tempdir tempfile);
use File::Path qw(make_path);
use File::Basename qw(basename);
use JSON::PP ();
use POSIX qw(strftime);
use Digest::SHA qw(sha256_hex);

my $SCRIPTS  = "$Bin/../../scripts";
my $SF_PM    = "$SCRIPTS/SessionFork.pm";
my $SCRIPT   = "$SCRIPTS/select-session.pl";
my $LS_PM    = "$SCRIPTS/tui/LaunchScreens.pm";
my $SI_PM    = "$SCRIPTS/SessionIndex.pm";
my $SFILT_PM = "$SCRIPTS/SessionFilter.pm";
my $LAUNCHER = "$SCRIPTS/launcher.pl";

use lib "$Bin/../../scripts";

# ============================================================================
# criterion($name, $code) -- a die (missing sub/module) becomes ONE explicit
# failing assertion instead of aborting the whole file (established
# convention: session-index-classify.t, session-filter.t, session-picker-
# cards.t).
# ============================================================================
sub criterion {
    my ($name, $code) = @_;
    my $ok = eval { $code->(); 1 };
    if (!$ok) {
        my $err = $@;
        $err = 'unknown error' unless length $err;
        $err =~ s/\s+\z//;
        fail("$name -- DIED (missing behavior): $err");
    }
    return;
}

# ============================================================================
# Module loads
# ============================================================================
my $LS_OK = eval { require tui::LaunchScreens; 1 };
ok($LS_OK, 'L1 tui/LaunchScreens.pm loads (shipped, package 03/08)')
    or diag("  require tui::LaunchScreens failed: $@");

my $SI_OK = eval { require $SI_PM; 1 };
ok($SI_OK, "L2 SessionIndex.pm loads via require '$SI_PM' (package 02, shipped)")
    or diag("  require SessionIndex failed: $@");

my $SFILT_OK = eval { require $SFILT_PM; 1 };
ok($SFILT_OK, "L3 SessionFilter.pm loads via require '$SFILT_PM' (shipped)")
    or diag("  require SessionFilter failed: $@");

ok(-f $SCRIPT, 'select-session.pl exists') or BAIL_OUT('select-session.pl is missing');
require $SCRIPT;   # guarded by `unless (caller)`; must NOT run main()
pass('require of select-session.pl did not run main() (caller guard holds)');

ok(-f $LAUNCHER, 'launcher.pl exists (read as SOURCE TEXT only below -- AC-25)');

# THE module this package adds. Expected MISSING today -- record that as one
# explicit, named failure rather than letting `require` abort the file.
my $SF_OK = eval { require $SF_PM; 1 };
ok($SF_OK, "L4 SessionFork.pm loads via require '$SF_PM' (THIS package's new module)")
    or diag("  require SessionFork failed (expected until the implementer lands it): $@");

# ============================================================================
# Generic helpers
# ============================================================================
sub href { my ($x) = @_; return ref $x eq 'HASH'  ? $x : {}; }
sub aref { my ($x) = @_; return ref $x eq 'ARRAY' ? $x : []; }
sub bstr { my ($x) = @_; return defined $x && !ref $x ? $x : ''; }

sub slurp {
    my ($path) = @_;
    open my $fh, '<:raw', $path or return undef;
    local $/;
    my $s = <$fh>;
    close $fh;
    return $s;
}

sub write_raw {
    my ($path, $bytes) = @_;
    open my $fh, '>:raw', $path or die "write_raw($path): $!";
    print {$fh} $bytes;
    close $fh;
    return $path;
}

# _comment_stripped($src) -> $src with whole-line `#` comments blanked
# (launcher-screens.t's own convention, reused verbatim for AC-25).
sub _comment_stripped {
    my ($src) = @_;
    return join("\n", map { /^\s*#/ ? '' : $_ } split /\n/, $src, -1);
}

# stat_sig($path) -> "mtime:sha256hex" | undef -- a single opaque signature
# used to assert byte-identity + mtime-unchanged in one comparison (AC-4/16).
sub stat_sig {
    my ($path) = @_;
    my @st = stat($path);
    return undef unless @st;
    my $bytes = slurp($path);
    return undef unless defined $bytes;
    return $st[9] . ':' . sha256_hex($bytes);
}

my $JSON = JSON::PP->new->utf8->canonical;
my $T0 = 1_734_000_000;
sub ts     { my ($off) = @_; return iso_ts($T0 + $off); }
sub iso_ts { my ($ep)  = @_; return strftime('%Y-%m-%dT%H:%M:%S', gmtime($ep)) . '.000Z'; }

# accent_dir($tag) -- a File::Temp dir whose LEAF component contains a
# UTF-8-encoded non-ASCII letter (Decision 15) -- never the operator's real
# path. $tag distinguishes the host side ("Zo\x{eb}") from the sandbox side
# ("S\x{e3}o") so a fixture never accidentally shares a directory across
# roles.
sub accent_dir {
    my ($tag) = @_;
    my $root = tempdir(CLEANUP => 1);
    my $leaf = Encode_leaf($tag) . '-' . int(rand(1_000_000));
    my $dir = "$root/$leaf";
    make_path($dir);
    return $dir;
}
sub Encode_leaf {
    my ($tag) = @_;
    require Encode;
    return Encode::encode('UTF-8', $tag);
}

my $HOST_TAG    = "Zo\x{eb}";     # "Zoe" + diaeresis
my $SANDBOX_TAG = "S\x{e3}o";     # "Sao" + tilde

# ----------------------------------------------------------------------------
# build_host_transcript($path, %opts) -> \%meta
#
# Writes a synthetic host transcript at $path modelled on the record shapes
# spec S1.2 lists: mode, permission-mode, a file-history-snapshot WITHOUT
# sessionId, a typed human "user" record (entrypoint cli, origin.kind human,
# promptSource typed, cwd, sessionId), an "assistant" record, an
# "attachment" record whose nested snapshot.workingDirectory/
# scratchpadDirectory carry the OLD id/path, a "last-prompt" record whose
# leafUuid names the attachment's uuid, an "ai-title" record, one malformed
# COMPLETE line (has a trailing \n but is not valid JSON, and contains the
# literal substring "sessionId" so it exercises the scan-returns-undef ->
# written-verbatim path), and a trailing FRAGMENT with no \n at all (must be
# dropped by the fork).
#
# Returns { old, u1, u2, u3, msg, cwd, complete_count } -- complete_count is
# the number of \n-terminated lines (8 well-formed + 1 malformed = 9); the
# fragment is never counted.
# ----------------------------------------------------------------------------
sub build_host_transcript {
    my ($path, %opts) = @_;
    my $old = $opts{old}   // 'aaaaaaaa-0000-4000-8000-000000000001';
    my $cwd = $opts{cwd}   // 'C:\\Users\\host\\proj';
    my $msg = $opts{msg}   // 'please fix the login bug';
    my ($u1, $u2, $u3) = ('c1000000-0000-0000-0000-000000000001',
                           'c2000000-0000-0000-0000-000000000002',
                           'c3000000-0000-0000-0000-000000000003');

    my @lines;
    push @lines, $JSON->encode({ type => 'mode', mode => 'default', timestamp => ts(0) });
    push @lines, $JSON->encode({ type => 'permission-mode', mode => 'default', timestamp => ts(1) });
    push @lines, $JSON->encode({ type => 'file-history-snapshot', messageId => 'm1',
        snapshot => { messageId => 'm1', trackedFileBackups => ['a.txt'], timestamp => ts(2) },
        isSnapshotUpdate => JSON::PP::false });
    push @lines, $JSON->encode({ type => 'user', uuid => $u1, parentUuid => undef,
        isSidechain => JSON::PP::false, promptId => 'p1', timestamp => ts(3),
        userType => 'external', entrypoint => 'cli', cwd => $cwd, sessionId => $old,
        version => '2.1.257', gitBranch => 'main', origin => { kind => 'human' },
        promptSource => 'typed',
        message => { role => 'user', content => [ { type => 'text', text => $msg } ] } });
    push @lines, $JSON->encode({ type => 'assistant', uuid => $u2, parentUuid => $u1,
        sessionId => $old, cwd => $cwd, timestamp => ts(4),
        message => { role => 'assistant', content => [ { type => 'text', text => 'ok, understood.' } ] } });
    push @lines, $JSON->encode({ type => 'attachment', uuid => $u3, parentUuid => $u2,
        sessionId => $old, timestamp => ts(5),
        snapshot => { workingDirectory => $cwd, scratchpadDirectory => "/tmp/claude/$old/scratchpad" } });
    push @lines, $JSON->encode({ type => 'last-prompt', lastPrompt => $msg, leafUuid => $u3,
        sessionId => $old, timestamp => ts(6) });
    push @lines, $JSON->encode({ type => 'ai-title', title => 'Fix the login bug',
        sessionId => $old, timestamp => ts(7) });

    my $bytes = join('', map { "$_\n" } @lines);
    my $malformed = qq({"type":"broken", "sessionId") . "\n";   # complete (has \n), NOT valid JSON, contains "sessionId"
    $bytes .= $malformed;
    my $complete_count = scalar(@lines) + 1;

    my $fragment = qq({"type":"user","sessionId":"$old","incomplete);   # NO trailing \n
    $bytes .= $fragment;

    write_raw($path, $bytes);
    return { old => $old, u1 => $u1, u2 => $u2, u3 => $u3, msg => $msg, cwd => $cwd,
             complete_count => $complete_count, malformed_line => $malformed };
}

# complete_lines($bytes) -> \@lines (each WITHOUT its \n, in order), dropping
# a final unterminated fragment if present. Mirrors spec S2.1 step 5's own
# rule so the oracle and the implementation agree on what "a line" means.
sub complete_lines {
    my ($bytes) = @_;
    return [] unless defined $bytes && length $bytes;
    my @out;
    my $pos = 0;
    while (1) {
        my $nl = index($bytes, "\n", $pos);
        last if $nl < 0;
        push @out, substr($bytes, $pos, $nl - $pos);
        $pos = $nl + 1;
    }
    return \@out;
}

# ----------------------------------------------------------------------------
# select-session.pl subprocess helpers -- mirror session-picker-cards.t's
# run_capture()/run_picker_output_content(), plus Decision 15's env
# localisation (HOME/USERPROFILE/CLAUDE_CONFIG_DIR -> a fresh temp dir for
# every spawn, so nothing this file runs can ever touch the real ~/.claude).
# ----------------------------------------------------------------------------
sub run_select {
    my (@argv) = @_;
    my %opt = (ref $argv[-1] eq 'HASH') ? %{ pop @argv } : ();
    local $ENV{HOME}              = tempdir(CLEANUP => 1);
    local $ENV{USERPROFILE}       = $ENV{HOME};
    local $ENV{CLAUDE_CONFIG_DIR} = $ENV{HOME};
    # out/err capture files ALWAYS live in their own fresh scratch dir --
    # never inside $opt{workdir} (which some callers deliberately point at a
    # sandbox dir that does not exist yet, e.g. AC-22's missing --sessions-dir
    # case; a tempfile() there would fail before the child even ran).
    my $scratch = tempdir(CLEANUP => 1);
    my (undef, $out_file) = tempfile(DIR => $scratch, SUFFIX => '.out');
    my (undef, $err_file) = tempfile(DIR => $scratch, SUFFIX => '.err');
    my $cmd = join(' ', qq("$^X"), qq("$SCRIPT"), @argv);
    open my $p, "| $cmd >\"$out_file\" 2>\"$err_file\"" or die "run_select: open pipe failed: $!";
    print $p ($opt{input} // '');
    close $p;
    my $rc = $? >> 8;
    my $slurp = sub {
        my ($f) = @_;
        my $s = slurp($f);
        return defined $s ? $s : '';
    };
    return { rc => $rc, stdout => $slurp->($out_file), stderr => $slurp->($err_file) };
}

sub list_json {
    my (%a) = @_;
    my @argv = ('--sessions-dir', $a{sessions_dir});
    push @argv, '--host-sessions-dir', $a{host_sessions_dir} if defined $a{host_sessions_dir};
    push @argv, '--blueprints-dir', $a{blueprints_dir} if defined $a{blueprints_dir};
    push @argv, '--project-label', $a{project_label} if defined $a{project_label};
    push @argv, '--list-json';
    my $r = run_select(@argv, { workdir => $a{sessions_dir} });
    my $data = eval { JSON::PP->new->utf8->decode($r->{stdout}) };
    return { rc => $r->{rc}, stdout => $r->{stdout}, stderr => $r->{stderr}, data => $data };
}

sub run_output_action {
    my (%a) = @_;
    my $dir = $a{sessions_dir};
    my (undef, $out) = tempfile(DIR => $dir, SUFFIX => '.action');
    my @argv = ('--sessions-dir', $dir, '--output', $out);
    push @argv, '--host-sessions-dir', $a{host_sessions_dir} if defined $a{host_sessions_dir};
    push @argv, '--blueprints-dir', $a{blueprints_dir} if defined $a{blueprints_dir};
    my $r = run_select(@argv, { input => $a{input} // '', workdir => $dir });
    my $content = slurp($out);
    $content =~ s/\r?\n\z// if defined $content;
    $r->{content} = $content;
    return $r;
}

sub write_registry {
    my (@uuids) = @_;
    my $reg_root = tempdir(CLEANUP => 1);
    make_path("$reg_root/bp-e2e/runs");
    my $i = 0;
    my @entries = map { $i++; qq("pkg$i":{"session_id":"$_"}) } @uuids;
    write_raw("$reg_root/bp-e2e/runs/registry.json",
        '{"packages":{' . join(',', @entries) . '}}');
    return $reg_root;
}

# ============================================================================
# AC-14: encode_project_path / host_sessions_dir -- pure, no fixtures needed
# ============================================================================
criterion('AC-14: encode_project_path -- every character outside [A-Za-z0-9] becomes one dash (two for U+FFFF+, none observed here)', sub {
    is(SessionFork::encode_project_path('C:/Work/demo'),  'C--Work-demo', 'AC-14: C:/Work/demo');
    is(SessionFork::encode_project_path('C:\\Work\\demo'), 'C--Work-demo', 'AC-14: C:\\Work\\demo (identical to the / form)');
    is(SessionFork::encode_project_path('/home/u/my proj'), '-home-u-my-proj', 'AC-14: /home/u/my proj');
    is(SessionFork::encode_project_path("C:/Users/Zo\x{eb}/p"), 'C--Users-Zo--p', 'AC-14: a non-ASCII path component');
    is(SessionFork::encode_project_path('/project'), '-project', 'AC-14: /project');
    is(SessionFork::encode_project_path(undef), '', 'AC-14: undef in gives \'\' out');
    is(SessionFork::encode_project_path(''), '', 'AC-14: empty in gives \'\' out');
    is(SessionFork::host_sessions_dir('/x/.claude', 'C:/Work/demo'), '/x/.claude/projects/C--Work-demo',
        'AC-14: host_sessions_dir joins claude_config_dir/projects/<encoded>');
});

# ============================================================================
# AC-2/AC-3/AC-4/AC-9/AC-10/AC-11/AC-12/AC-13: the core fork, exercised
# directly against SessionFork::fork_session (in-process, no subprocess).
# ============================================================================
my ($HOST1_DIR, $SBX1_DIR, $HOST1_FILE, $M1);
criterion('fixture setup: HOST1 (typed human session) + a fresh sandbox dir', sub {
    $HOST1_DIR  = accent_dir($HOST_TAG);
    $SBX1_DIR   = accent_dir($SANDBOX_TAG) . '/projects/-project';
    $HOST1_FILE = "$HOST1_DIR/aaaaaaaa-0000-4000-8000-000000000001.jsonl";
    $M1 = build_host_transcript($HOST1_FILE, old => 'aaaaaaaa-0000-4000-8000-000000000001',
        cwd => 'C:\\Users\\host\\proj', msg => 'please fix the login bug');
    ok(-f $HOST1_FILE, 'fixture: HOST1 transcript file exists');
});

my $BEFORE1 = stat_sig($HOST1_FILE);
my ($NEW1, $ERR1);
criterion('AC-2: fork_session returns a fresh, lowercase, v4 uuid distinct from the host id; the transcript exists; no tmp remains', sub {
    ($NEW1, $ERR1) = SessionFork::fork_session($HOST1_FILE, $SBX1_DIR);
    is($ERR1, undef, 'AC-2: fork_session on a valid host file returns no error') or diag("error: " . ($ERR1 // 'undef'));
    ok(defined($NEW1) && SessionFork::is_uuid($NEW1), 'AC-2: the returned id is is_uuid-shaped') or return;
    is($NEW1, lc($NEW1), 'AC-2: the returned id is lowercase');
    isnt($NEW1, $M1->{old}, 'AC-2: the returned id differs from the host id');
    my @parts = split /-/, $NEW1;
    like($parts[2], qr/^4/, 'AC-2: the version nibble (3rd group) starts with 4');
    like($parts[3], qr/^[89ab]/i, 'AC-2: the variant nibble (4th group) starts with 8/9/a/b');
    ok(-f "$SBX1_DIR/$NEW1.jsonl", 'AC-2: the new transcript file exists in the sandbox dir');
    opendir(my $dh, $SBX1_DIR) or die "opendir $SBX1_DIR: $!";
    my @tmp = grep { /^\.fork-/ } readdir($dh);
    closedir $dh;
    is(scalar(@tmp), 0, 'AC-2: no .fork-* tmp file remains after a successful fork');
});

criterion('AC-3: every fork record that HAD a top-level sessionId now has $new; none equal the old id; records without one still lack it', sub {
    ok(defined $NEW1, 'AC-3 precondition: AC-2 produced a new id') or return;
    my $fork_lines = complete_lines(slurp("$SBX1_DIR/$NEW1.jsonl"));
    my ($checked, $bad_new, $bad_old, $fhs_has_sid) = (0, 0, 0, 0);
    for my $line (@$fork_lines) {
        my $rec = eval { JSON::PP->new->utf8->decode($line) };
        next unless ref $rec eq 'HASH';
        $checked++;
        if (exists $rec->{sessionId}) {
            $bad_new++ unless defined($rec->{sessionId}) && $rec->{sessionId} eq $NEW1;
            $bad_old++ if defined($rec->{sessionId}) && $rec->{sessionId} eq $M1->{old};
        }
        if (($rec->{type} // '') eq 'file-history-snapshot') {
            $fhs_has_sid++ if exists $rec->{sessionId};
        }
    }
    cmp_ok($checked, '>', 0, 'AC-3: at least one fork record was decodable');
    is($bad_new, 0, 'AC-3: every record with a sessionId now has exactly $new');
    is($bad_old, 0, 'AC-3: no top-level sessionId anywhere still equals the old id');
    is($fhs_has_sid, 0, 'AC-3: the file-history-snapshot record still has no sessionId');
});

criterion('AC-4: the host transcript is byte-identical and its mtime is unchanged after a successful fork', sub {
    my $after = stat_sig($HOST1_FILE);
    is($after, $BEFORE1, 'AC-4: host file sha256+mtime signature unchanged after fork_session');
});

criterion('AC-10: resume-compat byte level -- same complete-line count, fragment absent, malformed line byte-identical, and undoing the two rewrites reproduces the source bytes exactly', sub {
    ok(defined $NEW1, 'AC-10 precondition') or return;
    my $src_lines  = complete_lines(slurp($HOST1_FILE));
    my $fork_lines = complete_lines(slurp("$SBX1_DIR/$NEW1.jsonl"));
    is(scalar(@$fork_lines), $M1->{complete_count}, 'AC-10: the fork has exactly as many lines as the source has COMPLETE lines');
    is(scalar(@$fork_lines), scalar(@$src_lines), 'AC-10: fork line count equals source complete-line count (fragment absent)');

    my $malformed_stripped = $M1->{malformed_line};
    $malformed_stripped =~ s/\n\z//;
    my ($found_malformed) = grep { $_ eq $malformed_stripped } @$fork_lines;
    is($found_malformed, $malformed_stripped, 'AC-10: the malformed line survives byte-identical in the fork');

    my $bad = 0;
    for my $i (0 .. $#$fork_lines) {
        my $fline = $fork_lines->[$i];
        my $sline = $src_lines->[$i];
        next if $fline eq $malformed_stripped;   # the one line never touched, checked above
        (my $undone = $fline) =~ s/"sessionId":"\Q$NEW1\E"/"sessionId":"$M1->{old}"/;
        $undone =~ s/"cwd":"\/project"/'"cwd":"' . _json_escape($M1->{cwd}) . '"'/e;
        $bad++ unless $undone eq $sline;
    }
    is($bad, 0, 'AC-10: undoing the sessionId/cwd rewrites reproduces every source line exactly');
});
sub _json_escape { my ($s) = @_; (my $t = $s) =~ s/\\/\\\\/g; $t; }

criterion('AC-11: resume-compat structure -- every decodable fork record deep-equals its source after deleting sessionId/cwd; every fork cwd is /project; nested paths/ids are untouched', sub {
    ok(defined $NEW1, 'AC-11 precondition') or return;
    my $src_lines  = complete_lines(slurp($HOST1_FILE));
    my $fork_lines = complete_lines(slurp("$SBX1_DIR/$NEW1.jsonl"));
    my ($mismatches, $cwd_bad, $decoded) = (0, 0, 0);
    for my $i (0 .. $#$fork_lines) {
        my $frec = eval { JSON::PP->new->utf8->decode($fork_lines->[$i]) };
        my $srec = eval { JSON::PP->new->utf8->decode($src_lines->[$i]) };
        next unless ref $frec eq 'HASH' && ref $srec eq 'HASH';
        $decoded++;
        if (exists $frec->{cwd} && defined($frec->{cwd}) && !ref($frec->{cwd})) {
            $cwd_bad++ unless $frec->{cwd} eq '/project';
        }
        delete $frec->{sessionId}; delete $srec->{sessionId};
        delete $frec->{cwd};       delete $srec->{cwd};
        $mismatches++ unless _deep_eq($frec, $srec);
    }
    cmp_ok($decoded, '>', 0, 'AC-11: at least one record pair decoded');
    is($mismatches, 0, 'AC-11: every decodable record deep-equals its source (aside from sessionId/cwd)');
    is($cwd_bad, 0, 'AC-11: every fork top-level string cwd is exactly /project');

    my $att = eval { JSON::PP->new->utf8->decode((grep { index($_, '"attachment"') >= 0 } @$fork_lines)[0]) };
    ok(ref $att eq 'HASH', 'AC-11: the attachment record decodes') or return;
    is($att->{snapshot}{workingDirectory}, $M1->{cwd}, 'AC-11: nested workingDirectory is UNCHANGED (still the old host path)');
    is($att->{snapshot}{scratchpadDirectory}, "/tmp/claude/$M1->{old}/scratchpad",
        'AC-11: nested scratchpadDirectory is UNCHANGED (still carries the OLD session id)');
});
sub _deep_eq {
    my ($a, $b) = @_;
    return JSON::PP->new->canonical->encode($a) eq JSON::PP->new->canonical->encode($b);
}

criterion('AC-12: resume-compat chain -- the set of uuids is identical, and every non-null parentUuid / leafUuid names a uuid present in the fork', sub {
    ok(defined $NEW1, 'AC-12 precondition') or return;
    my $src_lines  = complete_lines(slurp($HOST1_FILE));
    my $fork_lines = complete_lines(slurp("$SBX1_DIR/$NEW1.jsonl"));
    my (%src_uuids, %fork_uuids, @parents, @leafs);
    for my $l (@$src_lines) {
        my $r = eval { JSON::PP->new->utf8->decode($l) };
        next unless ref $r eq 'HASH';
        $src_uuids{$r->{uuid}} = 1 if defined $r->{uuid};
    }
    for my $l (@$fork_lines) {
        my $r = eval { JSON::PP->new->utf8->decode($l) };
        next unless ref $r eq 'HASH';
        $fork_uuids{$r->{uuid}} = 1 if defined $r->{uuid};
        push @parents, $r->{parentUuid} if defined $r->{parentUuid};
        push @leafs,   $r->{leafUuid}   if defined $r->{leafUuid};
    }
    is_deeply([ sort keys %fork_uuids ], [ sort keys %src_uuids ], 'AC-12: the SET of uuids is identical between source and fork');
    my $bad_parent = grep { !exists $fork_uuids{$_} } @parents;
    my $bad_leaf   = grep { !exists $fork_uuids{$_} } @leafs;
    is($bad_parent, 0, 'AC-12: every non-null parentUuid names a uuid present in the fork');
    is($bad_leaf, 0, 'AC-12: every leafUuid names a uuid present in the fork');
});

criterion('AC-13: resume-compat listability -- SessionIndex::index_file(fork) gives listable 1, id $new, kind human, first_typed equal to the source\'s', sub {
    ok(defined $NEW1, 'AC-13 precondition') or return;
    my $src_entry  = SessionIndex::index_file($HOST1_FILE);
    my $fork_entry = SessionIndex::index_file("$SBX1_DIR/$NEW1.jsonl");
    ok(ref $fork_entry eq 'HASH', 'AC-13: index_file decodes the fork') or return;
    is($fork_entry->{listable}, 1, 'AC-13: the fork is listable');
    is($fork_entry->{id}, $NEW1, 'AC-13: the fork\'s id is the new uuid (from its filename)');
    is($fork_entry->{kind}, 'human', 'AC-13: the fork classifies as human');
    is($fork_entry->{first_typed}, $src_entry->{first_typed}, 'AC-13: first_typed is unchanged from the source');
});

# ============================================================================
# AC-9: forking the same host session twice
# ============================================================================
criterion('AC-9: two fork_session calls on the same host file give distinct uuids, two transcripts, two sidecars; a later write to fork A never touches fork B', sub {
    my ($newA, $errA) = SessionFork::fork_session($HOST1_FILE, $SBX1_DIR);
    my ($newB, $errB) = SessionFork::fork_session($HOST1_FILE, $SBX1_DIR);
    is($errA, undef, 'AC-9: first fork succeeds') or return;
    is($errB, undef, 'AC-9: second fork succeeds') or return;
    isnt($newA, $newB, 'AC-9: the two forks get distinct uuids');
    ok(-f "$SBX1_DIR/$newA.jsonl" && -f "$SBX1_DIR/$newB.jsonl", 'AC-9: both transcripts exist');
    ok(-f "$SBX1_DIR/$newA.ccpraxis-fork.json" && -f "$SBX1_DIR/$newB.ccpraxis-fork.json", 'AC-9: both sidecars exist');
    my $sigB_before = stat_sig("$SBX1_DIR/$newB.jsonl");
    open(my $fh, '>>:raw', "$SBX1_DIR/$newA.jsonl") or die $!;
    print {$fh} $JSON->encode({ type => 'user', uuid => 'deadbeef-0000-0000-0000-000000000009',
        sessionId => $newA, message => { role => 'user', content => 'appended after the fact' } }) . "\n";
    close $fh;
    is(stat_sig("$SBX1_DIR/$newB.jsonl"), $sigB_before, 'AC-9: appending to fork A leaves fork B\'s bytes unchanged');
});

# ============================================================================
# AC-16/AC-17/AC-18/AC-19: failure paths -- nothing left behind
# ============================================================================
criterion('AC-16: an unreadable source (nonexistent path, or a directory) fails cleanly and creates nothing', sub {
    my $sbx = accent_dir($SANDBOX_TAG);
    my ($u1, $e1) = SessionFork::fork_session("$HOST1_DIR/does-not-exist.jsonl", $sbx);
    is($u1, undef, 'AC-16: a nonexistent host file returns undef');
    ok(length($e1 // ''), 'AC-16: a nonexistent host file returns a non-empty error');
    my ($u2, $e2) = SessionFork::fork_session($HOST1_DIR, $sbx);   # a directory, not a file
    is($u2, undef, 'AC-16: a directory (not a regular file) returns undef');
    ok(length($e2 // ''), 'AC-16: a directory as source returns a non-empty error');
    opendir(my $dh, $sbx) or die $!;
    my @files = grep { !/^\.\.?$/ } readdir($dh);
    closedir $dh;
    is(scalar(@files), 0, 'AC-16: the sandbox dir gains no file from either failure');
});

criterion('AC-17: a simulated disk-full write failure leaves no tmp, no new transcript, no new sidecar', sub {
    my $host = "$HOST1_DIR/bbbbbbbb-0000-4000-8000-000000000002.jsonl";
    build_host_transcript($host, old => 'bbbbbbbb-0000-4000-8000-000000000002');
    my $host_sig_before = stat_sig($host);
    my $sbx = accent_dir($SANDBOX_TAG);
    local $SessionFork::WRITE_LIMIT = 100;
    my ($u, $e) = SessionFork::fork_session($host, $sbx);
    is($u, undef, 'AC-17: fork_session fails under a simulated disk-full write limit');
    like($e // '', qr/write failed/, 'AC-17: the error mentions "write failed"');
    opendir(my $dh, $sbx) or die $!;
    my @files = grep { !/^\.\.?$/ } readdir($dh);
    closedir $dh;
    is(scalar(@files), 0, 'AC-17: no .fork-*, no *.jsonl, no sidecar remains in the sandbox dir');
    is(stat_sig($host), $host_sig_before, 'S3 (review): the host fixture file is byte-identical (sha256+mtime) after the disk-full failure');
});

criterion('AC-18: id collision -- retries past an occupied uuid; exhausting all attempts fails cleanly', sub {
    my $host = "$HOST1_DIR/cccccccc-0000-4000-8000-000000000003.jsonl";
    build_host_transcript($host, old => 'cccccccc-0000-4000-8000-000000000003');
    my $host_sig_before = stat_sig($host);
    my $sbx = accent_dir($SANDBOX_TAG);
    my $existing = 'dddddddd-1111-4111-8111-111111111111';
    my $fresh    = 'eeeeeeee-2222-4222-8222-222222222222';
    write_raw("$sbx/$existing.jsonl", "{}\n");
    my $before_existing = stat_sig("$sbx/$existing.jsonl");
    {
        my @seq = ($existing, $fresh);
        local $SessionFork::UUID_GEN = sub { shift @seq };
        my ($u, $e) = SessionFork::fork_session($host, $sbx);
        is($u, $fresh, 'AC-18: fork_session skips the occupied uuid and uses the fresh one') or diag("error: " . ($e // 'undef'));
    }
    is(stat_sig("$sbx/$existing.jsonl"), $before_existing, 'AC-18: the pre-existing occupied file is byte-unchanged');
    {
        local $SessionFork::UUID_GEN = sub { $existing };   # always occupied
        my ($u, $e) = SessionFork::fork_session($host, $sbx);
        is($u, undef, 'AC-18: exhausting all attempts on an always-occupied id returns undef');
        ok(length($e // ''), 'AC-18: exhausting all attempts returns a non-empty error');
    }
    is(stat_sig($host), $host_sig_before, 'S3 (review): the host fixture file is byte-identical (sha256+mtime) after AC-18\'s failures (both branches)');
});

criterion('AC-19: an empty host file, or one with only an unterminated fragment, fails with an "empty" error and creates nothing', sub {
    my $sbx1 = accent_dir($SANDBOX_TAG);
    my $empty_host = "$HOST1_DIR/f0000000-0000-4000-8000-000000000000.jsonl";
    write_raw($empty_host, '');
    my $empty_sig_before = stat_sig($empty_host);
    my ($u1, $e1) = SessionFork::fork_session($empty_host, $sbx1);
    is($u1, undef, 'AC-19: a zero-byte host file returns undef');
    like($e1 // '', qr/empty/i, 'AC-19: the error mentions "empty"');
    is(stat_sig($empty_host), $empty_sig_before, 'S3 (review): the zero-byte host fixture is byte-identical (sha256+mtime) after the failure');

    my $sbx2 = accent_dir($SANDBOX_TAG);
    my $frag_host = "$HOST1_DIR/f1111111-0000-4000-8000-000000000000.jsonl";
    write_raw($frag_host, '{"type":"user","sessionId":"x","no newline here');
    my $frag_sig_before = stat_sig($frag_host);
    my ($u2, $e2) = SessionFork::fork_session($frag_host, $sbx2);
    is($u2, undef, 'AC-19: a file with only a trailing fragment (no complete line) returns undef');
    like($e2 // '', qr/empty/i, 'AC-19: the fragment-only error also mentions "empty"');
    is(stat_sig($frag_host), $frag_sig_before, 'S3 (review): the fragment-only host fixture is byte-identical (sha256+mtime) after the failure');

    for my $sbx ($sbx1, $sbx2) {
        opendir(my $dh, $sbx) or die $!;
        my @files = grep { !/^\.\.?$/ } readdir($dh);
        closedir $dh;
        is(scalar(@files), 0, "AC-19: $sbx gains no file from either empty-source failure");
    }
});

# ============================================================================
# AC-8: read_provenance
# ============================================================================
criterion('AC-8: read_provenance returns source_session_id + a well-formed forked_at for a real fork, and undef for a native (non-forked) session', sub {
    ok(defined $NEW1, 'AC-8 precondition (AC-2 fork exists)') or return;
    my $prov = SessionFork::read_provenance($SBX1_DIR, $NEW1);
    ok(ref $prov eq 'HASH', 'AC-8: read_provenance returns a hashref for a real fork') or return;
    is($prov->{source_session_id}, $M1->{old}, 'AC-8: source_session_id is the host uuid');
    like($prov->{forked_at}, qr/\A\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ\z/, 'AC-8: forked_at matches the documented UTC ISO-8601 shape');

    my $native_dir = accent_dir($SANDBOX_TAG);
    write_raw("$native_dir/facefeed-0000-4000-8000-000000000000.jsonl",
        $JSON->encode({ type => 'user', sessionId => 'facefeed-0000-4000-8000-000000000000',
                        message => { role => 'user', content => 'native session, never forked' } }) . "\n");
    is(SessionFork::read_provenance($native_dir, 'facefeed-0000-4000-8000-000000000000'), undef,
        'AC-8: read_provenance of a native (non-forked) session is undef');
});

# ============================================================================
# AC-15: non-ASCII end to end (done criterion 5)
# ============================================================================
criterion('AC-15: non-ASCII host+sandbox dir names and non-ASCII message text survive listing, forking, and the byte-level compat check', sub {
    my $host_dir = accent_dir($HOST_TAG);
    my $sbx_dir  = accent_dir($SANDBOX_TAG) . '/projects/-project';
    my $EB_BYTES = Encode_leaf("\x{eb}");   # the UTF-8 bytes for the accented char, not the codepoint
    my $EA_BYTES = Encode_leaf("\x{e3}");
    cmp_ok(index($host_dir, $EB_BYTES), '>=', 0, 'AC-15 precondition: the host dir name really contains the accented character (UTF-8 bytes)');
    cmp_ok(index($sbx_dir,  $EA_BYTES), '>=', 0, 'AC-15 precondition: the sandbox dir name really contains the accented character (UTF-8 bytes)');

    my $old = 'accccccc-0000-4000-8000-000000000000';
    my $msg = "corre\x{e7}\x{e3}o de bug: \x{e9}poque errada";   # "ção" + "é"
    my $host_file = "$host_dir/$old.jsonl";
    my $meta = build_host_transcript($host_file, old => $old, msg => $msg);

    my $listing = list_json(sessions_dir => $sbx_dir, host_sessions_dir => $host_dir);
    ok(ref $listing->{data} eq 'HASH', 'AC-15: --list-json decodes with a non-ASCII host dir') or return;
    my @host_rows = grep { ($_->{origin} // '') eq 'host' } @{ aref($listing->{data}{sessions}) };
    is(scalar(@host_rows), 1, 'AC-15: exactly one host row is listed');
    is($host_rows[0]{card}{first}, $msg, 'AC-15: the card\'s "first" field round-trips the non-ASCII text exactly');

    my ($new, $err) = SessionFork::fork_session($host_file, $sbx_dir);
    is($err, undef, 'AC-15: fork_session succeeds with non-ASCII dir names') or return;
    ok(SessionFork::is_uuid($new // ''), 'AC-15: the resulting id is still is_uuid-shaped');

    my $src_lines  = complete_lines(slurp($host_file));
    my $fork_lines = complete_lines(slurp("$sbx_dir/$new.jsonl"));
    is(scalar(@$fork_lines), $meta->{complete_count}, 'AC-15: the fork\'s line count matches the source\'s complete-line count');
    my $user_line = (grep { index($_, '"type":"user"') >= 0 && index($_, $old) < 0 } @$fork_lines)[0];
    ok(defined $user_line, 'AC-15: the rewritten user record is present') or return;
    # $user_line is raw UTF-8 BYTES (slurped :raw). $msg is a Perl character
    # string, so comparing it directly against raw bytes never matches --
    # encode $msg to UTF-8 bytes first so byte compares byte (Decision 33).
    require Encode;
    my $msg_bytes = Encode::encode('UTF-8', $msg);
    like($user_line, qr/\Q$msg_bytes\E/, 'AC-15: the non-ASCII message text is byte-identical in the fork');
});

# ============================================================================
# AC-1 / AC-6 / AC-7 / AC-21 / AC-22 / AC-26: select-session.pl --list-json,
# exercised as a real subprocess (the merge/badge/origin logic lives in the
# script's main flow, not in an exported sub).
# ============================================================================
my ($HOST2_DIR, $SBX2_DIR, $HOST2_UUID, $SBX2_NATIVE_UUID);
criterion('fixture setup: HOST2 (one host session) + SBX2 (one native sandbox session)', sub {
    $HOST2_DIR = accent_dir($HOST_TAG);
    $SBX2_DIR  = accent_dir($SANDBOX_TAG) . '/projects/-project';
    make_path($SBX2_DIR);
    $HOST2_UUID = 'a2000000-0000-4000-8000-000000000000';
    build_host_transcript("$HOST2_DIR/$HOST2_UUID.jsonl", old => $HOST2_UUID, msg => 'a host-side question');
    $SBX2_NATIVE_UUID = 'b2000000-0000-4000-8000-000000000000';
    write_raw("$SBX2_DIR/$SBX2_NATIVE_UUID.jsonl",
        $JSON->encode({ type => 'user', sessionId => $SBX2_NATIVE_UUID, entrypoint => 'cli',
                        message => { role => 'user', content => 'a native sandbox question' } }) . "\n");
    ok(-f "$HOST2_DIR/$HOST2_UUID.jsonl" && -f "$SBX2_DIR/$SBX2_NATIVE_UUID.jsonl", 'fixture: both files exist');
});

criterion('AC-1: --list-json with --host-sessions-dir lists both the host row (origin host, badge [host]/accent) and the sandbox row (origin sandbox, badge [sandbox]/text.muted)', sub {
    my $r = list_json(sessions_dir => $SBX2_DIR, host_sessions_dir => $HOST2_DIR);
    ok(ref $r->{data} eq 'HASH', 'AC-1: --list-json produced decodable JSON') or return;
    my @rows = @{ aref($r->{data}{sessions}) };
    is(scalar(@rows), 2, 'AC-1: exactly 2 rows (one host, one sandbox)') or return;
    my %by_origin = map { ($_->{origin} // '?') => $_ } @rows;
    ok(exists $by_origin{host},    'AC-1: a host row is present');
    ok(exists $by_origin{sandbox}, 'AC-1: a sandbox row is present');
    is_deeply($by_origin{host}{card}{badges},    [ { text => 'host',    role => 'accent'     } ], 'AC-1: the host row carries exactly the [host]/accent badge');
    is_deeply($by_origin{sandbox}{card}{badges}, [ { text => 'sandbox', role => 'text.muted' } ], 'AC-1: the sandbox row carries exactly the [sandbox]/text.muted badge');
});

criterion('AC-21 (no regression): without --host-sessions-dir, every row\'s origin is in {sandbox,fork} and every badges list is empty', sub {
    my $r = list_json(sessions_dir => $SBX2_DIR);
    ok(ref $r->{data} eq 'HASH', 'AC-21: --list-json (no host dir) produced decodable JSON') or return;
    my @rows = @{ aref($r->{data}{sessions}) };
    cmp_ok(scalar(@rows), '>', 0, 'AC-21: at least one row is listed');
    my $bad_origin = grep { !defined($_->{origin}) || ($_->{origin} ne 'sandbox' && $_->{origin} ne 'fork') } @rows;
    is($bad_origin, 0, 'AC-21: every row\'s origin is sandbox or fork (never host)');
    my $bad_badges = grep { ref($_->{card}{badges}) ne 'ARRAY' || @{$_->{card}{badges}} } @rows;
    is($bad_badges, 0, 'AC-21: every row\'s card.badges is []');
});

criterion('AC-22: a NONEXISTENT --sessions-dir with --host-sessions-dir given gives error null and still lists the host rows', sub {
    my $missing_sbx = accent_dir($SANDBOX_TAG) . '/projects/-project-does-not-exist-yet';
    my $r = list_json(sessions_dir => $missing_sbx, host_sessions_dir => $HOST2_DIR);
    ok(ref $r->{data} eq 'HASH', 'AC-22: --list-json produced decodable JSON even with a missing sandbox dir') or return;
    is($r->{data}{error}, undef, 'AC-22: error is null when the sandbox sessions dir simply does not exist yet');
    my @host_rows = grep { ($_->{origin} // '') eq 'host' } @{ aref($r->{data}{sessions}) };
    is(scalar(@host_rows), 1, 'AC-22: the host row is still listed');
});

criterion('AC-26: a host session registered as butler lists is_butler 1, and so does its fork', sub {
    my $reg = write_registry($HOST2_UUID);
    my $r = list_json(sessions_dir => $SBX2_DIR, host_sessions_dir => $HOST2_DIR, blueprints_dir => $reg);
    ok(ref $r->{data} eq 'HASH', 'AC-26: --list-json with --blueprints-dir produced decodable JSON') or return;
    my @rows = @{ aref($r->{data}{sessions}) };
    my ($host_row) = grep { ($_->{origin} // '') eq 'host' } @rows;
    ok(ref $host_row eq 'HASH', 'AC-26: the host row is present') or return;
    is($host_row->{is_butler}, 1, 'AC-26: the registered host session lists is_butler 1');

    # Sanity check the registry is actually being found at all, independent of
    # fork inheritance: a plain sandbox session registered the same way must
    # also list is_butler 1 under the corrected blueprints_dir root. If this
    # fails, the fixture wiring (not fork inheritance) is at fault.
    my $reg_sbx = write_registry($SBX2_NATIVE_UUID);
    my $r_sbx = list_json(sessions_dir => $SBX2_DIR, host_sessions_dir => $HOST2_DIR, blueprints_dir => $reg_sbx);
    ok(ref $r_sbx->{data} eq 'HASH', 'AC-26: --list-json with a sandbox-registered blueprints_dir produced decodable JSON') or return;
    my ($sbx_row) = grep { ($_->{uuid} // '') eq $SBX2_NATIVE_UUID } @{ aref($r_sbx->{data}{sessions}) };
    ok(ref $sbx_row eq 'HASH', 'AC-26: the plain sandbox row is present') or return;
    is($sbx_row->{is_butler}, 1, 'AC-26: a plain sandbox session registered as butler lists is_butler 1 (confirms the registry root is being found)');

    # Fork it (through the real --fork subprocess mode), then list again: the
    # fork inherits is_butler through its provenance's source_session_id.
    my $fork_r = run_select('--sessions-dir', $SBX2_DIR, '--host-sessions-dir', $HOST2_DIR,
        '--fork', $HOST2_UUID, { workdir => $SBX2_DIR });
    my ($new) = ($fork_r->{stdout} =~ /\ARESUME\s+([0-9a-f-]{36})\s*\z/i);
    ok(defined $new, 'AC-26: --fork produced a RESUME token') or return;
    my $r2 = list_json(sessions_dir => $SBX2_DIR, host_sessions_dir => $HOST2_DIR, blueprints_dir => $reg);
    my ($fork_row) = grep { ($_->{uuid} // '') eq $new } @{ aref($r2->{data}{sessions}) };
    ok(ref $fork_row eq 'HASH', 'AC-26: the fork row is present in the next listing') or return;
    is($fork_row->{is_butler}, 1, 'AC-26: the fork also lists is_butler 1 (inherited via source_session_id)');
});

criterion('AC-7: after a fork, --list-json shows the fork row with the "duplicated from host <8hex>" badge, and the host row still carries [host]', sub {
    my $r = list_json(sessions_dir => $SBX2_DIR, host_sessions_dir => $HOST2_DIR);
    ok(ref $r->{data} eq 'HASH', 'AC-7: --list-json decodes') or return;
    my @rows = @{ aref($r->{data}{sessions}) };
    my ($host_row) = grep { ($_->{origin} // '') eq 'host' && $_->{uuid} eq $HOST2_UUID } @rows;
    ok(ref $host_row eq 'HASH', 'AC-7: the host original is still present') or return;
    is_deeply($host_row->{card}{badges}, [ { text => 'host', role => 'accent' } ], 'AC-7: the host row still carries [host]/accent');
    my @fork_rows = grep { ($_->{origin} // '') eq 'fork' } @rows;
    cmp_ok(scalar(@fork_rows), '>', 0, 'AC-7: at least one fork row is now listed') or return;
    my $expect_badge = { text => 'duplicated from host ' . substr(lc($HOST2_UUID), 0, 8), role => 'state.ok' };
    my ($matching) = grep { ref($_->{card}{badges}[0]) eq 'HASH' && $_->{card}{badges}[0]{text} eq $expect_badge->{text} } @fork_rows;
    ok(ref $matching eq 'HASH', 'AC-7: one fork row carries exactly the "duplicated from host <8hex>" badge text') or return;
    is($matching->{card}{badges}[0]{role}, 'state.ok', 'AC-7: that badge\'s role is state.ok');
});

# ============================================================================
# AC-5: the plain (line-prompt) path forks and emits RESUME
# ============================================================================
criterion('AC-5: the plain path (line prompt) can pick a host row, forks it, writes RESUME <new> to --output, and shows [host] in the prompt', sub {
    my $host_dir = accent_dir($HOST_TAG);
    my $sbx_dir  = accent_dir($SANDBOX_TAG) . '/projects/-project';
    make_path($sbx_dir);
    my $host_uuid = 'a5000000-0000-4000-8000-000000000000';
    build_host_transcript("$host_dir/$host_uuid.jsonl", old => $host_uuid, msg => 'oldest host question',
        cwd => 'C:\\Users\\host\\older');
    # A native sandbox session, older than the host row so the host row sorts
    # first (last_active_at desc). Option 1 is always "+ Start a new
    # session" (Decision 33), so the host row is choice [2] in the numbered
    # prompt.
    write_raw("$sbx_dir/b5000000-0000-4000-8000-000000000000.jsonl",
        $JSON->encode({ type => 'user', sessionId => 'b5000000-0000-4000-8000-000000000000', entrypoint => 'cli',
                        timestamp => ts(-1000), message => { role => 'user', content => 'an older native question' } }) . "\n");

    my $r = run_output_action(sessions_dir => $sbx_dir, host_sessions_dir => $host_dir, input => "2\n");
    like(bstr($r->{content}), qr/\ARESUME\s+[0-9a-f-]{36}\z/i, 'AC-5: --output contains exactly RESUME <uuid>')
        or diag("stdout=<$r->{stdout}> stderr=<$r->{stderr}> content=<" . bstr($r->{content}) . ">");
    my ($new) = (bstr($r->{content}) =~ /RESUME\s+([0-9a-f-]{36})/i);
    ok(defined($new) && -f "$sbx_dir/$new.jsonl", 'AC-5: the forked transcript exists in the sandbox dir') if defined $new;
    like($r->{stderr}, qr/\[host\]/, 'AC-5: the line prompt shows [host] on the host row');
});

# ============================================================================
# AC-6 / AC-20: --fork mode
# ============================================================================
criterion('AC-6: --fork <uuid> prints exactly RESUME <new>\\n on stdout, exit 0, and both files exist before the process returns', sub {
    my $host_dir = accent_dir($HOST_TAG);
    my $sbx_dir  = accent_dir($SANDBOX_TAG) . '/projects/-project';
    make_path($sbx_dir);
    my $host_uuid = 'a6000000-0000-4000-8000-000000000000';
    build_host_transcript("$host_dir/$host_uuid.jsonl", old => $host_uuid);
    my $r = run_select('--sessions-dir', $sbx_dir, '--host-sessions-dir', $host_dir, '--fork', $host_uuid,
        { workdir => $sbx_dir });
    is($r->{rc}, 0, 'AC-6: --fork exits 0') or diag("stderr: $r->{stderr}");
    like($r->{stdout}, qr/\ARESUME [0-9a-f-]{36}\n\z/i, 'AC-6: stdout is EXACTLY "RESUME <new>\\n"') or return;
    my ($new) = ($r->{stdout} =~ /RESUME ([0-9a-f-]{36})/i);
    ok(-f "$sbx_dir/$new.jsonl", 'AC-6: the transcript exists');
    ok(-f "$sbx_dir/$new.ccpraxis-fork.json", 'AC-6: the sidecar exists');
});

criterion('AC-20: --fork with a malformed uuid or combined with --list-json is a USAGE error (exit 1); one with no host file is a FORK failure (dedicated exit 3, Decision 33) -- both leave stdout empty and create nothing', sub {
    my $host_dir = accent_dir($HOST_TAG);
    my $sbx_dir  = accent_dir($SANDBOX_TAG) . '/projects/-project';
    make_path($sbx_dir);

    for my $bad_uuid ('not-a-uuid', '../x') {
        my $r = run_select('--sessions-dir', $sbx_dir, '--host-sessions-dir', $host_dir, '--fork', $bad_uuid,
            { workdir => $sbx_dir });
        is($r->{rc}, 1, "AC-20: --fork $bad_uuid (usage error) exits 1");
        is($r->{stdout}, '', "AC-20: --fork $bad_uuid leaves stdout empty");
    }

    # A well-formed uuid with no host file is a FORK failure, not a usage
    # error: Decision 33 gives it the dedicated FORK_FAILED_EXIT (3) so the
    # launcher can distinguish "retry the picker" from "usage error, do not
    # retry".
    my $well_formed_but_missing = 'ffffffff-0000-4000-8000-000000000000';
    my $r2 = run_select('--sessions-dir', $sbx_dir, '--host-sessions-dir', $host_dir, '--fork', $well_formed_but_missing,
        { workdir => $sbx_dir });
    is($r2->{rc}, 3, 'AC-20/Decision-33: --fork with a well-formed uuid but no host file exits the dedicated FORK_FAILED_EXIT (3)');
    is($r2->{stdout}, '', 'AC-20: that case also leaves stdout empty');

    my $r3 = run_select('--sessions-dir', $sbx_dir, '--host-sessions-dir', $host_dir, '--fork', $well_formed_but_missing,
        '--list-json', { workdir => $sbx_dir });
    is($r3->{rc}, 1, 'AC-20: --fork combined with --list-json exits 1 (usage error)');

    opendir(my $dh, $sbx_dir) or die $!;
    my @files = grep { !/^\.\.?$/ } readdir($dh);
    closedir $dh;
    is(scalar(@files), 0, 'AC-20: nothing was created in the sandbox dir across any of these failures');
});

# ============================================================================
# AC-23 / AC-24: tui::LaunchScreens pure functions
# ============================================================================
criterion('AC-23: session_pick_model gives a host row item id "host:<uuid>" and every other row keeps its bare uuid', sub {
    my $model = tui::LaunchScreens::session_pick_model(
        [ { origin => 'host', uuid => 'aaaaaaaa-0000-0000-0000-000000000001', mtime => 1, is_butler => 0, card => {} },
          { origin => 'sandbox', uuid => 'bbbbbbbb-0000-0000-0000-000000000002', mtime => 2, is_butler => 0, card => {} } ],
        'resume a session - proj', undef);
    ok(ref $model eq 'HASH', 'AC-23: session_pick_model returns a hashref') or return;
    my @items = @{ aref($model->{items}) };
    my ($host_item)    = grep { ($_->{display} // '') eq 'aaaaaaaa-0000-0000-0000-000000000001' || (($_->{id} // '') =~ /aaaaaaaa/) } @items;
    my ($sandbox_item) = grep { ($_->{id} // '') eq 'bbbbbbbb-0000-0000-0000-000000000002' } @items;
    ok(ref $host_item eq 'HASH', 'AC-23: a host-row item is present') or return;
    is($host_item->{id}, 'host:aaaaaaaa-0000-0000-0000-000000000001', 'AC-23: the host row\'s item id is "host:<uuid>"');
    ok(ref $sandbox_item eq 'HASH', 'AC-23: a sandbox-row item is present') or return;
    is($sandbox_item->{id}, 'bbbbbbbb-0000-0000-0000-000000000002', 'AC-23: the sandbox row keeps its bare uuid as item id');
});

criterion('AC-24: _card_cache_key differs for two cards identical except badges, so session_card_lines_cached renders each with its own badge', sub {
    tui::LaunchScreens::session_card_cache_clear() if defined &tui::LaunchScreens::session_card_cache_clear;
    my $base = { started => '2026-01-01 10:00', active => '2026-01-01 13:00', ago => '3h ago',
                 first => 'Fix the login bug', last => 'Deployed the fix to prod', kind_label => undef };
    my $host_card = { %$base, badges => [ { text => 'host', role => 'accent' } ] };
    my $fork_card = { %$base, badges => [ { text => 'duplicated from host aaaaaaaa', role => 'state.ok' } ] };
    my $host_lines = tui::LaunchScreens::session_card_lines_cached($host_card, 80, 0);
    my $fork_lines = tui::LaunchScreens::session_card_lines_cached($fork_card, 80, 0);
    my $line1 = sub { my ($lines) = @_; return join('', map { bstr(href($_)->{text}) } @{ aref($lines->[0]) }); };
    isnt($line1->($host_lines), $line1->($fork_lines), 'AC-24: line 1 text differs between the host-badged and fork-badged card (cache does not conflate them)');
});

# ============================================================================
# AC-25: launcher.pl SOURCE-TEXT checks (never require'd/executed -- it
# builds a container image and starts a container). Mirrors launcher-
# screens.t's AC-W convention.
# ============================================================================
criterion('AC-25: launcher.pl source wires SessionFork, passes --host-sessions-dir on both spawns, forks before resuming in the TUI path, and keeps the plain path\'s existing flags', sub {
    my $src = _comment_stripped(bstr(slurp($LAUNCHER)));
    ok(length($src) > 0, 'AC-25 liveness: launcher.pl was read as source text');
    cmp_ok(index($src, 'SessionFork::host_sessions_dir('), '>=', 0,
        'AC-25: launcher.pl calls SessionFork::host_sessions_dir(');
    my $count = 0;
    my $pos = 0;
    while ((my $i = index($src, '--host-sessions-dir', $pos)) >= 0) { $count++; $pos = $i + 1; }
    cmp_ok($count, '>=', 2, 'AC-25: --host-sessions-dir appears at least twice (both spawns)');

    my ($screen_body) = ($src =~ /sub\s+_pick_session_via_screen\s*\{(.*?)\n\}/s);
    ok(defined $screen_body, 'AC-25: _pick_session_via_screen is found in source') or return;
    cmp_ok(index($screen_body, 'host:'), '>=', 0, 'AC-25: _pick_session_via_screen\'s body matches on the "host:" item-id prefix');
    cmp_ok(index($screen_body, "'--fork'"), '>=', 0, 'AC-25: _pick_session_via_screen\'s body spawns select-session.pl with --fork');

    my ($plain_body) = ($src =~ /sub\s+pick_session_action\s*\{(.*?)\n\}/s);
    ok(defined $plain_body, 'AC-25: pick_session_action is found in source') or return;
    for my $flag ('--sessions-dir', '--project-label', '--output') {
        cmp_ok(index($plain_body, $flag), '>=', 0, "AC-25: pick_session_action still passes $flag");
    }
});

# ============================================================================
# Decision 33: launcher.pl returns to the picker ONLY on the picker's own
# dedicated fork-failed exit code, bounded to at most 3 retries -- never on
# a generic "any other non-zero exit" condition (which would let a picker
# that crashes on every run loop the launcher forever). Source-text checks,
# in the style of AC-25's launcher.pl checks above.
# ============================================================================
criterion('Decision 33: launcher.pl retries the picker only on a dedicated fork-failed exit code, bounded, and never on a generic non-zero/non-cancel condition', sub {
    my $src = _comment_stripped(bstr(slurp($LAUNCHER)));
    ok(length($src) > 0, 'Decision 33 liveness: launcher.pl was read as source text');

    # A dedicated fork-failed exit code exists as a named constant (not a
    # bare magic number), so both retry sites compare against ONE symbol
    # rather than duplicating (and risking drifting) a literal.
    cmp_ok(index($src, 'FORK_FAILED_EXIT'), '>=', 0,
        'Decision 33: a dedicated FORK_FAILED_EXIT-named constant is defined');

    my ($screen_body) = ($src =~ /sub\s+_pick_session_via_screen\s*\{(.*?)\n\}/s);
    ok(defined $screen_body, 'Decision 33: _pick_session_via_screen is found in source') or return;
    my ($plain_body) = ($src =~ /sub\s+pick_session_action\s*\{(.*?)\n\}/s);
    ok(defined $plain_body, 'Decision 33: pick_session_action is found in source') or return;

    for my $pair ([ 'TUI path (_pick_session_via_screen)', $screen_body ],
                  [ 'plain path (pick_session_action)',    $plain_body ]) {
        my ($label, $body) = @$pair;
        cmp_ok(index($body, 'FORK_FAILED_EXIT'), '>=', 0,
            "Decision 33: the $label body compares against the dedicated FORK_FAILED_EXIT constant");
        like($body, qr/retries_left\s*=\s*3\b/,
            "Decision 33: the $label body bounds its retry counter at 3");
        like($body, qr/retries_left\s*-\s*1/,
            "Decision 33: the $label body decrements the retry counter");
        like($body, qr/retries_left\s*>\s*0/,
            "Decision 33: the $label body guards the retry with a >0 bound (never unconditional)");
    }

    # The bug this decision fixes: a generic "any other non-zero, non-cancel
    # exit" condition retrying the picker forever. That shape must be gone
    # from the WHOLE file, not just the two bodies above -- a stray copy
    # anywhere would reintroduce the unbounded loop.
    unlike($src, qr/!=\s*0\s*&&[^\n]*!=\s*2\b/,
        'Decision 33: no generic "!= 0 && != 2" retry-forever condition exists anywhere in launcher.pl');
});

# ============================================================================
# Decision 32 override: a FAILED fork shows its error and returns to the
# picker on BOTH paths -- it does NOT start a new session on its own. This
# supersedes the spec's S2.2 emitting wording ("On failure ... The
# launcher's existing exit-1 path then warns and starts a new session"),
# per the coordinator's explicit override. Decision 33 gives this failure
# its own dedicated exit code (3, FORK_FAILED_EXIT) rather than the generic
# usage-error exit 1, so the launcher can retry the picker on THIS failure
# specifically without ever retrying on a genuine usage error.
# ============================================================================
criterion('Decision 32/33: a failing --fork (well-formed uuid, no host file) still leaves the picker able to report the error rather than silently starting a new session -- the dedicated FORK_FAILED_EXIT (3), never 0 or 1, non-empty stderr, empty stdout', sub {
    my $host_dir = accent_dir($HOST_TAG);
    my $sbx_dir  = accent_dir($SANDBOX_TAG) . '/projects/-project';
    make_path($sbx_dir);
    my $missing = 'd32d32d3-0000-4000-8000-000000000000';
    my $r = run_select('--sessions-dir', $sbx_dir, '--host-sessions-dir', $host_dir, '--fork', $missing,
        { workdir => $sbx_dir });
    is($r->{rc}, 3, 'Decision 33: a failed --fork exits the dedicated FORK_FAILED_EXIT (3), not the generic usage-error exit 1');
    is($r->{stdout}, '', 'Decision 32: a failed --fork leaves stdout empty (no RESUME token is ever emitted on failure)');
    ok(length($r->{stderr}), 'Decision 32: a failed --fork writes a non-empty error the caller (launcher/picker) can show');
});

# ============================================================================
# AC-M: manual, operator-side (batched per Decision 14; does NOT block
# `done` for this package). NOT a test -- deliberately not automated here,
# because it requires a real `claude --resume` inside a real sandbox
# container, which this test file is forbidden from starting.
#
#   (a) From the dashboard 'c' screen, fork a real host session: claude
#       starts, the prior conversation is visible, and a follow-up question
#       is answered with that context.
#   (b) New records append to <new>.jsonl; no other file appears and the
#       host file is unchanged.
#   (c) Repeat via the plain picker.
#   (d) Fork the same host session twice and resume both; each continues
#       independently.
#   (e) Claude Code's own /resume list inside the container is not disturbed
#       by the sidecar.
#   (f) If the host's CC version is newer than the container's, note any
#       load warning.
#
# Record the result in the ledger (packages/07-host-session-fork.md), not
# here.
# ============================================================================

# ============================================================================
# Fix-batch additions (Decision 34: reports/07-review.md, reports/07-redteam.md)
#
# Written BLIND to the fix-batch implementation the same way as the rest of
# this file: derived only from the review/red-team prose and Decision 34's
# ruling, never from a diff of SessionFork.pm/select-session.pl/launcher.pl.
# ============================================================================

# ----------------------------------------------------------------------------
# Red-team S1 (MUST-FIX, promoted by Decision 34): the container can write a
# sandbox-side transcript whose filename stem is NOT hex-uuid-shaped and
# whose first record's sessionId is "host:<real host uuid>". Because a
# non-hex stem makes SessionIndex derive the row's id from CONTENT, this can
# mint a sandbox row whose id collides with the genuine "host:<uuid>" TUI
# item id. Decision 34: host-ness is decided by ORIGIN, never by an id
# prefix; listed ids that are not uuid-shaped are dropped.
# ----------------------------------------------------------------------------
criterion('Red-team S1: a container-controlled sandbox transcript spoofing sessionId "host:<real host uuid>" must never be indistinguishable from a genuine host row', sub {
    my $host_dir = accent_dir($HOST_TAG);
    my $sbx_dir  = accent_dir($SANDBOX_TAG) . '/projects/-project';
    make_path($sbx_dir);

    my $real_host_uuid = 'a1000000-0000-4000-8000-000000000abc';
    build_host_transcript("$host_dir/$real_host_uuid.jsonl", old => $real_host_uuid, msg => 'a real host question');

    # The spoof: written under the SANDBOX dir (container-writable), stem is
    # NOT hex ("zz-spoof"), first record's sessionId is "host:<real uuid>".
    my $spoof_sid = "host:$real_host_uuid";
    write_raw("$sbx_dir/zz-spoof.jsonl", $JSON->encode({ type => 'user', uuid => 'f0000000-0000-0000-0000-00000000f00d',
        parentUuid => undef, isSidechain => JSON::PP::false, promptId => 'pz', timestamp => ts(200),
        userType => 'external', entrypoint => 'cli', cwd => '/project', sessionId => $spoof_sid,
        version => '2.1.257', gitBranch => 'main', origin => { kind => 'human' }, promptSource => 'typed',
        message => { role => 'user', content => [ { type => 'text', text => 'a spoofed row' } ] } }) . "\n");

    my $listing = list_json(sessions_dir => $sbx_dir, host_sessions_dir => $host_dir);
    ok(ref $listing->{data} eq 'HASH', 'S1 precondition: --list-json decodes') or return;
    my @rows = @{ aref($listing->{data}{sessions}) };

    my ($spoof_row) = grep { ($_->{uuid} // '') eq $spoof_sid } @rows;
    if (defined $spoof_row) {
        is($spoof_row->{origin}, 'sandbox', 'S1: if the spoofed row is listed at all, its origin is sandbox, never host');
        unlike($spoof_row->{uuid}, qr/\Ahost:/, 'S1: if listed, its id string does not carry a host: prefix');
    } else {
        pass('S1: the spoofed row is absent from the listing entirely (an acceptable mitigation)');
    }

    my $uuid_re = qr/\A[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\z/;
    my @bad_ids = grep { !defined($_->{uuid}) || $_->{uuid} !~ $uuid_re } @rows;
    is(scalar(@bad_ids), 0, 'S1: --list-json never emits a non-uuid-shaped id, for any row');

    # Unit-level: tui::LaunchScreens::session_pick_model must decide the
    # "host:" item-id prefix from the row's ORIGIN field alone. A row whose
    # ORIGIN is sandbox must never end up with a "host:"-prefixed item id,
    # even if its uuid field already happens to look like one (defense in
    # depth against S1, independent of whatever the listing layer does).
    my $model = tui::LaunchScreens::session_pick_model(
        [ { origin => 'sandbox', uuid => $spoof_sid, mtime => 1, is_butler => 0, card => {} },
          { origin => 'host', uuid => $real_host_uuid, mtime => 2, is_butler => 0, card => {} } ],
        'resume a session - proj', undef);
    ok(ref $model eq 'HASH', 'S1: session_pick_model returns a hashref') or return;
    my @items = @{ aref($model->{items}) };
    my @host_prefixed = grep { ($_->{id} // '') =~ /\Ahost:/ } @items;
    is(scalar(@host_prefixed), 1, 'S1: exactly one item carries a host: item id -- the genuine origin=host row, never the spoofed origin=sandbox row');
    my ($genuine) = grep { ($_->{id} // '') eq "host:$real_host_uuid" } @items;
    ok(ref $genuine eq 'HASH', 'S1: the genuine host row still gets its host:<uuid> item id');
});

# ----------------------------------------------------------------------------
# Red-team S2: a host-side file whose stem is NOT hex, and whose first
# record's sessionId is a path-traversal string ("../other/<uuid>"), must
# never let the PLAIN picker fork a file outside the host sessions dir.
# Decision 34: the plain picker validates the HOST id, and a listed host
# row's id comes from the file stem (never from spoofable content).
# ----------------------------------------------------------------------------
criterion('Red-team S2: a host transcript with a path-traversal sessionId must never let the plain picker fork a file outside the host sessions dir', sub {
    my $host_dir = accent_dir($HOST_TAG);
    my $sbx_dir  = accent_dir($SANDBOX_TAG) . '/projects/-project';
    make_path($sbx_dir);

    # A sibling directory OUTSIDE $host_dir simulating another project's
    # host transcripts, holding a transcript with an unmistakable marker so
    # a successful traversal is trivially detectable afterwards.
    my $other_uuid = 'deadbeef-0000-4000-8000-000000000abc';
    my $other_dir  = "$host_dir/../other";
    make_path($other_dir);
    my $marker = 'TRAVERSAL-MARKER-' . int(rand(1_000_000));
    build_host_transcript("$other_dir/$other_uuid.jsonl", old => $other_uuid, msg => $marker);

    # A legit host session too, so the picker offers at least one normal row.
    my $legit_uuid = 'a2000011-1111-4111-8111-000000000abc';
    build_host_transcript("$host_dir/$legit_uuid.jsonl", old => $legit_uuid, msg => 'a normal host question');

    # The malicious file: stem is NOT hex-uuid-shaped, sessionId is a
    # traversal path pointing at the sibling project's transcript.
    my $evil_sid = "../other/$other_uuid";
    write_raw("$host_dir/evil-notes.jsonl", $JSON->encode({ type => 'user', uuid => 'e0000000-0000-0000-0000-000000000001',
        parentUuid => undef, isSidechain => JSON::PP::false, promptId => 'pe', timestamp => ts(300),
        userType => 'external', entrypoint => 'cli', cwd => 'C:\\x', sessionId => $evil_sid,
        version => '2.1.257', gitBranch => 'main', origin => { kind => 'human' }, promptSource => 'typed',
        message => { role => 'user', content => [ { type => 'text', text => 'a spoofed host row' } ] } }) . "\n");

    my $listing = list_json(sessions_dir => $sbx_dir, host_sessions_dir => $host_dir);
    ok(ref $listing->{data} eq 'HASH', 'S2 precondition: --list-json decodes') or return;
    my @rows = @{ aref($listing->{data}{sessions}) };
    my @traversal_rows = grep { ($_->{uuid} // '') =~ /\.\./ } @rows;
    is(scalar(@traversal_rows), 0, 'S2: no listed row of any origin carries a ".." traversal id');

    # Whatever the mitigation (dropping the row, or validating the id before
    # building the fork path), picking through every numbered choice the
    # plain (line-prompt) picker offers must never copy the sibling
    # project's transcript into the sandbox dir.
    my $rows_count = scalar(@rows);
    for my $choice (2 .. $rows_count + 1) {
        run_output_action(sessions_dir => $sbx_dir, host_sessions_dir => $host_dir, input => "$choice\n");
    }
    opendir(my $dh, $sbx_dir) or die $!;
    my @sbx_files = grep { !/^\.\.?$/ && -f "$sbx_dir/$_" } readdir($dh);
    closedir $dh;
    my $leaked = 0;
    for my $f (@sbx_files) {
        my $bytes = slurp("$sbx_dir/$f") // '';
        $leaked++ if index($bytes, $marker) >= 0;
    }
    is($leaked, 0, 'S2: the sibling project\'s transcript content never reaches the sandbox dir via any picker choice');
});

# ----------------------------------------------------------------------------
# Review S3: CRLF preservation (no assertion covered this before). A CRLF-
# terminated line keeps its \r\n terminator byte for byte after the fork,
# apart from the rewritten sessionId/cwd spans.
# ----------------------------------------------------------------------------
criterion('Review S3: a CRLF-terminated host line keeps its \r\n terminator byte for byte after the fork, apart from the rewritten spans', sub {
    my $host_dir = accent_dir($HOST_TAG);
    my $sbx_dir  = accent_dir($SANDBOX_TAG) . '/projects/-project';
    make_path($sbx_dir);
    my $old = 'ccrrllff-0000-4000-8000-000000000000';
    my $host_cwd = 'C:\\Users\\host\\proj';
    my $crlf_msg = "line one, part t\x{e9}ste";
    my $rec = $JSON->encode({ type => 'user', uuid => 'cc000000-0000-0000-0000-000000000001',
        parentUuid => undef, isSidechain => JSON::PP::false, promptId => 'pcr', timestamp => ts(400),
        userType => 'external', entrypoint => 'cli', cwd => $host_cwd, sessionId => $old,
        version => '2.1.257', gitBranch => 'main', origin => { kind => 'human' }, promptSource => 'typed',
        message => { role => 'user', content => [ { type => 'text', text => $crlf_msg } ] } });
    my $host_file = "$host_dir/$old.jsonl";
    write_raw($host_file, "$rec\r\n");

    my ($new, $err) = SessionFork::fork_session($host_file, $sbx_dir);
    is($err, undef, 'S3 precondition: the CRLF fixture forks without error') or diag("error: " . ($err // 'undef'));
    ok(defined $new, 'S3 precondition: a new id was returned') or return;

    my $src_bytes  = slurp($host_file);
    my $fork_bytes = slurp("$sbx_dir/$new.jsonl");
    like($fork_bytes, qr/\r\n\z/, 'S3: the fork\'s line still ends in CRLF, not a bare LF');

    my $rewritten = $fork_bytes;
    $rewritten =~ s/"sessionId":"\Q$new\E"/"sessionId":"$old"/;
    $rewritten =~ s/"cwd":"\/project"/'"cwd":"' . _json_escape($host_cwd) . '"'/e;
    is($rewritten, $src_bytes, 'S3: undoing the two rewrites reproduces the CRLF source bytes exactly, terminator included');
});

# ----------------------------------------------------------------------------
# Review S4: the rename-failure branch (SessionFork.pm step 9/10), previously
# untested because it "cannot be tested without a further seam" -- the
# reviewer's scratch probe showed otherwise: an overloaded $CONTAINER_CWD
# plants a directory at the transcript's OWN eventual rename target on its
# first stringification (which happens while rewriting a cwd span, i.e.
# strictly after the step-3 existence check and strictly before the
# step-9 rename). $UUID_GEN is pinned so the target path is known in
# advance. Also checks review S2: cleanup must never delete a file this
# call did not itself create.
# ----------------------------------------------------------------------------
package SessionForkTest::Overloaded {
    use overload '""' => sub {
        my $self = shift;
        if (!$self->{done}) {
            $self->{done} = 1;
            require File::Path;
            File::Path::make_path($self->{block_path}) unless -e $self->{block_path};
        }
        return $self->{value};
    }, fallback => 1;
    sub new { my ($class, %a) = @_; return bless { done => 0, %a }, $class; }
}

criterion('Review S4: the rename-failure branch leaves no transcript, no sidecar, no tmp file, and never deletes a pre-existing unrelated file at a colliding name', sub {
    my $host_dir = accent_dir($HOST_TAG);
    my $sbx_dir  = accent_dir($SANDBOX_TAG) . '/projects/-project';
    make_path($sbx_dir);
    my $old = 's4000000-0000-4000-8000-000000000000';
    my $host_file = "$host_dir/$old.jsonl";
    build_host_transcript($host_file, old => $old);

    my $forced_uuid = 's4f00000-0000-4000-8000-000000000abc';
    # An unrelated pre-existing file at a name that has nothing to do with
    # this fork (review S2: cleanup must never sweep more broadly than the
    # names this call itself created).
    my $unrelated = "$sbx_dir/unrelated-marker.txt";
    write_raw($unrelated, "do not touch me\n");
    my $unrelated_sig = stat_sig($unrelated);

    local $SessionFork::UUID_GEN = sub { $forced_uuid };
    local $SessionFork::CONTAINER_CWD = SessionForkTest::Overloaded->new(
        value => '/project', block_path => "$sbx_dir/$forced_uuid.jsonl");

    my ($new, $err) = SessionFork::fork_session($host_file, $sbx_dir);
    is($new, undef, 'S4: fork_session returns undef when the transcript rename target is blocked') or diag("new=" . ($new // 'undef'));
    ok(length($err // ''), 'S4: a non-empty error is returned');

    opendir(my $dh, $sbx_dir) or die $!;
    my @files = grep { !/^\.\.?$/ } readdir($dh);
    closedir $dh;
    my @tmp      = grep { /^\.fork-/ } @files;
    my @sidecars = grep { /\.ccpraxis-fork\.json\z/ } @files;
    is(scalar(@tmp), 0, 'S4: no tmp file remains');
    is(scalar(@sidecars), 0, 'S4: no sidecar remains');
    ok(-e $unrelated, 'S4: the pre-existing unrelated file was NOT deleted');
    is(stat_sig($unrelated), $unrelated_sig, 'S4: the pre-existing unrelated file is byte-unchanged');
});

# ----------------------------------------------------------------------------
# Review M1/M2 (Decision 34 amendment): after the fork-retry bound is
# exhausted, BOTH launcher paths must CANCEL rather than fall through to a
# new session (Decision 32 requires the operator's chosen conversation never
# silently becomes a blank one). And the TUI path must pass the fork error
# into session_pick_model's error argument so it is visible on the retry
# screen, not just captured into an invisible log.
# ----------------------------------------------------------------------------
criterion('Decision 34 (M1): after the fork retry bound is exhausted, both launcher paths can CANCEL instead of always falling back to a new session', sub {
    my $src = _comment_stripped(bstr(slurp($LAUNCHER)));
    ok(length($src) > 0, 'M1 liveness: launcher.pl was read as source text');

    my ($screen_body) = ($src =~ /sub\s+_pick_session_via_screen\s*\{(.*?)\n\}/s);
    ok(defined $screen_body, 'M1: _pick_session_via_screen is found in source') or return;
    my ($plain_body) = ($src =~ /sub\s+pick_session_action\s*\{(.*?)\n\}/s);
    ok(defined $plain_body, 'M1: pick_session_action is found in source') or return;

    for my $pair ([ 'TUI path (_pick_session_via_screen)', $screen_body ],
                  [ 'plain path (pick_session_action)',    $plain_body ]) {
        my ($label, $body) = @$pair;
        cmp_ok(index($body, 'FORK_FAILED_EXIT'), '>=', 0,
            "M1: the $label body still guards on the dedicated FORK_FAILED_EXIT constant");
        cmp_ok(index($body, "'cancel'"), '>=', 0,
            "M1: the $label body can return a 'cancel' outcome (retry exhaustion no longer always falls back to a new session)");
    }
});

criterion('Decision 34 (M2): the TUI path passes the fork error into session_pick_model\'s error argument on the retry, rather than a bare undef', sub {
    my $src = _comment_stripped(bstr(slurp($LAUNCHER)));
    ok(length($src) > 0, 'M2 liveness: launcher.pl was read as source text');
    my ($screen_body) = ($src =~ /sub\s+_pick_session_via_screen\s*\{(.*?)\n\}/s);
    ok(defined $screen_body, 'M2: _pick_session_via_screen is found in source') or return;

    my @sp_calls = ($screen_body =~ /session_pick_model\(([^\n]*?)\)/gs);
    cmp_ok(scalar(@sp_calls), '>', 0, 'M2 precondition: at least one session_pick_model( call is found in the TUI body') or return;
    my $any_non_undef_error_arg = grep { /,[^,]+,[^,]+/ && $_ !~ /,\s*undef\s*\z/ } @sp_calls;
    ok($any_non_undef_error_arg, 'M2: at least one session_pick_model(...) call passes something other than a bare undef as its (error) argument');
});

# ----------------------------------------------------------------------------
# Decision 34 (N4): the sandbox projects dir being a symlink is refused,
# where the platform/filesystem supports symlink() at all. Skips cleanly
# (one passing assertion, not a failure) where it does not.
# ----------------------------------------------------------------------------
{
    my $target_dir = tempdir(CLEANUP => 1);
    my $link_path  = tempdir(CLEANUP => 1) . '/symlinked-sessions';
    my $sym_ok = eval { symlink($target_dir, $link_path); 1 } && -l $link_path;
    if (!$sym_ok) {
        pass('Decision 34 (N4): skipped cleanly -- this platform/filesystem does not support symlink()');
    } else {
        criterion('Decision 34 (N4): fork_session refuses when the sandbox projects dir is a symlink, and writes nothing through it', sub {
            my $host_dir = accent_dir($HOST_TAG);
            my $old = 'sy000000-0000-4000-8000-000000000000';
            my $host_file = "$host_dir/$old.jsonl";
            build_host_transcript($host_file, old => $old);

            my ($new, $err) = SessionFork::fork_session($host_file, $link_path);
            is($new, undef, 'N4: fork_session returns undef when the sandbox projects dir is a symlink');
            ok(length($err // ''), 'N4: a non-empty error is returned');

            opendir(my $dh, $target_dir) or die $!;
            my @files = grep { !/^\.\.?$/ } readdir($dh);
            closedir $dh;
            is(scalar(@files), 0, 'N4: nothing was written through the symlink into its real target directory');
        });
    }
}

done_testing();
