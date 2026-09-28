# BpHook::Guards::Shell -- the shell-noise stripper, ported in-process from
# plugins/butler/scripts/bp-lib.sh's bp_strip_shell_noise (package 14 of
# blueprint hook-continuity-remake).
#
# Contract: .ccpraxis-local-data/blueprints/hook-continuity-remake/specs/
# 14-guards-remake-spec.md sec 2.4. Output is byte-for-byte identical, for
# every input, to piping the same string through bp-lib.sh's
# bp_strip_shell_noise (a `perl -0777 -ne '...'` one-liner) -- this module
# runs the SAME algorithm directly on a Perl string instead of forking a
# process to do it (Decision 33: no module here spawns).
#
# Never calls exit, never spawns a process, never dies on purpose.
package BpHook::Guards::Shell;
use strict;
use warnings;

# ---------------------------------------------------------------------------
# strip_noise($cmd) -> string. Empty input returns ''.
# ---------------------------------------------------------------------------
sub strip_noise {
    my ($cmd) = @_;
    return '' unless defined $cmd && length $cmd;

    my @c = split //, $cmd, -1;
    my $n = scalar @c;
    my $filtered = '';
    my $state = 'none'; # none | squote | dquote | comment | heredoc
    my ($hd, $hd_tabs, $hd_pending, $line) = ('', 0, 0, '');
    my $i = 0;

    while ($i < $n) {
        my $ch = $c[$i];

        if ($state eq 'heredoc') {
            if ($ch eq "\n") {
                my $chk = $line;
                $chk =~ s/^\t+// if $hd_tabs;
                $state = 'none' if $chk eq $hd;
                $filtered .= (' ' x length($line)) . "\n";
                $line = '';
            }
            else {
                $line .= $ch;
            }
            $i++;
            next;
        }
        if ($state eq 'comment') {
            $filtered .= ($ch eq "\n" ? "\n" : ' ');
            $state = 'none' if $ch eq "\n";
            $i++;
            next;
        }
        if ($state eq 'squote') {
            $state = 'none' if $ch eq "\x27";
            $filtered .= ($ch eq "\n" ? "\n" : ' ');
            $i++;
            next;
        }
        if ($state eq 'dquote') {
            if ($ch eq "\\" && $i + 1 < $n) {
                $filtered .= '  ';
                $i += 2;
                next;
            }
            if ($ch eq "\$" && $i + 1 < $n && $c[$i + 1] eq '(') {
                my $depth = 1;
                my $j = $i + 2;
                my $buf = "\$(";
                while ($j < $n && $depth > 0) {
                    my $cj = $c[$j];
                    $depth++ if $cj eq '(';
                    $depth-- if $cj eq ')';
                    $buf .= $cj;
                    $j++;
                }
                $filtered .= $buf;
                $i = $j;
                next;
            }
            if ($ch eq "\x60") {
                my $j = $i + 1;
                my $buf = "\x60";
                while ($j < $n && $c[$j] ne "\x60") { $buf .= $c[$j]; $j++ }
                if ($j < $n) { $buf .= $c[$j]; $j++ }
                $filtered .= $buf;
                $i = $j;
                next;
            }
            $state = 'none' if $ch eq q{"};
            $filtered .= ($ch eq "\n" ? "\n" : ' ');
            $i++;
            next;
        }

        if ($hd_pending && $ch eq "\n") {
            $filtered .= "\n";
            $i++;
            $state = 'heredoc';
            $hd_pending = 0;
            $line = '';
            next;
        }
        if ($ch eq "\x27") { $state = 'squote'; $filtered .= ' '; $i++; next }
        if ($ch eq q{"})   { $state = 'dquote'; $filtered .= ' '; $i++; next }
        if ($ch eq "\\" && $i + 1 < $n) { $filtered .= '  '; $i += 2; next }
        if ($ch eq '#') {
            my $p = $filtered;
            $p =~ s/[ \t]+$//;
            my $last = length($p) ? substr($p, -1) : '';
            if ($last eq '' || $last =~ /[;&|(\n]/) {
                $state = 'comment';
                $filtered .= ' ';
                $i++;
                next;
            }
            $filtered .= '#';
            $i++;
            next;
        }
        if ($ch eq '<' && $i + 1 < $n && $c[$i + 1] eq '<') {
            my $j = $i + 2;
            my $tabs = 0;
            if ($j < $n && $c[$j] eq '-') { $tabs = 1; $j++ }
            $j++ while ($j < $n && $c[$j] =~ /[ \t]/);
            my $q = '';
            if ($j < $n && ($c[$j] eq "\x27" || $c[$j] eq q{"})) { $q = $c[$j]; $j++ }
            my $delim = '';
            $delim .= $c[$j++] while ($j < $n && $c[$j] =~ /[A-Za-z0-9_]/);
            $j++ if (length($q) && $j < $n && $c[$j] eq $q);
            if (length($delim)) {
                $filtered .= (' ' x ($j - $i));
                $i = $j;
                $hd = $delim;
                $hd_tabs = $tabs;
                $hd_pending = 1;
                next;
            }
        }
        $filtered .= $ch;
        $i++;
    }

    return $filtered;
}

1;
