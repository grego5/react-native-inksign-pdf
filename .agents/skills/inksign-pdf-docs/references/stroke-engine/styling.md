# Width and terminal styling

- `SignatureBrushTipModeler` owns an immutable `SignatureStrokeStyle` definition
  for one continuous signature brush. Width bounds and display scale are
  frozen; the owner separately observes real terminal speed. Color remains uniform
  in the existing platform rendering path.
- The brush owner contains `VelocityWidthModel`, initial/seam width snapshots,
  the tip fixed frontier, the authoritative width-derived `ModeledPoint`
  sequence, and reusable real/prediction materialization scratch. It returns
  borrowed modeled, fixed, and volatile upstream tip spans for synchronous
  consumption by the engine.
  Those views last until the next brush modeling operation or reset; no second
  persistent centerline or contour collection is introduced.
- Each materialization emits upstream `BrushTipState` values with equal width
  and height, full rounding, neutral rotation/slant/pinch, and no particles.
- `VelocityWidthModel` owns the current page-space radius and causal distance
  response inside that owner. Pressure is metadata and does not control width.
- Public widths are diameters in page units after platform conversion.
- Defaults: `minWidth = 2.0`, `maxWidth = 4.0`, and `smoothing = 0.4`. Moving
  strokes use an intrinsic rounded head from their first modeled tip; there is
  no independently sized or switchable production start-cap object.
- Speed is normalized independently of configured width: modeled page-space
  velocity is converted through the stroke-frozen display scale and divided by
  a fixed `960` logical-display-units/second reference. The same pre-lift moving
  speed controls terminal attenuation and tail length. The maximum tail budget
  is `48.0` logical display units, converted once to page units when the stroke
  style is created; the actual tail distance is that fixed page-space budget
  multiplied by the current response amount.
- Ordinary radius targets use the unbounded effective display speed. For each
  modeled sample after initialization, the previous page-space velocity and
  current page-space velocity produce `turnFactor` using the exact periodic
  cosine recurrence; zero or non-positive velocity on either side leaves that
  factor at `1.0`. `effectiveSpeedDisplay` is current velocity magnitude times
  the frozen display scale and `turnFactor`. With
  `x = effectiveSpeedDisplay / 960`, the target is
  `minRadius + exp(-4 * exp(-4 * x)) * (maxRadius - minRadius)`; the target is
  not clamped at `x = 1`.
- Moving sample 0 starts at `minimumRadius`, even when its target is already
  wide. Each subsequent modeled state applies the exponential distance response
  `alpha = -expm1(-segmentDistancePage / responseDistancePage)` to the target.
  Widening uses `responseDistancePage = 2 * maximumRadius * 6`; when the target
  is below the current radius, contraction uses `2 * maximumRadius * 2`. Both
  distances come from the stroke-frozen page-space brush diameter. All previous
  position, velocity, and timestamp fields are updated after every sample,
  including equal-time and zero-distance samples. Zero travel therefore has no
  width effect; equal bounds remain constant. Stationary dots retain their
  independent path. This width policy does not guarantee a neck-free silhouette.
- Prediction copies the complete recurrence state and never contributes width
  state to the real stroke. Stable seam checkpoints retain the radius,
  previous modeled position and velocity, and previous timestamp needed to
  reconstruct a volatile suffix.
- Invalid, zero, and stationary terminal speeds do not replace the last valid
  moving speed for terminal taper distance; this retention belongs to the
  terminal-taper owner and is not part of ordinary modeled width response.
- Moving strokes use a continuous terminal response. For the last valid moving
  speed in logical display units/second, `x = speed / 960` and
  `amount = -expm1(-x)`. The mutable tail length is the frozen page-space
  maximum tail budget times `amount`. Within that tail,
  backward distance `d` is normalized as `u = d / tailLength`. The influence is
  `cubic + amount * (linear - cubic)`, where `cubic = 1 - (3u^2 - 2u^3)` and
  `linear = 1 - u`; it is `1` at the endpoint and `0` at the body boundary.
  Thus low speed uses cubic smoothing and higher speed blends progressively
  toward an even linear shrink. Each ordinary radius is multiplied by
  `1 - amount * influence`, clamped to a small positive terminal radius of
  `0.25 * minimumRadius`. Thus slow lift-off keeps the actual terminal width,
  while faster lift-off progressively creates a longer, finer rounded tail
  without reaching a cusp or changing ordinary widening and contraction.
  Invalid, zero, and stationary terminal inputs do not replace the last valid
  moving speed, and prediction does not alter the real terminal response.
- Moving tapered strokes close through terminal centerline contact with a small
  rounded point. Non-tapered strokes use round/flat cap policy; dots retain dot
  geometry.
