package com.margelo.nitro.glyphocr

/** Thread pinning for the "little cores only" measurement. Lives in libNitroGlyphOcr. */
internal object CpuAffinity {
  init {
    NitroGlyphOcrOnLoad.initializeNative()
  }

  /** Pins the calling thread to `cpus` (0-based core ids). Returns 0 or an errno value. */
  @JvmStatic
  external fun setCurrentThreadCpus(cpus: IntArray): Int

  fun allCpus(): IntArray = IntArray(Runtime.getRuntime().availableProcessors()) { it }
}
