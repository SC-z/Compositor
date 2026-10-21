# LUT capability parity with PhotoCraft

Reference: PhotoCraft commit [`04d0212c7a1006b00f6ec9dd144affc98f8e7d83`](https://github.com/storytold/photocraft/tree/04d0212c7a1006b00f6ec9dd144affc98f8e7d83). This port covers LUT UI, import, rendering, presets and LUT export, using Compositor's existing project system. PSD export/round-trip, smart objects/filters and CLI automation are not included.

| Capability | Compositor implementation | Reference |
| --- | --- | --- |
| Load / None / eight built-ins | Native 3D LUT picker; built-in formulas and 33³ sampling match | `ui-egui/src/adjust_ui.rs`, `cms/src/lutfile.rs` |
| Preview cycling | Wheel over picker or up/down keys; native menu supports keyboard type-ahead | `ui-egui/src/adjust_ui.rs` |
| Interpolation | Trilinear default, selectable Tetrahedral, explicit Float32 table reads | `compose/src/adjust.rs::lut3d_sample` |
| Dither | Off by default; 4×4 Bayer, same offset on RGB, ±½ an 8-bit step, output clamped to 0–1 | `compose/src/adjust.rs::bayer4` |
| 3D `.cube` | Red-fastest, 2–129 grid; default domain required for new imports | `cms/src/lutfile.rs`, `engine/src/adjust_cmds.rs` |
| 1D `.cube` | Resampled to 33³, input range baked in, output clamped | `cms/src/lutfile.rs::parse_cube` |
| `.3dl` | Blue-fastest reordered; output scale inferred from 1/1023/4095/16383/65535 or maximum; input shaper assumed linear | `cms/src/lutfile.rs::parse_3dl` |
| `.look` | XML size/title/data; little-endian float hex, RGB or RGBA (alpha discarded) | `cms/src/lutfile.rs::parse_look` |
| Adjustment layer | Editable table, selection converted to a mask on creation, mask/opacity/blend controls, project embedding | Existing Compositor layers |
| Direct pixel application | Preview, selection, alpha and 16-bit preservation, cancel and undo; targeted layer masks use Rec.601 grayscale | Image menu, existing Compositor image system |
| Export LUT | `.cube`, 2–129 default 33, title, all/selected scope, ordered layer IDs at the engine boundary | `engine/src/file_cmds.rs::color_lookup_tables` |
| Export layer semantics | Visible top-level adjustments, document order, opacity/blend; spatial masks and clipping stripped | `engine/src/file_cmds.rs::bake_cube_layers` |

## Host adaptations

This is capability and LUT-algorithm parity, not a replacement of Compositor's compositing engine. PhotoCraft also supports document modes/profiles and adjustment kinds that Compositor does not have. LUT export uses Compositor's existing adjustments and RGB working pipeline; it does not promise identical results for an entire PhotoCraft project. A 3D LUT also cannot represent arbitrary spatial edits. Export rejects Gaussian Blur, Motion Blur, Grain and Add Noise layers in the chosen scope, naming the layers to hide or omit.

The native floating panel retains Compositor's Preview / OK / Cancel transaction: repeated previews become one undo operation when confirmed. PhotoCraft's properties panel commits changes immediately and groups wheel changes after a delay. The panel uses Compositor's existing project and undo system. The preset library's earlier folder/search UI and color-space controls are not offered in this baseline.

Existing format-15/16 projects retain their table domain, sampling path and optional color conversions. Selecting a different preset changes that layer to the new baseline; cancellation restores the original. Settings that are not changed (interpolation/dither) carry to the new LUT. File parsing preserves resource limits and rejects malformed/non-finite payloads more strictly than PhotoCraft's permissive parser. No filename/comment-based color-space inference is performed.

The LUT kernel is shared by the canvas and image export. It uses Core Image's runtime kernel compiler, which is available on the macOS 15 target; a future target that removes it requires migrating the same math to Metal. Packed 2D table textures keep even 129³ LUTs below the hardware texture-side limit.

## Verification

`LUTParityTests` covers all three file formats, 1D range resampling, invalid files, eight built-in reference colors, 129³ rendering, exact Bayer offsets, None, old settings, project version enforcement, pixel application/cancel/undo, and LUT export scope/order/opacity/mask behavior. `LUTColorTests` retains interpolation ordering, 16-bit precision/alpha and earlier color conversions. An optional local reference fixture checks external LUTs against independent numeric results. Third-party LUTs, local paths and generated reference data are not distributed.

`LUTParityTests` also verifies committing with Preview off, cancellation of hidden rendering, selection masks, positioned mask edits and undo, grayscale lookup on adjustment-layer masks, and rejection of spatial effects during LUT export.

`GPUCanvasTests` compares LUT results on the GPU and normal canvas, including dither. `PresetTests` covers asynchronous loading, stale-result rejection, one undo transaction, invalid-file recovery and native panel layout.

The implementation ports PhotoCraft's LUT format/built-in/interpolation/dither logic under its MIT license. The original copyright and license are in [`Compositor/Resources/PhotoCraft-LICENSE.txt`](../Compositor/Resources/PhotoCraft-LICENSE.txt), included in packaged apps.
