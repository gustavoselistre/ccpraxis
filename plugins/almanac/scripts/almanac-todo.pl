#!/usr/bin/env perl
# almanac-todo.pl -- todo CRUD over Almanac::Store (blueprint almanac-records,
# package 04-todos). See specs/04-todos-spec.md for the full contract; this
# file implements it and adds nothing beyond it.
#
# Store type is the literal string 'todo'. Every read/write goes through
# Almanac::Store -- this file contains no frontmatter parsing, no '---'
# delimiter handling, and no container-surface detection of its own (that
# stays inside Almanac::Store::surface(), package 03's single decision
# point).
package Almanac::Todo;
use strict;
use warnings;
use JSON::PP ();
use Encode ();

# Almanac/ sits beside THIS FILE (not $0, not FindBin -- both are the
# invoking program, which a test's `do $TODO_PL` makes the .t file, not
# this one). See almanac-bug.pl's BEGIN block for the same reasoning.
BEGIN {
    my $dir = __FILE__;
    $dir =~ s{\\}{/}g;
    $dir =~ s{/[^/]+\z}{};
    $dir = '.' unless length $dir;
    unshift @INC, $dir;
}
use Almanac::Store ();
use Almanac::Record ();

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
# platform returns raw UTF-8 BYTES without the internal utf8 flag set (every
# other value this script prints -- field values, the body -- already comes
# back as decoded characters from Almanac::Record). Printing raw bytes
# through STDOUT's single ':encoding(UTF-8)' layer would encode them a
# SECOND time (the em-dash/mojibake class documented across this plugin).
# Decode once here so the STDOUT layer's one encode is the only one (S2.7,
# S5.1: "this script never re-encodes a path it received").
sub _decode_maybe {
    my ($s) = @_;
    return $s unless defined $s;
    return $s if utf8::is_utf8($s);
    my $d = eval { Encode::decode('UTF-8', $s, Encode::FB_CROAK()) };
    return defined $d ? $d : $s;
}

sub _now_iso {
    my @t = gmtime(time);
    return sprintf('%04d-%02d-%02dT%02d:%02d:%02dZ',
                   $t[5] + 1900, $t[4] + 1, $t[3], $t[2], $t[1], $t[0]);
}

# _normalize_tags($raw) -> $normalized | undef
# undef means "zero tokens" -- omit on create, unset on edit (the caller
# decides which; this just reports "nothing left").
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

# _resolve_body(\%o) -> $body | undef
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

# open_store($scope, %opt) -> $store   -- %opt: root, home
sub open_store {
    my ($scope, %opt) = @_;
    return Almanac::Store->open(scope => $scope, type => 'todo',
                                 root => $opt{root}, home => $opt{home});
}

sub _open_store {
    my ($scope, $o) = @_;
    return open_store($scope, root => $o->{root}, home => $o->{home});
}

# ---------------------------------------------------------------------------
# count() -- the shape package 10 and package 19 build against (S2.6).
# Never dies, never prints, never exits.
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

sub count {
    my (%opt) = @_;
    my %out = (type => 'todo');
    for my $scope (qw(project global)) {
        my $store = eval {
            Almanac::Store->open(scope => $scope, type => 'todo',
                                  root => $opt{root}, home => $opt{home}, cwd => $opt{cwd});
        };
        if (my $err = $@) {
            $out{$scope} = { available => 0, reason => _err_reason($err) };
            next;
        }
        my $list = eval { $store->list() };
        if (my $err = $@) {
            $out{$scope} = { available => 0, reason => _err_reason($err) };
            next;
        }
        my ($o, $d, $t) = (0, 0, 0);
        my $bad = 0;
        for my $rec (@$list) {
            $t++;
            my $st = $rec->{fields}{status};
            if    (defined $st && $st eq 'open') { $o++ }
            elsif (defined $st && $st eq 'done') { $d++ }
            else                                 { $bad = 1; last }
        }
        if ($bad) {
            $out{$scope} = { available => 0, reason => 'bad_status' };
            next;
        }
        $out{$scope} = { available => 1, reason => 'ok', open => $o, done => $d, total => $t };
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
    print "status: $a{status}\n" if defined $a{status};
    print "rev: $a{rev}\n"       if defined $a{rev};
    print "changed: $a{changed}\n";
}

sub _print_list_default {
    my ($list) = @_;
    my ($open, $done) = (0, 0);
    for my $rec (@$list) {
        my $f = $rec->{fields};
        print "todo: $rec->{id}\n";
        print "  status: "  . (defined $f->{status}  ? $f->{status}  : '-') . "\n";
        print "  created: " . (defined $f->{created} ? $f->{created} : '-') . "\n";
        print "  tags: "    . (defined $f->{tags}    ? $f->{tags}    : '-') . "\n";
        print "  title: "   . (defined $f->{title}   ? $f->{title}   : '-') . "\n";
        my $st = defined $f->{status} ? $f->{status} : '';
        $open++ if $st eq 'open';
        $done++ if $st eq 'done';
    }
    print "total: " . scalar(@$list) . "\n";
    print "open: $open\n";
    print "done: $done\n";
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

sub _print_count_default {
    my ($c) = @_;
    print "type: $c->{type}\n";
    for my $s (qw(project global)) {
        print "scope: $s\n";
        print "  available: $c->{$s}{available}\n";
        print "  reason: $c->{$s}{reason}\n";
        if ($c->{$s}{available}) {
            print "  open: $c->{$s}{open}\n";
            print "  done: $c->{$s}{done}\n";
            print "  total: $c->{$s}{total}\n";
        }
    }
}

# ---------------------------------------------------------------------------
# verbs
# ---------------------------------------------------------------------------
sub _cmd_create {
    my ($scope, $o, $bool_default) = @_;

    my $title_missing = !exists($o->{title})
        || ($bool_default->{title} && !ref($o->{title}) && $o->{title} eq '1');
    _usage('missing_title') if $title_missing;

    my $title = _trim($o->{title});
    _usage('bad_title') if $title eq '' || $title =~ /[\r\n]/;

    my $body = _resolve_body($o);

    my %fields = (title => $title, status => 'open', created => _now_iso());
    if (exists $o->{tags}) {
        my $t = _normalize_tags($o->{tags});
        $fields{tags} = $t if defined $t;
    }

    my @set_order;
    if (exists $o->{set}) {
        for my $pair (@{ $o->{set} }) {
            my ($k, $v) = _parse_set_pair($pair);
            _usage('status_is_reserved') if $k eq 'status';
            $fields{$k} = $v;
            push @set_order, $k unless grep { $_ eq $k } @set_order;
        }
    }

    # Re-run the same title validation after the --set merge (redteam
    # LOW-2): --set title=... legitimately overrides the computed title
    # (package 11's migration needs it), but the override must still pass
    # the bad_title rule the first assignment already enforced.
    my $merged_title = defined $fields{title} ? _trim($fields{title}) : '';
    _usage('bad_title') if $merged_title eq '' || $merged_title =~ /[\r\n]/;

    my @base_order = grep { exists $fields{$_} } qw(title status created completed_at tags);
    my %seen = map { $_ => 1 } @base_order;
    my @extra = sort grep { !$seen{$_} } @set_order;
    my @order = (@base_order, @extra);

    my $store = _open_store($scope, $o);
    my %create_args = (fields => \%fields, order => \@order);
    $create_args{id}   = $o->{id} if exists $o->{id};
    $create_args{body} = $body    if defined $body;

    my $rec = $store->create(%create_args);
    _print_result(id => $rec->{id}, scope => $scope, path => $rec->{path},
                  status => $rec->{fields}{status}, rev => $rec->{rev}, changed => 'yes');
}

sub _cmd_list {
    my ($scope, $o) = @_;
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
            _usage('status_is_reserved') if $k eq 'status';
            $set{$k} = $v;
            push @set_order, $k unless grep { $_ eq $k } @set_order;
        }
    }
    my @unset;
    if (exists $o->{unset}) {
        for my $k (@{ $o->{unset} }) {
            _usage('status_is_reserved') if $k eq 'status';
            push @unset, $k;
        }
    }

    my $title_given = exists $o->{title};
    my $tags_given  = exists $o->{tags};
    my $body_given  = exists($o->{body}) || exists($o->{'body-file'});

    _usage('nothing_to_change')
        unless $title_given || $tags_given || $body_given || @set_order || @unset;

    if ($title_given) {
        my $t = _trim($o->{title});
        _usage('bad_title') if $t eq '' || $t =~ /[\r\n]/;
        $set{title} = $t;
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
                  status => $new->{fields}{status}, rev => $new->{rev}, changed => 'yes');
}

sub _cmd_complete {
    my ($scope, $o, $pos) = @_;
    my $id = $pos->[0];
    _usage('missing_id') unless defined $id && length $id;
    _usage('extra_positional') if @$pos > 1;
    my $store = _open_store($scope, $o);
    my $rec   = $store->read($id);
    if (defined($rec->{fields}{status}) && $rec->{fields}{status} eq 'done') {
        _print_result(id => $rec->{id}, scope => $scope, path => $rec->{path},
                      status => $rec->{fields}{status}, rev => $rec->{rev}, changed => 'no');
        return;
    }
    my %expect = (rev => $rec->{rev}, fields => $rec->{fields});
    $expect{rev} = $o->{'expect-rev'} if exists $o->{'expect-rev'};
    my $new = $store->update($id, expect => \%expect,
                              set => { status => 'done', completed_at => _now_iso() });
    _print_result(id => $new->{id}, scope => $scope, path => $new->{path},
                  status => $new->{fields}{status}, rev => $new->{rev}, changed => 'yes');
}

sub _cmd_reopen {
    my ($scope, $o, $pos) = @_;
    my $id = $pos->[0];
    _usage('missing_id') unless defined $id && length $id;
    _usage('extra_positional') if @$pos > 1;
    my $store = _open_store($scope, $o);
    my $rec   = $store->read($id);
    if (defined($rec->{fields}{status}) && $rec->{fields}{status} eq 'open') {
        _print_result(id => $rec->{id}, scope => $scope, path => $rec->{path},
                      status => $rec->{fields}{status}, rev => $rec->{rev}, changed => 'no');
        return;
    }
    my %expect = (rev => $rec->{rev}, fields => $rec->{fields});
    $expect{rev} = $o->{'expect-rev'} if exists $o->{'expect-rev'};
    my $new = $store->update($id, expect => \%expect,
                              set => { status => 'open' }, unset => ['completed_at']);
    _print_result(id => $new->{id}, scope => $scope, path => $new->{path},
                  status => $new->{fields}{status}, rev => $new->{rev}, changed => 'yes');
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

sub _cmd_count {
    my ($o) = @_;
    my $c = count(root => $o->{root}, home => $o->{home});
    if ($o->{json}) { print JSON::PP->new->canonical(1)->encode($c) }
    else            { _print_count_default($c) }
}

# ---------------------------------------------------------------------------
# CLI entry point
# ---------------------------------------------------------------------------
unless (caller) {
    binmode(STDOUT, ':encoding(UTF-8)');

    # Argv grammar (S2.2). Parsed in one pass over the WHOLE of @ARGV -- the
    # verb is not special-cased out beforehand, it is simply the first
    # positional token once parsing is done (so `--root X` with no verb at
    # all correctly yields an EMPTY positional list, not a bogus verb).
    my (%o, %bool_default, @pos);
    while (@ARGV) {
        my $a = shift @ARGV;
        if ($a =~ /^--([a-z0-9-]+)$/) {
            # Capture the key BEFORE the lookahead match below -- a
            # successful match resets $1 (almanac-bug.pl's documented
            # landmine, reproduced faithfully here).
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

        my %VERBS = map { $_ => 1 } qw(create list show edit complete reopen delete count);
        _usage('unknown_verb') unless $VERBS{$cmd};

        # Per-verb flag allowlist (redteam MEDIUM-3): an unknown flag --
        # most dangerously a typo'd --expect-rev -- must fail closed rather
        # than being silently dropped by the argv loop above.
        my %ALLOWED_FLAGS = (
            create   => [qw(title body body-file tags set id root home global project)],
            list     => [qw(json root home global project)],
            show     => [qw(json root home global project)],
            edit     => [qw(title body body-file tags set unset expect-rev root home global project)],
            complete => [qw(expect-rev root home global project)],
            reopen   => [qw(expect-rev root home global project)],
            delete   => [qw(expect-rev root home global project)],
            count    => [qw(root home json global project)],
        );
        my %allowed = map { $_ => 1 } @{ $ALLOWED_FLAGS{$cmd} };
        for my $k (keys %o) {
            _usage('unknown_flag') unless $allowed{$k};
        }

        # Value-taking flags fail OPEN when their value is missing (redteam
        # MEDIUM-2): a bare --root/--home/--id/--tags/--body/--body-file/
        # --expect-rev silently becomes the sentinel '1' instead of erroring.
        # --title already has its own bespoke guard inside _cmd_create.
        for my $k (qw(root home id tags body body-file expect-rev)) {
            _usage('missing_flag_value') if $bool_default{$k};
        }

        if ($cmd ne 'count') {
            _usage('scope_conflict') if exists($o{project}) && exists($o{global});
        }
        my $scope = exists($o{global}) ? 'global' : 'project';

        if    ($cmd eq 'create')   { _cmd_create($scope, \%o, \%bool_default) }
        elsif ($cmd eq 'list')     { _cmd_list($scope, \%o) }
        elsif ($cmd eq 'show')     { _cmd_show($scope, \%o, \@pos) }
        elsif ($cmd eq 'edit')     { _cmd_edit($scope, \%o, \@pos) }
        elsif ($cmd eq 'complete') { _cmd_complete($scope, \%o, \@pos) }
        elsif ($cmd eq 'reopen')   { _cmd_reopen($scope, \%o, \@pos) }
        elsif ($cmd eq 'delete')   { _cmd_delete($scope, \%o, \@pos) }
        elsif ($cmd eq 'count')    { _cmd_count(\%o) }
        1;
    };
    unless ($ok) {
        Almanac::Record::fatal($@);
    }
    exit 0;
}

1;
