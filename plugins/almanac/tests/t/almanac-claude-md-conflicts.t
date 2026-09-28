#!/usr/bin/env perl
# platform: any
# Immutable oracle for Almanac::ClaudeMdBlock's inspect() detection ladder
# (blueprint almanac-records, package 06-claude-md-block, spec S2.5/S2.8):
# every one of the nine ordered rules in isolation, git conflict markers
# both inside and outside the block (and which one wins when both are
# present), a genuine hand-edit correctly distinguished from a conflict, the
# injection-defence case (a note titled/covers like the sentinels), and the
# exact `reason()` tokens. The core generator surface (render/apply/remove,
# truncation, sort order) has its own oracle: almanac-claude-md-block.t. See
# specs/06-claude-md-block-spec.md -- AC numbers in test names refer to that
# file's section 4 table.
#
# HOUSE PATTERN for a not-yet-built module: every call into
# Almanac::ClaudeMdBlock is wrapped in eval{} so "Undefined subroutine" /
# "Can't locate" is a caught, reported failure for THIS assertion rather
# than an abort of the whole file -- every assertion below is expected to
# fail for exactly that reason right now, not for a fixture defect of this
# file's own making.
#
# This file never needs the module to build a "clean" block fixture: every
# block used below is hand-assembled from the exact S2.4 formula (ground
# truth, independent of the implementation) and then mutated per-test. This
# is deliberate -- an oracle that borrowed the module's own render_block()
# to build its fixtures could not tell a broken render_block from a broken
# inspect().
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
use File::Temp qw(tempdir);
use Digest::SHA qw(sha256_hex);
use Encode ();

(my $S = "$Bin/../../scripts") =~ s{\\}{/}g;
use lib "$Bin/../../scripts";

my $MOD_PM = "$S/Almanac/ClaudeMdBlock.pm";

# ---------------------------------------------------------------------------
# AC-39 tripwire (house rule): snapshot the repo's OWN CLAUDE.md before this
# file does anything, and again at the very end. Read-only -- this file
# never constructs a WRITE path into it. Every other CLAUDE.md-shaped path
# used below is rooted at a tempdir variable ($D).
# ---------------------------------------------------------------------------
sub slurp_raw {
    my ($p) = @_;
    open my $fh, '<:raw', $p or return undef;
    local $/;
    my $c = <$fh>;
    close $fh;
    return $c;
}

(my $REPO = "$Bin/../../../..") =~ s{\\}{/}g;
my $REAL_CLAUDE_MD = "$REPO/CLAUDE.md";  # TRIPWIRE-READ, never written
my $before_bytes = slurp_raw($REAL_CLAUDE_MD);  # TRIPWIRE-READ
ok(defined $before_bytes && length($before_bytes) > 0,
   'sanity: repo CLAUDE.md is readable before this file runs')
    or diag("could not read $REAL_CLAUDE_MD");
my $before_len  = defined($before_bytes) ? length($before_bytes)     : undef;
my $before_hash = defined($before_bytes) ? sha256_hex($before_bytes) : undef;

# ---------------------------------------------------------------------------
# module presence / load
# ---------------------------------------------------------------------------
ok(-f $MOD_PM, 'Almanac::ClaudeMdBlock module file exists at plugins/almanac/scripts/Almanac/ClaudeMdBlock.pm')
    or diag('Almanac/ClaudeMdBlock.pm is not present yet -- every assertion below is '
          . 'expected to fail for exactly that reason, not any other.');

my $LOAD_ERR;
eval { require Almanac::ClaudeMdBlock; 1 } or do { $LOAD_ERR = $@ };
ok(!defined $LOAD_ERR, 'Almanac::ClaudeMdBlock requires cleanly')
    or diag("load error: $LOAD_ERR");

# ---------------------------------------------------------------------------
# scaffolding
# ---------------------------------------------------------------------------
sub call_scalar {
    my ($sub, @args) = @_;
    no strict 'refs';
    my $r = eval { &{"Almanac::ClaudeMdBlock::$sub"}(@args) };
    return ($r, $@);
}
sub call_list {
    my ($sub, @args) = @_;
    no strict 'refs';
    my @r = eval { &{"Almanac::ClaudeMdBlock::$sub"}(@args) };
    return (\@r, $@);
}
sub err_kind   { my ($e) = @_; return (ref($e) && ref($e) =~ /::Error$/) ? $e->{kind}   : undef }
sub err_detail { my ($e) = @_; return (ref($e) && ref($e) =~ /::Error$/) ? $e->{detail} : undef }
sub err_path   { my ($e) = @_; return (ref($e) && ref($e) =~ /::Error$/) ? $e->{path}   : undef }

sub mk_rec {
    my (%o) = @_;
    my %fields;
    $fields{title}    = $o{title}    if exists $o{title};
    $fields{audience} = $o{audience} if exists $o{audience};
    $fields{target}   = $o{target}   if exists $o{target};
    $fields{covers}   = $o{covers}   if exists $o{covers};
    $fields{created}  = $o{created}  // '2026-01-01T00:00:00Z';
    my %rec = (path => '/fake/path.md', rev => 1, rank => 1, fields => \%fields);
    $rec{id} = $o{id} if exists $o{id};
    return \%rec;
}

# is_real_eq($got, $expected, $name) -- guards against the is(undef,undef)
# vacuous-pass class of bug for round-trip/derived-value comparisons.
sub is_real_eq {
    my ($got, $expected, $name) = @_;
    if (!defined $got) {
        fail("$name (call returned undef -- module missing/incomplete, not a fixture bug)");
        return;
    }
    is($got, $expected, $name);
}

# require_state($result, $name_for_diag) -> $state | () -- fails cleanly
# (not vacuously) when inspect() did not return a real hash.
sub require_state {
    my ($insp) = @_;
    return (ref($insp) eq 'HASH' && defined $insp->{state}) ? $insp->{state} : undef;
}

my $BEGIN_MARKER = '<!-- BEGIN GENERATED ALMANAC NOTES -- DO NOT EDIT BY HAND -->';
my $END_MARKER   = '<!-- END GENERATED ALMANAC NOTES -->';
my $HASH_PREFIX  = '<!-- almanac-notes-sha256: ';
my $HASH_SUFFIX  = ' -->';

sub build_payload {
    my (@entries) = @_;
    my $body = "\n" . "## Almanac notes -- the directory\n" . "\n"
             . "Generated from the almanac note store. Edit the note, never this block.\n" . "\n";
    for my $e (@entries) {
        my ($title, $audience, $target, $covers) = @$e;
        $covers = '-' unless defined $covers && length $covers;
        $body .= "- **$title** ($audience) -- `$target`\n  $covers\n";
    }
    return $body;
}
sub build_block {
    my (@entries) = @_;
    my $payload = build_payload(@entries);
    my $hex = sha256_hex(Encode::encode('UTF-8', $payload));
    return "$BEGIN_MARKER\n$HASH_PREFIX$hex$HASH_SUFFIX\n$payload$END_MARKER\n";
}

my @DEFAULT_ENTRY = (['A title', 'internal', 'notes/x.md', 'what it covers']);
my $CLEAN_BLOCK = build_block(@DEFAULT_ENTRY);

# Conflict-marker line builders (spec S2.5's four patterns).
my $OURS    = '<<<<<<< HEAD';
my $BASE    = '||||||| merged common ancestors';
my $SEP     = '=======';
my $THEIRS  = '>>>>>>> feature-branch';

my @N2 = (
    mk_rec(id => '20260101-000000-aaaa0002', title => 'Second note', audience => 'internal',
           target => 'notes/second.md', covers => 'covers the second thing'),
    mk_rec(id => '20260101-000000-aaaa0001', title => 'First note', audience => 'external',
           target => 'notes/first.md', covers => 'covers the first thing'),
);

# =============================================================================
# AC-22 -- injection defence: a note titled/covers like the sentinels cannot
# forge block structure (S2.3, matching is column-0 anchored only).
# =============================================================================
{
    my $rec1 = mk_rec(id => '20260101-000000-ffff0001', title => $END_MARKER, audience => 'internal',
                       target => 'notes/f1.md', covers => 'ordinary covers text');
    my $rec2 = mk_rec(id => '20260101-000000-ffff0002', title => 'Ordinary title', audience => 'internal',
                       target => 'notes/f2.md', covers => $OURS);
    my ($block, $err) = call_scalar('render_block', notes => [$rec1, $rec2]);
    ok(defined $block, 'AC-22: render_block with END-marker-shaped title and conflict-marker-shaped covers does not die')
        or diag("error: $err");
    if (defined $block) {
        ok(index($block, $END_MARKER) >= 0, 'AC-22: the forged END-marker text appears somewhere in the rendered entry');
        my ($insp) = call_scalar('inspect', $block);
        my $state = require_state($insp);
        is($state, 'clean', 'AC-22: the block still inspects as clean');
        is(ref($insp) eq 'HASH' ? $insp->{end_count} : undef, 1, 'AC-22: end_count is 1 (the forged title never anchors at column 0)');
        is(ref($insp) eq 'HASH' && ref($insp->{conflict_lines}) eq 'ARRAY' ? scalar(@{ $insp->{conflict_lines} }) : undef, 0,
           'AC-22: conflict_lines is empty (the forged covers text never anchors at column 0)');
        # The forged text is never at column 0 -- every occurrence in the
        # rendered entry is indented (either "- **<title>..." or "  <covers>").
        my @lines = split /\n/, $block;
        my @col0_end   = grep { $_ eq $END_MARKER } @lines;
        my @col0_ours  = grep { $_ eq $OURS } @lines;
        is(scalar(@col0_end), 1, 'AC-22: exactly one line equals the END marker at column 0 (the real one)');
        is(scalar(@col0_ours), 0, 'AC-22: no line equals the conflict-marker text at column 0');
    } else {
        fail('AC-22: the forged END-marker text appears somewhere in the rendered entry');
        fail('AC-22: the block still inspects as clean');
        fail('AC-22: end_count is 1 (the forged title never anchors at column 0)');
        fail('AC-22: conflict_lines is empty (the forged covers text never anchors at column 0)');
        fail('AC-22: exactly one line equals the END marker at column 0 (the real one)');
        fail('AC-22: no line equals the conflict-marker text at column 0');
    }
}

# =============================================================================
# AC-24 -- conflict markers inside the block outrank a simultaneously
# hash-invalid payload: conflict_markers, never hand_edited.
# =============================================================================
{
    for my $marker_line ($OURS, $BASE, $SEP, $THEIRS) {
        (my $conflicted = $CLEAN_BLOCK) =~ s/(what it covers\n)/$1$marker_line\n/;
        # The payload is now both conflict-bearing AND hash-invalid (the
        # inserted line changed the payload without updating the hash) --
        # exactly the case that makes rule ordering (conflict before hash)
        # load-bearing.
        my ($insp) = call_scalar('inspect', $conflicted);
        my $state = require_state($insp);
        is($state, 'conflict_markers', "AC-24: inspect() reports conflict_markers for a '$marker_line'-shaped line inside the block");

        my (undef, $err) = call_scalar('apply_text', text => $conflicted, notes => \@N2);
        my $detail = err_detail($err);
        isnt($detail, 'hand_edited', "AC-24: apply_text never reports hand_edited for a '$marker_line'-shaped conflict line")
            if defined $detail;
        fail("AC-24: apply_text never reports hand_edited for a '$marker_line'-shaped conflict line (call did not reach a refusal)")
            unless defined $detail;
        is($detail, 'conflict_markers', "AC-24: apply_text dies detail conflict_markers for a '$marker_line'-shaped line");
    }
}

# =============================================================================
# AC-25 -- reason() for conflict_markers.
# =============================================================================
{
    my ($s1) = call_scalar('reason', 'conflict_markers');
    is($s1,
       'The generated block contains git conflict markers, so this file is mid-merge. Do not resolve them by hand: remove the block and regenerate it from the note records.',
       'AC-25: reason(\'conflict_markers\') is exactly the S2.8 sentence');
    like($s1, qr/\bregenerate\b/, 'AC-25: reason(\'conflict_markers\') contains the word "regenerate"')
        if defined $s1;
    fail('AC-25: reason(\'conflict_markers\') contains the word "regenerate"') unless defined $s1;

    my ($s2) = call_scalar('reason', 'hand_edited');
    if (defined $s1 && defined $s2) {
        isnt($s1, $s2, 'AC-25: reason(\'hand_edited\') and reason(\'conflict_markers\') are different strings');
    } else {
        fail('AC-25: reason(\'hand_edited\') and reason(\'conflict_markers\') are different strings');
    }
}

# =============================================================================
# AC-26 -- conflict markers outside the block outrank everything.
# =============================================================================
{
    my $outside_only = "prose before\n$OURS\nmore prose\n" . $CLEAN_BLOCK . "trailing prose\n";
    my ($i1) = call_scalar('inspect', $outside_only);
    is(require_state($i1), 'conflict_markers_outside_block', 'AC-26: conflict markers in prose outside the block report conflict_markers_outside_block');

    (my $inside = $CLEAN_BLOCK) =~ s/(what it covers\n)/$1$THEIRS\n/;
    my $both = "prose\n$SEP\nmore prose\n" . $inside;
    my ($i2) = call_scalar('inspect', $both);
    is(require_state($i2), 'conflict_markers_outside_block', 'AC-26: markers both inside and outside report conflict_markers_outside_block (outside outranks)');

    my $outside_no_block = "just prose\n$OURS\nmore prose\n";
    my ($i3) = call_scalar('inspect', $outside_no_block);
    is(require_state($i3), 'conflict_markers_outside_block', 'AC-26: markers outside with no block present report conflict_markers_outside_block, not absent');
}

# =============================================================================
# AC-27 -- a merge that duplicated the whole block: conflict_markers, not
# markers_malformed; remove_block resolves it; apply_text then succeeds.
# =============================================================================
{
    my $duplicated = $CLEAN_BLOCK . "$OURS\n" . $CLEAN_BLOCK . "$SEP\n" . $THEIRS . "\n"; # crude but: 2 BEGIN, 2 END, conflict lines between markers... see note below
    # Build precisely: BEGIN...END, conflict line, BEGIN...END (2 BEGIN, 2 END,
    # with a conflict marker strictly between the first BEGIN and the last END).
    $duplicated = $CLEAN_BLOCK . "$SEP\n" . $CLEAN_BLOCK;

    my ($insp) = call_scalar('inspect', $duplicated);
    is(require_state($insp), 'conflict_markers', 'AC-27: a block duplicated by a merge (2 BEGIN/2 END, conflict marker between) reports conflict_markers, not markers_malformed');

    my ($rr, $er) = call_list('remove_block', $duplicated);
    my ($removed_new_text) = @{ $rr || [] };
    if (defined $removed_new_text) {
        my ($insp2) = call_scalar('inspect', $removed_new_text);
        is(require_state($insp2), 'absent', 'AC-27: after remove_block, no marker and no conflict marker remain (state absent)');

        my ($resolved, $ea) = call_scalar('apply_text', text => $removed_new_text, notes => \@N2);
        ok(defined $resolved, 'AC-27: apply_text then succeeds on the resolved text') or diag("error: $ea");
    } else {
        fail('AC-27: after remove_block, no marker and no conflict marker remain (state absent)');
        fail('AC-27: apply_text then succeeds on the resolved text');
    }
}

# =============================================================================
# AC-28 -- broken marker structure with NO conflict markers: markers_malformed.
# =============================================================================
{
    (my $no_end = $CLEAN_BLOCK) =~ s/\Q$END_MARKER\E\n\z//;
    (my $no_begin = $CLEAN_BLOCK) =~ s/\A\Q$BEGIN_MARKER\E\n//;

    # Exactly one BEGIN and one END, but END appears textually first --
    # spec S2.5 rule 8's "$e[0] < $b[0]" case, not merely "@e != 1".
    (my $body_only = $CLEAN_BLOCK) =~ s/\A\Q$BEGIN_MARKER\E\n//;
    $body_only =~ s/\Q$END_MARKER\E\n\z//;
    my $end_before_begin = $END_MARKER . "\n" . $body_only . $BEGIN_MARKER . "\n";

    my $two_begins = $BEGIN_MARKER . "\n" . $CLEAN_BLOCK;      # a second BEGIN prepended, still one END

    my %cases = (
        'END marker deleted'      => $no_end,
        'BEGIN marker deleted'    => $no_begin,
        'END appears before BEGIN' => $end_before_begin,
        'two BEGIN markers'       => $two_begins,
    );
    for my $label (sort keys %cases) {
        my $text = $cases{$label};
        my ($insp) = call_scalar('inspect', $text);
        is(require_state($insp), 'markers_malformed', "AC-28: $label (no conflict markers) reports markers_malformed");

        my (undef, $err) = call_scalar('apply_text', text => $text, notes => \@N2);
        is(err_detail($err), 'markers_malformed', "AC-28: apply_text on '$label' dies detail markers_malformed");
    }
}

# =============================================================================
# AC-29 -- hash line missing / moved.
# =============================================================================
{
    (my $deleted = $CLEAN_BLOCK) =~ s/\Q$HASH_PREFIX\E[0-9a-f]{64}\Q$HASH_SUFFIX\E\n//;
    my ($i1) = call_scalar('inspect', $deleted);
    is(require_state($i1), 'hash_line_missing', 'AC-29: hash line deleted reports hash_line_missing');
    isnt(require_state($i1), 'hand_edited', 'AC-29: hash line deleted is never reported as hand_edited') if defined require_state($i1);

    # Move the hash line below the first payload line.
    my @lines = split /\n/, $CLEAN_BLOCK, -1;
    pop @lines if @lines && $lines[-1] eq '';
    # lines[0]=BEGIN, lines[1]=hash, lines[2]=(blank payload-start line)
    my $hash_line = splice(@lines, 1, 1);
    splice(@lines, 2, 0, $hash_line);  # now after the blank payload-start line
    my $moved = join("\n", @lines) . "\n";
    my ($i2) = call_scalar('inspect', $moved);
    is(require_state($i2), 'hash_line_missing', 'AC-29: hash line moved below the first payload line reports hash_line_missing');
}

# =============================================================================
# AC-30 -- near-miss patterns are not conflict markers.
# =============================================================================
{
    for my $case (
        ['eight < characters',        '<' x 8],
        ['======= with trailing text', '======= x'],
        ['indented <<<<<<<',           '  <<<<<<<'],
        ['>>>>>>> with no space',      '>>>>>>>x'],
    ) {
        my ($label, $line) = @$case;
        # Build a block whose payload ALREADY contains the near-miss line,
        # via build_block/build_payload -- not by splicing $line into the
        # already-hashed $CLEAN_BLOCK. Splicing post-hash (as AC-24's own
        # fixtures deliberately do) invalidates the stored hash, which
        # correctly reports hand_edited per spec S2.5 rule 6 -- that is a
        # DIFFERENT property than this AC's own ("a near-miss pattern is
        # never mistaken for a real conflict marker"), and conflating the
        # two made this assertion fail regardless of the module's
        # correctness. Embedding the line pre-hash isolates the one
        # variable this AC actually tests.
        my $mutated = build_block(['A title', 'internal', 'notes/x.md', "what it covers\n$line"]);
        my ($insp) = call_scalar('inspect', $mutated);
        is(require_state($insp), 'clean', "AC-30: '$label' is not recognised as a conflict marker (state stays clean)");
    }
}

# =============================================================================
# AC-31 -- CRLF normalisation before hashing; the module always writes LF.
# =============================================================================
{
    (my $crlf = $CLEAN_BLOCK) =~ s/\n/\r\n/g;
    my ($insp) = call_scalar('inspect', $crlf);
    is(require_state($insp), 'clean', 'AC-31: a block whose every line ends \r\n reports clean');

    my $D = tempdir(CLEANUP => 1);
    $D =~ s{\\}{/}g;
    my $path = "$D/CLAUDE.md";
    my ($r, $err) = call_scalar('apply_file', path => $path, notes => \@N2);
    if (defined $r) {
        my $bytes = slurp_raw($path);
        ok(defined($bytes) && index($bytes, "\r") < 0, 'AC-31: apply_file writes LF only, no \r in the file\'s bytes');
    } else {
        fail('AC-31: apply_file writes LF only, no \r in the file\'s bytes');
    }
}

# =============================================================================
# AC-32 -- step ordering: a conflicted file with notes => [] reports the
# conflict, not no_notes.
# =============================================================================
{
    (my $conflicted = $CLEAN_BLOCK) =~ s/(what it covers\n)/$1$OURS\n/;
    my (undef, $err) = call_scalar('apply_text', text => $conflicted, notes => []);
    is(err_detail($err), 'conflict_markers', 'AC-32: apply_text(notes => []) on conflicted text dies detail conflict_markers, not no_notes');
}

# =============================================================================
# AC-33 -- inspect() returns all fourteen keys for every state; conflict_lines
# is always an arrayref; start/end undef iff present is 0; substr(start,end)
# equals the block for a clean state.
# =============================================================================
{
    my @EXPECTED_KEYS = qw(state present begin_count end_count begin_line end_line
                            start end stored_hash computed_hash payload conflict_lines);
    # spec names 12 explicit rows in the table plus 2 more implied by "begin_line
    # / end_line" and "start / end" each being two keys -- the table already
    # lists all of them individually; count them directly rather than trusting
    # a hardcoded number in this comment.
    my %fixtures = (
        absent                          => '',
        clean                           => $CLEAN_BLOCK,
        markers_malformed                => do { (my $x = $CLEAN_BLOCK) =~ s/\Q$END_MARKER\E\n\z//; $x },
        conflict_markers_outside_block  => "prose\n$OURS\nmore\n" . $CLEAN_BLOCK,
    );
    for my $expect_state (sort keys %fixtures) {
        my ($insp) = call_scalar('inspect', $fixtures{$expect_state});
        if (ref($insp) ne 'HASH') {
            fail("AC-33: inspect() returns a hashref for state=$expect_state");
            next;
        }
        my @missing = grep { !exists $insp->{$_} } @EXPECTED_KEYS;
        ok(@missing == 0, "AC-33: inspect() returns every documented key for state=$expect_state")
            or diag("missing: @missing");
        ok(ref($insp->{conflict_lines}) eq 'ARRAY', "AC-33: conflict_lines is always an arrayref for state=$expect_state");
        if (defined $insp->{present} && $insp->{present} == 0) {
            ok(!defined($insp->{start}) && !defined($insp->{end}), "AC-33: start/end are undef when present is 0 (state=$expect_state)");
        } elsif (defined $insp->{present} && $insp->{present} == 1) {
            ok(defined($insp->{start}) && defined($insp->{end}), "AC-33: start/end are defined when present is 1 (state=$expect_state)");
        }
    }

    my ($insp_clean) = call_scalar('inspect', $CLEAN_BLOCK);
    if (ref($insp_clean) eq 'HASH' && defined $insp_clean->{start} && defined $insp_clean->{end}) {
        my $extracted = substr($CLEAN_BLOCK, $insp_clean->{start}, $insp_clean->{end} - $insp_clean->{start});
        is_real_eq($extracted, $CLEAN_BLOCK, 'AC-33: substr(text, start, end-start) equals the whole clean block byte-for-byte');
    } else {
        fail('AC-33: substr(text, start, end-start) equals the whole clean block byte-for-byte');
    }
}

# =============================================================================
# AC-34 -- inspect(undef) dies usage/text_required; apply_file /
# remove_block_file without path die path_required; inspect never dies.
# =============================================================================
{
    my (undef, $err) = call_scalar('inspect', undef);
    is(err_kind($err), 'usage', 'AC-34: inspect(undef) dies kind usage');
    is(err_detail($err), 'text_required', 'AC-34: inspect(undef) dies detail text_required');

    my (undef, $e1) = call_scalar('apply_file', notes => \@N2);
    is(err_detail($e1), 'path_required', 'AC-34: apply_file without path dies detail path_required');

    my (undef, $e2) = call_scalar('remove_block_file');
    is(err_detail($e2), 'path_required', 'AC-34: remove_block_file without path dies detail path_required');

    # inspect() never dies -- exercised across every fixture text this file builds.
    my @all_texts = ($CLEAN_BLOCK, '', "prose\n$OURS\nmore\n" . $CLEAN_BLOCK,
                      do { (my $x = $CLEAN_BLOCK) =~ s/\Q$END_MARKER\E\n\z//; $x },
                      do { (my $x = $CLEAN_BLOCK) =~ s/(what it covers\n)/$1$SEP\n/; $x });
    my $any_died = 0;
    for my $t (@all_texts) {
        my $ok = eval { Almanac::ClaudeMdBlock::inspect($t); 1 };
        $any_died = 1 if !$ok && $@ !~ /Undefined subroutine|Can't locate/;
    }
    ok(!$any_died, 'AC-34: inspect() never dies (other than "not implemented yet") across every fixture text in this file');
}

# =============================================================================
# AC-39 tripwire (part 2): structural self-grep and unchanged-CLAUDE.md check.
# =============================================================================
{
    open my $fh, '<', $0 or die "cannot reopen self: $!";
    my @lines = <$fh>;
    close $fh;
    my @bad;
    for my $i (0 .. $#lines) {
        my $l = $lines[$i];
        next unless $l =~ /CLAUDE\.md/;
        next if $l =~ /TRIPWIRE-READ/;      # the one sanctioned read-only reference
        next if $l =~ /^\s*#/;              # prose comments
        next if $l =~ /AC-39|sanity:/;      # this check's own/adjacent prose (Test::More descriptions)
        next if $l =~ /\$D\/CLAUDE\.md/;    # tempdir-rooted
        push @bad, "$0:" . ($i + 1) . ": $l";
    }
    unless (ok(@bad == 0, 'AC-39: every CLAUDE.md reference in this file is tempdir-rooted or the sanctioned read-only tripwire')) {
        diag($_) for @bad;
    }

    my $after_bytes = slurp_raw($REAL_CLAUDE_MD);  # TRIPWIRE-READ
    is(defined($after_bytes) ? length($after_bytes) : undef, $before_len,
       'AC-39: the repo\'s own CLAUDE.md byte length is unchanged after this file ran');
    is(defined($after_bytes) ? sha256_hex($after_bytes) : undef, $before_hash,
       'AC-39: the repo\'s own CLAUDE.md sha256 is unchanged after this file ran');
}

done_testing();
