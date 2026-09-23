#!/usr/bin/env perl
# almanac-note.pl -- note CRUD + promote over Almanac::Store (blueprint
# almanac-records, package 05-notes). See specs/05-notes-spec.md for the
# full contract; this file implements it and adds nothing beyond it.
#
# A note is a pointer plus metadata (Decision 8), never a second copy of
# what it describes. Store type is the literal string 'note'. Every
# read/write goes through Almanac::Store -- this file contains no
# frontmatter parsing, no '---' delimiter handling, and no container-surface
# detection of its own (that stays inside Almanac::Store::surface(),
# package 03's single decision point).
package Almanac::Note;
use strict;
use warnings;
use File::Path ();
use JSON::PP ();
use Encode ();

# Almanac/ sits beside THIS FILE (not $0, not FindBin -- both are the
# invoking program, which a test's `do $NOTE_PL` makes the .t file, not
# this one). See almanac-todo.pl's BEGIN block for the same reasoning.
BEGIN {
    my $dir = __FILE__;
    $dir =~ s{\\}{/}g;
    $dir =~ s{/[^/]+\z}{};
    $dir = '.' unless length $dir;
    unshift @INC, $dir;
}
use Almanac::Store ();
use Almanac::Record ();
use Almanac::Lock ();

our $VERSION = '1.0';

# ---------------------------------------------------------------------------
# small helpers
# ---------------------------------------------------------------------------

sub _usage { die Almanac::Store::Error->new(kind => 'usage', detail => $_[0]) }

sub _trim {
    my ($s) = @_;
    return $s unless defined $s;
    $s =~ s/\A\s+//;
    $s =~ s/\s+\z//;
    return $s;
}

# _decode_maybe($s) -> decoded character string
#
# Almanac::Store builds a record's `path` via Cwd::abs_path, which on this
# platform returns raw UTF-8 BYTES without the internal utf8 flag set.
# Printing raw bytes through STDOUT's single ':encoding(UTF-8)' layer would
# encode them a SECOND time. Decode once here so the STDOUT layer's one
# encode is the only one (S2.4, S5.1: "this script never re-encodes a path
# it received").
sub _decode_maybe {
    my ($s) = @_;
    return $s unless defined $s;
    return $s if utf8::is_utf8($s);
    my $d = eval { Encode::decode('UTF-8', $s, Encode::FB_CROAK()) };
    return defined $d ? $d : $s;
}

# _encode_for_error($s) -> raw UTF-8 bytes
#
# The inverse of _decode_maybe. Almanac::Store::Error's path fields
# ultimately reach Almanac::Record::fatal()'s bare `print STDERR $msg`,
# which carries no ':encoding(UTF-8)' layer -- unlike Almanac::Store's OWN
# paths (built from Cwd bytes and never decoded, so they print correctly as-
# is), the paths this script builds from _anchor_abs()/_internal_dir_abs()
# are deliberately DECODED characters (so filesystem concatenation with a
# record's decoded `target` field does not corrupt a multi-byte sequence --
# see _anchor_abs's own comment). Printed decoded to a raw stream, a
# character like U+00E9 downgrades to a single Latin-1 byte instead of its
# two-byte UTF-8 form. Encode back to bytes at this one boundary so error
# paths print the same way Store's own do.
sub _encode_for_error {
    my ($s) = @_;
    return $s unless defined $s;
    return $s unless utf8::is_utf8($s);
    my $b = eval { Encode::encode('UTF-8', $s) };
    return defined $b ? $b : $s;
}

sub _now_iso {
    my @t = gmtime(time);
    return sprintf('%04d-%02d-%02dT%02d:%02d:%02dZ',
                   $t[5] + 1900, $t[4] + 1, $t[3], $t[2], $t[1], $t[0]);
}

# _normalize_tags($raw) -> $normalized | undef
# undef means "zero tokens" -- omit on create, unset on edit.
sub _normalize_tags {
    my ($raw) = @_;
    return undef unless defined $raw;
    my @tok = grep { length } map { _trim($_) } split /,/, $raw;
    return @tok ? join(',', @tok) : undef;
}

sub _parse_set_pair {
    my ($pair) = @_;
    _usage('bad_set') unless defined $pair && $pair =~ /=/;
    my ($k, $v) = split /=/, $pair, 2;
    _usage('bad_field_name') unless defined $k && $k =~ /\A[A-Za-z0-9_]+\z/;
    return ($k, $v);
}

# _check_reserved_field($k) -- the three script-reserved fields (S2.1).
sub _check_reserved_field {
    my ($k) = @_;
    _usage('audience_is_reserved') if $k eq 'audience';
    _usage('target_is_reserved')   if $k eq 'target';
    _usage('journal_is_reserved')  if $k eq 'promote_to';
}

# _resolve_body(\%o) -> $body | undef -- the RECORD's body.
sub _resolve_body {
    my ($o) = @_;
    _usage('body_conflict') if exists($o->{body}) && exists($o->{'body-file'});
    if (exists $o->{body}) {
        if (!ref($o->{body}) && $o->{body} eq '-') {
            local $/;
            my $s = <STDIN>;
            return defined $s ? $s : '';
        }
        return $o->{body};
    }
    if (exists $o->{'body-file'}) {
        my $path = $o->{'body-file'};
        open my $fh, '<:raw', $path or _usage('body_file_unreadable');
        local $/;
        my $c = <$fh>;
        close $fh;
        return $c;
    }
    return undef;
}

# _resolve_content(\%o) -> $content | undef -- the bytes of the pointed-at
# TARGET file (create's materializing branch only). undef means "default to
# the empty string".
sub _resolve_content {
    my ($o) = @_;
    _usage('content_conflict') if exists($o->{content}) && exists($o->{'content-file'});
    if (exists $o->{content}) {
        if (!ref($o->{content}) && $o->{content} eq '-') {
            local $/;
            my $s = <STDIN>;
            return defined $s ? $s : '';
        }
        return $o->{content};
    }
    if (exists $o->{'content-file'}) {
        my $path = $o->{'content-file'};
        open my $fh, '<:raw', $path or _usage('content_file_unreadable');
        local $/;
        my $c = <$fh>;
        close $fh;
        return $c;
    }
    return undef;
}

# open_store($scope, %opt) -> $store   -- %opt: root, home
sub open_store {
    my ($scope, %opt) = @_;
    return Almanac::Store->open(scope => $scope, type => 'note',
                                 root => $opt{root}, home => $opt{home});
}

sub _open_store {
    my ($scope, $o) = @_;
    return open_store($scope, root => $o->{root}, home => $o->{home});
}

# ---------------------------------------------------------------------------
# anchors and the internal directory (S2.3, ruling 1). Pure string
# operations on $store->root() -- no second call to Store's private
# resolvers, and no re-canonicalisation.
# ---------------------------------------------------------------------------

# _anchor_abs($store) -> $abs -- what every `target` value is relative to.
#
# $store->root() is built (Almanac::Store) via Cwd::abs_path, which returns
# raw UTF-8 BYTES with the utf8 flag off on this platform. Every value this
# is later concatenated with (a record's `target` field, decoded by
# Almanac::Record) carries the flag ON -- concatenating the two implicitly
# upgrades the byte string via Latin-1, splitting a multi-byte sequence (the
# CLAUDE.md-documented non-ASCII-path landmine). Decode once here so every
# caller of this function gets a character string consistent with the field
# values it will be joined with.
sub _anchor_abs {
    my ($store) = @_;
    my $r = _decode_maybe($store->root());
    if ($store->scope eq 'project') {
        $r =~ s{/\.ccpraxis-local-data/almanac\z}{};
    } else {
        $r =~ s{/almanac\z}{};
    }
    return $r;
}

# _internal_dir_abs($store) -> $abs -- the one home for internal targets.
sub _internal_dir_abs {
    my ($store) = @_;
    my $r = _decode_maybe($store->root());
    $r =~ s{/almanac\z}{/notes};
    return $r;
}

# _internal_prefix($store) -> $anchor-relative prefix, derived from the two
# above rather than hardcoded per scope.
sub _internal_prefix {
    my ($store) = @_;
    my $anchor = _anchor_abs($store);
    my $dir    = _internal_dir_abs($store);
    my $prefix = $dir;
    $prefix =~ s{\A\Q$anchor\E/}{};
    return $prefix;
}

# _unversioned_prefix($store) -> the scope's unversioned-area prefix (S2.3
# rule 5): '.ccpraxis-local-data' for project, 'notes' for global.
sub _unversioned_prefix {
    my ($store) = @_;
    return $store->scope eq 'project' ? '.ccpraxis-local-data' : 'notes';
}

# _structurally_valid_target($raw) -> 1 | 0 -- S2.3 steps 1-3 only (never
# dies, never checks audience). Used by check_pointers() so a malformed
# target/promote_to field can never make it probe outside the anchor.
sub _structurally_valid_target {
    my ($raw) = @_;
    return 0 unless defined $raw;
    my $t = _trim($raw);
    return 0 if $t eq '';
    return 0 if $t =~ /\\/;
    return 0 if $t =~ m{\A/};
    return 0 if $t =~ /\A[A-Za-z]:/;
    return 0 if $t =~ m{(?:\A|/)\.\.(?:/|\z)};
    return 0 if $t =~ m{//};
    return 0 if $t =~ m{/\z};
    return 0 if $t =~ m{(?:\A|/)\.(?:/|\z)};
    return 0 unless $t =~ /\A.+\.md\z/;
    return 1;
}

# _validate_target($raw, $audience, $store) -> $target -- S2.3, applied on
# every path that writes the field. In order; the first failure wins.
sub _validate_target {
    my ($raw, $audience, $store) = @_;
    my $t = defined($raw) ? _trim($raw) : undef;
    _usage('missing_target') unless defined($t) && length($t);
    _usage('bad_target') if $t =~ /\\/;
    _usage('bad_target') if $t =~ m{\A/};
    _usage('bad_target') if $t =~ /\A[A-Za-z]:/;
    _usage('bad_target') if $t =~ m{(?:\A|/)\.\.(?:/|\z)};
    _usage('bad_target') if $t =~ m{//};
    _usage('bad_target') if $t =~ m{/\z};
    _usage('bad_target') if $t =~ m{(?:\A|/)\.(?:/|\z)};
    _usage('bad_target') unless $t =~ /\A.+\.md\z/;
    if ($audience eq 'internal') {
        my $prefix = _internal_prefix($store);
        _usage('internal_target_outside_notes_dir')
            unless $t =~ m{\A\Q$prefix\E/[^/]+\.md\z};
    } elsif ($audience eq 'external') {
        my $unv = _unversioned_prefix($store);
        # Compared case-insensitively on Windows (and other case-insensitive
        # filesystems): NTFS resolves '.CCPRAXIS-LOCAL-DATA/x.md' and
        # '.ccpraxis-local-data/x.md' to the same file, so a case-sensitive
        # prefix check here would let an "external" note point right back
        # into the unversioned area it exists to escape (redteam MEDIUM).
        my ($tt, $uu) = ($t, $unv);
        if ($^O =~ /^(MSWin32|cygwin|msys)$/) { $tt = lc($tt); $uu = lc($uu); }
        _usage('external_target_unversioned') if $tt =~ m{\A\Q$uu\E/};
    }
    return $t;
}

# ---------------------------------------------------------------------------
# check_pointers() -- the shape package 17 builds against (S2.7, rulings
# 5/6). Never dies, never prints, never exits, never writes.
# ---------------------------------------------------------------------------
sub _err_reason {
    my ($err) = @_;
    if (ref($err) eq 'Almanac::Store::Error' || ref($err) eq 'Almanac::Record::Error') {
        if (defined $err->{kind} && $err->{kind} eq 'scope_unavailable' && defined $err->{reason}) {
            return $err->{reason};
        }
        return defined $err->{kind} ? $err->{kind} : 'error';
    }
    return 'error';
}

sub check_pointers {
    my (%opt) = @_;
    my %out = (type => 'note');
    for my $scope (qw(project global)) {
        my $entry = eval {
            my $store = Almanac::Store->open(scope => $scope, type => 'note',
                root => $opt{root}, home => $opt{home}, cwd => $opt{cwd});
            my $list  = $store->list();
            my $anchor_abs = _anchor_abs($store);

            my @pointers;
            for my $rec (@$list) {
                my $f = $rec->{fields};
                my $audience = (defined($f->{audience})
                             && ($f->{audience} eq 'internal' || $f->{audience} eq 'external'))
                             ? $f->{audience} : undef;
                my $target      = $f->{target};
                my $promote_to  = $f->{promote_to};

                # A note whose audience is garbage can never be listed as
                # healthy (S2.7 clause 6) -- and the AC-30 oracle expects
                # `resolved` itself to stay undef in that case, so the
                # candidate resolution below is gated on a valid audience
                # rather than merely overriding the status afterwards.
                my ($resolved, $status);
                if (!defined $audience) {
                    $status = 'dangling';
                } else {
                    my @candidates;
                    push @candidates, $target     if defined($target)     && _structurally_valid_target($target);
                    push @candidates, $promote_to if defined($promote_to) && _structurally_valid_target($promote_to);

                    for my $c (@candidates) {
                        my $abs = "$anchor_abs/$c";
                        if (-f $abs) { $resolved = $abs; last }
                    }

                    if    (defined($promote_to) &&  defined($resolved)) { $status = 'in_flight' }
                    elsif (!defined($promote_to) && defined($resolved)) { $status = 'ok' }
                    else                                                { $status = 'dangling' }
                }

                push @pointers, {
                    id         => $rec->{id},
                    title      => $f->{title},
                    audience   => $audience,
                    target     => $target,
                    promote_to => $promote_to,
                    resolved   => $resolved,
                    record     => _decode_maybe($rec->{path}),
                    status     => $status,
                };
            }
            my @dangling = grep { $_->{status} eq 'dangling' } @pointers;
            { available => 1, reason => 'ok', pointers => \@pointers, dangling => \@dangling };
        };
        if (my $err = $@) {
            $entry = { available => 0, reason => _err_reason($err) };
        }
        $out{$scope} = $entry;
    }
    return \%out;
}

# ---------------------------------------------------------------------------
# output formatting
# ---------------------------------------------------------------------------
sub _print_result {
    my (%a) = @_;
    print "id: $a{id}\n";
    print "scope: $a{scope}\n";
    print "path: " . _decode_maybe($a{path}) . "\n";
    print "audience: $a{audience}\n" if exists $a{audience};
    print "target: $a{target}\n"     if exists $a{target};
    print "from: $a{from}\n"         if exists $a{from};
    print "rev: $a{rev}\n"           if exists $a{rev};
    print "changed: $a{changed}\n";
}

sub _print_list_default {
    my ($list) = @_;
    my ($internal, $external) = (0, 0);
    for my $rec (@$list) {
        my $f = $rec->{fields};
        print "note: $rec->{id}\n";
        print "  audience: " . (defined $f->{audience} ? $f->{audience} : '-') . "\n";
        print "  target: "   . (defined $f->{target}   ? $f->{target}   : '-') . "\n";
        print "  covers: "   . (defined $f->{covers}   ? $f->{covers}   : '-') . "\n";
        print "  tags: "     . (defined $f->{tags}     ? $f->{tags}     : '-') . "\n";
        print "  title: "    . (defined $f->{title}    ? $f->{title}    : '-') . "\n";
        my $aud = defined $f->{audience} ? $f->{audience} : '';
        $internal++ if $aud eq 'internal';
        $external++ if $aud eq 'external';
    }
    print "total: " . scalar(@$list) . "\n";
    print "internal: $internal\n";
    print "external: $external\n";
}

sub _print_list_json {
    my ($list) = @_;
    my @out = map { $_->{fields} } @$list;
    print JSON::PP->new->canonical(1)->encode(\@out);
}

sub _print_show_default {
    my ($rec) = @_;
    for my $k (@{ $rec->{order} }) {
        next unless exists $rec->{fields}{$k};
        print "$k: $rec->{fields}{$k}\n";
    }
    print "\n";
    print $rec->{body} if defined $rec->{body};
}

sub _print_show_json {
    my ($rec) = @_;
    my %out = (
        id     => $rec->{id},
        path   => _decode_maybe($rec->{path}),
        rev    => $rec->{rev},
        rank   => $rec->{rank},
        fields => $rec->{fields},
        body   => $rec->{body},
    );
    print JSON::PP->new->canonical(1)->encode(\%out);
}

sub _print_check_pointers_default {
    my ($cp) = @_;
    print "type: $cp->{type}\n";
    for my $s (qw(project global)) {
        print "scope: $s\n";
        print "  available: $cp->{$s}{available}\n";
        print "  reason: $cp->{$s}{reason}\n";
        if ($cp->{$s}{available}) {
            print "  total: "    . scalar(@{ $cp->{$s}{pointers} }) . "\n";
            print "  dangling: " . scalar(@{ $cp->{$s}{dangling} }) . "\n";
            for my $e (@{ $cp->{$s}{pointers} }) {
                print "  note: $e->{id}\n";
                print "    audience: " . (defined $e->{audience} ? $e->{audience} : '-') . "\n";
                print "    target: "   . (defined $e->{target}   ? $e->{target}   : '-') . "\n";
                print "    status: $e->{status}\n";
            }
        }
    }
}

# ---------------------------------------------------------------------------
# verbs
# ---------------------------------------------------------------------------
sub _cmd_create {
    my ($scope, $o, $pos) = @_;
    _usage('extra_positional') if @$pos > 0;

    _usage('missing_title') unless exists $o->{title};
    my $title = _trim($o->{title});
    _usage('bad_title') if $title eq '' || $title =~ /[\r\n]/;

    my $audience = exists($o->{audience}) ? $o->{audience} : 'internal';
    _usage('bad_audience') unless $audience eq 'internal' || $audience eq 'external';

    my $store = _open_store($scope, $o);

    my $id = exists($o->{id}) ? $o->{id} : Almanac::Record::new_id();

    my $target;
    my $materialize = 0;
    if (exists $o->{target}) {
        _usage('content_refused') if exists($o->{content}) || exists($o->{'content-file'});
        $target = _validate_target($o->{target}, $audience, $store);
    } elsif ($audience eq 'internal') {
        $target = _internal_prefix($store) . "/$id.md";
        $materialize = 1;
    } else {
        _usage('missing_target');
    }

    my %fields = (title => $title, audience => $audience, target => $target, created => _now_iso());
    if (exists $o->{covers}) {
        my $c = _trim($o->{covers});
        _usage('bad_covers') if $c eq '' || $c =~ /[\r\n]/;
        $fields{covers} = $c;
    }
    if (exists $o->{tags}) {
        my $t = _normalize_tags($o->{tags});
        $fields{tags} = $t if defined $t;
    }

    my @set_order;
    if (exists $o->{set}) {
        for my $pair (@{ $o->{set} }) {
            my ($k, $v) = _parse_set_pair($pair);
            _check_reserved_field($k);
            $fields{$k} = $v;
            push @set_order, $k unless grep { $_ eq $k } @set_order;
        }
    }

    # Re-run the title/covers validation after the --set merge: an override
    # must pass the same rule the first assignment did (S2.5 step 4).
    my $mt = defined $fields{title} ? _trim($fields{title}) : '';
    _usage('bad_title') if $mt eq '' || $mt =~ /[\r\n]/;
    $fields{title} = $mt;
    if (exists $fields{covers}) {
        my $mc = defined $fields{covers} ? _trim($fields{covers}) : '';
        _usage('bad_covers') if $mc eq '' || $mc =~ /[\r\n]/;
        $fields{covers} = $mc;
    }

    my $body = _resolve_body($o);

    if ($materialize) {
        my $internal_dir = _internal_dir_abs($store);
        File::Path::make_path($internal_dir) unless -d $internal_dir;
        # An id with a path separator cannot name a sane single-level
        # target file; skip materialization and let the store's own id
        # grammar check (bad_id, at create() below) be the one authoritative
        # refusal rather than an incidental ENOENT from a nested open().
        unless ($id =~ m{[\\/]}) {
            my $target_abs = _anchor_abs($store) . "/$target";
            if (-e $target_abs) {
                die Almanac::Store::Error->new(kind => 'exists', id => $id, path => _encode_for_error($target_abs));
            }
            my $content = _resolve_content($o);
            $content = '' unless defined $content;
            open(my $fh, '>:raw', $target_abs)
                or die Almanac::Store::Error->new(kind => 'io', path => _encode_for_error($target_abs), errno => "$!");
            print {$fh} $content;
            close($fh)
                or die Almanac::Store::Error->new(kind => 'io', path => _encode_for_error($target_abs), errno => "$!");
        }
    }

    my @base_order = grep { exists $fields{$_} } qw(title audience target covers created tags);
    my %seen = map { $_ => 1 } @base_order;
    my @extra = sort grep { !$seen{$_} } @set_order;
    my @order = (@base_order, @extra);

    my %create_args = (id => $id, fields => \%fields, order => \@order);
    $create_args{body} = $body if defined $body;

    my $rec = $store->create(%create_args);
    _print_result(id => $rec->{id}, scope => $scope, path => $rec->{path},
                  audience => $rec->{fields}{audience}, target => $rec->{fields}{target},
                  rev => $rec->{rev}, changed => 'yes');
}

sub _cmd_list {
    my ($scope, $o, $pos) = @_;
    _usage('extra_positional') if @$pos > 0;
    my $store = _open_store($scope, $o);
    my $list  = $store->list();
    if ($o->{json}) { _print_list_json($list) }
    else            { _print_list_default($list) }
}

sub _cmd_show {
    my ($scope, $o, $pos) = @_;
    my $id = $pos->[0];
    _usage('missing_id') unless defined $id && length $id;
    _usage('extra_positional') if @$pos > 1;
    my $store = _open_store($scope, $o);
    my $rec   = $store->read($id);
    if ($o->{json}) { _print_show_json($rec) }
    else            { _print_show_default($rec) }
}

sub _cmd_edit {
    my ($scope, $o, $pos) = @_;
    my $id = $pos->[0];
    _usage('missing_id') unless defined $id && length $id;
    _usage('extra_positional') if @$pos > 1;

    my %set;
    my @set_order;
    if (exists $o->{set}) {
        for my $pair (@{ $o->{set} }) {
            my ($k, $v) = _parse_set_pair($pair);
            _check_reserved_field($k);
            $set{$k} = $v;
            push @set_order, $k unless grep { $_ eq $k } @set_order;
        }
    }
    my @unset;
    if (exists $o->{unset}) {
        for my $k (@{ $o->{unset} }) {
            _check_reserved_field($k);
            push @unset, $k;
        }
    }

    my $title_given  = exists $o->{title};
    my $covers_given = exists $o->{covers};
    my $tags_given   = exists $o->{tags};
    my $body_given   = exists($o->{body}) || exists($o->{'body-file'});

    _usage('nothing_to_change')
        unless $title_given || $covers_given || $tags_given || $body_given || @set_order || @unset;

    if ($title_given) {
        my $t = _trim($o->{title});
        _usage('bad_title') if $t eq '' || $t =~ /[\r\n]/;
        $set{title} = $t;
    }
    if ($covers_given) {
        my $c = _trim($o->{covers});
        _usage('bad_covers') if $c eq '' || $c =~ /[\r\n]/;
        $set{covers} = $c;
    }
    if ($tags_given) {
        my $t = _normalize_tags($o->{tags});
        if (defined $t) { $set{tags} = $t }
        else            { push @unset, 'tags' unless grep { $_ eq 'tags' } @unset }
    }
    my $body = $body_given ? _resolve_body($o) : undef;

    my $store = _open_store($scope, $o);
    my $rec   = $store->read($id);
    my %expect = (rev => $rec->{rev}, fields => $rec->{fields});
    $expect{rev} = $o->{'expect-rev'} if exists $o->{'expect-rev'};

    my %update_args = (expect => \%expect, set => \%set, unset => \@unset);
    $update_args{body} = $body if $body_given;

    my $new = $store->update($id, %update_args);
    _print_result(id => $new->{id}, scope => $scope, path => $new->{path},
                  audience => $new->{fields}{audience}, target => $new->{fields}{target},
                  rev => $new->{rev}, changed => 'yes');
}

sub _cmd_promote {
    my ($scope, $o, $pos) = @_;
    my $id = $pos->[0];
    _usage('missing_id') unless defined $id && length $id;
    _usage('extra_positional') if @$pos > 1;

    my $store = _open_store($scope, $o);   # dies scope_unavailable (Decision 7)
    my $rec   = $store->read($id);         # dies not_found

    my $target_audience = exists($o->{audience}) ? $o->{audience} : 'external';
    _usage('bad_audience') unless $target_audience eq 'internal' || $target_audience eq 'external';

    # target_refused is checked ahead of audience_unchanged: a caller asking
    # to promote to 'internal' while also naming --target is a contradiction
    # in the REQUEST itself (there is no defaultable destination for an
    # internal promote to override), independent of whether the CURRENT
    # audience happens to already be internal too. Naming the mistake in the
    # request beats reporting that nothing would have changed.
    _usage('target_refused') if $target_audience eq 'internal' && exists $o->{target};

    _usage('audience_unchanged')
        if defined($rec->{fields}{audience}) && $rec->{fields}{audience} eq $target_audience;

    my $dest_rel;
    my $is_internal_default = 0;
    if ($target_audience eq 'external') {
        _usage('missing_target') unless exists $o->{target};
        $dest_rel = _validate_target($o->{target}, 'external', $store);
    } else {
        $dest_rel = _internal_prefix($store) . "/$id.md";
        $is_internal_default = 1;
    }

    my $anchor_abs = _anchor_abs($store);
    my $dest_abs   = "$anchor_abs/$dest_rel";
    unless ($is_internal_default) {
        my $parent = $dest_abs;
        $parent =~ s{/[^/]+\z}{};
        _usage('dest_parent_missing') unless -d $parent;
    }

    my $src_rel = $rec->{fields}{target};

    # redteam HIGH-1: this record's OWN `target` field is trusted as a
    # rename source below with no path validation, while check_pointers()
    # guards the identical field via _structurally_valid_target before ever
    # treating it as a filesystem path. A malformed `target` (hand-edited,
    # written by a stale script version, or a future bug) must not be able
    # to turn a rename source into an out-of-anchor path.
    die Almanac::Store::Error->new(kind => 'malformed', id => $id,
            path => _encode_for_error(defined($src_rel) ? "$anchor_abs/$src_rel" : undef))
        unless defined($src_rel) && _structurally_valid_target($src_rel);

    my $src_abs = "$anchor_abs/$src_rel";

    my $resuming = defined($rec->{fields}{promote_to}) && $rec->{fields}{promote_to} eq $dest_rel;

    # redteam MEDIUM: a resume must still fail closed against an occupied
    # destination -- but "occupied" only means something UNRELATED sits
    # there. If we are resuming and the source file is already gone, the
    # destination is what THIS promote's own phase 2 already wrote, and
    # that is not a conflict. If the source is still present, phase 2 never
    # ran and whatever is at $dest_abs is a foreign occupant.
    die Almanac::Store::Error->new(kind => 'exists', id => $id, path => _encode_for_error($dest_abs))
        if -e $dest_abs && (!$resuming || -e $src_abs);

    # redteam HIGH-2 / review MEDIUM-3: two interleaved promotes on the same
    # note must not let the second phase-1 write clobber the first's live
    # `promote_to` journal entry -- that would orphan the already-moved (or
    # about-to-move) content with no crash and no recovery. A resume of the
    # SAME destination is fine; a different, still-live journal entry is a
    # conflict.
    if (defined($rec->{fields}{promote_to}) && !$resuming) {
        die Almanac::Store::Error->new(kind => 'conflict', id => $id, field => 'promote_to',
            winner => undef, expected_rev => undef, actual_rev => $rec->{rev},
            path => _encode_for_error($rec->{path}));
    }

    my %baseline = (rev => $rec->{rev}, fields => $rec->{fields});
    $baseline{rev} = $o->{'expect-rev'} if exists $o->{'expect-rev'};

    # --- PHASE 1: journal the destination, committed to disk BEFORE anything moves.
    # This is also the writability gate -- $store->update's own writable
    # check fires here, before any file has moved.
    my $r1 = $store->update($id, expect => \%baseline, set => { promote_to => $dest_rel });

    # --- PHASE 2: move the file (skip if already moved -- resume).
    unless (-e $dest_abs && (!defined($src_abs) || !-e $src_abs)) {
        die Almanac::Store::Error->new(kind => 'not_found', id => $id, path => _encode_for_error($src_abs))
            unless defined($src_abs) && -e $src_abs;
        File::Path::make_path(_internal_dir_abs($store)) if $is_internal_default;
        my ($ok, $err) = Almanac::Lock::rename_with_retry($src_abs, $dest_abs);
        die Almanac::Store::Error->new(kind => 'io', path => _encode_for_error($dest_abs), errno => $err->{errno})
            unless $ok;
    }

    # --- PHASE 3: commit the new pointer and retire the journal.
    my $r2 = $store->update($id,
        expect => { rev => $r1->{rev}, fields => $r1->{fields} },
        set    => { audience => $target_audience, target => $dest_rel },
        unset  => ['promote_to'],
    );

    _print_result(id => $r2->{id}, scope => $scope, path => $r2->{path},
                  audience => $r2->{fields}{audience}, target => $r2->{fields}{target},
                  from => $src_rel, rev => $r2->{rev}, changed => 'yes');
}

sub _cmd_delete {
    my ($scope, $o, $pos) = @_;
    my $id = $pos->[0];
    _usage('missing_id') unless defined $id && length $id;
    _usage('extra_positional') if @$pos > 1;
    my $store = _open_store($scope, $o);
    my $rec   = $store->read($id);
    my %expect = (rev => $rec->{rev}, fields => $rec->{fields});
    $expect{rev} = $o->{'expect-rev'} if exists $o->{'expect-rev'};
    $store->delete($id, expect => \%expect);
    _print_result(id => $rec->{id}, scope => $scope, path => $rec->{path}, changed => 'yes');
}

sub _cmd_check_pointers {
    my ($o, $pos) = @_;
    _usage('extra_positional') if @$pos > 0;
    my $cp = check_pointers(root => $o->{root}, home => $o->{home});
    if ($o->{json}) { print JSON::PP->new->canonical(1)->encode($cp) }
    else            { _print_check_pointers_default($cp) }
}

# ---------------------------------------------------------------------------
# CLI entry point
# ---------------------------------------------------------------------------
unless (caller) {
    binmode(STDOUT, ':encoding(UTF-8)');

    # Argv grammar (S2.2). Parsed in one pass over the WHOLE of @ARGV -- the
    # verb is not special-cased out beforehand, it is simply the first
    # positional token once parsing is done.
    my (%o, %bool_default, @pos);
    while (@ARGV) {
        my $a = shift @ARGV;
        if ($a =~ /^--([a-z0-9-]+)$/) {
            # Capture the key BEFORE the lookahead match below -- a
            # successful match resets $1 (the almanac-bug.pl landmine,
            # reproduced faithfully here).
            my $key = $1;
            my $has_val = (@ARGV && $ARGV[0] !~ /^--/);
            my $val = $has_val ? shift @ARGV : 1;
            if ($key eq 'set' || $key eq 'unset') {
                push @{ $o{$key} ||= [] }, $val;
            } else {
                $o{$key} = $val;
                if ($has_val) { delete $bool_default{$key} }
                else          { $bool_default{$key} = 1 }
            }
        } else {
            push @pos, $a;
        }
    }
    my $cmd = shift @pos;

    my $ok = eval {
        _usage('missing_verb') unless defined $cmd && length $cmd;

        my %VERBS = map { $_ => 1 } qw(create list show edit promote delete check-pointers);
        _usage('unknown_verb') unless $VERBS{$cmd};

        # Per-verb flag allowlist (S2.2), checked after the verb is known.
        my %ALLOWED_FLAGS = (
            create         => [qw(title audience target covers tags body body-file content content-file set id root home global project)],
            list           => [qw(json root home global project)],
            show           => [qw(json root home global project)],
            edit           => [qw(title covers tags body body-file set unset expect-rev root home global project)],
            promote        => [qw(audience target expect-rev root home global project)],
            delete         => [qw(expect-rev root home global project)],
            'check-pointers' => [qw(json root home global project)],
        );
        my %allowed = map { $_ => 1 } @{ $ALLOWED_FLAGS{$cmd} };
        for my $k (keys %o) {
            _usage('unknown_flag') unless $allowed{$k};
        }

        # Value-taking flags fail CLOSED when their value is missing (S2.2).
        for my $k (qw(root home id title target covers tags body body-file content content-file audience expect-rev)) {
            _usage('missing_flag_value') if $bool_default{$k};
        }

        if ($cmd ne 'check-pointers') {
            _usage('scope_conflict') if exists($o{project}) && exists($o{global});
        }
        my $scope = exists($o{global}) ? 'global' : 'project';

        if    ($cmd eq 'create')          { _cmd_create($scope, \%o, \@pos) }
        elsif ($cmd eq 'list')            { _cmd_list($scope, \%o, \@pos) }
        elsif ($cmd eq 'show')            { _cmd_show($scope, \%o, \@pos) }
        elsif ($cmd eq 'edit')            { _cmd_edit($scope, \%o, \@pos) }
        elsif ($cmd eq 'promote')         { _cmd_promote($scope, \%o, \@pos) }
        elsif ($cmd eq 'delete')          { _cmd_delete($scope, \%o, \@pos) }
        elsif ($cmd eq 'check-pointers')  { _cmd_check_pointers(\%o, \@pos) }
        1;
    };
    unless ($ok) {
        Almanac::Record::fatal($@);
    }
    exit 0;
}

1;
