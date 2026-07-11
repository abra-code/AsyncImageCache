// FixtureParityInstrumentedTest.kt - Stage F, the Android half of the cross-platform parity net.
//
// Reads the SAME fixture files the Swift emitter produced (Fixtures/images + Fixtures/expected, mounted as
// androidTest assets via build.gradle.kts) and asserts the Kotlin ImageProcessing produces the values recorded in
// each <name>.json. The JSON is the ground truth: exact for animated / header size / variant geometry, and within
// a per-fixture tolerance for the placeholder grid and dominant color (CoreGraphics and createScaledBitmap
// downsample slightly differently; lossy JPEG and GIF palette quantization widen the band further).
//
// To regenerate the fixtures after a deliberate behavior change, run the Swift emitter:
//   AIC_EMIT_FIXTURES=1 swift test --filter testEmitFixtures
// then re-run this suite; a drift here without a matching Swift change is a real cross-platform divergence.

package com.abracode.asyncimagecache

import android.content.res.AssetManager
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.assertFalse
import org.junit.Test
import org.junit.runner.RunWith
import org.json.JSONArray
import org.json.JSONObject
import kotlin.math.abs

@RunWith(AndroidJUnit4::class)
class FixtureParityInstrumentedTest {

    // The fixtures ride in the TEST apk, so read them from the instrumentation context (not the target context).
    private val assets: AssetManager
        get() = InstrumentationRegistry.getInstrumentation().context.assets

    private fun assetBytes(path: String): ByteArray = assets.open(path).use { it.readBytes() }

    @Test fun fixturesMatchKotlinReference() {
        val expectedFiles = assets.list("expected")?.filter { it.endsWith(".json") }.orEmpty().sorted()
        // Guard against a broken asset mount silently passing: the Swift emitter writes 7 fixtures.
        assertFalse(
            "no expected/*.json assets found - is Fixtures/ mounted as an androidTest assets srcDir?",
            expectedFiles.isEmpty(),
        )

        val failures = mutableListOf<String>()
        for (jsonName in expectedFiles) {
            val json = JSONObject(String(assetBytes("expected/$jsonName"), Charsets.UTF_8))
            val name = json.optString("name", jsonName)
            val bytes = assetBytes("images/${json.getString("file")}")
            checkFixture(name, bytes, json, failures)
        }
        assertFalse("parity mismatches:\n" + failures.joinToString("\n"), failures.isNotEmpty())
    }

    private fun checkFixture(name: String, bytes: ByteArray, json: JSONObject, failures: MutableList<String>) {
        // animated - exact (byte sniffer vs the Swift decoder frame count).
        val expectedAnimated = json.getBoolean("animated")
        val actualAnimated = ImageProcessing.isAnimated(bytes)
        if (actualAnimated != expectedAnimated) {
            failures.add("$name: animated expected=$expectedAnimated actual=$actualAnimated")
        }

        // headerPixelSize - exact (decode-free, EXIF 5-8 axes swapped).
        val header = json.getJSONObject("headerPixelSize")
        val actualHeader = ImageProcessing.headerPixelSize(bytes)
        if (actualHeader == null) {
            failures.add("$name: headerPixelSize returned null")
        } else {
            if (actualHeader.width != header.getInt("width") || actualHeader.height != header.getInt("height")) {
                failures.add("$name: header expected=${header.getInt("width")}x${header.getInt("height")} " +
                    "actual=${actualHeader.width}x${actualHeader.height}")
            }
        }

        // Everything below needs the decoded bitmap.
        val bitmap = ImageProcessing.decode(bytes)
        if (bitmap == null) {
            failures.add("$name: decode returned null")
            return
        }
        try {
            // variant geometry - exact (cap width, height scales, never upscale).
            val variant = json.getJSONObject("variant")
            val out = ImageProcessing.variant(bitmap, variant.getInt("targetWidth").toFloat(), 0f)
            if (out.width != variant.getInt("width") || out.height != variant.getInt("height")) {
                failures.add("$name: variant expected=${variant.getInt("width")}x${variant.getInt("height")} " +
                    "actual=${out.width}x${out.height}")
            }
            if (out !== bitmap) {
                out.recycle()
            }

            // colors - within tolerance, only where the JSON carries a grid (unambiguous decode orientation).
            if (!json.has("grid")) {
                return
            }
            val tolerance = json.getInt("colorTolerance")
            val placeholder = ImageProcessing.placeholder(bitmap)
            if (placeholder == null) {
                failures.add("$name: placeholder returned null")
                return
            }
            val cells = json.getJSONObject("grid").getJSONArray("cells")
            if (placeholder.cells.size != cells.length()) {
                failures.add("$name: cell count expected=${cells.length()} actual=${placeholder.cells.size}")
            } else {
                for (i in 0 until cells.length()) {
                    colorClose(name, "cell $i", placeholder.cells[i], cells.getJSONArray(i), tolerance, failures)
                }
            }
            colorClose(name, "dominant", placeholder.dominantColor, json.getJSONArray("dominantColor"), tolerance, failures)
        } finally {
            bitmap.recycle()
        }
    }

    private fun colorClose(
        name: String,
        label: String,
        actual: ImageColor,
        expected: JSONArray,
        tolerance: Int,
        failures: MutableList<String>,
    ) {
        val got = intArrayOf(actual.red, actual.green, actual.blue, actual.alpha)
        for (ch in 0 until 4) {
            if (abs(got[ch] - expected.getInt(ch)) > tolerance) {
                failures.add("$name $label channel $ch: expected=${expected.getInt(ch)} actual=${got[ch]} " +
                    "(tolerance $tolerance)")
                return
            }
        }
    }
}
