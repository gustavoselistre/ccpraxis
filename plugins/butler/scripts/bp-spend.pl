#!/usr/bin/env perl
# bp-spend.pl — normalized OpenCode Go + Zen spend reader, plus the composed
# audit-verdict, for b36-multi-provider-spend-governance.
#
# THE MECHANISM (spec §0): both providers publish spend ONLY on an authenticated
# HTML page (opencode.ai/workspace/{id}/billing) — no API, no CLI subcommand, no
# usage headers exist today. This file scrapes that page. It vendors NOTHING
# from any reference implementation; the selectors below are this repo's own,
# derived only from the fixture shape documented in the spec.
#
# THE THREE BINDING RULES (spec §1), restated at the point they are enforced
# below so a future editor cannot miss them while changing a regex:
#
#   1. A parse failure NEVER becomes a number. Every extraction returns
#      status => 'ok' with real figures, or status => 'unknown' with a
#      diagnostic. Never a default, never a zero, never a guess.
#   2. The cookie is a whole browser-session credential, broader than anything
#      else this system handles. resolve_credential() refuses a group/world-
#      readable fallback file outright, and nothing in this file ever places
#      the cookie value into a diagnostic, a log field, or an exception string.
#   3. No cadence of its own is published upstream, so this file enforces one:
#      $CADENCE_TTL_SECONDS (a NAMED constant, never a bare literal at the call
#      sites) plus a TTL cache. Failure direction is always "degrade to warn",
#      never "manufacture a pause/block out of a network hiccup" — mirrors
#      bp-deps-check.pl's binding invariant and b46's audit-vs-build split.
#
# REVISIT TRIGGER (spec §3a, operator 2026-08-03): the scrape is a workaround,
# not the destination. Every parse-failure diagnostic below therefore ends
# with the revisit prompt — check whether OpenCode now publishes a documented
# API, CLI subcommand, or usage header for Go/Zen quota BEFORE repairing the
# scrape; if one exists, replace this reader rather than patch a regex.
#
# NO LIVE HTTP AT LOAD TIME. fetch() takes an injected `http` coderef seam
# ($method, $url, \%headers) -> {status=>N, content=>STR}. Production code
# only reaches for a real transport (bp-http.pl, the house's curl wrapper —
# never HTTP::Tiny/LWP::UserAgent) lazily, inside the branch that actually
# performs a live fetch, so the test suite never triggers it and neither
# HTTP::Tiny nor LWP::UserAgent ever lands in %INC while it runs.
#
# mandated_means: bp-log.pl — every fetch attempt/outcome, when a log_path is
# given, goes through the real BpLog::event(). Never a reimplementation.

package BpSpend;
use strict;
use warnings;
use JSON::PP;
use File::Basename qw(dirname);
use Cwd qw(abs_path);
use Fcntl ();

my $DIR = dirname(do { (my $f = __FILE__) =~ s{\\}{/}g; abs_path($f) // $f });
require "$DIR/bp-log.pl";   # mandated_means — loaded unconditionally, no HTTP inside it.

# ---------------------------------------------------------------------------
# Cadence floor (spec §1.3). NAMED constant — referenced by variable at every
# call site below, never re-typed as a bare literal seconds figure.
# ---------------------------------------------------------------------------
our $CADENCE_TTL_SECONDS = 900;   # 15 minutes: a billing dashboard, not a meter.

my %WINDOW_KEY = ('5h' => 'five_hour', 'Weekly' => 'weekly', 'Monthly' => 'monthly');

# ---------------------------------------------------------------------------
# _revisit_diagnostic($why) -> the parse-failure diagnostic, always carrying
# the §3a revisit prompt so nobody who reads it can miss the question.
# ---------------------------------------------------------------------------
sub _revisit_diagnostic {
    my ($why) = @_;
    return "$why. Before repairing the scrape, check whether OpenCode now "
         . "publishes a documented API, CLI subcommand, or usage header for "
         . "Go/Zen quota -- if it does, replace this reader rather than fix it.";
}

# ---------------------------------------------------------------------------
# parse_go($html) -> pure, no I/O.
#   ok:      { status => 'ok', five_hour=>{used,limit}, weekly=>{...}, monthly=>{...} }
#   unknown: { status => 'unknown', diagnostic => $str }
# ---------------------------------------------------------------------------
sub parse_go {
    my ($html) = @_;
    $html = '' unless defined $html;

    my %found;
    while ($html =~ /<div\s+class="quota-window"\s+data-window="([^"]+)">(.*?)<\/div>/gs) {
        my ($label, $block) = ($1, $2);
        if ($block =~ /<span\s+class="quota-used">\s*\$?([\d.]+)\s*<\/span>\s*\/\s*<span\s+class="quota-limit">\s*\$?([\d.]+)\s*<\/span>/s) {
            $found{$label} = { used => $1 + 0, limit => $2 + 0 };
        }
    }

    my @missing = grep { !$found{$_} } qw(5h Weekly Monthly);
    if (@missing) {
        return {
            status     => 'unknown',
            diagnostic => _revisit_diagnostic(
                "Go quota-window selector (div.quota-window[data-window]/span.quota-used"
                . "+span.quota-limit) did not yield figures for: " . join(', ', @missing)
            ),
        };
    }

    return {
        status    => 'ok',
        five_hour => $found{'5h'},
        weekly    => $found{'Weekly'},
        monthly   => $found{'Monthly'},
    };
}

# ---------------------------------------------------------------------------
# parse_zen($html) -> pure, no I/O.
#   ok:      { status => 'ok', balance => N, budget => N|undef }
#   unknown: { status => 'unknown', diagnostic => $str }
# ---------------------------------------------------------------------------
sub parse_zen {
    my ($html) = @_;
    $html = '' unless defined $html;

    my $balance;
    if ($html =~ /<div\s+class="billing-balance">.*?<span\s+class="balance-value">\s*\$?([\d.]+)\s*<\/span>.*?<\/div>/s) {
        $balance = $1;
    }

    unless (defined $balance) {
        return {
            status     => 'unknown',
            diagnostic => _revisit_diagnostic(
                "Zen billing-balance selector (div.billing-balance span.balance-value) "
                . "did not yield a recognisable balance"
            ),
        };
    }

    my $budget;
    if ($html =~ /<div\s+class="billing-budget">.*?<span\s+class="budget-value">\s*\$?([\d.]+)\s*<\/span>.*?<\/div>/s) {
        $budget = $1;
    }

    return { status => 'ok', balance => $balance, budget => $budget };
}

# ---------------------------------------------------------------------------
# resolve_credential(%opts) -> file-only (spec b36-reopen §1: the env path is
# REMOVED as a supported input, deliberately -- not merely unused. See the
# reopen spec's ruling: bp-jail.pl performs no environment isolation, exec()
# inherits %ENV wholesale, so a cookie that is never IN %ENV cannot leak via
# the jail. env_var/env are still accepted opts for call-site compatibility
# but are NEVER consulted -- resolution is file-only, unconditionally.
#   opts: env_var => NAME (ignored), env => \%ENV (ignored), fallback_path => PATH
#   ok:  { ok => 1, cookie => $str, source => 'file' }
#   fail:{ ok => 0, reason => 'missing'|'insecure-file', detail => $str }
# A group/world-readable fallback file is refused outright, naming the path
# and the required mode (0600) — never silently read.
# ---------------------------------------------------------------------------
sub resolve_credential {
    my (%opts) = @_;
    my $fallback_path = $opts{fallback_path};

    if (defined $fallback_path && -e $fallback_path) {
        my @st = stat($fallback_path);
        my $mode = @st ? ($st[2] & 07777) : undef;
        if (defined $mode && ($mode & 0077)) {
            return {
                ok     => 0,
                reason => 'insecure-file',
                detail => sprintf(
                    "credential file %s is group/world-readable (mode %04o); refusing "
                    . "to read a session cookie from it -- required mode is 0600 "
                    . "(chmod 0600 %s)",
                    $fallback_path, $mode, $fallback_path
                ),
            };
        }

        my $raw = do {
            local $/;
            open my $fh, '<', $fallback_path
                or return { ok => 0, reason => 'missing', detail => "cannot open $fallback_path: $!" };
            <$fh>;
        };
        my $data = eval { JSON::PP->new->decode($raw) };
        if (ref $data eq 'HASH' && defined $data->{cookie} && length $data->{cookie}) {
            return { ok => 1, cookie => $data->{cookie}, source => 'file' };
        }
        return { ok => 0, reason => 'missing', detail => "credential file $fallback_path did not contain a usable 'cookie' field" };
    }

    return {
        ok     => 0,
        reason => 'missing',
        detail => "no credential found: "
                . (defined $fallback_path ? "no usable fallback file at $fallback_path" : "no fallback file configured"),
    };
}

sub _looks_like_login_redirect {
    my ($content) = @_;
    return 0 unless defined $content;
    return $content =~ /sign\s*in\s*to\s*opencode|action\s*=\s*"\/login"|please\s*sign\s*in/i ? 1 : 0;
}

# ---------------------------------------------------------------------------
# fetch(%opts) -> the normalized reader + cadence + credential + parse,
# composed. Returns the same shape as parse_go/parse_zen, with a 'provider'
# key stamped on.
#
#   opts: provider => 'go'|'zen',
#         http     => CODEREF($method,$url,\%hdrs)->{status,content},
#         now      => epoch,
#         cache    => \%hashref (mutated, shared across calls, keyed by provider,
#                     enforces the $CADENCE_TTL_SECONDS floor),
#         credential => { cookie => $str }  -- OR --
#         env_var / fallback_path (resolved via resolve_credential),
#         log_path => optional; every attempt/outcome logged via BpLog::event.
# ---------------------------------------------------------------------------
sub fetch {
    my (%opts) = @_;
    my $provider = $opts{provider} // 'unknown';
    my $now      = defined $opts{now} ? $opts{now} : time;
    my $cache    = $opts{cache} // {};
    my $log_path = $opts{log_path};

    my $_log = sub {
        my ($outcome, $extra) = @_;
        return unless defined $log_path;
        my %fields = (provider => $provider, outcome => $outcome, %{ $extra || {} });
        # NEVER include the credential/cookie here (spec §1.2) -- deliberately
        # not forwarded into %fields anywhere on this path.
        eval { BpLog::event($log_path, 'spend_fetch', \%fields, $now) };
    };

    # --- cadence floor: served from cache inside the TTL window, no I/O at all. ---
    if (exists $cache->{$provider}
        && defined $cache->{$provider}{fetched_at}
        && ($now - $cache->{$provider}{fetched_at}) < $CADENCE_TTL_SECONDS) {
        $_log->('cached', { status => $cache->{$provider}{result}{status} });
        return $cache->{$provider}{result};
    }

    # --- credential resolution ---
    my $cred;
    if (ref $opts{credential} eq 'HASH' && defined $opts{credential}{cookie}) {
        $cred = { ok => 1, cookie => $opts{credential}{cookie}, source => 'provided' };
    } else {
        $cred = resolve_credential(
            env_var       => $opts{env_var},
            env           => $opts{env},
            fallback_path => $opts{fallback_path},
        );
    }

    unless ($cred->{ok}) {
        # THREE STATES, not two (ledger done-criterion 1). A provider that was
        # never configured at all is ABSENT -- there is no meter to read, and
        # saying "unknown" about it would be a claim we cannot support and would
        # drag the composed verdict to unknown for a provider the operator never
        # asked us to govern.
        #
        # `missing` means no env var AND no usable fallback file: nobody
        # configured this provider. Anything else (notably `insecure-file`, a
        # credential that EXISTS but which we refuse to read) means the provider
        # IS configured and we could not read its meter -- that is genuinely
        # unknown, and must keep propagating as such.
        #
        # Neither ever becomes a number. Absent is not zero-spent.
        my $absent = (($cred->{reason} // '') eq 'missing') ? 1 : 0;
        my $status = $absent ? 'absent' : 'unknown';
        my $result = {
            status     => $status,
            provider   => $provider,
            diagnostic => $absent
                ? "provider not configured: $cred->{detail}"
                : "credential unavailable ($cred->{reason}): $cred->{detail}",
        };
        $cache->{$provider} = { fetched_at => $now, result => $result };
        $_log->('credential-unavailable', { status => $status, reason => $cred->{reason} });
        return $result;
    }

    # --- transport: injected seam, or (lazily, only here) the house curl wrapper. ---
    my $http = $opts{http};
    unless (defined $http) {
        require "$DIR/bp-http.pl";   # lazy: never touched by the test suite's injected-seam paths.
        $http = sub {
            my ($method, $url, $hdrs) = @_;
            return BpHttp::request($method, $url, $hdrs);
        };
    }

    my $workspace_env = $provider eq 'go' ? 'OPENCODE_GO_WORKSPACE_ID' : 'OPENCODE_WORKSPACE_ID';
    my $workspace_id  = $opts{workspace_id} // $ENV{$workspace_env} // 'unknown';
    my $url = "https://opencode.ai/workspace/$workspace_id/billing";

    my $res = eval { $http->('GET', $url, { Cookie => "session=" . $cred->{cookie} }) };
    if ($@) {
        my $err = $@;
        $err =~ s/\s+$//;
        my $result = {
            status     => 'unknown',
            provider   => $provider,
            diagnostic => _revisit_diagnostic("network transport failed (caught, not a crash): $err"),
        };
        $cache->{$provider} = { fetched_at => $now, result => $result };
        $_log->('transport-error', { status => 'unknown' });
        return $result;
    }

    my $status  = ref($res) eq 'HASH' ? ($res->{status} // 0) : 0;
    my $content = ref($res) eq 'HASH' ? ($res->{content} // '') : '';

    my $result;
    if ($status == 401) {
        $result = {
            status     => 'unknown',
            provider   => $provider,
            diagnostic => "cookie rejected (401 unauthorized) -- re-copy the cookie from your opencode.ai session and try again.",
        };
    } elsif ($status == 200 && _looks_like_login_redirect($content)) {
        $result = {
            status     => 'unknown',
            provider   => $provider,
            diagnostic => "session rejected (redirected to sign-in) -- re-copy the cookie from your opencode.ai session and try again.",
        };
    } elsif ($status == 200) {
        my $parsed = $provider eq 'zen' ? parse_zen($content) : parse_go($content);
        $result = { %$parsed, provider => $provider };
    } else {
        $result = {
            status     => 'unknown',
            provider   => $provider,
            diagnostic => _revisit_diagnostic("network problem reaching the billing page (status=$status)"),
        };
    }

    $cache->{$provider} = { fetched_at => $now, result => $result };
    $_log->('fetched', { status => $result->{status}, http_status => $status });
    return $result;
}

# ---------------------------------------------------------------------------
# verdict(@results) -> composes N provider results into ONE decision.
#   { action => 'ok'|'unknown', reason => $str }
# ANY 'unknown' result propagates: overall action is 'unknown', NEVER 'ok',
# and NEVER coerced into a pause/block -- this is a WARN/audit path (spec
# §1.3, bp-deps-check.pl's binding invariant).
# ---------------------------------------------------------------------------
sub verdict {
    my @results = @_;
    # ABSENT providers are skipped, not counted as unknown: nobody configured
    # them, so there is no meter to be uncertain about, and letting an
    # unconfigured provider drag the whole verdict to unknown would make the
    # default (Zen is off by default) permanently unknown for every operator.
    # Absent is still never zero -- it simply does not participate.
    @results = grep { !(ref($_) eq 'HASH' && (($_->{status} // '') eq 'absent')) } @results;
    my @unknown = grep { ref($_) eq 'HASH' && (($_->{status} // '') eq 'unknown') } @results;

    if (@unknown) {
        my @who = map { $_->{provider} // '?' } @unknown;
        return {
            action => 'unknown',
            reason => 'one or more providers unreadable (never coerced to a pause): ' . join(', ', @who),
        };
    }

    return { action => 'ok', reason => 'all providers reporting real figures' };
}

# ---------------------------------------------------------------------------
# write_snapshot(%opts) -> persists the composed spend snapshot so the TUI
# (launcher.pl's _gather_spend) can render without fetching (b36-reopen §2).
#
#   opts: path       => PATH (final destination, e.g. "<active run>/spend.json"),
#         results    => \@results (each shaped like fetch()'s own return value),
#         credential => \%opt (OPTIONAL -- accepted only so a caller that still
#                      has the credential struct in scope cannot accidentally
#                      leak it in; it is NEVER read, NEVER serialised, below),
#         now        => epoch (defaults to time).
#
# ⚠ REDACTION IS THE BINDING CONSTRAINT (spec §2.1). This sub NEVER serialises
# a raw result hash -- it builds each snapshot row from an explicit FIELD
# WHITELIST (provider/status/five_hour/weekly/monthly/balance/budget/
# diagnostic). Anything else on a result -- a stray `cookie` key, a `_debug`
# sub-hash carrying request headers, whatever a careless composer bolted on --
# is dropped on the floor, not merely "not forwarded" but never even looked
# at for the write. This is what makes the redaction structural rather than
# a matter of remembering not to pass the credential in.
#
# Atomic: write to a temp file in the SAME directory as $path, then rename()
# over the final path -- a reader can never observe a half-written file. That
# half is true on every platform.
#
# THE MODE IS A POSIX-ONLY BEST EFFORT, NOT A GUARANTEE. sysopen asks for 0600
# at creation and is never chmod'd after, which POSIX honours -- but Windows
# does not implement the group/other bits that mode describes, and the file
# measurably lands 0644 on the Git-for-Windows host. almanac 20260823-204738-ee90.
#
# THE ACTUAL GUARANTEE IS THE FIELD WHITELIST, a few lines below. Every persisted
# row is built from an explicit list, so a secret cannot reach this file by being
# added to a struct upstream -- the OpenCode session cookie, the broadest secret
# in the system, provably never appears here. That is what is doing the work the
# mode used to get credit for.
#
# This distinction is stated at length ON PURPOSE. The header previously read
# "Mode 0600 from creation", full stop, and a future reader deciding whether some
# new field is safe to persist would weigh that as a second line of defence. On
# this platform there is none. A comment that overstates a security property is
# worse than one that omits it, because it is load-bearing for a decision nobody
# has made yet -- which is precisely the decision this paragraph exists to inform.
#
# Deliberately NOT fixed by enforcing an ACL on Windows: that trades a documented
# limitation for platform-specific permission code in a script whose whole point
# is running everywhere perl does, and it would not change what is safe to put in
# the file. The whitelist is the invariant to protect; see t/171 AC7, which
# asserts the honest property (the global destination is no more permissive than
# the run-dir one) rather than an absolute mode that cannot hold here.
# ---------------------------------------------------------------------------
my @SNAPSHOT_RESULT_FIELDS = qw(provider status five_hour seven_day weekly monthly balance budget diagnostic);

# The nested sub-fields a whitelisted field may carry. `used`/`limit` are go's
# window shape; `utilization` is claude's (t02, blueprint Decision 12 -- claude
# became a fetched provider, and without this its figures were stripped on
# write and the panel read `unreadable` for a brand new reason).
#
# STILL A WHITELIST, and that is the point. Widening it is the one change in
# t02 that could weaken the property this whole sub exists for: the OpenCode
# session cookie is the broadest secret in the system and must provably never
# reach a persisted file. So the new field is NAMED, never `%$v` -- a stray key
# smuggled inside a whitelisted nested field is dropped exactly as before.
# t/171's AC13 asserts that directly, at top level and nested.
my @SNAPSHOT_NESTED_FIELDS = qw(used limit utilization);

sub _whitelist_result {
    my ($r) = @_;
    return {} unless ref($r) eq 'HASH';
    my %out;
    for my $f (@SNAPSHOT_RESULT_FIELDS) {
        next unless exists $r->{$f};
        my $v = $r->{$f};
        if (ref($v) eq 'HASH') {
            # five_hour/seven_day/weekly/monthly are the only nested shapes
            # this file ever produces -- whitelist their sub-fields only, so an
            # unexpected nested key (e.g. a smuggled credential) can never ride
            # along even inside a field that IS on the list.
            my %sub;
            for my $sf (@SNAPSHOT_NESTED_FIELDS) {
                $sub{$sf} = $v->{$sf} if exists $v->{$sf};
            }
            $out{$f} = \%sub;
        } else {
            $out{$f} = $v;
        }
    }
    return \%out;
}

sub write_snapshot {
    my (%opts) = @_;
    my $path    = $opts{path};
    my $results = ref($opts{results}) eq 'ARRAY' ? $opts{results} : [];
    my $now     = defined $opts{now} ? $opts{now} : time;

    die "write_snapshot: path is required\n" unless defined $path && length $path;

    my @clean = map { _whitelist_result($_) } @$results;
    my $snapshot = { generated_at => BpLog::_iso_now($now), results => \@clean };
    my $json = JSON::PP->new->canonical->encode($snapshot);

    (my $dir = $path) =~ s{[/\\][^/\\]+$}{};
    $dir = '.' unless length $dir;
    if (length $dir && !-d $dir) { require File::Path; File::Path::make_path($dir); }

    my $tmp_path = "$path.tmp.$$." . int(rand(1_000_000));
    # 0600 is asked for at creation and KEPT -- it is honoured on POSIX and
    # ignored on Windows (lands 0644 there). Requesting it costs nothing and is
    # right wherever it works; what must not happen is anyone reading this line
    # as a guarantee. See the header: the field whitelist is the invariant.
    sysopen(my $fh, $tmp_path, Fcntl::O_WRONLY() | Fcntl::O_CREAT() | Fcntl::O_TRUNC(), 0600)
        or die "write_snapshot: sysopen $tmp_path: $!";
    print {$fh} $json or die "write_snapshot: write $tmp_path: $!";
    close $fh or die "write_snapshot: close $tmp_path: $!";

    rename($tmp_path, $path) or die "write_snapshot: rename $tmp_path -> $path: $!";
    return $path;
}

# ---------------------------------------------------------------------------
# claude_from_gate($line, $exit) -> a result hash for the `claude` provider.
#
# PURE. The subprocess is run by the caller; this only interprets its output,
# so the mapping is testable without credentials, without a network, and
# without a fork.
#
# WHY A SUBPROCESS AND NOT A REIMPLEMENTATION (blueprint Decision 12). Until
# t02, `claude` was never fetched by ANYTHING -- this file's provider list was
# qw(go zen) and nothing else composed a claude entry -- so the TUI's
# "Claude : no snapshot" was structural, guaranteed on every launch since the
# panel shipped, and would have survived the format fix untouched.
# bp-usage-gate.pl already reads ~/.claude/.credentials.json, enforces a
# token-life floor, and polls api.anthropic.com/api/oauth/usage with the right
# oauth beta header. Duplicating that here would fork the handling of the
# broadest secret in the system -- the same constraint write_snapshot's field
# whitelist exists to honour. So we call it and parse its one line.
#
# Its documented single-line contract (see that script's --help):
#   OK          five=<u5> seven=<u7> token_life_h=<h>                exit 0
#   PAUSE       window=... five=<u5> seven=<u7> ...                  exit 10
#   RELOGIN / UNAVAILABLE / CREDS  detail=...                        exit 40/20/30
#
# A PAUSE IS A READING, and a high one. Mapping it to `unknown` would discard
# the figures at exactly the moment they matter most -- the operator is near a
# limit and that is what the panel is for. So exit 10 yields status `ok` with
# both utilizations, and the fact that it is a pause verdict is the governor's
# business, not the panel's.
#
# Anything else -- including a ZERO exit with an unparseable line -- is
# `unknown` with a diagnostic. `unknown` is never `absent` and never zero: a
# provider configured enough to have failed is reported as having failed. That
# rule already governs go and zen here; this extends it rather than inventing
# a policy.
sub claude_from_gate {
    my ($line, $exit) = @_;
    $line = '' unless defined $line && !ref $line;
    $exit = -1 unless defined $exit && $exit =~ /^-?\d+$/;

    # THE FIRST LINE THAT LOOKS LIKE THE CONTRACT, not simply the first line.
    #
    # The caller captures stderr as well as stdout, deliberately -- a gate that
    # fails while saying why is more useful than one that fails silently. But
    # that means a warning printed before the result would become "the first
    # line", and a healthy poll would be reported as `unknown`. So the verb
    # prefix is what selects the line.
    #
    # Still strict about WHERE the figures may come from: only a line that
    # opens with one of the five documented verbs is eligible, so a stray
    # diagnostic that happens to contain `five=` cannot supply a reading.
    my $first = '';
    for my $l (split(/\r?\n/, $line)) {
        next unless $l =~ /^(?:OK|PAUSE|RELOGIN|UNAVAILABLE|CREDS)\b/;
        $first = $l;
        last;
    }

    if ($exit == 0 || $exit == 10) {
        my ($u5) = $first =~ /\bfive=(-?\d+(?:\.\d+)?)\b/;
        my ($u7) = $first =~ /\bseven=(-?\d+(?:\.\d+)?)\b/;
        if (defined $u5 && defined $u7) {
            return { provider   => 'claude', status => 'ok',
                     five_hour  => { utilization => $u5 + 0 },
                     seven_day  => { utilization => $u7 + 0 } };
        }
        return { provider => 'claude', status => 'unknown',
                 diagnostic => _gate_diagnostic($first, $exit,
                     'gate exited 0 without parseable five= and seven= figures') };
    }

    return { provider => 'claude', status => 'unknown',
             diagnostic => _gate_diagnostic($first, $exit, 'gate reported no figures') };
}

# _gate_diagnostic($line, $exit, $fallback) -> a short, SAFE one-line string.
#
# The gate's own `detail=` is preferred because it names the actual cause
# (telemetry-unreachable, no-oauth-block, oauth-token-under-floor-...), which
# is the difference between a panel that says "something went wrong" and one
# that says what to do about it.
#
# SANITISED, and not as a formality. This value is server-influenced (the gate
# forwards an upstream ISO string into its own line, and its redteam already
# stripped control characters there for the same reason), it is written into a
# JSON file, and it is then rendered into a terminal. Control bytes are removed
# so nothing can forge a line break or smuggle an escape sequence into the TUI,
# and the length is capped so a pathological reply cannot push a panel row into
# unbounded wrapping. PRIVATE.
sub _gate_diagnostic {
    my ($line, $exit, $fallback) = @_;
    my $d;
    if (defined $line && $line =~ /\bdetail=(\S+)/) { $d = $1 }
    elsif (defined $line && $line =~ /^([A-Z]+)\b/) { $d = lc($1) }
    $d = $fallback unless defined $d && length $d;
    $d =~ tr/\x00-\x1f\x7f//d;
    $d = substr($d, 0, 120) if length($d) > 120;
    return length($d) ? "$d (gate exit $exit)" : "gate exit $exit";
}

package BpSpend::Derive;
# ===========================================================================
# BpSpend::Derive -- derive-from-transcripts mode (blueprint
# fleet-cost-accounting, package 01-spend-is-recorded). Reads a package's
# EXISTING runs/<pkg>.jsonl coordinator transcript directly -- no external
# provider, no network, no credential -- and produces a token/cost figure
# split coordinator-vs-subagent, plus a named cache-write anomaly report.
# Spec: .ccpraxis-local-data/blueprints/fleet-cost-accounting/specs/
# 01-spend-is-recorded-spec.md. Pure functions; the CLI verbs at the bottom
# of this file are the only I/O-performing callers.
#
# NO CONSUMER YET (fix-batch, reviewer should-fix #1). Nothing reads the
# runs/spend-derived.json this package writes -- not launcher.pl's
# _gather_spend, not SpendPanel.pm, not the reporter/harvest log. Both files
# are outside this package's write set (spec §4's explicit gap flag); wiring
# either of them up is a separate, not-yet-scheduled package.
# ===========================================================================
use strict;
use warnings;
use JSON::PP;
use Fcntl ();

# ---------------------------------------------------------------------------
# _empty_package_result($pkg) -> the zero-valued shape every derive_package()
# call starts from and, for 'no-file'/'empty' status, returns unmodified.
# ---------------------------------------------------------------------------
sub _empty_package_result {
    my ($pkg) = @_;
    return {
        pkg    => $pkg,
        status => 'ok',
        tokens => {
            coordinator => { input => 0, output => 0, cache_creation => 0, cache_read => 0 },
            subagent    => { input => 0, output => 0, cache_creation => 0, cache_read => 0 },
        },
        by_model      => {},
        record_counts => {
            assistant_total       => 0,
            coordinator           => 0,
            subagent              => 0,
            skipped_unparseable   => 0,
            result_usage_seen     => 0,
            system_usage_seen     => 0,
            malformed_usage_field => 0,
        },
        anomaly => {
            name         => 'consecutive-same-size-cache-write',
            count        => 0,
            total_tokens => 0,
            pairs        => [],
        },
        cross_check => {
            seen            => 0,
            total_cost_usd  => undef,
            model_usage     => {},
        },
        derived => 1,
    };
}

# ---------------------------------------------------------------------------
# _safe_usage_num($val, \%record_counts) -> a non-negative number, NEVER a
# silent corruption of the total (fix-batch M3). A usage sub-field that is
# undef is legitimately absent and becomes 0 with no diagnostic (spec's own
# "missing sub-field" edge case). Anything else that is not a bare
# non-negative integer -- a negative figure, a string, a boolean, a hashref --
# is NOT summed in (a negative value would silently REDUCE the reported total,
# which is the one failure mode this package exists to avoid being fooled by)
# and is instead counted in record_counts.malformed_usage_field so a caller
# has a real signal that some input was suspect, mirroring how a JSON-decode
# failure is counted in skipped_unparseable rather than silently ignored.
# ---------------------------------------------------------------------------
sub _safe_usage_num {
    my ($val, $counts) = @_;
    return 0 unless defined $val;
    if (!ref($val) && $val =~ /^\d+\z/) {
        return $val + 0;
    }
    $counts->{malformed_usage_field}++;
    return 0;
}

# ---------------------------------------------------------------------------
# derive_package(%opts) -> \%package_result. See spec §2.1-2.4.
#   opts: jsonl_path => PATH (required), pkg => STR (required)
# A missing file is status=>'no-file'. A file with zero assistant/usage
# records is status=>'empty'. A line that fails JSON decode is SKIPPED, not
# fatal, and counted in record_counts.skipped_unparseable.
# ---------------------------------------------------------------------------
sub derive_package {
    my (%opts) = @_;
    my $jsonl_path = $opts{jsonl_path};
    my $pkg        = $opts{pkg};

    my $result = _empty_package_result($pkg);

    unless (defined $jsonl_path && -f $jsonl_path) {
        $result->{status} = 'no-file';
        return $result;
    }

    open(my $fh, '<:raw', $jsonl_path) or do {
        $result->{status} = 'no-file';
        return $result;
    };
    my @lines = <$fh>;
    close $fh;

    my $saw_assistant = 0;
    my %prev_by_session;   # session_id => { role => { size => N, uuid => STR } }
    my @pairs;

    for my $line (@lines) {
        $line =~ s/\r?\n\z//;
        next unless length $line;

        my $rec = eval { JSON::PP->new->decode($line) };
        if ($@ || ref($rec) ne 'HASH') {
            $result->{record_counts}{skipped_unparseable}++;
            next;
        }

        my $type = defined($rec->{type}) ? $rec->{type} : '';

        if ($type eq 'assistant'
            && ref($rec->{message}) eq 'HASH'
            && ref($rec->{message}{usage}) eq 'HASH') {

            $saw_assistant = 1;
            my $role  = defined($rec->{parent_tool_use_id}) ? 'subagent' : 'coordinator';
            my $model = defined($rec->{message}{model}) && length($rec->{message}{model})
                      ? $rec->{message}{model} : 'unknown';
            my $u = $rec->{message}{usage};
            my $input  = _safe_usage_num($u->{input_tokens},                $result->{record_counts});
            my $output = _safe_usage_num($u->{output_tokens},               $result->{record_counts});
            my $cc     = _safe_usage_num($u->{cache_creation_input_tokens}, $result->{record_counts});
            my $cr     = _safe_usage_num($u->{cache_read_input_tokens},     $result->{record_counts});

            $result->{tokens}{$role}{input}          += $input;
            $result->{tokens}{$role}{output}         += $output;
            $result->{tokens}{$role}{cache_creation} += $cc;
            $result->{tokens}{$role}{cache_read}     += $cr;

            my $bm = ($result->{by_model}{$model} //= {
                role => $role, input => 0, output => 0, cache_creation => 0, cache_read => 0,
            });
            $bm->{role} = 'mixed' if $bm->{role} ne $role;
            $bm->{input}          += $input;
            $bm->{output}         += $output;
            $bm->{cache_creation} += $cc;
            $bm->{cache_read}     += $cr;

            $result->{record_counts}{assistant_total}++;
            $result->{record_counts}{$role}++;

            # Decision 5 -- consecutive same-size (>0) cache-write anomaly,
            # per (session_id, role), in file order. A 0-size write is
            # skipped: it participates as neither half of a pair and never
            # resets the tracked previous value (spec §2.4).
            #
            # SCOPED BY ROLE TOO, not session_id alone (fix-batch M2 --
            # red-team headline finding). Subagent (Task-tool) turns share the
            # coordinator's session_id and interleave with it in file order as
            # NORMAL operation, not an edge case. Tracking "previous" per
            # session_id alone lets an interleaved subagent write both hide a
            # real same-role duplicate (the subagent's differently-sized write
            # overwrites the tracked pointer between two identical coordinator
            # writes, so the real dup is never compared) and false-positive
            # across roles (an unrelated coordinator/subagent pair that
            # coincidentally share a cache-write size gets reported as a
            # duplicate). Keying by (session_id, role) means only writes from
            # the SAME branch of the conversation are ever compared.
            my $session = $rec->{session_id};
            if (defined $session && $cc > 0) {
                my $uuid = defined($rec->{uuid}) ? $rec->{uuid} : '';
                my $prev = $prev_by_session{$session}{$role};
                if (defined $prev && $prev->{size} == $cc) {
                    push @pairs, {
                        session_id  => $session,
                        role        => $role,
                        size        => $cc,
                        first_uuid  => $prev->{uuid},
                        second_uuid => $uuid,
                    };
                }
                $prev_by_session{$session}{$role} = { size => $cc, uuid => $uuid };
            }
        }
        elsif ($type eq 'system'
            && (ref($rec->{usage}) eq 'HASH'
                || (defined($rec->{subtype}) && $rec->{subtype} eq 'task_progress'))) {
            # A cumulative running counter -- counted, never summed in.
            $result->{record_counts}{system_usage_seen}++;
        }
        elsif ($type eq 'result') {
            # A whole-session summary -- captured verbatim into cross_check
            # for audit only, never blended into tokens/by_model.
            $result->{record_counts}{result_usage_seen}++;
            $result->{cross_check}{seen} = 1;
            $result->{cross_check}{total_cost_usd} = $rec->{total_cost_usd}
                if defined $rec->{total_cost_usd};
            if (ref($rec->{usage}) eq 'HASH' && ref($rec->{usage}{modelUsage}) eq 'HASH') {
                for my $m (keys %{ $rec->{usage}{modelUsage} }) {
                    my $mu = $rec->{usage}{modelUsage}{$m};
                    next unless ref($mu) eq 'HASH';
                    $result->{cross_check}{model_usage}{$m} = {
                        input_tokens                => $mu->{inputTokens}               // 0,
                        output_tokens               => $mu->{outputTokens}              // 0,
                        cache_read_input_tokens     => $mu->{cacheReadInputTokens}      // 0,
                        cache_creation_input_tokens => $mu->{cacheCreationInputTokens}  // 0,
                        cost_usd                    => $mu->{costUSD}                   // 0,
                    };
                }
            }
        }
        # else: system/init, user, or any other record type -- ignored, no
        # usage to account for (spec §2.2, last bullet).
    }

    $result->{anomaly}{pairs} = \@pairs;
    $result->{anomaly}{count} = scalar(@pairs);
    my $total = 0;
    $total += $_->{size} for @pairs;
    $result->{anomaly}{total_tokens} = $total;

    $result->{status} = $saw_assistant ? 'ok' : 'empty';
    return $result;
}

# ---------------------------------------------------------------------------
# derive_blueprint(%opts) -> \%blueprint_result. See spec §2.1.
#   opts: runs_dir => PATH (required), pkgs => \@ARRAY (optional -- if
#         omitted, scans runs_dir for *.jsonl files, basename minus .jsonl is
#         the pkg id, excluding spend.json/spend-derived.json/non-.jsonl and
#         a file literally named spend.jsonl).
# Sums each independently-derived package result additively -- never by
# re-scanning a combined stream.
# ---------------------------------------------------------------------------
sub derive_blueprint {
    my (%opts) = @_;
    my $runs_dir = $opts{runs_dir};

    my @pkgs;
    if (ref($opts{pkgs}) eq 'ARRAY') {
        @pkgs = @{ $opts{pkgs} };
    }
    elsif (defined $runs_dir && -d $runs_dir) {
        opendir(my $dh, $runs_dir) or @pkgs = ();
        if ($dh) {
            for my $f (sort readdir($dh)) {
                next unless $f =~ /\.jsonl\z/;
                next if $f eq 'spend.jsonl';   # reserved (§4)
                (my $pkg = $f) =~ s/\.jsonl\z//;
                push @pkgs, $pkg;
            }
            closedir $dh;
        }
    }

    my $result = {
        status => 'ok',
        tokens => {
            coordinator => { input => 0, output => 0, cache_creation => 0, cache_read => 0 },
            subagent    => { input => 0, output => 0, cache_creation => 0, cache_read => 0 },
        },
        by_model => {},
        packages => [],
        anomaly  => {
            name         => 'consecutive-same-size-cache-write',
            count        => 0,
            total_tokens => 0,
            by_package   => {},
        },
        derived => 1,
    };

    for my $pkg (@pkgs) {
        my $jsonl_path = defined($runs_dir) ? "$runs_dir/$pkg.jsonl" : undef;
        my $pr = derive_package(jsonl_path => $jsonl_path, pkg => $pkg);
        push @{ $result->{packages} }, $pr;

        for my $role (qw(coordinator subagent)) {
            for my $f (qw(input output cache_creation cache_read)) {
                $result->{tokens}{$role}{$f} += $pr->{tokens}{$role}{$f};
            }
        }

        for my $model (keys %{ $pr->{by_model} }) {
            my $src = $pr->{by_model}{$model};
            my $bm = ($result->{by_model}{$model} //= {
                role => $src->{role}, input => 0, output => 0, cache_creation => 0, cache_read => 0,
            });
            $bm->{role} = 'mixed' if $bm->{role} ne $src->{role};
            for my $f (qw(input output cache_creation cache_read)) {
                $bm->{$f} += $src->{$f};
            }
        }

        if ($pr->{anomaly}{count} > 0) {
            $result->{anomaly}{count}        += $pr->{anomaly}{count};
            $result->{anomaly}{total_tokens} += $pr->{anomaly}{total_tokens};
            $result->{anomaly}{by_package}{$pkg} = {
                count        => $pr->{anomaly}{count},
                total_tokens => $pr->{anomaly}{total_tokens},
            };
        }
    }

    return $result;
}

# ---------------------------------------------------------------------------
# write_derived(%opts) -> writes the spend-derived.json shape (spec §4)
# atomically (temp file in the same directory + rename()), mirroring
# BpSpend::write_snapshot's pattern without calling it -- the two files'
# shapes are unrelated and this must never touch spend.json (AC8).
#   opts: path => PATH, doc => \%hashref (already shaped -- see CLI below)
# ---------------------------------------------------------------------------
sub write_derived {
    my (%opts) = @_;
    my $path = $opts{path};
    my $doc  = $opts{doc};

    die "write_derived: path is required\n" unless defined $path && length $path;

    my $json = JSON::PP->new->canonical->encode($doc);

    (my $dir = $path) =~ s{[/\\][^/\\]+$}{};
    $dir = '.' unless length $dir;
    if (length $dir && !-d $dir) { require File::Path; File::Path::make_path($dir); }

    my $tmp_path = "$path.tmp.$$." . int(rand(1_000_000));
    sysopen(my $fh, $tmp_path, Fcntl::O_WRONLY() | Fcntl::O_CREAT() | Fcntl::O_TRUNC(), 0600)
        or die "write_derived: sysopen $tmp_path: $!";
    print {$fh} $json or die "write_derived: write $tmp_path: $!";
    close $fh or die "write_derived: close $tmp_path: $!";

    rename($tmp_path, $path) or die "write_derived: rename $tmp_path -> $path: $!";
    return $path;
}

package main;

# Same allow-list bp-blueprint.pl enforces on --pkg before using it to build a
# path ($PKG_ID_RE there, bp-blueprint.pl:73) -- reused here rather than
# re-derived, so the two files' notion of "a valid package id" cannot drift
# apart. Applied below (fix-batch M1) before --pkg is used to build
# $jsonl_path: an unsanitized value could otherwise traverse (`../`) outside
# the intended blueprint's runs/ directory and pull another blueprint's
# transcript into this one's derived figure.
my $PKG_ID_RE = qr/^[A-Za-z0-9][A-Za-z0-9_.-]*$/;

# ===========================================================================
# CLI (b47). THIS BLOCK'S ABSENCE WAS THE DEFECT.
#
# bp-spend.pl previously ended `package main; 1;` with no `unless (caller)`
# block, so nothing outside a `require` could ever invoke it. Combined with
# write_snapshot having no production caller, the Spend panel could never
# render on any real fleet -- and the reader's `-f` guard plus its swallowing
# `eval` made that permanent breakage look exactly like "no data yet".
#
#   bp-spend.pl snapshot --run-dir DIR [--offline] [--now EPOCH] [--log PATH]
#
# Writes DIR/spend.json -- the exact path launcher.pl's _gather_spend reads.
# Exit 0 wrote (or served a still-fresh snapshot) - 2 usage - 4 I/O.
#
# CADENCE ACROSS PROCESSES. fetch()'s TTL cache is in-process and therefore
# useless to a CLI that exits, so this re-derives the floor from the EXISTING
# snapshot's generated_at. That makes the verb safe to call on any tick: inside
# $CADENCE_TTL_SECONDS it is a stat plus a read and makes no network call at
# all. Without this, wiring it to a frequent loop would hammer the providers --
# the cadence floor would exist in the library and be bypassed by its only
# caller.
#
# --offline performs no fetch and records every provider as `absent`. It exists
# so the write path can be exercised deterministically (no credentials, no
# network) -- the check that would have caught the original defect.
# ===========================================================================
unless (caller) {
    my $verb = shift(@ARGV) // '';
    my %opt;
    while (@ARGV) {
        my $a = shift @ARGV;
        if    ($a =~ /^--run-dir=(.*)$/)    { $opt{run_dir}    = $1 }
        elsif ($a eq '--run-dir')           { $opt{run_dir}    = shift @ARGV }
        elsif ($a =~ /^--global-dir=(.*)$/) { $opt{global_dir} = $1 }
        elsif ($a eq '--global-dir')        { $opt{global_dir} = shift @ARGV }
        elsif ($a =~ /^--now=(.*)$/)        { $opt{now}        = $1 }
        elsif ($a eq '--now')               { $opt{now}        = shift @ARGV }
        elsif ($a =~ /^--log=(.*)$/)        { $opt{log}        = $1 }
        elsif ($a eq '--log')               { $opt{log}        = shift @ARGV }
        elsif ($a =~ /^--gate-cmd=(.*)$/)   { $opt{gate_cmd}   = $1 }
        elsif ($a eq '--gate-cmd')          { $opt{gate_cmd}   = shift @ARGV }
        elsif ($a =~ /^--pkg=(.*)$/)        { $opt{pkg}        = $1 }
        elsif ($a eq '--pkg')               { $opt{pkg}        = shift @ARGV }
        # --no-opencode fetches claude ONLY. Like --gate-cmd it exists for the
        # test suite: without it, exercising the claude mapping would reach out
        # to the real OpenCode providers on every case, which is both slow and
        # a poll of the operator's actual account for no reason. Production
        # never passes it.
        elsif ($a eq '--no-opencode')       { $opt{no_opencode} = 1 }
        elsif ($a eq '--offline')           { $opt{offline}    = 1 }
        elsif ($a eq '--force')             { $opt{force}      = 1 }
        else { print STDERR "bp-spend: unrecognised argument '$a'\n"; exit 2 }
    }

    # ---------------------------------------------------------------------
    # derive-package / derive-blueprint (blueprint fleet-cost-accounting,
    # package 01-spend-is-recorded). No external provider, no network, no
    # credential -- reads runs/<pkg>.jsonl directly. See spec §2.6.
    # ---------------------------------------------------------------------
    if ($verb eq 'derive-package' || $verb eq 'derive-blueprint') {
        my $run_dir = $opt{run_dir};
        unless (defined $run_dir && length $run_dir) {
            print STDERR "bp-spend: $verb requires --run-dir DIR\n";
            exit 2;
        }
        if ($verb eq 'derive-package' && !(defined $opt{pkg} && length $opt{pkg})) {
            print STDERR "bp-spend: derive-package requires --pkg PKG\n";
            exit 2;
        }
        # M1 (fix-batch): reject a --pkg that cannot form a bare filename
        # component BEFORE it is used to build $jsonl_path below -- an
        # unvalidated value (e.g. containing `../`) could otherwise read a
        # transcript outside this blueprint's own runs/ directory, silently
        # contaminating the derived figure with another blueprint's spend.
        if ($verb eq 'derive-package' && $opt{pkg} !~ $PKG_ID_RE) {
            print STDERR "bp-spend: --pkg '$opt{pkg}' is not a valid package id (must match $PKG_ID_RE)\n";
            exit 2;
        }

        my $now      = defined $opt{now} && $opt{now} =~ /^\d+$/ ? $opt{now} + 0 : time;
        my $runs_dir = "$run_dir/runs";
        my $out_path = "$runs_dir/spend-derived.json";

        my $bp_result;
        if ($verb eq 'derive-package') {
            my $jsonl_path = "$runs_dir/$opt{pkg}.jsonl";
            # A specifically-requested missing package is a CALLER ERROR
            # (spec §2.6): exit 4, write nothing -- an existing
            # spend-derived.json from a prior successful call is untouched.
            unless (-f $jsonl_path) {
                print STDERR "bp-spend: no such file $jsonl_path\n";
                exit 4;
            }
            $bp_result = BpSpend::Derive::derive_blueprint(
                runs_dir => $runs_dir, pkgs => [ $opt{pkg} ],
            );
        }
        else {
            $bp_result = BpSpend::Derive::derive_blueprint(runs_dir => $runs_dir);
        }

        my $doc = {
            generated_at => BpLog::_iso_now($now),
            derived      => 1,
            tokens       => $bp_result->{tokens},
            by_model     => $bp_result->{by_model},
            anomaly      => $bp_result->{anomaly},
            packages     => $bp_result->{packages},
        };

        eval { BpSpend::Derive::write_derived(path => $out_path, doc => $doc) };
        if ($@) {
            print STDERR "bp-spend: could not write $out_path: $@";
            exit 4;
        }
        print "$out_path\n";
        exit 0;
    }

    if ($verb ne 'snapshot') {
        print STDERR "usage: bp-spend.pl snapshot [--run-dir DIR] [--global-dir DIR] [--offline]\n"
                   . "                            [--force] [--now EPOCH] [--log PATH]\n"
                   . "       bp-spend.pl derive-package --run-dir DIR --pkg PKG [--now EPOCH]\n"
                   . "       bp-spend.pl derive-blueprint --run-dir DIR [--now EPOCH]\n";
        exit 2;
    }

    # AT LEAST ONE DESTINATION, not specifically --run-dir. Blueprint Decision
    # 11: every figure in this snapshot -- go's windows, zen's balance,
    # claude's utilizations -- describes the ACCOUNT, not the run that happened
    # to poll for it. Requiring a run directory scoped an account fact to a run
    # and made it unreadable in exactly the state the operator is normally in:
    # no fleet run active. The run copy keeps being written when asked for, so
    # no existing fleet behaviour changes.
    my @dirs = grep { defined && length } ($opt{run_dir}, $opt{global_dir});
    unless (@dirs) {
        print STDERR "bp-spend: at least one of --run-dir or --global-dir is required\n";
        exit 2;
    }

    my $now   = defined $opt{now} && $opt{now} =~ /^\d+$/ ? $opt{now} + 0 : time;
    my @paths = map { "$_/spend.json" } @dirs;

    # Cross-process cadence floor -- see the header note. Evaluated across
    # EVERY destination, not just one: with two paths, a floor that only
    # consulted the run copy would fetch on every call whenever the global copy
    # was the stale one, which is the opposite of what a floor is for.
    my $fresh_path;
    if (!$opt{force}) {
        for my $p (@paths) {
            next unless -f $p;
            my $fresh = eval {
                open my $fh, '<:raw', $p or die "read\n";
                my $raw = do { local $/; <$fh> };
                close $fh;
                my $prev = JSON::PP->new->decode($raw);
                die "shape\n" unless ref $prev eq 'HASH';
                # generated_at is ISO; compare via mtime, which is what we control.
                my @st = stat($p);
                (@st && ($now - $st[9]) < $BpSpend::CADENCE_TTL_SECONDS) ? 1 : 0;
            };
            if ($fresh) { $fresh_path = $p; last }
        }
    }

    my @results;
    my $reused = 0;
    if (defined $fresh_path) {
        # SERVE THE FRESH CONTENT TO EVERY DESTINATION rather than exiting
        # here. A cadence floor exists to suppress a FETCH; letting it also
        # suppress the WRITE would mean a destination that does not yet exist
        # never appears, and the panel stays empty for as long as some other
        # copy keeps being refreshed -- a floor turned into a permanent
        # absence. So: no network call, but the file still lands.
        $reused = 1;
        my $prev = eval {
            open my $fh, '<:raw', $fresh_path or die "read\n";
            my $raw = do { local $/; <$fh> };
            close $fh;
            JSON::PP->new->decode($raw);
        };
        @results = (ref($prev) eq 'HASH' && ref($prev->{results}) eq 'ARRAY')
                 ? @{ $prev->{results} } : ();
    }
    elsif ($opt{offline}) {
        # claude joins go and zen here. Until t02 it was absent from this list
        # entirely, which is why the TUI's "Claude : no snapshot" was
        # structural rather than a data gap (blueprint Decision 12).
        @results = map { { provider => $_, status => 'absent' } } qw(claude go zen);
    }
    else {
        # claude first: it is the provider the operator named, and a failure in
        # the OpenCode fetches must not cost it.
        push @results, _fetch_claude($opt{gate_cmd});

        unless ($opt{no_opencode}) {
            my %cache;
            for my $p (qw(go zen)) {
                my $r = eval {
                    BpSpend::fetch(provider => $p, now => $now, cache => \%cache,
                                   log_path => $opt{log});
                };
                # A provider that blows up must not lose the whole snapshot: record
                # it as unknown (never zero, never absent -- it IS configured enough
                # to have failed) and keep going.
                push @results, (ref $r eq 'HASH') ? $r
                             : { provider => $p, status => 'unknown' };
            }
        }
    }

    my @written;
    for my $path (@paths) {
        # Already fresh AND already present -- nothing to do for this one.
        next if $reused && -f $path;
        my $w = eval { BpSpend::write_snapshot(path => $path, results => \@results, now => $now) };
        if ($@ || !defined $w) {
            print STDERR "bp-spend: could not write $path: " . ($@ || "unknown error\n");
            exit 4;
        }
        push @written, $w;
    }
    push @written, $fresh_path if $reused && !@written;

    print "$_\n" for @written;
    exit 0;
}

# _fetch_claude($gate_cmd) -> a claude result hash. Runs bp-usage-gate.pl (or
# an injected substitute) and hands its output to the pure mapper.
#
# --gate-cmd EXISTS FOR THE TEST SUITE AND FOR NOTHING ELSE IN PRODUCTION. It
# is the seam that makes the credential path exercisable without owning
# credentials and without reaching api.anthropic.com -- a test that polled the
# operator's real account on every run would be both non-deterministic and
# rude. The default is the real script, resolved next to this one.
sub _fetch_claude {
    my ($gate_cmd) = @_;

    my $cmd = (defined $gate_cmd && length $gate_cmd)
            ? $gate_cmd
            : do { my $d = $0; $d =~ s{[/\\][^/\\]+$}{}; $d = '.' unless length $d;
                   qq("$^X" "$d/bp-usage-gate.pl") };

    my $out = eval {
        local $SIG{__WARN__} = sub {};
        `$cmd 2>&1`;
    };
    # A gate that cannot be RUN at all is still `unknown`, never `absent`: the
    # distinction is about the provider, not about our ability to ask.
    return BpSpend::claude_from_gate(defined $out ? $out : '', defined $out ? ($? >> 8) : -1);
}

1;
