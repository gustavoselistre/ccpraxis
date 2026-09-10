#!/usr/bin/env perl
# bp-resumption.pl — "will anything actually bring this session back?", for
# callers that are not perl. A thin shell over BpResumption.pm; the reasoning
# lives there and nothing here should grow logic of its own.
#
# Exists because gate-continuity.sh is bash and the answer needs a process
# fingerprint, which bash cannot compute. Translating the rules into shell a
# second time is exactly the duplication BpResumption.pm was extracted to end.
#
#   verify --file PATH [--ttl N]   exit 0 if the marker promises a real return
#                                  exit 1 otherwise, printing REASON: ...
#                                  exit 2 if the file cannot be read
use strict;
use warnings;
use File::Basename qw(dirname);
use File::Spec;

my $SCRIPT_DIR = dirname(File::Spec->rel2abs(__FILE__));
require "$SCRIPT_DIR/BpResumption.pm";

my $cmd = shift @ARGV // '';
if ($cmd ne 'verify') {
    print "REASON: unknown command '$cmd' (usage: verify --file PATH [--ttl N])\n";
    exit 2;
}

my %opt;
while (defined(my $arg = shift @ARGV)) {
    unless ($arg =~ /^--(file|ttl)$/) {
        print "REASON: unexpected argument: $arg\n";
        exit 2;
    }
    my $key = $1;
    my $val = shift @ARGV;
    unless (defined $val) {
        print "REASON: --$key requires a value\n";
        exit 2;
    }
    $opt{$key} = $val;
}

unless (defined $opt{file} && length $opt{file}) {
    print "REASON: --file required\n";
    exit 2;
}

open my $fh, '<', $opt{file} or do {
    print "REASON: cannot read $opt{file}\n";
    exit 2;
};
my $line = <$fh>;
close $fh;

my %vopt;
$vopt{ttl} = $opt{ttl} if defined $opt{ttl} && $opt{ttl} =~ /^\d+$/;

my ($ok, $reason) = BpResumption::verify_line($line, %vopt);
if ($ok) {
    print "REASON: ok\n";
    exit 0;
}
print "REASON: " . ($reason // 'refused') . "\n";
exit 1;
