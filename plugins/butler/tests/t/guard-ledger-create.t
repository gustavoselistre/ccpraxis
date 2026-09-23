#!/usr/bin/env perl
# platform: any
# guard-ledger-create.t -- oracle for plugins/butler/hooks/guard-ledger-create.sh
# (04-model-effort-ledger-validation).
#
# Derived ONLY from
# .ccpraxis-local-data/blueprints/coordinator-context-discipline/specs/04-model-effort-ledger-validation-spec.md
# section 2.2/2.3/2.5/3 (B-21..B-40, AC-10..AC-16). WRITTEN BLIND TO ANY IMPLEMENTATION: the guard
# file does not exist at authoring time, so every assertion below is expected to fail because the
# hook script is ABSENT, never because of a bug in this file.
#
# Harness mirrors plugins/butler/tests/t/blueprint-write-api.t's run_hook and
# plugins/butler/tests/t/subagent-stall-guard.t's CLAUDE_PROJECT_DIR-scoped fire(): every call gets
# its own throwaway root, so the override file / bug-reports directory / target ledger never touch
# the real repo tree. No BP_* variable is ever exported (proves the guard is ungated, per B-21..B-40's
# own preamble).
use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use File::Temp qw(tempdir);
use Cwd qw(abs_path);
use JSON::PP;
use POSIX qw(WIFEXITED WEXITSTATUS);

sub fwd { (my $p = shift) =~ s{\\}{/}g; $p }

my $TESTS  = fwd("$Bin");
my $BUTLER = fwd(abs_path("$Bin/../..")       // "$Bin/../..");
my $PROJ   = fwd(abs_path("$Bin/../../../..") // "$Bin/../../../..");
my $GUARD  = "$BUTLER/hooks/guard-ledger-create.sh";

diag("subject under test: $GUARD " . (-e $GUARD ? "(present)" : "(ABSENT -- every assertion below is expected to fail on a MISSING FILE)"));

my $J = JSON::PP->new->canonical;

my %CLEAN_ENV = map { ($_ => $ENV{$_}) } grep { !/^BP_/ } keys %ENV;

# Resolved ONCE via the unrestricted PATH, always invoked absolutely -- mirrors
# context-ceiling-flush.t's $BASH_ABS. A `path_without_any('perl','jq')`-shaped PATH
# (B-39) can strip the same /usr/bin that hosts bash itself; passing the hook as an
# ARGUMENT to this absolute interpreter sidesteps the OS's own exec/PATH lookup, while
# the hook process still sees the caller's (possibly stripped) %ENV for its own
# internal `command -v jq`/`command -v perl` checks.
my $BASH_ABS = do {
    local $ENV{PATH} = $CLEAN_ENV{PATH};
    chomp(my $p = `command -v bash 2>/dev/null`);
    ($p && -x $p) ? $p : 'bash';
};

sub write_file {
    my ($path, $bytes) = @_;
    open my $w, '>', $path or die "write $path: $!";
    binmode $w;
    print $w $bytes;
    close $w or die "close $path: $!";
    return $path;
}

sub read_file {
    my ($path) = @_;
    open my $r, '<', $path or return undef;
    binmode $r;
    my $c = do { local $/; <$r> };
    close $r;
    return defined $c ? $c : '';
}

my $rn = 0;
sub newroot {
    my $r = tempdir(CLEANUP => 1);
    mkdir "$r/.ccpraxis-local-data";
    mkdir "$r/.ccpraxis-local-data/.subagent-guard";
    mkdir "$r/.ccpraxis-local-data/bug-reports";
    mkdir "$r/.ccpraxis-local-data/blueprints";
    return fwd($r);
}

sub override_path { my ($root) = @_; return "$root/.ccpraxis-local-data/.subagent-guard/ledger-write-override" }
sub bug_report_path { my ($root, $id) = @_; return "$root/.ccpraxis-local-data/bug-reports/$id.md" }
sub ledger_path { my ($root, $bp, $pkg) = @_; $bp //= 'demo-bp'; $pkg //= '01-a'; return "$root/.ccpraxis-local-data/blueprints/$bp/packages/$pkg.md" }

# run_hook(ROOT, PAYLOAD_HASHREF, %extra_env) -> (rc, stdout, stderr)
my $pn = 0;
sub run_hook {
    my ($root, $payload, %extra) = @_;
    my $n = ++$pn;
    my $pf   = write_file("$root/.payload.$n.json", $J->encode($payload));
    my $outf = write_file("$root/.hout.$n", '');
    my $errf = write_file("$root/.herr.$n", '');
    local %ENV = (%CLEAN_ENV, %extra, CLAUDE_PROJECT_DIR => $root);
    my $exit = -1;
    eval {
        local $SIG{ALRM} = sub { die "alarm\n" };
        alarm 30;
        open(local *CHSTDIN,  '<', $pf)    or die "open $pf: $!";
        open(local *CHSTDOUT, '>', $outf)  or die "open $outf: $!";
        open(local *CHSTDERR, '>', $errf)  or die "open $errf: $!";
        my $pid = fork();
        die "fork: $!" unless defined $pid;
        if ($pid == 0) {
            open(STDIN,  '<&', \*CHSTDIN)  or exit 126;
            open(STDOUT, '>&', \*CHSTDOUT) or exit 126;
            open(STDERR, '>&', \*CHSTDERR) or exit 126;
            exec($BASH_ABS, $GUARD) or exit 127;
        }
        waitpid($pid, 0);
        $exit = ($? == -1) ? -1 : WIFEXITED($?) ? WEXITSTATUS($?) : -1;
        alarm 0;
        1;
    } or do { alarm 0; $exit = -1; };
    return ($exit, read_file($outf) // '', read_file($errf) // '');
}

sub payload {
    my (%o) = @_;
    my %ti;
    $ti{file_path} = $o{path} if defined $o{path} && !$o{notebook};
    $ti{notebook_path} = $o{path} if defined $o{path} && $o{notebook};
    return {
        hook_event_name => 'PreToolUse',
        tool_name => $o{tool} // 'Write',
        cwd => $o{cwd},
        tool_input => \%ti,
    };
}

sub path_without_any {
    my (@names) = @_;
    my @keep;
    for my $dir (split /:/, ($CLEAN_ENV{PATH} // '')) {
        next unless length $dir;
        next if grep { -x "$dir/$_" || -x "$dir/$_.exe" } @names;
        push @keep, $dir;
    }
    return join ':', @keep;
}

# =====================================================================================
# AC-11 (B-21, B-22): inert on Bash and read-only tools.
# =====================================================================================
{
    my $r = newroot();
    my $lp = ledger_path($r);
    my ($rc, $out, $err) = run_hook($r,
        payload(tool => 'Bash', cwd => $r, path => undef),
        # can't set file_path on Bash naturally; simulate via tool_input.command instead
    );
    # Build a Bash payload whose command string names a ledger path, per B-21.
    my $bash_payload = { hook_event_name => 'PreToolUse', tool_name => 'Bash', cwd => $r,
                          tool_input => { command => "cat $lp" } };
    ($rc, $out, $err) = run_hook($r, $bash_payload);
    is($rc, 0, "AC-11/B-21: tool_name Bash exits 0 even when the command string names a ledger path");
    is($out . $err, '', "AC-11/B-21: Bash produces no output");
}
for my $tool (qw(Read Grep Glob)) {
    my $r = newroot();
    my ($rc, $out, $err) = run_hook($r, payload(tool => $tool, cwd => $r, path => ledger_path($r)));
    is($rc, 0, "AC-11/B-22: tool_name $tool exits 0");
}

# =====================================================================================
# AC-10 (B-23, B-24, B-29): denies Write/Edit/MultiEdit/NotebookEdit to a not-yet-existing
# ledger path.
# =====================================================================================
for my $tool (qw(Write Edit MultiEdit)) {
    my $r = newroot();
    my $lp = ledger_path($r);
    ok(!-e $lp, "AC-10: target does not exist yet (tool=$tool)");
    my ($rc, $out, $err) = run_hook($r, payload(tool => $tool, cwd => $r, path => $lp));
    is($rc, 2, "AC-10/B-23/B-24: $tool to a not-yet-existing ledger path exits 2");
    is($out, '', "AC-10/B-23/B-24: nothing on stdout ($tool)");
    like($err, qr/\Qbp-ledger.pl create\E/, "AC-10/B-23/B-24: denial names the bp-ledger.pl create remedy ($tool)");
}
{
    my $r = newroot();
    my $lp = ledger_path($r);
    my ($rc, $out, $err) = run_hook($r, payload(tool => 'NotebookEdit', cwd => $r, path => $lp, notebook => 1));
    is($rc, 2, "AC-10/B-24: NotebookEdit via notebook_path to a not-yet-existing ledger path exits 2");
    like($err, qr/\Qbp-ledger.pl create\E/, "AC-10/B-24: denial names the remedy (NotebookEdit)");
}

# =====================================================================================
# AC-11 (B-25, B-26, B-27): existing ledgers are still denied; non-blueprint packages/
# and the template path are exempt.
# =====================================================================================
{
    my $r = newroot();
    my $lp = ledger_path($r);
    mkdir "$r/.ccpraxis-local-data/blueprints/demo-bp";
    mkdir "$r/.ccpraxis-local-data/blueprints/demo-bp/packages";
    write_file($lp, "---\npackage: 01-a\n---\nexisting\n");
    my ($rc, $out, $err) = run_hook($r, payload(tool => 'Write', cwd => $r, path => $lp));
    is($rc, 2, "AC-11/B-25: an EXISTING ledger is also denied");
}
{
    my $r = newroot();
    mkdir "$r/notes";
    mkdir "$r/notes/packages";
    my $p = "$r/notes/packages/readme.md";
    my ($rc) = run_hook($r, payload(tool => 'Write', cwd => $r, path => $p));
    is($rc, 0, "AC-11/B-26: a packages/ dir NOT under blueprints/ is exempt");
}
{
    my $r = newroot();
    mkdir "$r/plugins"; mkdir "$r/plugins/blueprint"; mkdir "$r/plugins/blueprint/templates";
    my $p = "$r/plugins/blueprint/templates/package-ledger.md";
    my ($rc) = run_hook($r, payload(tool => 'Write', cwd => $r, path => $p));
    is($rc, 0, "AC-11/B-27: the template itself is exempt");
}

# =====================================================================================
# AC-12 (B-28): path resolution for POSIX-absolute, C:/, C:\ and relative-to-cwd; no
# doubled path in the denial.
# =====================================================================================
{
    my $r = newroot();
    my $lp = ledger_path($r);
    my ($rc, $out, $err) = run_hook($r, payload(tool => 'Write', cwd => $r, path => $lp));
    is($rc, 2, "AC-12/B-28: POSIX-absolute file_path denies");
    my $count = () = $err =~ /\Q$lp\E/g;
    is($count, 1, "AC-12/B-28: the absolute path appears exactly once (POSIX-absolute input)");
}
{
    my $r = newroot();
    my $lp = ledger_path($r);
    (my $winpath = $lp) =~ s{^([A-Za-z]):?/?}{C:/}; # best-effort Windows-shaped stand-in
    # Build a path guaranteed to be recognised as C:/... shaped regardless of host.
    my $drivepath = "C:/fake-root/.ccpraxis-local-data/blueprints/demo-bp/packages/01-a.md";
    my ($rc, $out, $err) = run_hook($r, payload(tool => 'Write', cwd => $r, path => $drivepath));
    is($rc, 2, "AC-12/B-28: a C:/... drive-letter path denies");
    my $count = () = $err =~ /\QC:\/fake-root\E/g;
    ok($count <= 1, "AC-12/B-28: the C:/ path is never doubled in the denial");
}
{
    my $r = newroot();
    my $drivepath = 'C:\\fake-root\\.ccpraxis-local-data\\blueprints\\demo-bp\\packages\\01-a.md';
    my ($rc, $out, $err) = run_hook($r, payload(tool => 'Write', cwd => $r, path => $drivepath));
    is($rc, 2, "AC-12/B-28: a C:\\... drive-letter path denies");
}
{
    my $r = newroot();
    my $lp = ledger_path($r);
    my $rel = '.ccpraxis-local-data/blueprints/demo-bp/packages/01-a.md';
    my ($rc, $out, $err) = run_hook($r, payload(tool => 'Write', cwd => $r, path => $rel));
    is($rc, 2, "AC-12/B-28: a relative path resolved against cwd denies");
    my $count = () = $err =~ /\Q$lp\E/g;
    is($count, 1, "AC-12/B-28: the resolved relative path appears exactly once, not doubled");
}

# =====================================================================================
# AC-12 (B-39): fails closed with no JSON parser at all.
# =====================================================================================
{
    my $r = newroot();
    my $lp = ledger_path($r);
    my ($rc, $out, $err) = run_hook($r, payload(tool => 'Write', cwd => $r, path => $lp),
                                     PATH => path_without_any('perl', 'jq'));
    is($rc, 2, "AC-12/B-39: with no JSON parser on PATH, the guard fails closed (exit 2)");
    like($err, qr/no JSON parser available/, "AC-12/B-39: ...with the no-parser message");
}

# =====================================================================================
# AC-12 (B-40): the guard never calls bp_hook_gate.
# =====================================================================================
SKIP: {
    skip('B-40: guard-ledger-create.sh not present yet', 1) unless -e $GUARD;
    my $src = read_file($GUARD);
    unlike($src, qr/\bbp_hook_gate\b/, "AC-12/B-40: guard-ledger-create.sh contains no call to bp_hook_gate");
}

# =====================================================================================
# AC-16 (B-29): all nine §2.5 literals, with the ordering constraint on two of them.
# =====================================================================================
{
    my $r = newroot();
    my $lp = ledger_path($r);
    my (undef, undef, $err) = run_hook($r, payload(tool => 'Write', cwd => $r, path => $lp));
    like($err, qr/LEDGER-CREATE-GUARD: BLOCKED/, "AC-16: literal 1 -- LEDGER-CREATE-GUARD: BLOCKED");
    like($err, qr/\Q$lp\E/, "AC-16: literal 2 -- the absolute target path");
    like($err, qr/\bWrite\b/, "AC-16: literal 3 -- the tool name");
    like($err, qr/\Qbp-ledger.pl create\E/, "AC-16: literal 4 -- bp-ledger.pl create");
    like($err, qr{\Q.ccpraxis-local-data/.subagent-guard/ledger-write-override\E},
         "AC-16: literal 5 -- the override path");
    like($err, qr/\QThis escape hatch is for a genuine ccpraxis tooling defect ONLY.\E/,
         "AC-16: literal 6 -- the ONLY-clause sentence");
    like($err, qr/\Qalmanac-bug.pl file --title "..." --body -\E/,
         "AC-16: literal 7 -- the almanac-bug.pl invocation");
    like($err, qr/\bone-shot\b/, "AC-16: literal 8 -- one-shot");
    like($err, qr/verified against the report on disk/, "AC-16: literal 9 -- verified against the report on disk");

    # Ordering: the ONLY-clause sentence sits on its own line, and the almanac-bug.pl
    # invocation is the next NON-BLANK line after it.
    my @lines = split /\n/, $err;
    my ($only_i) = grep { $lines[$_] =~ /This escape hatch is for a genuine ccpraxis tooling defect ONLY\./ } 0 .. $#lines;
  SKIP: {
        ok(defined $only_i, "AC-16: the ONLY-clause sentence is present as a whole line")
            or skip('ordering unverifiable -- ONLY-clause sentence not found', 1);
        my $next_nonblank;
        for my $i ($only_i + 1 .. $#lines) {
            next unless length($lines[$i] // '') && $lines[$i] !~ /^\s*$/;
            $next_nonblank = $lines[$i];
            last;
        }
        like($next_nonblank // '', qr/almanac-bug\.pl file/,
             "AC-16: the next non-blank line after the ONLY-clause is the almanac-bug.pl invocation");
    }
}

# =====================================================================================
# AC-13/AC-14/AC-15 (D-G escape hatch, B-30..B-38).
# =====================================================================================

# AC-13 (B-30, B-31, B-35): a valid override (real on-disk report id) allows the write,
# is consumed, and the immediately-repeated write is denied again.
{
    my $r = newroot();
    my $lp = ledger_path($r);
    my $id = '20260101-120000-abcd';
    write_file(bug_report_path($r, $id), "# a real report\n");
    write_file(override_path($r), "$id\n");
    my ($rc, $out, $err) = run_hook($r, payload(tool => 'Write', cwd => $r, path => $lp));
    is($rc, 0, "AC-13/B-30: a valid override (real report id) allows the write");
    is($out . $err, '', "AC-13/B-30: nothing printed on the allowed path");
    ok(!-e override_path($r), "AC-13/B-30: the override file no longer exists (consumed)");

    my ($rc2, $out2, $err2) = run_hook($r, payload(tool => 'Write', cwd => $r, path => $lp));
    is($rc2, 2, "AC-13/B-31: the immediately-repeated identical write is denied again");
    like($err2, qr/LEDGER-CREATE-GUARD: BLOCKED/, "AC-13/B-31: ...with the full denial");
}
{
    # B-35: trailing whitespace / newline / CR, and extra lines after the first, still verify.
    for my $shape ('trailing space', 'trailing newline', 'trailing CR', 'extra lines') {
        my $r = newroot();
        my $lp = ledger_path($r);
        my $id = '20260102-130000-beef';
        write_file(bug_report_path($r, $id), "# report\n");
        my $content =
            $shape eq 'trailing space'   ? "$id   "
          : $shape eq 'trailing newline' ? "$id\n"
          : $shape eq 'trailing CR'      ? "$id\r\n"
          :                                 "$id\nsome other line\nand another\n";
        write_file(override_path($r), $content);
        my ($rc) = run_hook($r, payload(tool => 'Write', cwd => $r, path => $lp));
        is($rc, 0, "AC-13/B-35: override with $shape still verifies and allows");
    }
}

# AC-14 (B-32, B-33, B-34): a failed verification denies AND leaves the override file in
# place, unchanged.
{
    my @cases = (
        [ 'fabricated well-formed id', '20260101-000000-dead' ],
        [ 'empty file',                '' ],
        [ 'whitespace only',           "   \n" ],
        [ 'non-id string',             'not-an-id' ],
        [ 'traversal string',          '../../../etc/passwd' ],
    );
    for my $c (@cases) {
        my ($label, $content) = @$c;
        my $r = newroot();
        my $lp = ledger_path($r);
        write_file(override_path($r), $content);
        my ($rc, $out, $err) = run_hook($r, payload(tool => 'Write', cwd => $r, path => $lp));
        is($rc, 2, "AC-14/B-32/B-33: override with $label denies (exit 2)");
        ok(-e override_path($r), "AC-14/B-32/B-33: override file still exists after $label");
        is(read_file(override_path($r)), $content, "AC-14/B-32/B-33: override content is unchanged after $label");
    }
}
{
    # B-34: the id resolves to a DIRECTORY, not a regular file.
    my $r = newroot();
    my $lp = ledger_path($r);
    my $id = '20260103-140000-cafe';
    mkdir bug_report_path($r, $id); # a DIRECTORY at the report path, not a file
    write_file(override_path($r), "$id\n");
    my ($rc) = run_hook($r, payload(tool => 'Write', cwd => $r, path => $lp));
    is($rc, 2, "AC-14/B-34: a directory at the report path denies");
    ok(-e override_path($r), "AC-14/B-34: override survives a directory-shaped report path");
}

# AC-15 (B-36, B-37, B-38): the hatch is consumed only by a call that would otherwise be
# denied; the fail-consume test seam denies rather than allows.
{
    my $r = newroot();
    my $id = '20260104-150000-face';
    write_file(bug_report_path($r, $id), "# report\n");
    write_file(override_path($r), "$id\n");
    my $bash_payload = { hook_event_name => 'PreToolUse', tool_name => 'Bash', cwd => $r,
                          tool_input => { command => 'echo hi' } };
    my ($rc) = run_hook($r, $bash_payload);
    is($rc, 0, "AC-15/B-36: a Bash payload with a valid override present exits 0");
    ok(-e override_path($r), "AC-15/B-36: ...and the override is NOT consumed by a Bash call");
}
{
    my $r = newroot();
    my $id = '20260105-160000-f00d';
    write_file(bug_report_path($r, $id), "# report\n");
    write_file(override_path($r), "$id\n");
    mkdir "$r/notes"; mkdir "$r/notes/packages";
    my $p = "$r/notes/packages/readme.md";
    my ($rc) = run_hook($r, payload(tool => 'Write', cwd => $r, path => $p));
    is($rc, 0, "AC-15/B-37: a Write to a non-ledger path with a valid override present exits 0");
    ok(-e override_path($r), "AC-15/B-37: ...and the override is NOT consumed by a non-ledger write");
}
{
    # B-38: the test seam for the consume-failure branch.
    my $r = newroot();
    my $lp = ledger_path($r);
    my $id = '20260106-170000-feed';
    write_file(bug_report_path($r, $id), "# report\n");
    write_file(override_path($r), "$id\n");
    my ($rc, $out, $err) = run_hook($r, payload(tool => 'Write', cwd => $r, path => $lp),
                                     BP_LEDGER_GUARD_FAIL_CONSUME => '1');
    is($rc, 2, "AC-15/B-38: BP_LEDGER_GUARD_FAIL_CONSUME=1 denies rather than allows");
    like($err, qr/could not be consumed/, "AC-15/B-38: denial contains 'could not be consumed'");
    ok(-e override_path($r), "AC-15/B-38: the override still exists (step 6 was skipped by the seam)");
}

done_testing();
