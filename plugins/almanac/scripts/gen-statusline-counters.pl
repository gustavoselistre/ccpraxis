#!/usr/bin/env perl
# gen-statusline-counters.pl -- prints the almanac counting block that
# scripts/statusline.pl embeds between its "GENERATED FROM
# gen-statusline-counters.pl" markers (blueprint hook-continuity-remake,
# package 10, spec section 2.1).
#
# WHY GENERATED. statusline.pl is a standalone installed payload: it may load
# nothing from this repo (Decision 18, AC-S3), and it runs on every render,
# where a subprocess costs about 292 ms on the Windows host. So the counting
# code can be neither imported nor spawned. It is emitted here instead, next
# to the modules whose rules it restates, and statusline.pl carries the exact
# bytes. A test compares the two byte for byte, so a drift fails the suite
# rather than silently miscounting.
#
# Usage: perl plugins/almanac/scripts/gen-statusline-counters.pl
#   Prints the payload to STDOUT and exits 0. Takes no arguments; any
#   argument prints one usage line to STDERR and exits 2. Writes no file.
#
# The payload is deterministic, LF-only, printable ASCII, with no blank lines
# and no trailing whitespace. It contains subs, `my` scalars and nothing else
# at column 0; no use/require, no spawn, no write-mode open (spec 2.2).
use strict;
use warnings;
use File::Basename ();
BEGIN {
    # Separators FIRST, then dirname -- __FILE__ can carry backslashes on
    # Windows and dirname on a mixed-separator path misbehaves. Same shape as
    # BpTurnCaps::script_dir_for; asserted repo-wide by turn-cap-consistency.t's C9.
    (my $self = __FILE__) =~ s{\\}{/}g;
    unshift @INC, File::Basename::dirname($self);
}
use Almanac::GlobalCounts ();

if (@ARGV) {
    print STDERR "usage: perl plugins/almanac/scripts/gen-statusline-counters.pl (takes no arguments)\n";
    exit 2;
}

my $file_name = $Almanac::GlobalCounts::FILE_NAME;
die "gen-statusline-counters: GlobalCounts FILE_NAME is not a plain file name\n"
    unless defined $file_name && $file_name =~ /\A[A-Za-z0-9][A-Za-z0-9._-]*\z/;

my $payload = <<'PAYLOAD';
# ALMANAC COUNTERS -- generated from plugins/almanac/scripts/gen-statusline-counters.pl.
# Regenerate: perl plugins/almanac/scripts/gen-statusline-counters.pl
#
# The one shared accessor for almanac counts, restated from Almanac::Store,
# Almanac::GlobalCounts and almanac-task.pl because this file may import
# nothing. Every public sub wraps its body in eval and degrades to the
# "unavailable" value (undef); nothing here ever dies to its caller, spawns,
# or writes. Paths are byte strings throughout.
#
#   almanac_counts(cwd => $dir, sandbox => 0|1) -> {
#       project => { todo, note, task, decision } | undef,
#       global  => { todo, note } | undef }
#   almanac_focus(cwd => $dir, session => $sid) -> undef | { name, current }
my $ALMANAC_SNAPSHOT_NAME = '@@FILE_NAME@@';
# Frontmatter already read this render, keyed by the record dir's identity
# (device and inode where the platform has them, else its path) plus the
# entry name. A focused tasklist is often the project itself under another
# spelling of its path, and a file open is the dominant cost of a render, so
# its task files are read once, not twice.
my $ALMANAC_FM_SEEN = {};
my $ALMANAC_DIR_KEY = {};
# _alm_bytes($s) -> $s as UTF-8 bytes. A JSON-decoded path is a character
# string; the filesystem wants the bytes.
sub _alm_bytes {
    my ($s) = @_;
    return '' unless defined $s && !ref($s);
    $s = "$s";
    utf8::encode($s) if utf8::is_utf8($s);
    return $s;
}
sub _alm_is_abs {
    my ($p) = @_;
    return 0 unless defined $p && length $p;
    return 1 if substr($p, 0, 1) eq '/';
    return ($p =~ m{\A[A-Za-z]:(?:/|\z)}) ? 1 : 0;
}
# _alm_is_id($id) -> 1 when $id is a record id (Almanac::Store's grammar).
sub _alm_is_id {
    my ($id) = @_;
    return 0 unless defined $id && !ref($id);
    return 0 unless length($id) <= 128 && $id =~ /\A[A-Za-z0-9][A-Za-z0-9._-]*\z/;
    return 0 if index($id, '..') >= 0;
    return 0 if $id =~ /\A(?:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])\z/i;
    return 1;
}
# _alm_project_root($cwd) -> the project root, or undef. Mirrors
# Almanac::Store::resolve_project_root textually (Cwd is not allowed here):
# the nearest ancestor holding .ccpraxis-local-data or .git, else a non-empty
# CLAUDE_PROJECT_DIR, else the start. A relative start is never walked, so
# the process cwd is never consulted; a relative result is no project.
sub _alm_project_root {
    my ($cwd) = @_;
    my $start = _alm_bytes($cwd);
    $start =~ tr{\\}{/};
    my $project;
    if (_alm_is_abs($start)) {
        my $dir = $start;
        $dir =~ s{/+\z}{} unless $dir =~ m{\A(?:[A-Za-z]:)?/\z};
        while (length $dir) {
            if (-d "$dir/.ccpraxis-local-data" || -e "$dir/.git") { $project = $dir; last }
            last if $dir =~ m{\A[A-Za-z]:/?\z} || $dir eq '/';
            my $idx = rindex($dir, '/');
            last if $idx < 0;
            my $parent = substr($dir, 0, $idx);
            $parent = '/' if $parent eq '';
            $parent = "$parent/" if $parent =~ m{\A[A-Za-z]:\z};
            last if $parent eq $dir;
            $dir = $parent;
        }
    }
    if (!defined $project) {
        my $cpd = $ENV{CLAUDE_PROJECT_DIR};
        $project = (defined $cpd && length $cpd) ? $cpd : $start;
        $project =~ tr{\\}{/};
    }
    $project =~ s{/+\z}{};
    return undef unless _alm_is_abs($project);
    return $project;
}
# _alm_home() -> ALMANAC_HOME, else HOME, else USERPROFILE; undef if none.
sub _alm_home {
    for my $h ($ENV{ALMANAC_HOME}, $ENV{HOME}, $ENV{USERPROFILE}) {
        next unless defined $h && length $h;
        my $v = $h;
        $v =~ tr{\\}{/};
        $v =~ s{/+\z}{};
        return $v;
    }
    return undef;
}
# _alm_record_names($dir) -> the entries of $dir that name a record. A
# missing or unreadable dir has none.
sub _alm_record_names {
    my ($dir) = @_;
    my @names;
    opendir(my $dh, $dir) or return @names;
    while (defined(my $e = readdir($dh))) {
        next unless $e =~ /\A(.+)\.md\z/s;
        push @names, $e if _alm_is_id($1);
    }
    closedir($dh);
    return @names;
}
sub _alm_dir_key {
    my ($dir) = @_;
    my $k = $ALMANAC_DIR_KEY->{$dir};
    return $k if defined $k;
    my @st = stat($dir);
    $k = (@st && $st[1]) ? "inode:$st[0]:$st[1]" : "path:$dir";
    $ALMANAC_DIR_KEY->{$dir} = $k;
    return $k;
}
# almanac_parse_record($bytes) -> \%fields, or undef when Almanac::Record
# would refuse the bytes (almanac-records Decision 38: this parser accepts
# exactly what Almanac::Record::check accepts). Field values are decoded
# characters, exactly as Almanac::Record::parse returns them. Refused:
# invalid UTF-8 (strict: no surrogate, noncharacter or code point past
# U+10FFFF), a first line that is not exactly "---", no closing "---", a CR
# on either delimiter or any field line, an empty front matter, a line that
# is not "key: value" (one colon, one space), a duplicate key, and a value
# carrying C0 (less TAB), DEL, C1, U+2028 or U+2029. A value is never
# trimmed, so "status: open " is not "open".
sub almanac_parse_record {
    my ($bytes) = @_;
    return undef unless defined $bytes && !ref($bytes);
    my $text = "$bytes";
    if ($text =~ /[^\x00-\x7f]/) {
        return undef if utf8::is_utf8($text);
        return undef unless utf8::decode($text);
        return undef if $text =~ /[^\x{0}-\x{10FFFF}]/;
        return undef if $text =~ /@@BAD_CODE_POINTS@@/;
    }
    my @l = split /\n/, $text, -1;
    return undef unless @l && $l[0] eq '---';
    my $closing;
    for my $i (1 .. $#l) {
        if ($l[$i] =~ /\A---\r?\z/) { $closing = $i; last }
    }
    return undef unless defined $closing && $closing >= 2 && $l[$closing] eq '---';
    my %fields;
    for my $i (1 .. $closing - 1) {
        return undef unless $l[$i] =~ /\A([A-Za-z0-9_]+): (.*)\z/;
        my ($k, $v) = ($1, $2);
        return undef if exists $fields{$k};
        return undef if $v =~ /[\x00-\x08\x0A-\x1F\x7F-\x9F\x{2028}\x{2029}]/;
        $fields{$k} = $v;
    }
    return \%fields;
}
# _alm_frontmatter($dir, $entry) -> almanac_parse_record's fields for that
# file, or 0 when it cannot be read, exceeds @@READ_CAP@@ bytes, or is refused.
sub _alm_frontmatter {
    my ($dir, $entry) = @_;
    my $path = "$dir/$entry";
    my $key = _alm_dir_key($dir) . "/$entry";
    my $seen = $ALMANAC_FM_SEEN->{$key};
    return $seen if defined $seen;
    my $fm = 0;
    if (open(my $fh, '<:raw', $path)) {
        # Read in 8 KiB steps: one read() with the whole cap as its length
        # would allocate that much for every record, and records are small.
        my $bytes = '';
        my $n = 0;
        while (1) {
            my $got = read($fh, $bytes, 8192, length $bytes);
            if (!defined $got) { $n = undef; last }
            $n += $got;
            last if $got < 8192 || $n > @@READ_CAP@@;
        }
        close($fh);
        if (defined $n && $n <= @@READ_CAP@@) {
            my $f = almanac_parse_record($bytes);
            $fm = $f if $f;
        }
    }
    $ALMANAC_FM_SEEN->{$key} = $fm;
    return $fm;
}
# _alm_count($dir, @statuses) -> the records in $dir that parse and whose
# status is one of @statuses; with no statuses, every record that parses.
sub _alm_count {
    my ($dir, @statuses) = @_;
    my %want = map { ($_ => 1) } @statuses;
    my $n = 0;
    for my $e (_alm_record_names($dir)) {
        my $fm = _alm_frontmatter($dir, $e);
        next unless $fm;
        if (@statuses) {
            next unless defined $fm->{status};
            next unless $want{ $fm->{status} };
        }
        $n++;
    }
    return $n;
}
sub _alm_nonneg_int {
    my ($v) = @_;
    return 0 unless defined $v && !ref($v);
    return ("$v" =~ /\A\d+\z/) ? 1 : 0;
}
# _alm_snapshot($path) -> { todo, note } or undef. One attempt, never a
# retry: Almanac::GlobalCounts::_read_snapshot_once's checks, in its order.
sub _alm_snapshot {
    my ($path) = @_;
    return undef unless -f $path;
    my @st = stat($path);
    return undef unless @st && defined $st[7] && $st[7] >= 1 && $st[7] <= 4096;
    open(my $fh, '<:raw', $path) or return undef;
    my $bytes = '';
    my $n = read($fh, $bytes, 4097);
    close($fh);
    return undef unless defined $n && $n >= 1 && $n <= 4096;
    my $d = eval { JSON::PP->new->decode($bytes) };
    return undef unless ref($d) eq 'HASH';
    return undef unless defined $d->{schema} && !ref($d->{schema}) && "$d->{schema}" eq '1';
    my $at = $d->{generated_at};
    return undef unless defined $at && !ref($at) && $at =~ /\A\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ\z/;
    my $todo = $d->{todo};
    return undef unless ref($todo) eq 'HASH';
    for my $k (qw(open done total)) {
        return undef unless _alm_nonneg_int($todo->{$k});
    }
    my $note = $d->{note};
    return undef unless ref($note) eq 'HASH' && _alm_nonneg_int($note->{total});
    return { todo => 0 + $todo->{open}, note => 0 + $note->{total} };
}
sub almanac_counts {
    my (%o) = @_;
    my ($project, $global);
    eval {
        my $root = _alm_project_root($o{cwd});
        if (defined $root) {
            my $ad = "$root/.ccpraxis-local-data/almanac";
            $project = {
                todo     => _alm_count("$ad/todo", 'open'),
                note     => _alm_count("$ad/note"),
                task     => _alm_count("$ad/task", 'pending', 'doing', 'blocked'),
                decision => _alm_count("$ad/decision", 'unanswered'),
            };
        }
        1;
    } or $project = undef;
    eval {
        my $home = _alm_home();
        if (defined $home && $o{sandbox}) {
            $global = _alm_snapshot("$home/.claude/$ALMANAC_SNAPSHOT_NAME");
        }
        elsif (defined $home) {
            my $v = "$home/.claude/claude-code-vault/almanac";
            $global = { todo => _alm_count("$v/todo", 'open'), note => _alm_count("$v/note") };
        }
        1;
    } or $global = undef;
    return { project => $project, global => $global };
}
# _alm_text($chars) -> a decoded field value with C0 and DEL removed.
sub _alm_text {
    my ($s) = @_;
    $s = '' unless defined $s;
    $s =~ s/[\x00-\x1f\x7f]//g;
    return $s;
}
sub _alm_focus {
    my (%o) = @_;
    my $sid = $o{session};
    return undef unless _alm_is_id($sid);
    my $root = _alm_project_root($o{cwd});
    return undef unless defined $root;
    my $fm = _alm_frontmatter("$root/.ccpraxis-local-data/almanac/task-focus", "$sid.md");
    return undef unless $fm && defined $fm->{tasklist};
    my $tl = $fm->{tasklist};
    $tl =~ tr{\\}{/};
    $tl =~ s{/+\z}{};
    return undef unless length $tl;
    my $base = $tl;
    $base =~ s{\A.*/}{}s;
    my $name = _alm_text($base);
    return undef unless length $name;
    my $current;
    # The value is decoded text; the filesystem wants its bytes. A relative
    # tasklist would resolve against the process cwd, so it names only.
    my $tl_bytes = _alm_bytes($tl);
    return { name => $name, current => $current } unless _alm_is_abs($tl_bytes);
    my $dir = "$tl_bytes/.ccpraxis-local-data/almanac/task";
    my @doing;
    for my $e (_alm_record_names($dir)) {
        my $t = _alm_frontmatter($dir, $e);
        next unless $t && defined $t->{status} && $t->{status} eq 'doing';
        (my $id = $e) =~ s/\.md\z//;
        push @doing, [ $t->{rank}, $id, $t->{title} ];
    }
    @doing = sort {
        (defined $a->[0] && defined $b->[0]) ? (($a->[0] cmp $b->[0]) || ($a->[1] cmp $b->[1]))
      : defined $a->[0] ? -1
      : defined $b->[0] ? 1
      : ($a->[1] cmp $b->[1])
    } @doing;
    if (@doing && defined $doing[0][2]) {
        $current = _alm_text($doing[0][2]);
        $current = undef unless length $current;
    }
    return { name => $name, current => $current };
}
sub almanac_focus {
    my (%o) = @_;
    my $focus;
    eval { $focus = _alm_focus(%o); 1 } or $focus = undef;
    return $focus;
}
PAYLOAD

$payload =~ s/\@\@FILE_NAME\@\@/$file_name/g;

# The code points strict UTF-8 (Encode's 'UTF-8', which Almanac::Record::check
# uses) refuses but utf8::decode admits: surrogates and the 66 noncharacters.
# Spelled out as one character class so the payload needs no \p{} property,
# whose first use can load Unicode tables at render time.
my $bad = '[\x{D800}-\x{DFFF}\x{FDD0}-\x{FDEF}'
        . join('', map { sprintf('\x{%X}\x{%X}', $_ * 0x10000 + 0xFFFE, $_ * 0x10000 + 0xFFFF) } 0 .. 16)
        . ']';
$payload =~ s/\@\@BAD_CODE_POINTS\@\@/$bad/g;

# A record larger than this is not counted. Records are a few hundred bytes;
# the cap only bounds what one render may read from a hostile or broken file.
my $read_cap = 1048576;
$payload =~ s/\@\@READ_CAP\@\@/$read_cap/g;
die "gen-statusline-counters: unreplaced placeholder\n" if $payload =~ /\@\@[A-Z_]+\@\@/;
print $payload;
exit 0;
