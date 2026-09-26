# BpPricing.pm -- fresh Anthropic pricing acquisition + parsing, for
# blueprint spend-token-report, package 01-token-columns-fresh-pricing.
# Spec: .ccpraxis-local-data/blueprints/spend-token-report/specs/
# 01-token-columns-fresh-pricing-spec.md
#
# NO SIDE EFFECTS AT LOAD TIME: no process spawn, no network, no file I/O,
# and bp-http.pl/HTTP::Tiny are never required at module load -- only lazily,
# inside acquire()'s live-fetch rung.
#
# Acquisition precedence (Decision 16, spec Sec2.2): CCPRAXIS_SPEND_PRICING_FILE,
# then --offline/CCPRAXIS_SPEND_NO_FETCH (offline), then a live fetch via the
# CCPRAXIS_SPEND_FETCH_CMD transport seam (Decision 21) or bp-http.pl (curl).
package BpPricing;
use strict;
use warnings;
use File::Basename qw(dirname);
use Cwd qw(abs_path);

our $SOURCE_URL = 'https://platform.claude.com/docs/en/about-claude/pricing.md';
our $MAX_BYTES  = 5_000_000;
our @RATE_TYPES       = qw(input cache_write_5m cache_write_1h cache_read output);
our @UNPRICED_REASONS = qw(unknown-model cache-write-unsplit non-standard-speed
                           rate-missing offline pricing-unavailable
                           fast-long-context-unspecified);

my $DIR = dirname(do { (my $f = __FILE__) =~ s{\\}{/}g; abs_path($f) // $f });

# ---------------------------------------------------------------------------
# _iso($epoch) -> 'YYYY-MM-DDTHH:MM:SSZ' (UTC).
# ---------------------------------------------------------------------------
sub _iso {
    my ($t) = @_;
    my @g = gmtime($t);
    return sprintf('%04d-%02d-%02dT%02d:%02d:%02dZ', $g[5] + 1900, $g[4] + 1, $g[3], $g[2], $g[1], $g[0]);
}

# ---------------------------------------------------------------------------
# offline() / unavailable($reason,$source) -> the two "no rates" shapes.
# ---------------------------------------------------------------------------
sub offline {
    return {
        status => 'offline', reason => undef, source => undef, fetched_at => undef,
        models => {}, long_context => { threshold_tokens => undef, unresolved => 0, models => {}, note => undef },
        fast   => { models => {} },
    };
}

sub unavailable {
    my ($reason, $source) = @_;
    $reason = defined($reason) ? $reason : '';
    $reason =~ s/[\x00-\x1f\x7f]//g;
    $reason = substr($reason, 0, 200) if length($reason) > 200;
    return {
        status => 'unavailable', reason => $reason, source => $source, fetched_at => undef,
        models => {}, long_context => { threshold_tokens => undef, unresolved => 0, models => {}, note => undef },
        fast   => { models => {} },
    };
}

sub _tag_override {
    my ($doc, $flag) = @_;
    $doc->{price_fetch_override} = $flag ? 1 : 0;
    return $doc;
}

sub status_string {
    my ($p) = @_;
    return 'ok'      if $p->{status} eq 'ok';
    return 'offline' if $p->{status} eq 'offline';
    return "unavailable: " . (defined($p->{reason}) ? $p->{reason} : '');
}

# ---------------------------------------------------------------------------
# acquire(%o) -> $p. %o: offline=>0|1, now=>EPOCH (default time). Spec Sec2.2.
# ---------------------------------------------------------------------------
sub acquire {
    my (%o) = @_;
    # S3 (fix-batch review): spec Sec2.1 says none of these ever dies. The
    # require, the transport calls and parsing all run inside eval, so a
    # missing/broken bp-http.pl or an unexpected die inside parsing gives
    # unavailable rather than aborting the caller before any token column
    # prints.
    my $doc = eval { _acquire_impl(%o) };
    if (!defined $doc) {
        (my $err = defined($@) ? "$@" : 'unknown error') =~ s/\s+\z//;
        return _tag_override(unavailable("internal error: $err"), 0);
    }
    return $doc;
}

sub _acquire_impl {
    my (%o) = @_;
    my $now = defined($o{now}) ? $o{now} : time;

    my $file = $ENV{CCPRAXIS_SPEND_PRICING_FILE};
    if (defined($file) && $file ne '') {
        my $ok = open(my $fh, '<:raw', $file);
        unless ($ok) {
            return unavailable("pricing file unreadable: $file", "file:$file");
        }
        local $/;
        my $bytes = <$fh>;
        close $fh;
        return _tag_override(parse_document($bytes, source => "file:$file", fetched_at => _iso($now)), 0);
    }

    my $no_fetch = $ENV{CCPRAXIS_SPEND_NO_FETCH};
    my $no_fetch_truthy = defined($no_fetch) && $no_fetch ne '' && $no_fetch ne '0';
    if ($o{offline} || $no_fetch_truthy) {
        return _tag_override(offline(), 0);
    }

    require "$DIR/bp-http.pl";

    my ($status, $content);
    my $seam = $ENV{CCPRAXIS_SPEND_FETCH_CMD};
    my $override = (defined($seam) && $seam ne '') ? 1 : 0;
    if ($override) {
        my @argv = ($seam =~ /\.pl\z/) ? ($^X, $seam, $SOURCE_URL) : ($seam, $SOURCE_URL);
        my $pid = open(my $fh, '-|', @argv);
        unless ($pid) {
            return _tag_override(unavailable("fetch command could not be run: $!", $SOURCE_URL), $override);
        }
        local $/;
        my $out = <$fh>;
        $out = '' unless defined $out;
        close $fh;
        my $rc = $? >> 8;
        if ($rc != 0) {
            return _tag_override(unavailable("fetch command exited $rc", $SOURCE_URL), $override);
        }
        ($status, $content) = BpHttp::parse_response($out);
    }
    else {
        my $r = BpHttp::request('GET', $SOURCE_URL, {});
        $status  = $r->{status};
        $content = $r->{content};
    }

    if (!$status) {
        return _tag_override(
            unavailable("transport failed: " . substr(defined($content) ? $content : '', 0, 200), $SOURCE_URL),
            $override);
    }
    if ($status < 200 || $status > 299) {
        return _tag_override(unavailable("HTTP $status", $SOURCE_URL), $override);
    }
    if (!defined($content) || $content eq '') {
        return _tag_override(unavailable("empty response", $SOURCE_URL), $override);
    }
    if (length($content) > $MAX_BYTES) {
        return _tag_override(unavailable("response too large", $SOURCE_URL), $override);
    }
    return _tag_override(parse_document($content, source => $SOURCE_URL, fetched_at => _iso(time)), $override);
}

# ===========================================================================
# Cleaning (spec Sec2.3).
# ===========================================================================
sub _clean {
    my ($s) = @_;
    return '' unless defined $s;
    # Footnote markers (Decision 23): strip before anything else touches the
    # cell, so a stray digit never survives into a rate. Covers HTML <sup>N</sup>
    # (the real page's form), markdown reference footnotes [^N], pandoc-style
    # caret superscripts attached to a token (e.g. MTok^1^ or MTok^1), and
    # Unicode superscript digits.
    $s =~ s/<sup\b[^>]*>.*?<\/sup>//gis;
    $s =~ s/\[\^\d+\]//g;
    $s =~ s/(?<=\S)\^\d+\^?//g;
    # N1 (fix-batch review): match the UTF-8 byte sequences, not the
    # decoded codepoints -- the document is never decoded (spec Sec2.3), so
    # a \x{...} class here matched single bytes and corrupted the following
    # continuation byte of any real multi-byte character (e.g. an accented
    # letter) that happened to start with 0xC2.
    $s =~ s/\xC2[\xB2\xB3\xB9]|\xE2\x81[\xB0\xB4-\xB9]//g;
    $s =~ s/\[([^\]]*)\]\([^)]*\)/$1/g;
    $s =~ s/\*\*//g;
    $s =~ s/__//g;
    $s =~ s/`//g;
    $s =~ s/<[^>]+>//g;
    $s =~ s/&lt;/</gi;
    $s =~ s/&gt;/>/gi;
    $s =~ s/&quot;/"/gi;
    $s =~ s/&#39;/'/g;
    $s =~ s/&apos;/'/gi;
    $s =~ s/&nbsp;/ /gi;
    $s =~ s/&le;/<=/gi;
    $s =~ s/&ge;/>=/gi;
    $s =~ s/&dollar;/\$/gi;
    $s =~ s/&#x([0-9a-fA-F]+);/ my $n = hex($1); $n < 128 ? chr($n) : "&#x$1;" /ge;
    $s =~ s/&#(\d+);/ my $n = $1; $n < 128 ? chr($n) : "&#$n;" /ge;
    $s =~ s/&amp;/&/gi;
    $s =~ s/\xE2\x89\xA4/<=/g;
    $s =~ s/\xE2\x89\xA5/>=/g;
    $s =~ s/\xC2\xA0/ /g;
    $s =~ s/\s+/ /g;
    $s =~ s/^\s+//;
    $s =~ s/\s+$//;
    return $s;
}

# ===========================================================================
# Extraction: document to an ordered event list (spec Sec2.3).
# ===========================================================================
sub _split_cells {
    my ($line) = @_;
    my @parts = split /(?<!\\)\|/, $line;
    shift @parts if @parts && $parts[0] =~ /^\s*$/;
    pop @parts   if @parts && $parts[-1] =~ /^\s*$/;
    return [ map { _clean($_) } @parts ];
}

sub _extract_markdown_events {
    my ($bytes) = @_;
    my @lines = split /\n/, $bytes;
    my @events;
    my $i = 0;
    my $in_fence = 0;
    while ($i <= $#lines) {
        my $line = $lines[$i];
        if ($line =~ /^\s*(?:```|~~~)/) {
            # S2: a fenced code block is never scanned for headings, tables
            # or text -- a `# comment` inside a code sample must never start
            # or end a section.
            $in_fence = !$in_fence;
            $i++;
            next;
        }
        if ($in_fence) {
            $i++;
            next;
        }
        if ($line =~ /^(#{1,6})\s+(.*?)\s*$/) {
            push @events, { kind => 'heading', level => length($1), text => _clean($2) };
            $i++;
            next;
        }
        if ($line =~ /^\s*\|/
            && $i + 1 <= $#lines
            && $lines[$i + 1] =~ /^\s*\|?\s*:?-{3,}:?\s*(\|\s*:?-{3,}:?\s*)*\|?\s*$/) {
            my $header = _split_cells($line);
            my $j = $i + 2;
            my @rows;
            while ($j <= $#lines && $lines[$j] =~ /^\s*\|/) {
                push @rows, _split_cells($lines[$j]);
                $j++;
            }
            push @events, { kind => 'table', header => $header, rows => \@rows };
            $i = $j;
            next;
        }
        if ($line =~ /\S/) {
            push @events, { kind => 'text', text => _clean($line) };
        }
        $i++;
    }
    return \@events;
}

sub _html_cells {
    my ($tr) = @_;
    my @cells = ($tr =~ /<t[hd]\b[^>]*>(.*?)<\/t[hd]>/gis);
    return [ map { _clean($_) } @cells ];
}

sub _extract_html_events {
    my ($bytes) = @_;
    my @events;
    my $re = qr/(<h([1-6])\b[^>]*>(.*?)<\/h\2>)|(<table\b.*?<\/table>)|(<(?:p|li)\b[^>]*>(.*?)<\/(?:p|li)>)/is;
    while ($bytes =~ /$re/g) {
        if (defined $2) {
            push @events, { kind => 'heading', level => $2 + 0, text => _clean($3) };
        }
        elsif (defined $4) {
            my $table = $4;
            my @trs = ($table =~ /<tr\b.*?<\/tr>/gis);
            my $header = @trs ? _html_cells(shift @trs) : [];
            my @rows = map { _html_cells($_) } @trs;
            push @events, { kind => 'table', header => $header, rows => \@rows };
        }
        elsif (defined $6) {
            push @events, { kind => 'text', text => _clean($6) };
        }
    }
    return \@events;
}

sub _extract_events {
    my ($bytes) = @_;
    return ($bytes =~ /<table\b/i) ? _extract_html_events($bytes) : _extract_markdown_events($bytes);
}

# ===========================================================================
# Header classification (spec Sec2.4).
# ===========================================================================
sub _classify_header {
    my ($h) = @_;
    return undef unless defined $h;
    return 'model'          if $h =~ /\bmodel\b/i;
    return 'cache_write_5m' if $h =~ /cache/i && $h =~ /write/i && $h =~ /\b5\s*-?\s*m(?:in(?:ute)?s?)?\b/i;
    return 'cache_write_1h' if $h =~ /cache/i && $h =~ /write/i && $h =~ /\b1\s*-?\s*h(?:our|r)?s?\b/i;
    return 'cache_read'     if $h =~ /cache/i && $h =~ /(?:hit|read)/i;
    return 'output'         if $h =~ /output/i;
    return 'input'          if $h =~ /input/i && $h !~ /cache/i;
    return undef;
}

sub _side {
    my ($h) = @_;
    return undef unless defined $h;
    my $over  = ($h =~ /[>]/ || $h =~ /exceed|above|over|more than/i) ? 1 : 0;
    my $under = ($h =~ /[<]/ || $h =~ /up to|under|below|at most/i)  ? 1 : 0;
    return undef if $over && $under;
    return 'over'  if $over;
    return 'under' if $under;
    return undef;
}

sub parse_rate {
    my ($cell) = @_;
    return undef unless defined $cell;
    my @m = ($cell =~ /\$\s*(\d+(?:\.\d+)?)\s*(?:\/|per)\s*MTok\b/gi);
    return undef unless @m == 1;
    my $v = $m[0] + 0;
    return undef unless $v > 0;
    return $v;
}

sub _rates_equal {
    my ($a, $b) = @_;
    for my $k (qw(input cache_write_5m cache_write_1h cache_read output)) {
        my ($x, $y) = ($a->{$k}, $b->{$k});
        return 0 if (defined($x) ? 1 : 0) != (defined($y) ? 1 : 0);
        return 0 if defined($x) && $x != $y;
    }
    return 1;
}

# ===========================================================================
# Model id normalisation (spec Sec2.5).
# ===========================================================================
sub normalise_model_id {
    my ($raw) = @_;
    return undef if !defined($raw) || ref($raw) || $raw eq '';
    my $id = lc($raw);
    $id =~ s/^\s+//;
    $id =~ s/\s+$//;
    $id =~ s/\[[^\]]*\]\z//;
    $id =~ s/-\d{8}\z//;
    return $id;
}

sub page_model_id {
    my ($cell) = @_;
    return undef unless defined $cell;
    if ($cell =~ /\b(claude-[a-z0-9][a-z0-9.-]*[a-z0-9](?:\[[^\]]*\])?)/i) {
        return normalise_model_id($1);
    }
    if ($cell =~ /\A\s*Claude\s+([A-Za-z]+)\s+(\d+(?:\.\d+)*)\b/) {
        my ($fam, $ver) = (lc($1), $2);
        $ver =~ s/\./-/g;
        return normalise_model_id("claude-$fam-$ver");
    }
    return undef;
}

# ===========================================================================
# Sections (spec Sec2.4): events after a matching heading up to the next
# heading of level <= that heading's own level.
# ===========================================================================
sub _sections_for {
    my ($events, $re) = @_;
    my @sections;
    for my $i (0 .. $#$events) {
        my $ev = $events->[$i];
        next unless $ev->{kind} eq 'heading' && $ev->{text} =~ $re;
        my $level = $ev->{level};
        my @sec;
        for my $j ($i + 1 .. $#$events) {
            my $e2 = $events->[$j];
            last if $e2->{kind} eq 'heading' && $e2->{level} <= $level;
            push @sec, $e2;
        }
        push @sections, \@sec;
    }
    return @sections;
}

sub _collect_thresholds {
    my ($text, $found) = @_;
    return unless defined $text;
    while ($text =~ /(?:>=?|exceed(?:s|ing)?|over|above|more than)\s*(\d+(?:\.\d+)?)\s*([KM])\b/gi) {
        my ($n, $u) = ($1, $2);
        my $val = (uc($u) eq 'K') ? $n * 1000 : $n * 1_000_000;
        $found->{ int($val) } = 1;
    }
    while ($text =~ /(?:>=?|exceed(?:s|ing)?|more than)\s*(\d{1,3}(?:,\d{3})+)\s+(?:input\s+)?tokens?/gi) {
        (my $d = $1) =~ s/,//g;
        $found->{ $d + 0 } = 1;
    }
}

# ---------------------------------------------------------------------------
# _prose_has_rate($text) -> true when a $-rate ($N / MTok or $N per MTok)
# appears anywhere in the text (M3, fix-batch review).
# ---------------------------------------------------------------------------
sub _prose_has_rate {
    my ($text) = @_;
    return 0 unless defined $text;
    return $text =~ /\$\s*\d+(?:\.\d+)?\s*(?:\/|per)\s*MTok\b/i ? 1 : 0;
}

# ---------------------------------------------------------------------------
# _prose_has_threshold_signal($text) -> true when the text names a token
# threshold in any wording the strict _collect_thresholds regex might miss
# (M3): "over 200,000 input tokens" has no K/M suffix and used a comparison
# word _collect_thresholds' comma-number branch does not accept, but it is
# still a threshold statement, and the standard-pricing sentinel must not
# apply to a section that names one that the parser could not resolve.
# ---------------------------------------------------------------------------
sub _prose_has_threshold_signal {
    my ($text) = @_;
    return 0 unless defined $text;
    return $text =~ /(?:>=?|exceed(?:s|ing)?|over|above|beyond|more\s+than)
                      \s*\d[\d,.]*\s*(?:[KM]\b)?\s*(?:input\s+)?tokens?\b/xi ? 1 : 0;
}

# ---------------------------------------------------------------------------
# _parse_long_context(\@events) -> ($threshold_or_error, $unresolved, \%models, \%conflicted)
# $threshold_or_error is either an integer, undef (no LC section at all), or
# a hashref { error => STR } when the threshold could not be resolved.
# ---------------------------------------------------------------------------
sub _parse_long_context {
    my ($events) = @_;
    my @sections = _sections_for($events, qr/long[\s-]*context/i);
    return (undef, 0, {}, {}) unless @sections;

    my %found;
    for my $sec (@sections) {
        for my $ev (@$sec) {
            if ($ev->{kind} eq 'text') {
                _collect_thresholds($ev->{text}, \%found);
            }
            elsif ($ev->{kind} eq 'table') {
                _collect_thresholds($_, \%found) for @{ $ev->{header} };
            }
        }
    }
    my @distinct = keys %found;
    my $threshold;
    if (@distinct == 0) {
        # Decision 23/M3 (fix-batch review): a long-context section with no
        # threshold sentence and no rate table is standard pricing ONLY when
        # the section's prose explicitly says so -- absence alone is a guess,
        # not the page stating the rate. A section with a $-rate or any
        # token-threshold wording the parser could not turn into a rule
        # (even one _collect_thresholds' strict regex missed) is never
        # folded into "standard": it is unreadable, not silent.
        my $has_table = 0;
        my $prose = '';
        for my $sec (@sections) {
            for my $ev (@$sec) {
                $has_table = 1 if $ev->{kind} eq 'table';
                $prose .= ' ' . $ev->{text} if $ev->{kind} eq 'text' && defined $ev->{text};
            }
        }
        if (!$has_table
            && $prose =~ /\bstandard\s+pric/i
            && !_prose_has_rate($prose)
            && !_prose_has_threshold_signal($prose)) {
            return ({ standard => 1 }, 0, {}, {});
        }
        return ({ error => 'long-context threshold not found' }, 0, {}, {});
    }
    elsif (@distinct > 1) {
        return ({ error => 'long-context threshold ambiguous' }, 0, {}, {});
    }
    else {
        $threshold = $distinct[0] + 0;
    }

    my %models;
    my %conflicted;
    my $any_table = 0;
    for my $sec (@sections) {
        for my $ev (@$sec) {
            next unless $ev->{kind} eq 'table';
            my (@model_idx, @input_over, @output_over, %cache_over);
            for my $i (0 .. $#{ $ev->{header} }) {
                my $h = $ev->{header}[$i];
                my $m = _classify_header($h);
                next unless $m;
                if ($m eq 'model') { push @model_idx, $i; next; }
                my $side = _side($h);
                next unless defined($side) && $side eq 'over';
                if    ($m eq 'input')  { push @input_over, $i; }
                elsif ($m eq 'output') { push @output_over, $i; }
                else  { $cache_over{$m} = $i unless exists $cache_over{$m}; }
            }
            next unless @model_idx == 1 && @input_over == 1 && @output_over == 1;
            $any_table = 1;
            my ($mi, $ii, $oi) = ($model_idx[0], $input_over[0], $output_over[0]);
            for my $row (@{ $ev->{rows} }) {
                my $id = page_model_id($row->[$mi]);
                next unless defined $id;
                my %rates;
                $rates{input}  = parse_rate($row->[$ii]);
                $rates{output} = parse_rate($row->[$oi]);
                for my $cm (keys %cache_over) {
                    my $cidx = $cache_over{$cm};
                    $rates{$cm} = parse_rate($row->[$cidx]) if defined $row->[$cidx];
                }
                next if !defined($rates{input}) || !defined($rates{output});
                if (exists $models{$id}) {
                    unless (_rates_equal($models{$id}, \%rates)) {
                        delete $models{$id};
                        $conflicted{$id} = 1;
                    }
                }
                else {
                    next if $conflicted{$id};
                    $models{$id} = \%rates;
                }
            }
        }
    }
    my $unresolved = $any_table ? 0 : 1;
    return ($threshold, $unresolved, \%models, \%conflicted);
}

sub _parse_fast_mode {
    my ($events) = @_;
    my @sections = _sections_for($events, qr/fast[\s-]*mode/i);
    return ({}, {}) unless @sections;

    my %models;
    my %conflicted;
    for my $sec (@sections) {
        for my $ev (@$sec) {
            next unless $ev->{kind} eq 'table';
            my ($model_idx, @input_idx, @output_idx, %cache_idx);
            for my $i (0 .. $#{ $ev->{header} }) {
                my $m = _classify_header($ev->{header}[$i]);
                next unless $m;
                if    ($m eq 'model')  { $model_idx = $i; next; }
                elsif ($m eq 'input')  { push @input_idx, $i; next; }
                elsif ($m eq 'output') { push @output_idx, $i; next; }
                else { $cache_idx{$m} = $i unless exists $cache_idx{$m}; }
            }
            next unless defined($model_idx) && @input_idx == 1 && @output_idx == 1;
            for my $row (@{ $ev->{rows} }) {
                # Decision 23: a row naming several models ("A / B") maps
                # every named model to the same rates, not only the first.
                my @ids;
                for my $piece (split m{\s*/\s*}, $row->[$model_idx]) {
                    my $piece_id = page_model_id($piece);
                    push @ids, $piece_id if defined $piece_id;
                }
                next unless @ids;
                my %rates;
                $rates{input}  = parse_rate($row->[ $input_idx[0] ]);
                $rates{output} = parse_rate($row->[ $output_idx[0] ]);
                for my $cm (keys %cache_idx) {
                    my $cidx = $cache_idx{$cm};
                    $rates{$cm} = parse_rate($row->[$cidx]) if defined $row->[$cidx];
                }
                next if !defined($rates{input}) || !defined($rates{output});
                for my $id (@ids) {
                    # M2 (fix-batch review): a later fast row for the same id
                    # with different rates is a conflict, never last-row-wins.
                    # Same-rate repeats (e.g. from a duplicate section) are
                    # fine, mirroring the standard and long-context tables.
                    if (exists $models{$id}) {
                        unless (_rates_equal($models{$id}, \%rates)) {
                            delete $models{$id};
                            $conflicted{$id} = 1;
                        }
                    }
                    else {
                        next if $conflicted{$id};
                        $models{$id} = { %rates };
                    }
                }
            }
        }
    }
    return (\%models, \%conflicted);
}

# ---------------------------------------------------------------------------
# parse_document($bytes, %o) -> $p. Pure. %o: source=>STR, fetched_at=>ISO.
# ---------------------------------------------------------------------------
sub parse_document {
    my ($bytes, %o) = @_;
    $bytes = '' unless defined $bytes;
    my $events = _extract_events($bytes);

    my @std_candidates;
    for my $ev (@$events) {
        next unless $ev->{kind} eq 'table';
        my %col;
        for my $i (0 .. $#{ $ev->{header} }) {
            my $m = _classify_header($ev->{header}[$i]);
            next unless $m;
            push @{ $col{$m} }, $i;
        }
        my $ok = 1;
        for my $m (qw(model input cache_write_5m cache_write_1h cache_read output)) {
            $ok = 0 unless $col{$m} && @{ $col{$m} } == 1;
        }
        next unless $ok;
        push @std_candidates, { event => $ev, col => { map { $_ => $col{$_}[0] } keys %col } };
    }
    return unavailable("standard price table not found", $o{source}) if @std_candidates == 0;
    return unavailable("more than one standard price table", $o{source}) if @std_candidates > 1;

    my ($std) = @std_candidates;
    my %rows_by_id;
    for my $row (@{ $std->{event}{rows} }) {
        my $id = page_model_id($row->[ $std->{col}{model} ]);
        next unless defined $id;
        my %rates;
        for my $m (qw(input cache_write_5m cache_write_1h cache_read output)) {
            my $cell = $row->[ $std->{col}{$m} ];
            $rates{$m} = defined($cell) ? parse_rate($cell) : undef;
        }
        push @{ $rows_by_id{$id} }, \%rates;
    }
    my %models;
    for my $id (keys %rows_by_id) {
        my @variants = @{ $rows_by_id{$id} };
        my $same = 1;
        for my $v (@variants[ 1 .. $#variants ]) {
            $same = 0 unless _rates_equal($v, $variants[0]);
        }
        $models{$id} = $same ? $variants[0]
                              : { input => undef, cache_write_5m => undef, cache_write_1h => undef,
                                  cache_read => undef, output => undef };
    }
    my $has_complete = 0;
    for my $id (keys %models) {
        my $m = $models{$id};
        $has_complete = 1
            if defined($m->{input}) && defined($m->{cache_write_5m}) && defined($m->{cache_write_1h})
            && defined($m->{cache_read}) && defined($m->{output});
    }
    return unavailable("no model has a complete rate row", $o{source}) unless $has_complete;

    my ($lc_threshold, $lc_unresolved, $lc_models, $lc_conflicted) = _parse_long_context($events);
    my $lc_note;
    if (ref($lc_threshold) eq 'HASH') {
        return unavailable($lc_threshold->{error}, $o{source}) if exists $lc_threshold->{error};
        # Decision 23: no threshold, no table -- standard pricing, stated by
        # the source rather than guessed.
        $lc_note   = 'long-context: standard pricing per source';
        $lc_threshold = undef;
    }

    my ($fast_models, $fast_conflicted) = _parse_fast_mode($events);

    return {
        status => 'ok', reason => undef, source => $o{source}, fetched_at => $o{fetched_at},
        models => \%models,
        long_context => {
            threshold_tokens => $lc_threshold, unresolved => $lc_unresolved,
            models => $lc_models, conflicted => $lc_conflicted, note => $lc_note,
        },
        fast => { models => $fast_models, conflicted => $fast_conflicted },
    };
}

# ===========================================================================
# Per-request rate selection (spec Sec2.6).
# ===========================================================================
sub _tier_rates {
    my ($p, $id, $tier_row) = @_;
    my $std = $p->{models}{$id};
    my %rates = (input => $tier_row->{input}, output => $tier_row->{output});
    for my $c (qw(cache_write_5m cache_write_1h cache_read)) {
        if (defined $tier_row->{$c}) {
            $rates{$c} = $tier_row->{$c};
            next;
        }
        if (defined($std) && defined($std->{$c}) && defined($std->{input}) && $std->{input} != 0) {
            $rates{$c} = $std->{$c} * $tier_row->{input} / $std->{input};
        }
        else {
            $rates{$c} = undef;
        }
    }
    return \%rates;
}

sub rates_for_request {
    my ($p, %o) = @_;
    my ($model, $speed) = ($o{model}, $o{speed});
    my $input_total = $o{input_total} // 0;

    if ($p->{status} eq 'offline')     { return { reason => 'offline' }; }
    if ($p->{status} eq 'unavailable') { return { reason => 'pricing-unavailable' }; }

    my $id = normalise_model_id($model);
    if (!defined($id) || !exists $p->{models}{$id}) {
        return { reason => 'unknown-model' };
    }

    my $non_standard = defined($speed) && (ref($speed) || $speed ne 'standard');
    if ($non_standard) {
        if (!ref($speed) && $speed eq 'fast') {
            # M1 (Decision 22/fix-batch review): fast mode over the
            # long-context threshold is never priced flat at the fast rate --
            # the page has no way to say how the two combine, so it is
            # unpriced with its own reason, checked before the fast lookup.
            if (defined($p->{long_context}{threshold_tokens}) && $input_total > $p->{long_context}{threshold_tokens}) {
                return { reason => 'fast-long-context-unspecified' };
            }
            if (exists $p->{fast}{models}{$id}) {
                return { tier => 'fast', rates => _tier_rates($p, $id, $p->{fast}{models}{$id}) };
            }
            # M2: a fast row that existed but conflicted across sections is a
            # known rate that could not be resolved -- rate-missing, not the
            # same "no fast row at all" reason as a genuinely absent model.
            if ($p->{fast}{conflicted} && $p->{fast}{conflicted}{$id}) {
                return { reason => 'rate-missing' };
            }
        }
        return { reason => 'non-standard-speed' };
    }

    if (defined($p->{long_context}{threshold_tokens}) && $input_total > $p->{long_context}{threshold_tokens}) {
        if (exists $p->{long_context}{models}{$id}) {
            return { tier => 'long_context', rates => _tier_rates($p, $id, $p->{long_context}{models}{$id}) };
        }
        elsif ($p->{long_context}{unresolved} || ($p->{long_context}{conflicted} && $p->{long_context}{conflicted}{$id})) {
            return { reason => 'rate-missing' };
        }
        # else: the page lists no LC rate for this model -- fall through to standard.
    }

    return { tier => 'standard', rates => { %{ $p->{models}{$id} } } };
}

package main;
1;
