#!/usr/bin/env perl
# almanac-decision.pl -- the project-only pending-decisions store, over
# Almanac::Store (blueprint almanac-records, package 08-pending-decisions).
# See specs/08-pending-decisions-spec.md for the full contract; this file
# implements it and adds nothing beyond it.
#
# Agent-authored (`file`), operator-answered (`answer`). This package owns
# the traversal decision -> tasks whose blocked_on names it; it reads tasks
# only through Almanac::Task::list_tasks (loaded below as the sibling
# script), never owning or writing that field itself.
package Almanac::Decision;
use strict;
use warnings;
use JSON::PP ();
use Encode ();

# Almanac/ and almanac-task.pl sit beside THIS FILE (not $0, not FindBin --
# both are the invoking program, which a test's `do $DECISION_PL` makes the
# .t file, not this one).
my $TASK_PL;
BEGIN {
    my $dir = __FILE__;
    $dir =~ s{\\}{/}g;
    $dir = ($dir =~ m{/}) ? ($dir =~ s{/[^/]+\z}{}r) : '.';
    unshift @INC, $dir;
    $TASK_PL = "$dir/almanac-task.pl";
}
use Almanac::Store ();
use Almanac::Record ();

# Loading this script brings Almanac::Task::* with it (spec S2.3): a
# `require` of the sibling script's absolute path, at compile time, so
# after loading almanac-decision.pl alone, Almanac::Task::* is already
# defined. `require` (unlike `system`/`exec`) runs it with a caller frame,
# so almanac-task.pl's own `unless (caller)` CLI main never fires here.
require $TASK_PL;

our $VERSION = '1.0';

# ---------------------------------------------------------------------------
# small helpers.
# ---------------------------------------------------------------------------

sub _usage { die Almanac::Store::Error->new(kind => 'usage', detail => $_[0]) }

sub _trim {
    my ($s) = @_;
    return $s unless defined $s;
    $s =~ s/\A\s+//;
    $s =~ s/\s+\z//;
    return $s;
}

# _decode_maybe($s) -> decoded character string. See almanac-task.pl's
# comment of the same name.
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

# ---------------------------------------------------------------------------
# 2.3 -- module functions.
# ---------------------------------------------------------------------------

# open_decisions(%opt) -> Almanac::Store -- THE single accessor: every other
# function and CLI verb in this file reaches the decision store only through
# this sub. It is the ONLY ->open( call in the whole file.
sub open_decisions {
    my (%opt) = @_;
    return Almanac::Store->open(scope => 'project', type => 'decision',
        root => $opt{root}, home => $opt{home}, cwd => $opt{cwd});
}

sub file {
    my (%opt) = @_;
    _usage('missing_title') unless exists($opt{title}) && defined($opt{title});
    my $title = _trim($opt{title});
    _usage('bad_title') if $title eq '' || $title =~ /[\r\n]/;

    my %fields = (title => $title, status => 'unanswered', created => _now_iso());
    my @order  = qw(title status created);

    my %args = (fields => \%fields, order => \@order);
    $args{id}   = $opt{id}   if exists $opt{id};
    $args{body} = $opt{body} if exists $opt{body};

    return open_decisions(%opt)->create(%args);
}

sub list_decisions {
    my (%opt) = @_;
    return open_decisions(%opt)->list();
}

sub read_decision {
    my ($id, %opt) = @_;
    return open_decisions(%opt)->read($id);
}

# answer($id, %opt) -> ($record, $changed) -- opt: answer*, expect_rev. The
# five-way branch of spec S2.3.
sub answer {
    my ($id, %opt) = @_;
    _usage('missing_answer') unless exists($opt{answer}) && defined($opt{answer});
    my $ans = _decode_maybe(_trim($opt{answer}));
    _usage('bad_answer') if $ans eq '' || $ans =~ /[\r\n]/;

    my $store = open_decisions(%opt);
    my $rec   = $store->read($id);
    my $status = $rec->{fields}{status};

    if (defined($status) && $status eq 'unanswered') {
        my %expect = (rev => (exists $opt{expect_rev} ? $opt{expect_rev} : $rec->{rev}),
                      fields => $rec->{fields});
        my $new = $store->update($id, expect => \%expect,
            set => { status => 'answered', answer => $ans, answered_at => _now_iso() });
        return ($new, 1);
    }
    elsif (defined($status) && $status eq 'answered') {
        my $cur_answer = defined($rec->{fields}{answer}) ? $rec->{fields}{answer} : undef;
        if (defined($cur_answer) && $cur_answer eq $ans) {
            return ($rec, 0);
        }
        _usage('already_answered');
    }
    else {
        _usage('bad_status');
    }
}

# blocked_tasks($id, %opt) -> \%report -- NEVER dies, prints, or writes task
# records except via Store's own crash recovery of the task store (Store::
# list() rolls back an abandoned reorder journal when the store is
# writable). Tasks are obtained only via Almanac::Task::list_tasks; this sub
# does not open a task store itself and never checks that decision $id
# exists.
sub blocked_tasks {
    my ($id, %opt) = @_;
    my $report = { decision => $id };

    # $ok, not `if (my $err = $@)`: an error object may stringify to ''
    # (Store::Error's `""` overload falls back on `{message}`, and a bare
    # error with no message is boolean-false even as a real reference), so
    # $@ truthiness alone can miss a real failure and fall through to
    # `@$list` on an undef $list -- reported wrongly as available => 1.
    my $list;
    my $ok = eval { $list = Almanac::Task::list_tasks(%opt); 1 };
    unless ($ok) {
        $report->{available} = 0;
        $report->{reason}    = _err_reason($@);
        return $report;
    }

    my @tasks;
    for my $t (@$list) {
        my $bo = $t->{fields}{blocked_on};
        next unless defined $bo && $bo eq $id;
        push @tasks, {
            task   => $t->{id},
            status => $t->{fields}{status},
            title  => $t->{fields}{title},
            ref    => ((defined($t->{fields}{status}) && $t->{fields}{status} eq 'obsoleted')
                       ? 'dangling' : 'live'),
        };
    }
    my @dangling = grep { $_->{ref} eq 'dangling' } @tasks;

    $report->{available} = 1;
    $report->{reason}    = 'ok';
    $report->{tasks}      = \@tasks;
    $report->{dangling}   = \@dangling;
    return $report;
}

# count(%opt) -> \%counts -- NEVER dies, prints or writes. Shape mirrors
# Almanac::Todo::count; project key only (decisions have no global scope).
sub count {
    my (%opt) = @_;
    my $report = { type => 'decision' };

    my $list;
    my $ok = eval { $list = list_decisions(%opt); 1 };
    unless ($ok) {
        $report->{project} = { available => 0, reason => _err_reason($@) };
        return $report;
    }

    my ($un, $an) = (0, 0);
    for my $r (@$list) {
        my $s = $r->{fields}{status};
        if (defined($s) && $s eq 'unanswered') { $un++ }
        elsif (defined($s) && $s eq 'answered') { $an++ }
        else {
            $report->{project} = { available => 0, reason => 'bad_status' };
            return $report;
        }
    }
    $report->{project} = { available => 1, reason => 'ok', unanswered => $un, answered => $an, total => $un + $an };
    return $report;
}

# ---------------------------------------------------------------------------
# output formatting (CLI only).
# ---------------------------------------------------------------------------
sub _print_result {
    my ($rec, %a) = @_;
    print "id: $rec->{id}\n";
    print "path: " . _decode_maybe($rec->{path}) . "\n";
    print "status: $a{status}\n";
    print "rev: $rec->{rev}\n";
    print "changed: $a{changed}\n";
}

sub _print_traversal {
    my ($report) = @_;
    print "decision: $report->{decision}\n";
    print "tasks_available: " . ($report->{available} ? 'yes' : 'no') . "\n";
    print "tasks_reason: $report->{reason}\n";
    if ($report->{available}) {
        for my $t (@{ $report->{tasks} }) {
            print "blocked_task: $t->{task}\n";
            print "  status: " . (defined $t->{status} ? $t->{status} : '-') . "\n";
            print "  ref: $t->{ref}\n";
            print "  title: "  . (defined $t->{title}  ? $t->{title}  : '-') . "\n";
        }
        print "blocked_total: "  . scalar(@{ $report->{tasks} })    . "\n";
        print "dangling_total: " . scalar(@{ $report->{dangling} }) . "\n";
    } else {
        print "blocked_total: 0\n";
        print "dangling_total: 0\n";
    }
}

sub _print_traversal_json {
    my ($report) = @_;
    my @blocked;
    if ($report->{available}) {
        for my $t (@{ $report->{tasks} }) {
            push @blocked, { id => $t->{task}, status => $t->{status}, title => $t->{title}, ref => $t->{ref} };
        }
    }
    my %out = (
        decision        => $report->{decision},
        tasks_available => ($report->{available} ? JSON::PP::true() : JSON::PP::false()),
        tasks_reason    => $report->{reason},
        blocked         => \@blocked,
    );
    print JSON::PP->new->canonical(1)->encode(\%out);
}

sub _print_list_default {
    my ($list) = @_;
    my ($un, $an) = (0, 0);
    for my $rec (@$list) {
        my $f = $rec->{fields};
        print "decision: $rec->{id}\n";
        print "  status: " . (defined $f->{status} ? $f->{status} : '-') . "\n";
        print "  title: "  . (defined $f->{title}  ? $f->{title}  : '-') . "\n";
        print "  answer: " . (defined $f->{answer} ? $f->{answer} : '-') . "\n";
        if    (defined($f->{status}) && $f->{status} eq 'unanswered') { $un++ }
        elsif (defined($f->{status}) && $f->{status} eq 'answered')   { $an++ }
    }
    print "unanswered: $un\n";
    print "answered: $an\n";
    print "total: " . scalar(@$list) . "\n";
}

sub _print_list_json {
    my ($list) = @_;
    my @out;
    for my $rec (@$list) {
        my $f = $rec->{fields};
        push @out, {
            id          => $rec->{id},
            status      => $f->{status},
            title       => $f->{title},
            created     => $f->{created},
            answer      => (exists $f->{answer}      ? $f->{answer}      : undef),
            answered_at => (exists $f->{answered_at} ? $f->{answered_at} : undef),
        };
    }
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

# ---------------------------------------------------------------------------
# CLI verbs.
# ---------------------------------------------------------------------------
sub _cmd_file {
    my ($o, $bool_default) = @_;
    my $title_missing = !exists($o->{title}) || $bool_default->{title};
    _usage('missing_title') if $title_missing;

    my %opt;
    $opt{root}  = $o->{root} if exists $o->{root};
    $opt{title} = $o->{title};
    $opt{body}  = $o->{body} if exists $o->{body};
    $opt{id}    = $o->{id}   if exists $o->{id};

    my $rec = file(%opt);
    _print_result($rec, status => 'unanswered', changed => 'yes');
}

sub _cmd_list {
    my ($o) = @_;
    my $list = list_decisions(root => $o->{root});
    if ($o->{json}) { _print_list_json($list) }
    else            { _print_list_default($list) }
}

sub _cmd_show {
    my ($o, $id) = @_;
    my $rec = read_decision($id, root => $o->{root});
    if ($o->{json}) { _print_show_json($rec) }
    else            { _print_show_default($rec) }
}

sub _cmd_answer {
    my ($o, $bool_default, $id) = @_;
    my $answer_missing = !exists($o->{answer}) || $bool_default->{answer};
    _usage('missing_answer') if $answer_missing;

    my %opt = (root => $o->{root}, answer => $o->{answer});
    $opt{expect_rev} = $o->{'expect-rev'} if exists $o->{'expect-rev'};

    my ($rec, $changed) = answer($id, %opt);
    _print_result($rec, status => $rec->{fields}{status}, changed => ($changed ? 'yes' : 'no'));

    my $report = blocked_tasks($id, root => $o->{root});
    _print_traversal($report);
}

sub _cmd_blocks {
    my ($o, $id) = @_;
    read_decision($id, root => $o->{root});   # existence check (not_found on a miss)

    my $report = blocked_tasks($id, root => $o->{root});
    if ($o->{json}) { _print_traversal_json($report) }
    else            { _print_traversal($report) }
}

# ---------------------------------------------------------------------------
# CLI entry point.
# ---------------------------------------------------------------------------
unless (caller) {
    binmode(STDOUT, ':encoding(UTF-8)');

    # Argv grammar: one pass over the WHOLE of @ARGV, same as almanac-
    # task.pl -- the verb is simply the first positional token once parsing
    # is done.
    my (%o, %bool_default, @pos);
    while (@ARGV) {
        my $a = shift @ARGV;
        if ($a =~ /^--([a-z0-9-]+)$/) {
            my $key = $1;
            my $has_val = (@ARGV && $ARGV[0] !~ /^--/);
            my $val = $has_val ? shift @ARGV : 1;
            $o{$key} = $val;
            if ($has_val) { delete $bool_default{$key} }
            else          { $bool_default{$key} = 1 }
        } else {
            push @pos, $a;
        }
    }
    my $cmd = shift @pos;

    my $ok = eval {
        _usage('missing_verb') unless defined $cmd && length $cmd;

        my %VERBS = map { $_ => 1 } qw(file list show answer blocks);
        _usage('unknown_verb') unless $VERBS{$cmd};

        my %ALLOWED_FLAGS = (
            'file'   => [qw(title body id root)],
            'list'   => [qw(json root)],
            'show'   => [qw(json root)],
            'answer' => [qw(answer expect-rev root)],
            'blocks' => [qw(json root)],
        );
        my %allowed = map { $_ => 1 } @{ $ALLOWED_FLAGS{$cmd} };
        for my $k (keys %o) {
            _usage('unknown_flag') unless $allowed{$k};
        }

        # Value-taking flags fail OPEN on a missing value (bare flag) --
        # `title`, `answer` and the boolean `json` are deliberately excluded
        # (bespoke / genuine booleans, same rule as almanac-task.pl).
        for my $k (qw(root body id expect-rev)) {
            _usage('missing_flag_value') if $bool_default{$k};
        }

        if ($cmd eq 'file') {
            _usage('extra_positional') if @pos;
            _cmd_file(\%o, \%bool_default);
        }
        elsif ($cmd eq 'list') {
            _usage('extra_positional') if @pos;
            _cmd_list(\%o);
        }
        elsif ($cmd eq 'show') {
            my $id = shift @pos;
            _usage('missing_id') unless defined $id && length $id;
            _usage('extra_positional') if @pos;
            _cmd_show(\%o, $id);
        }
        elsif ($cmd eq 'answer') {
            my $id = shift @pos;
            _usage('missing_id') unless defined $id && length $id;
            _usage('extra_positional') if @pos;
            _cmd_answer(\%o, \%bool_default, $id);
        }
        elsif ($cmd eq 'blocks') {
            my $id = shift @pos;
            _usage('missing_id') unless defined $id && length $id;
            _usage('extra_positional') if @pos;
            _cmd_blocks(\%o, $id);
        }
        1;
    };
    unless ($ok) {
        Almanac::Record::fatal($@);
    }
    exit 0;
}

1;
