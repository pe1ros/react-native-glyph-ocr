package com.margelo.nitro.glyphocr

/** BCP-47 tags and how they map onto the manifest's Paddle packs. */
internal object Languages {
  class Tag(val language: String, val script: String?)

  /** `RU` → `ru`, `zh_hans` → `zh-Hans`, `pt-br` → `pt-BR`. Empty for an empty tag. */
  fun normalize(tag: String): String {
    val parts = tag.trim().replace('_', '-').split('-').filter { it.isNotEmpty() }
    return parts.mapIndexed { i, p ->
      when {
        i == 0 -> p.lowercase()
        p.length == 4 && p.all { it.isLetter() } -> p.lowercase().replaceFirstChar { it.uppercaseChar() }
        p.length == 2 && p.all { it.isLetter() } -> p.uppercase()
        else -> p.lowercase()
      }
    }.joinToString("-")
  }

  fun parse(tag: String): Tag {
    val parts = tag.split('-')
    return Tag(parts[0], parts.drop(1).firstOrNull { it.length == 4 })
  }

  /** A pack language covers a request with the same language and, if both name one, the same script. */
  fun covers(offered: String, requested: String): Boolean {
    val o = parse(offered)
    val r = parse(requested)
    return o.language == r.language && (r.script == null || o.script == null || r.script == o.script)
  }

  fun packCovers(pack: ModelPack, languages: List<String>): Boolean =
    languages.all { r -> pack.languages.any { covers(it, r) } }

  class Resolution(val languages: List<String>, val pack: ModelPack?, val unsupported: List<String>)

  /** The first pack (manifest order) covering every language, or the given one. */
  fun resolve(manifest: ModelManifest, requested: Array<String>, packId: String?): Resolution {
    val languages = requested.map(::normalize).filter { it.isNotEmpty() }.distinct()
    if (languages.isEmpty()) throw OcrException("invalid-argument", "No languages given")
    val packs = manifest.packs.filter { it.engine == OcrEngine.PADDLE }
    if (packId != null) {
      val pack = packs.firstOrNull { it.id == packId }
        ?: throw OcrException("invalid-argument", "No pack $packId in the manifest", mapOf("packId" to packId))
      return Resolution(languages, pack, languages.filter { r -> pack.languages.none { covers(it, r) } })
    }
    packs.firstOrNull { packCovers(it, languages) }?.let { return Resolution(languages, it, emptyList()) }
    // None covers all: report what the best pack (most languages, first in order) leaves out.
    val best = packs.maxByOrNull { p -> languages.count { r -> p.languages.any { covers(it, r) } } }
    val unsupported = if (best == null) languages else languages.filter { r -> best.languages.none { covers(it, r) } }
    return Resolution(languages, null, unsupported)
  }
}
