# keep-awake.ps1 -- hold a Windows wake-lock for as long as THIS process lives,
# and NO LONGER than its lease.
#
# Started/killed by the sandbox dashboard's keep-awake (B5, KeepAwake.pm) and by
# butler's bp-keepawake.pl, gated by the orchestrator's busy-lease: spawned only
# while there is active work or a pending auto-resume, killed when idle.
#
# The host perl has no Win32::API, so we assert SetThreadExecutionState via
# P/Invoke from PowerShell. ES_CONTINUOUS ties the request to the calling thread,
# so the lock is released automatically the moment this process is killed -- no
# explicit "undo" call is needed (which is exactly why we run it as a dedicated
# child whose lifetime == the wake-lock's lifetime).
#
# We request ES_SYSTEM_REQUIRED. That is the whole request, as of 2026-09-17.
#
# THIS BLOCK USED TO CLAIM ES_DISPLAY_REQUIRED WAS "the load-bearing flag on
# Modern Standby (S0 Low Power Idle) machines", on the reasoning that "those
# systems enter connected standby when the display turns off". MEASURED, and the
# premise is false on this class of machine. An eight-hour unattended run was
# lost, and Windows named the cause itself:
#
#   Kernel-Power 506, 06:04:57 local
#   "The system is entering connected standby.  Reason: Idle Timeout."
#
# IDLE TIMEOUT -- not display-off. The display request was held and refreshing on
# its normal two-minute cadence when that fired. So the flag was blocking a
# trigger that was not the trigger, while costing a lit screen through every
# unattended night. Dropped at the operator's instruction.
#
# WHAT THE REQUESTS ACTUALLY DO HERE, from `powercfg /requests` taken elevated
# while a lock was held:
#
#   DISPLAY:    [PROCESS] ...\powershell.exe     <- was registered, worked
#   SYSTEM:     [PROCESS] ...\powershell.exe     <- registered, works
#   EXECUTION:  None.                            <- the gap that mattered
#
# SetThreadExecutionState was never being ignored: Windows had both requests.
# Neither of them keeps a PROCESS RUNNING once the system is in connected
# standby -- that is PowerRequestExecutionRequired, which has no ES_* flag and
# cannot be expressed through this API at all. Work continued INSIDE standby for
# nearly four hours on DISPLAY+SYSTEM alone, then Desktop Activity Moderation
# suspended it.
#
# WHY WE ARE NOT CHASING AN EXECUTION REQUEST HERE. It protects the CALLING
# PROCESS only. One held by this PowerShell would keep this PowerShell alive and
# do nothing for the launcher, the orchestrator, or the agent process doing the
# actual work -- and the containerised case is already covered differently, since
# everything inside the WSL VM is one process (`vmmem`) to Windows. Per-process
# requests are the wrong shape for "keep this machine working overnight".
#
# THE ACTUAL FIX IS TO LEAVE THE REGIME: disabling Modern Standby
# (PlatformAoAcOverride) restores classic S3 sleep, where ES_SYSTEM_REQUIRED is
# correct AND sufficient, because S3 is exactly the idle timer it targets. That
# is a machine-level change and is the operator's to make; this script is
# already correct for that world and costs nothing in the meantime.
#
# Caveats no software request can beat: closing the lid or the power button still
# forces standby, and battery power policy may override -- for a long unattended
# run, keep the machine on AC.
#
# THE LEASE, added 2026-08-14. Before this, the body was
# `while ($true) { Start-Sleep -Seconds 3600 }` with no owner check and no
# expiry: the ONLY release was the parent killing us. That fails in exactly the
# case that matters -- the parent dying unexpectedly (crash, forced restart, WSL
# VM kill, a session torn down mid-run). An orphan then held ES_DISPLAY_REQUIRED
# and kept the machine awake INDEFINITELY, with nothing left that knew to reap
# it. The -PidFile reaping path only helps if some LATER launcher happens to run
# in the same project and finds the file. The operator asked the right question:
# these should be refreshed against a timeout threshold.
#
# So the pid file is now a HEARTBEAT as well as an identity: the owning side
# touches it while it still wants the lock (see bp-keepawake.pl's apply(), which
# refreshes it on the very tick that finds a live lock and leaves it alone). We
# poll, and exit when either
#   * the pid file is GONE      -- someone released us deliberately, or
#   * it has not been touched within -LeaseSeconds -- nobody is left who wants it.
# Exiting drops the wake-lock automatically, because ES_CONTINUOUS is bound to
# this thread. Worst case an abandoned lock now costs one lease period, not "until
# the next reboot".
#
# -PidFile: we write our own Windows PID here at startup and remove it on exit,
# so a launcher that crashed while we were running can still reap us by pid.
#
# ASCII ONLY. This file previously carried em-dashes with no BOM; PowerShell 5.1
# reads a BOM-less file as CP1252, where the UTF-8 bytes for an em-dash decode to
# a sequence containing 0x94 -- a smart quote, which PowerShell treats as a STRING
# DELIMITER. It was harmless only because those bytes sat inside comments. Do not
# reintroduce non-ASCII here.
# THE LEASE IS OPT-IN, and that is deliberate. It is only safe for a caller that
# actually REFRESHES the heartbeat; a caller that spawns us and then never
# touches the pid file would have its lock reaped mid-run, letting the machine
# sleep during exactly the long unattended run the lock exists to protect.
#
# Today: butler's bp-keepawake.pl refreshes on every director tick and passes a
# lease. launcher.pl's dashboard holder does NOT refresh, so it passes none and
# keeps the previous hold-until-killed behaviour. Giving that path a refresher
# (its heartbeat loop is the obvious home) is what would let it opt in too --
# until then, do not "helpfully" default this to a finite value.
[CmdletBinding()]
param(
    [string]$PidFile,
    [int]$LeaseSeconds = 0,     # 0 = no lease (hold until killed)
    [int]$PollSeconds  = 60,
    [string]$LogFile,
    [switch]$SimulatePowerRequestFailure,
    [switch]$SimulatePowerRequestException
)
$ErrorActionPreference = 'Stop'

# -LogFile: THE QUESTION THIS EXISTS TO ANSWER. When the machine sleeps during an
# unattended run there are exactly two stories, and they need opposite fixes:
#
#   (a) the request WAS held and Windows slept anyway, or
#   (b) the request was already gone -- the lease reaped this helper first.
#
# Neither is recoverable after the fact. run.md carries no timestamps, the pid
# file's mtime history is overwritten on every heartbeat, and the helper leaves
# no trace at all once it exits. So on 2026-09-17 we had a Kernel-Power 506 and
# no way to say which story it belonged to, and a whole conclusion about
# ES_DISPLAY_REQUIRED was drawn on the assumption of (a) without testing it.
#
# Every line is stamped in LOCAL time to match Event Viewer, so a 506 can be
# correlated directly:
#   powershell "Get-WinEvent -FilterHashtable @{LogName='System';Id=506,507}"
# against this file. A HOLD line either brackets that timestamp or it does not.
#
# Logging must never be able to kill the wake-lock it is observing, so every
# write is best-effort and swallowed. No -LogFile means every call is a no-op.
$script:KA_LOG = $LogFile
function Write-KaLog {
    param([string]$Event, [string]$Detail = '')
    if (-not $script:KA_LOG) { return }
    try {
        $ts = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        Add-Content -LiteralPath $script:KA_LOG -Encoding ascii `
                    -Value "$ts pid=$PID $Event $Detail" -ErrorAction SilentlyContinue
    } catch {}
}

if ($PidFile) {
    try { Set-Content -LiteralPath $PidFile -Value $PID -Encoding ascii -ErrorAction SilentlyContinue } catch {}
}

Add-Type -Namespace Win32 -Name Power -MemberDefinition @'
[DllImport("kernel32.dll", SetLastError = true)]
public static extern uint SetThreadExecutionState(uint esFlags);

[StructLayout(LayoutKind.Sequential)]
public struct POWER_REQUEST_CONTEXT {
    public uint Version;
    public uint Flags;
    [MarshalAs(UnmanagedType.LPWStr)] public string SimpleReasonString;
}

[DllImport("kernel32.dll", SetLastError = true)]
public static extern IntPtr PowerCreateRequest(ref POWER_REQUEST_CONTEXT Context);

[DllImport("kernel32.dll", SetLastError = true)]
[return: MarshalAs(UnmanagedType.Bool)]
public static extern bool PowerSetRequest(IntPtr PowerRequest, int RequestType);

[DllImport("kernel32.dll", SetLastError = true)]
[return: MarshalAs(UnmanagedType.Bool)]
public static extern bool PowerClearRequest(IntPtr PowerRequest, int RequestType);

[DllImport("kernel32.dll", SetLastError = true)]
[return: MarshalAs(UnmanagedType.Bool)]
public static extern bool CloseHandle(IntPtr hObject);
'@

# String->uint32 casts avoid PowerShell parsing 0x80000000 as a (signed) int.
$ES_CONTINUOUS       = [uint32]'0x80000000'
$ES_SYSTEM_REQUIRED  = [uint32]'0x00000001'

# ES_DISPLAY_REQUIRED WAS DROPPED 2026-09-17, on measurement. See the header.
#
# It was here to block S0 connected-standby entry, on the stated premise that
# "those systems enter connected standby when the display turns off". The
# premise is false on this class of machine, and Windows said so itself:
#
#   Kernel-Power 506, 06:04:57
#   "The system is entering connected standby.  Reason: Idle Timeout."
#
# Idle timeout, not display-off -- with the display request held and refreshing
# normally at the time. The flag was chosen to block a trigger that was not the
# trigger, and it cost a lit screen every unattended night in exchange.
#
# Operator, 2026-09-17: "We don't need to hold the display lock anymore. I don't
# want to keep the display on forever."
#
# ES_SYSTEM_REQUIRED stays. It is the correct and sufficient request once Modern
# Standby is off and the machine uses classic S3 sleep, which is the direction
# this host is going -- and it costs nothing while S0 is still in force.
$r = [Win32.Power]::SetThreadExecutionState($ES_CONTINUOUS -bor $ES_SYSTEM_REQUIRED)
if ($r -eq 0) {
    Write-KaLog 'ASSERT-FAILED' 'SetThreadExecutionState returned 0'
    Write-Error 'SetThreadExecutionState returned 0 (wake-lock not asserted)'
    exit 1
}
# The return value is the PREVIOUS execution state, so it is also the only
# in-process confirmation that the kernel recorded anything at all. Logged as hex
# because that is how the ES_* flags are documented and compared.
Write-KaLog 'ASSERTED' ("flags=ES_CONTINUOUS|ES_SYSTEM_REQUIRED prev=0x{0:X8} lease={1}s poll={2}s pidfile={3}" -f $r, $LeaseSeconds, $PollSeconds, $PidFile)

# EXECUTION POWER REQUEST -- see the header at the top of this file for why
# SetThreadExecutionState alone leaves the EXECUTION row in `powercfg
# /requests` as None. Acquired here, immediately after the existing
# SetThreadExecutionState success, and released from the finally block below.
#
# Invariant: $script:PowerRequestHandle is truthy IFF a Power Request was
# both successfully CREATED and successfully SET. Any other outcome (create
# failed, set failed, exception, simulated failure) leaves it $null, and a
# handle obtained but not fully set is closed immediately at the point of
# failure -- never left for the finally block to find.
$script:PowerRequestHandle = $null

$POWER_REQUEST_CONTEXT_VERSION       = 0        # Version field
$POWER_REQUEST_CONTEXT_SIMPLE_STRING = 1        # Flags field (uint)
$PowerRequestExecutionRequired       = 3        # POWER_REQUEST_TYPE enum value; passed as plain int, NOT OR'd with anything (not a bitmask)

if ($SimulatePowerRequestFailure) {
    # Test-only seam (-SimulatePowerRequestFailure). No real Win32 call is
    # made -- goes straight to the degrade branch as if the real API failed.
    Write-KaLog 'POWER-REQUEST-DEGRADED' 'reason=simulated-failure -- continuing on ES_SYSTEM_REQUIRED alone'
} else {
    # $handle is initialized here, OUTSIDE the try block, specifically so the
    # catch block below (same scope -- try/catch is not a scope boundary in
    # PowerShell) can still see whatever PowerCreateRequest last assigned to
    # it even when the exception is thrown by a LATER statement (PowerSetRequest).
    # Without this, a handle successfully created by PowerCreateRequest but
    # then orphaned by an exception from PowerSetRequest (interop failure,
    # not the ordinary boolean-false return -- see redteam-01.md MEDIUM
    # finding) would never be closed: $script:PowerRequestHandle stays $null,
    # so the `finally` block's own guard skips it too, and the real OS handle
    # leaks for the life of the process.
    $handle = [IntPtr]::Zero
    try {
        $context = New-Object Win32.Power+POWER_REQUEST_CONTEXT
        $context.Version = $POWER_REQUEST_CONTEXT_VERSION
        $context.Flags = $POWER_REQUEST_CONTEXT_SIMPLE_STRING
        $context.SimpleReasonString = 'ccpraxis keep-awake: execution required'

        $handle = [Win32.Power]::PowerCreateRequest([ref]$context)
        if ($handle -eq [IntPtr]::Zero -or $handle.ToInt64() -eq -1) {
            Write-KaLog 'POWER-REQUEST-DEGRADED' 'reason=create-invalid-handle -- continuing on ES_SYSTEM_REQUIRED alone'
        } else {
            if ($SimulatePowerRequestException) {
                # Test-only seam (-SimulatePowerRequestException). Unlike
                # -SimulatePowerRequestFailure (which skips the real Win32
                # calls entirely), this seam makes a REAL PowerCreateRequest
                # call above (so $handle is a real, live OS handle) and then
                # simulates PowerSetRequest raising a CLR/interop exception
                # instead of returning $false, without making the real
                # PowerSetRequest call. This exercises the catch block's
                # handle-close path against a genuine handle.
                throw 'simulated PowerSetRequest exception (test seam)'
            }
            $ok = [Win32.Power]::PowerSetRequest($handle, $PowerRequestExecutionRequired)
            if (-not $ok) {
                [Win32.Power]::CloseHandle($handle) | Out-Null
                Write-KaLog 'POWER-REQUEST-DEGRADED' 'reason=set-request-failed -- continuing on ES_SYSTEM_REQUIRED alone'
            } else {
                $script:PowerRequestHandle = $handle
                Write-KaLog 'POWER-REQUEST-CREATED' ("handle=0x{0:X} type=PowerRequestExecutionRequired" -f $handle.ToInt64())
            }
        }
    } catch {
        if ($handle -ne [IntPtr]::Zero -and $handle.ToInt64() -ne -1) {
            # A real handle was created before the exception hit (thrown by
            # PowerSetRequest, or by the test seam above) -- close it here so
            # it is never left dangling; the `finally` block cannot reach it
            # because $script:PowerRequestHandle was never set.
            [Win32.Power]::CloseHandle($handle) | Out-Null
            Write-KaLog 'POWER-REQUEST-DEGRADED' ("reason=exception:{0} handle-closed=true -- continuing on ES_SYSTEM_REQUIRED alone" -f $_.Exception.Message)
        } else {
            Write-KaLog 'POWER-REQUEST-DEGRADED' ("reason=exception:{0} -- continuing on ES_SYSTEM_REQUIRED alone" -f $_.Exception.Message)
        }
    }
}

# Guard against a caller passing nonsense that would disable the lease entirely.
if ($LeaseSeconds -lt 60)   { $LeaseSeconds = 60 }
if ($PollSeconds  -lt 5)    { $PollSeconds  = 5 }
if ($PollSeconds  -gt $LeaseSeconds) { $PollSeconds = $LeaseSeconds }

try {
    if (-not $PidFile) {
        # No heartbeat file to watch: fall back to the old behaviour rather than
        # exiting immediately, but still cap it so it cannot outlive a session
        # by days. A caller with no pid file cannot reap us by pid either.
        $deadline = (Get-Date).AddSeconds($LeaseSeconds)
        while ((Get-Date) -lt $deadline) { Start-Sleep -Seconds $PollSeconds }
    }
    else {
        # A SUSPENDED OWNER IS NOT AN ABSENT OWNER. Added 2026-09-17 after this
        # lock dropped during an eight-hour unattended run.
        #
        # The lease asks "has anyone touched the pid file recently", and treats
        # no as "nobody still wants the lock". Under Modern Standby that
        # inference is wrong: Desktop Activity Moderation suspends the owner, the
        # owner cannot touch anything while suspended, and this loop then
        # concludes it was abandoned and EXITS -- dropping the wake-lock at
        # exactly the moment the machine is going under. Standby throttles the
        # owner, the lease expires, the lock drops, the machine sleeps properly.
        # Self-reinforcing, and measured: three hours of silence starting 09:00.
        #
        # We cannot ask the owner whether it is alive -- the pid file holds OUR
        # pid, not theirs. But we can notice that WE were suspended: a
        # Start-Sleep that was asked for $PollSeconds and took very much longer
        # means wall time passed that no process on this machine was running
        # through. The owner could not have heartbeated during it, so that
        # interval is not evidence of anything.
        #
        # On detecting it, grant ONE further lease period from the moment of
        # waking. Bounded on purpose: a genuinely dead owner still releases the
        # lock, just one lease later. The alternative -- forgiving the whole
        # suspended interval -- grows without limit across repeated sleeps, which
        # is how an orphan comes to hold a machine awake indefinitely, the exact
        # failure the lease was introduced to end.
        Write-KaLog 'WATCH' ("effective lease={0}s poll={1}s" -f $LeaseSeconds, $PollSeconds)
        $resumeGraceUntil = $null
        while ($true) {
            $before = Get-Date
            Start-Sleep -Seconds $PollSeconds
            $actualSleep = ((Get-Date) - $before).TotalSeconds

            # 3x the requested sleep plus 30s of slack: scheduler jitter and a
            # loaded host never reach it; a suspend passes it by orders of
            # magnitude (186 and 204 minutes, measured).
            if ($actualSleep -gt (($PollSeconds * 3) + 30)) {
                # This line is the direct evidence that THIS PROCESS was frozen:
                # a sleep asked for $PollSeconds that took orders of magnitude
                # longer. Paired with a Kernel-Power 506/507 it shows the machine
                # went under WHILE the lock was asserted -- story (a).
                Write-KaLog 'SUSPEND-DETECTED' ("slept={0:N0}s requested={1}s grace={2}s" -f $actualSleep, $PollSeconds, $LeaseSeconds)
                $resumeGraceUntil = (Get-Date).AddSeconds($LeaseSeconds)
            }

            # Released deliberately: the file is our reason to exist.
            if (-not (Test-Path -LiteralPath $PidFile)) {
                Write-KaLog 'RELEASE' 'reason=pidfile-gone (deliberate release)'
                break
            }

            # Lease expired: nobody has touched it, so nobody still wants the
            # lock. Do not keep the machine awake on behalf of a dead run.
            try {
                $age = ((Get-Date) - (Get-Item -LiteralPath $PidFile).LastWriteTime).TotalSeconds
                if ($age -gt $LeaseSeconds) {
                    if ($resumeGraceUntil -and (Get-Date) -lt $resumeGraceUntil) {
                        Write-KaLog 'GRACE' ("lease expired (age={0:N0}s) but a suspend was seen -- holding" -f $age)
                        continue
                    }
                    # THE OTHER STORY, (b): the lock is about to stop being
                    # asserted because nobody refreshed the heartbeat. A 506 after
                    # this line is a machine sleeping with NO request held, which
                    # says nothing about whether ES_SYSTEM_REQUIRED works.
                    Write-KaLog 'RELEASE' ("reason=lease-expired age={0:N0}s lease={1}s" -f $age, $LeaseSeconds)
                    break
                }
                # The steady state, and the line that makes absence meaningful: a
                # gap in HOLD lines is itself evidence, so they must be emitted
                # unconditionally rather than only when something changes.
                Write-KaLog 'HOLD' ("heartbeat_age={0:N0}s slept={1:N0}s" -f $age, $actualSleep)
            }
            catch {
                # Unreadable/vanished between the two calls -- treat as released.
                Write-KaLog 'RELEASE' 'reason=pidfile-unreadable'
                break
            }
        }
    }
}
finally {
    # ES_CONTINUOUS is bound to this thread, so process exit IS the release. This
    # is the last moment the lock is asserted, and the log has to say so -- an
    # entry that just stops with no EXIT line means the process was KILLED rather
    # than having released, which is a third story again.
    if ($script:PowerRequestHandle) {
        try {
            [Win32.Power]::PowerClearRequest($script:PowerRequestHandle, $PowerRequestExecutionRequired) | Out-Null
            [Win32.Power]::CloseHandle($script:PowerRequestHandle) | Out-Null
            Write-KaLog 'POWER-REQUEST-RELEASED' 'handle cleared and closed'
        } catch {}
    }
    Write-KaLog 'EXIT' 'wake-lock released (process exiting)'
    if ($PidFile) { try { Remove-Item -LiteralPath $PidFile -Force -ErrorAction SilentlyContinue } catch {} }
}
