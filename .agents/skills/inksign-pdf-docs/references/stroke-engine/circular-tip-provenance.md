# Startup envelope evaluator provenance

The startup-envelope evaluator in `cpp/circular/StartupEnvelope.cpp` is a
diagnostic-only feasibility and replay aid. It is not linked into production
stroke geometry and does not construct or repair production paths.

`cpp/modeling/SignatureBrushTipModeler.*` adopts the separation between a brush
definition and a stateful tip modeler, with fixed and volatile upstream output ranges.
Its fixed frontier requires both stable modeled input and styling that future
input cannot change. The single circular tip corresponds to `BrushTip` defaults
of unit scale, full corner rounding, no slant/pinch/rotation and zero particle
gaps. Production contours come directly from the upstream `BrushTipExtruder`
output; no custom circular geometry backend is compiled. The ordinary width
recurrence is repository-owned and is documented in [styling.md](styling.md);
it is not presented as a Google Ink brush setting or binary clone.

The local Google Ink snapshot has no verified repository revision. The following
SHA-256 hashes identify the inspected sources and license:

| Local reference                                      | SHA-256                                                            |
| ---------------------------------------------------- | ------------------------------------------------------------------ |
| `.codex/ink-main/LICENSE`                            | `CFC7749B96F63BD31C3C42B5C471BF756814053E847C10F3EB003417BC523D30` |
| `ink/geometry/internal/circle.h`                     | `1B8A1FF61E4AF077485725417B68F0403943DE056B29B29B0B4B26F053818E14` |
| `ink/geometry/internal/circle.cc`                    | `B3B5CC3DD0AC1819CB2AAD7BD15FEB440D5EE119B404EED6ED73C6433B304B4B` |
| `ink/strokes/internal/circular_extrusion_helpers.h`  | `39CF88942392B498CEC898243F883CF7FC61EAB845ADD91656EAC7BAB5E8CB05` |
| `ink/strokes/internal/circular_extrusion_helpers.cc` | `00A569D60ED247E8410597218BB5192E5167AEA02A57252CC52DB9E282FF665C` |
| `ink/brush/brush_tip.h`                              | `6C6D7BD823A435C3E6882F9015C51B0ED61CAC9E223AA01254CF0636221753BD` |
| `ink/strokes/internal/brush_tip_modeler.h`           | `7F04FF1637AD143252C333ECAE8D98A7441CFE0E20B438F59BD0FE9B71601058` |
| `ink/strokes/internal/brush_tip_modeler.cc`          | `E03C040416971EF0B9DDA6A11984D7D32AC5FA367DD9C91915BC4C50F0EF80D5` |
| `ink/strokes/internal/brush_tip_modeler_helpers.cc`  | `CC39808DF322886F7F27C3BD89ECEB0D0911D12A1C89241499DB7F8EDDD99BBE` |

The adapted material is covered by the Apache License, Version 2.0, in the
Google Ink `LICENSE` file. No Google Ink source files are compiled into this
repository target.

