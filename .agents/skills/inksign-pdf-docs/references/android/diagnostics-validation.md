# Android diagnostics and validation

## Diagnostics and validation

- Diagnostics observe state; they do not own stroke state. Perfetto covers
  input, JNI/C++, geometry, frame transport, prediction, front-buffer work,
  lifecycle, and FrameTimeline data.
- Front-buffer callback/rendering durations measure worker work, not physical
  display scanout. Logcat is for renderer and contract failures.
- JVM tests cover Android surface, composition, viewport, history, export, and
  diagnostics. Connected instrumentation covers lifecycle, callback ordering,
  prediction, composition, and device rendering. Use
  `tools\test-android.ps1 -Mode connected` to target the first online `adb
  devices` entry; pass `-AllDevices` to run on every connected device.
- Use a profileable real-device trace before changing JNI copies, batching,
  buffer reuse, or front-buffer ownership. Keep JNI, C++, frame-copy,
  allocation, input-batching, and missed-frame effects separate.
- Replay feeds validated debug records through production `StrokeEngine` and
  writes ignored artifacts under `diagnostics/`; recording and diagnostic
  scans are disabled during normal live strokes.
- Android debug CSV recordings are written beneath the configured native cache
  root as `android-stroke-*.csv`. They remain available for caller copy-out;
  debug startup scavenging removes stale recordings, while release builds do
  not classify or remove them.

### Compatibility text geometry map

Debug builds emit bounded, one-line `InkSignPdfMap` records while opening a PDF
and preparing the Android compatibility-text overlay. Capture them with:

```powershell
adb logcat -s InkSignPdfMap:D '*:S'
```

The records identify page text objects, page line rectangles and their source,
candidate UTF-16 ranges and code points, selected-content exactness, capped
source rectangles, line matches, final combined rectangles, vertical cluster
members and unions, preparation metrics, and the final disposition. They do
not log document text. Pages emit at most 256 candidate/content/line records
and 32 rectangles per logged candidate/content record; truncation is explicit.
The map is diagnostic only and must not change selection, merging, shaping, or
rendering behavior.

## Unified trace report

```powershell
python tools\analyze-trace.py diagnostics\traces\capture1.perfetto-trace
python tools\analyze-trace.py diagnostics\traces\capture1.perfetto-trace --format json
```

The analyzer loads the trace once and runs `tools\trace-analysis.sql`, which
returns normalized `section, metric, scope, value, unit` rows. Optional tracks
produce diagnostics or `NULL` metrics rather than invalidating the report.

- `native_timing` and `hot_paths` separate JNI, geometry stages, decoding,
  rendering, input dispatch, front-buffer updates, and prediction replacement.
- `frames` uses application FrameTimeline data; `cpu` uses application sched
  slices and separates main-thread from worker time.
- `allocation` reports GC count, total/p95/max pause, and duration-normalized
  rates. Heap-profile counts/bytes are `NULL` unless profiling is present;
  `diagnostics/allocation_profile_present` is the availability flag.
  Heap-profile data is native; `dalvik` slices do not provide Java allocation
  attribution.

## Trace comparison

```powershell
python tools\compare-traces.py baseline.json current.json
python tools\compare-traces.py baseline.json current.json --format json
```

Comparison keys are `(section, metric, scope)`. Duplicate keys and unit
changes fail; missing metrics are reported, never treated as zero. Deltas are
`current - baseline`; percentage deltas are unavailable for zero or
nonnumeric baselines. Optional geometry and serialized-byte gates are skipped
when their target metrics are unavailable.

Without replay, captures are approximate measurements. Keep device, app build,
warm-up, duration, and interaction pattern consistent as practical. Compare
averages, percentages, and rates before raw counts, and do not treat one pair
as causal proof.

## Device trace capture

```powershell
tools\capture-trace.ps1 -Duration 20 -Device <adb-device>
tools\capture-trace.ps1 -Duration 20 -Device <adb-device> -Format markdown
tools\capture-trace.ps1 -Duration 20 -Device <adb-device> -Format both
tools\capture-trace.ps1 -Duration 20 -Device <adb-device> -ProfileAllocations -Format json
```

The app must already be running; the wrapper does not install or launch it.
JSON is the default report format; `-Format markdown` produces only
human-readable Markdown, and `-Format both` produces both reports. Without
`-Output`, it writes timestamped files under
`diagnostics\traces\`. Use `-StartEmulator` and optionally `-AvdName` when no
device is connected. Use `-Force` to overwrite an existing output set.

`-ProfileAllocations` requests native heap profiling through
`android.heapprofd`. If no samples are emitted, the capture succeeds with
`allocation_profile=unavailable`. The script pulls, validates, analyzes, and
cleans up the remote temporary trace automatically. It also checks duration
and required geometry spans; progress heartbeats keep long capture/analysis
steps observable.

## Geometry contract gate

Run `tools\check-geometry-contract.ps1`. It validates built-in replay fixtures
against `tools\testdata\geometry-contract-manifest.json` using the replay
CLI's `--invariants-only --summary` output. The contract covers outline
segments, maximum chord, contours, serialized frame bytes, and transport hash.
Normal validation does not rewrite the manifest; use `-GenerateBaseline` with a
separate output path to create a review candidate.

## Changed-area verification

Run `npm run verify:change`, or inspect its plan with
`tools\verify-change.ps1 -DryRun`. Checks are deduplicated, run in fixed order,
and stop at the first failure while preserving its status. The dispatcher does
not modify the working tree; trace analysis uses the newest ignored
`diagnostics/**/*.perfetto-trace` when available.
