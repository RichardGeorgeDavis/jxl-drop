# JXL Drop

JXL Drop is a local macOS app for converting images to JPEG XL. Drop files or several folders at once, or choose them in the app. Selected folders are scanned recursively, including nested folders. Hidden files, package contents, unsupported formats and existing `.jxl` files are skipped or reported.

For each supported single-frame image, JXL Drop writes a sibling `.jxl`, checks the JPEG XL signature, decodes the result and validates transparency when the source has alpha. It moves the original to macOS Trash only after those checks pass. A failed conversion, changed source, transparency mismatch or output-name collision keeps the original in place. “Clear List” only removes rows from the app.

## Defaults

- Colour compression: Lossy, quality 90, passed directly to libjxl as `--quality=90`
- Transparency compression: Lossy, quality 100 / Maximum, matching the supplied Photoshop transparency panel; libjxl alpha distance 0 is mathematically lossless
- Medium (Good Size), approximated with libjxl effort 6
- EXIF, XMP and JUMBF metadata excluded
- Existing `.jxl` files are never overwritten

Libjxl quality 90 corresponds to distance 1.0; quality 100 maps to distance 0 and is mathematically lossless. The colour quality control is passed directly to libjxl. The separate transparency control uses libjxl’s quality-to-distance curve for `--alpha_distance`; it is not a known mapping to Adobe’s slider. Thus transparency quality 90 maps to alpha distance 1.0, while 100 maps to 0 (mathematically lossless). Both controls can be changed independently when the colour mode is lossy. Libjxl’s lossless colour mode also encodes transparency losslessly, so the transparency controls are disabled in that mode and when colour quality is 100.

## Transparency and input handling

When an input has alpha, JXL Drop applies the transparency setting separately from colour quality, keeps colour and extra channels at full resolution, and preserves invisible pixel colours. It verifies that the decoded result still has the source dimensions and transparency channel. Lossless alpha is compared sample by sample; lossy alpha is checked to ensure transparency remains present rather than becoming fully opaque. Staged inputs must preserve the source alpha exactly before encoding.

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
