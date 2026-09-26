package WtProfile;
use strict;
use warnings;
use Digest::SHA ();   # core; sha1() only, called fully-qualified
use File::Path  ();   # core; make_path() only, always with the error-capture form
use File::Spec  ();   # core; catfile/catdir/splitpath only
use JSON::PP    ();   # core; decode/encode only, always fenced in eval, never imported

# =============================================================================
# WtProfile.pm -- everything about the ccpraxis Windows Terminal profile
# EXCEPT when to call it (blueprint sandbox-wt-profile, package
# 01-wt-profile-fragment). It derives the profile's UUIDv5 GUID (Decision 6),
# renders the fragment JSON (Decision 4 -- scrollbarState only), writes it
# idempotently under a CALLER-SUPPLIED root (Decision 8), and separately
# resolves the real root from a supplied (or ambient) environment.
#
# Only core Perl modules are called from here (Digest::SHA::sha1,
# File::Path::make_path, File::Spec->catdir/catfile) -- no application code
# calls in: no dashboard, no launcher, no argv, no install hook. Package 02
# is the only consumer and it does not exist yet.
#
# -----------------------------------------------------------------------
# MODULE SHAPE (spec sec-2.0), matching Theme.pm's convention in this same
# directory:
#   * Core modules only -- Digest::SHA, File::Path, File::Spec. No CPAN, no
#     UUID module (Decision 6 is pure Perl with core Digest::SHA).
#   * No "use utf8". Every literal in this file is ASCII.
#   * No top-level side effects: loading this module performs no I/O, opens
#     no file, reads no environment variable, and prints nothing. The only
#     places %ENV is read are inside fragment_root(), settings_candidates(),
#     and ensure_fragment()'s default (one-argument) path -- and only on
#     call, never at load.
#   * NEVER DIES, NEVER WARNS -- a hard contract, not a style note (spec
#     sec-2.0/2.5). Nothing in this module calls die/warn/carp/croak/print/
#     printf/say, and nothing it calls is allowed to do so on its behalf:
#     File::Path::make_path is always invoked with the { error => \$err }
#     capture form (never the bare form, which dies on failure), and every
#     construct that could still die or warn (open/print/close, sha1/pack/
#     unpack on already-validated input) is fenced with
#     eval { local $SIG{__WARN__} = sub { }; ...; 1 }. Decision 5 depends on
#     ensure_fragment() being non-fatal: the dashboard owns a full-screen TUI
#     that a stray warn would corrupt.
#   * Ends with "1;".
# =============================================================================

# -----------------------------------------------------------------------
# CONSTANTS (spec sec-2.1) -- module-private; exposed only through the named
# accessor functions below (profile_name(), fragment_json(), etc.), never as
# bare constant calls from outside this file. Plain top-level lexical
# scalars rather than "use constant": the module's own hygiene rule (spec
# AC-7.3) closes the permitted use/require list to strict/warnings/
# Digest::SHA/File::Path/File::Spec, and "constant" is a separate pragma
# module, not one of those five.
# -----------------------------------------------------------------------
my $NAMESPACE_GUID    = '{f65ddb7e-706b-4499-8a50-40313caf510a}';
my $APP_NAME          = 'ccpraxis';           # fed into the GUID chain
my $PROFILE_NAME      = 'claude-sandbox';     # fed into the GUID chain, and wt.exe -p's argument (package 02)
my $APP_DIR_NAME      = 'ccpraxis';           # the directory this module owns under the Fragments root
my $FRAGMENT_FILENAME = 'claude-sandbox.json';
my $SCROLLBAR_STATE   = 'hidden';

# The allow-listed appearance keys (spec sec-2.4), in RENDER order. 'font' is
# handled specially (merged per sub-key -- see _merge_font below) but still
# occupies its slot in this order for fragment_json()'s rendering loop.
my @ALLOW_LIST_ORDER = qw(
    font colorScheme cursorShape cursorHeight foreground background
    selectionBackground cursorColor opacity useAcrylic padding
    antialiasingMode intenseTextStyle adjustIndistinguishableColors
);

# Top-level allow-listed keys OTHER than font -- these follow the simple
# "profile wins over defaults, else absent" rule (spec sec-2.3).
my @TOP_LEVEL_KEYS = grep { $_ ne 'font' } @ALLOW_LIST_ORDER;

# Font sub-keys kept from a font object at any merge layer (spec sec-2.3).
my @FONT_SUBKEYS = qw(face size weight features axes cellHeight cellWidth);

# The closed set of appearance_reason values (spec sec-2.2).
my %APPEARANCE_REASONS = map { $_ => 1 } qw(
    settings_not_found settings_unreadable settings_unparseable no_default_profile
);

my $MAX_SETTINGS_BYTES = 4_194_304;   # 4 MiB (spec sec-2.2)

# =============================================================================
# GUID DERIVATION (spec sec-2.2, Decision 6) -- pure Perl UUIDv5 (SHA-1) over
# core Digest::SHA. The algorithm below is the VERIFIED implementation quoted
# in blueprint.md's "Key references" (matches Microsoft's own published check
# vector) and must not be re-derived from the RFC/MS docs.
# =============================================================================

# utf16le($string) -> $bytes | '' | undef
#
# Encodes an ASCII/Latin-1 Perl string to UTF-16LE bytes, one
# pack('v', ord $c) per character. Pure; no I/O, no die, no warn on any
# input pack('v', ...) can accept for a defined string (ord() on a
# multi-char string in the map is applied per-character via split //).
sub utf16le {
    my ($string) = @_;
    return undef unless defined $string;
    return '' if $string eq '';
    return join('', map { pack('v', ord($_)) } split(//, $string));
}

# uuid5($namespace_guid, $name_bytes) -> $guid_string | undef
#
# RFC 4122 version 5 (SHA-1) UUID, brace-wrapped and lowercase.
# $name_bytes is ALREADY encoded -- the caller passes utf16le(...) output.
#
# Quiet-rejection contract (spec sec-2.2, B4): returns undef -- never dies,
# never warns -- if $namespace_guid is undef, does not reduce to exactly 32
# hex digits after stripping '{', '}' and '-', or $name_bytes is undef. The
# hex-digit count is validated BEFORE pack('H*', ...) is reached, because an
# illegal hex digit there would warn.
sub uuid5 {
    my ($ns_str, $name) = @_;
    return undef unless defined $ns_str;
    return undef unless defined $name;

    (my $hex = $ns_str) =~ s/[{}\-]//g;
    return undef unless $hex =~ /\A[0-9A-Fa-f]{32}\z/;

    my $guid;
    my $ok = eval {
        local $SIG{__WARN__} = sub { };
        my @bytes = unpack('C16', Digest::SHA::sha1(pack('H*', $hex) . $name));
        $bytes[6] = ($bytes[6] & 0x0f) | 0x50;   # version 5
        $bytes[8] = ($bytes[8] & 0x3f) | 0x80;   # RFC 4122 variant
        my $hexout = unpack('H*', pack('C16', @bytes));
        $guid = sprintf(
            '{%s-%s-%s-%s-%s}',
            substr($hexout, 0, 8), substr($hexout, 8, 4), substr($hexout, 12, 4),
            substr($hexout, 16, 4), substr($hexout, 20, 12),
        );
        1;
    };
    return undef unless $ok;
    return lc($guid);
}

# profile_guid() -> $guid_string
#
# The ccpraxis profile GUID, DERIVED AT CALL TIME, never a stored literal
# (AC-1.6 scans this file's non-comment lines for the literal result and
# fails the suite if it appears -- that is what stops this function
# degrading into a vacuous constant).
sub profile_guid {
    my $ns_app = uuid5($NAMESPACE_GUID, utf16le($APP_NAME));
    return uuid5($ns_app, utf16le($PROFILE_NAME));
}

# profile_name() -> 'claude-sandbox'
#
# The profile's "name", and the string package 02 hands to "wt.exe -p"
# (Decision 7). Exposed so 02 never hardcodes it.
sub profile_name {
    return $PROFILE_NAME;
}

# =============================================================================
# THE FRAGMENT (spec sec-2.3, Decision 4) -- exactly three keys, rendered by
# hand. NEVER use JSON::PP's canonical encoder here: canonical mode sorts
# keys (guid before name) and its pretty-print layout is a property of the
# installed JSON::PP version, not of this spec -- either way it would not
# reproduce the pinned bytes below. The guid/name values come from
# profile_guid()/profile_name(), never as literals in this rendering code.
# =============================================================================

# _encode_json_scalar($value) -> $bytes | undef
#
# JSON::PP->new->canonical(1)->ascii(1)->allow_nonref(1)->encode($value)
# (spec sec-2.5), fenced -- returns undef (never dies/warns) on any failure.
sub _encode_json_scalar {
    my ($value) = @_;
    my $encoded;
    my $ok = eval {
        local $SIG{__WARN__} = sub { };
        $encoded = JSON::PP->new->canonical(1)->ascii(1)->allow_nonref(1)->encode($value);
        1;
    };
    return undef unless $ok;
    return $encoded;
}

# fragment_json(\%app?) -> $bytes
#
# Pure, deterministic, byte-stable. ASCII only, LF-only, two-space indent,
# one trailing LF, no BOM. With no argument, undef, or an empty hashref, the
# output is byte-identical to today's pinned three-key literal (spec
# sec-2.5). With appearance keys, each present allow-listed key (spec
# sec-2.4) is rendered in section-2.4 order after scrollbarState, 6-space
# indent, one per line, commas between and none after the last.
sub fragment_json {
    my ($app) = @_;
    my $name  = profile_name();
    my $guid  = profile_guid();
    my $state = $SCROLLBAR_STATE;

    my @rendered;
    if (ref($app) eq 'HASH') {
        for my $key (@ALLOW_LIST_ORDER) {
            next unless exists($app->{$key}) && defined($app->{$key});
            my $encoded = _encode_json_scalar($app->{$key});
            next unless defined $encoded;
            push @rendered, "      \"$key\": $encoded";
        }
    }

    my $scrollbar_line = "      \"scrollbarState\": \"$state\"" . (@rendered ? ",\n" : "\n");

    my $out = "{\n"
            . "  \"profiles\": [\n"
            . "    {\n"
            . "      \"name\": \"$name\",\n"
            . "      \"guid\": \"$guid\",\n"
            . $scrollbar_line;

    $out .= join(",\n", @rendered) . "\n" if @rendered;

    $out .= "    }\n"
          . "  ]\n"
          . "}\n";

    return $out;
}

# fragment_path($root) -> $path | undef
#
# File::Spec->catfile($root, 'ccpraxis', 'claude-sandbox.json'). $root is the
# Fragments directory, NOT the app directory -- this module owns the
# 'ccpraxis' directory name (see blueprint sec-7 point 1 for why). Returns
# undef if $root is undef or the empty string. Performs no I/O.
sub fragment_path {
    my ($root) = @_;
    return undef unless defined($root) && length($root);
    return File::Spec->catfile($root, $APP_DIR_NAME, $FRAGMENT_FILENAME);
}

# =============================================================================
# WRITING THE FRAGMENT (spec sec-2.4/sec-2.5, sec-3 B6..B12) -- idempotent,
# self-healing, never fatal. Every return is a hashref; success carries
# exactly ok/action/path, failure adds reason/error (spec sec-2.2's
# ensure_fragment contract).
# =============================================================================

# _read_raw($path) -> $bytes | undef
#
# Raw-mode slurp (binmode on read, per spec sec-2.4 point 2), used both for
# the idempotence content-comparison and by ensure_fragment(). Never dies,
# never warns: returns undef on any failure to open/read.
sub _read_raw {
    my ($path) = @_;
    my $data;
    my $ok = eval {
        local $SIG{__WARN__} = sub { };
        open(my $fh, '<', $path) or die "open failed: $!\n";
        binmode($fh);
        local $/;
        $data = <$fh>;
        close($fh) or die "close failed: $!\n";
        1;
    };
    return undef unless $ok;
    return defined($data) ? $data : '';
}

# _quiet_is_dir($path) / _quiet_is_file($path) -> 1 | 0
#
# Fenced filetest wrappers. A bare -d/-f on a pathname containing a NUL (or
# other illegal-for-the-platform bytes) warns -- these are the only two
# filetests ensure_fragment performs, and criterion 6 is an UNCONDITIONAL
# never-warns contract on the whole function, not just on its open/print/
# close paths. Never dies; never warns.
sub _quiet_is_dir {
    my ($path) = @_;
    my $result;
    eval { local $SIG{__WARN__} = sub { }; $result = (-d $path) ? 1 : 0; 1; };
    return $result ? 1 : 0;
}

sub _quiet_is_file {
    my ($path) = @_;
    my $result;
    eval { local $SIG{__WARN__} = sub { }; $result = (-f $path) ? 1 : 0; 1; };
    return $result ? 1 : 0;
}

# _mkdir_error_message($err) -> $message | undef
#
# Extracts a human-readable string from File::Path::make_path's
# { error => \$err } diagnostic arrayref (a list of one-key hashrefs,
# path => message). Returns undef if $err carries nothing usable, so the
# caller can fall back to $@ / $! instead of losing the failure entirely.
sub _mkdir_error_message {
    my ($err) = @_;
    return undef unless ref($err) eq 'ARRAY' && @$err;
    my @parts;
    for my $diag (@$err) {
        next unless ref($diag) eq 'HASH';
        for my $key (keys %$diag) {
            push @parts, "$key: $diag->{$key}";
        }
    }
    return @parts ? join('; ', @parts) : undef;
}

# =============================================================================
# APPEARANCE (spec sec-2.1/2.2/2.3, Decision 9) -- read-only access to the
# operator's Windows Terminal settings.json, tolerant JSONC parsing, and the
# profiles.defaults/defaultProfile merge. Nothing here ever opens the
# settings file for writing.
# =============================================================================

# _validate_localappdata($value) -> $trimmed | undef
#
# Shared validity rule for a %ENV{LOCALAPPDATA}-shaped value, used by both
# fragment_root() and settings_candidates(): defined and non-whitespace,
# trailing separator(s) trimmed, must match ^[A-Za-z]:[\\/], and must not
# contain a '..' segment. Never dies, never warns.
sub _validate_localappdata {
    my ($value) = @_;
    return undef unless defined($value) && $value =~ /\S/;

    (my $trimmed = $value) =~ s{[\\/]+\z}{};

    my $looks_resolvable = ($trimmed =~ m{\A[A-Za-z]:[\\/]})
                         && ($trimmed !~ m{(?:\A|[\\/])\.\.(?:[\\/]|\z)});
    return $looks_resolvable ? $trimmed : undef;
}

# settings_candidates(\%env?) -> @paths
#
# Pure, no I/O. Resolves the two known Windows Terminal settings.json
# locations (packaged/Store, then unpackaged) from $env->{LOCALAPPDATA} (or
# %ENV when $env is omitted), joined with literal backslashes -- never
# File::Spec (spec sec-2.1). An invalid LOCALAPPDATA returns the empty list.
sub settings_candidates {
    my ($env) = @_;
    $env = \%ENV unless defined $env;

    my $trimmed = _validate_localappdata($env->{LOCALAPPDATA});
    return () unless defined $trimmed;

    return (
        "$trimmed\\Packages\\Microsoft.WindowsTerminal_8wekyb3d8bbwe\\LocalState\\settings.json",
        "$trimmed\\Microsoft\\Windows Terminal\\settings.json",
    );
}

# _strip_jsonc_comments($bytes) -> $stripped | undef
#
# String-aware removal of '// ...' (to end of line) and '/* ... */' comments
# (spec sec-2.2 point 3). Content inside a JSON string literal (including
# '//', '/*' and escaped quotes) is never altered. Returns undef if a '/*'
# is never closed (unparseable). Never dies, never warns.
sub _strip_jsonc_comments {
    my ($s) = @_;
    return undef unless defined $s;

    my $out = '';
    my $len = length($s);
    my $i = 0;
    my $in_string = 0;

    while ($i < $len) {
        my $c = substr($s, $i, 1);

        if ($in_string) {
            $out .= $c;
            if ($c eq "\\" && $i + 1 < $len) {
                $out .= substr($s, $i + 1, 1);
                $i += 2;
                next;
            }
            $in_string = 0 if $c eq '"';
            $i++;
            next;
        }

        if ($c eq '"') {
            $in_string = 1;
            $out .= $c;
            $i++;
            next;
        }

        if ($c eq '/' && $i + 1 < $len && substr($s, $i + 1, 1) eq '/') {
            my $nl = index($s, "\n", $i);
            if ($nl == -1) {
                $out .= ' ';
                $i = $len;
            } else {
                $out .= ' ';
                $i = $nl;
            }
            next;
        }

        if ($c eq '/' && $i + 1 < $len && substr($s, $i + 1, 1) eq '*') {
            my $close = index($s, '*/', $i + 2);
            return undef if $close == -1;
            $out .= ' ';
            $i = $close + 2;
            next;
        }

        $out .= $c;
        $i++;
    }

    return $out;
}

# _resolve_profiles_shape($data) -> ($list_arrayref | undef, $defaults_hashref)
#
# Resolves the "profiles" shape (spec sec-2.2): an object with an array
# "list" (defaults come from its "defaults" hash, or {} if absent/not a
# hash), or a legacy bare array (no defaults). Returns (undef, {}) for
# anything else.
sub _resolve_profiles_shape {
    my ($data) = @_;
    my $profiles = (ref($data) eq 'HASH') ? $data->{profiles} : undef;

    if (ref($profiles) eq 'HASH') {
        my $list = $profiles->{list};
        return (undef, {}) unless ref($list) eq 'ARRAY';
        my $defaults = (ref($profiles->{defaults}) eq 'HASH') ? $profiles->{defaults} : {};
        return ($list, $defaults);
    }
    if (ref($profiles) eq 'ARRAY') {
        return ($profiles, {});
    }
    return (undef, {});
}

# _match_default_profile($list, $default_profile) -> \%entry | undef
#
# Matches spec sec-2.2's "default-profile match" rule: a braced-GUID-shaped
# value matches the first list entry whose guid equals it case-insensitively;
# otherwise the first entry whose name equals it exactly.
sub _match_default_profile {
    my ($list, $default_profile) = @_;
    return undef unless ref($list) eq 'ARRAY';
    return undef unless defined($default_profile) && !ref($default_profile);

    if ($default_profile =~ /\A\{[0-9A-Fa-f-]{36}\}\z/) {
        for my $entry (@$list) {
            next unless ref($entry) eq 'HASH';
            my $g = $entry->{guid};
            next unless defined($g) && !ref($g);
            return $entry if lc($g) eq lc($default_profile);
        }
        return undef;
    }

    for my $entry (@$list) {
        next unless ref($entry) eq 'HASH';
        my $n = $entry->{name};
        next unless defined($n) && !ref($n);
        return $entry if $n eq $default_profile;
    }
    return undef;
}

# _apply_legacy_font(\%font, $source_hashref) -> ()
#
# Layer helper (spec sec-2.3): copies fontFace/fontSize/fontWeight from
# $source_hashref into %font as face/size/weight, when defined.
sub _apply_legacy_font {
    my ($font, $source) = @_;
    return unless ref($source) eq 'HASH';
    $font->{face}   = $source->{fontFace}   if defined $source->{fontFace};
    $font->{size}   = $source->{fontSize}   if defined $source->{fontSize};
    $font->{weight} = $source->{fontWeight} if defined $source->{fontWeight};
}

# _apply_font_object(\%font, $font_value) -> ()
#
# Layer helper (spec sec-2.3): copies the allow-listed font sub-keys from
# $font_value (a "font" object) into %font, when present and non-null. A
# non-object $font_value is ignored for this layer.
sub _apply_font_object {
    my ($font, $font_value) = @_;
    return unless ref($font_value) eq 'HASH';
    for my $key (@FONT_SUBKEYS) {
        next unless exists($font_value->{$key}) && defined($font_value->{$key});
        $font->{$key} = $font_value->{$key};
    }
}

# _merge_appearance($defaults, $profile) -> \%app
#
# Implements spec sec-2.3's merge rule. $defaults and $profile are both
# expected to be hashrefs (callers pass {} when absent).
sub _merge_appearance {
    my ($defaults, $profile) = @_;
    $defaults = {} unless ref($defaults) eq 'HASH';
    $profile  = {} unless ref($profile)  eq 'HASH';

    my %app;
    for my $key (@TOP_LEVEL_KEYS) {
        if (defined $profile->{$key}) {
            $app{$key} = $profile->{$key};
        } elsif (defined $defaults->{$key}) {
            $app{$key} = $defaults->{$key};
        }
    }

    my %font;
    _apply_legacy_font(\%font, $defaults);
    _apply_font_object(\%font, $defaults->{font});
    _apply_legacy_font(\%font, $profile);
    _apply_font_object(\%font, $profile->{font});

    $app{font} = \%font if %font;

    return \%app;
}

# default_appearance($settings_path) -> \%result
#
# Reads $settings_path (read-only) and resolves the effective appearance of
# the default profile (spec sec-2.2). Never writes, never dies, never warns.
# Success: { ok => 1, appearance => \%app }. Failure: { ok => 0, reason => R }
# with R drawn from the closed set in %APPEARANCE_REASONS.
sub default_appearance {
    my ($settings_path) = @_;

    if (!defined($settings_path) || $settings_path !~ /\S/) {
        return { ok => 0, reason => 'settings_not_found' };
    }
    return { ok => 0, reason => 'settings_not_found' } unless _quiet_is_file($settings_path);

    my $size = -s $settings_path;
    return { ok => 0, reason => 'settings_unreadable' } unless defined($size) && $size <= $MAX_SETTINGS_BYTES;

    my $raw = _read_raw($settings_path);
    return { ok => 0, reason => 'settings_unreadable' } unless defined $raw;

    $raw =~ s/\A\xEF\xBB\xBF//;

    my $stripped = _strip_jsonc_comments($raw);
    return { ok => 0, reason => 'settings_unparseable' } unless defined $stripped;

    my $data;
    my $decode_ok = eval {
        local $SIG{__WARN__} = sub { };
        $data = JSON::PP->new->utf8(1)->relaxed(1)->decode($stripped);
        1;
    };
    return { ok => 0, reason => 'settings_unparseable' } unless $decode_ok && ref($data) eq 'HASH';

    my ($list, $defaults) = _resolve_profiles_shape($data);
    return { ok => 0, reason => 'no_default_profile' } unless defined $list;

    my $default_profile = $data->{defaultProfile};
    return { ok => 0, reason => 'no_default_profile' } unless defined($default_profile) && !ref($default_profile);

    my $matched = _match_default_profile($list, $default_profile);
    return { ok => 0, reason => 'no_default_profile' } unless defined $matched;

    my $app = _merge_appearance($defaults, $matched);
    return { ok => 1, appearance => $app };
}

# _resolve_settings_path(\%opts) -> $path | undef
#
# spec sec-2.6 point 1: if $opts explicitly carries a 'settings_path' key
# (even undef), that value is the only source considered -- no filesystem or
# %ENV access. Otherwise the first settings_candidates(\%ENV) entry for
# which -f is true, or undef if none qualifies.
sub _resolve_settings_path {
    my ($opts) = @_;
    return $opts->{settings_path} if exists $opts->{settings_path};

    for my $candidate (settings_candidates(\%ENV)) {
        return $candidate if _quiet_is_file($candidate);
    }
    return undef;
}

# ensure_fragment($root, \%opts?) -> \%result
#
# Idempotently makes the fragment exist under $root with the operator's
# copied appearance (or today's base bytes on fallback). Always returns a
# hashref. Never dies, never warns, never prints (spec sec-2.2/2.5/2.6).
sub ensure_fragment {
    my ($root, $opts) = @_;
    $opts = {} unless ref($opts) eq 'HASH';

    if (!defined($root) || $root !~ /\S/) {
        return {
            ok     => 0,
            action => 'failed',
            path   => undef,
            reason => 'root_missing',
            error  => 'fragment root is undef, empty, or whitespace only',
        };
    }

    my $path    = fragment_path($root);
    my $app_dir = File::Spec->catdir($root, $APP_DIR_NAME);

    # Create the app directory (and any missing intermediate levels) unless
    # it already exists. An already-existing directory is not a failure --
    # this also absorbs a concurrent creation (spec sec-2.5).
    unless (_quiet_is_dir($app_dir)) {
        my $err;
        eval {
            local $SIG{__WARN__} = sub { };
            File::Path::make_path($app_dir, { error => \$err });
            1;
        };
        # The -d check after the attempt is the source of truth, not the
        # eval's own success/failure (spec sec-2.5) -- it also absorbs a
        # concurrent creation that raced us to the same directory.
        unless (_quiet_is_dir($app_dir)) {
            my $message = _mkdir_error_message($err);
            $message = "$!" if !defined($message) || !length($message);
            $message = 'unknown mkdir failure' unless defined($message) && length($message);
            return {
                ok     => 0,
                action => 'failed',
                path   => $path,
                reason => 'mkdir_failed',
                error  => $message,
            };
        }
    }

    # Appearance resolution (spec sec-2.6 point 3): a failure here is NOT an
    # ensure_fragment() failure -- it degrades to the base three-key fragment
    # with a machine-readable reason.
    my $settings_path      = _resolve_settings_path($opts);
    my $appearance_result  = default_appearance($settings_path);
    my $appearance_status  = $appearance_result->{ok} ? 'copied' : 'fallback';
    my $appearance_reason  = $appearance_result->{ok} ? undef : $appearance_result->{reason};
    my $appearance         = $appearance_result->{ok} ? $appearance_result->{appearance} : undef;

    my $wanted = fragment_json($appearance);

    # Idempotent no-op: content already matches. Read-only -- never opens
    # the file for writing, never truncates, never touches mtime (AC-3.3).
    # The size check is an ADDITIONAL precondition on the read, never a
    # replacement for the byte-exact eq below: a same-size-different-content
    # file must still fail this comparison and fall through to a rewrite.
    # It exists only to bound the slurp -- without it, a multi-gigabyte file
    # squatting at this path (however it got there) would be read into
    # memory in full on every single ensure_fragment() call.
    if (_quiet_is_file($path)) {
        my $existing_size = -s $path;
        if (defined($existing_size) && $existing_size == length($wanted)) {
            my $existing = _read_raw($path);
            if (defined($existing) && $existing eq $wanted) {
                my %result = (ok => 1, action => 'unchanged', path => $path, appearance => $appearance_status);
                $result{appearance_reason} = $appearance_reason if $appearance_status eq 'fallback';
                return \%result;
            }
        }
    }

    # Write (first write, or drifted content self-healing -- Decision 3).
    my $write_err;
    my $write_ok = eval {
        local $SIG{__WARN__} = sub { };
        open(my $fh, '>', $path) or die "open failed: $!\n";
        binmode($fh);   # raw mode on write -- spec sec-2.4 point 1
        print { $fh } $wanted or die "print failed: $!\n";
        close($fh) or die "close failed: $!\n";
        1;
    };
    unless ($write_ok) {
        $write_err = $@;
        $write_err =~ s/\n\z// if defined $write_err;
        $write_err = "$!" unless defined($write_err) && length($write_err);
        return {
            ok     => 0,
            action => 'failed',
            path   => $path,
            reason => 'write_failed',
            error  => $write_err,
        };
    }

    my %result = (ok => 1, action => 'wrote', path => $path, appearance => $appearance_status);
    $result{appearance_reason} = $appearance_reason if $appearance_status eq 'fallback';
    return \%result;
}

# =============================================================================
# THE REAL-ROOT RESOLVER (spec sec-2.2/2.2, Decision 8) -- the only function
# in this module that ever touches the process environment, and only on
# call, never at load (mirrors Theme::detect_capability / Theme::capability).
# =============================================================================

# fragment_root(\%env) -> \%result
#
# Resolves the real Windows Fragments root from $env->{LOCALAPPDATA} (or
# %ENV when $env is omitted). Builds the Windows path as a LITERAL
# backslash join, never via File::Spec -- File::Spec would emit '/' on
# Linux, and this is a Windows path by definition regardless of the host
# running the test. The environment value is treated as opaque: never
# encoded/decoded/upgraded/downgraded, never inspected for non-ASCII beyond
# matching literal ASCII separator characters at its own end.
sub fragment_root {
    my ($env) = @_;
    $env = \%ENV unless defined $env;

    my $local_appdata = $env->{LOCALAPPDATA};
    if (!defined($local_appdata) || $local_appdata !~ /\S/) {
        return { ok => 0, reason => 'no_localappdata' };
    }

    (my $trimmed = $local_appdata) =~ s{[\\/]+\z}{};

    # A degenerate value -- a bare separator, a relative path, a UNC share,
    # or one containing a ".." traversal segment -- must not produce a path
    # that LOOKS resolved. A leading backslash with no drive letter is
    # resolved by Windows against the CURRENT drive, so handing that on
    # would create files at the drive root -- exactly the failure class this
    # repo has already paid for (see CLAUDE.md, 576 stray drive-root entries
    # on 2026-06-12). A UNC root (\\host\share) would make every ensure_
    # fragment() call block on SMB/DNS with no timeout inside the
    # dashboard's synchronous [c] handler. Reusing 'no_localappdata' here
    # (rather than inventing a new reason) keeps AC-5.5/AC-6's closed set
    # intact -- this degrades exactly as the spec already describes for a
    # missing value.
    my $looks_resolvable = ($trimmed =~ m{\A[A-Za-z]:[\\/]})
                         && ($trimmed !~ m{(?:\A|[\\/])\.\.(?:[\\/]|\z)});
    return { ok => 0, reason => 'no_localappdata' } unless $looks_resolvable;

    return { ok => 1, root => $trimmed . "\\Microsoft\\Windows Terminal\\Fragments" };
}

1;
