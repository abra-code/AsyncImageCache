// CachedImageUiTest.kt - Compose UI tests for the composable (porting-plan section 4): the reserved box takes
// the intrinsic aspect immediately (no reflow), and a data: URL hydrates to a drawn image. Uses createComposeRule
// with a fixed-width parent so the aspect reservation resolves the height deterministically.

package com.abracode.asyncimagecache

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import androidx.compose.foundation.layout.width
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.test.assertHeightIsEqualTo
import androidx.compose.ui.test.assertWidthIsEqualTo
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.unit.dp
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import java.io.ByteArrayOutputStream
import java.util.UUID

@RunWith(AndroidJUnit4::class)
class CachedImageUiTest {

    @get:Rule val composeRule = createComposeRule()

    private fun dataUrl(width: Int, height: Int): String {
        val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
        Canvas(bitmap).drawColor(Color.rgb(20, 120, 220))
        val out = ByteArrayOutputStream()
        bitmap.compress(Bitmap.CompressFormat.PNG, 100, out)
        return "data:image/png;base64," + android.util.Base64.encodeToString(out.toByteArray(), android.util.Base64.NO_WRAP)
    }

    @Test fun reservesAspectBoxFromIntrinsicSizeImmediately() {
        // A 200x100 intrinsic in a 200 dp-wide parent must reserve a 200 x 100 dp box up front, before any load.
        composeRule.setContent {
            CachedImage(
                url = null,
                modifier = Modifier.width(200.dp).testTag("image"),
                intrinsicSize = Size(200f, 100f),
            )
        }
        composeRule.onNodeWithTag("image").assertWidthIsEqualTo(200.dp).assertHeightIsEqualTo(100.dp)
    }

    @Test fun dataUrlHydratesAndKeepsReservedBox() {
        composeRule.setContent {
            CachedImage(
                url = dataUrl(200, 100),
                modifier = Modifier.width(200.dp).testTag("image"),
                intrinsicSize = Size(200f, 100f),
            )
        }
        composeRule.waitForIdle()
        // The box must not reflow after hydration - still 200 x 100 dp.
        composeRule.onNodeWithTag("image").assertWidthIsEqualTo(200.dp).assertHeightIsEqualTo(100.dp)
    }

    // Regression for the aspect-reflow fix: with NO intrinsicSize and an empty store, the box starts at the
    // neutral 4:3 and must reflow to the loaded image's true aspect once it hydrates. A frozen 4:3 (the bug)
    // would leave a 200 dp-wide box at 150 dp tall; the reflow makes it 100 dp (a 2:1 image).
    @Test fun reservedBoxReflowsToLoadedAspectWhenNoIntrinsicSize() {
        val store = ImageStore(ApplicationProvider.getApplicationContext(), "ui-${UUID.randomUUID()}")
        try {
            composeRule.setContent {
                CachedImage(
                    url = dataUrl(200, 100),
                    modifier = Modifier.width(200.dp).testTag("image"),
                    store = store,
                )
            }
            composeRule.waitForIdle()
            composeRule.onNodeWithTag("image").assertWidthIsEqualTo(200.dp).assertHeightIsEqualTo(100.dp)
        } finally {
            store.removeAll()
        }
    }
}
