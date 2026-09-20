# Google Ink input-model adaptation

The implementation in `CurrentInkInputModeler.{hpp,cpp}` is an intentionally
small adaptation of Google Ink's sliding-window input model and its
stable/unstable input-model contract. It does not copy Google Ink's brush,
geometry, or storage layers.

Source: [Google Ink](https://github.com/google/ink), paths under
`ink/strokes/internal/`.

The inspected source snapshot has no Git metadata, so a Git revision is
unavailable. The following SHA-256 file hashes pin the source snapshot used
for this adaptation:

```text
ink/strokes/internal/stroke_input_modeler.h 97f02b0c31891163052543a0b529c444652c4d6ea9d2075e273330b648416163
ink/strokes/internal/stroke_input_modeler.cc 405c908d6fa27d8ef9a87184e718439eaac1468eeee779c6713199fcb10c4e53
ink/strokes/internal/stroke_input_modeler/input_model_impl.h ff91cc36504d26c39c66a7637fb1b7b7bfabf9e7e797ae9d0c5ca56829a7a460
ink/strokes/internal/stroke_input_modeler/passthrough_input_modeler.h 09abddc39250a36ad246822e939751d43052a5fcb55dcb7a81083ebeb590c858
ink/strokes/internal/stroke_input_modeler/passthrough_input_modeler.cc 2828ad6fc318423babcba37622830161d80ec379325f5537c0476e77e8591e7d
ink/strokes/internal/stroke_input_modeler/sliding_window_input_modeler.h d9121088b6390192183fd03470fefc3736d0e81e9c9caae376616d5d90997785
ink/strokes/internal/stroke_input_modeler/sliding_window_input_modeler.cc 566daf000a518eabfaa5bdf164a5a3cb2c12ad16095c3179e086ce6976f8ae17
ink/strokes/internal/modeled_stroke_input.h 649a9ec854dffbe2e10969ebc88b2766023a25791893b8e36ae4be9e664441d4
ink/strokes/internal/modeled_stroke_input.cc fcdc049f82db20477cffe72edbbc8532eb087fcde3cafb63d47420e7410b3fcc
```

The adapted files are new repository code under the Apache 2.0 license. Local
adaptations are: page-space `Vec2` and double-precision seconds replace Ink
geometry/time types; the model accepts the repository's raw input spans;
time-weighted trapezoidal averaging, bounded 180 Hz upsampling, position-
epsilon filtering, and centered sliding-window derivatives are retained;
velocity is derived from modeled position and acceleration from modeled
velocity; modeled state is mapped to `CenterlineState`; and prediction is a
replaceable raw suffix modeled from scratch without mutating real state.
Forward and lateral acceleration are projections of the finite acceleration
onto normalized velocity and its counterclockwise orthogonal, respectively.
The listed hashes pin the Google source snapshot used for this adaptation.
