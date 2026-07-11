# Fixtures - cross-platform parity net (Stage F)

A small set of canonical images plus their expected decoded values, shared byte-for-byte by the Swift and Android implementations of AsyncImageCache. This is the ground truth that links the two ports: any future behavior change on either side must regenerate the fixtures, which forces a conscious cross-platform review.

## Layout

- `images/` - the canonical encoded images (PNG, JPEG, EXIF-rotated JPEG, animated + static GIF, Display P3 PNG).
- `expected/<name>.json` - the values each image must decode to.

Each `expected/<name>.json` carries only the fields that apply to its image:

| Field | Comparison | Meaning |
|---|---|---|
| `animated` | exact | Multi-frame container. Swift reads the decoder frame count; Android sniffs the container header (porting-plan section 8). |
| `headerPixelSize` | exact | Natural size AS DISPLAYED, read decode-free from the header. EXIF orientations 5-8 swap the axes. This is the relaunch-without-decode path. |
| `variant` | exact | The downscale geometry at `targetWidth`: cap width, height scales proportionally, never upscale. Target widths halve cleanly so there is no cross-platform rounding ambiguity. |
| `dominantColor` | within `colorTolerance` | Average of the placeholder grid. Present only when the decode orientation is unambiguous. |
| `grid` | within `colorTolerance`, per cell | The 6x6 placeholder grid, row 0 = top. Present only when the decode orientation is unambiguous. |

Colors carry a tolerance because CoreGraphics and `Bitmap.createScaledBitmap` area-average slightly differently, and lossy JPEG / GIF-palette quantization widen the band. Sizes, flags, and variant geometry are exact.

The EXIF-rotated fixture asserts only `animated` + `headerPixelSize` + `variant` (its decoded pixel orientation differs across the emitter host and the device); the animated GIF likewise skips colors (first-frame palette differs per decoder).

## Regenerating

The Swift test target owns generation. To (re)produce every image and its JSON after a deliberate behavior change:

```
AIC_EMIT_FIXTURES=1 swift test --filter testEmitFixtures
```

Then run both suites to confirm they still agree:

- Swift: `swift test` (runs `testFixturesMatchSwiftReference`, the always-on regression guard).
- Android: `./gradlew :asyncimagecache:connectedDebugAndroidTest` (runs `FixtureParityInstrumentedTest`).

Android consumes these files directly: `android/asyncimagecache/build.gradle.kts` mounts `../../Fixtures` as an androidTest assets source dir, so the device reads the exact same bytes the Swift side emitted. JSON is parsed with the `org.json` classes built into the Android SDK - no added dependency on either platform.
