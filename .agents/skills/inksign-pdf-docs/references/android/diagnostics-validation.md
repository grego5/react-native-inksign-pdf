# Android diagnostics and validation

## Diagnostics and validation

- Diagnostics observe native state; they do not own stroke or presentation
  state. Perfetto covers input, JNI/C++, geometry, frame transport, prediction,
  front-buffer work, lifecycle, and FrameTimeline data.
- JVM tests cover Android composition, viewport, history, export, and
  diagnostics. Connected tests cover lifecycle, callbacks, prediction, and
  device rendering. Use `tools\test-android.ps1 -Mode connected`.
- Use a profileable real-device trace before changing JNI copies, batching,
  buffer reuse, or front-buffer ownership. Treat trace results as measurements,
  not causal proof from one capture.
- Replay and debug recordings are diagnostic artifacts only. Normal release
  rendering does not record them; Android debug recordings use the configured
  native cache root and are removed only by debug cleanup.

## Tile dispatch measurements

```powershell
tools\test-android.ps1 -Mode connected -TileBenchmark
python tools\analyze-tile-dispatch.py diagnostics\tile-dispatch-report.json
```

- The opt-in harness uses real PDFium, a non-debuggable release APK, hardware
  drawing, and generated vector/image PDFs. Normal test runs exclude it.
- Fixed 3× fit zoom and scheduled pan/reversal produce repeatable demand.
  Separate fresh-session/tile-cache and warm-cache samples; exclude warmup.
- JSON reports are saved to device Downloads as `inksign-tile-dispatch-*.json`;
  pull the report locally before analysis. Metrics separate rendering, worker
  queueing, UI admission observation, and draw coverage. Continuation gaps
  exclude viewport-triggered submissions after idle intervals.
- Idle memory snapshots compare native allocations and process PSS before open,
  after prefetch drains, and after close; they do not measure peak memory.
- This isolates detailed tiles without React, base rasters, or ink. Draw timings
  describe CPU submission; use an app trace for full-pipeline frame costs.

## Trace reports

Analyze and compare traces with:

```powershell
python tools\analyze-trace.py diagnostics\traces\capture1.perfetto-trace
python tools\compare-traces.py baseline.json current.json
```

Reports normalize native timing, frames, CPU, and allocation metrics. Missing
optional tracks remain unavailable rather than becoming zero. Keep device,
build, warm-up, duration, and interaction pattern consistent when comparing
captures; a single pair is not causal proof.

## Device and contract checks

Capture a running app with:

```powershell
tools\capture-trace.ps1 -Duration 20 -Device <adb-device>
```

Use `-ProfileAllocations` when allocation data is required. Run
`tools\check-geometry-contract.ps1` for the built-in replay/geometry gate and
`npm run verify:change` for changed-area verification. These checks do not
rewrite the working tree unless an explicit baseline output is requested.
