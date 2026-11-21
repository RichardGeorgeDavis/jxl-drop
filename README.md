# JXL Drop

JXL Drop is a local macOS app for converting images to JPEG XL. Drop files or several folders at once, or choose them in the app. Selected folders are scanned recursively, including nested folders. Hidden files, package contents, unsupported formats and existing `.jxl` files are skipped or reported.

For each supported single-frame image, JXL Drop writes a sibling `.jxl`, checks the JPEG XL signature, decodes the result and verifies the transparency plane when the source has alpha. It moves the original to macOS Trash only after those checks pass. A failed conversion, changed source, transparency mismatch or output-name collision keeps the original in place. “Clear List” only removes rows from the app.

## Defaults

- Lossy mode, quality 100 / Maximum in the app, mapped to libjxl quality 95
- Medium (Good Size), approximated with libjxl effort 6
- EXIF, XMP and JUMBF metadata excluded
- Existing `.jxl` files are never overwritten

The app’s quality scale is mapped from 1–100 to libjxl quality 1–95. Libjxl quality 100 is mathematically lossless, so the app maps its displayed quality 100 to 95 to retain the requested lossy behaviour. Adobe’s internal quality and speed mappings are not published; the mapping is an approximation.

## Transparency and input handling

When an input has alpha, the app requests mathematically lossless alpha, disables resampling for colour and extra channels, and preserves invisible pixel colours. It compares every decoded alpha sample with the source before moving the source to Trash. Inputs that macOS cannot inspect, multi-frame images, and multi-page documents are kept rather than flattened for replacement. HEIC/HEIF, TIFF, BMP, WebP and JPEG 2000 are staged as PNG through macOS `sips`; the app compares staged alpha with source alpha before encoding. Lossy colour may still change RGB values, and staging may change colour representation.

EXIF and XMP are stripped separately. The “Photoshop Extras” setting controls JUMBF metadata; it does not claim to remove every application-specific data block. Embedded colour information is retained where supported.

## Requirements

- macOS 13 or later
- Xcode Command Line Tools
- JPEG XL command-line tools (`cjxl` and `djxl`), installed with `brew install jpeg-xl`

The app looks for `cjxl` and `djxl` in `/opt/homebrew/bin` and `/usr/local/bin`.

## Build

Run `./build.sh` on macOS. The script compiles for the current Mac architecture, installs `Info.plist` and the app icon into the `.app` bundle, and applies an ad-hoc local signature. It does not notarise the app for distribution. The tracked `Resources/AppIcon.icns` preserves the icon supplied with this app.
