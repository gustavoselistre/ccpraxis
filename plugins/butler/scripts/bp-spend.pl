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
use Time::Local ();

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
        my $n = $val + 0;
        # A ~300+-digit token count overflows a Perl NV to Inf (fix-batch
        # redteam M1) -- that would otherwise pass through int()/rounding
        # unrounded and land in the JSON output as an invalid `Infinity`
        # token, breaking every consumer that decodes it. Reject non-finite
        # results the same way any other malformed field is rejected.
        return $n if $n == $n && $n != 9**9**9 && $n != -9**9**9;
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

# ===========================================================================
# derive_session(%opts) -- blueprint usage-telemetry, package
# 01-drive-solo-input-and-pricing. Reads a DRIVE-SOLO session's own
# transcripts directly: a `<uuid>.jsonl` main transcript plus a sibling
# `<uuid>/subagents/agent-<id>.jsonl` per subagent and its `.meta.json`
# sidecar. This shape has no `result` record (no self-reported cost) and no
# `parent_tool_use_id` (role must come from the sidecar, not the record), and
# one API request is spread over several `assistant` records that repeat
# their input/cache figures while `output_tokens` grows -- hence the
# per-request dedup below. Spec: .ccpraxis-local-data/blueprints/
# usage-telemetry/specs/01-drive-solo-input-and-pricing-spec.md. Pure,
# read-only: opens files '<:raw', writes nothing, creates nothing (Decision
# 7). Deliberately does NOT reuse derive_package's (session_id, role)
# anomaly key -- see the per-agent-file rationale at _agent_anomaly() below.
# ===========================================================================

# ---------------------------------------------------------------------------
# Price table (spec §2.4). US dollars per million tokens (MTok), fetched live
# 2026-09-23 from the docs pricing page (chosen over claude.com/pricing per
# Decisions 11-12, because only the docs page itemises the cache-write
# 5m/1h split). `claude-haiku-4-5-20251001` is priced from the
# `claude-haiku-4-5` alias row -- an alias identity, not a sibling/older-model
# substitution (Decision 8 is not violated). Every other id is read from a
# row that names that exact id.
# ---------------------------------------------------------------------------
our $SESSION_PRICE_SOURCE = 'https://platform.claude.com/docs/en/about-claude/pricing';
our $SESSION_PRICE_AS_OF  = '2026-09-23';
our @SESSION_PRICE_REQUIRED = qw(
    claude-opus-5-5 claude-sonnet-5 claude-fable-5-1
    claude-haiku-4-5-20251001 claude-opus-5
);
our %SESSION_PRICES = (
    'claude-opus-5-5'           => { input => 4,  output => 20, cache_write_5m => 5,     cache_write_1h => 8,  cache_read => 0.20 },
    'claude-sonnet-5'           => { input => 2,  output => 10, cache_write_5m => 2.50,  cache_write_1h => 4,  cache_read => 0.20 },
    'claude-fable-5-1'          => { input => 10, output => 50, cache_write_5m => 12.50, cache_write_1h => 20, cache_read => 0.25 },
    'claude-haiku-4-5-20251001' => { input => 1,  output => 5,  cache_write_5m => 1.25,  cache_write_1h => 2,  cache_read => 0.10 },
    'claude-opus-5'             => { input => 5,  output => 25, cache_write_5m => 6.25,  cache_write_1h => 10, cache_read => 0.50 },
);
our %SESSION_PRICES_MISSING = ();   # model id => reason string; empty for this release

# ---------------------------------------------------------------------------
# session_price_table() -> { source, as_of, required => \@, prices => \%,
# missing => \% }. Returns COPIES -- callers must not mutate the originals.
# ---------------------------------------------------------------------------
sub session_price_table {
    my %prices;
    for my $id (keys %SESSION_PRICES) {
        $prices{$id} = { %{ $SESSION_PRICES{$id} } };
    }
    return {
        source   => $SESSION_PRICE_SOURCE,
        as_of    => $SESSION_PRICE_AS_OF,
        required => [ @SESSION_PRICE_REQUIRED ],
        prices   => \%prices,
        missing  => { %SESSION_PRICES_MISSING },
    };
}

# ---------------------------------------------------------------------------
# _norm_scalar_or_unknown($v) -> $v when it is a defined, non-ref, non-empty
# scalar; else the literal string 'unknown' (B5). Never a default such as
# 'medium'.
# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
# _session_truncate_for_error($s) -> $s, or its first 200 chars + '...' when
# longer (fix-batch redteam L10) -- keeps a pathologically long --session
# value from being echoed verbatim (and unbounded) into a diagnostic.
# ---------------------------------------------------------------------------
sub _session_truncate_for_error {
    my ($s) = @_;
    return '' unless defined $s;
    return $s if !ref($s) && length($s) <= 200;
    return ref($s) ? "$s" : substr($s, 0, 200) . '...';
}

sub _norm_scalar_or_unknown {
    my ($v) = @_;
    return (defined($v) && !ref($v) && length($v)) ? $v : 'unknown';
}

# ---------------------------------------------------------------------------
# _session_parse_ts($str) -> epoch seconds, or undef when $str is not one of
# the accepted forms (B12): YYYY-MM-DDTHH:MM:SS, an optional fractional part
# (truncated), and either Z or +-HH:MM.
# ---------------------------------------------------------------------------
sub _session_parse_ts {
    my ($str) = @_;
    return undef unless defined($str) && !ref($str);
    return undef unless $str =~ /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.\d+)?(Z|[+-]\d{2}:\d{2})$/;
    my ($y, $mo, $d, $h, $mi, $s, $off) = ($1, $2, $3, $4, $5, $6, $7);
    my $epoch = eval { Time::Local::timegm($s, $mi, $h, $d, $mo - 1, $y) };
    return undef unless defined $epoch;
    if ($off ne 'Z') {
        my ($sign, $oh, $om) = $off =~ /^([+-])(\d{2}):(\d{2})$/;
        my $off_secs = ($oh * 3600 + $om * 60);
        $off_secs = -$off_secs if $sign eq '-';
        $epoch -= $off_secs;
    }
    return $epoch;
}

# ---------------------------------------------------------------------------
# _session_read_sidecar($path) -> \%hashref, or undef when the file is
# absent, unreadable, not valid JSON, or not a JSON object. Never fatal.
# ---------------------------------------------------------------------------
sub _session_read_sidecar {
    my ($path) = @_;
    return undef unless -f $path;
    open(my $fh, '<:raw', $path) or return undef;
    my $raw = do { local $/; <$fh> };
    close $fh;
    my $data = eval { JSON::PP->new->utf8->decode($raw) };
    return undef if $@ || ref($data) ne 'HASH';
    return $data;
}

# ---------------------------------------------------------------------------
# _session_slashify($path) -> $path with every backslash replaced by a
# forward slash, so emitted path strings are byte-identical on Windows and
# POSIX (spec §2.3).
# ---------------------------------------------------------------------------
sub _session_slashify {
    my ($path) = @_;
    (my $out = $path) =~ s{\\}{/}g;
    return $out;
}

# ---------------------------------------------------------------------------
# FAST LINE READER. A session is ~130 MB of JSONL for a day of drive-solo
# work, and JSON::PP -- the only JSON decoder core Perl ships -- decodes it at
# about 1 MB/s: `derive-session` measured 154s on one real session. Almost
# all of those bytes are tool output, file contents and thinking text that
# nothing here reads.
#
# So a line is not decoded whole. A strict JSON grammar, written as a
# recursive regex (it runs in the regex engine, in C), validates the line and
# splits objects into members; only the handful of fields
# _session_read_agent_file reads are decoded, into a THIN record with exactly
# the shape JSON::PP would have given them. Same session: 12s.
#
# The result must equal a JSON::PP decode exactly. Any line the grammar
# cannot vouch for returns undef and takes the full JSON::PP decode instead,
# so malformed lines are still judged by JSON::PP alone
# (record_counts.skipped_unparseable is unchanged). The grammar follows
# RFC 8259 exactly as JSON::PP enforces it (no raw control characters in
# strings, no unknown escapes, no leading zeros); the three things JSON::PP
# also rejects that a regex does not see -- invalid UTF-8, unpaired
# surrogate escapes, nesting deeper than 512 -- send the line to JSON::PP.
# Scalars take JSON::PP too unless they are plain printable ASCII strings or
# integers of at most 15 digits, because _safe_usage_num judges the DECODED
# value and JSON::PP decodes a long integer to its exact digit string, where
# `0 + $raw` would give a rounded float (25 digits: the string passes
# _safe_usage_num's /^\d+\z/, the float's "1.23e+24" does not).
# Measured before landing: all 32,290 lines of a real session gave
# field-for-field the same record through both paths;
# spend-session-fast-reader.t pins the edge cases.
# ---------------------------------------------------------------------------
our $SESSION_JSON_GRAMMAR = qr{
    (?(DEFINE)
        (?<str> " [^"\\\x00-\x1f]*+ (?: \\ (?: ["\\/bfnrt] | u[0-9a-fA-F]{4} ) [^"\\\x00-\x1f]*+ )*+ " )
        (?<num> -?+ (?: 0 | [1-9][0-9]*+ ) (?: \.[0-9]++ )?+ (?: [eE][-+]?+[0-9]++ )?+ )
        (?<ws>  [\x20\x09\x0a\x0d]*+ )
        (?<val> (?&str) | (?&num) | (?&obj) | (?&arr) | true | false | null )
        (?<obj> \{ (?&ws) (?: (?&str) (?&ws) : (?&ws) (?&val) (?&ws)
                              (?: , (?&ws) (?&str) (?&ws) : (?&ws) (?&val) (?&ws) )*+ )?+ \} )
        (?<arr> \[ (?&ws) (?: (?&val) (?&ws) (?: , (?&ws) (?&val) (?&ws) )*+ )?+ \] )
    )
}x;
my $SESSION_MEMBER_RE = qr{ \G (?&ws) ( (?&str) ) (?&ws) : (?&ws) ( (?&val) ) (?&ws) ( [,\}] ) $SESSION_JSON_GRAMMAR }x;
my $SESSION_ELEM_RE   = qr{ \G (?&ws) (?&val) (?&ws) ( [,\]] ) $SESSION_JSON_GRAMMAR }x;
my $SESSION_JSON_ONE  = JSON::PP->new->utf8->allow_nonref;
my $SESSION_JSON_LINE = JSON::PP->new->utf8;

# _session_json_members($text) -> [ [key, raw-value-text], ... ] in document
# order for a text that is exactly one JSON object, else undef.
sub _session_json_members {
    my ($t) = @_;
    pos($t) = 0;
    $t =~ /\G[\x20\x09\x0a\x0d]*\{[\x20\x09\x0a\x0d]*/gc or return undef;
    my @members;
    unless ($t =~ /\G\}/gc) {
        while (1) {
            $t =~ /$SESSION_MEMBER_RE/gc or return undef;
            my ($k, $v, $sep) = ($1, $2, $3);
            push @members, [ _session_json_scalar($k), $v ];
            last if $sep eq '}';
        }
    }
    return ($t =~ /\G[\x20\x09\x0a\x0d]*\z/gc) ? \@members : undef;
}

# _session_json_array_len($text) -> element count of a text that is exactly
# one JSON array, else undef.
sub _session_json_array_len {
    my ($t) = @_;
    pos($t) = 0;
    $t =~ /\G[\x20\x09\x0a\x0d]*\[[\x20\x09\x0a\x0d]*/gc or return undef;
    my $n = 0;
    unless ($t =~ /\G\]/gc) {
        while (1) {
            $t =~ /$SESSION_ELEM_RE/gc or return undef;
            $n++;
            last if $1 eq ']';
        }
    }
    return ($t =~ /\G[\x20\x09\x0a\x0d]*\z/gc) ? $n : undef;
}

# _session_json_scalar($raw) -> exactly what JSON::PP (utf8, allow_nonref)
# returns for one grammar-valid JSON value.
sub _session_json_scalar {
    my ($raw) = @_;
    return substr($raw, 1, -1) if $raw =~ /\A"[\x20\x21\x23-\x5b\x5d-\x7e]*"\z/;
    return 0 + $raw            if $raw =~ /\A(?:0|[1-9][0-9]{0,14})\z/;
    return $SESSION_JSON_ONE->decode($raw);
}

# _session_json_pick($raw, \%scalars, \%nested) -> for a raw OBJECT value, a
# hashref holding only the keys named in %scalars (decoded as scalars) and
# %nested (key => coderef applied to the raw sub-value); any other raw value
# decodes as-is. Duplicate keys: last wins, as in JSON::PP.
sub _session_json_pick {
    my ($raw, $scalars, $nested) = @_;
    return _session_json_scalar($raw) unless $raw =~ /\A\{/;
    my $members = _session_json_members($raw) or return _session_json_scalar($raw);
    my %h;
    for my $m (@$members) {
        my ($k, $v) = @$m;
        if    ($scalars->{$k})         { $h{$k} = _session_json_scalar($v) }
        elsif ($nested && $nested->{$k}) { $h{$k} = $nested->{$k}->($v) }
    }
    return \%h;
}

my %SESSION_THIN_TOP   = map { $_ => 1 } qw(type timestamp requestId effort uuid session_id);
my %SESSION_THIN_MSG   = map { $_ => 1 } qw(model id);
my %SESSION_THIN_USAGE = map { $_ => 1 } qw(input_tokens output_tokens cache_read_input_tokens
                                            cache_creation_input_tokens speed);
my %SESSION_THIN_CC    = map { $_ => 1 } qw(ephemeral_5m_input_tokens ephemeral_1h_input_tokens);

my %SESSION_THIN_USAGE_NESTED = (
    cache_creation => sub { _session_json_pick($_[0], \%SESSION_THIN_CC) },
    # Only the element count is ever read (multi_iteration), so the array is
    # counted, not decoded: a list of that many placeholders.
    iterations     => sub {
        my $n = ($_[0] =~ /\A\[/) ? _session_json_array_len($_[0]) : undef;
        return defined($n) ? [ (undef) x $n ] : _session_json_scalar($_[0]);
    },
);
my %SESSION_THIN_MSG_NESTED = (
    usage => sub { _session_json_pick($_[0], \%SESSION_THIN_USAGE, \%SESSION_THIN_USAGE_NESTED) },
);

# _session_thin_record($line) -> thin record (see the block comment above),
# or undef when the line must take the full JSON::PP decode.
sub _session_thin_record {
    my ($line) = @_;
    return undef if $line =~ /[\x80-\xff]/ && !do { my $c = $line; utf8::decode($c) };
    return undef if $line =~ /\\u[dD][89abAB]/;
    # Only a line holding 512+ brackets can nest past JSON::PP's limit, so
    # only such a line pays for counting the brackets outside strings.
    if (($line =~ tr/{[//) > 512) {
        (my $s = $line) =~ s/"[^"\\]*+(?:\\.[^"\\]*+)*+"//g;
        return undef if ($s =~ tr/{[//) > 512;
    }
    my $top = _session_json_members($line) or return undef;
    my %rec;
    for my $m (@$top) {
        my ($k, $v) = @$m;
        if ($SESSION_THIN_TOP{$k}) {
            $rec{$k} = _session_json_scalar($v);
        }
        elsif ($k eq 'message') {
            $rec{message} = _session_json_pick($v, \%SESSION_THIN_MSG, \%SESSION_THIN_MSG_NESTED);
        }
    }
    return \%rec;
}

# ---------------------------------------------------------------------------
# _session_read_agent_file($path, \%record_counts) -> ( \@order, \%requests,
# $first_ts ). Reads one agent transcript, deduplicates its assistant records
# into per-request entries keyed per B1, and returns them in
# first-appearance file order (@order holds the keys). Every usage figure is
# read through the shared _safe_usage_num($val, \%record_counts) so
# malformed fields tally centrally (spec §2.1).
# ---------------------------------------------------------------------------
sub _session_read_agent_file {
    my ($path, $counts) = @_;

    my @order;
    my %requests;
    my $first_ts;
    my $unkeyed_n = 0;

    open(my $fh, '<:raw', $path) or return (\@order, \%requests, undef);

    while (defined(my $line = <$fh>)) {
        $line =~ s/\r?\n\z//;
        next unless length $line;

        my $rec = _session_thin_record($line)
            // eval { $SESSION_JSON_LINE->decode($line) };
        if (ref($rec) ne 'HASH') {
            $counts->{skipped_unparseable}++;
            next;
        }

        if (defined $rec->{timestamp} && !ref($rec->{timestamp})) {
            my $ts = _session_parse_ts($rec->{timestamp});
            if (defined $ts && (!defined($first_ts) || $ts < $first_ts)) {
                $first_ts = $ts;
            }
        }

        next unless defined($rec->{type}) && $rec->{type} eq 'assistant'
            && ref($rec->{message}) eq 'HASH'
            && ref($rec->{message}{usage}) eq 'HASH';

        $counts->{assistant_records}++;
        my $usage = $rec->{message}{usage};

        if (ref($usage->{iterations}) eq 'ARRAY' && scalar(@{ $usage->{iterations} }) > 1) {
            $counts->{multi_iteration}++;
        }
        $counts->{speed_absent}++ unless defined $usage->{speed};

        my $key;
        if (defined($rec->{requestId}) && !ref($rec->{requestId}) && length($rec->{requestId})) {
            $key = "id:$rec->{requestId}";
        }
        elsif (defined($rec->{message}{id}) && !ref($rec->{message}{id}) && length($rec->{message}{id})) {
            $key = "mid:$rec->{message}{id}";
        }
        else {
            $key = "u:" . (++$unkeyed_n);
            $counts->{unkeyed}++;
        }

        my $input      = _safe_usage_num($usage->{input_tokens}, $counts);
        my $output     = _safe_usage_num($usage->{output_tokens}, $counts);
        my $cache_read = _safe_usage_num($usage->{cache_read_input_tokens}, $counts);
        my $cc_unsplit = _safe_usage_num($usage->{cache_creation_input_tokens}, $counts);
        my ($cc_5m, $cc_1h) = (0, 0);
        my $has_split_hash = ref($usage->{cache_creation}) eq 'HASH';
        if ($has_split_hash) {
            $cc_5m = _safe_usage_num($usage->{cache_creation}{ephemeral_5m_input_tokens}, $counts);
            $cc_1h = _safe_usage_num($usage->{cache_creation}{ephemeral_1h_input_tokens}, $counts);
        }
        my $use_split = $has_split_hash && ($cc_5m + $cc_1h > 0);

        my $uuid       = (defined($rec->{uuid}) && !ref($rec->{uuid})) ? $rec->{uuid} : '';
        my $session_id = (defined($rec->{session_id}) && !ref($rec->{session_id})) ? $rec->{session_id} : '';

        my $req = $requests{$key};
        if (!$req) {
            $req = $requests{$key} = {
                output          => $output,
                input           => $input,
                cache_read      => $cache_read,
                cc_unsplit      => $cc_unsplit,
                cc_5m           => $cc_5m,
                cc_1h           => $cc_1h,
                use_split       => $use_split,
                model           => $rec->{message}{model},
                effort          => $rec->{effort},
                speed           => $usage->{speed},
                first_uuid      => $uuid,
                first_session_id => $session_id,
                mismatched      => 0,
            };
            push @order, $key;
        }
        else {
            $req->{output} = $output if $output > $req->{output};
            if (!$req->{mismatched}
                && (   $input      != $req->{input}
                    || $cache_read != $req->{cache_read}
                    || $cc_unsplit != $req->{cc_unsplit}
                    || $cc_5m      != $req->{cc_5m}
                    || $cc_1h      != $req->{cc_1h})) {
                $req->{mismatched} = 1;
                $counts->{request_usage_mismatch}++;
            }
            $req->{input}      = $input;
            $req->{cache_read} = $cache_read;
            $req->{cc_unsplit} = $cc_unsplit;
            $req->{cc_5m}      = $cc_5m;
            $req->{cc_1h}      = $cc_1h;
            $req->{use_split}  = $use_split;
            $req->{model}      = $rec->{message}{model};
            $req->{effort}     = $rec->{effort};
            $req->{speed}      = $usage->{speed};
        }
    }
    close $fh;

    $counts->{requests} += scalar(@order);
    return (\@order, \%requests, $first_ts);
}

# ---------------------------------------------------------------------------
# _session_price_request($req, $role) -> ( \@cells, \%unpriced_deltas ).
# Prices one deduplicated request's non-zero token-type amounts per the
# precedence of spec B9 -- exactly one reason applies to any unpriced
# amount:
#   1. request speed present and != 'standard' -> non-standard-speed
#   2. else model not a key of %SESSION_PRICES  -> model-not-in-table
#   3. else token type is cache_write_unsplit   -> cache-write-unsplit
#   4. else priced: cost = tokens / 1_000_000 * rate[model][token_type]
# ---------------------------------------------------------------------------
sub _session_price_request {
    my ($req, $role) = @_;

    my $model  = _norm_scalar_or_unknown($req->{model});
    my $effort = _norm_scalar_or_unknown($req->{effort});
    # No `!ref` guard here (fix-batch review L3, per spec B8's literal
    # wording): a ref-valued (boolean/object/array) `speed` is still PRESENT
    # and is not the exact string 'standard', so it must be treated as
    # non-standard-speed, not silently priced as standard.
    my $non_standard_speed = defined($req->{speed})
        && (ref($req->{speed}) || $req->{speed} ne 'standard');

    my %amounts;
    $amounts{input}               = $req->{input};
    $amounts{output}              = $req->{output};
    $amounts{cache_read}          = $req->{cache_read};
    if ($req->{use_split}) {
        $amounts{cache_write_5m}       = $req->{cc_5m};
        $amounts{cache_write_1h}       = $req->{cc_1h};
        $amounts{cache_write_unsplit}  = 0;
    }
    else {
        $amounts{cache_write_5m}       = 0;
        $amounts{cache_write_1h}       = 0;
        $amounts{cache_write_unsplit}  = $req->{cc_unsplit};
    }

    my @cells;
    my %unpriced_deltas;
    for my $type (qw(input output cache_write_5m cache_write_1h cache_read cache_write_unsplit)) {
        my $tokens = $amounts{$type};
        next unless $tokens > 0;

        my $reason;
        my $cost = 0;
        if ($non_standard_speed) {
            $reason = 'non-standard-speed';
        }
        elsif (!exists $SESSION_PRICES{$model}) {
            $reason = 'model-not-in-table';
        }
        elsif ($type eq 'cache_write_unsplit') {
            $reason = 'cache-write-unsplit';
        }
        else {
            $cost = $tokens / 1_000_000 * $SESSION_PRICES{$model}{$type};
        }

        my $unpriced_tokens = defined($reason) ? $tokens : 0;
        $unpriced_deltas{$reason} += $tokens if defined $reason;

        push @cells, {
            role => $role, model => $model, effort => $effort, token_type => $type,
            tokens => $tokens, cost_usd => $cost, unpriced_tokens => $unpriced_tokens,
        };
    }

    return (\@cells, \%unpriced_deltas);
}

# ---------------------------------------------------------------------------
# _session_agent_anomaly(\@order, \%requests, $role) -> \%anomaly. Mirrors
# bp-spend.pl's consecutive-same-size-cache-write anomaly (:757-770), but
# DELIBERATELY keyed by the agent FILE alone, not (session_id, role): within
# one file every request is the same conversation branch, and session_id is
# shared across every file of a drive-solo session, so keying by it here
# would compare unrelated branches (spec B11).
# ---------------------------------------------------------------------------
sub _session_agent_anomaly {
    my ($order, $requests, $role) = @_;

    my @pairs;
    my $prev;
    for my $key (@$order) {
        my $req  = $requests->{$key};
        my $size = $req->{cc_unsplit};
        next if $size == 0;
        if (defined($prev) && $prev->{size} == $size) {
            push @pairs, {
                session_id  => $req->{first_session_id},
                role        => $role,
                size        => $size,
                first_uuid  => $prev->{first_uuid},
                second_uuid => $req->{first_uuid},
            };
        }
        $prev = { size => $size, first_uuid => $req->{first_uuid} };
    }

    my $total = 0;
    $total += $_->{size} for @pairs;
    return {
        name         => 'consecutive-same-size-cache-write',
        count        => scalar(@pairs),
        total_tokens => $total,
        pairs        => \@pairs,
    };
}

# ---------------------------------------------------------------------------
# _session_cell_key($cell) -> the (role, model, effort, token_type) string
# key used to merge cells emitted by different requests/agents into one.
# ---------------------------------------------------------------------------
sub _session_cell_key {
    my ($c) = @_;
    # \x1e-escape each field before joining (fix-batch redteam L4): without
    # this, a field containing a literal \x1e could collide two genuinely
    # distinct cells into one.
    return join("\x1e", map { (my $x = defined($_) ? $_ : ''); $x =~ s/\x1e/\x1e\x1e/g; $x }
        ($c->{role}, $c->{model}, $c->{effort}, $c->{token_type}));
}

# ---------------------------------------------------------------------------
# _session_merge_cells(\%acc, \@cells) -> merges @cells into %acc in place,
# keyed by _session_cell_key.
# ---------------------------------------------------------------------------
sub _session_merge_cells {
    my ($acc, $cells) = @_;
    for my $c (@$cells) {
        my $k = _session_cell_key($c);
        my $entry = ($acc->{$k} //= {
            role => $c->{role}, model => $c->{model}, effort => $c->{effort},
            token_type => $c->{token_type}, tokens => 0, cost_usd => 0, unpriced_tokens => 0,
        });
        $entry->{tokens}          += $c->{tokens};
        $entry->{cost_usd}        += $c->{cost_usd};
        $entry->{unpriced_tokens} += $c->{unpriced_tokens};
    }
    return;
}

# ---------------------------------------------------------------------------
# _session_sorted_cells(\%acc) -> \@cells, rounded per B10 (0 +
# sprintf('%.6f', $c) once at emission), sorted ascending by role, then
# model, then effort, then token_type (cmp on each), zero-tokens cells
# dropped.
# ---------------------------------------------------------------------------
sub _session_sorted_cells {
    my ($acc) = @_;
    my @cells =
        grep { $_->{tokens} > 0 }
        map  {
            my $c = $acc->{$_};
            {
                role => $c->{role}, model => $c->{model}, effort => $c->{effort},
                token_type => $c->{token_type}, tokens => int($c->{tokens}),
                cost_usd => 0 + sprintf('%.6f', $c->{cost_usd}),
                unpriced_tokens => int($c->{unpriced_tokens}),
            };
        }
        keys %$acc;
    @cells = sort {
           $a->{role} cmp $b->{role}
        || $a->{model} cmp $b->{model}
        || $a->{effort} cmp $b->{effort}
        || $a->{token_type} cmp $b->{token_type}
    } @cells;
    return \@cells;
}

# ---------------------------------------------------------------------------
# derive_session(%opts) -> \%session_result. See spec §2.1-2.5.
#   opts: session => PATH (required)
# Dies (never returns a partial doc) when the session's main transcript
# cannot be resolved or opened.
# ---------------------------------------------------------------------------
sub derive_session {
    my (%opts) = @_;
    my $session = $opts{session};

    my $p = defined($session) ? $session : '';
    $p =~ s{[/\\]+\z}{};

    my ($main, $dir);
    if ($p =~ /\.jsonl\z/) {
        $main = $p;
        ($dir = $p) =~ s/\.jsonl\z//;
    }
    else {
        $dir  = $p;
        $main = "$p.jsonl";
    }
    my $subdir = "$dir/subagents";

    unless (length($main) && -f $main) {
        die "derive_session: no such session transcript: " . _session_truncate_for_error($session) . "\n";
    }
    # An existing-but-unopenable main transcript (permissions, a Windows
    # sharing lock, etc.) must not silently report an all-zero document as if
    # the session were genuinely empty (fix-batch redteam M4/review L1) --
    # only the MAIN transcript is fatal here; subagent files stay non-fatal
    # on open failure via _session_read_agent_file.
    unless (open(my $main_probe_fh, '<:raw', $main)) {
        die "derive_session: no such session transcript: " . _session_truncate_for_error($session) . "\n";
    }
    else {
        close $main_probe_fh;
    }

    my @agent_files;   # { path => STR, kind => 'driver'|'subagent', name => STR }
    push @agent_files, { path => $main, kind => 'driver' };
    if (-d $subdir) {
        my $dh;
        opendir($dh, $subdir);
        if ($dh) {
            my @names = sort grep { /^agent-.*\.jsonl\z/ && -f "$subdir/$_" } readdir($dh);
            closedir $dh;
            for my $n (@names) {
                push @agent_files, { path => "$subdir/$n", kind => 'subagent', name => $n };
            }
        }
    }

    my $record_counts = {
        assistant_records       => 0,
        requests                => 0,
        unkeyed                 => 0,
        request_usage_mismatch  => 0,
        multi_iteration         => 0,
        speed_absent            => 0,
        skipped_unparseable     => 0,
        malformed_usage_field   => 0,
    };

    my %session_cell_acc;
    my %unpriced = ('model-not-in-table' => 0, 'cache-write-unsplit' => 0, 'non-standard-speed' => 0);
    my @agents;
    my @session_pairs;

    for my $af (@agent_files) {
        my ($role, $spawn_depth, $description);
        if ($af->{kind} eq 'driver') {
            $role = 'driver';
            $spawn_depth = 0;
            $description = undef;
        }
        else {
            (my $base = $af->{name}) =~ s/\.jsonl\z//;
            my $meta = _session_read_sidecar("$subdir/$base.meta.json");
            if (ref($meta) eq 'HASH' && defined($meta->{agentType}) && !ref($meta->{agentType}) && length($meta->{agentType})) {
                $role = $meta->{agentType};
            }
            else {
                $role = 'unknown-agent';
            }
            if (ref($meta) eq 'HASH' && defined($meta->{spawnDepth}) && !ref($meta->{spawnDepth})
                && $meta->{spawnDepth} =~ /^\d+\z/) {
                $spawn_depth = $meta->{spawnDepth} + 0;
            }
            else {
                $spawn_depth = undef;
            }
            if (ref($meta) eq 'HASH' && defined($meta->{description}) && !ref($meta->{description})
                && length($meta->{description})) {
                $description = $meta->{description};
            }
            else {
                $description = undef;
            }
        }

        my ($order, $requests, $first_ts) = _session_read_agent_file($af->{path}, $record_counts);

        my %agent_cell_acc;
        for my $key (@$order) {
            my $req = $requests->{$key};
            my ($cells, $deltas) = _session_price_request($req, $role);
            _session_merge_cells(\%agent_cell_acc, $cells);
            _session_merge_cells(\%session_cell_acc, $cells);
            for my $reason (keys %$deltas) {
                $unpriced{$reason} += $deltas->{$reason};
            }
        }

        my $anomaly = _session_agent_anomaly($order, $requests, $role);
        push @session_pairs, @{ $anomaly->{pairs} };

        push @agents, {
            path        => _session_slashify($af->{path}),
            role        => $role,
            spawn_depth => $spawn_depth,
            description => $description,
            first_ts    => $first_ts,
            cells       => _session_sorted_cells(\%agent_cell_acc),
            anomaly     => $anomaly,
        };
    }

    my $session_cells = _session_sorted_cells(\%session_cell_acc);

    my %totals;
    for my $type (qw(input output cache_write_5m cache_write_1h cache_read cache_write_unsplit)) {
        $totals{$type} = { tokens => 0, cost_usd => 0, unpriced_tokens => 0 };
    }
    # Accumulated from the UNROUNDED %session_cell_acc, not from $session_cells
    # (whose cost_usd is already rounded to 6dp by _session_sorted_cells) --
    # fix-batch review M1/redteam L8/n2: summing already-rounded per-cell
    # figures and rounding the sum again is a double-round. Rounding happens
    # exactly once, below, at final emission.
    for my $c (values %session_cell_acc) {
        $totals{ $c->{token_type} }{tokens}          += $c->{tokens};
        $totals{ $c->{token_type} }{cost_usd}        += $c->{cost_usd};
        $totals{ $c->{token_type} }{unpriced_tokens} += $c->{unpriced_tokens};
    }
    for my $type (keys %totals) {
        $totals{$type}{cost_usd} = 0 + sprintf('%.6f', $totals{$type}{cost_usd});
    }

    my $session_anomaly_total = 0;
    $session_anomaly_total += $_->{size} for @session_pairs;

    return {
        cost_basis   => 'notional-api-equivalent',
        price_source => $SESSION_PRICE_SOURCE,
        price_as_of  => $SESSION_PRICE_AS_OF,
        cells        => $session_cells,
        totals       => \%totals,
        unpriced     => \%unpriced,
        anomaly      => {
            name         => 'consecutive-same-size-cache-write',
            count        => scalar(@session_pairs),
            total_tokens => $session_anomaly_total,
            pairs        => \@session_pairs,
        },
        record_counts => $record_counts,
        agents        => \@agents,
    };
}

# ===========================================================================
# Package 02 -- attribution and report (blueprint usage-telemetry, package
# 02-attribution-and-report). Attributes each derive_session() agent entry to
# a blueprint/package via bp-dispatch-log.pl's dispatch records and the
# on-disk blueprint ledgers, then pivots package 01's agents[].cells by any
# ordered subset of role/blueprint/package/model/effort/token_type. Pure
# functions except for the filesystem reads named in their own docs; the CLI
# verb at the bottom of this file is the only writer-adjacent caller (and it
# never writes -- read-only, spec §2.7 B12).
# Spec: .ccpraxis-local-data/blueprints/usage-telemetry/specs/
# 02-attribution-and-report-spec.md
# ===========================================================================
use File::Basename qw(dirname);
use Cwd qw(abs_path);

# Mirrors bp-spend.pl:51-52's require idiom exactly (spec §2.1) -- re-derives
# its own $DISPATCH_DIR rather than reaching across packages for BpSpend's
# file-scoped $DIR. bp-dispatch-log.pl guards its own CLI with `unless
# (caller)` and ends `1;`, so this require is side-effect-free. The ONLY
# symbol used from it is $BpDispatchLog::DEFAULT_BUDGET_SECONDS --
# list_records/read_record/log_dir take the repo root, not the data root, and
# are never called (out of scope, spec §6).
my $DISPATCH_DIR = dirname(do { (my $f = __FILE__) =~ s{\\}{/}g; abs_path($f) // $f });
# Soft require: bp-orchestrator.pl, bp-spend-auth.pl and the launcher's spend
# sampler all load bp-spend.pl at their own load time, so a compile failure in
# bp-dispatch-log.pl must not take them down too. $DISPATCH_DEFAULT_BUDGET_FALLBACK
# below covers the anomaly path where this failed or the upstream constant is
# missing/renamed; the NORMAL path still reads
# $BpDispatchLog::DEFAULT_BUDGET_SECONDS by its fully-qualified name (spec §2.1).
eval { require "$DISPATCH_DIR/bp-dispatch-log.pl"; 1 };

# Anomaly-path-only fallback -- used ONLY if the require above failed or
# $BpDispatchLog::DEFAULT_BUDGET_SECONDS is missing/renamed upstream. Never
# read in the normal path (spec §2.1 forbids re-typing 1800 as the
# normal-path value, not as an anomaly fallback).
our $DISPATCH_DEFAULT_BUDGET_FALLBACK = 1800;

our @REPORT_DIMENSIONS        = qw(role blueprint package model effort token_type);
our @REPORT_DEFAULT_BY        = qw(role model);
our @ATTRIBUTION_REASONS      = qw(unknown-agent ambiguous id-unresolved no-dispatch-record outside-window);
our $DRIVER_LABEL             = '(driver)';
our $UNATTRIBUTED_LABEL       = 'unattributed';
our $ATTRIBUTION_LEAD_SECONDS = 120;

our @REPORT_TOKEN_TYPES = qw(input output cache_write_5m cache_write_1h cache_read cache_write_unsplit);

# ---------------------------------------------------------------------------
# resolve_data_root($explicit, $session) -> ( slashified data-root path,
# source ). In order:
#   1. --data-root, verbatim                             -> 'explicit'
#   2. the nearest .ccpraxis-local-data at or above the
#      `cwd` the SESSION recorded                        -> 'session-cwd'
#   3. $CLAUDE_PROJECT_DIR/.ccpraxis-local-data          -> 'CLAUDE_PROJECT_DIR'
#   4. <this script>/../../../.ccpraxis-local-data       -> 'script-location'
# Step 2 is first among the defaults because the question is "which project
# did THIS session run in", and the session says so itself. Steps 3-4 were
# the whole default before it, and step 4 is wrong in exactly the normal
# case: run from the live install, it names the live install's own data dir,
# so on 2026-09-23 report-session read 21 stray records there instead of the
# project's 552 and attributed 0 of 605M subagent tokens. Only step 2 checks
# the filesystem; steps 1, 3 and 4 never do (spec §2.3).
# ---------------------------------------------------------------------------
sub resolve_data_root {
    my ($explicit, $session) = @_;
    if (defined $explicit && length $explicit) {
        (my $r = $explicit) =~ s{\\}{/}g;
        $r =~ s{/+\z}{};
        return wantarray ? ($r, 'explicit') : $r;
    }
    my ($root, $source);
    if (defined(my $cwd = _session_recorded_cwd($session))) {
        my ($d, $prev, $n) = ($cwd, '', 0);
        while (length($d) && $d ne $prev && $n++ < 64) {
            my $cand = ($d eq '/') ? '/.ccpraxis-local-data' : "$d/.ccpraxis-local-data";
            if (-d $cand) { ($root, $source) = ($d, 'session-cwd'); last }
            $prev = $d;
            $d =~ s{/[^/]*\z}{};
            $d = '/' if $d eq '' && $prev =~ m{\A/};
        }
    }
    if (!defined $root && defined $ENV{CLAUDE_PROJECT_DIR} && length $ENV{CLAUDE_PROJECT_DIR}) {
        ($root, $source) = ($ENV{CLAUDE_PROJECT_DIR}, 'CLAUDE_PROJECT_DIR');
    }
    if (!defined $root) {
        ($root, $source) = (Cwd::abs_path("$DISPATCH_DIR/../../..") // '.', 'script-location');
    }
    (my $r = $root) =~ s{\\}{/}g;
    $r =~ s{/+\z}{};
    $r .= '/.ccpraxis-local-data';
    return wantarray ? ($r, $source) : $r;
}

# ---------------------------------------------------------------------------
# _session_recorded_cwd($session) -> the slashified `cwd` the session's main
# transcript records, or undef. Claude Code stamps `cwd` on its records from
# the first line on, so this reads at most the first 200 lines and skips any
# line over 1 MiB rather than parsing a large one to find a small field.
# ---------------------------------------------------------------------------
sub _session_recorded_cwd {
    my ($session) = @_;
    return undef unless defined $session && length $session;
    (my $main = $session) =~ s{[/\\]+\z}{};
    $main .= '.jsonl' unless $main =~ /\.jsonl\z/;
    open(my $fh, '<:raw', $main) or return undef;
    my $cwd;
    my $n = 0;
    while (defined(my $line = <$fh>)) {
        last if ++$n > 200;
        next if length($line) > 1_048_576;
        $line =~ s/\r?\n\z//;
        my $members = _session_json_members($line) or next;
        for my $m (@$members) {
            next unless $m->[0] eq 'cwd';
            my $v = eval { _session_json_scalar($m->[1]) };
            $cwd = $v if defined($v) && !ref($v) && length($v);
        }
        last if defined $cwd;
    }
    close $fh;
    return undef unless defined $cwd;
    $cwd =~ s{\\}{/}g;
    $cwd =~ s{/+\z}{} unless $cwd eq '/';
    return $cwd;
}

# ---------------------------------------------------------------------------
# load_dispatch_records($data_root) -> \@records (never dies). Spec §2.4.
# ---------------------------------------------------------------------------
sub load_dispatch_records {
    my ($data_root) = @_;
    my $dir = "$data_root/.dispatch-log";
    my @records;
    my $dh;
    return [] unless opendir($dh, $dir);
    my @names = sort readdir($dh);
    closedir $dh;
    for my $name (@names) {
        next unless $name =~ /\.json\z/;
        my $path = "$dir/$name";
        next unless -f $path;
        (my $base = $name) =~ s/\.json\z//;
        next if $base =~ /\Ahk-/;
        open(my $fh, '<:raw', $path) or next;
        my $raw = do { local $/; <$fh> };
        close $fh;
        my $rec = eval { JSON::PP->new->utf8->decode($raw) };
        next unless ref($rec) eq 'HASH';
        my $id = (defined $rec->{id} && !ref($rec->{id}) && length($rec->{id})) ? $rec->{id} : $base;
        # SANITISED: $id/worker_type/blueprint/package are record-sourced and
        # can reach a text report or a JSON row key. Control bytes are
        # stripped and length capped so a hostile record can neither inject a
        # line break/ANSI escape into the report nor collide two distinct
        # blueprint/package names into the same \x1f-joined row key via an
        # embedded \x1f byte. Same precedent as _gate_diagnostic above.
        $id =~ tr/\x00-\x1f\x7f//d;
        $id = substr($id, 0, 120) if length($id) > 120;
        next if $id =~ /\Ahk-/;
        next unless defined $rec->{worker_type} && !ref($rec->{worker_type}) && length($rec->{worker_type});
        next unless defined $rec->{started_at} && !ref($rec->{started_at}) && $rec->{started_at} =~ /\A\d+(?:\.\d+)?\z/;
        my $started_at = $rec->{started_at} + 0;

        my $ended_at;
        if (defined $rec->{ended_at} && !ref($rec->{ended_at}) && $rec->{ended_at} =~ /\A\d+(?:\.\d+)?\z/) {
            my $e = $rec->{ended_at} + 0;
            $ended_at = $e if $e >= $started_at;
        }

        my $budget;
        if (defined $rec->{budget_seconds} && !ref($rec->{budget_seconds})
            && $rec->{budget_seconds} =~ /\A\d+(?:\.\d+)?\z/ && $rec->{budget_seconds} + 0 > 0) {
            $budget = $rec->{budget_seconds} + 0;
        }
        else {
            # Still the only code reference to this fully-qualified package
            # variable in this file (the require above is soft, so it can
            # legitimately never populate it) -- scoped no warnings 'once',
            # not a file-wide blanket.
            no warnings 'once';
            $budget = $BpDispatchLog::DEFAULT_BUDGET_SECONDS // $DISPATCH_DEFAULT_BUDGET_FALLBACK;
        }

        my $worker_type = $rec->{worker_type};
        $worker_type =~ tr/\x00-\x1f\x7f//d;
        $worker_type = substr($worker_type, 0, 120) if length($worker_type) > 120;

        my $blueprint = (defined $rec->{blueprint} && !ref($rec->{blueprint}) && length($rec->{blueprint}))
            ? $rec->{blueprint} : undef;
        if (defined $blueprint) {
            $blueprint =~ tr/\x00-\x1f\x7f//d;
            $blueprint = substr($blueprint, 0, 120) if length($blueprint) > 120;
        }
        my $package = (defined $rec->{package} && !ref($rec->{package}) && length($rec->{package}))
            ? $rec->{package} : undef;
        if (defined $package) {
            $package =~ tr/\x00-\x1f\x7f//d;
            $package = substr($package, 0, 120) if length($package) > 120;
        }

        push @records, {
            id => $id, worker_type => $worker_type, started_at => $started_at,
            ended_at => $ended_at, budget => $budget, blueprint => $blueprint, package => $package,
        };
    }
    return \@records;
}

# ---------------------------------------------------------------------------
# load_dispatch_attribution($data_root) -> { <tool_use_id> => { blueprint,
# package, source } } (never dies), from the append-only records
# hooks/record-dispatch-package.sh writes at dispatch time:
# <data_root>/.dispatch-log/attribution.jsonl, plus its one rolled-over
# predecessor attribution.jsonl.1. A tool_use_id recorded twice with
# DIFFERENT packages maps to { conflict => 1 } and attributes nothing -- two
# claims about one dispatch are not resolved by picking one. Names are held to
# the hook's own rule ([A-Za-z0-9._-], no leading dot, no '..'), so a
# hand-edited line cannot smuggle a control byte into a report row.
# ---------------------------------------------------------------------------
sub load_dispatch_attribution {
    my ($data_root) = @_;
    my %map;
    my $name_ok = sub {
        my ($v) = @_;
        return defined($v) && !ref($v) && $v =~ /\A[A-Za-z0-9._-]{1,120}\z/
            && $v !~ /\A\./ && $v !~ /\.\./;
    };
    for my $file ("$data_root/.dispatch-log/attribution.jsonl.1",
                  "$data_root/.dispatch-log/attribution.jsonl") {
        open(my $fh, '<:raw', $file) or next;
        while (defined(my $line = <$fh>)) {
            next if length($line) > 4096;
            $line =~ s/\r?\n\z//;
            my $members = _session_json_members($line) or next;
            my %f;
            for my $m (@$members) {
                my $v = eval { _session_json_scalar($m->[1]) };
                $f{ $m->[0] } = $v unless ref $v;
            }
            my $tuid = $f{tool_use_id};
            next unless defined($tuid) && $tuid =~ /\A[A-Za-z0-9_-]{1,128}\z/;
            next unless $name_ok->($f{blueprint}) && $name_ok->($f{package});
            my $source = (defined($f{source}) && $f{source} =~ /\A[a-z-]{1,32}\z/) ? $f{source} : 'unknown';
            my $prev = $map{$tuid};
            if ($prev && ($prev->{conflict}
                          || $prev->{blueprint} ne $f{blueprint} || $prev->{package} ne $f{package})) {
                $map{$tuid} = { conflict => 1 };
                next;
            }
            $map{$tuid} = { blueprint => $f{blueprint}, package => $f{package}, source => $source };
        }
        close $fh;
    }
    return \%map;
}

# ---------------------------------------------------------------------------
# _session_agent_tool_use_id($agent_path) -> the `toolUseId` in the agent
# file's `.meta.json` sidecar, or undef. Claude Code writes the id of the
# Agent tool call that spawned the subagent there; it is the same id a
# PreToolUse hook sees as `tool_use_id` (verified 2026-09-23: every sidecar
# sampled matched a tool_use block `id` in its parent transcript).
# ---------------------------------------------------------------------------
sub _session_agent_tool_use_id {
    my ($agent_path) = @_;
    return undef unless defined($agent_path) && $agent_path =~ /\.jsonl\z/;
    (my $meta_path = $agent_path) =~ s/\.jsonl\z/.meta.json/;
    my $meta = _session_read_sidecar($meta_path);
    return undef unless ref($meta) eq 'HASH';
    my $id = $meta->{toolUseId};
    return (defined($id) && !ref($id) && $id =~ /\A[A-Za-z0-9_-]{1,128}\z/) ? $id : undef;
}

# ---------------------------------------------------------------------------
# _blueprint_packages($bp_dir) -> { <int> => [ <ledger-id>, ... ] }, built
# from $bp_dir/packages/*.md. Private, used only by blueprint_index below.
# ---------------------------------------------------------------------------
sub _blueprint_packages {
    my ($bp_dir) = @_;
    my %packages;
    my $pkg_dir = "$bp_dir/packages";
    my $dh;
    return {} unless opendir($dh, $pkg_dir);
    my @names = sort readdir($dh);
    closedir $dh;
    for my $name (@names) {
        next unless $name =~ /\.md\z/;
        my $path = "$pkg_dir/$name";
        next unless -f $path;
        (my $ledger_id = $name) =~ s/\.md\z//;
        next unless $ledger_id =~ /\A(\d+)/;
        my $n = $1 + 0;
        push @{ $packages{$n} //= [] }, $ledger_id;
    }
    return \%packages;
}

# ---------------------------------------------------------------------------
# blueprint_index($data_root) -> { <name> => { archived => 0|1, packages =>
# {...} } }. Spec §2.5. A name present under both blueprints/ and
# blueprints/_archive/ resolves to the active one; the archived entry is
# discarded outright.
# ---------------------------------------------------------------------------
sub blueprint_index {
    my ($data_root) = @_;
    my %index;

    my $active_dir = "$data_root/blueprints";
    if (opendir(my $dh, $active_dir)) {
        my @names = sort readdir($dh);
        closedir $dh;
        for my $name (@names) {
            next if $name eq '.' || $name eq '..' || $name eq '_archive';
            next unless -d "$active_dir/$name";
            $index{$name} = { archived => 0, packages => _blueprint_packages("$active_dir/$name") };
        }
    }

    my $archive_dir = "$data_root/blueprints/_archive";
    if (opendir(my $dh2, $archive_dir)) {
        my @names = sort readdir($dh2);
        closedir $dh2;
        for my $name (@names) {
            next if $name eq '.' || $name eq '..';
            next unless -d "$archive_dir/$name";
            next if exists $index{$name};   # active-over-archive
            $index{$name} = { archived => 1, packages => _blueprint_packages("$archive_dir/$name") };
        }
    }

    return \%index;
}

# ---------------------------------------------------------------------------
# _resolve_bp_pkg($record, $index) -> ($blueprint, $package, $source) |
# (undef, undef). Spec §2.6/B3. $record is already-normalised (load_dispatch_
# records shape, or an equivalent plain hash passed directly by a caller).
# ---------------------------------------------------------------------------
sub _resolve_bp_pkg {
    my ($rec, $index) = @_;

    if (defined $rec->{blueprint} && !ref($rec->{blueprint}) && length($rec->{blueprint})
        && defined $rec->{package} && !ref($rec->{package}) && length($rec->{package})) {
        return ($rec->{blueprint}, $rec->{package}, 'record-fields');
    }

    my $id = defined $rec->{id} ? $rec->{id} : '';
    my $best_name;
    for my $name (keys %$index) {
        next unless $id =~ /\A\Q$name\E-/;
        $best_name = $name if !defined($best_name) || length($name) > length($best_name);
    }
    return (undef, undef) unless defined $best_name;

    my $rest  = substr($id, length($best_name) + 1);
    my $token = ($rest =~ /\A([^-]*)/) ? $1 : $rest;
    return (undef, undef) unless $token =~ /\A\d+\z/;
    my $n = $token + 0;

    my $bucket = $index->{$best_name}{packages}{$n};
    return (undef, undef) unless $bucket && @$bucket == 1;
    return ($best_name, $bucket->[0], 'record-id');
}

# ---------------------------------------------------------------------------
# attribute_session(doc => \%session_doc, records => \@records,
# index => \%blueprint_index, dispatch_hook => \%tool_use_id_map,
# tool_use_ids => \@ids) -> \@attributions (spec §2.6). Pure function:
# reads no file, no wall-clock. Entry 0 is always the driver (B6).
#
# An agent whose sidecar toolUseId ($tool_use_ids[$i]) has a
# record-dispatch-package.sh record is attributed from that record, source
# `dispatch-hook`: an exact key recorded when the dispatch happened, so it
# goes before every inference below. The dispatch-log time-window match and
# the description heuristic (B4) remain for sessions older than the hook,
# and for dispatches it did not see. dispatch_hook and tool_use_ids are
# optional; without them this is the spec §2.6 function unchanged.
# ---------------------------------------------------------------------------
sub attribute_session {
    my (%opts) = @_;
    my $doc     = $opts{doc}     // {};
    my $records = $opts{records} // [];
    my $index   = $opts{index}   // {};
    my $hook    = $opts{dispatch_hook} // {};
    my $tuids   = $opts{tool_use_ids}  // [];

    my @agents = @{ $doc->{agents} // [] };
    my @attrs;

    for my $i (0 .. $#agents) {
        my $agent = $agents[$i];
        if ($i == 0) {
            push @attrs, {
                path => $agent->{path}, role => $agent->{role}, kind => 'driver',
                blueprint => $DRIVER_LABEL, package => $DRIVER_LABEL,
                reason => undef, source => 'driver',
            };
            next;
        }

        my $role = $agent->{role};

        my $tuid = $tuids->[$i];
        my $hk   = defined($tuid) ? $hook->{$tuid} : undef;
        if ($hk && !$hk->{conflict}) {
            push @attrs, {
                path => $agent->{path}, role => $role, kind => 'attributed',
                blueprint => $hk->{blueprint}, package => $hk->{package},
                reason => undef, source => 'dispatch-hook',
            };
            next;
        }
        if (defined $role && $role eq 'unknown-agent') {
            push @attrs, {
                path => $agent->{path}, role => $role, kind => 'unattributed',
                blueprint => $UNATTRIBUTED_LABEL, package => $UNATTRIBUTED_LABEL,
                reason => 'unknown-agent', source => 'none',
            };
            next;
        }

        (my $wt = defined $role ? $role : '') =~ s/\A[^:]*://;
        my $t0 = $agent->{first_ts};
        my @candidates = grep { defined($_->{worker_type}) && $_->{worker_type} eq $wt } @$records;
        my @matches;
        if (defined $t0) {
            for my $r (@candidates) {
                my $end = defined($r->{ended_at}) ? $r->{ended_at} : $r->{started_at} + 4 * $r->{budget};
                push @matches, $r if ($r->{started_at} - $ATTRIBUTION_LEAD_SECONDS) <= $t0 && $t0 <= $end;
            }
        }

        if (@matches == 1) {
            my ($bp, $pkg, $src) = _resolve_bp_pkg($matches[0], $index);
            if (defined $bp && defined $pkg) {
                push @attrs, {
                    path => $agent->{path}, role => $role, kind => 'attributed',
                    blueprint => $bp, package => $pkg, reason => undef, source => $src,
                };
            }
            else {
                push @attrs, {
                    path => $agent->{path}, role => $role, kind => 'unattributed',
                    blueprint => $UNATTRIBUTED_LABEL, package => $UNATTRIBUTED_LABEL,
                    reason => 'id-unresolved', source => 'none',
                };
            }
        }
        elsif (@matches >= 2) {
            push @attrs, {
                path => $agent->{path}, role => $role, kind => 'unattributed',
                blueprint => $UNATTRIBUTED_LABEL, package => $UNATTRIBUTED_LABEL,
                reason => 'ambiguous', source => 'none',
            };
        }
        else {
            my $reason = @candidates ? 'outside-window' : 'no-dispatch-record';
            push @attrs, {
                path => $agent->{path}, role => $role, kind => 'unattributed',
                blueprint => $UNATTRIBUTED_LABEL, package => $UNATTRIBUTED_LABEL,
                reason => $reason, source => 'none',
            };
        }
    }

    # Description heuristic, second pass (B4). S is computed once from the
    # primary pass ONLY -- heuristic successes never enlarge it.
    my %S;
    for my $a (@attrs) {
        $S{ $a->{blueprint} } = 1
            if $a->{kind} eq 'attributed'
            && ($a->{source} eq 'record-fields' || $a->{source} eq 'record-id' || $a->{source} eq 'dispatch-hook');
    }
    if (%S) {
        for my $i (0 .. $#attrs) {
            next unless $attrs[$i]{kind} eq 'unattributed';
            my $desc = $agents[$i]{description};
            next unless defined $desc && !ref($desc);
            next unless $desc =~ /\b(?:package|pkg)\s+(\d{1,3})\b/i;
            my $n = $1 + 0;
            my @found;
            for my $bp_name (keys %S) {
                my $bucket = $index->{$bp_name} && $index->{$bp_name}{packages}{$n};
                next unless $bucket;
                push @found, [$bp_name, $_] for @$bucket;
            }
            next unless @found == 1;
            $attrs[$i] = {
                path => $attrs[$i]{path}, role => $attrs[$i]{role}, kind => 'attributed',
                blueprint => $found[0][0], package => $found[0][1],
                reason => undef, source => 'description-heuristic',
            };
        }
    }

    return \@attrs;
}

# ---------------------------------------------------------------------------
# _valid_by_list(\@dims) -> 1|0. Shared predicate for --by validation, used
# by both report_session (below) and the CLI's own --by parsing, so the two
# call sites can never drift on what counts as a valid dimension list.
# PRIVATE.
# ---------------------------------------------------------------------------
sub _valid_by_list {
    my ($dims) = @_;
    return 0 unless ref($dims) eq 'ARRAY';
    return 0 unless @$dims >= 1 && @$dims <= scalar(@REPORT_DIMENSIONS);
    my %valid = map { $_ => 1 } @REPORT_DIMENSIONS;
    my %seen;
    for my $d (@$dims) { return 0 if !$valid{$d} || $seen{$d}++ }
    return 1;
}

# ---------------------------------------------------------------------------
# report_session(session => PATH, data_root => DIR|undef, by => \@dims|undef)
# -> \%report_doc. Spec §2.7. The ONLY source of tokens/costs is
# derive_session(); this aggregates agents[].cells and nothing else.
# ---------------------------------------------------------------------------
sub report_session {
    my (%opts) = @_;
    my $doc = derive_session(session => $opts{session});

    my $by = $opts{by};
    $by = [@REPORT_DEFAULT_BY] unless defined $by;
    die "report_session: invalid --by dimension list\n" unless _valid_by_list($by);

    my ($data_root, $data_root_source) = resolve_data_root($opts{data_root}, $opts{session});
    my $records   = load_dispatch_records($data_root);
    my $index     = blueprint_index($data_root);
    my @agents    = @{ $doc->{agents} };
    my @tuids     = map { $_ == 0 ? undef : _session_agent_tool_use_id($agents[$_]{path}) } 0 .. $#agents;
    my $attrs     = attribute_session(
        doc => $doc, records => $records, index => $index,
        dispatch_hook => load_dispatch_attribution($data_root), tool_use_ids => \@tuids,
    );

    my %rows;
    for my $i (0 .. $#agents) {
        my $agent = $agents[$i];
        my $attr  = $attrs->[$i];
        for my $c (@{ $agent->{cells} }) {
            next unless $c->{tokens} > 0;
            my %dimval = (
                role => $c->{role}, model => $c->{model}, effort => $c->{effort},
                token_type => $c->{token_type}, blueprint => $attr->{blueprint}, package => $attr->{package},
            );
            my @vals = map { $dimval{$_} } @$by;
            my $key = join("\x1f", @vals);
            my $row = $rows{$key};
            unless ($row) {
                $row = {};
                for my $idx (0 .. $#$by) { $row->{ $by->[$idx] } = $vals[$idx]; }
                $row->{tokens} = 0; $row->{cost_usd} = 0; $row->{unpriced_tokens} = 0;
                $rows{$key} = $row;
            }
            $row->{tokens}          += $c->{tokens};
            $row->{cost_usd}        += $c->{cost_usd};
            $row->{unpriced_tokens} += $c->{unpriced_tokens};
        }
    }

    my @rows = values %rows;
    for my $row (@rows) {
        $row->{tokens}          = int($row->{tokens});
        $row->{unpriced_tokens} = int($row->{unpriced_tokens});
        $row->{cost_usd}        = 0 + sprintf('%.6f', $row->{cost_usd});
    }
    @rows = sort {
        my $cmp = 0;
        for my $d (@$by) {
            $cmp = $a->{$d} cmp $b->{$d};
            last if $cmp;
        }
        $cmp;
    } @rows;

    my %driver       = map { $_ => 0 } @REPORT_TOKEN_TYPES;
    my %attributed   = map { $_ => 0 } @REPORT_TOKEN_TYPES;
    my %unattributed = map { $_ => 0 } @REPORT_TOKEN_TYPES;
    my %reasons;
    for my $reason (@ATTRIBUTION_REASONS) {
        $reasons{$reason} = { map { $_ => 0 } @REPORT_TOKEN_TYPES };
    }

    for my $i (0 .. $#agents) {
        my $agent = $agents[$i];
        my $attr  = $attrs->[$i];
        for my $c (@{ $agent->{cells} }) {
            next unless $c->{tokens} > 0;
            my $t   = $c->{token_type};
            my $tok = $c->{tokens};
            if ($attr->{kind} eq 'driver')          { $driver{$t}     += $tok; }
            elsif ($attr->{kind} eq 'attributed')   { $attributed{$t} += $tok; }
            else {
                $unattributed{$t} += $tok;
                $reasons{ $attr->{reason} }{$t} += $tok;
            }
        }
    }

    return {
        cost_basis   => 'notional-api-equivalent',
        price_source => $SESSION_PRICE_SOURCE,
        price_as_of  => $SESSION_PRICE_AS_OF,
        by           => [@$by],
        data_root    => $data_root,
        data_root_source => $data_root_source,
        rows         => \@rows,
        totals       => $doc->{totals},
        attribution  => {
            driver       => \%driver,
            attributed   => \%attributed,
            unattributed => \%unattributed,
            reasons      => \%reasons,
            agents       => $attrs,
        },
    };
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
        elsif ($a =~ /^--session=(.*)$/)    { $opt{session}    = $1 }
        elsif ($a eq '--session')           { $opt{session}    = shift @ARGV }
        elsif ($a eq '--json')              { $opt{json}       = 1 }
        elsif ($a =~ /^--data-root=(.*)$/)  { $opt{data_root}  = $1 }
        elsif ($a eq '--data-root')         { $opt{data_root}  = shift @ARGV }
        elsif ($a =~ /^--by=(.*)$/)         { $opt{by}         = $1 }
        elsif ($a eq '--by')                { $opt{by}         = shift @ARGV }
        else { print STDERR "bp-spend: unrecognised argument '$a'\n"; exit 2 }
    }

    # --session/--json/--data-root/--by living in the shared option loop
    # above means a verb that never asked for them (snapshot, derive-package,
    # derive-blueprint) now parses them instead of hitting the old
    # unrecognised-argument hard error (fix-batch redteam M3) -- restore that
    # safety net explicitly for every verb that does not ask for a given flag.
    my %SESSION_VERBS = (('derive-session') => 1, ('report-session') => 1);
    if (!$SESSION_VERBS{$verb} && (exists $opt{session} || $opt{json})) {
        print STDERR "bp-spend: --session/--json only apply to derive-session or report-session\n";
        exit 2;
    }
    if ($verb ne 'report-session' && (exists $opt{data_root} || exists $opt{by})) {
        print STDERR "bp-spend: --data-root/--by only apply to report-session\n";
        exit 2;
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

    # ---------------------------------------------------------------------
    # derive-session (blueprint usage-telemetry, package
    # 01-drive-solo-input-and-pricing). Read-only: never calls write_derived,
    # prints to stdout only. See spec §2.6.
    # ---------------------------------------------------------------------
    if ($verb eq 'derive-session') {
        unless (defined $opt{session} && length $opt{session}) {
            print STDERR "bp-spend: derive-session requires --session PATH\n";
            exit 2;
        }

        my $doc = eval { BpSpend::Derive::derive_session(session => $opt{session}) };
        if ($@) {
            my $err = $@;
            # Match on the die message's CONTENT, not merely "any die happened"
            # (fix-batch redteam L6/review L4) -- necessary now that an
            # unopenable main transcript (M4 above) is a second possible die
            # path here, and an unrelated internal failure must not be
            # misreported as a missing-transcript edge case.
            if ($err =~ /^derive_session: no such/) {
                print STDERR "bp-spend: no such session transcript: "
                    . BpSpend::Derive::_session_truncate_for_error($opt{session}) . "\n";
                exit 4;
            }
            print STDERR "bp-spend: $err";
            exit 1;
        }

        if ($opt{json}) {
            print JSON::PP->new->canonical->utf8->encode($doc), "\n";
            exit 0;
        }

        my @type_order = qw(input output cache_write_5m cache_write_1h cache_read cache_write_unsplit);
        print "derive-session: notional as-if-API-billed cost equivalent, not an actual charge\n";
        print "session: $doc->{agents}[0]{path}\n";
        print "price-source: $doc->{price_source} (as-of $doc->{price_as_of})\n";
        print "requests: $doc->{record_counts}{requests}  assistant-records: $doc->{record_counts}{assistant_records}  agents: "
            . scalar(@{ $doc->{agents} }) . "\n";
        my $grand_total_cost   = 0;
        my $grand_total_tokens = 0;
        for my $type (@type_order) {
            my $t = $doc->{totals}{$type};
            # sprintf('%.6f', ...) directly, no `+ 0` (fix-batch redteam L7) --
            # a tiny dollar amount stringifies as exponent notation (e.g.
            # `5e-05`) once coerced back to a number; this is TEXT-MODE DISPLAY
            # ONLY and never touches the JSON-mode numeric value in $doc.
            printf "total %s: %s tokens, \$%.6f notional as-if-API-billed, unpriced %s tokens\n",
                $type, $t->{tokens}, $t->{cost_usd}, $t->{unpriced_tokens};
            $grand_total_cost   += $t->{cost_usd};
            $grand_total_tokens += $t->{tokens};
        }
        printf "TOTAL: \$%.6f notional as-if-API-billed across %s tokens\n",
            $grand_total_cost, $grand_total_tokens;
        print "unpriced: model-not-in-table $doc->{unpriced}{'model-not-in-table'}, "
            . "cache-write-unsplit $doc->{unpriced}{'cache-write-unsplit'}, "
            . "non-standard-speed $doc->{unpriced}{'non-standard-speed'}\n";
        print "anomaly consecutive-same-size-cache-write: count $doc->{anomaly}{count}, total_tokens $doc->{anomaly}{total_tokens}\n";

        # Surface the six diagnostic counters in text mode too (fix-batch
        # redteam M2) -- previously only --json exposed them, so a text-mode
        # run could silently degrade (skipped lines, malformed fields, a
        # dropped mismatch, etc.) with no visible sign at all.
        my $rc = $doc->{record_counts};
        my @warn_parts;
        push @warn_parts, "skipped-unparseable $rc->{skipped_unparseable}"     if $rc->{skipped_unparseable};
        push @warn_parts, "malformed-usage-field $rc->{malformed_usage_field}" if $rc->{malformed_usage_field};
        push @warn_parts, "request-usage-mismatch $rc->{request_usage_mismatch}" if $rc->{request_usage_mismatch};
        push @warn_parts, "unkeyed $rc->{unkeyed}"                             if $rc->{unkeyed};
        push @warn_parts, "multi-iteration $rc->{multi_iteration}"            if $rc->{multi_iteration};
        push @warn_parts, "speed-absent $rc->{speed_absent}"                  if $rc->{speed_absent};
        print "warnings: " . join(', ', @warn_parts) . "\n" if @warn_parts;

        exit 0;
    }

    # ---------------------------------------------------------------------
    # report-session (blueprint usage-telemetry, package
    # 02-attribution-and-report). Read-only: never calls write_derived,
    # prints to stdout only. See spec §2.7-2.8.
    # ---------------------------------------------------------------------
    if ($verb eq 'report-session') {
        unless (defined $opt{session} && length $opt{session}) {
            print STDERR "bp-spend: report-session requires --session PATH\n";
            exit 2;
        }
        if (exists $opt{data_root} && !(defined $opt{data_root} && length $opt{data_root})) {
            print STDERR "bp-spend: --data-root requires a directory\n";
            exit 2;
        }

        my @by_dims;
        if (exists $opt{by}) {
            unless (defined $opt{by}) {
                print STDERR "bp-spend: --by requires a dimension list\n";
                exit 2;
            }
            @by_dims = split(/,/, $opt{by}, -1);
            unless (BpSpend::Derive::_valid_by_list(\@by_dims)) {
                print STDERR "bp-spend: --by '$opt{by}' is not a valid dimension list (allowed: "
                    . join(',', @BpSpend::Derive::REPORT_DIMENSIONS) . "; each at most once)\n";
                exit 2;
            }
        }

        my $doc = eval {
            BpSpend::Derive::report_session(
                session   => $opt{session},
                data_root => $opt{data_root},
                (@by_dims ? (by => \@by_dims) : ()),
            );
        };
        if ($@) {
            my $err = $@;
            if ($err =~ /^derive_session: no such/) {
                print STDERR "bp-spend: no such session transcript: "
                    . BpSpend::Derive::_session_truncate_for_error($opt{session}) . "\n";
                exit 4;
            }
            print STDERR "bp-spend: $err";
            exit 1;
        }

        if ($opt{json}) {
            print JSON::PP->new->canonical->utf8->encode($doc), "\n";
            exit 0;
        }

        print "report-session: notional as-if-API-billed cost equivalent, not an actual charge\n";
        print "session: $doc->{attribution}{agents}[0]{path}\n";
        print "data-root: $doc->{data_root} (from $doc->{data_root_source})\n";
        print "price-source: $doc->{price_source} (as-of $doc->{price_as_of})\n";
        print "by: " . join(',', @{ $doc->{by} }) . "\n";

        my $grand_cost   = 0;
        my $grand_tokens = 0;
        for my $row (@{ $doc->{rows} }) {
            my @parts = map { "$_=$row->{$_}" } @{ $doc->{by} };
            printf "row: %s | %s tokens, \$%.6f notional as-if-API-billed, unpriced %s tokens\n",
                join(' ', @parts), $row->{tokens}, $row->{cost_usd}, $row->{unpriced_tokens};
            $grand_cost   += $row->{cost_usd};
            $grand_tokens += $row->{tokens};
        }
        printf "TOTAL: \$%.6f notional as-if-API-billed across %s tokens\n", $grand_cost, $grand_tokens;

        my $sum_types = sub {
            my ($map) = @_;
            my $s = 0;
            $s += $map->{$_} for @BpSpend::Derive::REPORT_TOKEN_TYPES;
            return $s;
        };
        printf "attribution: driver %s tokens, attributed %s tokens, unattributed %s tokens\n",
            $sum_types->($doc->{attribution}{driver}),
            $sum_types->($doc->{attribution}{attributed}),
            $sum_types->($doc->{attribution}{unattributed});
        for my $reason (@BpSpend::Derive::ATTRIBUTION_REASONS) {
            printf "attribution-reason %s: %s tokens\n", $reason, $sum_types->($doc->{attribution}{reasons}{$reason});
        }

        exit 0;
    }

    if ($verb ne 'snapshot') {
        print STDERR "usage: bp-spend.pl snapshot [--run-dir DIR] [--global-dir DIR] [--offline]\n"
                   . "                            [--force] [--now EPOCH] [--log PATH]\n"
                   . "       bp-spend.pl derive-package --run-dir DIR --pkg PKG [--now EPOCH]\n"
                   . "       bp-spend.pl derive-blueprint --run-dir DIR [--now EPOCH]\n"
                   . "       bp-spend.pl derive-session --session PATH [--json]\n"
                   . "       bp-spend.pl report-session --session PATH [--data-root DIR] [--by dims] [--json]\n";
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
