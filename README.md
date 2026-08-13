# WPS Bench — Win32PrioritySeparation Benchmark Tool

WPS Bench empirically determines the best `Win32PrioritySeparation` registry value for **this
machine** by running a synthetic CPU-scheduling benchmark against each candidate value and
measuring foreground-thread timing consistency while background load competes for the CPU.
Fully self-contained — no games, no PresentMon, no third-party binaries.

## Requirements

- Windows, PowerShell 5.1+ or 7+.
- Administrator rights (the tool will relaunch itself elevated via a UAC prompt if it isn't
  already running elevated).
- A DirectX 11 capable GPU for the (optional, on by default) GPU load generator — standard
  `cs_5_0` compute, no Resizable BAR or advanced feature-level requirements. If no compatible
  GPU/driver is present, the tool detects this automatically, warns once, and continues with
  CPU-only background load for the rest of the run; pass `-GpuLoad Off` to skip it outright.

## Usage

```powershell
# Full default sweep: all 12 canonical values, 5s per run. If -Runs is omitted you'll be
# prompted interactively for how many times to test each value (default 5).
.\WPS-Bench.ps1

# Explicit values / runs / duration, matching the build spec's example (skips the Runs prompt)
.\WPS-Bench.ps1 -Values 0x14,0x15,0x16,0x18,0x19,0x1A,0x24,0x25,0x26,0x28,0x29,0x2A -Runs 5 -DurationSec 5

# Resume an interrupted sweep (continues WPS_Bench_Results.csv in this folder instead of
# deleting it and starting over)
.\WPS-Bench.ps1 -Resume

# Heavier concurrent GPU load (simulates a more demanding game); Off skips the GPU thread
# entirely and falls back to the original CPU-only background load
.\WPS-Bench.ps1 -GpuLoad Heavy
```

Run `Get-Help .\WPS-Bench.ps1 -Full` for every parameter (background thread count, foreground
process/thread priority, outlier/variance thresholds, WPS Score weights, output directory, etc).

## What it does

1. If `-Runs` wasn't passed on the command line, prompts interactively: *"How many times do
   you want to test each value? (default: 5)"* — re-prompts on invalid input, warns if you pick
   fewer than 3 (variance across runs won't be meaningfully measurable). The chosen count
   applies uniformly to every candidate value in the sweep.
2. Saves the current `Win32PrioritySeparation` value (or notes that it isn't set).
3. Unless `-Resume` is given, deletes any existing `WPS_Bench_Results.csv` from a previous run
   so old and new results never mix.
4. For each candidate value: writes it to the registry, then repeats the chosen number of times:
   - starts background CPU-bound worker threads (default = logical cores − 1) **and**, unless
     `-GpuLoad Off`, a dedicated GPU load thread (see below) — both start together,
   - waits 500ms for the scheduler to settle,
   - runs a precision C# timing loop on a high-priority foreground thread for 5 seconds,
     recording the actual delta of every tick,
   - stops the GPU load thread and the CPU background load, and computes mean interval, jitter
     (stdev), P99 latency spike, and outlier count for that run.
5. Flags any value whose results vary too much run-to-run (possible sign the scheduler change
   needs a restart to fully apply).
6. Restores the original registry value — always, including on Ctrl+C — *before* anything else
   happens next, so no test value is ever left active unconfirmed.
7. Writes every run's stats to `WPS_Bench_Results.csv` and prints a summary table sorted
   best → worst by a composite "WPS Score" — see [Scoring formula](#scoring-formula) below.
8. Asks: *"Best value found: 0xXX (Label). Apply this now? (Y/N)"* If you answer Y, that value
   is written to the registry as the new **persistent** setting (it will not be reverted when
   the tool exits). If you answer N — or just press Enter, or the run was cancelled, or the
   session isn't interactive — the original value from step 2 is left in place.

Every registry write is timestamped in `WPS_Bench_Log_<timestamp>.log` for audit purposes.

## GPU load generator

Runs at full intensity by default (`-GpuLoad Heavy`; also accepts `Light`/`Medium`/`Off` if you
want lighter or no GPU pressure). It generates **both** real
GPU compute occupancy and the CPU-side driver overhead (command submission, synchronization) that
continuous GPU work produces alongside a game's render/engine threads — that combination is what
should compete with the foreground timing thread for CPU scheduling time.

- Runs on its own dedicated thread, started and stopped alongside the CPU background load for
  every run.
- Self-contained: creates a D3D11 device directly via `D3D11CreateDevice`, compiles a small
  inline HLSL compute shader at runtime via `D3DCompile` (`cs_5_0` target), and drives it with
  `Dispatch()` calls — no PresentMon, no external stress tool, no managed D3D wrapper library.
  The COM vtable layouts used for this were cross-checked against the actual Microsoft D3D11
  headers before being wired in, and it self-tests on first start (dispatch → copy → map →
  verify non-trivial finite output) before ever being used for real load generation.
- Each dispatch (524,288 threads, 2,000 trig ops each) is calibrated to run for ~5ms of real GPU
  time — empirically measured, not guessed — so the GPU is actually kept busy, not just handed a
  dispatch call it finishes before the next one arrives.
- `Light`/`Medium`/`Heavy` control **duty cycle** — the idle gap inserted after each dispatch
  (~25% / ~50% / ~100% GPU-busy time respectively) — not the shader's own work, so the same
  calibrated workload scales cleanly from light background pressure up to sustained near-100%
  occupancy.
- Every iteration maps the result back with a blocking `Map()` call before deciding how long to
  idle. This is a deliberate real synchronization point, not just bookkeeping: without one, D3D11
  can batch/defer `Dispatch()` calls indefinitely instead of submitting them as they're issued,
  which decouples "when the tool calls Dispatch" from "when the GPU actually runs it" and silently
  breaks both the GPU-occupancy and duty-cycle timing. The blocking wait itself is also exactly
  the kind of CPU-side driver synchronization overhead a real game's render loop produces every
  frame.
- If GPU load fails to start (no compatible GPU/driver, compile failure, etc.), the tool warns
  once with the specific error and continues the rest of the run with CPU-only background load —
  it never aborts the benchmark over this.

## Scoring formula

For each candidate value, across all its runs:

1. **Aggregate**: average jitter and average P99 across that value's runs (12 values → 12
   averages, not 12×Runs individual numbers).
2. **Normalize**: min-max scale `avg_jitter` and `avg_p99` to 0–1 *relative to the other values
   tested in this run* — without this, P99's naturally larger absolute scale (hundreds/thousands
   of µs vs. jitter's usually-sub-µs range) would swamp jitter in the combined score.
3. **Consistency penalty**: a value whose jitter swings a lot between its own repeat runs is less
   trustworthy than one that's consistently good, even if its average looks fine — this is the
   stdev of that value's per-run jitter, also min-max normalized to 0–1 against the other values.
4. **Composite**: `WpsScore = (JitterWeight·norm_jitter + P99Weight·norm_p99 + ConsistencyWeight·norm_consistency) / (JitterWeight + P99Weight + ConsistencyWeight)`
   — defaults `0.5 / 0.5 / 0.2`, all configurable. Weights are auto-normalized to sum to 1, so
   **WpsScore always lands in 0–1, lowest = best**, regardless of what raw weights you pass.

The summary table shows `AvgJitterUs`, `AvgP99Us`, `ConsistencyPenalty`, and `WpsScore` per value
— never just the final number — so the recommendation is auditable. Because normalization is
relative to the batch, scores from different runs (different candidate sets, different machines)
are **not** comparable to each other — only within a single run's table.

## Important notes

- `Win32PrioritySeparation` changes **CPU scheduling policy only** — it does not raise clock
  speed, unlock more cores, or add processing capacity of any kind. It changes how the
  scheduler slices time between the foreground process and background processes.
- Results are specific to **this exact hardware and background-load profile**. The value that
  wins on a quiet desktop won't necessarily win once Discord, a browser, and OBS are all
  running — re-run WPS Bench with a background-load mix that resembles your real usage, and
  re-run it again after major hardware, driver, or OS changes.
- WPS Bench deliberately does not overclaim a single universal winner: always check the full
  per-value table, not just the top recommendation, since close scores may not be meaningfully
  different on your workload.
- The registry key is restored automatically when the tool exits, including on Ctrl+C. If the
  process is killed forcefully (e.g. via Task Manager `End Task`) the restore can't run — check
  `HKLM:\SYSTEM\CurrentControlSet\Control\PriorityControl\Win32PrioritySeparation` manually in
  that case; the log file records the original value that was saved at startup.

## Candidate value set

Only these 12 values (low 6 bits of the byte) produce distinct scheduler behavior; anything
else is redundant (values above `0x3F` wrap and re-read the same 6 bits), which is why these
are the default sweep:

| Hex  | Dec | Length | Type     | Boost                    |
|------|-----|--------|----------|---------------------------|
| 0x14 | 20  | Long   | Variable | None                      |
| 0x15 | 21  | Long   | Variable | Medium                    |
| 0x16 | 22  | Long   | Variable | High                      |
| 0x18 | 24  | Long   | Fixed    | None                      |
| 0x19 | 25  | Long   | Fixed    | Medium                    |
| 0x1A | 26  | Long   | Fixed    | High                      |
| 0x24 | 36  | Short  | Variable | None                      |
| 0x25 | 37  | Short  | Variable | Medium                    |
| 0x26 | 38  | Short  | Variable | High (Windows default)   |
| 0x28 | 40  | Short  | Fixed    | None                      |
| 0x29 | 41  | Short  | Fixed    | Medium                    |
| 0x2A | 42  | Short  | Fixed    | High                      |
