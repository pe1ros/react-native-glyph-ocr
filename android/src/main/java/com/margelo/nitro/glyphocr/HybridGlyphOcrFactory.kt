package com.margelo.nitro.glyphocr

/** Entry object (autolinked): PaddleOCR on Android. */
class HybridGlyphOcrFactory : HybridGlyphOcrFactorySpec() {
  override val defaultEngine = OcrEngine.PADDLE
  override val availableEngines = arrayOf(OcrEngine.PADDLE)

  override val models: HybridOcrModelStoreSpec by lazy { HybridOcrModelStore() }

  override fun getSupportedLanguages(engine: OcrEngine?): Array<SupportedLanguage> {
    if (engine != null) requireEngine(engine)
    return ModelStore.manifest.packs.filter { it.engine == OcrEngine.PADDLE }.flatMap { pack ->
      val status = when (ModelStore.packStatus(pack)) {
        ModelPackStatus.INSTALLED, ModelPackStatus.EMBEDDED -> LanguageStatus.READY
        else -> if (ModelStore.canDownload(pack)) LanguageStatus.NEEDS_DOWNLOAD else LanguageStatus.UNAVAILABLE
      }
      val bytes = ModelStore.missingBytes(pack).toDouble()
      pack.languages.map { SupportedLanguage(it, OcrEngine.PADDLE, pack.id, status, bytes) }
    }.toTypedArray()
  }

  override fun resolveLanguages(engine: OcrEngine, languages: Array<String>, packId: String?): LanguageResolution {
    requireEngine(engine)
    val r = Languages.resolve(ModelStore.manifest, languages, packId)
    return LanguageResolution(OcrEngine.PADDLE, r.languages.toTypedArray(), emptyArray(), r.pack?.id, r.unsupported.toTypedArray())
  }

  /** `customWords` are Vision's; Paddle has no language model to bias. */
  override fun createRecognizer(
    engine: OcrEngine, languages: Array<String>, customWords: Array<String>, packId: String?, threads: Double?,
  ): HybridOcrRecognizerSpec = create(engine, languages, packId, threads?.toInt() ?: DEFAULT_THREADS, null)

  override fun createFrameMeter(): HybridOcrFrameMeterSpec = HybridOcrFrameMeter()

  companion object {
    /** The best measured on Pixel 6a. */
    const val DEFAULT_THREADS = 4

    fun requireEngine(engine: OcrEngine) {
      when (engine) {
        OcrEngine.PADDLE -> return
        OcrEngine.VISION -> throw OcrException("engine-unavailable", "Apple Vision is iOS only", mapOf("engine" to "vision"))
        OcrEngine.MLKIT -> throw OcrException(
          "engine-unavailable", "ML Kit is only in react-native-glyph-ocr/dev", mapOf("engine" to "mlkit"),
        )
      }
    }

    internal fun create(engine: OcrEngine, languages: Array<String>, packId: String?, threads: Int, tuning: DevTuning?): HybridOcrRecognizer {
      requireEngine(engine)
      val r = Languages.resolve(ModelStore.manifest, languages, packId)
      val pack = r.pack
      if (pack == null || r.unsupported.isNotEmpty()) {
        throw OcrException(
          "language-not-supported", "paddle cannot read ${r.unsupported.joinToString()}",
          mapOf("engine" to "paddle", "unsupported" to org.json.JSONArray(r.unsupported)),
        )
      }
      return HybridOcrRecognizer(pack, r.languages.toTypedArray(), threads, tuning)
    }
  }
}
