package com.margelo.nitro.purelyocr

/** Camera frames (`AHardwareBuffer*`) read on the CPU; see src/main/cpp/FrameBuffers.cpp. */
internal object FrameBuffers {
  init {
    NitroPurelyOcrOnLoad.initializeNative()
  }

  /** `[width, height, format]` of the stored buffer; empty below Android 10. */
  @JvmStatic external fun describe(pointer: Long): IntArray

  /** Upright ARGB of the upright region (x, y, w, h), resampled to outW x outH. */
  @JvmStatic external fun readArgb(
    pointer: Long, exif: Int, x: Float, y: Float, w: Float, h: Float, outW: Int, outH: Int, out: IntArray,
  ): Int

  /** Upright luma (0..255) of the upright region, resampled to outW x outH. */
  @JvmStatic external fun readLuma(
    pointer: Long, exif: Int, x: Float, y: Float, w: Float, h: Float, outW: Int, outH: Int, out: FloatArray,
  ): Int

  /** A YUV 4:2:0 (or RGBA) buffer holding upright ARGB pixels stored as `exif` says. Negative on failure. */
  @JvmStatic external fun createTestFrame(argb: IntArray, uprightW: Int, uprightH: Int, exif: Int): Long

  @JvmStatic external fun release(pointer: Long)

  fun check(status: Int, format: Int) {
    when (status) {
      0 -> return
      -1 -> throw OcrException("frame-unsupported", "Camera frames need Android 10 (API 29)")
      -2 -> throw OcrException(
        "frame-unsupported", "The frame is not readable on the CPU (format 0x${format.toString(16)}); use pixelFormat 'yuv'",
        mapOf("format" to format),
      )
      -3 -> throw OcrException("frame-unsupported", "Unsupported frame format 0x${format.toString(16)}", mapOf("format" to format))
      else -> throw OcrException("internal", "Frame read failed ($status)")
    }
  }
}
