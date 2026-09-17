package Almanac::Record;
# Almanac::Record -- the on-disk record format shared by every almanac record
# type: one file, frontmatter plus body, exactly as almanac-bug.pl already
# renders (blueprint almanac-records, package 02-record-format). Extracted
# from almanac-bug.pl's _render/_parse/has_forbidden_bytes/_read_file/new_id
# (see specs/02-record-format-spec.md, section 1). almanac-bug.pl is NOT
# edited by this module and is not depended on at runtime -- the two stay in
# sync only through the equivalence test in almanac-record-refusals.t (AC20).
#
# THE WHOLE UTF-8 STORY: decode once on the way in, encode once on the way
# out. `fields` and `body` in the record hash are DECODED characters; `raw`
# (read_file() only) is the original BYTES; serialize() returns BYTES.
#
# A module must never call exit(). Every public function that can fail dies
# with a blessed Almanac::Record::Error (kind, path, problems, message,
# exit_code => 2) instead -- fatal() below is the one sanctioned place exit()
# happens, and only a caller (package 17's CLI) invokes it.
use strict;
use warnings;
use Encode ();
use Almanac::Lock ();

our $VERSION = '1.0';

# ---------------------------------------------------------------------------
# Almanac::Record::Error -- the blessed die payload. Stringifies to its own
# message so an uncaught die is still readable on a bare STDERR dump.
# ---------------------------------------------------------------------------
package Almanac::Record::Error;

use overload '""' => sub { $_[0]->{message} }, fallback => 1;

sub new {
    my ($class, %a) = @_;
    return bless {
        kind      => $a{kind},
        path      => $a{path},
        problems  => (ref $a{problems} eq 'ARRAY') ? $a{problems} : [],
        message   => $a{message},
        exit_code => 2,
    }, $class;
}

package Almanac::Record;

# EXIT_MALFORMED() -- the only place the exit code is written down.
sub EXIT_MALFORMED { return 2 }

# ---------------------------------------------------------------------------
# has_forbidden_bytes($value) -> 1 | 0
#
# The one definition of "not safe in a frontmatter value" for this module.
# Behaviourally equivalent to AlmanacBug::has_forbidden_bytes (asserted by
# almanac-record-refusals.t AC20 over a shared vector table) -- see the spec
# section 2.6 for the rule this restates: decode first when the bytes are
# valid UTF-8 (the em-dash fix), reject C0 (less TAB) + DEL + C1, reject the
# UTF-8 byte form of U+2028/U+2029, reject the decoded characters
# U+2028/U+2029, TAB is allowed, undef is not forbidden.
# ---------------------------------------------------------------------------
sub has_forbidden_bytes {
    my ($val) = @_;
    return 0 unless defined $val;

    my $checked = $val;
    if (!utf8::is_utf8($checked)) {
        my $tail = $checked;
        my $decoded = eval { Encode::decode('UTF-8', $tail, Encode::FB_QUIET()) };
        if (defined $decoded && !length $tail) {
            # The whole value decoded cleanly -- use the decoded characters
            # for the control-character scan below (the em-dash fix).
            $checked = $decoded;
        }
        elsif (length $tail) {
            # MEDIUM-3a (red-team): decode() stopped at the first byte it
            # could not consume; $tail's first byte is that byte. A byte
            # that can NEVER begin or continue ANY UTF-8 sequence -- a
            # stray continuation byte (\x80-\xBF) with nothing valid before
            # it, or a lead byte UTF-8 never uses at all (\xC0, \xC1: always
            # an overlong encoding; \xF5-\xFF: would encode past U+10FFFF)
            # -- is refused outright. This is exactly C1 BF, C0 AF, BF, A0
            # and F5 BF BF BF, all of which survived the old byte-range
            # fallback because none of their bytes fall in \x7F-\x9F.
            #
            # A lead byte for a multi-byte sequence that simply ran out of
            # input (e.g. a lone \xE9 -- AC10's "eacute" acceptance fixture,
            # `"\x{00E9}"` downgraded by Perl to a bare Latin-1-range byte
            # with the UTF8 flag off) is deliberately NOT one of these: it
            # falls through to the byte-range scan below, unchanged, to stay
            # equivalent with AlmanacBug::has_forbidden_bytes (AC20).
            my $first = ord(substr($tail, 0, 1));
            return 1 if ($first >= 0x80 && $first <= 0xBF)
                     || $first == 0xC0 || $first == 0xC1
                     || $first >= 0xF5;
        }
    }

    return 1 if $checked =~ /[\x00-\x08\x0A-\x1F\x7F-\x9F]/;   # C0 (less TAB) + DEL + C1
    return 1 if $val     =~ /\xE2\x80[\xA8\xA9]/;              # UTF-8 U+2028 / U+2029
    return 1 if $val     =~ /[\x{2028}\x{2029}]/;              # decoded U+2028 / U+2029
    return 0;
}

# ---------------------------------------------------------------------------
# _is_delim($line) -> 1 | 0
#
# The one definition of "this line is a '---' frontmatter delimiter" --
# shared by check()'s opening/closing search and parse()'s closing search
# (review SHOULD-FIX-1 / red-team LOW-1: the two used to disagree, safe today
# only because check() always gates parse() first; sharing one sub removes
# the coincidence rather than documenting it).
# ---------------------------------------------------------------------------
sub _is_delim { return defined $_[0] && $_[0] =~ /\A---\r?\z/ }

# ---------------------------------------------------------------------------
# new_id($epoch) -> $id
#
# YYYYMMDD-HHMMSS-<pid4hex><seq4hex>. Deliberately NOT AlmanacBug::new_id --
# that function's only sub-second entropy is the pid, which is constant
# within a process (measured: 10000 calls in one second from one process
# yield ONE id). $SEQ is a per-process counter, masked to 16 bits, so within
# one process at least 65536 calls in one second are distinct.
#
# MEDIUM-4 (red-team, fix-batch A7): a bare ($$ & 0xffff) is NOT injective in
# the pid the moment two processes' real pids are 65536 apart -- measured on
# this host, where pids run near 900000, so the truncation is the normal
# case, not an edge. The realistic collision is two pid namespaces sharing
# one store over a bind mount (a container pid and a host pid), the exact
# topology Almanac::Lock's own header calls out. $PID_MIX folds in one
# process-lifetime random draw so two processes whose pids happen to share
# their low 16 bits still (almost) certainly differ. This is a *fix-batch*
# divergence from the pid-mask expression in spec section 2.5's pseudocode,
# authorised because that expression is exactly what MEDIUM-4 names as
# broken; the overall 4-hex-plus-4-hex FORMAT the spec pins is unchanged.
# ---------------------------------------------------------------------------
my $SEQ = 0;
my $PID_MIX = ($$ ^ int(rand(0x10000))) & 0xffff;

sub new_id {
    my ($epoch) = @_;
    my @t = gmtime(defined $epoch ? $epoch : time);
    my $n = $SEQ++ & 0xffff;
    return sprintf('%04d%02d%02d-%02d%02d%02d-%04x%04x',
                   $t[5] + 1900, $t[4] + 1, $t[3], $t[2], $t[1], $t[0],
                   $PID_MIX, $n);
}

# ---------------------------------------------------------------------------
# _problem($kind, $path, $line, $reason, %extra) -> \%problem
#
# The one place the message template (spec 2.7.2) is written:
#   almanac record: <path>: line <N>: <reason>
# `key` is included via %extra only for duplicate_key / forbidden_field_value
# call sites -- never manufactured here.
# ---------------------------------------------------------------------------
sub _problem {
    my ($kind, $path, $line, $reason, %extra) = @_;
    return {
        kind    => $kind,
        path    => $path,
        line    => $line,
        message => "almanac record: $path: line $line: $reason",
        %extra,
    };
}

# ---------------------------------------------------------------------------
# check($bytes, $path) -> \@problems     -- NEVER dies, NEVER prints.
#
# Detection order is exactly the closed set in spec section 2.8. The first
# five kinds are terminal (check returns that one problem and stops); the
# last four are collected (check returns every one it finds), in ascending
# line order.
#
# CLOSING-DELIMITER CR (implementer's call; the oracle deliberately left this
# cell unspecified -- see the package report). The spec's own pseudocode
# resolves the OPENING delimiter's CR ("---\r" -> carriage_return, not
# no_frontmatter) explicitly, but is silent on the CLOSING delimiter. This
# treats the closing delimiter the same way, for the same reason: a
# delimiter line carrying a stray CR is still structurally a delimiter (so
# field/body extraction stays well-defined), and the CR is reported through
# the one carriage_return kind used everywhere else in the frontmatter
# region -- never re-labelled as "no closing delimiter exists" when one does,
# just with a CR on it.
# ---------------------------------------------------------------------------
sub check {
    my ($bytes, $path) = @_;
    $bytes = '' unless defined $bytes;
    $path  = '(string)' unless defined $path;

    my @problems;

    # --- kind 2: not_utf8 (terminal) ---------------------------------------
    my $tail = $bytes;
    my $decoded = eval { Encode::decode('UTF-8', $tail, Encode::FB_QUIET()) };
    if (!defined $decoded || length $tail) {
        my $offset = length($bytes) - length($tail);
        my $line   = 1 + (substr($bytes, 0, $offset) =~ tr/\n//);
        push @problems, _problem('not_utf8', $path, $line,
            "file is not valid UTF-8 (first invalid byte at offset $offset)");
        return \@problems;
    }
    my $text = $decoded;

    my @l = split /\n/, $text, -1;
    # MEDIUM-1 (red-team): a genuinely empty file decodes to '', and
    # split(/\n/, '', -1) returns the EMPTY LIST (not one empty element), so
    # $l[0] below is undef under `use warnings` -- check()/check_file() must
    # never print, ever. Guarantee at least one (empty) line.
    @l = ('') unless @l;

    # --- kind 3: no_frontmatter (terminal) ---------------------------------
    if (!_is_delim($l[0])) {
        push @problems, _problem('no_frontmatter', $path, 1,
            "expected the frontmatter delimiter '---' as the first line");
        return \@problems;
    }

    # --- kind 4: unterminated_frontmatter (terminal) -----------------------
    my $closing;
    for my $i (1 .. $#l) {
        if (_is_delim($l[$i])) { $closing = $i; last }
    }
    unless (defined $closing) {
        push @problems, _problem('unterminated_frontmatter', $path, 1,
            "the frontmatter opened here is never closed by a '---' line");
        return \@problems;
    }

    # --- kind 5: empty_frontmatter (terminal) ------------------------------
    my @field_lines = @l[1 .. $closing - 1];
    if (!@field_lines) {
        push @problems, _problem('empty_frontmatter', $path, 2,
            "the frontmatter block is empty; a record must carry at least one field");
        return \@problems;
    }

    # --- kinds 6-9: collected -----------------------------------------------
    if ($l[0] =~ /\r\z/) {
        push @problems, _problem('carriage_return', $path, 1,
            "carriage return in the frontmatter; record files are LF-only");
    }
    if ($l[$closing] =~ /\r\z/) {
        push @problems, _problem('carriage_return', $path, $closing + 1,
            "carriage return in the frontmatter; record files are LF-only");
    }

    my %seen;
    for my $idx (0 .. $#field_lines) {
        my $line_no = $idx + 2;   # field lines start at line 2
        my $line    = $field_lines[$idx];

        if ($line =~ /\r\z/) {
            push @problems, _problem('carriage_return', $path, $line_no,
                "carriage return in the frontmatter; record files are LF-only");
        }

        # SF2 / LOW-2 (review + red-team): a trailing CR is already reported
        # above by the check just before this one. Without stripping it here,
        # the field-value grammar's `(.*)` captures the CR into the VALUE,
        # and has_forbidden_bytes then fires a second, misleading
        # forbidden_field_value for the very same root cause. Strip it before
        # the grammar match so a CRLF field line is diagnosed exactly once.
        (my $grammar_line = $line) =~ s/\r\z//;

        if ($grammar_line =~ /\A([A-Za-z0-9_]+): (.*)\z/) {
            my ($k, $v) = ($1, $2);
            if ($seen{$k}++) {
                push @problems, _problem('duplicate_key', $path, $line_no,
                    "duplicate frontmatter key '$k'", key => $k);
            }
            if (has_forbidden_bytes($v)) {
                push @problems, _problem('forbidden_field_value', $path, $line_no,
                    "field '$k' must be one line: no line break, control character or "
                  . "Unicode line/paragraph separator", key => $k);
            }
        }
        else {
            push @problems, _problem('bad_field_line', $path, $line_no,
                "expected a frontmatter line of the form 'key: value' (key matching "
              . "[A-Za-z0-9_]+, then a colon and one space)");
        }
    }

    # Ascending line, ties in detection order -- Perl's sort is stable.
    @problems = sort { $a->{line} <=> $b->{line} } @problems;
    return \@problems;
}

# ---------------------------------------------------------------------------
# _read_bytes_for_check($path) -> ($bytes, \@problems)
#
# Shared by check_file() and read_file(). Never dies. On success returns
# ($bytes, []); on failure returns (undef, [ one 'unreadable' problem ]).
# ---------------------------------------------------------------------------
sub _read_bytes_for_check {
    my ($path) = @_;
    unless (-f $path) {
        my $why = -e $path ? 'not a plain file' : "$!";
        return (undef, [ _problem('unreadable', $path, 0, "could not read the file: $why") ]);
    }
    my $bytes = eval {
        open my $fh, '<:raw', $path or die "$!\n";
        local $/;
        my $c = <$fh>;
        close $fh;
        $c;
    };
    if (!defined $bytes) {
        my $err = $@; chomp $err;
        return (undef, [ _problem('unreadable', $path, 0, "could not read the file: $err") ]);
    }
    return ($bytes, []);
}

# ---------------------------------------------------------------------------
# check_file($path) -> \@problems     -- NEVER dies, NEVER prints.
# ---------------------------------------------------------------------------
sub check_file {
    my ($path) = @_;
    $path = '(unknown)' unless defined $path;
    my ($bytes, $problems) = _read_bytes_for_check($path);
    return $problems if @$problems;
    return check($bytes, $path);
}

# ---------------------------------------------------------------------------
# _die_malformed($path, \@problems) -- never returns.
#
# The overall Error kind is 'unreadable' when the single problem IS the
# unreadable one (open failed / not a plain file), and 'malformed' for every
# structural problem from check(). $err->{problems} carries the same
# structures check() returns (spec 2.7.3).
# ---------------------------------------------------------------------------
sub _die_malformed {
    my ($path, $problems) = @_;
    my $kind = (@$problems && $problems->[0]{kind} eq 'unreadable') ? 'unreadable' : 'malformed';
    my $message = join("\n", map { $_->{message} } @$problems) . "\n";
    die Almanac::Record::Error->new(
        kind => $kind, path => $path, problems => $problems, message => $message,
    );
}

# ---------------------------------------------------------------------------
# parse($bytes, %opt) -> \%record     -- dies on any problem.
#
# %opt: path => $p (used only in messages; default '(string)').
# ---------------------------------------------------------------------------
sub parse {
    my ($bytes, %opt) = @_;
    my $path = defined $opt{path} ? $opt{path} : '(string)';

    my $problems = check($bytes, $path);
    _die_malformed($path, $problems) if @$problems;

    my $text = Encode::decode('UTF-8', $bytes);
    my @l = split /\n/, $text, -1;
    @l = ('') unless @l;

    my $closing;
    for my $i (1 .. $#l) {
        if (_is_delim($l[$i])) { $closing = $i; last }
    }

    my (%fields, @order);
    for my $i (1 .. $closing - 1) {
        $l[$i] =~ /\A([A-Za-z0-9_]+): (.*)\z/
            or die "Almanac::Record::parse: internal inconsistency -- check() passed but "
                 . "line $i did not match the field-line grammar\n";
        my ($k, $v) = ($1, $2);
        $fields{$k} = $v;
        push @order, $k;
    }

    # MEDIUM-2 (red-team, fix-batch A5): when the closing delimiter is the
    # LAST line, the raw bytes had NO trailing newline at all after it --
    # "---\nk: v\n---" round-trips to "---\nk: v\n---\n" with plain
    # `join("\n", @l[$closing+1..$#l])`, because that join can't tell "no
    # bytes followed" from "one empty line followed". Keep body undef in the
    # former case; serialize() reproduces the missing newline from that.
    my $body = ($closing == $#l) ? undef : join("\n", @l[$closing + 1 .. $#l]);

    return { fields => \%fields, order => \@order, body => $body };
}

# ---------------------------------------------------------------------------
# serialize(\%record) -> $bytes     -- dies on a refused field/key.
#
# HIGH-2 (red-team): has_forbidden_bytes() DECODES a byte-string value before
# checking it (the em-dash fix), but the pre-fix code went on to emit the
# UNDECODED bytes into $text, which the trailing Encode::encode() then
# re-encoded a SECOND time -- the em-dash incident, moved to the write side.
# A caller handing this a raw byte value (an @ARGV title, a <:raw> slurp) is
# exactly how the original incident arrived. Fixed by normalizing every field
# value (and the body) to decoded characters before assembly, and by making
# the one final encode FB_CROAK instead of silently substituting -- which
# also closes MEDIUM-3b (a surrogate or noncharacter must be refused, never
# silently rewritten to U+FFFD).
# ---------------------------------------------------------------------------
sub serialize {
    my ($record) = @_;
    my $path         = (ref $record eq 'HASH' && defined $record->{path}) ? $record->{path} : '(string)';
    my $fields       = (ref $record eq 'HASH' && ref $record->{fields} eq 'HASH') ? $record->{fields} : {};
    my $order        = (ref $record eq 'HASH' && ref $record->{order}  eq 'ARRAY') ? $record->{order}  : [];
    my $has_body_key = (ref $record eq 'HASH') && exists $record->{body};
    my $body         = $has_body_key ? $record->{body} : '';

    my @keys;
    my %emitted;
    for my $k (@$order) {
        next unless exists $fields->{$k};
        next if $emitted{$k}++;
        push @keys, $k;
    }
    for my $k (sort keys %$fields) {
        next if $emitted{$k}++;
        push @keys, $k;
    }

    if (!@keys) {
        my $message = "almanac record: $path: line 0: a record must carry at least one field\n";
        die Almanac::Record::Error->new(
            kind => 'refused', path => $path, problems => [], message => $message,
        );
    }

    my @reasons;
    my @lines;
    for my $k (@keys) {
        if ($k !~ /\A[A-Za-z0-9_]+\z/) {
            push @reasons,
                "almanac record: $path: line 0: field name '$k' is not a legal frontmatter "
              . "key (it must match [A-Za-z0-9_]+)";
            next;
        }
        my $v = $fields->{$k};
        $v = '' unless defined $v;
        if (has_forbidden_bytes($v)) {
            push @reasons,
                "almanac record: $path: line 0: field '$k' must be one line: no line break, "
              . "control character or Unicode line/paragraph separator";
            next;
        }
        # HIGH-2: if $v is a byte string that decodes CLEANLY and COMPLETELY
        # as UTF-8, use the decoded characters -- this is what stops those
        # bytes from being encoded a second time below (the em-dash incident
        # moved to the write side). Deliberately NOT a plain
        # Encode::decode($v) with the default lossy fallback: has_forbidden_
        # bytes() tolerates a value like a lone \xE9 (AC10's "eacute" case,
        # a truncated multi-byte lead byte that is not one of the
        # structurally-invalid ones), and force-decoding THAT with a lossy
        # fallback would silently substitute it with U+FFFD -- exactly the
        # mangling this module exists to refuse rather than commit. Leaving
        # such a value as raw bytes lets Perl's own concatenation-time
        # upgrade treat each remaining byte as its own Latin-1 code point,
        # which is the only sense in which it was ever well-defined.
        if (!utf8::is_utf8($v)) {
            my $tail = $v;
            my $decoded = eval { Encode::decode('UTF-8', $tail, Encode::FB_QUIET()) };
            $v = $decoded if defined $decoded && !length $tail;
        }
        push @lines, "$k: $v";
    }
    if (@reasons) {
        my $message = join("\n", @reasons) . "\n";
        die Almanac::Record::Error->new(
            kind => 'refused', path => $path, problems => [], message => $message,
        );
    }

    if ($has_body_key && defined $body && !utf8::is_utf8($body)) {
        my $decoded_body = eval { Encode::decode('UTF-8', $body, Encode::FB_CROAK()) };
        if (!defined $decoded_body) {
            my $message = "almanac record: $path: line 0: body is not valid UTF-8 bytes\n";
            die Almanac::Record::Error->new(
                kind => 'refused', path => $path, problems => [], message => $message,
            );
        }
        $body = $decoded_body;
    }

    my $text;
    if ($has_body_key && !defined $body) {
        # MEDIUM-2 (fix-batch A5): parse() sets body to undef ONLY for a file
        # whose closing '---' is its very last line with no trailing newline
        # at all. Reproduce that exact absence instead of adding a newline
        # the original bytes never had.
        $text = "---\n" . join("\n", @lines) . "\n---";
    }
    else {
        $body = '' unless defined $body;
        $text = "---\n" . join("\n", @lines) . "\n---\n" . $body;
    }

    my $out = eval { Encode::encode('UTF-8', $text, Encode::FB_CROAK()) };
    if (!defined $out) {
        my $reason = $@;
        $reason =~ s/\s+at\s+\S.*\z//s;
        chomp $reason;
        my $message = "almanac record: $path: line 0: value cannot be represented in UTF-8"
                    . (length($reason) ? " ($reason)" : '') . "\n";
        die Almanac::Record::Error->new(
            kind => 'refused', path => $path, problems => [], message => $message,
        );
    }
    return $out;
}

# ---------------------------------------------------------------------------
# read_file($path) -> \%record     -- dies on any problem.
# ---------------------------------------------------------------------------
sub read_file {
    my ($path) = @_;
    my ($bytes, $problems) = _read_bytes_for_check($path);
    $problems = check($bytes, $path) unless @$problems;
    _die_malformed($path, $problems) if @$problems;

    my $rec = parse($bytes, path => $path);
    $rec->{path} = $path;
    $rec->{raw}  = $bytes;
    return $rec;
}

# ---------------------------------------------------------------------------
# write_file($path, \%record) -> 1     -- dies on any problem.
#
# Order (spec 2.3, load-bearing): serialize first (nothing touches disk on a
# refusal); then, if $path already exists, read and check it -- any problem
# there dies before the existing bytes are touched; only then the atomic
# write. Takes no lock and releases none -- the caller (package 03) holds it.
# ---------------------------------------------------------------------------
sub write_file {
    my ($path, $record) = @_;

    my $rec_for_ser = (ref $record eq 'HASH') ? { %$record, path => $path } : $record;
    my $bytes = serialize($rec_for_ser);

    if (-e $path) {
        my $problems = check_file($path);
        _die_malformed($path, $problems) if @$problems;
    }

    my ($ok, $err) = Almanac::Lock::write_atomic($path, $bytes);
    unless ($ok) {
        my $reason  = (ref $err eq 'HASH' && defined $err->{message}) ? $err->{message} : "$err";
        my $message = "almanac record: $path: line 0: $reason\n";
        die Almanac::Record::Error->new(
            kind => 'io', path => $path, problems => [], message => $message,
        );
    }
    return 1;
}

# ---------------------------------------------------------------------------
# fatal($err) -- never returns. The ONLY exit() in this module.
# ---------------------------------------------------------------------------
sub fatal {
    my ($err) = @_;
    my $code = (ref $err eq 'Almanac::Record::Error' && defined $err->{exit_code})
             ? $err->{exit_code} : 2;
    my $msg = defined $err ? "$err" : 'unknown error';
    $msg .= "\n" unless $msg =~ /\n\z/;
    print STDERR $msg;
    exit $code;
}

1;
