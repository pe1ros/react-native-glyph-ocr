package com.margelo.nitro.glyphocr

import kotlinx.coroutines.CancellationException
import org.json.JSONObject
import java.io.FileNotFoundException

/**
 * Every error the module throws. Nitro passes only the message to JS, so the code and details
 * travel in it as `[ocr:<code>] <message> {json details}`; `toOcrError` in JS restores them.
 * Codes are the 17 of `OcrErrorCode` (src/errors.ts).
 */
class OcrException(
  val code: String,
  text: String,
  val details: Map<String, Any?>? = null,
  cause: Throwable? = null,
) : Exception(format(code, text, details), cause) {
  companion object {
    private fun format(code: String, text: String, details: Map<String, Any?>?): String {
      // `{` would end the message early in toOcrError's pattern.
      val clean = text.replace('{', '(').replace('}', ')')
      val json = if (details.isNullOrEmpty()) "" else " " + JSONObject(details).toString()
      return "[ocr:$code] $clean$json"
    }

    /** Anything thrown inside the module, as an OcrException. */
    fun wrap(t: Throwable): OcrException = when (t) {
      is OcrException -> t
      is CancellationException -> OcrException("cancelled", "Cancelled", cause = t)
      is OutOfMemoryError -> OcrException("out-of-memory", t.message ?: "Out of memory", cause = t)
      is FileNotFoundException -> OcrException("source-not-found", t.message ?: "Not found", cause = t)
      is SecurityException -> OcrException("source-permission-denied", t.message ?: "Permission denied", cause = t)
      else -> OcrException("internal", t.message ?: t.toString(), cause = t)
    }
  }
}
