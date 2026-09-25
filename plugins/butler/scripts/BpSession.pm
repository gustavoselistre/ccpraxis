# BpSession.pm — WHICH SESSION AM I, answered authoritatively.
#
# THE PROBLEM. Nothing running as a Bash tool call is told which session Claude
# Code considers live. Two things look like they answer it and neither does:
#
#   * ${CLAUDE_SESSION_ID} is a TEMPLATE SUBSTITUTION, replaced inside SKILL.md
#     before the body runs (references/extending-ccpraxis.md). It is baked into
#     the text of an instruction at render time, never re-checked, and it is not
#     an environment variable at all -- the old continuity CLI's own
#     $ENV{CLAUDE_SESSION_ID} fallback could therefore never fire once.
#   * $CLAUDE_CODE_SESSION_ID *is* in the Bash environment, but it is one
#     process-scoped value with nothing to verify it against.
#
# That mattered because the consumer disagreed: stop-gate.sh looks its
# marker up by the session_id in its own hook payload and exits SILENTLY when
# there is none. One unverified writer, one authoritative reader, no comparison
# -- so any disagreement produced the worst outcome available, arming reported
# as successful while enforcing nothing. Reported from a live session.
#
# THE FIX, and why it is exact rather than a heuristic. A session's tool output
# is recorded in that session's transcript, and each transcript record carries
# its own `sessionId` field. So:
#
#   1. print a nonce from a Bash tool call;
#   2. later, find the transcript record containing that nonce;
#   3. read `sessionId` off THAT record.
#
# Step 3 is what makes this survive a resumed conversation: the answer comes
# from the record, not from the file's name, so it is right even when a resumed
# session appends to a transcript named for the session it resumed.
#
# It is NOT true that a nonce can only ever appear in one transcript, and
# assuming so would have reintroduced the bug in a new shape. A tool call's
# COMMAND TEXT is recorded as well as its output, so a nonce merely NAMED on a
# command line is planted in that session's transcript by the naming. Measured:
# querying a never-planted nonce resolved to the querying session, because the
# query planted it. Hence session_for_nonce refuses an ambiguous nonce instead
# of taking the first match -- see the note there.
#
# The one thing it cannot do is answer inside the SAME tool call that plants the
# nonce: the tool result is written to the transcript after the call returns. So
# resolution is always "plant now, resolve on a later invocation" -- see
# butler-continuity's ticket flow, where the later invocation is the Stop hook
# that needs the answer anyway.
package BpSession;
use strict;
use warnings;
use File::Spec;
use Cwd qw(getcwd abs_path);
use JSON::PP ();

# ── transcript discovery ───────────────────────────────────────────────────
#
# Candidate roots holding <project>/<session>.jsonl, most explicit first.
# Cheap and non-fatal by design: a missing root is skipped, never an error.
#
# LIFTED VERBATIM from bp-feedback.pl's _transcript_roots, which is now a thin
# wrapper over this. It was the only transcript-locating code in the repo and a
# second consumer arrived; two copies of a list of search roots is exactly the
# kind of duplication that drifts silently, and the sandbox/host-view cases
# below are the parts nobody would remember to copy correctly.
sub transcript_roots {
    my ($data_dir_override) = @_;
    my @roots;

    push @roots, File::Spec->catdir($ENV{CLAUDE_CONFIG_DIR}, 'projects')
        if defined $ENV{CLAUDE_CONFIG_DIR} && length $ENV{CLAUDE_CONFIG_DIR};
    for my $home (grep { defined && length } ($ENV{HOME}, $ENV{USERPROFILE})) {
        push @roots, File::Spec->catdir($home, '.claude', 'projects');
    }
    # In a sandbox the container's ~/.claude/projects IS the bind-mounted
    # claude-home, so the HOME entry above already covers it; this handles the
    # host-side view of the same tree (reading a container session's transcript
    # from outside), which HOME does not reach.
    for my $d (grep { defined && length } ($data_dir_override, $ENV{CCPRAXIS_DATA_DIR})) {
        push @roots, File::Spec->catdir($d, 'claude-home', 'projects');
    }
    {
        my $dir = getcwd();
        while (1) {
            push @roots, File::Spec->catdir($dir, '.ccpraxis-local-data', 'claude-home', 'projects');
            my $parent = abs_path(File::Spec->catdir($dir, File::Spec->updir));
            last if !defined $parent || $parent eq $dir;
            $dir = $parent;
        }
    }

    my (@out, %seen);
    for my $r (@roots) {
        next if $seen{$r}++;
        push @out, $r if -d $r;
    }
    return @out;
}

sub find_transcript {
    my ($session_id, $data_dir_override) = @_;
    return undef unless defined $session_id && length $session_id;
    return undef if $session_id =~ m{[/\\\x00]};
    for my $root (transcript_roots($data_dir_override)) {
        opendir(my $dh, $root) or next;
        my @projects = grep { $_ ne '.' && $_ ne '..' } readdir $dh;
        closedir $dh;
        for my $p (@projects) {
            my $cand = File::Spec->catfile($root, $p, "$session_id.jsonl");
            return $cand if -f $cand;
        }
    }
    return undef;
}

# transcript_files(%opts) -> list of .jsonl paths, NEWEST FIRST.
#
# `max_age` (seconds, default 3600) bounds the scan: a nonce is resolved within
# a turn or two of being planted, so a transcript untouched for an hour cannot
# hold the one we are looking for. Newest-first plus that bound is what keeps
# this cheap on a machine with hundreds of transcripts. Pass max_age => 0 to
# disable the bound.
# `max_files` (default 50) bounds how many candidates are opened, newest first.
# This runs inside a Stop hook with a 15s budget, and the scan is O(bytes of
# every recently-touched transcript) with no early exit -- uniqueness requires
# seeing them all. Cheap today (~0.1s), but it grows with the number of
# concurrent live sessions, which is exactly the unattended-fleet condition this
# exists for. A killed hook does not block, so a timeout here would make the
# gate stand aside leaving no trace: the one outcome worth engineering against.
sub transcript_files {
    my (%opts) = @_;
    my $max_age   = exists $opts{max_age}   ? $opts{max_age}   : 3600;
    my $max_files = exists $opts{max_files} ? $opts{max_files} : 50;
    my $now = time();

    my @found;
    for my $root (transcript_roots($opts{data_dir})) {
        opendir(my $dh, $root) or next;
        my @projects = grep { $_ ne '.' && $_ ne '..' } readdir $dh;
        closedir $dh;
        for my $p (@projects) {
            my $pdir = File::Spec->catdir($root, $p);
            next unless -d $pdir;
            opendir(my $ph, $pdir) or next;
            my @files = grep { /\.jsonl\z/ } readdir $ph;
            closedir $ph;
            for my $f (@files) {
                my $path = File::Spec->catfile($pdir, $f);
                my $mtime = (stat $path)[9];
                next unless defined $mtime;
                next if $max_age > 0 && ($now - $mtime) > $max_age;
                push @found, [ $path, $mtime ];
            }
        }
    }
    my @sorted = map { $_->[0] } sort { $b->[1] <=> $a->[1] } @found;
    return @sorted if $max_files <= 0 || @sorted <= $max_files;
    return @sorted[0 .. $max_files - 1];

}

# ── nonces ─────────────────────────────────────────────────────────────────
#
# Long enough that it cannot collide with anything already in a transcript, and
# prefixed so a human reading a transcript can see what it is. Not a secret: it
# identifies, it does not authorise. Anything that can read the registry can
# already read the markers themselves.
sub new_nonce {
    my @parts = map { sprintf('%08x', int(rand(2**32))) } 1 .. 3;
    return 'ccpx-sess-' . join('', @parts) . sprintf('-%d', $$);
}

sub valid_nonce {
    my ($n) = @_;
    return 0 unless defined $n && length $n;
    return $n =~ /\Accpx-sess-[0-9a-f]{24}-\d+\z/ ? 1 : 0;
}

# ── the resolution itself ──────────────────────────────────────────────────
#
# session_for_nonce($nonce, %opts) -> $session_id, or undef.
#
# Scans transcripts for the nonce and reads `sessionId` off the record that
# carries it. A cheap index() prefilter runs before any JSON decode: a long
# transcript is tens of thousands of lines and only one can match.
#
# `sessionId` is preferred over the filename DELIBERATELY -- that is the whole
# point (see the header). The filename is used only as a last resort.
#
# UNIQUENESS IS REQUIRED, and this is not a theoretical nicety. A tool call's
# COMMAND TEXT is recorded in the transcript too, not just its output -- so a
# nonce merely MENTIONED on a command line is thereby planted in that session's
# transcript. Measured, not assumed: querying a never-planted nonce resolved to
# the querying session on the first attempt, because naming it in the query put
# it there. A "first match wins" scan would therefore let any session claim any
# nonce simply by mentioning it. So every candidate transcript is scanned, the
# distinct session ids are collected, and an ambiguous nonce resolves to NOTHING
# rather than to a guess. Refusing to answer is safe here: the caller's ticket
# stays pending and expires visibly, where a wrong answer would arm the wrong
# session silently -- the exact failure this module exists to end.
sub session_for_nonce {
    my ($nonce, %opts) = @_;
    my ($sid, $route) = _resolve($nonce, %opts);
    return $sid;
}

# _resolve -> ($session_id, $route). $route is 'record', 'filename', 'ambiguous'
# or undef. One scan answers both public questions; they used to be two scans of
# the same files.
sub _resolve {
    my ($nonce, %opts) = @_;
    return (undef, undef) unless defined $nonce && length $nonce;

    my (%ids, %routes);
    my $max_bytes = exists $opts{max_bytes} ? $opts{max_bytes} : 64 * 1024 * 1024;
    for my $path (transcript_files(%opts)) {
        open my $fh, '<:raw', $path or next;
        my $hit;
        my $read = 0;
        while (my $line = <$fh>) {
            $read += length $line;
            # A per-file byte cap, for the same reason as max_files: this runs
            # under a hook timeout, and a single pathological transcript should
            # not be able to consume the whole budget. A nonce is planted at the
            # END of a transcript in the ordinary case, but the scan is
            # front-to-back, so the cap is generous rather than tight.
            last if $max_bytes > 0 && $read > $max_bytes;
            next if index($line, $nonce) < 0;
            $hit = $line;
            last;
        }
        close $fh;
        next unless defined $hit;

        my $id;
        my $route = 'filename';
        my $rec = eval { JSON::PP->new->utf8->decode($hit) };
        if (ref $rec eq 'HASH') {
            # `sessionId` ONLY. Records carry `session_id` as well, and the two
            # are NOT synonyms: measured across every transcript in this project,
            # every record carrying both has them DIFFERENT -- `session_id` is
            # the PREDECESSOR session in a resume chain. Accepting it as a
            # fallback would bind a ticket to a session that has already ended,
            # which is the failure this module exists to prevent, reached by a
            # subtler route. A record without `sessionId` is skipped, not guessed
            # at.
            my $v = $rec->{sessionId};
            if (defined $v && !ref $v && length $v) { $id = $v; $route = 'record' }

        }
        if (!defined $id) {
            my ($vol, $dir, $file) = File::Spec->splitpath($path);
            $id = $1 if $file =~ /\A(.+)\.jsonl\z/;
        }
        next unless defined $id;
        $ids{$id} = 1;
        $routes{$id} = $route;
    }

    my @found = keys %ids;
    return (undef, undef)       if !@found;
    return (undef, 'ambiguous') if @found > 1;
    return ($found[0], $routes{$found[0]});
}

# resolution_route($nonce, %opts) -> 'record' | 'filename' | 'ambiguous' | undef
# Which source answered, for callers that report their own confidence.
sub resolution_route {
    my ($nonce, %opts) = @_;
    my ($sid, $route) = _resolve($nonce, %opts);
    return $route;
}

1;
