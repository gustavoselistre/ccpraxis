#!/usr/bin/env perl
# bp-session.pl — the session-identity CLI. A thin shell over BpSession.pm; all
# of the reasoning lives there, and nothing here should grow logic of its own.
#
# Subcommands:
#   nonce                          print a fresh nonce (plant it in a transcript
#                                  by letting it reach stdout of a tool call)
#   whoami --nonce N               the session id that printed N, or exit 3
#   claim --session S [--dir D]    bind any pending continuity ticket whose
#                                  nonce resolves to S; prints one BOUND: line
#                                  per ticket bound
#
# `claim` is what closes the loop. A Bash tool call cannot learn which session
# Claude Code considers live, but a HOOK is handed it, so arming writes a ticket
# and the Stop hook binds it to the session whose transcript actually carries
# the ticket's nonce. Both halves must agree -- the transcript record says which
# session printed it, the hook payload says which session is stopping -- so a
# ticket can only ever bind to the one session that is both.
use strict;
use warnings;
use File::Path qw(make_path);
use File::Basename qw(dirname);
use File::Spec;

my $SCRIPT_DIR = dirname(File::Spec->rel2abs(__FILE__));
require "$SCRIPT_DIR/BpSession.pm";

my $cmd = shift @ARGV // '';

if    ($cmd eq 'nonce')  { cmd_nonce()  }
elsif ($cmd eq 'whoami') { cmd_whoami() }
elsif ($cmd eq 'claim')  { cmd_claim()  }
else {
    print "STATUS: error\n";
    print "ERROR: unknown command '$cmd' (usage: nonce|whoami|claim)\n";
    exit 1;
}

sub cmd_nonce {
    my $n = BpSession::new_nonce();
    print "NONCE: $n\n";
    exit 0;
}

sub cmd_whoami {
    my $opts = parse_args(qw(nonce));
    my $n = $opts->{nonce};
    unless (defined $n && length $n) {
        print "STATUS: error\nERROR: --nonce required\n";
        exit 1;
    }
    my $sid = BpSession::session_for_nonce($n);
    unless (defined $sid) {
        # Exit 3, not 1: "not resolved yet" is an ordinary, expected state --
        # the nonce was planted in this same turn and the transcript record for
        # it does not exist until the tool call returns. A caller polling for it
        # needs to tell that apart from a malformed request.
        print "STATUS: unresolved\n";
        print "NONCE: $n\n";
        exit 3;
    }
    print "STATUS: resolved\n";
    print "SESSION: $sid\n";
    print "ROUTE: " . (BpSession::resolution_route($n) // 'unknown') . "\n";
    exit 0;
}

# claim --session S : bind pending tickets belonging to S.
#
# A ticket binds only when the transcript record carrying its nonce names the
# SAME session the caller says is live. That double condition is what makes this
# safe with any number of concurrent sessions sharing one registry: a session
# cannot claim a ticket it did not print, and a ticket cannot be bound to a
# session that is not stopping.
sub cmd_claim {
    my $opts = parse_args(qw(session dir));
    my $sid = $opts->{session};
    unless (defined $sid && length $sid) {
        print "STATUS: error\nERROR: --session required\n";
        exit 1;
    }
    if ($sid =~ m{[/\\*.\x00]}) {
        print "STATUS: error\nERROR: invalid session id: $sid\n";
        exit 1;
    }

    my $dir = $opts->{dir};
    $dir = continuity_dir() unless defined $dir && length $dir;
    unless (defined $dir) {
        print "STATUS: error\nERROR: cannot resolve the continuity registry\n";
        exit 1;
    }
    my $pending = "$dir/pending";
    unless (-d $pending) {
        print "STATUS: nothing_pending\n";
        exit 0;
    }

    opendir(my $dh, $pending) or do {
        print "STATUS: nothing_pending\n";
        exit 0;
    };
    my @tickets = sort grep { !/^\.\.?$/ } readdir $dh;
    closedir $dh;

    my $ttl = $ENV{CCPRAXIS_CONTINUITY_TICKET_TTL_S};
    $ttl = 3600 unless defined $ttl && $ttl =~ /^\d+$/ && $ttl > 0;

    my $bound = 0;
    for my $nonce (@tickets) {
        my $tpath = "$pending/$nonce";
        next unless -f $tpath;

        # Expire first, so an unclaimable ticket cannot accumulate. A ticket
        # whose session never reached a Stop is indistinguishable from one
        # printed by a session that has since died.
        my $mtime = (stat $tpath)[9];
        if (defined $mtime && (time() - $mtime) > $ttl) {
            unlink $tpath;
            print "EXPIRED: $nonce\n";
            next;
        }

        next unless BpSession::valid_nonce($nonce);
        my $owner = BpSession::session_for_nonce($nonce);
        next unless defined $owner && $owner eq $sid;

        # Same line format bp-continuity.pl's arm writes, because status and the
        # statusline badge read these markers and must not learn a second shape.
        open my $in, '<', $tpath or next;
        my $line = <$in>;
        close $in;
        chomp($line //= 'operator unknown');

        make_path($dir) unless -d $dir;
        my $mark = "$dir/$sid";
        open my $out, '>', $mark or next;
        print {$out} "$line\n";
        close $out;
        my $now = time();
        utime($now, $now, $mark);

        unlink $tpath;
        print "BOUND: $sid\n";
        print "NONCE: $nonce\n";
        $bound++;
    }

    print "STATUS: " . ($bound ? 'bound' : 'nothing_bound') . "\n";
    exit 0;
}

# The registry directory, resolved by the SAME rule as lib.sh's
# bp_continuity_active_dir and bp-continuity.pl's own copy: override, else HOME,
# else USERPROFILE, else unresolvable -- and ABSOLUTE, which the perl copies
# used to skip while bash enforced it. Four legs share this rule: lib.sh, this
# file, bp-continuity.pl and scripts/statusline.pl.
# ABSOLUTE, OR UNRESOLVED. lib.sh's bp_is_absolute_path is the rule of record:
# a value beginning '/' or a Windows drive letter, and nothing else. The perl
# copies used to accept ANY non-empty string, so bash and perl disagreed about
# the same environment -- a relative CCPRAXIS_CONTINUITY_ACTIVE_DIR let `arm`
# write a marker under the caller's cwd and report success while the gate,
# which rejects it, enforced nothing. That is precisely the "armed, enforcing
# nothing" failure this subsystem exists to remove, reached through the parity
# these copies are supposed to guarantee.
sub _bp_is_absolute_path {
    my ($v) = @_;
    return 0 unless defined $v && length $v;
    return 1 if $v =~ m{^/};
    return 0 unless $v =~ m{^[A-Za-z]:};
    # The drive-letter form may be bare ("C:"), slashed, or backslashed. The
    # backslash is matched via chr(92) rather than written into a character
    # class: this repo edits perl through shell heredocs, which collapse a
    # doubled backslash and silently produce an unterminated class.
    my $rest = substr($v, 2);
    return 1 if $rest eq q{} || $rest =~ m{^/} || substr($rest, 0, 1) eq chr(92);
    return 0;
}

sub continuity_dir {
    my $override = $ENV{CCPRAXIS_CONTINUITY_ACTIVE_DIR};
    return $override if _bp_is_absolute_path($override);
    return undef if defined $override && length $override;   # set but relative
    for my $home ($ENV{HOME}, $ENV{USERPROFILE}) {
        next unless _bp_is_absolute_path($home);
        return "$home/.claude/ccpraxis/.continuity-active";
    }
    return undef;
}

sub parse_args {
    my %known = map { $_ => 1 } @_;
    my %opts;
    while (defined(my $arg = shift @ARGV)) {
        unless ($arg =~ /^--([\w-]+)$/ && $known{$1}) {
            print "STATUS: error\nERROR: unknown or unexpected argument: $arg\n";
            exit 1;
        }
        my $key = $1;
        my $val = shift @ARGV;
        unless (defined $val) {
            print "STATUS: error\nERROR: --$key requires a value\n";
            exit 1;
        }
        $opts{$key} = $val;
    }
    return \%opts;
}
