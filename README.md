# JXL Drop

JXL Drop is a local macOS app for converting images to JPEG XL. Drop several files and folders at once, or choose them in the app. Selected folders are scanned recursively, including nested folders. Hidden files, package contents, unsupported formats and existing `.jxl` files are skipped or reported. Existing JPEG XL files are always ignored.

Discovered images are queued and processed one at a time in the app's single window, so one drop can contain many files and folders without running several encoders concurrently.

For each supported single-frame image, JXL Drop writes a sibling `.jxl`, checks the JPEG XL signature, decodes the result and validates transparency when the source has alpha. It moves the original to macOS Trash only after those checks pass. If a transparent PNG shares a filename with a JPEG, its output uses `-transparent` before `.jxl` (for example, `cover-transparent.jxl`). Other occupied output names receive `-2`, `-3` and higher suffixes; no existing file is overwritten. A failed conversion, changed source or transparency mismatch keeps the original in place. “Clear List” only removes rows from the app.

The result area shows live file-count progress while converting and a persistent completion summary when the queue is finished. Aggregate size reporting compares only successful replacements in the current drop session, showing their combined source size, combined JXL size and net reduction or growth in MB and as a percentage. Failed or skipped files are excluded from those totals. Earlier result rows remain visible until “Clear List” is used.

## Defaults

- Colour compression: Lossy, quality 90, passed directly to libjxl as `--quality=90`
- Transparency compression: Lossy, quality 90, mapped to libjxl alpha distance 1.0
- Medium (Good Size), mapped to libjxl effort 6
- Automatic libjxl buffering; full-image buffering is an optional setting and may use more memory for better compression
- EXIF, XMP and JUMBF metadata excluded
- Existing `.jxl` files are always ignored

The main window opens with a settings side panel. On a fresh install, colour quality 90 is passed directly to libjxl and both colour and transparency default to Lossy 90. Existing saved settings are preserved during upgrades. Settings, metadata choices, speed, buffering and panel visibility are stored between launches. Libjxl quality 90 corresponds to distance 1.0; quality 100 maps to distance 0 and is mathematically lossless. Transparency has a separate Lossy/Lossless mode and quality control. The app maps transparency quality 90 to alpha distance 1.0 and 100 to distance 0, so 100 encodes alpha losslessly. This is an app-defined mapping based on libjxl’s quality-to-distance curve, not a confirmed mapping to Adobe’s slider. Libjxl’s whole-image lossless colour path also encodes transparency losslessly, so the transparency controls are disabled in that mode and when colour quality is 100.

The Speed picker sets libjxl effort to 1, 3, 6, 8 or 10. Higher effort takes longer and may improve compression at the selected quality, but does not guarantee a smaller file for every image. “Use full image buffering” passes `--buffering=0`; it can improve compression while using more memory. It is off by default, leaving buffering to libjxl.

## Transparency and input handling

When an input has alpha, JXL Drop applies the transparency setting separately from colour quality, keeps colour and extra channels at full resolution, and preserves invisible pixel colours. It verifies that the decoded result still has the source dimensions and transparency channel. Integer alpha up to 16 bits is checked at 16-bit precision; lossless alpha is compared sample by sample, while lossy alpha is checked to ensure transparency remains present rather than becoming fully opaque. Floating-point or higher-precision alpha is retained unchanged because the app cannot verify it safely. Staged inputs must preserve the source alpha exactly before encoding.

Inputs that macOS cannot inspect, multi-frame images and multi-page documents are kept rather than flattened for replacement. HEIC/HEIF, TIFF, BMP, WebP and JPEG 2000 are staged as PNG through macOS `sips`. Lossy colour and lossy alpha can change pixel values; staging may change colour representation.

EXIF and XMP are stripped separately. The “Photoshop Extras” setting controls JUMBF metadata; it does not claim to remove every application-specific data block. Embedded colour information is retained where supported.

## JPEG XL settings in existing files

A JPEG XL file identifies image properties such as dimensions, colour encoding, bit depth and whether alpha is present. It does not record the encoder’s quality slider value or effort preset, so exact settings cannot be read back from a JXL file alone. Decoded pixels can be compared with the original image to assess the result, but that does not reveal the encoder settings.

## Requirements

- macOS 13 or later
- Xcode Command Line Tools
- JPEG XL command-line tools (`cjxl` and `djxl`), installed with `brew install jpeg-xl`

The app looks for `cjxl` and `djxl` in `/opt/homebrew/bin` and `/usr/local/bin`.

## Build

Run `./build.sh` on macOS. The script compiles for the current Mac architecture, installs `Info.plist` and the app icon into the `.app` bundle, and applies an ad-hoc local signature. It does not notarise the app for distribution. The tracked `Resources/AppIcon.icns` preserves the icon supplied with this app.
