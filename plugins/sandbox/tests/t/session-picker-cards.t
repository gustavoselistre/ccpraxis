#!/usr/bin/env perl
# platform: any
# Oracle for blueprint sandbox-session-ux, package 03-picker-cards
# (specs/03-picker-cards-spec.md, Decisions 1-7, 14, 15, 16, 26).
# Written BLIND to the eventual tui::LaunchScreens.pm / select-session.pl /
# launcher.pl implementation of THIS package's new surfaces
# (session_card_lines, session_new_lines, card_window, session_pick_model,
# card_fields, run_picker_loop) -- derived only from the spec's contracts
# (S2), observable behaviours (S3) and numbered acceptance criteria (S4).
#
# TODAY'S EXPECTED STATE: none of the five new tui::LaunchScreens functions
# exist yet, select-session.pl has no card_fields/run_picker_loop/--list-json
# card shape, and launcher.pl's _pick_session_via_screen still builds rows
# from ->{label}. Every group below is therefore expected to go RED, mostly
# for "missing sub" reasons. criterion() turns a die (missing sub/module)
# into one explicit failing assertion, so one absent function cannot take
# the whole file down and every criterion still gets to run independently.
#
# Decision 15/26 (open-source hygiene): every fixture is synthetic, built
# fresh in a File::Temp dir whose name contains "e" with a combining accent
# (UTF-8 bytes for e-acute) -- invented UUIDs, invented /work/demo cwd,
# invented message text. Nothing is copied or read from the operator's real
# transcripts, and no real path/username reaches a committed fixture.
#
# NEVER spawns launcher.pl, podman or claude. Never reads the real session
# store or ~/.claude. No test in this file runs another test file (AC-23's
# "run the edit targets" is out of scope for this file by the coordinator's
# own instruction -- those are the IMPLEMENTER's edit targets).

use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use File::Temp qw(tempdir tempfile);
use File::Path qw(make_path);
use JSON::PP ();
use Time::Local qw(timegm);
use POSIX qw(strftime);
use Encode qw(decode);

my $SCRIPTS  = "$Bin/../../scripts";
my $SCRIPT   = "$SCRIPTS/select-session.pl";
my $LS_PM    = "$SCRIPTS/tui/LaunchScreens.pm";
my $SI_PM    = "$SCRIPTS/SessionIndex.pm";
my $SF_PM    = "$SCRIPTS/SessionFilter.pm";
my $LAUNCHER = "$SCRIPTS/launcher.pl";

use lib "$Bin/../../scripts";

# ============================================================================
# criterion($name, $code) -- a die (missing sub/module) becomes ONE explicit
# failing assertion instead of aborting the whole file (established
# convention: session-index-classify.t, session-filter.t).
# ============================================================================
sub criterion {
    my ($name, $code) = @_;
    my $ok = eval { $code->(); 1 };
    if (!$ok) {
        my $err = $@;
        $err = 'unknown error' unless length $err;
        $err =~ s/\s+\z//;
        fail("$name -- DIED (missing behavior): $err");
    }
    return;
}

# ============================================================================
# Module loads
# ============================================================================
my $THEME_OK = eval { require Theme; 1 };
ok($THEME_OK, 'L1 Theme.pm loads (shipped)') or diag("  require Theme failed: $@");
my $FRAME_OK = eval { require tui::Frame; 1 };
ok($FRAME_OK, 'L2 tui/Frame.pm loads (shipped)') or diag("  require tui::Frame failed: $@");
my $LAYOUT_OK = eval { require tui::Layout; 1 };
ok($LAYOUT_OK, 'L3 tui/Layout.pm loads (shipped)') or diag("  require tui::Layout failed: $@");

my $LS_OK = eval { require tui::LaunchScreens; 1 };
ok($LS_OK, 'L4 tui/LaunchScreens.pm loads (THIS package extends it -- expected already shipped)')
    or diag("  require tui::LaunchScreens failed: $@");

my $SI_OK = eval { require $SI_PM; 1 };
ok($SI_OK, "L5 SessionIndex.pm loads via require '$SI_PM' (package 02, shipped)")
    or diag("  require SessionIndex failed: $@");

my $SF_OK = eval { require $SF_PM; 1 };
ok($SF_OK, "L6 SessionFilter.pm loads via require '$SF_PM' (shipped)")
    or diag("  require SessionFilter failed: $@");

ok(-f $SCRIPT, 'select-session.pl exists') or BAIL_OUT('select-session.pl is missing');
require $SCRIPT;   # guarded by `unless (caller)`; must NOT run main()
pass('require of select-session.pl did not run main() (caller guard holds)');

ok(-f $LAUNCHER, 'launcher.pl exists (read as SOURCE TEXT only below -- AC-20)');

# ============================================================================
# Generic helpers
# ============================================================================
sub href { my ($x) = @_; return ref $x eq 'HASH'  ? $x : {}; }
sub aref { my ($x) = @_; return ref $x eq 'ARRAY' ? $x : []; }
sub bstr { my ($x) = @_; return defined $x && !ref $x ? $x : ''; }
sub num  { my ($x) = @_; return -1 unless defined $x && !ref $x && $x =~ /\A-?\d+(?:\.\d+)?\z/; return $x; }

# call_ls($fn, @args) -> (\@result, $err). Never dies.
sub call_ls {
    my ($fn, @args) = @_;
    my @r;
    my $ok = eval { no strict 'refs'; @r = &{"tui::LaunchScreens::$fn"}(@args); 1 };
    return (\@r, $ok ? undef : ($@ || 'died'));
}
sub scalar_ls {
    my ($r, $e) = call_ls(@_);
    return undef if $e;
    return $r->[0];
}

# index_of($haystack, $needle) -- literal, never a regex (ESC bytes compare
# literally; \Q..\E does not interpolate escapes).
sub index_of {
    my ($h, $n) = @_;
    return -1 unless defined $h && defined $n && length $n;
    return index($h, $n);
}

# count_sub($haystack, $needle) -- non-overlapping literal occurrence count.
sub count_sub {
    my ($h, $n) = @_;
    return 0 unless defined $h && defined $n && length $n;
    my ($c, $p) = (0, 0);
    while ((my $i = index($h, $n, $p)) >= 0) { $c++; $p = $i + length($n); }
    return $c;
}

# joined_text($spans_or_lines) -- flattens one line's spans, or a whole
# \@lines arrayref-of-arrayrefs, into their concatenated text.
sub joined_text {
    my ($x) = @_;
    return '' unless ref $x eq 'ARRAY';
    my $out = '';
    for my $el (@$x) {
        if (ref $el eq 'HASH') { $out .= bstr($el->{text}); }
        elsif (ref $el eq 'ARRAY') { $out .= joined_text($el); }
    }
    return $out;
}

# all_spans(\@lines) -- every span hashref across every line, flattened.
sub all_spans {
    my ($lines) = @_;
    my @out;
    for my $line (@{ aref($lines) }) {
        push @out, grep { ref $_ eq 'HASH' } @{ aref($line) };
    }
    return @out;
}

# has_span(\@lines_or_spans, $text, $role) -- true if some span, anywhere,
# has EXACTLY this text and EXACTLY this role.
sub has_span {
    my ($x, $text, $role) = @_;
    my @spans = (ref $x->[0] eq 'ARRAY') ? all_spans($x) : grep { ref $_ eq 'HASH' } @$x;
    for my $sp (@spans) {
        return 1 if bstr($sp->{text}) eq $text && bstr($sp->{role}) eq $role;
    }
    return 0;
}

# line_width($spans) -- via tui::Frame::spans_width, the SAME helper the
# renderer itself measures with.
sub line_width {
    my ($spans) = @_;
    my $w = eval { tui::Frame::spans_width($spans) };
    return defined $w ? $w : -1;
}

# sgr_params($bytes) -- every \e[...m parameter string in $bytes, in order.
# A structural scan (not a content-equality comparison), mirroring
# select-session-viewport.t's own visible()/clip_visible tests.
sub sgr_params {
    my ($bytes) = @_;
    return () unless defined $bytes;
    return ($bytes =~ /\e\[([0-9;]*)m/g);
}

sub has_color_param {
    my ($params) = @_;
    for my $p (@$params) {
        for my $tok (split /;/, $p) {
            return 1 if $tok =~ /^(?:38|48|3[0-7]|9[0-7])$/;
        }
    }
    return 0;
}

sub warn_count_of {
    my ($code) = @_;
    my $n = 0;
    local $SIG{__WARN__} = sub { $n++ };
    $code->();
    return $n;
}

# mk_card(%over) -- a hand-built %card contract (S2.1), both messages
# present, short text, no badges: the "everything fits" baseline every AC-1/
# AC-2/AC-6/AC-7 variant overrides pieces of.
sub mk_card {
    my (%over) = @_;
    return {
        started    => '2026-01-01 10:00',
        active     => '2026-01-01 13:00',
        ago        => '3h ago',
        first      => 'Fix the login bug',
        last       => 'Deployed the fix to prod',
        kind_label => undef,
        badges     => [],
        %over,
    };
}

my $DOT = Theme::glyph('sep.dot');
my $D   = " $DOT ";
my $CURSOR_GLYPH = Theme::glyph('cursor');
my $RULEV_GLYPH  = Theme::glyph('rule.v');

# ============================================================================
# SessionIndex fixture helpers (mirrors session-index-classify.t's
# convention -- write_jsonl/user_rec/ts -- so THIS file's fixtures use the
# same shape package 02's own oracle already exercises).
# ============================================================================
my $JSON = JSON::PP->new->utf8->canonical;
my $T0 = 1_734_000_000;

sub ts     { my ($off) = @_; return iso_ts($T0 + $off); }
sub iso_ts { my ($ep)  = @_; return strftime('%Y-%m-%dT%H:%M:%S', gmtime($ep)) . '.000Z'; }

sub write_jsonl {
    my ($path, @records) = @_;
    open my $fh, '>:raw', $path or die "write_jsonl($path): $!";
    print {$fh} $JSON->encode($_), "\n" for @records;
    close $fh;
    return $path;
}

sub user_rec {
    my (%opts) = @_;
    my $content = delete $opts{content};
    my $rec = {
        type      => 'user',
        sessionId => delete($opts{sessionId}) // 'aaaaaaaa-0000-0000-0000-000000000000',
        cwd       => '/work/demo',
        message   => { role => 'user', content => $content },
    };
    for my $k (qw(timestamp entrypoint promptSource origin isSidechain isMeta
                  isCompactSummary isVisibleInTranscriptOnly agentId toolUseResult)) {
        $rec->{$k} = $opts{$k} if exists $opts{$k};
    }
    return $rec;
}

sub assistant_rec {
    my (%opts) = @_;
    my $content = delete $opts{content} // 'ok, understood.';
    my $rec = { type => 'assistant', sessionId => $opts{sessionId} // 'aaaaaaaa-0000-0000-0000-000000000000',
                message => { role => 'assistant', content => $content } };
    $rec->{timestamp} = $opts{timestamp} if exists $opts{timestamp};
    return $rec;
}

# accent_dir() -- a File::Temp dir whose name contains a UTF-8-encoded
# e-acute (Decision 15), never the operator's real path.
sub accent_dir {
    my $root = tempdir(CLEANUP => 1);
    my $dir  = "$root/sess\xc3\xa9ss-" . int(rand(1_000_000));
    make_path($dir);
    return $dir;
}

sub write_registry {
    my ($sessions_root, @uuids) = @_;
    my $reg_root = tempdir(CLEANUP => 1);
    make_path("$reg_root/bp-e2e/runs");
    my $i = 0;
    my @entries = map { $i++; qq("pkg$i":{"session_id":"$_"}) } @uuids;
    open my $fh, '>:raw', "$reg_root/bp-e2e/runs/registry.json" or die $!;
    print {$fh} '{"packages":{' . join(',', @entries) . '}}';
    close $fh;
    return $reg_root;
}

# run_capture(\@cmd, %opt) -- spawns select-session.pl, feeding %opt{input}
# on STDIN (default none), returning { content (from --output file, if
# %opt{out} given), rc, stdout, stderr }. Mirrors session-filter.t's
# run_picker() child-process pattern.
sub run_capture {
    my (@argv) = @_;
    my %opt = (ref $argv[-1] eq 'HASH') ? %{ pop @argv } : ();
    my $dir = $opt{workdir} // tempdir(CLEANUP => 1);
    my (undef, $out_file) = tempfile(DIR => $dir, SUFFIX => '.out');
    my (undef, $err_file) = tempfile(DIR => $dir, SUFFIX => '.err');
    my $cmd = join(' ', qq("$^X"), qq("$SCRIPT"), @argv);
    open my $p, "| $cmd >\"$out_file\" 2>\"$err_file\"" or die "run_capture: open pipe failed: $!";
    print $p ($opt{input} // '');
    close $p;
    my $rc = $? >> 8;
    my $slurp = sub {
        my ($f) = @_;
        open my $fh, '<:raw', $f or return '';
        local $/; my $s = <$fh>; close $fh; return defined $s ? $s : '';
    };
    return { rc => $rc, stdout => $slurp->($out_file), stderr => $slurp->($err_file) };
}

sub run_picker_output_content {
    my (%a) = @_;
    my $dir = $a{sessions_dir};
    my (undef, $out) = tempfile(DIR => $dir, SUFFIX => '.action');
    my @argv = ('--sessions-dir', $dir, '--output', $out);
    push @argv, '--blueprints-dir', $a{blueprints_dir} if exists $a{blueprints_dir};
    my $r = run_capture(@argv, { input => $a{input} // '', workdir => $dir });
    my $content;
    if (open my $fh, '<', $out) { local $/; $content = <$fh>; close $fh; }
    $content =~ s/\r?\n\z// if defined $content;
    $r->{content} = $content;
    return $r;
}

# ============================================================================
# AC-1: line 1 is G + F1 exactly at 80 cols; then First:/Last:/blank; height 4
# ============================================================================
criterion('AC-1: card at 80 cols, first!=last, short messages: line 1 is G+F1 exactly; First:/Last:/blank; height 4', sub {
    my $card = mk_card();
    my $lines = scalar_ls('session_card_lines', $card, 80, 0);
    is(ref $lines, 'ARRAY', 'AC-1: session_card_lines returns an arrayref') or return;
    is(scalar(@$lines), 4, 'AC-1: card height is 4 (line1 + First: + Last: + blank)');
    my $line1 = joined_text($lines->[0]);
    my $expect = '  started ' . $card->{started} . $D . 'last active ' . $card->{active} . $D . $card->{ago};
    is($line1, $expect, 'AC-1: line 1 text is G+F1 exactly');
    like(joined_text($lines->[1]), qr/First:/, 'AC-1: a First: line follows');
    like(joined_text($lines->[2]), qr/Last:/,  'AC-1: a Last: line follows');
    is(joined_text($lines->[3]), '', 'AC-1: the last line is blank');
});

# ============================================================================
# AC-2: F2 at 60, F1 at 120; width invariant at 60/80/120, selected 0/1
# ============================================================================
criterion('AC-2: template selection by width (F2 at 60, F1 at 120) and the never-overflow invariant', sub {
    my $card = mk_card();
    my $line1_60  = joined_text(aref(scalar_ls('session_card_lines', $card, 60, 0))->[0]);
    my $line1_120 = joined_text(aref(scalar_ls('session_card_lines', $card, 120, 0))->[0]);
    unlike($line1_60, qr/started /, 'AC-2: at 60 cols the F2 template (no "started " label) is used');
    like($line1_120, qr/^\ \ started /, 'AC-2: at 120 cols the F1 template is used');

    my $violations = 0;
    for my $cols (60, 80, 120) {
        for my $sel (0, 1) {
            my $lines = scalar_ls('session_card_lines', $card, $cols, $sel);
            for my $line (@{ aref($lines) }) {
                my $w = line_width($line);
                $violations++ if $w < 0 || $w > $cols;
            }
        }
    }
    is($violations, 0, 'AC-2: every line at 60/80/120, selected and unselected, fits within cols');
});

# ============================================================================
# AC-3: a 600-char first message wraps to exactly 2 lines with an ellipsis
# ============================================================================
criterion('AC-3: a 600-char first message: block is exactly 2 lines, ends in ELLIPSIS, no \\n or \\r anywhere', sub {
    my $long = substr(('lorem ipsum dolor sit amet consectetur ' x 20), 0, 600);
    my $card = mk_card(first => $long, last => undef);
    my $lines = scalar_ls('session_card_lines', $card, 80, 0);
    is(scalar(@$lines), 4, 'AC-3: height is 4 (line1 + 2 block lines + blank)');
    my $row1 = joined_text($lines->[1]);
    my $row2 = joined_text($lines->[2]);
    my $ellipsis = tui::Frame::ELLIPSIS();
    like($row2, qr/\Q$ellipsis\E\s*\z/, 'AC-3: row 2 ends with the ELLIPSIS glyph');

    my ($lab1) = ($row1 =~ /^(\s*Message:\s*)/);
    my ($lab2) = ($row2 =~ /^(\s*)/);
    is(length($lab2 // ''), length($lab1 // ''), 'AC-3: row 2 text starts at the same display column as row 1 text');

    (my $t1 = $row1) =~ s/^\s*Message:\s*//;
    (my $t2 = $row2) =~ s/^\s*//;
    $t2 =~ s/\Q$ellipsis\E\s*\z//;
    $t1 =~ s/\s+\z//; $t2 =~ s/\s+\z//;
    my $joined = length($t2) ? "$t1 $t2" : $t1;
    is(index($long, $joined), 0, 'AC-3: the two rows, joined, are a prefix of the normalised message');

    my $bad_nl = 0;
    for my $sp (all_spans($lines)) {
        $bad_nl++ if index(bstr($sp->{text}), "\n") >= 0 || index(bstr($sp->{text}), "\r") >= 0;
    }
    is($bad_nl, 0, 'AC-3: no span text anywhere contains \\n or \\r');
});

# ============================================================================
# AC-4: width drives wrapping; embedded \n\n and tabs collapse to one space
# ============================================================================
criterion('AC-4: a ~100-char message is 1 line at 120, 2 lines (no ellipsis) at 80, 2 lines (ellipsis) at 60', sub {
    # 102 chars: text_w = cols-4-9 (Message: label is 9 wide) gives 107/67/47
    # at 120/80/60 cols. Verified against tui::Frame::wrap_line: this wraps to
    # exactly 1 row at 120 (no wrap at all), 2 rows at 80 (no truncation --
    # wrap_capped only truncates when it produces MORE than 2 rows), and 3
    # rows at 60 (truncated to 2 with an ellipsis). A shorter fixture (the
    # previous 88-char one) wrapped to only 2 rows even at 60 cols, so 60
    # never actually exercised truncation.
    my $msg = join(' ', map { "word$_" } 1 .. 16);

    for my $spec ([120, 3], [80, 4]) {
        my ($cols, $want_height) = @$spec;
        my $card = mk_card(first => $msg, last => undef);
        my $lines = scalar_ls('session_card_lines', $card, $cols, 0);
        is(scalar(@$lines), $want_height, "AC-4: at $cols cols the card height is $want_height");
    }
    my $card60 = mk_card(first => $msg, last => undef);
    my $lines60 = scalar_ls('session_card_lines', $card60, 60, 0);
    is(scalar(@$lines60), 4, 'AC-4: at 60 cols the block still wraps to 2 lines');
    my $ellipsis = tui::Frame::ELLIPSIS();
    like(joined_text($lines60->[2]), qr/\Q$ellipsis\E/, 'AC-4: at 60 cols row 2 carries the ellipsis');
    my $lines80 = scalar_ls('session_card_lines', mk_card(first => $msg, last => undef), 80, 0);
    unlike(joined_text($lines80->[2]), qr/\Q$ellipsis\E/, 'AC-4: at 80 cols row 2 has NO ellipsis (it is not clipped)');

    my $card_ws = mk_card(first => "hello\n\nworld\ttab\ttrailing", last => undef);
    my $lines_ws = scalar_ls('session_card_lines', $card_ws, 120, 0);
    my $body = joined_text($lines_ws->[1]);
    $body =~ s/^\s*Message:\s*//;
    unlike($body, qr/\t/,     'AC-4: no literal tab reaches the rendered paragraph');
    unlike($body, qr/  /,     'AC-4: no double space reaches the rendered paragraph (single-spaced)');
    like($body, qr/hello world tab trailing/, 'AC-4: embedded blank line and tabs collapse to single spaces');
});

# ============================================================================
# AC-5: same_message / single-message -> one Message: block; first!=last ->
# both blocks. Exercised via list_sessions() + card_fields() directly.
# ============================================================================
criterion('AC-5: list_sessions + card_fields: same_message and single-message sessions get one Message: block; first!=last gets both', sub {
    my $dir = accent_dir();
    my $UUID_SAME = 'aaaaaaaa-1111-2222-3333-444444444444';
    my $UUID_ONE  = 'bbbbbbbb-1111-2222-3333-444444444444';
    my $UUID_DIFF = 'cccccccc-1111-2222-3333-444444444444';

    write_jsonl("$dir/$UUID_SAME.jsonl",
        user_rec(sessionId => $UUID_SAME, timestamp => ts(0),  entrypoint => 'cli', content => 'the exact same words'),
        assistant_rec(sessionId => $UUID_SAME, timestamp => ts(5)),
        user_rec(sessionId => $UUID_SAME, timestamp => ts(10), entrypoint => 'cli', content => 'the exact same words'),
    );
    write_jsonl("$dir/$UUID_ONE.jsonl",
        user_rec(sessionId => $UUID_ONE, timestamp => ts(0), entrypoint => 'cli', content => 'only one typed message'),
    );
    write_jsonl("$dir/$UUID_DIFF.jsonl",
        user_rec(sessionId => $UUID_DIFF, timestamp => ts(0), entrypoint => 'cli', content => 'the first message'),
        user_rec(sessionId => $UUID_DIFF, timestamp => ts(5), entrypoint => 'cli', content => 'a totally different last message'),
    );

    no strict 'refs';
    my @sessions = &{'main::list_sessions'}($dir);
    my %by_uuid = map { $_->{uuid} => $_ } @sessions;
    is(scalar(keys %by_uuid), 3, 'AC-5: list_sessions returns the 3 non-empty fixture sessions');

    for my $u ($UUID_SAME, $UUID_ONE) {
        my $card = &{'main::card_fields'}($by_uuid{$u}, $T0 + 100);
        ok(ref $card eq 'HASH', "AC-5: card_fields($u) returns a hashref");
        my $lines = scalar_ls('session_card_lines', $card, 80, 0);
        my $text = joined_text($lines);
        is(($text =~ tr/:/:/) >= 0 ? (() = $text =~ /Message:/g) : 0, 1, "AC-5: $u renders exactly one Message: label");
        unlike($text, qr/First:/, "AC-5: $u renders no First: label");
        unlike($text, qr/Last:/,  "AC-5: $u renders no Last: label");
    }

    my $card_diff = &{'main::card_fields'}($by_uuid{$UUID_DIFF}, $T0 + 100);
    my $text_diff = joined_text(scalar_ls('session_card_lines', $card_diff, 80, 0));
    like($text_diff, qr/First:/, 'AC-5: a first!=last session renders First:');
    like($text_diff, qr/Last:/,  'AC-5: a first!=last session renders Last:');
});

# ============================================================================
# AC-6: role table
# ============================================================================
criterion('AC-6: roles -- labels muted, timestamps primary/accent, separator rule, age faint, message primary, (no message) faint, badge state.warn, gutter glyphs, NEW accent', sub {
    my $card = mk_card();
    my $unsel = scalar_ls('session_card_lines', $card, 80, 0);
    my $sel   = scalar_ls('session_card_lines', $card, 80, 1);

    ok(has_span($unsel, 'started ', 'text.muted'),      'AC-6: "started " label is text.muted');
    ok(has_span($unsel, 'last active ', 'text.muted'),  'AC-6: "last active " label is text.muted');
    ok(has_span($unsel, $card->{started}, 'text.primary'), 'AC-6: unselected started timestamp is text.primary');
    ok(has_span($sel,   $card->{started}, 'accent'),       'AC-6: selected started timestamp is accent');
    ok(has_span($unsel, $DOT, 'rule'),                  'AC-6: the separator glyph is role rule');
    ok(has_span($unsel, $card->{ago}, 'text.faint'),    'AC-6: age is text.faint');

    my $nomsg = mk_card(first => undef, last => undef);
    my $nomsg_lines = scalar_ls('session_card_lines', $nomsg, 80, 0);
    ok(has_span($nomsg_lines, '(no message)', 'text.faint'), 'AC-6: (no message) is text.faint');
    ok(has_span($nomsg_lines, 'Message:', 'text.muted'), 'AC-6: the Message: label is text.muted');

    my $msgtext = mk_card(first => 'hello world', last => undef);
    my $msg_lines = scalar_ls('session_card_lines', $msgtext, 80, 0);
    ok(has_span($msg_lines, 'hello world', 'text.primary'), 'AC-6: message text is text.primary');

    my $badge = mk_card(kind_label => 'coordinator');
    my $badge_lines = scalar_ls('session_card_lines', $badge, 80, 0);
    ok(has_span($badge_lines, ' [coordinator]', 'state.warn'), 'AC-6: the kind badge is state.warn');

    ok(has_span($sel, $CURSOR_GLYPH . ' ', 'accent'), 'AC-6: selected line 1 gutter is the cursor glyph, accent');
    ok(has_span($sel, $RULEV_GLYPH . ' ', 'accent'),  'AC-6: selected content-line gutter is rule.v, accent');

    my $new_unsel = scalar_ls('session_new_lines', 80, 0);
    my $new_sel   = scalar_ls('session_new_lines', 80, 1);
    ok(has_span($new_unsel, '+ Start a new session', 'accent'), 'AC-6: the NEW row is accent, unselected');
    ok(has_span($new_sel,   '+ Start a new session', 'accent'), 'AC-6: the NEW row is accent, selected');
    is(scalar(@{ aref($new_unsel) }), 2, 'AC-6: session_new_lines height is 2');
});

# ============================================================================
# AC-7: paint_row emits truecolor SGR under 'truecolor', none under 'none'
# ============================================================================
criterion("AC-7: paint_row(make_cell(line,undef,cols),'truecolor') carries 38;2;; 'none' carries no colour parameter", sub {
    my $card = mk_card(kind_label => 'headless');
    my $lines = scalar_ls('session_card_lines', $card, 80, 1);
    is(ref $lines, 'ARRAY', 'AC-7: session_card_lines returns lines') or return;

    my $any_true = 0;
    my $bad_none = 0;
    for my $line (@$lines) {
        next unless grep { length(bstr(href($_)->{text})) } @{ aref($line) };
        my $cell_t = tui::Frame::make_cell($line, undef, 80);
        my $painted_t = tui::Frame::paint_row($cell_t, 'truecolor');
        $any_true++ if index_of($painted_t, '38;2;') >= 0;

        my $cell_n = tui::Frame::make_cell($line, undef, 80);
        my $painted_n = tui::Frame::paint_row($cell_n, 'none');
        $bad_none++ if has_color_param([ sgr_params($painted_n) ]);
    }
    cmp_ok($any_true, '>', 0, "AC-7: at least one non-blank card line carries a truecolor SGR ('38;2;') under 'truecolor'");
    is($bad_none, 0, "AC-7: no card line carries any colour SGR parameter under 'none'");
});

# ============================================================================
# AC-8: NO_COLOR -> zero colour params on the plain loop; CCPRAXIS_COLOR=
# truecolor -> title/NEW/footer are each preceded by their role's SGR
# ============================================================================
criterion('AC-8: run_picker_loop honours NO_COLOR (no colour params) and CCPRAXIS_COLOR=truecolor (role SGR present)', sub {
    no strict 'refs';
    my @opts = &{'main::build_options'}();
    my @keys = ('q');
    my $out_buf = '';
    {
        local $ENV{NO_COLOR} = 1;
        Theme::_reset_capability_memo();
        $out_buf = '';
        &{'main::run_picker_loop'}(\@opts,
            read_key  => sub { @keys ? shift @keys : undef },
            term_size => sub { (80, 24) },
            out       => sub { $out_buf .= $_[0]; 1 },
        );
        is(has_color_param([ sgr_params($out_buf) ]), 0, 'AC-8: under NO_COLOR the plain loop emits no colour parameter');
    }
    {
        local $ENV{NO_COLOR};
        delete $ENV{NO_COLOR};
        local $ENV{CCPRAXIS_COLOR} = 'truecolor';
        Theme::_reset_capability_memo();
        @keys = ('q');
        $out_buf = '';
        &{'main::run_picker_loop'}(\@opts,
            read_key  => sub { @keys ? shift @keys : undef },
            term_size => sub { (80, 24) },
            out       => sub { $out_buf .= $_[0]; 1 },
        );
        my $accent_sgr = Theme::sgr('accent', 'truecolor');
        my $faint_sgr  = Theme::sgr('text.faint', 'truecolor');
        cmp_ok(index_of($out_buf, $accent_sgr), '>=', 0, 'AC-8: the accent-role SGR (title/NEW) appears under truecolor');
        cmp_ok(index_of($out_buf, $faint_sgr),  '>=', 0, 'AC-8: the text.faint-role SGR (hints/footer) appears under truecolor');
    }
    Theme::_reset_capability_memo();
});

# ============================================================================
# AC-9: TUI resize via list_run + session_pick_model
# ============================================================================
criterion('AC-9: list_run detects a resize at the next idle poll, repaints in full, then settles', sub {
    no strict 'refs';
    my $model = scalar_ls('session_pick_model', [ { uuid => 'aaaaaaaa-0000-0000-0000-000000000000', mtime => 1, is_butler => 0, card => {} } ],
                           'resume a session - proj', undef);
    is(ref $model, 'HASH', 'AC-9: session_pick_model returns a hashref') or return;

    my $settle = scalar_ls('RESIZE_SETTLE_POLLS');
    cmp_ok(num($settle), '>=', 1, 'AC-9: RESIZE_SETTLE_POLLS() is >= 1');

    for my $variant (['resize', 1], ['constant', 0]) {
        my ($label, $resizes) = @$variant;
        my @renders;
        my @wait_seq = (undef, undef, undef, undef, 'q');
        my $calls = 0;
        my $term_size = sub {
            $calls++;
            return $resizes && $calls > 1 ? (60, 30) : (120, 30);
        };
        scalar_ls('list_run',
            model     => $model,
            read_key  => sub { undef },
            wait_key  => sub { shift @wait_seq },
            term_size => $term_size,
            render    => sub { my ($prev, $f) = @_; push @renders, { prev => $prev, frame => $f }; return ''; },
            out       => sub { 1 },
        );
        cmp_ok(scalar(@renders), '>=', 1, "AC-9 ($label): at least the initial paint happened");
        if ($resizes) {
            my @prev_undef_60 = grep { !defined $_->{prev} } @renders[1 .. $#renders];
            # Spec 3.6 / AC-9: "the first idle-poll paint happens, then
            # EXACTLY RESIZE_SETTLE_POLLS() more" -- an exact count, not a
            # floor, and no key was fed in between (the scripted wait_key
            # sequence is all-undef until the trailing 'q').
            is(scalar(@prev_undef_60), num($settle) + 1,
                "AC-9 (resize): exactly the resize paint plus RESIZE_SETTLE_POLLS() further prev-undef paints occur, no more");
            my $bad_width = 0;
            for my $r (@prev_undef_60) {
                for my $c (@{ aref($r->{frame}) }) {
                    my $w = eval { tui::Layout::display_width(bstr(href($c)->{text})) };
                    $bad_width++ unless defined $w && $w == 60;
                }
            }
            is($bad_width, 0, 'AC-9 (resize): every cell of every repainted frame is exactly 60 display columns wide');
        } else {
            # The scripted run still ends on a 'q' keypress, and list_run's
            # key path (S2.2: "the key path... unchanged") always repaints
            # after a real key -- that final paint is expected and is not an
            # idle-poll/resize paint. Only a paint with prev undef (the
            # signature list_run gives an idle/resize repaint, per the resize
            # branch above) may not occur beyond the initial one.
            my @prev_undef_extra = grep { !defined $_->{prev} } @renders[1 .. $#renders];
            is(scalar(@prev_undef_extra), 0, 'AC-9 (constant size): no idle-poll paint beyond the initial one');
        }
    }
});

# ============================================================================
# AC-10: plain resize via run_picker_loop
# ============================================================================
criterion('AC-10: run_picker_loop detects a resize on an idle read_key timeout, repaints in full, then settles; timeouts stay in (0, 0.25]', sub {
    no strict 'refs';
    my @opts = &{'main::build_options'}();
    my $settle = scalar_ls('RESIZE_SETTLE_POLLS');
    for my $variant (['resize', 1], ['constant', 0]) {
        my ($label, $resizes) = @$variant;
        my @keys = (undef, undef, undef, undef, 'q');
        my @timeouts;
        my @snap;   # out_buf length at the START of each idle (timeout) poll
        my $calls = 0;
        my $out_buf = '';
        &{'main::run_picker_loop'}(\@opts,
            read_key  => sub {
                my ($t) = @_;
                if (defined $t) { push @timeouts, $t; push @snap, length($out_buf); }
                return shift @keys;
            },
            term_size => sub { $calls++; return $resizes && $calls > 1 ? (60, 24) : (120, 24); },
            out       => sub { $out_buf .= $_[0]; 1 },
        );
        my $bad_timeout = grep { !($_ > 0 && $_ <= 0.25) } @timeouts;
        is($bad_timeout, 0, "AC-10 ($label): every idle read_key timeout is in (0, 0.25]");
        my $full_repaints = count_sub($out_buf, "\e[H\e[2J");
        if ($resizes) {
            # Spec 3.6 / AC-10: exactly the unconditional initial full paint,
            # plus the resize repaint, plus RESIZE_SETTLE_POLLS() further
            # full repaints -- not merely ">=2".
            is($full_repaints, num($settle) + 2,
                'AC-10 (resize): exactly the initial paint plus the resize repaint plus RESIZE_SETTLE_POLLS() further full repaints occur, no more');
            # A 60-wide frame is actually emitted after the resize (S2 review
            # fix: the old assertion never checked the emitted width at all).
            my $visible = $out_buf;
            $visible =~ s/\e\[[0-9;]*[A-Za-z]//g;
            my @rows60 = grep { length($_) == 60 } split /\r\n/, $visible;
            cmp_ok(scalar(@rows60), '>=', 1, 'AC-10 (resize): at least one 60-column-wide row is emitted after the resize');
        } else {
            is($full_repaints, 1, 'AC-10 (constant size): exactly the initial full paint occurs, no resize repaint');
            # Zero out-buffer growth across timeouts (S2 review fix): with a
            # constant size, nothing is emitted in response to ANY of the
            # idle-poll timeouts -- the buffer length at the start of every
            # timeout poll after the first is identical.
            my $bad_growth = 0;
            for my $i (1 .. $#snap) { $bad_growth++ if $snap[$i] != $snap[$i - 1]; }
            is($bad_growth, 0, 'AC-10 (constant size): zero out-buffer growth across timeouts');
        }
    }
});

# ============================================================================
# M1 (review must-fix): plan_frame must see the SUMMED CARD HEIGHTS of the
# view, not the option count, or the more-above/more-below hints never fire
# at ordinary sizes and sessions are hidden with no indication they exist.
# ============================================================================
criterion('M1: 12 sessions at 80x24 show a more-below hint (and more-above once scrolled), and the visible cards never overflow the frame budget', sub {
    no strict 'refs';
    my @sessions = map {
        { uuid => sprintf('cccccccc-0000-0000-0000-%012d', $_), mtime => 1000 + $_, kind => 'human',
          started_at => $T0, last_active_at => $T0 + $_, first_typed => "message number $_", last_typed => undef, same_message => 0 }
    } 1 .. 12;
    my @opts = &{'main::build_options'}(@sessions);

    # First frame, no key pressed: the cursor sits on option 0 (NEW). 12
    # multi-line cards cannot possibly fit an 80x24 budget, so a "more below"
    # hint MUST appear, and no "more above" (the window starts at the top).
    {
        my $out_buf = '';
        &{'main::run_picker_loop'}(\@opts,
            read_key  => sub { 'q' },
            term_size => sub { (80, 24) },
            out       => sub { $out_buf .= $_[0]; 1 },
        );
        like($out_buf, qr/more below/, 'M1: a "more below" hint appears at 80x24 with 12 sessions');
        unlike($out_buf, qr/more above/, 'M1: no "more above" hint while the window starts at the top');
    }

    # Scroll to the bottom with repeated down-arrows (ESC [ B, three reads
    # per press, per the loop's own ESC-sequence handling), then quit: the
    # window has moved off the top, so a "more above" hint must now appear.
    {
        my @keys = (("\e", '[', 'B') x 13, 'q');
        my $out_buf = '';
        &{'main::run_picker_loop'}(\@opts,
            read_key  => sub { @keys ? shift @keys : undef },
            term_size => sub { (80, 24) },
            out       => sub { $out_buf .= $_[0]; 1 },
        );
        like($out_buf, qr/more above/, 'M1: a "more above" hint appears once the window has scrolled past the top');
    }

    # The window never shows more than the frame can hold: for every cursor
    # position, the summed heights of the visible (card_window) cards never
    # exceed plan_frame's row budget for an 80x24 terminal (unless the
    # cursor's own card alone exceeds the budget, the documented exception).
    my @heights;
    for my $o (@opts) {
        if (($o->{action} // '') eq 'NEW') { push @heights, 2; }
        else {
            my $ln = scalar_ls('session_card_lines', $o->{card}, 80, 0);
            push @heights, (ref $ln eq 'ARRAY' && @$ln) ? scalar(@$ln) : 3;
        }
    }
    my $total_h = 0; $total_h += $_ for @heights;
    my $plan = &{'main::plan_frame'}(24, $total_h);
    my $bad_overflow = 0;
    for my $cursor (0 .. $#opts) {
        my $win = scalar_ls('card_window', \@heights, $cursor, $plan->{cap}, 0);
        next unless ref $win eq 'HASH';
        my $sum = 0; $sum += $heights[$_] for $win->{first} .. $win->{last};
        $bad_overflow++ if $sum > $plan->{cap} && $win->{first} != $win->{last};
    }
    is($bad_overflow, 0, "M1: the visible cards' summed heights never exceed the frame's row budget");
});

# ============================================================================
# M2 (review must-fix / Decision 30): every paint must stay cheap regardless
# of message length. Decision 30 splits the old single-frame check into what
# the user actually feels: the FIRST paint (no memoised card heights to lean
# on yet) gets a generous 1000ms budget; a REPAINT after one cursor keypress
# (which SHOULD be able to reuse memoised card heights, since only the
# terminal size invalidates them -- not the cursor moving) must stay under
# 100ms. Each bound is judged on the MEDIAN of 3 runs so one contended
# scheduler tick on a loaded host does not make either check flaky.
#
# Both criteria build the SAME 300-card, 4096-char-message fixture; a helper
# avoids constructing it three times over.
# ============================================================================
sub _m2_fixture_opts {
    my @sessions = map {
        { uuid => sprintf('dddddddd-0000-0000-0000-%012d', $_), mtime => $_, kind => 'human',
          started_at => $T0, last_active_at => $T0 + $_,
          first_typed => ('m' x 4096), last_typed => ('n' x 4096), same_message => 0 }
    } 1 .. 300;
    no strict 'refs';
    return &{'main::build_options'}(@sessions);
}

sub _median_ms { my @s = sort { $a <=> $b } @_; return $s[1]; }

criterion('M2a: the FIRST (COLD) paint of 300 cards with 4096-char messages completes under a generous time bound (median of 3 runs)', sub {
    no strict 'refs';
    require Time::HiRes;
    my @opts = _m2_fixture_opts();
    my @runs_ms;
    for (1 .. 3) {
        # Decision 31: the card cache is warm by default (it survives across
        # runs within this process), so without an explicit clear this loop
        # would measure a warm re-paint, not the cold first paint the name
        # promises. tui::LaunchScreens::session_card_cache_clear() is what
        # THIS package is adding; until it lands this dies with "missing
        # sub", which is the right failure per the coordinator's guidance.
        tui::LaunchScreens::session_card_cache_clear();
        my $t0 = Time::HiRes::time();
        &{'main::run_picker_loop'}(\@opts,
            read_key  => sub { 'q' },   # exactly one frame is painted before this quits the loop
            term_size => sub { (80, 24) },
            out       => sub { 1 },
        );
        push @runs_ms, (Time::HiRes::time() - $t0) * 1000;
    }
    my $median_ms = _median_ms(@runs_ms);
    cmp_ok($median_ms, '<', 1000,
        sprintf('M2a: the first COLD frame of 300 cards with 4096-char messages renders in under 1000ms ' .
                '(median %.1fms across runs %s)', $median_ms, join(', ', map { sprintf('%.1f', $_) } @runs_ms)));
});

# ============================================================================
# M2c (Decision 31): the card cache is dropped whole on every width change,
# so it never accumulates more than one width's worth of cards -- cycling
# through several widths must not leave the cache holding all of them.
# ============================================================================
criterion('M2c: session_card_cache_size() never exceeds one width\'s worth of cards after cycling through several widths', sub {
    no strict 'refs';
    my @opts = _m2_fixture_opts();
    tui::LaunchScreens::session_card_cache_clear();
    my $item_count = scalar(@opts);
    my $max_size = 0;
    for my $cols (80, 100, 120, 60, 80) {
        &{'main::run_picker_loop'}(\@opts,
            read_key  => sub { 'q' },
            term_size => sub { ($cols, 24) },
            out       => sub { 1 },
        );
        my $size = tui::LaunchScreens::session_card_cache_size();
        $max_size = $size if $size > $max_size;
    }
    cmp_ok($max_size, '<=', $item_count,
        "M2c: session_card_cache_size() never exceeds the $item_count-item count of one width's worth of cards, even after cycling widths 80/100/120/60/80");
});

criterion('M2b: a REPAINT after one cursor keypress on 300 cards with 4096-char messages stays under a tight time bound (median of 3 runs)', sub {
    no strict 'refs';
    require Time::HiRes;
    my @opts = _m2_fixture_opts();
    my @runs_ms;
    for (1 .. 3) {
        # One down-arrow keypress (ESC [ B, three read_key reads per press --
        # the same convention M1 above uses), then quit. read_key is wrapped
        # to timestamp each invocation: the interval between the call that
        # hands back the sequence's FINAL byte ('B', which is when the loop
        # actually dispatches the move and repaints) and the NEXT call (for
        # 'q') brackets exactly the cost of handling the keypress and
        # repainting -- not the first paint, and not the time spent idling
        # in the test harness itself.
        my @keys = ("\e", '[', 'B', 'q');
        my @call_times;
        &{'main::run_picker_loop'}(\@opts,
            read_key  => sub { push @call_times, Time::HiRes::time(); return @keys ? shift @keys : undef; },
            term_size => sub { (80, 24) },
            out       => sub { 1 },
        );
        is(scalar(@call_times), 4,
            'M2b: all four scripted read_key calls were consumed (ESC, [, B, q) -- the repaint window below is well-formed')
            if $_ == 1;   # shape-check once; asserting it 3x adds noise without adding coverage
        my $repaint_ms = (scalar(@call_times) >= 4) ? ($call_times[3] - $call_times[2]) * 1000 : 9e9;
        push @runs_ms, $repaint_ms;
    }
    my $median_ms = _median_ms(@runs_ms);
    cmp_ok($median_ms, '<', 100,
        sprintf('M2b: a repaint after one cursor keypress on 300 cards with 4096-char messages completes in under 100ms ' .
                '(median %.1fms across runs %s)', $median_ms, join(', ', map { sprintf('%.1f', $_) } @runs_ms)));
});

# ============================================================================
# M3 (review must-fix): a read_key that can never block (e.g. EOF on stdin)
# must not spin run_picker_loop forever -- it needs the same IDLE_POLL_LIMIT
# backstop list_run already has.
# ============================================================================
criterion('M3: run_picker_loop with read_key returning undef forever terminates within IDLE_POLL_LIMIT polls', sub {
    no strict 'refs';
    my @opts = &{'main::build_options'}();
    my $limit = eval { tui::LaunchScreens::IDLE_POLL_LIMIT() };
    my $polls = 0;
    my $result;
    my $died = '';
    local $SIG{ALRM} = sub { die "M3 TIMEOUT: run_picker_loop never returned within the alarm bound\n"; };
    alarm(30);
    eval {
        $result = &{'main::run_picker_loop'}(\@opts,
            read_key  => sub { $polls++; return undef; },
            term_size => sub { (80, 24) },
            out       => sub { 1 },
        );
        1;
    } or $died = $@;
    alarm(0);
    is($died, '', 'M3: run_picker_loop returned instead of hanging past the 30s alarm bound') or diag($died);
    cmp_ok($polls, '>', 0, 'M3: run_picker_loop actually polled read_key at least once before terminating');
    ok(defined($limit) && $polls <= $limit,
        'M3: run_picker_loop polled read_key at most IDLE_POLL_LIMIT() times (' . (defined $limit ? $limit : 'undef') . ')');
    is($result, 'CANCEL', 'M3: run_picker_loop returns CANCEL when read_key never yields a key');
});

# ============================================================================
# AC-11: card_window sweep
# ============================================================================
criterion('AC-11: card_window keeps the cursor inside [first,last], respects the budget, and never dies on degenerate input', sub {
    srand(20260926);
    my @bad_contains;
    my @bad_budget;
    my @bad_die;
    for my $n (0 .. 12) {
        my @heights = map { 1 + int(rand(7)) } 1 .. $n;
        for my $budget (1, 5, 10, 20, 40) {
            my $top = 0;
            for my $cursor (0 .. ($n ? $n - 1 : 0)) {
                next unless $n;
                my $w = eval { scalar_ls('card_window', \@heights, $cursor, $budget, $top) };
                if (ref $w ne 'HASH') { push @bad_die, "n=$n cursor=$cursor budget=$budget"; next; }
                my ($first, $last) = (num($w->{first}), num($w->{last}));
                push @bad_contains, "n=$n cursor=$cursor" unless $cursor >= $first && $cursor <= $last;
                my $sum = 0; $sum += $heights[$_] for $first .. $last;
                push @bad_budget, "n=$n cursor=$cursor sum=$sum budget=$budget"
                    unless $sum <= $budget || ($first == $last && $first == $cursor);
                $top = $first;
            }
        }
    }
    is(scalar(@bad_contains), 0, 'AC-11: the cursor is always inside [first,last]') or diag(join("; ", @bad_contains[0..2]));
    is(scalar(@bad_budget), 0, 'AC-11: the summed window heights respect the budget (or the single overflowing item)')
        or diag(join("; ", @bad_budget[0..2]));

    for my $case ([undef, undef, undef, undef], [[], -1, -5, -3], ['not-an-array', 0, 5, 0], [[1,2,3], 99, 5, 0]) {
        my $died = 0;
        my $r = eval { scalar_ls('card_window', @$case); 1 } or $died = 1;
        push @bad_die, "degenerate case died" if $died;
    }
    is(scalar(@bad_die), 0, 'AC-11: degenerate inputs (undef/negative/non-array/out-of-range) never die');

    my $empty = scalar_ls('card_window', [], 0, 10, 0);
    is_deeply($empty, { first => 0, last => -1, above => 0, below => 0 }, 'AC-11: an empty list returns the documented degenerate window');
});

# ============================================================================
# AC-12: listing -- default view hides butler/headless/coordinator/empty
# ============================================================================
criterion('AC-12: listing via the line prompt: default view is NEW+human sessions in last-activity order; butler view holds the rest with kind_label; empty session appears nowhere', sub {
    my $dir = accent_dir();
    my $UUID_A = 'a1000000-0000-0000-0000-000000000001';   # human, 2 messages
    my $UUID_B = 'b2000000-0000-0000-0000-000000000002';   # human, 1 message
    my $UUID_C = 'c3000000-0000-0000-0000-000000000003';   # empty (noise only)
    my $UUID_D = 'd4000000-0000-0000-0000-000000000004';   # headless
    my $UUID_E = 'e5000000-0000-0000-0000-000000000005';   # coordinator (old-style preamble)
    my $UUID_F = 'f6000000-0000-0000-0000-000000000006';   # human, registered -> butler

    write_jsonl("$dir/$UUID_A.jsonl",
        user_rec(sessionId => $UUID_A, timestamp => ts(250), entrypoint => 'cli', content => 'first ask'),
        user_rec(sessionId => $UUID_A, timestamp => ts(300), entrypoint => 'cli', content => 'follow-up ask'),
    );
    write_jsonl("$dir/$UUID_B.jsonl",
        user_rec(sessionId => $UUID_B, timestamp => ts(200), entrypoint => 'cli', content => 'a single request'),
    );
    write_jsonl("$dir/$UUID_C.jsonl",
        user_rec(sessionId => $UUID_C, timestamp => ts(1), entrypoint => 'cli', content => '[Request interrupted by user]'),
        user_rec(sessionId => $UUID_C, timestamp => ts(2), entrypoint => 'cli', content => '<local-command-stdout>x</local-command-stdout>'),
    );
    write_jsonl("$dir/$UUID_D.jsonl",
        user_rec(sessionId => $UUID_D, timestamp => ts(500), entrypoint => 'sdk-cli', promptSource => 'sdk', content => 'summarize the PRs'),
    );
    write_jsonl("$dir/$UUID_E.jsonl",
        user_rec(sessionId => $UUID_E, timestamp => ts(400), content => 'You are a ccpraxis butler coordinator for this run.'),
    );
    write_jsonl("$dir/$UUID_F.jsonl",
        user_rec(sessionId => $UUID_F, timestamp => ts(600), entrypoint => 'cli', content => "a\x{e7}\x{e3}o - revis\x{e3}o do trabalho conjunto"),
    );

    # mtimes set in REVERSE of last-activity order (A=300,B=200,D=500,E=400,F=600
    # -> last-activity desc: F,D,E,A,B -> mtime ascending must be F,D,E,A,B too
    # i.e. oldest mtime on F, newest on B), proving the picker sorts by
    # last_active_at (SessionIndex), never by file mtime.
    my $base = $T0 + 900_000;
    utime($base + 0,  $base + 0,  "$dir/$UUID_F.jsonl");
    utime($base + 10, $base + 10, "$dir/$UUID_D.jsonl");
    utime($base + 20, $base + 20, "$dir/$UUID_E.jsonl");
    utime($base + 30, $base + 30, "$dir/$UUID_A.jsonl");
    utime($base + 40, $base + 40, "$dir/$UUID_B.jsonl");
    utime($base + 5,  $base + 5,  "$dir/$UUID_C.jsonl");

    my $reg_root = write_registry($dir, $UUID_F);

    my $r2 = run_picker_output_content(sessions_dir => $dir, blueprints_dir => $reg_root, input => "2\n");
    is($r2->{content}, "RESUME $UUID_A", 'AC-12: default view option 2 is the newest human session (A)');
    my $r3 = run_picker_output_content(sessions_dir => $dir, blueprints_dir => $reg_root, input => "3\n");
    is($r3->{content}, "RESUME $UUID_B", 'AC-12: default view option 3 is the older human session (B)');
    my $r4 = run_picker_output_content(sessions_dir => $dir, blueprints_dir => $reg_root, input => "4\n");
    is($r4->{content}, 'NEW', 'AC-12: default view has exactly 3 options (NEW,A,B); option 4 is out of range -> NEW');

    for my $u ($UUID_C) {
        unlike($r2->{stderr}, qr/\Q$u\E/, 'AC-12: the empty session never appears in the menu text');
    }
});

# ============================================================================
# AC-13: --list-json shape and non-ASCII round trip
# ============================================================================
criterion('AC-13: --list-json rows are exactly the non-empty sessions, in last-activity order, with the new card shape; non-ASCII first message round-trips', sub {
    my $dir = accent_dir();
    my $UUID_1 = '11111111-0000-0000-0000-000000000001';
    my $UUID_2 = '22222222-0000-0000-0000-000000000002';
    write_jsonl("$dir/$UUID_1.jsonl",
        user_rec(sessionId => $UUID_1, timestamp => ts(100), entrypoint => 'cli', content => "a\x{e7}\x{e3}o - revis\x{e3}o"),
    );
    write_jsonl("$dir/$UUID_2.jsonl",
        user_rec(sessionId => $UUID_2, timestamp => ts(200), entrypoint => 'cli', content => 'a later session'),
    );
    my $r = run_capture('--sessions-dir', $dir, '--project-label', 'proj', '--list-json', { workdir => $dir });
    is($r->{rc}, 0, 'AC-13: --list-json exits 0');
    my $data = eval { $JSON->decode($r->{stdout}) };
    ok(ref $data eq 'HASH', 'AC-13: --list-json prints a decodable JSON object') or diag($r->{stdout});
    my @rows = @{ aref($data->{sessions}) };
    is(scalar(@rows), 2, 'AC-13: exactly the 2 non-empty sessions are listed');
    is($rows[0]{uuid}, $UUID_2, 'AC-13: rows are in last-activity order (newest first)');
    for my $row (@rows) {
        for my $k (qw(uuid mtime is_butler card)) {
            ok(exists $row->{$k}, "AC-13: each row has key '$k'");
        }
        ok(!exists $row->{label}, 'AC-13: no row carries a "label" key');
        for my $ck (qw(started active ago first last kind_label badges)) {
            ok(exists $row->{card}{$ck}, "AC-13: card has key '$ck'");
        }
    }
    my ($row1) = grep { $_->{uuid} eq $UUID_1 } @rows;
    is($row1->{card}{first}, "a\x{e7}\x{e3}o - revis\x{e3}o", 'AC-13: the accented first message decodes character-equal');

    my $empty_dir = accent_dir();
    write_jsonl("$empty_dir/33333333-0000-0000-0000-000000000003.jsonl",
        user_rec(timestamp => ts(1), entrypoint => 'cli', content => '[Request interrupted by user]'));
    my $re = run_capture('--sessions-dir', $empty_dir, '--project-label', 'proj', '--list-json', { workdir => $empty_dir });
    my $data_e = eval { $JSON->decode($re->{stdout}) };
    is_deeply($data_e->{sessions}, [], 'AC-13: a dir with only an empty session -> sessions is empty');
    is($data_e->{error}, undef, 'AC-13: ...and error is null');
});

# ============================================================================
# AC-14: TUI model -- NEW first in both views, [t]/[T], footer, empty_note,
# Enter -> cursor_id
# ============================================================================
criterion('AC-14: session_pick_model + list_dispatch_key: NEW first in both views, lowercase t toggles (T does not), footer legend, empty_note, Enter selection', sub {
    no strict 'refs';
    my @rows = (
        { uuid => 'u1', mtime => 1, is_butler => 0, card => {} },
        { uuid => 'u2', mtime => 2, is_butler => 1, card => {} },
    );
    my $model = scalar_ls('session_pick_model', \@rows, 'resume a session - proj', undef);
    is(ref $model, 'HASH', 'AC-14: session_pick_model returns a hashref') or return;
    is($model->{mode}, 'single', 'AC-14: model mode is single');
    is(scalar(@{ aref($model->{views}) }), 2, 'AC-14: model declares 2 views');
    my ($uview) = grep { bstr(href($_)->{name}) eq 'user' } @{ $model->{views} };
    my ($bview) = grep { bstr(href($_)->{name}) eq 'butler' } @{ $model->{views} };
    is(href(aref($uview->{items})->[0])->{id}, 'NEW', 'AC-14: user view starts with NEW');
    is(href(aref($bview->{items})->[0])->{id}, 'NEW', 'AC-14: butler view starts with NEW');

    my $ls = scalar_ls('list_init', model => $model);
    is(ref $ls, 'HASH', 'AC-14: list_init returns a hashref') or return;
    my $act_t = scalar_ls('list_dispatch_key', $ls, 't');
    is($act_t, 'toggle-view', "AC-14: lowercase 't' returns toggle-view");
    is(scalar_ls('list_apply', $ls, $act_t), 0, "AC-14: list_apply('toggle-view') does not close the screen");
    is(bstr(href($ls)->{view_index}), 1, 'AC-14: view_index flipped to 1 (butler)');
    my $items_now = aref(href($ls)->{items});
    is(bstr(href($items_now->[ num(href($ls)->{cursor}) ])->{id}), 'NEW', 'AC-14: the cursor lands on NEW after toggling');

    my $act_T = scalar_ls('list_dispatch_key', $ls, 'T');
    isnt($act_T, 'toggle-view', "AC-14: uppercase 'T' does NOT toggle");

    my $legend = scalar_ls('LIST_FOOTER_LEGEND', 'single');
    cmp_ok(length(bstr($legend)), '>', 0, 'AC-14: LIST_FOOTER_LEGEND(single) is non-empty');
    my $frame = scalar_ls('compose_list', $ls, 24, 100);
    my $text = join("\n", map { bstr(href($_)->{text}) } @{ aref($frame) });
    like($text, qr/view: butler\s+\[t\] show user sessions/, 'AC-14: footer names the butler view and offers to show user sessions');
    cmp_ok(index_of($text, $legend), '>=', 0, 'AC-14: the footer includes LIST_FOOTER_LEGEND(single)');

    my $empty_rows = [ { uuid => 'only-user', mtime => 1, is_butler => 0, card => {} } ];
    my $empty_model = scalar_ls('session_pick_model', $empty_rows, 'lbl', undef);
    my $ls2 = scalar_ls('list_init', model => $empty_model);
    scalar_ls('list_dispatch_key', $ls2, 't');   # -> butler view, which has only NEW
    my $frame2 = scalar_ls('compose_list', $ls2, 24, 100);
    my $text2 = join("\n", map { bstr(href($_)->{text}) } @{ aref($frame2) });
    like($text2, qr/\Q(no butler sessions)\E/, 'AC-14: an empty view shows its empty_note');

    my ($row_idx) = grep { bstr(href($items_now->[$_])->{id}) eq 'NEW' } 0 .. $#$items_now;
    $ls->{cursor} = $row_idx;
    scalar_ls('list_dispatch_key', $ls, 'ENTER');
    my $dec = href(scalar_ls('list_selection', $ls));
    is($dec->{cursor_id}, 'NEW', 'AC-14: Enter on the NEW row gives cursor_id NEW');
});

# ============================================================================
# AC-15: compose_list card-mode frame invariants
# ============================================================================
criterion('AC-15: compose_list in card mode -- exact frame length, exact cell width, and +N below agrees with card_window', sub {
    no strict 'refs';
    my @rows = map { { uuid => "u$_", mtime => $_, is_butler => 0,
                        card => { started => '2026-01-01 10:00', active => '2026-01-01 10:0' . ($_ % 9), ago => "${_}m ago", first => "message $_", last => undef, kind_label => undef, badges => [] } } } 1 .. 15;
    my $model = scalar_ls('session_pick_model', \@rows, 'lbl', undef);
    for my $cols (60, 80, 120) {
        my $ls = scalar_ls('list_init', model => $model);
        my $frame = scalar_ls('compose_list', $ls, 30, $cols);
        is(scalar(@{ aref($frame) }), 30, "AC-15: at cols=$cols the frame has exactly 30 rows");
        my $bad = 0;
        for my $c (@{ aref($frame) }) {
            my $w = eval { tui::Layout::display_width(bstr(href($c)->{text})) };
            $bad++ unless defined $w && $w == $cols;
        }
        is($bad, 0, "AC-15: at cols=$cols every cell is exactly $cols display columns wide");
    }
});

# ============================================================================
# AC-16: non-ASCII -- Latin survives verbatim, CJK degrades to '?'
# ============================================================================
criterion(q{AC-16: "acao - revisao do codigo <CJK>" renders the Latin verbatim and each CJK char as '?', within cols}, sub {
    my $msg = "a\x{e7}\x{e3}o \x{2014} revis\x{e3}o do c\x{f3}digo \x{65e5}\x{672c}";
    my $card = mk_card(first => $msg, last => undef);
    my $lines = scalar_ls('session_card_lines', $card, 80, 0);
    my $text = joined_text($lines);
    # $text is a UTF-8 BYTE string (tui::Frame::safe Encode::encode's it) --
    # decode it back to code points before matching a \x{..} code-point
    # regex, or the accented bytes (e.g. \xc3\xa7 for e-cedilla) never equal
    # the single code point 0xe7.
    my $text_cp = decode('UTF-8', $text);
    like($text_cp, qr/a\x{e7}\x{e3}o \x{2014} revis\x{e3}o do c\x{f3}digo/, 'AC-16: the accented Latin substring renders verbatim');
    like($text_cp, qr/\?\?/, 'AC-16: the two CJK characters each degrade to a literal ?');
    my $bad = grep { line_width($_) > 80 } @$lines;
    is($bad, 0, 'AC-16: every line stays within 80 columns despite the multi-byte source text');

    no strict 'refs';
    my @opts = &{'main::build_options'}( { uuid => 'x', mtime => 1, kind => 'human',
        started_at => $T0, last_active_at => $T0, first_typed => $msg, last_typed => undef, same_message => 0 } );
    my @keys = ('q');
    my $out_buf = '';
    &{'main::run_picker_loop'}(\@opts,
        read_key  => sub { @keys ? shift @keys : undef },
        term_size => sub { (80, 24) },
        out       => sub { $out_buf .= $_[0]; 1 },
    );
    unlike($out_buf, qr/\x{e6}\x{97}\x{a5}/, 'AC-16: the plain loop never paints the raw CJK UTF-8 bytes');
});

# ============================================================================
# AC-17: narrow and degenerate cards never die/warn; height stays 3..6
# ============================================================================
criterion('AC-17: session_card_lines never dies or warns for cols 1..200, selected 0/1, hostile card shapes; compose_list card mode never miscounts rows for rows 1..40', sub {
    my @shapes = (
        {},
        { started => undef, active => undef, ago => undef, first => undef, last => undef, kind_label => undef, badges => 'not-an-array' },
        mk_card(first => ('z' x 5000), last => ('y' x 5000), badges => [ { text => 'x', role => 'bogus' } ]),
    );
    my ($died, $warned, $bad_height, $bad_width) = (0, 0, 0, 0);
    for my $cols (1 .. 200) {
        for my $sel (0, 1) {
            for my $card (@shapes) {
                my $w = warn_count_of(sub {
                    my $lines = eval { scalar_ls('session_card_lines', $card, $cols, $sel) };
                    if (!ref $lines) { $died++; return; }
                    my $h = scalar(@$lines);
                    $bad_height++ unless $h >= 3 && $h <= 6;
                    for my $l (@$lines) { $bad_width++ if line_width($l) > $cols; }
                });
                $warned += $w;
            }
        }
    }
    is($died, 0, 'AC-17: session_card_lines never dies across cols 1..200 x selected x hostile shapes');
    is($warned, 0, 'AC-17: session_card_lines never warns');
    is($bad_height, 0, 'AC-17: card height is always 3..6 lines');
    is($bad_width, 0, 'AC-17: no line ever exceeds cols');

    no strict 'refs';
    my @rows = map { { uuid => "u$_", mtime => $_, is_butler => 0, card => {} } } 1 .. 5;
    my $model = scalar_ls('session_pick_model', \@rows, 'lbl', undef);
    my $rowcount_bad = 0;
    for my $rows2 (1 .. 40) {
        for my $cols2 (1, 2, 10, 20, 40) {
            my $ls = scalar_ls('list_init', model => $model);
            my $f = eval { scalar_ls('compose_list', $ls, $rows2, $cols2) };
            $rowcount_bad++ unless ref $f eq 'ARRAY' && scalar(@$f) == $rows2;
        }
    }
    is($rowcount_bad, 0, 'AC-17: compose_list card mode returns exactly $rows cells for rows 1..40 at narrow/degenerate widths');
});

# ============================================================================
# AC-18: sanitisation -- ESC/BEL/C1/OSC never reach the terminal as control
# bytes on the plain loop's painted output
# ============================================================================
criterion('AC-18: control bytes and OSC 52 in a first message never reach the plain loop\'s painted output as control bytes', sub {
    no strict 'refs';
    my $hostile = "before\e[2Jafter\x07bel\x9bC1osc\e]52;c;AAAA==\e\\end";
    my @opts = &{'main::build_options'}( { uuid => 'x', mtime => 1, kind => 'human',
        started_at => $T0, last_active_at => $T0, first_typed => $hostile, last_typed => undef, same_message => 0 } );
    my @keys = ('q');
    my $out_buf = '';
    &{'main::run_picker_loop'}(\@opts,
        read_key  => sub { @keys ? shift @keys : undef },
        term_size => sub { (80, 24) },
        out       => sub { $out_buf .= $_[0]; 1 },
    );
    (my $stripped = $out_buf) =~ s/\e\[H//g;
    $stripped =~ s/\e\[2J//g;
    $stripped =~ s/\e\[K//g;
    $stripped =~ s/\e\[J//g;
    $stripped =~ s/\e\[[0-9;]*m//g;
    my $bad_esc = () = $stripped =~ /\e/g;
    is($bad_esc, 0, 'AC-18: no ESC byte remains once the frame\'s own control/SGR sequences are stripped');
    # "\r\n" is the S1 fix's legitimate row separator, not a hostile control
    # byte -- strip PAIRED \r\n before scanning so it isn't misjudged as a
    # bad C0 byte. A LONE \r (never paired with \n) is NOT stripped by this
    # and still falls through to the grep below exactly as before.
    (my $c0_src = $stripped) =~ s/\r\n//g;
    my $bad_c0 = grep { ord($_) < 0x20 && $_ ne "\n" } split //, $c0_src;
    is($bad_c0, 0, 'AC-18: no C0 control byte (other than newline, and \r only when paired as a legitimate \r\n row separator) remains');
    {
        # Counter-fixture (anti-vacuity): a LONE \r -- never paired with \n --
        # must still be flagged as a bad C0 byte by this exact detection
        # logic, proving the \r\n stripping above does not blanket-exempt
        # every \r and only tolerates the paired row-separator shape.
        my $lone_cr = "before\rafter";
        (my $c0_probe = $lone_cr) =~ s/\r\n//g;
        my $bad_c0_probe = grep { ord($_) < 0x20 && $_ ne "\n" } split //, $c0_probe;
        cmp_ok($bad_c0_probe, '>', 0,
            'AC-18 counter-fixture: a lone \r (not part of a \r\n pair) is still flagged as a bad C0 byte');
    }
    # C1 (U+0080-U+009F) is a CODE-POINT range, but $stripped is still a
    # UTF-8 BYTE string (tui::Frame::safe Encode::encode's it): a raw
    # per-byte scan flags 0x96, which is a UTF-8 CONTINUATION byte of the
    # U+25B6 cursor glyph (bytes e2 96 b6), not a C1 control byte. Decode to
    # code points first, then check the C1 range.
    my $stripped_cp = decode('UTF-8', $stripped);
    my $bad_c1 = grep { ord($_) >= 0x80 && ord($_) <= 0x9f } split //, $stripped_cp;
    is($bad_c1, 0, 'AC-18: no C1 control byte remains');
});

# ============================================================================
# AC-19: badges extension point
# ============================================================================
criterion("AC-19: a card with badges shows ' [host]' (accent) and ' [x]' (text.muted, unknown role) on line 1, surviving at 60 cols too", sub {
    my $card = mk_card(badges => [ { text => 'host', role => 'accent' }, { text => 'x', role => 'bogus' } ]);
    for my $cols (80, 60) {
        my $lines = scalar_ls('session_card_lines', $card, $cols, 0);
        ok(has_span($lines, ' [host]', 'accent'),     "AC-19: at $cols cols the host badge is accent");
        ok(has_span($lines, ' [x]', 'text.muted'),    "AC-19: at $cols cols the unknown-role badge falls back to text.muted");
    }
});

# ============================================================================
# AC-20: launcher.pl wiring, by SOURCE TEXT only (never spawned)
# ============================================================================
criterion('AC-20: launcher.pl source calls session_pick_model, no longer reads ->{label}; pick_session_action\'s plain-path argv is unchanged', sub {
    open my $fh, '<:raw', $LAUNCHER or die "read $LAUNCHER: $!";
    local $/; my $src = <$fh>; close $fh;
    (my $stripped = $src) =~ s/^[ \t]*#.*$//mg;

    cmp_ok(index_of($stripped, 'tui::LaunchScreens::session_pick_model'), '>=', 0,
        'AC-20: launcher.pl calls tui::LaunchScreens::session_pick_model');

    my ($pick_body) = ($stripped =~ /sub\s+_pick_session_via_screen\s*\{(.*?)\n\}/s);
    ok(defined $pick_body, 'AC-20: liveness: _pick_session_via_screen is found in the source')
        or diag('could not isolate the sub body -- check the regex against source drift');
    if (defined $pick_body) {
        unlike($pick_body, qr/->\{label\}/, 'AC-20: _pick_session_via_screen no longer reads ->{label}');
    }

    for my $flag (qw(--sessions-dir --project-label --output)) {
        cmp_ok(index_of($stripped, $flag), '>=', 0, "AC-20: pick_session_action's plain spawn still passes $flag");
    }
});

# ============================================================================
# AC-21: output-file contract (plain loop, spawned)
# ============================================================================
criterion('AC-21: output-file contract: choosing a number resumes it, q cancels (exit 2), an all-empty dir writes NEW; menu labels carry no 8-hex uuid column', sub {
    my $dir = accent_dir();
    my $UUID_NEWEST = 'e1000000-0000-0000-0000-000000000001';
    my $UUID_OLDER  = 'e2000000-0000-0000-0000-000000000002';
    write_jsonl("$dir/$UUID_NEWEST.jsonl", user_rec(sessionId => $UUID_NEWEST, timestamp => ts(200), entrypoint => 'cli', content => 'newest ask'));
    write_jsonl("$dir/$UUID_OLDER.jsonl",  user_rec(sessionId => $UUID_OLDER,  timestamp => ts(100), entrypoint => 'cli', content => 'older ask'));

    my $r2 = run_picker_output_content(sessions_dir => $dir, input => "2\n");
    is($r2->{content}, "RESUME $UUID_NEWEST", 'AC-21: choosing 2 resumes the newest session');
    unlike($r2->{stderr}, qr/[0-9a-f]{8}/, 'AC-21: menu text carries no 8-hex uuid column');
    like($r2->{stderr}, qr/\[1\]/, 'AC-21: menu text contains [1]');
    unlike($r2->{stderr}, qr/\e/, "AC-21: the line prompt's STDERR contains no ESC byte");

    my $rq = run_picker_output_content(sessions_dir => $dir, input => "q\n");
    is($rq->{rc}, 2, "AC-21: 'q' exits 2");

    my $empty_dir = accent_dir();
    write_jsonl("$empty_dir/33333333-0000-0000-0000-000000000009.jsonl",
        user_rec(timestamp => ts(1), entrypoint => 'cli', content => '[Request interrupted by user]'));
    my $re = run_picker_output_content(sessions_dir => $empty_dir, input => "1\n");
    is($re->{content}, 'NEW', 'AC-21: an all-empty dir writes NEW');
    is($re->{rc}, 0, 'AC-21: ...and exits 0');
});

# ============================================================================
# AC-22: select-session.pl source contains no SGR literal / ReadKey(0)
# ============================================================================
criterion('AC-22: select-session.pl source contains no SGR colour literal and no blocking ReadKey(0)', sub {
    open my $fh, '<:raw', $SCRIPT or die "read $SCRIPT: $!";
    local $/; my $src = <$fh>; close $fh;
    (my $stripped = $src) =~ s/^[ \t]*#.*$//mg;

    for my $lit ("\e[1;36m", "\e[1m", "\e[2m") {
        is(count_sub($stripped, $lit), 0, 'AC-22: no SGR literal ' . join('', map { sprintf('\\x%02x', ord $_) } split //, $lit) . ' remains');
    }
    unlike($stripped, qr/ReadKey\s*\(\s*0\s*\)/, 'AC-22: no blocking ReadKey(0) call remains');

    # counter-fixture: the same detector DOES fire on a hand-built literal,
    # proving the zero counts above are real and not a broken scanner.
    my $counter = "some code \e[1;36mNEW\e[0m more code";
    cmp_ok(count_sub($counter, "\e[1;36m"), '>', 0, 'AC-22 counter-fixture: the literal detector fires on a fixture that has the literal');
});

# ============================================================================
# AC-23 note: select-session-viewport.t / session-filter.t (and
# launcher-screens.t / wrap-on-overflow.t / session-index-classify.t) are the
# IMPLEMENTER's edit targets per the coordinator's instruction, not this
# file's. This file deliberately does not spawn or require any other test
# file (no test may run other tests) -- AC-23's "run one by one, green" is
# verified by running those files directly, outside this suite.
# ============================================================================

done_testing();
