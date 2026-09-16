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

### Compatibility text map

Debug builds can emit bounded `InkSignPdfMap` records while preparing the
compatibility-text overlay:

```powershell
adb logcat -s InkSignPdfMap:D '*:S'
```

The map reports geometry selection and final disposition without logging
document text. It is diagnostic only and must not change text selection,
shaping, merging, or rendering.

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

