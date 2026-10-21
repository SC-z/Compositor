# Legacy LUT color spaces (format 16)

These settings were exposed in the format-16 build. The current PhotoCraft-compatible preset UI does not offer them for new LUTs. Saved values remain supported so existing projects keep their rendering; choosing another LUT resets the color conversion while retaining interpolation and dither. See [the current LUT workflow](lut-photocraft-parity.md).

The rendering engine applies a 3D `.cube` table as an editable adjustment layer. It does not infer a color space from a filename or `TITLE`: these are labels, not a color specification.

## Settings

- **Interpolation:** Trilinear or Tetrahedral. Trilinear remains the default for compatibility with existing projects.
- **LUT input space:** the gamut and encoding the LUT expects. For ordinary photos, Compositor decodes its encoded sRGB working values, converts linear RGB to the selected gamut, and applies the selected encoding before sampling the LUT.
- **LUT output space:** the gamut and encoding produced by the LUT. Compositor decodes this output, converts linear RGB back to sRGB primaries, and encodes sRGB for its existing compositing pipeline. This is not the file export profile.
- **Image is already in LUT input space:** bypasses the pre-LUT conversion and reads the current RGB numbers directly. Use only for an image whose imported pixel values actually retain the LUT's expected encoding. This does not undo an earlier image-profile conversion, reconstruct clipped highlights, decode a video file, or detect camera metadata.

Defaults are sRGB input, sRGB output, Trilinear, with the bypass off. Existing projects without settings retain their previous rendering path. Settings belong to the adjustment layer; they survive saving, undo/redo and reopening. Selecting another file in the same preview keeps the settings. Current Preset restores the original table and settings; Cancel restores the original layer.

For an ordinary JPEG/HEIC photo with an Apple Log 2 LUT, leave the bypass off and choose Apple Log 2 / Apple Wide Gamut as input. Choose output according to the LUT author's specification. If that specification is missing, Rec.709 Gamma 2.2, Gamma 2.4, BT.709 encoding and sRGB cannot be treated as interchangeable. When a LUT does not declare its output space, no output setting can be assumed to reproduce its author's intent.

Applying a camera Log LUT to an ordinary photo converts the available photo colors into that LUT's input encoding. It cannot recover the original scene's dynamic range or reverse the camera's tone mapping. Genuine Log frames require preserved encoded samples; do not enable the bypass on a normal photo merely because the LUT filename contains “Log”.

## Supported definitions

All supported gamuts use D65. Matrices are derived from xy primaries, with no white-point adaptation needed between these spaces.

| Space | Transfer | Primaries |
| --- | --- | --- |
| sRGB | IEC sRGB curve | BT.709 |
| Linear sRGB | Linear | BT.709 |
| Rec.709 / Gamma 2.2 | Power 2.2 | BT.709 |
| Rec.709 / Gamma 2.4 | Power 2.4 | BT.709 |
| Rec.709 / BT.709 curve | BT.709 OETF/inverse | BT.709 |
| Apple Log | Apple Log curve | BT.2020 |
| Apple Log 2 | Apple Log curve | Apple Wide Gamut |
| F-Log2 | Fujifilm F-Log2 curve | F-Gamut (BT.2020) |
| V-Log | Panasonic V-Log curve | V-Gamut |

Rec.709 Gamma 2.4 is a pure power function, not a display-specific BT.1886 model with measured black level. Video-range normalization, HDR output tone mapping, automatic camera exposure and automatic gamut compression are outside this setting. Table coordinates clamp at the declared `DOMAIN_MIN`/`DOMAIN_MAX`; floating-point output can exceed 0–1 until the destination image format clips it.

The original default keeps its existing Core Image/16-bit C path. Other settings use one Core Image kernel for the canvas and exported images, with explicit table texel reads for selectable interpolation. The table is stored as Float32 RGBA. The kernel is compiled at runtime using the Core Image kernel language to support the macOS 15 local build without the Xcode Metal compiler. It must be migrated if a future deployment target removes that API.

## References and checks

- [PhotoCraft LUT interpolation and color lookup](https://github.com/storytold/photocraft/blob/b097800e78405aeb2068113988898f991e707eb4/crates/compose/src/adjust.rs#L731): trilinear/tetrahedral behavior; no PhotoCraft runtime dependency.
- [OpenColorIO Apple camera definitions](https://github.com/AcademySoftwareFoundation/OpenColorIO/blob/main/src/OpenColorIO/transforms/builtins/AppleCameras.cpp) and [Apple Log 2 transform derivation](https://opencolorio.readthedocs.io/projects/config-aces/en/latest/_modules/opencolorio_config_aces/clf/transforms/apple/generate.html): Apple Log constants, shared Apple Log/Log 2 transfer, Apple Wide Gamut primaries.
- [Fujifilm F-Log2 data sheet, version 1.1](https://dl.fujifilm-x.com/support/lut/F-Log2_DataSheet_E_Ver.1.1.pdf): curve constants and F-Gamut primaries.
- [Panasonic V-Log/V-Gamut reference manual](https://pro-av.panasonic.net/en/cinema_camera_varicam_eva/support/pdf/VARICAM_V-Log_V-Gamut.pdf): curve constants and V-Gamut primaries.

`LUTColorTests` checks all six tetrahedron orderings, published 18% gray reference values, gamut-sensitive colors, encode/decode round trips, bypass, alpha, 16-bit precision, persistence and cancellation. The optional `COMPOSITOR_LUT_REFERENCE` JSON fixture checks externally supplied LUTs against independent numeric results without bundling or redistributing third-party LUT files.
