<#
.SYNOPSIS
    WPS Bench - Win32PrioritySeparation Benchmark Tool.

.DESCRIPTION
    Empirically determines the optimal HKLM\SYSTEM\CurrentControlSet\Control\PriorityControl
    \Win32PrioritySeparation registry value for THIS machine by running a synthetic CPU
    scheduling benchmark against each candidate value and measuring foreground-thread timing
    consistency while background load is competing for the CPU.

    The registry only reads the low 6 bits of Win32PrioritySeparation (quantum length x
    quantum type x foreground boost), which gives exactly 12 combinations that produce
    distinct scheduling behavior. By default WPS Bench tests all 12.

    A precision timing loop (implemented in C#, compiled at runtime via Add-Type) records the
    actual delta of every tick of a foreground thread while background worker threads keep the
    CPU busy. Mean interval, jitter (stdev), P99 latency spikes and outlier counts are computed
    per run, and a weighted "WPS Score" ranks candidate values best to worst.

    WPS Bench must run elevated (Administrator), because writing Win32PrioritySeparation
    requires admin rights. The original value is always saved before the first write and
    restored on exit - including on Ctrl+C.

.PARAMETER Values
    Candidate Win32PrioritySeparation values to test (decimal or 0xNN hex). Defaults to the
    full canonical 12-value set (0x14,0x15,0x16,0x18,0x19,0x1A,0x24,0x25,0x26,0x28,0x29,0x2A).

.PARAMETER Runs
    Number of repeat measurement runs per candidate value, used to gauge run-to-run
    consistency. Default 3 (spec range: 3-5).

.PARAMETER DurationSec
    Length of the foreground timing loop per run, in seconds. Default 5.

.PARAMETER WarmupMs
    Warm-up time after background load starts and before the foreground loop begins timing,
    in milliseconds. Default 500.

.PARAMETER IntervalTargetUs
    Target foreground tick interval, in microseconds. Default 1000 (1ms).

.PARAMETER BackgroundThreads
    Number of CPU-bound background worker threads. Default = logical core count - 1.

.PARAMETER ForegroundProcessPriority
    Process priority class for the WPS Bench process while the foreground loop runs.
    One of AboveNormal, High. Default AboveNormal.

.PARAMETER ForegroundThreadPriority
    Thread priority for the foreground timing thread. Default Highest.

.PARAMETER VarianceThresholdPercent
    If the relative stdev of per-run mean intervals for a value exceeds this percentage, the
    value is flagged as inconsistent between runs (a restart may be needed for the scheduler
    change to fully apply). Default 25.

.PARAMETER OutlierMultiplier
    A tick delta is counted as an outlier if it exceeds IntervalTargetUs * OutlierMultiplier.
    Default 3.

.PARAMETER JitterWeight
    Weight applied to jitter's min-max-normalized (0-1) score across the tested candidate
    values, in the composite WPS Score. Default 0.5.

.PARAMETER P99Weight
    Weight applied to the P99 latency spike's min-max-normalized (0-1) score across the tested
    candidate values, in the composite WPS Score. Default 0.5.

.PARAMETER ConsistencyWeight
    Weight applied to a value's run-to-run consistency penalty (min-max-normalized stdev of
    per-run jitter across that value's repeat runs) in the composite WPS Score - a value whose
    jitter swings a lot between repeats is penalized even if its average jitter looks good.
    Default 0.2. JitterWeight/P99Weight/ConsistencyWeight are auto-normalized to sum to 1, so
    the final WPS Score always stays in the 0-1 range regardless of the raw values supplied.

.PARAMETER OutputDir
    Directory for the CSV results file and the audit log file. Defaults to the script's own
    directory.

.PARAMETER Resume
    If set, looks for WPS_Bench_Results.csv in OutputDir and skips any value/run combinations
    already present in it, appending new results to that same file instead of deleting it and
    starting over.

.PARAMETER GpuLoad
    Concurrent GPU compute load run on its own thread alongside the CPU background load, so
    Win32PrioritySeparation is tested against realistic GPU-driven CPU overhead (driver command
    submission/synchronization), not just synthetic CPU busy-loops. One of Off, Light, Medium,
    Heavy. Default Heavy - runs at full, near-continuous GPU occupancy every run unless you ask
    for less. Falls back to CPU-only load automatically (with a one-time warning) if no
    compatible GPU/driver is available.

.EXAMPLE
    .\WPS-Bench.ps1

.EXAMPLE
    .\WPS-Bench.ps1 -Values 0x14,0x15,0x16,0x18,0x19,0x1A,0x24,0x25,0x26,0x28,0x29,0x2A -Runs 5 -DurationSec 5

.EXAMPLE
    .\WPS-Bench.ps1 -Resume
#>

[CmdletBinding()]
param(
    [int[]] $Values,

    [ValidateRange(1, 20)]
    [int] $Runs = 5,

    [ValidateRange(1, 60)]
    [int] $DurationSec = 5,

    [ValidateRange(0, 10000)]
    [int] $WarmupMs = 500,

    [ValidateRange(50, 100000)]
    [int] $IntervalTargetUs = 1000,

    [ValidateRange(1, 256)]
    [int] $BackgroundThreads = [Math]::Max(1, [Environment]::ProcessorCount - 1),

    [ValidateSet('AboveNormal', 'High')]
    [string] $ForegroundProcessPriority = 'AboveNormal',

    [ValidateSet('Normal', 'AboveNormal', 'Highest')]
    [string] $ForegroundThreadPriority = 'Highest',

    [ValidateRange(0.0, 1000.0)]
    [double] $VarianceThresholdPercent = 25.0,

    [ValidateRange(1.0, 100.0)]
    [double] $OutlierMultiplier = 3.0,

    [ValidateRange(0.0, 1.0)]
    [double] $JitterWeight = 0.5,

    [ValidateRange(0.0, 1.0)]
    [double] $P99Weight = 0.5,

    [ValidateRange(0.0, 1.0)]
    [double] $ConsistencyWeight = 0.2,

    [string] $OutputDir,

    [switch] $Resume,

    [ValidateSet('Off', 'Light', 'Medium', 'Heavy')]
    [string] $GpuLoad = 'Heavy'
)

# ---------------------------------------------------------------------------
# 0. Environment sanity checks
# ---------------------------------------------------------------------------

if (-not $IsWindows -and $PSVersionTable.PSVersion.Major -ge 6) {
    Write-Error "WPS Bench tunes the Windows CPU scheduler and only runs on Windows."
    exit 1
}

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $OutputDir) { $OutputDir = $ScriptDir }
if (-not (Test-Path $OutputDir)) { New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null }

# ---------------------------------------------------------------------------
# 1. Elevation check - relaunch elevated if needed
# ---------------------------------------------------------------------------

function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p = New-Object Security.Principal.WindowsPrincipal($id)
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-IsAdmin)) {
    Write-Warning "WPS Bench must run elevated (Administrator) because it modifies Win32PrioritySeparation."
    Write-Host "Attempting to relaunch elevated..." -ForegroundColor Yellow

    # NOTE: array parameters (e.g. -Values 0x14,0x15,0x16) only bind correctly when the comma
    # syntax is parsed by the PowerShell *language engine*. Relaunching via "-File" hands the
    # child process raw argv strings instead, which silently mangles comma-separated arrays
    # (PowerShell's parameter binder concatenates the numbers rather than building an array).
    # So instead of "-File", we build a real PowerShell command string and pass it via
    # "-Command", letting the child parse it exactly as if it had been typed interactively.
    $scriptPath = $MyInvocation.MyCommand.Path
    $cmdParts = New-Object System.Collections.Generic.List[string]
    $cmdParts.Add("& '" + ($scriptPath -replace "'", "''") + "'")

    foreach ($key in $PSBoundParameters.Keys) {
        $val = $PSBoundParameters[$key]
        if ($val -is [System.Management.Automation.SwitchParameter]) {
            if ($val.IsPresent) { $cmdParts.Add("-$key") }
        }
        elseif ($val -is [array]) {
            $joined = ($val | ForEach-Object { $_.ToString() }) -join ','
            $cmdParts.Add("-$key $joined")
        }
        elseif ($val -is [string]) {
            $escaped = $val -replace "'", "''"
            $cmdParts.Add("-$key '$escaped'")
        }
        else {
            $cmdParts.Add("-$key $val")
        }
    }

    $commandString = $cmdParts -join ' '

    try {
        Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', $commandString) -Verb RunAs | Out-Null
    }
    catch {
        Write-Error "Elevation was declined or failed: $_"
        exit 1
    }
    exit 0
}

# ---------------------------------------------------------------------------
# 1b. Runs-per-value prompt (only when -Runs wasn't passed explicitly)
# ---------------------------------------------------------------------------

if (-not $PSBoundParameters.ContainsKey('Runs')) {
    $inputRedirected = $false
    try { $inputRedirected = [Console]::IsInputRedirected } catch { }

    if ($inputRedirected) {
        Write-Host "No -Runs specified and input isn't interactive - defaulting to 5 runs per value." -ForegroundColor Yellow
        $Runs = 5
    }
    else {
        while ($true) {
            $ansStr = Read-Host "How many times do you want to test each value? (default: 5)"
            if ([string]::IsNullOrWhiteSpace($ansStr)) {
                $Runs = 5
                break
            }
            $parsedRuns = 0
            if ([int]::TryParse($ansStr.Trim(), [ref]$parsedRuns) -and $parsedRuns -ge 1) {
                $Runs = $parsedRuns
                break
            }
            Write-Host "Please enter a positive whole number (or press Enter for the default of 5)." -ForegroundColor Yellow
        }
        if ($Runs -lt 3) {
            Write-Warning "Runs=$Runs is below 3 - run-to-run variance won't be meaningfully measurable. Consider at least 3."
        }
    }
    # This value applies uniformly to every candidate value tested in this run.
}

# ---------------------------------------------------------------------------
# 2. Canonical 12-value candidate table
# ---------------------------------------------------------------------------

$WpsValueTable = @(
    [PSCustomObject]@{ ValueDec = 0x14; Length = 'Long';  Type = 'Variable'; Boost = 'None'   }
    [PSCustomObject]@{ ValueDec = 0x15; Length = 'Long';  Type = 'Variable'; Boost = 'Medium' }
    [PSCustomObject]@{ ValueDec = 0x16; Length = 'Long';  Type = 'Variable'; Boost = 'High'   }
    [PSCustomObject]@{ ValueDec = 0x18; Length = 'Long';  Type = 'Fixed';    Boost = 'None'   }
    [PSCustomObject]@{ ValueDec = 0x19; Length = 'Long';  Type = 'Fixed';    Boost = 'Medium' }
    [PSCustomObject]@{ ValueDec = 0x1A; Length = 'Long';  Type = 'Fixed';    Boost = 'High'   }
    [PSCustomObject]@{ ValueDec = 0x24; Length = 'Short'; Type = 'Variable'; Boost = 'None'   }
    [PSCustomObject]@{ ValueDec = 0x25; Length = 'Short'; Type = 'Variable'; Boost = 'Medium' }
    [PSCustomObject]@{ ValueDec = 0x26; Length = 'Short'; Type = 'Variable'; Boost = 'High'   } # Windows default
    [PSCustomObject]@{ ValueDec = 0x28; Length = 'Short'; Type = 'Fixed';    Boost = 'None'   }
    [PSCustomObject]@{ ValueDec = 0x29; Length = 'Short'; Type = 'Fixed';    Boost = 'Medium' }
    [PSCustomObject]@{ ValueDec = 0x2A; Length = 'Short'; Type = 'Fixed';    Boost = 'High'   }
) | ForEach-Object {
    $_ | Add-Member -NotePropertyName ValueHex -NotePropertyValue ("0x{0:X2}" -f $_.ValueDec) -PassThru |
        Add-Member -NotePropertyName Label -NotePropertyValue ("{0}/{1}/{2}" -f $_.Length, $_.Type, $_.Boost) -PassThru
}

if (-not $Values) {
    $Values = $WpsValueTable.ValueDec
}

$CandidateTable = @(foreach ($v in $Values) {
    $match = $WpsValueTable | Where-Object { $_.ValueDec -eq $v }
    if ($match) {
        $match
    }
    else {
        if ($v -lt 0 -or $v -gt 0x3F) {
            Write-Error "Value 0x$($v.ToString('X2')) is outside the valid 0x00-0x3F range and will be skipped."
            continue
        }
        Write-Warning "Value 0x$($v.ToString('X2')) is not one of the 12 canonical values - testing anyway, but note the kernel only reads the low 6 bits."
        [PSCustomObject]@{
            ValueDec = $v
            ValueHex = "0x{0:X2}" -f $v
            Length   = '?'
            Type     = '?'
            Boost    = '?'
            Label    = "Custom (0x{0:X2})" -f $v
        }
    }
})

# ---------------------------------------------------------------------------
# 3. Logging
# ---------------------------------------------------------------------------

$Timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$LogPath = Join-Path $OutputDir "WPS_Bench_Log_$Timestamp.log"

function Write-Log {
    param([string] $Message)
    $line = "[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'), $Message
    Add-Content -Path $LogPath -Value $line
}

# ---------------------------------------------------------------------------
# 4. C# precision timing engine + background load generator
# ---------------------------------------------------------------------------

if (-not ('WpsBench.Timer' -as [type])) {
    Add-Type -Language CSharp -TypeDefinition @'
using System;
using System.Diagnostics;
using System.Threading;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

namespace WpsBench
{
    public static class Timer
    {
        public static ThreadPriority ForegroundThreadPriority = ThreadPriority.Highest;
        public static ProcessPriorityClass ForegroundProcessPriority = ProcessPriorityClass.AboveNormal;

        // Runs a tight timed loop for durationMs, targeting intervalTargetUs between ticks.
        // Returns the actual delta of every tick, in microseconds. Uses Stopwatch only.
        public static double[] RunForegroundLoop(int durationMs, int intervalTargetUs)
        {
            Thread.CurrentThread.Priority = ForegroundThreadPriority;
            try { Process.GetCurrentProcess().PriorityClass = ForegroundProcessPriority; } catch { }

            double freq = Stopwatch.Frequency;
            long targetTicks = (long)((intervalTargetUs / 1000000.0) * freq);
            if (targetTicks < 1) targetTicks = 1;

            int capacityHint = (int)((durationMs * 1000L) / Math.Max(intervalTargetUs, 1)) + 64;
            List<double> deltas = new List<double>(capacityHint);

            Stopwatch sw = Stopwatch.StartNew();
            long endTicks = (long)((durationMs / 1000.0) * freq);

            long lastTick = sw.ElapsedTicks;
            long nextTarget = lastTick + targetTicks;

            while (sw.ElapsedTicks < endTicks)
            {
                long now;
                while ((now = sw.ElapsedTicks) < nextTarget) { }

                double deltaUs = (now - lastTick) * 1000000.0 / freq;
                deltas.Add(deltaUs);
                lastTick = now;
                nextTarget = now + targetTicks;
            }

            return deltas.ToArray();
        }
    }

    public class BackgroundLoadGenerator
    {
        private readonly List<Thread> _threads = new List<Thread>();
        private volatile bool _running;

        public void Start(int threadCount)
        {
            _running = true;
            _threads.Clear();
            for (int i = 0; i < threadCount; i++)
            {
                Thread t = new Thread(BusyLoop);
                t.IsBackground = true;
                t.Priority = ThreadPriority.Normal;
                _threads.Add(t);
                t.Start();
            }
        }

        private void BusyLoop()
        {
            // Simple integer math, no allocations -> no GC pressure, purely CPU-bound.
            uint x = (uint)Environment.TickCount | 1u;
            while (_running)
            {
                for (int i = 0; i < 200000; i++)
                {
                    x ^= x << 13;
                    x ^= x >> 17;
                    x ^= x << 5;
                }
            }
        }

        public void Stop()
        {
            _running = false;
            foreach (Thread t in _threads) { t.Join(2000); }
            _threads.Clear();
        }
    }

    // ------------------------------------------------------------------
    // GPU load generator: drives a D3D11 compute shader continuously on its
    // own thread so Win32PrioritySeparation is tested against realistic
    // driver-side CPU overhead (command submission/synchronization), not
    // just synthetic CPU busy-loops. No SharpDX/managed D3D wrapper is used
    // - the vtables below are a flat, hand-verified transcription of the
    // real d3d11.h / d3dcommon.h COM interface layouts (cross-checked
    // against the winapi-rs bindings, which mirror the Microsoft headers
    // field-for-field). Slots this tool never calls are declared as
    // zero-arg placeholders purely to reserve their vtable position -
    // declaration ORDER is what matters for COM dispatch, not the dummy
    // signature. Only the named/real methods below are ever invoked.
    // ------------------------------------------------------------------

    [StructLayout(LayoutKind.Sequential)]
    public struct D3D11_BUFFER_DESC
    {
        public uint ByteWidth;
        public uint Usage;
        public uint BindFlags;
        public uint CPUAccessFlags;
        public uint MiscFlags;
        public uint StructureByteStride;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct D3D11_UNORDERED_ACCESS_VIEW_DESC
    {
        public uint Format;
        public uint ViewDimension;
        public uint FirstElement;
        public uint NumElements;
        public uint Flags;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct D3D11_MAPPED_SUBRESOURCE
    {
        public IntPtr pData;
        public uint RowPitch;
        public uint DepthPitch;
    }

    [ComImport, Guid("db6f6ddb-ac77-4e88-8253-819df9bbf140"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface ID3D11DeviceRaw
    {
        [PreserveSig] int CreateBuffer(ref D3D11_BUFFER_DESC pDesc, IntPtr pInitialData, out IntPtr ppBuffer);
        void Reserved_CreateTexture1D();
        void Reserved_CreateTexture2D();
        void Reserved_CreateTexture3D();
        void Reserved_CreateShaderResourceView();
        [PreserveSig] int CreateUnorderedAccessView(IntPtr pResource, ref D3D11_UNORDERED_ACCESS_VIEW_DESC pDesc, out IntPtr ppUAView);
        void Reserved_CreateRenderTargetView();
        void Reserved_CreateDepthStencilView();
        void Reserved_CreateInputLayout();
        void Reserved_CreateVertexShader();
        void Reserved_CreateGeometryShader();
        void Reserved_CreateGeometryShaderWithStreamOutput();
        void Reserved_CreatePixelShader();
        void Reserved_CreateHullShader();
        void Reserved_CreateDomainShader();
        [PreserveSig] int CreateComputeShader(IntPtr pShaderBytecode, UIntPtr BytecodeLength, IntPtr pClassLinkage, out IntPtr ppComputeShader);
    }

    [ComImport, Guid("c0bfa96c-e089-44fb-8eaf-26f8796190da"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface ID3D11DeviceContextRaw
    {
        // ID3D11DeviceChild (base interface) - 4 slots
        void Reserved_GetDevice();
        void Reserved_GetPrivateData();
        void Reserved_SetPrivateData();
        void Reserved_SetPrivateDataInterface();
        // ID3D11DeviceContext's own methods, true declaration order
        void Reserved_VSSetConstantBuffers();
        void Reserved_PSSetShaderResources();
        void Reserved_PSSetShader();
        void Reserved_PSSetSamplers();
        void Reserved_VSSetShader();
        void Reserved_DrawIndexed();
        void Reserved_Draw();
        [PreserveSig] int Map(IntPtr pResource, uint Subresource, uint MapType, uint MapFlags, out D3D11_MAPPED_SUBRESOURCE pMappedResource);
        [PreserveSig] void Unmap(IntPtr pResource, uint Subresource);
        void Reserved_PSSetConstantBuffers();
        void Reserved_IASetInputLayout();
        void Reserved_IASetVertexBuffers();
        void Reserved_IASetIndexBuffer();
        void Reserved_DrawIndexedInstanced();
        void Reserved_DrawInstanced();
        void Reserved_GSSetConstantBuffers();
        void Reserved_GSSetShader();
        void Reserved_IASetPrimitiveTopology();
        void Reserved_VSSetShaderResources();
        void Reserved_VSSetSamplers();
        void Reserved_Begin();
        void Reserved_End();
        void Reserved_GetData();
        void Reserved_SetPredication();
        void Reserved_GSSetShaderResources();
        void Reserved_GSSetSamplers();
        void Reserved_OMSetRenderTargets();
        void Reserved_OMSetRenderTargetsAndUnorderedAccessViews();
        void Reserved_OMSetBlendState();
        void Reserved_OMSetDepthStencilState();
        void Reserved_SOSetTargets();
        void Reserved_DrawAuto();
        void Reserved_DrawIndexedInstancedIndirect();
        void Reserved_DrawInstancedIndirect();
        [PreserveSig] void Dispatch(uint ThreadGroupCountX, uint ThreadGroupCountY, uint ThreadGroupCountZ);
        void Reserved_DispatchIndirect();
        void Reserved_RSSetState();
        void Reserved_RSSetViewports();
        void Reserved_RSSetScissorRects();
        void Reserved_CopySubresourceRegion();
        [PreserveSig] void CopyResource(IntPtr pDstResource, IntPtr pSrcResource);
        void Reserved_UpdateSubresource();
        void Reserved_CopyStructureCount();
        void Reserved_ClearRenderTargetView();
        void Reserved_ClearUnorderedAccessViewUint();
        void Reserved_ClearUnorderedAccessViewFloat();
        void Reserved_ClearDepthStencilView();
        void Reserved_GenerateMips();
        void Reserved_SetResourceMinLOD();
        void Reserved_GetResourceMinLOD();
        void Reserved_ResolveSubresource();
        void Reserved_ExecuteCommandList();
        void Reserved_HSSetShaderResources();
        void Reserved_HSSetShader();
        void Reserved_HSSetSamplers();
        void Reserved_HSSetConstantBuffers();
        void Reserved_DSSetShaderResources();
        void Reserved_DSSetShader();
        void Reserved_DSSetSamplers();
        void Reserved_DSSetConstantBuffers();
        void Reserved_CSSetShaderResources();
        [PreserveSig] void CSSetUnorderedAccessViews(uint StartSlot, uint NumUAVs, ref IntPtr ppUnorderedAccessViews, IntPtr pUAVInitialCounts);
        [PreserveSig] void CSSetShader(IntPtr pComputeShader, IntPtr ppClassInstances, uint NumClassInstances);
    }

    [ComImport, Guid("8ba5fb08-5195-40e2-ac58-0d989c3a0102"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface ID3D10BlobRaw
    {
        [PreserveSig] IntPtr GetBufferPointer();
        [PreserveSig] UIntPtr GetBufferSize();
    }

    internal static class D3DNative
    {
        [DllImport("d3d11.dll", CallingConvention = CallingConvention.StdCall)]
        internal static extern int D3D11CreateDevice(
            IntPtr pAdapter, uint DriverType, IntPtr Software, uint Flags,
            int[] pFeatureLevels, uint FeatureLevels, uint SDKVersion,
            out ID3D11DeviceRaw ppDevice, out int pFeatureLevel, out ID3D11DeviceContextRaw ppImmediateContext);

        [DllImport("d3dcompiler_47.dll", CallingConvention = CallingConvention.StdCall)]
        internal static extern int D3DCompile(
            byte[] pSrcData, UIntPtr SrcDataSize,
            [MarshalAs(UnmanagedType.LPStr)] string pSourceName,
            IntPtr pDefines, IntPtr pInclude,
            [MarshalAs(UnmanagedType.LPStr)] string pEntrypoint,
            [MarshalAs(UnmanagedType.LPStr)] string pTarget,
            uint Flags1, uint Flags2,
            out ID3D10BlobRaw ppCode, out ID3D10BlobRaw ppErrorMsgs);

        // Default Windows timer resolution can make Thread.Sleep(1) actually sleep ~15.6ms.
        // Raising it to 1ms while the GPU load thread is pacing its idle gaps keeps the
        // Light/Medium duty-cycle timing reasonably accurate instead of wildly overshooting.
        [DllImport("winmm.dll", EntryPoint = "timeBeginPeriod")]
        internal static extern uint TimeBeginPeriod(uint uPeriod);

        [DllImport("winmm.dll", EntryPoint = "timeEndPeriod")]
        internal static extern uint TimeEndPeriod(uint uPeriod);
    }

    public enum GpuLoadIntensity { Light, Medium, Heavy }

    public class GpuLoad
    {
        private const uint D3D11_USAGE_DEFAULT = 0;
        private const uint D3D11_USAGE_STAGING = 3;
        private const uint D3D11_BIND_UNORDERED_ACCESS = 0x80;
        private const uint D3D11_CPU_ACCESS_READ = 0x20000;
        private const uint D3D11_RESOURCE_MISC_BUFFER_STRUCTURED = 0x40;
        private const uint D3D11_MAP_READ = 1;
        private const uint D3D_DRIVER_TYPE_HARDWARE = 1;
        private const int D3D_FEATURE_LEVEL_11_0 = 0xb000;
        private const int D3D_FEATURE_LEVEL_10_0 = 0xa000;

        // A single Dispatch() at WORK_GROUPS groups (numthreads(256,1,1) x WORK_GROUPS =
        // 524288 threads, 2000 trig iterations each) measures ~5ms of real GPU-side compute on
        // a GTX 1660 Super - calibrated empirically so the GPU is actually kept busy, not just
        // issued a dispatch call it finishes before the next one arrives. This is a tiny
        // fraction of the ~2s Windows TDR (driver timeout/reset) threshold, so it's safe to
        // call repeatedly even on the primary display GPU. Intensity is controlled purely by
        // how much idle time follows each dispatch (duty cycle), not by shrinking the work
        // itself - see RunLoop.
        private const uint WORK_GROUPS = 2048;
        private const uint THREADS_PER_GROUP = 256;
        private const uint ELEMENT_COUNT = WORK_GROUPS * THREADS_PER_GROUP;

        private const string ShaderSource =
            "RWStructuredBuffer<float> Result : register(u0);\n" +
            "[numthreads(256, 1, 1)]\n" +
            "void CSMain(uint3 DTid : SV_DispatchThreadID)\n" +
            "{\n" +
            "    float x = (float)DTid.x * 0.001f + 1.0f;\n" +
            "    for (uint i = 0; i < 2000; i++)\n" +
            "    {\n" +
            "        x = sin(x) * cos(x) + sqrt(abs(x)) + 1.0001f;\n" +
            "    }\n" +
            "    Result[DTid.x] = x;\n" +
            "}\n";

        private Thread _thread;
        private volatile bool _running;

        public string LastError { get; private set; }
        public bool IsRunning { get; private set; }

        public bool Start(GpuLoadIntensity intensity)
        {
            LastError = null;
            IsRunning = false;
            _running = true;

            ManualResetEventSlim ready = new ManualResetEventSlim(false);
            bool[] ok = new bool[] { false };

            _thread = new Thread(() =>
            {
                try
                {
                    RunLoop(intensity, ready, ok);
                }
                catch (Exception ex)
                {
                    LastError = ex.Message;
                    ok[0] = false;
                    ready.Set();
                }
            });
            _thread.IsBackground = true;
            _thread.Start();

            ready.Wait(15000);
            IsRunning = ok[0];
            return IsRunning;
        }

        public void Stop()
        {
            _running = false;
            if (_thread != null) { _thread.Join(3000); }
            _thread = null;
            IsRunning = false;
        }

        private void RunLoop(GpuLoadIntensity intensity, ManualResetEventSlim ready, bool[] ok)
        {
            ID3D11DeviceRaw device = null;
            ID3D11DeviceContextRaw context = null;
            ID3D10BlobRaw codeBlob = null;
            ID3D10BlobRaw errBlob = null;
            IntPtr computeShader = IntPtr.Zero;
            IntPtr gpuBuffer = IntPtr.Zero;
            IntPtr stagingBuffer = IntPtr.Zero;
            IntPtr uav = IntPtr.Zero;
            bool timerPeriodRaised = false;

            try
            {
                int featureLevel;
                int[] levels = new int[] { D3D_FEATURE_LEVEL_11_0, D3D_FEATURE_LEVEL_10_0 };
                int hr = D3DNative.D3D11CreateDevice(IntPtr.Zero, D3D_DRIVER_TYPE_HARDWARE, IntPtr.Zero, 0,
                    levels, (uint)levels.Length, 7, out device, out featureLevel, out context);
                if (hr < 0) { throw new InvalidOperationException("D3D11CreateDevice failed: 0x" + hr.ToString("X8")); }

                byte[] srcBytes = Encoding.ASCII.GetBytes(ShaderSource);
                int chr = D3DNative.D3DCompile(srcBytes, (UIntPtr)srcBytes.Length, "wpsbench_gpu_load.hlsl",
                    IntPtr.Zero, IntPtr.Zero, "CSMain", "cs_5_0", 0x8000u, 0u, out codeBlob, out errBlob);
                if (chr < 0)
                {
                    string msg = "D3DCompile failed: 0x" + chr.ToString("X8");
                    if (errBlob != null)
                    {
                        IntPtr ep = errBlob.GetBufferPointer();
                        if (ep != IntPtr.Zero) { msg += " - " + Marshal.PtrToStringAnsi(ep); }
                    }
                    throw new InvalidOperationException(msg);
                }

                IntPtr bytecodePtr = codeBlob.GetBufferPointer();
                UIntPtr bytecodeSize = codeBlob.GetBufferSize();

                int cshr = device.CreateComputeShader(bytecodePtr, bytecodeSize, IntPtr.Zero, out computeShader);
                if (cshr < 0) { throw new InvalidOperationException("CreateComputeShader failed: 0x" + cshr.ToString("X8")); }

                D3D11_BUFFER_DESC bufDesc = new D3D11_BUFFER_DESC();
                bufDesc.ByteWidth = ELEMENT_COUNT * 4;
                bufDesc.Usage = D3D11_USAGE_DEFAULT;
                bufDesc.BindFlags = D3D11_BIND_UNORDERED_ACCESS;
                bufDesc.CPUAccessFlags = 0;
                bufDesc.MiscFlags = D3D11_RESOURCE_MISC_BUFFER_STRUCTURED;
                bufDesc.StructureByteStride = 4;

                int bhr = device.CreateBuffer(ref bufDesc, IntPtr.Zero, out gpuBuffer);
                if (bhr < 0) { throw new InvalidOperationException("CreateBuffer (UAV target) failed: 0x" + bhr.ToString("X8")); }

                D3D11_BUFFER_DESC stagingDesc = bufDesc;
                stagingDesc.Usage = D3D11_USAGE_STAGING;
                stagingDesc.BindFlags = 0;
                stagingDesc.CPUAccessFlags = D3D11_CPU_ACCESS_READ;

                int shr = device.CreateBuffer(ref stagingDesc, IntPtr.Zero, out stagingBuffer);
                if (shr < 0) { throw new InvalidOperationException("CreateBuffer (staging) failed: 0x" + shr.ToString("X8")); }

                D3D11_UNORDERED_ACCESS_VIEW_DESC uavDesc = new D3D11_UNORDERED_ACCESS_VIEW_DESC();
                uavDesc.Format = 0; // DXGI_FORMAT_UNKNOWN - required for structured buffer UAVs
                uavDesc.ViewDimension = 1; // D3D11_UAV_DIMENSION_BUFFER
                uavDesc.FirstElement = 0;
                uavDesc.NumElements = ELEMENT_COUNT;
                uavDesc.Flags = 0;

                int uhr = device.CreateUnorderedAccessView(gpuBuffer, ref uavDesc, out uav);
                if (uhr < 0) { throw new InvalidOperationException("CreateUnorderedAccessView failed: 0x" + uhr.ToString("X8")); }

                context.CSSetShader(computeShader, IntPtr.Zero, 0);
                IntPtr uavForBind = uav;
                context.CSSetUnorderedAccessViews(0, 1, ref uavForBind, IntPtr.Zero);

                // Self-test: dispatch once, copy to staging, map, and verify the shader actually
                // produced finite, non-trivial output before trusting this vtable layout for the
                // real load-generation loop below.
                context.Dispatch(4, 1, 1);
                context.CopyResource(stagingBuffer, gpuBuffer);
                D3D11_MAPPED_SUBRESOURCE mapped;
                int mhr = context.Map(stagingBuffer, 0, D3D11_MAP_READ, 0, out mapped);
                if (mhr < 0) { throw new InvalidOperationException("Map (self-test) failed: 0x" + mhr.ToString("X8")); }
                float[] sample = new float[8];
                Marshal.Copy(mapped.pData, sample, 0, 8);
                context.Unmap(stagingBuffer, 0);

                bool allZero = true;
                foreach (float f in sample)
                {
                    if (float.IsNaN(f) || float.IsInfinity(f))
                    {
                        throw new InvalidOperationException("Self-test failed: compute shader produced NaN/Infinity.");
                    }
                    if (f != 0f) { allZero = false; }
                }
                if (allZero)
                {
                    throw new InvalidOperationException("Self-test failed: compute shader output was all zero (dispatch likely did not execute).");
                }

                ok[0] = true;
                ready.Set();

                // Empirically calibrated: one WORK_GROUPS-sized dispatch takes ~5ms of actual
                // GPU execution on a GTX 1660 Super. Intensity is the fraction of time spent
                // dispatching vs. idle (duty cycle) - Heavy dispatches back-to-back (GPU-bound,
                // near-continuous occupancy); Medium/Light insert idle gaps so the GPU is
                // genuinely busy only part of the time, matching how a lighter game scene
                // would load the GPU less than a demanding one.
                double idleMsPerDispatch;
                switch (intensity)
                {
                    case GpuLoadIntensity.Light: idleMsPerDispatch = 15.0; break;  // ~25% duty cycle
                    case GpuLoadIntensity.Heavy: idleMsPerDispatch = 0.0; break;   // ~100% duty cycle
                    default: idleMsPerDispatch = 5.0; break;                       // Medium, ~50% duty cycle
                }

                if (idleMsPerDispatch > 0)
                {
                    try { D3DNative.TimeBeginPeriod(1); timerPeriodRaised = true; } catch { }
                }

                while (_running)
                {
                    context.Dispatch(WORK_GROUPS, 1, 1);
                    context.CopyResource(stagingBuffer, gpuBuffer);

                    // Map() on the immediate context blocks until the GPU has actually finished
                    // the work affecting this resource - without a real sync point like this,
                    // D3D11 can batch/defer Dispatch calls indefinitely instead of submitting
                    // them as they're issued, which decouples "when we call Dispatch" from
                    // "when the GPU actually runs it" and breaks duty-cycle timing entirely.
                    // This blocking wait is also exactly the kind of CPU-side driver
                    // synchronization overhead a real game's render loop produces every frame -
                    // not a bug, the point.
                    D3D11_MAPPED_SUBRESOURCE syncMap;
                    int syncHr = context.Map(stagingBuffer, 0, D3D11_MAP_READ, 0, out syncMap);
                    if (syncHr >= 0) { context.Unmap(stagingBuffer, 0); }

                    if (idleMsPerDispatch > 0)
                    {
                        Stopwatch idleSw = Stopwatch.StartNew();
                        while (idleSw.Elapsed.TotalMilliseconds < idleMsPerDispatch && _running) { Thread.Sleep(1); }
                    }
                }
            }
            finally
            {
                try { if (timerPeriodRaised) { D3DNative.TimeEndPeriod(1); } } catch { }
                try { if (uav != IntPtr.Zero) { Marshal.Release(uav); } } catch { }
                try { if (stagingBuffer != IntPtr.Zero) { Marshal.Release(stagingBuffer); } } catch { }
                try { if (gpuBuffer != IntPtr.Zero) { Marshal.Release(gpuBuffer); } } catch { }
                try { if (computeShader != IntPtr.Zero) { Marshal.Release(computeShader); } } catch { }
                try { if (errBlob != null) { Marshal.ReleaseComObject(errBlob); } } catch { }
                try { if (codeBlob != null) { Marshal.ReleaseComObject(codeBlob); } } catch { }
                try { if (context != null) { Marshal.ReleaseComObject(context); } } catch { }
                try { if (device != null) { Marshal.ReleaseComObject(device); } } catch { }
                if (!ready.IsSet) { ready.Set(); }
            }
        }
    }
}
'@
}

# ---------------------------------------------------------------------------
# 5. Registry backup / restore
# ---------------------------------------------------------------------------

$RegPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\PriorityControl'
$RegName = 'Win32PrioritySeparation'

$OriginalValuePresent = $true
try {
    $OriginalValue = (Get-ItemProperty -Path $RegPath -Name $RegName -ErrorAction Stop).$RegName
}
catch {
    $OriginalValuePresent = $false
    $OriginalValue = $null
}
Write-Log ("Original {0} = {1}" -f $RegName, $(if ($OriginalValuePresent) { $OriginalValue } else { '<not present>' }))

$script:RestoredAlready = $false
function Restore-OriginalValue {
    if ($script:RestoredAlready) { return }
    $script:RestoredAlready = $true
    try {
        if ($OriginalValuePresent) {
            Set-ItemProperty -Path $RegPath -Name $RegName -Value $OriginalValue -Type DWord
            Write-Log ("Restored {0} to original value {1}" -f $RegName, $OriginalValue)
            Write-Host "Restored $RegName to original value $OriginalValue." -ForegroundColor Green
        }
        else {
            Remove-ItemProperty -Path $RegPath -Name $RegName -ErrorAction SilentlyContinue
            Write-Log ("Removed {0} (was not originally present)" -f $RegName)
            Write-Host "$RegName was not originally present - removed." -ForegroundColor Green
        }
    }
    catch {
        Write-Warning "Failed to restore original registry value: $_"
        Write-Log ("ERROR restoring original value: {0}" -f $_)
    }
}

function Set-WpsValue {
    param([int] $Value)
    if ($Value -lt 0 -or $Value -gt 0x3F) {
        throw "Refusing to write out-of-range value 0x$($Value.ToString('X2')) (valid range is 0x00-0x3F)."
    }
    Set-ItemProperty -Path $RegPath -Name $RegName -Value $Value -Type DWord
    Write-Log ("Set {0} = 0x{1:X2} ({1})" -f $RegName, $Value)
}

# ---------------------------------------------------------------------------
# 6. Ctrl+C handling
# ---------------------------------------------------------------------------

# Primary mechanism: a console CancelKeyPress handler lets us finish the in-flight run
# gracefully and break out of the loop cleanly. This requires a real attached console, so it
# can fail in some hosts (e.g. certain non-interactive automation contexts) - if so we fall
# back silently to the trap/finally safety net below, which is host-independent.
$script:CancelRequested = $false
try {
    [Console]::CancelKeyPress.Add({
        param($cSender, $cArgs)
        $cArgs.Cancel = $true
        $script:CancelRequested = $true
        Write-Host "`nCtrl+C received - finishing current run, then restoring registry and exiting..." -ForegroundColor Yellow
    })
}
catch {
    Write-Verbose "Could not register a console CancelKeyPress handler in this host; relying on trap/finally for Ctrl+C cleanup instead."
}

# Backup mechanism (per spec): a script-scope trap catches the PipelineStoppedException that
# Ctrl+C raises (when no CancelKeyPress handler intercepted it first) as well as any other
# unexpected terminating error, restores the registry, and stops background load before the
# script unwinds.
trap {
    Write-Warning "Unexpected terminating error or interrupt: $_"
    Write-Log "TRAP: $_"
    Restore-OriginalValue
    if (Get-Variable -Name loadGen -Scope Script -ErrorAction SilentlyContinue) {
        try { $loadGen.Stop() } catch { }
    }
    if (Get-Variable -Name gpuLoadGen -Scope Script -ErrorAction SilentlyContinue) {
        try { if ($gpuLoadGen) { $gpuLoadGen.Stop() } } catch { }
    }
    break
}

# ---------------------------------------------------------------------------
# 7. Stats
# ---------------------------------------------------------------------------

function Get-DeltaStats {
    param(
        [double[]] $Deltas,
        [double] $TargetUs,
        [double] $OutlierMultiplier
    )
    $n = $Deltas.Count
    if ($n -eq 0) {
        return [PSCustomObject]@{ MeanIntervalUs = 0; JitterUs = 0; P99Us = 0; OutlierCount = 0 }
    }

    $sum = 0.0
    foreach ($d in $Deltas) { $sum += $d }
    $mean = $sum / $n

    $sqSum = 0.0
    foreach ($d in $Deltas) { $sqSum += [Math]::Pow($d - $mean, 2) }
    $stdev = [Math]::Sqrt($sqSum / $n)

    $sorted = $Deltas | Sort-Object
    $p99Index = [Math]::Ceiling(0.99 * $n) - 1
    if ($p99Index -ge $n) { $p99Index = $n - 1 }
    if ($p99Index -lt 0) { $p99Index = 0 }
    $p99 = $sorted[$p99Index]

    $outlierThreshold = $TargetUs * $OutlierMultiplier
    $outlierCount = 0
    foreach ($d in $Deltas) { if ($d -gt $outlierThreshold) { $outlierCount++ } }

    [PSCustomObject]@{
        MeanIntervalUs = [Math]::Round($mean, 3)
        JitterUs       = [Math]::Round($stdev, 3)
        P99Us          = [Math]::Round($p99, 3)
        OutlierCount   = $outlierCount
    }
}

function Get-PopulationStdev {
    param([double[]] $Values)
    if ($Values.Count -le 1) { return 0.0 }
    $mean = ($Values | Measure-Object -Average).Average
    $sqSum = 0.0
    foreach ($v in $Values) { $sqSum += [Math]::Pow($v - $mean, 2) }
    return [Math]::Sqrt($sqSum / $Values.Count)
}

function Get-MinMaxNorm {
    # Scales Value into 0-1 relative to [Min, Max]. When Min equals Max (no spread across the
    # candidates being compared), returns 0 - with nothing to discriminate on, this term should
    # not penalize any candidate.
    param([double] $Value, [double] $Min, [double] $Max)
    if ($Max -eq $Min) { return 0.0 }
    return ($Value - $Min) / ($Max - $Min)
}

# ---------------------------------------------------------------------------
# 8. Resume support / CSV setup
# ---------------------------------------------------------------------------

$completedSet = New-Object 'System.Collections.Generic.HashSet[string]'
$csvPath = Join-Path $OutputDir 'WPS_Bench_Results.csv'

if ($Resume) {
    if (Test-Path $csvPath) {
        try {
            Import-Csv -Path $csvPath | ForEach-Object {
                [void]$completedSet.Add("$($_.ValueDec)_$($_.Run)")
            }
            Write-Host "Resuming from $csvPath ($($completedSet.Count) run(s) already completed)." -ForegroundColor Cyan
        }
        catch {
            Write-Warning "Could not parse existing results file for resume: $_"
        }
    }
    else {
        Write-Host "No existing results file found at $csvPath to resume from - starting fresh." -ForegroundColor Cyan
    }
}
else {
    # Fresh (non-resumed) run: never let a previous run's results linger or mix with this one.
    if (Test-Path $csvPath) {
        Remove-Item -Path $csvPath -Force
        Write-Log "Deleted previous results file $csvPath before starting a new run."
        Write-Host "Removed previous results file $csvPath (pass -Resume to continue it instead)." -ForegroundColor DarkYellow
    }
}

# ---------------------------------------------------------------------------
# 9. Header / ETA
# ---------------------------------------------------------------------------

$totalRuns = $CandidateTable.Count * $Runs
$estSecPerRun = $DurationSec + ($WarmupMs / 1000.0) + 0.5
$estTotalSec = $totalRuns * $estSecPerRun

Write-Host ""
Write-Host "=== WPS Bench - Win32PrioritySeparation Benchmark ===" -ForegroundColor Cyan
Write-Host "Candidate values : $($CandidateTable.Count)"
Write-Host "Runs per value   : $Runs"
Write-Host "Duration/run     : ${DurationSec}s (+ ${WarmupMs}ms warm-up)"
Write-Host "Background threads: $BackgroundThreads"
Write-Host "GPU load         : $GpuLoad"
Write-Host "Foreground prio  : process=$ForegroundProcessPriority thread=$ForegroundThreadPriority"
Write-Host "Total test runs  : $totalRuns"
Write-Host ("Estimated time   : ~{0:N1} minutes" -f ($estTotalSec / 60.0))
Write-Host "Results CSV      : $csvPath"
Write-Host "Log file         : $LogPath"
Write-Host ""

Write-Log "=== WPS Bench run started ==="
Write-Log "Params: Values=$($Values -join ','); Runs=$Runs; DurationSec=$DurationSec; WarmupMs=$WarmupMs; IntervalTargetUs=$IntervalTargetUs; BackgroundThreads=$BackgroundThreads; GpuLoad=$GpuLoad; ForegroundProcessPriority=$ForegroundProcessPriority; ForegroundThreadPriority=$ForegroundThreadPriority"

# ---------------------------------------------------------------------------
# 10. Main benchmark loop
# ---------------------------------------------------------------------------

$allResults = New-Object System.Collections.Generic.List[object]
$loadGen = New-Object WpsBench.BackgroundLoadGenerator
$testIndex = 1

$gpuLoadGen = $null
$gpuLoadGenFailed = $false
if ($GpuLoad -ne 'Off') {
    $gpuLoadGen = New-Object WpsBench.GpuLoad
}

try {
    :valueLoop foreach ($entry in $CandidateTable) {
        if ($script:CancelRequested) { break valueLoop }

        $valueDec = $entry.ValueDec
        $label = $entry.Label

        try {
            Set-WpsValue -Value $valueDec
        }
        catch {
            Write-Warning "Skipping $label : $_"
            continue
        }
        Start-Sleep -Milliseconds 200

        $runResults = New-Object System.Collections.Generic.List[object]

        for ($run = 1; $run -le $Runs; $run++) {
            if ($script:CancelRequested) { break valueLoop }

            $key = "${valueDec}_${run}"
            if ($completedSet.Contains($key)) {
                Write-Host "  [skip] $label (0x$($valueDec.ToString('X2'))) run $run/$Runs - already in results file" -ForegroundColor DarkGray
                continue
            }

            Write-Host ("[{0}/{1}] {2} (0x{3:X2}) - run {4}/{5}..." -f $testIndex, $totalRuns, $label, $valueDec, $run, $Runs) -NoNewline
            $testIndex++

            $loadGen.Start($BackgroundThreads)

            $gpuLoadGenRunning = $false
            if ($gpuLoadGen -and -not $gpuLoadGenFailed) {
                $gpuLoadGenRunning = $gpuLoadGen.Start([WpsBench.GpuLoadIntensity]$GpuLoad)
                if (-not $gpuLoadGenRunning) {
                    $gpuLoadGenFailed = $true
                    Write-Warning "GPU load could not be started ($($gpuLoadGen.LastError)) - continuing with CPU-only background load for the rest of this run."
                    Write-Log "WARNING: GPU load failed to start: $($gpuLoadGen.LastError)"
                }
            }

            Start-Sleep -Milliseconds $WarmupMs

            [WpsBench.Timer]::ForegroundThreadPriority = [System.Threading.ThreadPriority]$ForegroundThreadPriority
            [WpsBench.Timer]::ForegroundProcessPriority = [System.Diagnostics.ProcessPriorityClass]$ForegroundProcessPriority
            $deltas = [WpsBench.Timer]::RunForegroundLoop($DurationSec * 1000, $IntervalTargetUs)

            if ($gpuLoadGenRunning) { $gpuLoadGen.Stop() }
            $loadGen.Stop()

            $stats = Get-DeltaStats -Deltas $deltas -TargetUs $IntervalTargetUs -OutlierMultiplier $OutlierMultiplier

            $row = [PSCustomObject]@{
                ValueHex       = "0x{0:X2}" -f $valueDec
                ValueDec       = $valueDec
                Label          = $label
                Run            = $run
                MeanIntervalUs = $stats.MeanIntervalUs
                JitterUs       = $stats.JitterUs
                P99Us          = $stats.P99Us
                OutlierCount   = $stats.OutlierCount
            }

            $row | Export-Csv -Path $csvPath -Append -NoTypeInformation
            $runResults.Add($row)
            $allResults.Add($row)

            Write-Host (" mean={0}us jitter={1}us p99={2}us outliers={3}" -f $stats.MeanIntervalUs, $stats.JitterUs, $stats.P99Us, $stats.OutlierCount)
            Write-Log ("Result {0} run {1}: mean={2}us jitter={3}us p99={4}us outliers={5}" -f $label, $run, $stats.MeanIntervalUs, $stats.JitterUs, $stats.P99Us, $stats.OutlierCount)
        }

        if ($runResults.Count -gt 1) {
            $means = $runResults.MeanIntervalUs
            $mMean = ($means | Measure-Object -Average).Average
            $mSqSum = 0.0
            foreach ($m in $means) { $mSqSum += [Math]::Pow($m - $mMean, 2) }
            $mStdev = [Math]::Sqrt($mSqSum / $means.Count)
            $relVar = if ($mMean -ne 0) { ($mStdev / $mMean) * 100 } else { 0 }

            if ($relVar -gt $VarianceThresholdPercent) {
                $msg = "High run-to-run variance for $label (0x$($valueDec.ToString('X2'))): $([Math]::Round($relVar,1))% > threshold $VarianceThresholdPercent%. This value's results are inconsistent between runs - a restart may be needed for the scheduler change to fully apply. Consider re-testing this value after a reboot."
                Write-Warning $msg
                Write-Log "WARNING: $msg"
            }
        }
    }
}
finally {
    Restore-OriginalValue
    $loadGen.Stop()
    if ($gpuLoadGen) { try { $gpuLoadGen.Stop() } catch { } }
}

if ($script:CancelRequested) {
    Write-Host ""
    Write-Host "Run cancelled by user - registry restored, partial results saved to $csvPath" -ForegroundColor Yellow
    Write-Log "=== WPS Bench run cancelled by user ==="
}

# ---------------------------------------------------------------------------
# 11. Summary
# ---------------------------------------------------------------------------

# Build the summary from the full CSV on disk (not just $allResults), so a resumed session's
# summary reflects every run ever recorded for this results file, not only the ones collected
# in this particular invocation.
$csvRows = @()
if (Test-Path $csvPath) {
    $csvRows = @(Import-Csv -Path $csvPath | ForEach-Object {
        [PSCustomObject]@{
            ValueHex       = $_.ValueHex
            ValueDec       = [int]$_.ValueDec
            Label          = $_.Label
            Run            = [int]$_.Run
            MeanIntervalUs = [double]$_.MeanIntervalUs
            JitterUs       = [double]$_.JitterUs
            P99Us          = [double]$_.P99Us
            OutlierCount   = [int]$_.OutlierCount
        }
    })
}

if ($csvRows.Count -eq 0) {
    Write-Host "No results collected." -ForegroundColor Yellow
    return
}

# Step 1 - aggregate per value: one avg_jitter/avg_p99/etc pair per candidate value (12 values
# -> 12 pairs), plus the raw run-to-run consistency signal (stdev of that value's own per-run
# jitter, 0 when only one run was collected for it).
$perValue = @($csvRows | Group-Object ValueDec | ForEach-Object {
    $g = $_.Group
    [PSCustomObject]@{
        ValueHex         = $g[0].ValueHex
        ValueDec         = [int]$_.Name
        Label            = $g[0].Label
        RunsCounted      = $g.Count
        AvgMeanUs        = ($g.MeanIntervalUs | Measure-Object -Average).Average
        AvgJitterUs      = ($g.JitterUs | Measure-Object -Average).Average
        AvgP99Us         = ($g.P99Us | Measure-Object -Average).Average
        AvgOutliers      = ($g.OutlierCount | Measure-Object -Average).Average
        JitterRunStdevUs = Get-PopulationStdev -Values $g.JitterUs
    }
})

# Step 2 - normalize each metric across the tested candidates (min-max, 0-1) before combining,
# so P99's naturally larger absolute scale can't drown out jitter in the composite score.
$minJitter = ($perValue.AvgJitterUs | Measure-Object -Minimum).Minimum
$maxJitter = ($perValue.AvgJitterUs | Measure-Object -Maximum).Maximum
$minP99 = ($perValue.AvgP99Us | Measure-Object -Minimum).Minimum
$maxP99 = ($perValue.AvgP99Us | Measure-Object -Maximum).Maximum
$minCons = ($perValue.JitterRunStdevUs | Measure-Object -Minimum).Minimum
$maxCons = ($perValue.JitterRunStdevUs | Measure-Object -Maximum).Maximum

# Step 3/4 - composite score: weighted blend of normalized jitter + P99 + a consistency penalty
# (a value whose jitter swings a lot between repeat runs is less trustworthy even if its average
# looks good). Weights are auto-normalized to sum to 1, so WpsScore always stays in 0-1 - lowest
# score wins.
$weightSum = $JitterWeight + $P99Weight + $ConsistencyWeight
if ($weightSum -le 0) { $weightSum = 1 }

$summary = $perValue | ForEach-Object {
    $normJitter = Get-MinMaxNorm -Value $_.AvgJitterUs -Min $minJitter -Max $maxJitter
    $normP99 = Get-MinMaxNorm -Value $_.AvgP99Us -Min $minP99 -Max $maxP99
    $normConsistency = Get-MinMaxNorm -Value $_.JitterRunStdevUs -Min $minCons -Max $maxCons
    $score = (($JitterWeight * $normJitter) + ($P99Weight * $normP99) + ($ConsistencyWeight * $normConsistency)) / $weightSum

    [PSCustomObject]@{
        ValueHex           = $_.ValueHex
        ValueDec           = $_.ValueDec
        Label              = $_.Label
        RunsCounted        = $_.RunsCounted
        AvgMeanUs          = [Math]::Round($_.AvgMeanUs, 3)
        AvgJitterUs        = [Math]::Round($_.AvgJitterUs, 3)
        AvgP99Us           = [Math]::Round($_.AvgP99Us, 3)
        AvgOutliers        = [Math]::Round($_.AvgOutliers, 2)
        ConsistencyPenalty = [Math]::Round($normConsistency, 4)
        WpsScore           = [Math]::Round($score, 4)
    }
} | Sort-Object WpsScore

Write-Host ""
Write-Host "=== Results (best -> worst by WPS Score, 0-1, lower is better) ===" -ForegroundColor Cyan
Write-Host "WpsScore = normalized-weighted blend of jitter + P99 + run-to-run consistency, relative to the $($perValue.Count) value(s) tested this run (weights: Jitter=$JitterWeight, P99=$P99Weight, Consistency=$ConsistencyWeight, auto-normalized to sum to 1)." -ForegroundColor DarkGray
Write-Host "Scores are only comparable within this batch/run - re-running with a different candidate set or machine will rescale them." -ForegroundColor DarkGray
$summary | Format-Table ValueHex, Label, RunsCounted, AvgMeanUs, AvgJitterUs, AvgP99Us, AvgOutliers, ConsistencyPenalty, WpsScore -AutoSize | Out-String | Write-Host

$best = $summary | Select-Object -First 1
Write-Host "Recommended value: $($best.ValueHex) ($($best.Label)) - WPS Score $($best.WpsScore)" -ForegroundColor Green
Write-Host "This is a recommendation based on THIS run's background-load profile and hardware - review the full table above, results can vary with a different workload mix." -ForegroundColor Yellow
Write-Host ""
Write-Host "Full per-run data: $csvPath"
Write-Host "Audit log        : $LogPath"

Write-Log "=== WPS Bench run finished. Recommended: $($best.ValueHex) ($($best.Label)), WpsScore=$($best.WpsScore) ==="

# ---------------------------------------------------------------------------
# 12. Apply-best-value prompt
# ---------------------------------------------------------------------------
# The original value has already been restored above (Restore-OriginalValue ran in the main
# loop's `finally`), so at this point the registry is back to whatever it was before this run -
# nothing risky is left active while we wait on the user's answer.

Write-Host ""
if ($script:CancelRequested) {
    Write-Host "Run was cancelled - skipping the apply prompt. Original value $RegName = $(if ($OriginalValuePresent) { $OriginalValue } else { '<not present>' }) remains in effect." -ForegroundColor Yellow
}
else {
    $applyInputRedirected = $false
    try { $applyInputRedirected = [Console]::IsInputRedirected } catch { }

    if ($applyInputRedirected) {
        Write-Host "Input isn't interactive - leaving the original value in place. Re-run interactively (or set it manually) to apply $($best.ValueHex)." -ForegroundColor Yellow
    }
    else {
        $applyAns = Read-Host "Best value found: $($best.ValueHex) ($($best.Label)). Apply this now? (Y/N)"
        if ($applyAns -match '^(?i:y(es)?)$') {
            try {
                Set-WpsValue -Value $best.ValueDec
                Write-Host "Applied $($best.ValueHex) ($($best.Label)) - this is now the persistent $RegName setting (not reverted on exit)." -ForegroundColor Green
                Write-Log "User confirmed apply: $RegName set to $($best.ValueHex) ($($best.Label)) as the new persistent setting."
            }
            catch {
                Write-Error "Failed to apply $($best.ValueHex): $_"
                Write-Log "ERROR applying recommended value: $_"
            }
        }
        else {
            Write-Host "Keeping the original value ($RegName = $(if ($OriginalValuePresent) { $OriginalValue } else { '<not present>' }))." -ForegroundColor Cyan
            Write-Log "User declined to apply the recommended value; original value left in place."
        }
    }
}
