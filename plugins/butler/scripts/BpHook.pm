# BpHook.pm -- the shared hook core (package 03 of blueprint hook-continuity-remake).
# Contract: .ccpraxis-local-data/blueprints/hook-continuity-remake/specs/03-hook-core-spec.md
# Architecture: plugins/butler/docs/hook-architecture.md ("BpHook core API",
# "Arm state storage and format", "Holder protocol", "Command binding").
#
# The only place that decides "is this session running butler work"
# (Decision 3). Additive only (Decision 19): nothing here is registered.
#
# Conventions, following BpState.pm: nothing is exported; callers use
# BpHook::name(...). Directories are read with opendir/readdir, never glob
# (glob splits on whitespace and drops fragments of a path with spaces).
# Only core modules are used (JSON::PP, Digest::SHA, Fcntl, File::Path, Cwd).
# BpProjectRoot.pm is loaded with require (an explicit path via this file's
# own directory) and never copied.
#
# Pid discipline (DC3, project CLAUDE.md "Windows landmines"): the only pids
# read are holder pids, written by a holder's own $$ and read back through
# /proc/<pid>/cmdline in the SAME (MSYS) namespace. Never /proc/*/stat,
# /proc/*/status or /proc/*/winpid; never ps -W, tasklist, taskkill or
# Get-Process; never a WINPID compared with an MSYS pid.
package BpHook;
use strict;
use warnings;
use JSON::PP ();
use Digest::SHA qw(sha1_hex);
use Fcntl qw(:flock O_WRONLY O_APPEND O_CREAT O_EXCL);
use File::Basename qw(dirname);
use Cwd ();
use B qw(svref_2object SVp_POK);

my $SID_RE    = qr/\A[A-Za-z0-9_-]{1,128}\z/;
my $AGENT_RE  = qr/\A[A-Za-z0-9_-]{1,64}\z/;
my $TUID_RE   = qr/\A[A-Za-z0-9_-]{1,128}\z/;
my $TOKEN_RE  = qr/\A[0-9a-f]{8}\z/;

my %READER_BLACKLIST = map { ($_ => 1) } qw(echo printf grep rg cat sed awk head tail);

my $SELF_DIR;
{
    my $f = __FILE__;
    $f = Cwd::abs_path($f) // $f;
    $SELF_DIR = dirname($f);
}
my $BPPROJROOT_LOADED = 0;

# --------------------------------------------------------------- errors -----

my $LAST_ERROR;
sub _clear_error { $LAST_ERROR = undef; return }
sub _set_error   { my ($m) = @_; $LAST_ERROR = $m; return }
sub last_error   { return $LAST_ERROR }

# ------------------------------------------------------------- byte/char ----

sub _is_plain_string {
    my ($v) = @_;
    return 0 unless defined $v;
    return 0 if ref $v;
    my $flags = svref_2object(\$v)->FLAGS;
    return ($flags & SVp_POK()) ? 1 : 0;
}

# Filesystem-path bytes: encode a character string to UTF-8 bytes, and turn
# backslashes into forward slashes. A byte string with no utf8 flag is
# assumed to already be the correct on-disk byte sequence and is left alone
# apart from the slash conversion.
sub _to_bytes {
    my ($s) = @_;
    return undef unless defined $s;
    my $v = "$s";
    if (utf8::is_utf8($v)) {
        utf8::encode($v);
    }
    else {
        # Perl keeps a string unflagged whenever every character fits in a
        # byte, even one built from a \x{..} escape (DC1: "Andr\x{e9}" is 5
        # chars, unflagged, single byte 0xE9 -- indistinguishable at the SV
        # level from a genuine byte string). Probe: if the raw bytes already
        # form valid UTF-8 (utf8::decode succeeds), they are ALREADY the
        # target encoding and must not be re-encoded (that would double-
        # encode "Andr\xC3\xA9" into "Andr\xC3\x83\xC2\xA9"). If decode
        # fails (a lone lead byte such as 0xE9 has no continuation bytes),
        # this is Perl's own per-byte character storage, and utf8::encode
        # correctly expands each such byte into its UTF-8 form.
        my $probe = $v;
        my $already_utf8 = utf8::decode($probe);
        unless ($already_utf8) {
            utf8::encode($v);
        }
    }
    $v =~ tr{\\}{/};
    return $v;
}

# A character string suitable for JSON::PP->utf8->encode: decode a
# non-flagged byte string once if it holds valid UTF-8, so nothing is ever
# encoded twice (Andre stored as bytes 41 6E 64 72 C3 A9, never doubly
# encoded as ...C3 83 C2 A9).
sub _decode_maybe {
    my ($s) = @_;
    return undef unless defined $s;
    return $s if ref $s;
    my $v = $s;
    unless (utf8::is_utf8($v)) {
        my $copy = $v;
        if (utf8::decode($copy)) { $v = $copy }
    }
    return $v;
}

# Argv-key bytes: encode a character string to UTF-8 bytes for hashing,
# WITHOUT the path helper's backslash-to-slash fold (m1/L3: argv is not a
# path, and folding \ to / would let 'a\b' and 'a/b' collide on one ticket
# key).
sub _utf8_bytes {
    my ($s) = @_;
    return undef unless defined $s;
    my $v = "$s";
    if (utf8::is_utf8($v)) {
        utf8::encode($v);
    }
    else {
        my $probe = $v;
        my $already_utf8 = utf8::decode($probe);
        unless ($already_utf8) {
            utf8::encode($v);
        }
    }
    return $v;
}

sub _to_json_path {
    my ($s) = @_;
    return undef unless defined $s;
    my $v = _decode_maybe($s);
    $v =~ tr{\\}{/};
    return $v;
}

sub _is_abs {
    my ($p) = @_;
    return 0 unless defined $p && length $p;
    return 1 if $p =~ m{^/};
    return 1 if $p =~ m{^[A-Za-z]:[\\/]};
    return 0;
}

# -------------------------------------------------------------- state_dir ---

sub state_dir {
    my $bsd = $ENV{BUTLER_STATE_DIR};
    if (defined $bsd && length $bsd) {
        return undef unless _is_abs($bsd);
        my $v = _to_bytes($bsd);
        $v =~ s{/+$}{};
        return "$v/continuity";
    }
    for my $var (qw(HOME USERPROFILE)) {
        my $val = $ENV{$var};
        next unless defined $val && length $val && _is_abs($val);
        my $v = _to_bytes($val);
        $v =~ s{/+$}{};
        return "$v/.claude/butler-state/continuity";
    }
    return undef;
}

sub _ensure_bpprojroot {
    return 1 if $BPPROJROOT_LOADED;
    my $path = "$SELF_DIR/BpProjectRoot.pm";
    return 0 unless -f $path;
    my $ok = eval { require $path; 1 };
    $BPPROJROOT_LOADED = 1 if $ok;
    return $ok ? 1 : 0;
}

sub data_dir {
    my ($p) = @_;
    my $ccp = $ENV{CCPRAXIS_DATA_DIR};
    if (defined $ccp && length $ccp && _is_abs($ccp)) {
        return _to_bytes($ccp);
    }
    my $root;
    my $cpd = $ENV{CLAUDE_PROJECT_DIR};
    if (defined $cpd && length $cpd) {
        $root = $cpd;
    }
    elsif (ref $p eq 'HASH' && defined $p->{cwd} && length $p->{cwd} && _is_abs($p->{cwd})) {
        my $cwd_cand = _to_bytes($p->{cwd});
        if (-d $cwd_cand) {
            my $saved = Cwd::getcwd();
            if (defined $saved && chdir($cwd_cand)) {
                if (_ensure_bpprojroot()) {
                    $root = eval { BpProjectRoot::resolve() };
                }
                chdir($saved);
            }
        }
    }
    return undef unless defined $root && length $root;
    my $root_b = _to_bytes($root);
    my $dd = "$root_b/.ccpraxis-local-data";
    return -d $dd ? $dd : undef;
}

# ------------------------------------------------------------------ io ------

sub _read_bytes {
    my ($path) = @_;
    open(my $fh, '<:raw', $path) or return undef;
    local $/;
    my $c = <$fh>;
    close $fh;
    return $c;
}

sub _read_json {
    my ($path) = @_;
    my $raw = _read_bytes($path);
    return undef unless defined $raw;
    return eval { JSON::PP->new->utf8->decode($raw) };
}

sub _basename_of {
    my ($p) = @_;
    $p =~ s{.*/}{};
    return $p;
}

sub _write_json_atomic {
    my ($path, $data) = @_;
    my $dir = $path;
    $dir =~ s{/[^/]*$}{};
    unless (-d $dir) {
        eval { require File::Path; File::Path::make_path($dir) };
    }
    return 0 unless -d $dir;
    my $json = eval { JSON::PP->new->utf8->canonical->encode($data) };
    return 0 unless defined $json;
    my $tmp = "$dir/." . _basename_of($path) . ".tmp.$$";
    open(my $fh, '>:raw', $tmp) or return 0;
    my $ok = print {$fh} $json . "\n";
    $ok &&= close($fh);
    unless ($ok) { unlink $tmp; return 0 }
    return 1 if rename($tmp, $path);
    my $e = "$!";
    unlink $tmp;
    _set_error("io: $e");
    return 0;
}

sub _open_armlock {
    my ($root, $sid) = @_;
    my $lockdir = "$root/armlock";
    eval { require File::Path; File::Path::make_path($lockdir) };
    my $lockpath = "$lockdir/$sid";
    open(my $lockfh, '>>', $lockpath) or return undef;
    return $lockfh;
}

sub _flock_with_timeout {
    my ($fh, $secs) = @_;
    my $got = 0;
    eval {
        local $SIG{ALRM} = sub { die "bphook-lock-timeout\n" };
        alarm($secs);
        $got = flock($fh, LOCK_EX);
        alarm(0);
    };
    alarm(0);
    return $got ? 1 : 0;
}

sub _iso_now {
    my @t = gmtime(time());
    return sprintf('%04d-%02d-%02dT%02d:%02d:%02dZ', $t[5] + 1900, $t[4] + 1, $t[3], $t[2], $t[1], $t[0]);
}

sub _word_count {
    my ($s) = @_;
    return 0 unless defined $s;
    my @w = grep { length } split /\s+/, $s;
    return scalar @w;
}

# -------------------------------------------------------- session/agent ----

sub session_id {
    my ($p) = @_;
    return undef unless ref $p eq 'HASH';
    my $v = $p->{session_id};
    return undef unless defined $v && !ref($v) && _is_plain_string($v);
    return ($v =~ $SID_RE) ? $v : undef;
}

sub agent_id {
    my ($p) = @_;
    return undef unless ref $p eq 'HASH';
    return undef unless exists $p->{agent_id};
    my $v = $p->{agent_id};
    return undef unless defined $v;
    return '?' if ref $v;
    return ($v =~ $AGENT_RE) ? $v : '?';
}

sub _env_role_kind {
    my $ledger = $ENV{BP_LEDGER};
    if (defined $ledger && length $ledger) {
        my $role = $ENV{BP_ROLE};
        return 'coordinator' if !defined $role || $role eq '' || $role eq 'coordinator';
        return 'judge';
    }
    return 'none';
}

sub role {
    my ($p) = @_;
    my $k = _env_role_kind();
    return 'coordinator' if $k eq 'coordinator';
    return 'judge'       if $k eq 'judge';
    my $sid = session_id($p);
    return 'manual' unless defined $sid;
    my $root = state_dir();
    return 'manual' unless defined $root;
    my $data = _read_json("$root/armed/$sid");
    return 'manual' unless ref $data eq 'HASH';
    my $r = $data->{role};
    return (defined $r && ($r eq 'driver' || $r eq 'reporter')) ? $r : 'manual';
}

sub is_armed {
    my ($sid) = @_;
    my $k = _env_role_kind();
    return 1 if $k eq 'coordinator';
    return 0 if $k eq 'judge';
    return 0 unless defined $sid && $sid =~ $SID_RE;
    my $root = state_dir();
    return 0 unless defined $root;
    return -e "$root/armed/$sid" ? 1 : 0;
}

# ------------------------------------------------------------- arm/disarm ---

sub arm {
    my ($sid, %opts) = @_;
    _clear_error();
    unless (defined $sid && $sid =~ $SID_RE) { _set_error('bad session id'); return 0 }
    my $role = $opts{role};
    unless (defined $role && ($role eq 'driver' || $role eq 'reporter' || $role eq 'manual')) {
        _set_error('bad role');
        return 0;
    }
    my $by = $opts{by};
    unless (defined $by && $by =~ /^[a-z][a-z0-9-]{0,31}$/) { _set_error('bad role'); return 0 }
    my $root = state_dir();
    unless (defined $root) { _set_error('no state root'); return 0 }
    my $lockdir = "$root/armlock";
    eval { require File::Path; File::Path::make_path($lockdir) };
    my $lockpath = "$lockdir/$sid";
    open(my $lockfh, '>>', $lockpath) or do { my $e = "$!"; _set_error("io: $e"); return 0 };
    unless (_flock_with_timeout($lockfh, 10)) {
        close $lockfh;
        _set_error('io: lock timeout');
        return 0;
    }
    my $offpath = "$root/off/$sid";
    if (-e $offpath && $by ne 'on') {
        flock($lockfh, LOCK_UN);
        close $lockfh;
        _set_error('off');
        return 0;
    }
    my $rec = { session_id => $sid, role => $role, by => $by, at => _iso_now() };
    if (defined $opts{transcript_path}) { $rec->{transcript_path} = _to_json_path($opts{transcript_path}) }
    my $ok = _write_json_atomic("$root/armed/$sid", $rec);
    if ($ok && $by eq 'on') { unlink($offpath) }
    flock($lockfh, LOCK_UN);
    close $lockfh;
    unless ($ok) { _set_error('io: write failed'); return 0 }
    return 1;
}

sub disarm {
    my ($sid, %opts) = @_;
    _clear_error();
    unless (defined $sid && $sid =~ $SID_RE) { _set_error('bad session id'); return 0 }
    my $actor = $opts{actor};
    unless (defined $actor && ($actor eq 'agent' || $actor eq 'operator')) { _set_error('bad role'); return 0 }
    my $reason = $opts{reason};
    my $root = state_dir();
    unless (defined $root) { _set_error('no state root'); return 0 }
    my $lockdir = "$root/armlock";
    eval { require File::Path; File::Path::make_path($lockdir) };
    my $lockpath = "$lockdir/$sid";
    open(my $lockfh, '>>', $lockpath) or do { my $e = "$!"; _set_error("io: $e"); return 0 };
    unless (_flock_with_timeout($lockfh, 10)) {
        close $lockfh;
        _set_error('io: lock timeout');
        return 0;
    }
    my $armed_data = _read_json("$root/armed/$sid");
    my $tp = (ref $armed_data eq 'HASH' && defined $armed_data->{transcript_path} && length $armed_data->{transcript_path})
        ? $armed_data->{transcript_path}
        : undef;
    unlink("$root/armed/$sid");
    unlink("$root/silence/$sid");
    unlink("$root/holder/$sid.json");
    revoke_stop_token($sid);
    my $rec = { session_id => $sid, actor => $actor, reason => _decode_maybe($reason), at => _iso_now() };
    if (defined $tp) { $rec->{transcript_path} = $tp }
    my $ok = _write_json_atomic("$root/off/$sid", $rec);
    flock($lockfh, LOCK_UN);
    close $lockfh;
    unless ($ok) { _set_error('io: write failed'); return 0 }
    return 1;
}

sub latest_is_off {
    my ($sid) = @_;
    return 0 unless defined $sid && $sid =~ $SID_RE;
    my $root = state_dir();
    return 0 unless defined $root;
    return -e "$root/off/$sid" ? 1 : 0;
}

# ------------------------------------------------------------------ silence -

sub set_silence {
    my ($sid, %opts) = @_;
    _clear_error();
    return 0 unless defined $sid && $sid =~ $SID_RE;
    my $reason = $opts{reason};
    return 0 unless defined $reason && _word_count($reason) >= 2;
    my $root = state_dir();
    unless (defined $root) { _set_error('no state root'); return 0 }
    my $lockfh = _open_armlock($root, $sid);
    unless ($lockfh) { my $e = "$!"; _set_error("io: $e"); return 0 }
    unless (_flock_with_timeout($lockfh, 10)) {
        close $lockfh;
        _set_error('io: lock timeout');
        return 0;
    }
    my $rec = { session_id => $sid, by => 'butler-continuity', reason => _decode_maybe($reason), at => _iso_now() };
    my $ok = _write_json_atomic("$root/silence/$sid", $rec) ? 1 : 0;
    flock($lockfh, LOCK_UN);
    close $lockfh;
    return $ok;
}

sub take_silence {
    my ($sid) = @_;
    return 0 unless defined $sid && $sid =~ $SID_RE;
    my $root = state_dir();
    return 0 unless defined $root;
    my $lockfh = _open_armlock($root, $sid);
    return 0 unless $lockfh;
    unless (_flock_with_timeout($lockfh, 10)) {
        close $lockfh;
        return 0;
    }
    my $path = "$root/silence/$sid";
    my $data = _read_json($path);
    my $valid = 0;
    if (ref $data eq 'HASH'
        && defined $data->{session_id} && $data->{session_id} eq $sid
        && defined $data->{by} && $data->{by} eq 'butler-continuity'
        && defined $data->{reason} && _word_count($data->{reason}) >= 2)
    {
        $valid = 1;
    }
    my $unlinked = unlink($path) ? 1 : 0;
    flock($lockfh, LOCK_UN);
    close $lockfh;
    return ($valid && $unlinked) ? 1 : 0;
}

# ------------------------------------------------------------------- holder -

sub holder {
    my ($sid) = @_;
    return undef unless defined $sid && $sid =~ $SID_RE;
    my $root = state_dir();
    return undef unless defined $root;
    my $data = _read_json("$root/holder/$sid.json");
    return (ref $data eq 'HASH' && defined $data->{session_id} && $data->{session_id} eq $sid) ? $data : undef;
}

sub holder_live {
    my ($sid, $p) = @_;
    return 0 unless defined $sid;
    my $h = holder($sid);
    return 0 unless ref $h eq 'HASH';
    my $now = time();
    my $deadline = $h->{deadline};
    return 0 unless defined $deadline && $deadline =~ /^-?\d+$/ && $deadline > $now && $deadline <= $now + 3600;

    my $role = role($p);
    my $is_coord = ($role eq 'coordinator') ? 1 : 0;

    my $items = (ref $h->{items} eq 'ARRAY') ? $h->{items} : [];
    my %item_set = map { (defined $_ ? ($_ => 1) : ()) } @$items;

    my $bg = (ref $p eq 'HASH') ? $p->{background_tasks} : undef;
    if (ref $bg eq 'ARRAY') {
        my $found = 0;
        for my $entry (@$bg) {
            next unless ref $entry eq 'HASH';
            next unless defined $entry->{status} && $entry->{status} eq 'running';
            next unless defined $entry->{id} && $item_set{$entry->{id}};
            if ($is_coord) {
                next unless defined $entry->{type} && $entry->{type} eq 'subagent';
            }
            $found = 1;
            last;
        }
        return 0 unless $found;
    }
    else {
        return 0 if $is_coord;
    }

    unless ($is_coord) {
        my $pid = $h->{pid};
        return 0 unless defined $pid && "$pid" =~ /^[1-9][0-9]{0,9}$/;
        if (-r '/proc/self/cmdline') {
            my $fp = $h->{fp};
            return 0 unless defined $fp && length $fp;
            return 0 if $fp eq sha1_hex('');
            my $cmdline = _read_bytes("/proc/$pid/cmdline");
            return 0 unless defined $cmdline && length $cmdline;
            return 0 unless sha1_hex($cmdline) eq $fp;
        }
        else {
            return 0 unless kill(0, $pid);
        }
    }
    return 1;
}

# --------------------------------------------------------------- reasons ---

sub log_reason {
    my ($sid, $actor, $verb, $text, $project) = @_;
    my $root = state_dir();
    return 0 unless defined $root;
    eval { require File::Path; File::Path::make_path($root) };
    my $path = "$root/reasons.log";
    if (-f $path) {
        my $size = (stat($path))[7];
        if (defined $size && $size > 1024 * 1024) {
            rename($path, "$path.1");
        }
    }
    my $flatten = sub {
        my ($v) = @_;
        $v = (defined $v && length $v) ? $v : '-';
        $v = _decode_maybe($v);
        $v =~ s/[\t\r\n]/ /g;
        return $v;
    };
    my $f_sid   = $flatten->($sid);
    my $f_actor = $flatten->($actor);
    my $f_verb  = $flatten->($verb);
    my $f_proj  = $flatten->($project);
    my $flat = $flatten->($text);
    $flat = substr($flat, 0, 300);
    my $line = join("\t", _iso_now(), $f_sid, $f_actor, $f_verb, $f_proj, $flat) . "\n";
    my $bytes = $line;
    if (utf8::is_utf8($bytes)) { utf8::encode($bytes) }
    sysopen(my $fh, $path, O_WRONLY | O_APPEND | O_CREAT) or return 0;
    binmode($fh, ':raw');
    my $ok = syswrite($fh, $bytes);
    close $fh;
    return defined $ok ? 1 : 0;
}

sub gc_sessions {
    my $root = state_dir();
    return 0 unless defined $root;
    my %sids;
    for my $sub (qw(armed off)) {
        my $dir = "$root/$sub";
        next unless -d $dir;
        opendir(my $dh, $dir) or next;
        for my $e (readdir($dh)) {
            next if $e eq '.' || $e eq '..';
            next unless $e =~ $SID_RE;
            $sids{$e} = 1;
        }
        closedir $dh;
    }
    my $count = 0;
    for my $sid (sort keys %sids) {
        my $armed = _read_json("$root/armed/$sid");
        my $off   = _read_json("$root/off/$sid");
        my $tp;
        if (ref $armed eq 'HASH' && defined $armed->{transcript_path} && length $armed->{transcript_path}) {
            $tp = $armed->{transcript_path};
        }
        elsif (ref $off eq 'HASH' && defined $off->{transcript_path} && length $off->{transcript_path}) {
            $tp = $off->{transcript_path};
        }
        next unless defined $tp;
        my $path_bytes = _to_bytes($tp);
        next if -e $path_bytes;
        my $lockfh = _open_armlock($root, $sid);
        next unless $lockfh;
        unless (_flock_with_timeout($lockfh, 10)) { close $lockfh; next }
        unlink("$root/armed/$sid");
        unlink("$root/off/$sid");
        unlink("$root/silence/$sid");
        unlink("$root/holder/$sid.json");
        revoke_stop_token($sid);
        flock($lockfh, LOCK_UN);
        close $lockfh;
        unlink("$root/armlock/$sid");
        log_reason($sid, 'gc', 'gc', "transcript gone: $tp", undef);
        $count++;
    }
    return $count;
}

# --------------------------------------------------------------- tickets ---

sub _normalize_ticket_name {
    my ($name) = @_;
    return undef unless defined $name && length $name;
    my $b = $name;
    $b =~ s{.*[/\\]}{};
    $b =~ s/\.(?:pl|sh)$//;
    return ($b eq 'butler-continuity' || $b eq 'butler-hold') ? $b : undef;
}

sub write_ticket {
    my ($p, $name, $argv, %opts) = @_;
    my $norm = _normalize_ticket_name($name);
    return 0 unless defined $norm;
    my $sid = session_id($p);
    return 0 unless defined $sid;
    my $tuid = (ref $p eq 'HASH') ? $p->{tool_use_id} : undef;
    return 0 unless defined $tuid && !ref($tuid) && $tuid =~ $TUID_RE;
    return 0 unless ref $argv eq 'ARRAY';
    return 0 if grep { !defined $_ } @$argv;
    my @bytes_argv = map { _utf8_bytes($_) } @$argv;
    return 0 if grep { index($_, "\0") >= 0 } @bytes_argv;
    my $root = state_dir();
    return 0 unless defined $root;
    my $k = sha1_hex(join("\0", $norm, @bytes_argv));
    my $aid = agent_id($p);
    my $rec = {
        session_id      => $sid,
        tool_use_id     => $tuid,
        agent_id        => $aid,
        operator        => ($opts{operator} ? JSON::PP::true() : JSON::PP::false()),
        background      => ($opts{background} ? JSON::PP::true() : JSON::PP::false()),
        transcript_path => _to_json_path($p->{transcript_path}),
        cwd             => _to_json_path($p->{cwd}),
        at              => time(),
    };
    return _write_json_atomic("$root/tickets/$k/$sid.$tuid.json", $rec);
}

sub take_ticket {
    my ($name, $argv) = @_;
    my $norm = _normalize_ticket_name($name);
    return undef unless defined $norm;
    return undef unless ref $argv eq 'ARRAY';
    my $root = state_dir();
    return undef unless defined $root;
    my @bytes_argv = map { _utf8_bytes($_) } @$argv;
    my $k = sha1_hex(join("\0", $norm, @bytes_argv));
    my $dir = "$root/tickets/$k";
    return undef unless -d $dir;
    opendir(my $dh, $dir) or return undef;
    my @entries = grep { /\.json$/ } readdir($dh);
    closedir $dh;
    my $now = time();
    my @live;
    for my $e (@entries) {
        my $full = "$dir/$e";
        my $data = _read_json($full);
        if (ref $data ne 'HASH'
            || !defined $data->{at} || $data->{at} !~ /^-?\d+$/
            || $data->{at} < $now - 30 || $data->{at} > $now + 30)
        {
            unlink $full;
            next;
        }
        push @live, $full;
    }
    return undef if @live == 0;
    return 'ambiguous' if @live > 1;
    my $file = $live[0];
    my $claimed = "$file.claimed.$$";
    return undef unless rename($file, $claimed);
    my $data = _read_json($claimed);
    unlink($claimed);
    if (opendir(my $dh2, $dir)) {
        my @remaining = grep { $_ ne '.' && $_ ne '..' } readdir($dh2);
        closedir $dh2;
        rmdir($dir) if @remaining == 0;
    }
    return ref $data eq 'HASH' ? $data : undef;
}

# ------------------------------------------------------------- stop tokens --

sub _rand_token {
    my $bytes;
    if (open(my $fh, '<:raw', '/dev/urandom')) {
        read($fh, $bytes, 4);
        close $fh;
    }
    if (defined $bytes && length($bytes) == 4) {
        return lc(unpack('H*', $bytes));
    }
    return substr(sha1_hex(time() . $$ . rand()), 0, 8);
}

sub _write_current_token {
    my ($root, $sid, $token) = @_;
    my $dir = "$root/stop-tokens";
    unless (-d $dir) { eval { require File::Path; File::Path::make_path($dir) } }
    my $tmp = "$dir/.$sid.current.tmp.$$";
    open(my $fh, '>:raw', $tmp) or return 0;
    my $ok = print {$fh} "$token\n";
    $ok &&= close($fh);
    unless ($ok) { unlink $tmp; return 0 }
    return 1 if rename($tmp, "$dir/$sid.current");
    unlink $tmp;
    return 0;
}

sub mint_stop_token {
    my ($sid, $p) = @_;
    return undef unless defined $sid && $sid =~ $SID_RE;
    return undef unless ref $p eq 'HASH';
    return undef unless defined $p->{hook_event_name} && $p->{hook_event_name} eq 'Stop';
    return undef if defined agent_id($p);
    my $root = state_dir();
    return undef unless defined $root;

    revoke_stop_token($sid);

    my $dir = "$root/stop-tokens";
    eval { require File::Path; File::Path::make_path($dir) };
    my ($token, $created);
    for (1 .. 5) {
        $token = _rand_token();
        if (sysopen(my $fh, "$dir/$token", O_WRONLY | O_CREAT | O_EXCL)) {
            binmode($fh, ':raw');
            my $json = JSON::PP->new->utf8->canonical->encode({ session_id => $sid, minted_at => time() });
            my $ok = print {$fh} $json . "\n";
            $ok &&= close($fh);
            unless ($ok) { unlink "$dir/$token"; next }
            $created = 1;
            last;
        }
    }
    return undef unless $created;
    unless (_write_current_token($root, $sid, $token)) {
        unlink "$dir/$token";
        return undef;
    }
    return $token;
}

sub revoke_stop_token {
    my ($sid) = @_;
    return 0 unless defined $sid && $sid =~ $SID_RE;
    my $root = state_dir();
    return 0 unless defined $root;
    my $cur_path = "$root/stop-tokens/$sid.current";
    my $removed_tok = 0;
    if (open(my $fh, '<:raw', $cur_path)) {
        local $/;
        my $t = <$fh>;
        close $fh;
        if (defined $t) {
            $t =~ s/\s+$//;
            if ($t =~ $TOKEN_RE) {
                $removed_tok = unlink("$root/stop-tokens/$t") ? 1 : 0;
            }
        }
    }
    my $removed_cur = unlink($cur_path) ? 1 : 0;
    return ($removed_tok || $removed_cur) ? 1 : 0;
}

sub take_stop_token {
    my ($t) = @_;
    return undef unless defined $t && $t =~ $TOKEN_RE;
    my $root = state_dir();
    return undef unless defined $root;
    my $path = "$root/stop-tokens/$t";
    my $claimed = "$path.taken.$$";
    return undef unless rename($path, $claimed);
    my $sid;
    my $ok = 0;
    my $data = _read_json($claimed);
    if (ref $data eq 'HASH' && defined $data->{session_id} && $data->{session_id} =~ $SID_RE) {
        $sid = $data->{session_id};
        my $lockfh = _open_armlock($root, $sid);
        if ($lockfh && _flock_with_timeout($lockfh, 10)) {
            my $cur_path = "$root/stop-tokens/$sid.current";
            if (open(my $fh, '<:raw', $cur_path)) {
                local $/;
                my $cur = <$fh>;
                close $fh;
                if (defined $cur) { $cur =~ s/\s+$//; $ok = 1 if $cur eq $t }
            }
            unlink($cur_path) if $ok;
            flock($lockfh, LOCK_UN);
        }
        close $lockfh if $lockfh;
    }
    unlink($claimed);
    return $ok ? $sid : undef;
}

# ----------------------------------------------------------- invocations ---

sub _strip_heredocs {
    my ($text) = @_;
    return $text unless $text =~ /<<-?/;
    my @lines = split /\n/, $text;
    my @out;
    my $i = 0;
    my $n = scalar @lines;
    while ($i < $n) {
        my $line = $lines[$i];
        my @ops;
        # R8-RTM1 (review M1): the delimiter may be preceded by whitespace
        # (<< 'EOF', << EOF), and there may be more than one heredoc
        # operator on one line -- collect ALL of them, in order, and
        # consume their bodies in that same order. '<<<' (here-string, not
        # a heredoc) is excluded by the <</<< lookaround.
        while ($line =~ /(?<!<)<<(?!<)(-)?[ \t]*(?:'([^'\n]*)'|"([^"\n]*)"|([A-Za-z_][A-Za-z0-9_.-]*))/g) {
            my $dash = $1;
            my $word = defined $2 ? $2 : defined $3 ? $3 : $4;
            push @ops, [$dash, $word] if defined $word && length $word;
        }
        push @out, $line;
        $i++;
        for my $op (@ops) {
            my ($dash, $word) = @$op;
            while ($i < $n) {
                my $body = $lines[$i];
                my $check = $body;
                $check =~ s/^[ \t]+// if $dash;
                if ($check eq $word) { $i++; last }
                $i++;
            }
        }
    }
    return join("\n", @out);
}

sub _segments {
    my ($text) = @_;
    $text = _strip_heredocs($text);
    my @segs;
    my @stack = ({ closer => undef, buf => '' });
    my $len = length($text);
    my $i = 0;
    my $quote = '';
    while ($i < $len) {
        my $c = substr($text, $i, 1);
        my $frame = $stack[-1];
        if ($quote eq "'") {
            $frame->{buf} .= $c;
            $quote = '' if $c eq "'";
            $i++;
            next;
        }
        if ($quote eq '"') {
            if ($c eq '\\' && $i + 1 < $len) {
                $frame->{buf} .= $c . substr($text, $i + 1, 1);
                $i += 2;
                next;
            }
            $frame->{buf} .= $c;
            $quote = '' if $c eq '"';
            $i++;
            next;
        }
        if (defined $frame->{closer} && $c eq $frame->{closer}) {
            push @segs, $frame->{buf};
            pop @stack;
            $i++;
            next;
        }
        # R8-RTM1 (review M1): a '#' at word start (start of text, or right
        # after whitespace/;/|/&/() outside quotes starts a comment that
        # runs to end of line. Its text (backticks, $(...), ; and all) must
        # never be re-parsed for $( )/backtick command substitution -- skip
        # it wholesale, unlike the default per-character walk below.
        if ($c eq '#') {
            my $buf = $frame->{buf};
            if ($buf eq '' || substr($buf, -1, 1) =~ /[ \t;|&(]/) {
                push @segs, $buf;
                $frame->{buf} = '';
                while ($i < $len && substr($text, $i, 1) ne "\n") { $i++ }
                next;
            }
        }
        if ($c eq "'") { $quote = "'"; $frame->{buf} .= $c; $i++; next }
        if ($c eq '"') { $quote = '"'; $frame->{buf} .= $c; $i++; next }
        if ($c eq '\\' && $i + 1 < $len) { $frame->{buf} .= $c . substr($text, $i + 1, 1); $i += 2; next }
        if (substr($text, $i, 2) eq '$(') {
            push @segs, $frame->{buf};
            $frame->{buf} = '';
            push @stack, { closer => ')', buf => '' };
            $i += 2;
            next;
        }
        if ($c eq '`') {
            push @segs, $frame->{buf};
            $frame->{buf} = '';
            push @stack, { closer => '`', buf => '' };
            $i++;
            next;
        }
        if (substr($text, $i, 2) eq '<(' || substr($text, $i, 2) eq '>(') {
            push @segs, $frame->{buf};
            $frame->{buf} = '';
            push @stack, { closer => ')', buf => '' };
            $i += 2;
            next;
        }
        if ($c eq ')' && !defined $frame->{closer}) {
            push @segs, $frame->{buf};
            $frame->{buf} = '';
            $i++;
            next;
        }
        if ($c eq ';' || $c eq '|' || $c eq "\n") {
            push @segs, $frame->{buf};
            $frame->{buf} = '';
            $i++;
            next;
        }
        if ($c eq '&') {
            my $prev = length($frame->{buf}) ? substr($frame->{buf}, -1, 1) : '';
            my $nextc = ($i + 1 < $len) ? substr($text, $i + 1, 1) : '';
            if ($prev eq '>' || $prev eq '<' || $nextc eq '>') {
                $frame->{buf} .= $c;
                $i++;
                next;
            }
            push @segs, $frame->{buf};
            $frame->{buf} = '';
            $i++;
            next;
        }
        $frame->{buf} .= $c;
        $i++;
    }
    for my $frame (@stack) { push @segs, $frame->{buf} }
    return @segs;
}

sub _tokenize_words {
    my ($seg) = @_;
    my @words;
    my $len = length($seg);
    my $i = 0;
    while ($i < $len) {
        my $c = substr($seg, $i, 1);
        if ($c eq ' ' || $c eq "\t") { $i++; next }
        my $word_start = $i;
        my $value = '';
        my @flags; # per-character: 1 iff that character of $value is unpredictable
        my $unpredictable = 0;
        my $first = 1;
        while ($i < $len) {
            my $cc = substr($seg, $i, 1);
            last if $cc eq ' ' || $cc eq "\t";
            if ($cc eq "'") {
                $i++;
                while ($i < $len && substr($seg, $i, 1) ne "'") {
                    $value .= substr($seg, $i, 1);
                    push @flags, 0;
                    $i++;
                }
                $i++ if $i < $len;
                $first = 0;
                next;
            }
            if ($cc eq '"') {
                $i++;
                while ($i < $len && substr($seg, $i, 1) ne '"') {
                    my $c2 = substr($seg, $i, 1);
                    if ($c2 eq '\\' && $i + 1 < $len) {
                        $unpredictable = 1;
                        $value .= substr($seg, $i + 1, 1);
                        push @flags, 1;
                        $i += 2;
                        next;
                    }
                    my $f = ($c2 eq '$' || $c2 eq '`') ? 1 : 0;
                    $unpredictable = 1 if $f;
                    $value .= $c2;
                    push @flags, $f;
                    $i++;
                }
                $i++ if $i < $len;
                $first = 0;
                next;
            }
            if ($cc eq '\\' && $i + 1 < $len) {
                $value .= substr($seg, $i + 1, 1);
                push @flags, 0;
                $i += 2;
                $first = 0;
                next;
            }
            if ($cc eq '$' || $cc eq '`' || $cc eq '*' || $cc eq '?' || $cc eq '[' || $cc eq '{') {
                $unpredictable = 1;
                $value .= $cc;
                push @flags, 1;
                $i++;
                $first = 0;
                next;
            }
            if ($cc eq '~' && $first) {
                $unpredictable = 1;
                $value .= $cc;
                push @flags, 1;
                $i++;
                $first = 0;
                next;
            }
            $value .= $cc;
            push @flags, 0;
            $i++;
            $first = 0;
        }
        # A bare { or } word (never glued to anything else) is a transparent
        # grouping token, not brace expansion, so it is always a literal
        # (RV-M3/RT-M4: '{ butler-continuity status; }' must be recognised).
        if ($value eq '{' || $value eq '}') { $unpredictable = 0 }
        # R8-B1 (Decision 55, review B1/redteam H1): a word with an
        # unexpandable prefix (~/..., $HOME/..., ${VAR}/..., $VAR/...) still
        # carries a fully literal basename after its LAST unquoted '/' or
        # '\'. Record that basename as 'tail' whenever every character after
        # that last slash is itself predictable -- so a variable or glob
        # inside the basename itself (not just the directory) still leaves
        # tail undef, per spec.
        my $tail;
        {
            my $lastslash = -1;
            for (my $k = 0; $k < length($value); $k++) {
                my $ch = substr($value, $k, 1);
                if ($ch eq '/' || $ch eq '\\') { $lastslash = $k }
            }
            if ($lastslash >= 0) {
                my $tailstr = substr($value, $lastslash + 1);
                if (length($tailstr)) {
                    my $ok = 1;
                    for my $k ($lastslash + 1 .. $#flags) { $ok = 0 if $flags[$k] }
                    $tail = $tailstr if $ok;
                }
            }
        }
        my $raw = substr($seg, $word_start, $i - $word_start);
        push @words, { literal => ($unpredictable ? undef : $value), tail => $tail, raw => $raw };
    }
    return \@words;
}

sub _strip_redirection_words {
    my (@words) = @_;
    my @out;
    my $j = 0;
    my $n = scalar @words;
    while ($j < $n) {
        my $lit = $words[$j]{literal};
        if (defined $lit && $lit =~ /^[0-9]*(?:>>?|<|>&|<&|&>)(.*)$/) {
            my $rest = $1;
            $j++;
            if ($rest eq '') { $j++ if $j < $n }
            next;
        }
        push @out, $lit;
        $j++;
    }
    return @out;
}

sub _reduce_and_match {
    my ($words, $name) = @_;
    # A leading '(' glued to the command word, e.g. "(butler-continuity status)",
    # is a subshell open with no space after it. Strip it from the first
    # word's literal (RV-M3/RT-M4); the closing ')' is already a segment
    # separator, so nothing else is needed.
    if (@$words && defined $words->[0]{literal} && $words->[0]{literal} =~ /^\(+(.*)$/) {
        my $rest = $1;
        if (length $rest) {
            $words = [ { literal => $rest }, @{$words}[1 .. $#$words] ];
        }
        else {
            $words = [ @{$words}[1 .. $#$words] ];
        }
    }
    my $n = scalar @$words;
    return undef if $n == 0;
    my $first_lit = $words->[0]{literal};
    return undef if defined $first_lit && $READER_BLACKLIST{$first_lit};

    my $i = 0;
    while ($i < $n && defined $words->[$i]{literal} && ($words->[$i]{literal} eq '(' || $words->[$i]{literal} eq '{')) {
        $i++;
    }

    my $progress = 1;
    while ($progress) {
        $progress = 0;
        while ($i < $n) {
            my $lit = $words->[$i]{literal};
            my $raw = $words->[$i]{raw};
            if (defined $lit && $lit =~ /^[A-Za-z_][A-Za-z0-9_]*=/) { $i++; $progress = 1; next }
            # R8-M2 (redteam M2): an env-assignment prefix whose VALUE
            # contains an expansion ($PWD/a, etc) makes the whole word
            # unpredictable (literal undef), but the assignment's NAME= part
            # is never itself expanded, so it is still a transparent prefix
            # regardless of how unpredictable its value is. Detected off the
            # raw (unquoted) text, since quoting never touches the name.
            if (!defined $lit && defined $raw && $raw =~ /^[A-Za-z_][A-Za-z0-9_]*=/) { $i++; $progress = 1; next }
            if (defined $lit && $lit =~ /^[0-9]*(?:>>?|<|>&|<&|&>)(.*)$/) {
                my $rest = $1;
                $i++;
                if ($rest eq '') { $i++ if $i < $n }
                $progress = 1;
                next;
            }
            last;
        }
        last unless $i < $n && defined $words->[$i]{literal};
        my $lit = $words->[$i]{literal};
        if ($lit eq 'timeout') {
            $i++;
            $progress = 1;
            while ($i < $n && defined $words->[$i]{literal} && $words->[$i]{literal} =~ /^-/) {
                my $opt = $words->[$i]{literal};
                if ($opt =~ /^(?:--kill-after=|--signal=)/) {
                    $i++;
                }
                elsif ($opt eq '-k' || $opt eq '-s' || $opt eq '--kill-after' || $opt eq '--signal') {
                    $i++;
                    $i++ if $i < $n;
                }
                else {
                    # --preserve-status, --foreground, -v, or an unknown flag
                    $i++;
                }
            }
            $i++ if $i < $n;
        }
        elsif ($lit eq 'env') {
            $i++;
            $progress = 1;
            if ($i < $n && defined $words->[$i]{literal} && $words->[$i]{literal} eq '-i') { $i++ }
            while ($i < $n && defined $words->[$i]{literal} && $words->[$i]{literal} =~ /^[A-Za-z_][A-Za-z0-9_]*=/) { $i++ }
        }
        elsif ($lit eq 'nice') {
            $i++;
            $progress = 1;
            if ($i < $n && defined $words->[$i]{literal} && $words->[$i]{literal} eq '-n') { $i += 2 }
        }
        elsif ($lit eq 'nohup' || $lit eq 'command' || $lit eq 'exec') {
            $i++;
            $progress = 1;
        }
        elsif ($lit eq 'then' || $lit eq 'do' || $lit eq 'else' || $lit eq 'elif'
            || $lit eq '!' || $lit eq 'time')
        {
            $i++;
            $progress = 1;
        }
    }

    if ($i < $n && defined $words->[$i]{literal} && $words->[$i]{literal} =~ /^(?:perl|bash|sh)$/) {
        $i++;
        while ($i < $n && defined $words->[$i]{literal} && $words->[$i]{literal} =~ /^-/) { $i++ }
    }

    return undef unless $i < $n;
    my $cmd = $words->[$i]{literal};
    # R8-B1 (Decision 55, review B1/redteam H1): the command word itself may
    # be unpredictable (~/..., $HOME/..., ${VAR}/..., $VAR/...) while its
    # basename after the last unquoted '/' or '\' is fully literal -- fall
    # back to that literal basename ONLY at this, the command-word position.
    # Argv words never consult 'tail'.
    $cmd = $words->[$i]{tail} unless defined $cmd;
    return undef unless defined $cmd;
    my $base = $cmd;
    $base =~ s{.*[/\\]}{};
    return undef unless $base =~ /^\Q$name\E(?:\.sh|\.pl)?$/;

    my @argv_words = @{$words}[($i + 1) .. ($n - 1)];
    my @argv = _strip_redirection_words(@argv_words);
    return \@argv;
}

sub invocations {
    my ($command, $name) = @_;
    return () unless defined $command && defined $name && length $name;
    my @segs = _segments($command);
    my @results;
    for my $seg (@segs) {
        my $words = _tokenize_words($seg);
        my $argv = _reduce_and_match($words, $name);
        push @results, $argv if defined $argv;
    }
    return @results;
}

# sole_invocation($command, $name): the argv only when $command is EXACTLY
# one invocation of $name and nothing else -- no other segment (no &&/||/;
# tail, no other pipeline stage) and no trailing background '&' job.
# invocations()==1 cannot express this (RV-M3/RT-M4): 'butler-hold a1 &&
# sleep 999' and 'butler-hold a1; long-job' each yield exactly one match from
# invocations(), which over-exempts the whole compound command for any
# consumer using that count as a sole-call predicate.
sub sole_invocation {
    my ($command, $name) = @_;
    return undef unless defined $command && defined $name && length $name;
    my $trimmed = $command;
    $trimmed =~ s/^\s+//;
    $trimmed =~ s/\s+$//;
    return undef unless length $trimmed;
    # A trailing background '&' job (not part of a redirection) means the
    # command is not solely the invocation.
    if ($trimmed =~ /(?<![<>&])&\s*$/) {
        return undef;
    }
    my @segs = _segments($trimmed);
    my @nonempty = grep { /\S/ } @segs;
    return undef unless scalar(@nonempty) == 1;
    my $words = _tokenize_words($nonempty[0]);
    return _reduce_and_match($words, $name);
}

# --------------------------------------------------------------- payload ---

my $PAYLOAD_CACHE  = {};
my $PAYLOAD_LOADED = 0;
my $PAYLOAD_OK     = 0;
my $PARSE_COUNT    = 0;

# R6-M2 (red-team MEDIUM-2, Decision 51): JSON::PP's decode dies outright on
# a lone (unpaired) UTF-16 surrogate escape -- one bad code unit sliced out
# of free text such as last_assistant_message, or a Node JSON.stringify
# artefact of an unpaired surrogate -- rather than treating it as ordinary
# malformed JSON. Left unhandled, that turns a single bad code unit into a
# fail-open {} for the WHOLE payload (session_id and hook_event_name lost
# too), which is exactly the "stranding" red-team found. Repair every lone
# \uD800-\uDFFF escape (one that is not one half of a valid high+low pair)
# to � (U+FFFD) BEFORE decoding, so the rest of an otherwise well-formed
# payload still comes through. A genuinely paired surrogate escape is left
# byte-for-byte untouched.
sub _repair_lone_surrogates {
    my ($raw) = @_;
    return $raw unless defined $raw && length $raw;
    # Pass 1: a high surrogate (\uD800-\uDBFF, case-insensitive hex digits --
    # a real Node/JSON.stringify artefact is lowercase, e.g. \ud800)
    # immediately followed by a low surrogate (\uDC00-\uDFFF) is a valid
    # pair -- leave it alone, byte for byte. A high surrogate with no such
    # follower is lone -> the literal JSON escape "�" (U+FFFD), so the
    # SUBSEQUENT decode turns it into one replacement character.
    $raw =~ s{
        \\u([Dd][89abAB][0-9A-Fa-f]{2})
        (\\u[Dd][c-fC-F][0-9A-Fa-f]{2})?
    }{
        defined $2 ? "\\u$1$2" : "\\ufffd"
    }gex;
    # Pass 2: any low surrogate escape that survives pass 1 was never
    # preceded by a matching high surrogate, so it is lone too.
    $raw =~ s{\\u[Dd][c-fC-F][0-9A-Fa-f]{2}}{\\ufffd}gx;
    return $raw;
}

sub load_payload {
    my ($raw) = @_;
    $PARSE_COUNT++;
    my $ok = 1;
    my $data;
    if (!defined $raw) {
        $ok = 0;
    }
    else {
        $data = eval { JSON::PP->new->utf8->decode($raw) };
        if (!defined $data || ref($data) ne 'HASH') {
            my $repaired = _repair_lone_surrogates($raw);
            if ($repaired ne $raw) {
                $data = eval { JSON::PP->new->utf8->decode($repaired) };
            }
            if (!defined $data || ref($data) ne 'HASH') {
                $ok = 0;
                if (defined $@ && length $@) {
                    my $err = $@;
                    $err =~ s/\s+\z//;
                    warn "BpHook: payload decode failed: $err\n";
                }
            }
        }
    }
    if ($ok && defined $ENV{BP_PAYLOAD_TRUNCATED} && $ENV{BP_PAYLOAD_TRUNCATED} eq '1') { $ok = 0 }
    if ($ok) {
        $PAYLOAD_CACHE = $data;
        $PAYLOAD_OK = 1;
    }
    else {
        $PAYLOAD_CACHE = {};
        $PAYLOAD_OK = 0;
    }
    $PAYLOAD_LOADED = 1;
    return;
}

sub payload    { return $PAYLOAD_CACHE }
sub payload_ok { return $PAYLOAD_OK ? 1 : 0 }
sub parse_count { return $PARSE_COUNT }

sub _read_stdin_bulk {
    binmode(STDIN, ':raw');
    my $buf = '';
    my $cap = 8 * 1024 * 1024 + 1;
    while (length($buf) < $cap) {
        my $chunk;
        my $n = sysread(STDIN, $chunk, 65536);
        last unless defined $n && $n > 0;
        $buf .= $chunk;
    }
    if (length($buf) > 8 * 1024 * 1024) {
        $ENV{BP_PAYLOAD_TRUNCATED} = 1;
        $buf = substr($buf, 0, 8 * 1024 * 1024);
    }
    return $buf;
}

sub _append_hook_error {
    my ($tag, $msg) = @_;
    my $root = state_dir();
    return unless defined $root;
    eval {
        require File::Path;
        File::Path::make_path($root);
        my $path = "$root/hook-errors.log";
        if (-f $path) {
            my $size = (stat($path))[7];
            if (defined $size && $size > 256 * 1024) { rename($path, "$path.1") }
        }
        my $first = defined $msg ? $msg : '';
        $first =~ s/\r?\n.*$//s;
        $first = substr($first, 0, 300);
        my $line = _iso_now() . "\t" . (defined $tag ? $tag : '?') . "\t" . $first . "\n";
        my $bytes = $line;
        if (utf8::is_utf8($bytes)) { utf8::encode($bytes) }
        sysopen(my $fh, $path, O_WRONLY | O_APPEND | O_CREAT) or return;
        binmode($fh, ':raw');
        syswrite($fh, $bytes);
        close $fh;
    };
    return;
}

sub main {
    my ($module, @args) = @_;
    # R8-RVM1 (review M1): track whether the warn handler actually fired
    # for THIS invocation, not whether payload_ok() is true -- payload_ok()
    # is also false for a JSON array/null payload and for a
    # BP_PAYLOAD_TRUNCATED=1 truncation of an otherwise well-formed payload,
    # and load_payload() never warns in any of those cases, so gating on
    # payload_ok() alone left a missing/require-failing module unlogged in
    # exactly those cases.
    my $decode_warned = 0;
    local $SIG{__WARN__} = sub { $decode_warned = 1; _append_hook_error($module, $_[0]) };
    my $raw = _read_stdin_bulk();
    load_payload($raw);

    return 0 unless defined $module && $module =~ /^[A-Za-z][A-Za-z0-9_]*(?:::[A-Za-z][A-Za-z0-9_]*)*$/;

    my $relpath = $module;
    $relpath =~ s{::}{/}g;

    my $require_ok = eval {
        require "BpHook/$relpath.pm";
        1;
    };
    unless ($require_ok) {
        # Only skip this when a payload-decode failure has ALREADY been
        # recorded (via the $SIG{__WARN__} handler above) for this same
        # invocation -- a missing module on top of unparseable input adds
        # no information beyond "nothing ran", and R7-warn requires exactly
        # one hook-errors.log line per malformed payload. Otherwise (no
        # decode warning fired -- payload was valid JSON, just not usable,
        # or truncated) the missing module IS the only thing worth logging.
        _append_hook_error($module, $@) unless $decode_warned;
        return 0;
    }

    my $ret;
    my $ok = eval {
        my $fn = "BpHook::${module}::run";
        no strict 'refs';
        $ret = &$fn(payload(), @args);
        1;
    };
    unless ($ok) {
        _append_hook_error($module, $@);
        return 0;
    }

    my $rs = defined $ret ? "$ret" : '';
    return ($rs =~ /^\s*2\s*$/) ? 2 : 0;
}

# ---------------------------------------------------------- deny/context ---

sub deny {
    my (@lines) = @_;
    binmode(STDERR, ':raw');
    for my $l (@lines) {
        my $b = defined $l ? _decode_maybe($l) : '';
        utf8::encode($b) if utf8::is_utf8($b);
        print STDERR $b . "\n";
    }
    return 2;
}

sub context {
    my ($text) = @_;
    my $p = payload();
    my $event = (ref $p eq 'HASH' && defined $p->{hook_event_name} && length $p->{hook_event_name})
        ? $p->{hook_event_name}
        : 'PostToolUse';
    $text = _decode_maybe($text);
    my $out = { hookSpecificOutput => { hookEventName => $event, additionalContext => $text } };
    my $json = eval { JSON::PP->new->utf8->canonical->encode($out) };
    binmode(STDOUT, ':raw');
    print STDOUT (defined $json ? $json : '{}') . "\n";
    return 0;
}

1;
