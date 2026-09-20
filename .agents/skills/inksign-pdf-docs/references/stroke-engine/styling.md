# Stroke styling

`SignatureBrushTipModeler` owns the immutable style for one continuous stroke.
The width bounds and display scale are fixed when the stroke begins; color is
handled by the platform renderer.

## Width

- Public widths are diameters in page units after platform conversion. Defaults
  are `minWidth = 2.0`, `maxWidth = 4.0`, and `smoothing = 0.4`.
- `VelocityWidthModel` converts movement speed into a radius and applies the
  change over traveled distance. A moving stroke starts at the minimum width,
  then widens or contracts smoothly toward its speed-dependent target.
- Pressure is recorded as input metadata and does not control width. Stationary
  dots use their own geometry path.
- Each materialized brush tip is fully round with equal width and height. The
  moving head is intrinsic to the first tip; there is no separate configurable
  start-cap object.

## Prediction and terminal taper

- Prediction copies the modeling state and cannot modify the real stroke's
  width or terminal behavior. Modeled and predicted spans are borrowed scratch
  views, not a second persistent stroke representation.
- The terminal taper uses the last valid moving speed before lift-off. Invalid,
  zero, or stationary terminal samples do not replace it.
- Faster lift-off produces a longer, finer rounded tail; slower lift-off keeps
  more of the body width. The taper stays positive and avoids a cusp. Moving
  strokes close through centerline contact; dots and non-tapered strokes keep
  their dedicated cap/point geometry.
