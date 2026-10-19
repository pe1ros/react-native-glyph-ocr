package com.margelo.nitro.purelyocr

import android.graphics.Bitmap
import com.google.android.gms.tasks.Tasks
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.text.TextRecognition
import com.google.mlkit.vision.text.latin.TextRecognizerOptions

// Compiled only with PurelyOcr_devMlKit=true (see build.gradle); created by reflection.

/** ML Kit Text Recognition v2, Latin script, model bundled into the APK. */
internal class MlKitTextEngine : MlKitEngine {
  private val recognizer = TextRecognition.getClient(TextRecognizerOptions.DEFAULT_OPTIONS)

  override fun recognize(bitmap: Bitmap): List<List<RawLine>> {
    val text = Tasks.await(recognizer.process(InputImage.fromBitmap(bitmap, 0)))
    return text.textBlocks.map { block ->
      block.lines.mapNotNull { line ->
        val box = line.boundingBox ?: return@mapNotNull null
        val corners = line.cornerPoints?.takeIf { it.size == 4 }?.map { Pt(it.x.toDouble(), it.y.toDouble()) }
          ?: listOf(
            Pt(box.left.toDouble(), box.top.toDouble()), Pt(box.right.toDouble(), box.top.toDouble()),
            Pt(box.right.toDouble(), box.bottom.toDouble()), Pt(box.left.toDouble(), box.bottom.toDouble()),
          )
        RawLine(
          text = line.text,
          confidence = line.confidence.toDouble(),
          corners = corners,
          left = box.left.toDouble(), top = box.top.toDouble(), right = box.right.toDouble(), bottom = box.bottom.toDouble(),
          words = line.elements.mapNotNull { e ->
            val points = e.cornerPoints?.takeIf { it.size == 4 } ?: return@mapNotNull null
            RawWord(e.text, e.confidence.toDouble(), points.map { Pt(it.x.toDouble(), it.y.toDouble()) })
          },
        )
      }
    }
  }

  override fun close() {
    recognizer.close()
  }
}
