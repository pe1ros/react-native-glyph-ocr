package com.margelo.nitro.glyphocr

import com.margelo.nitro.core.Promise
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob

/** JS face of [ModelStore]. */
class HybridOcrModelStore : HybridOcrModelStoreSpec() {
  private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

  override val manifest: ModelManifest get() = ModelStore.manifest
  override val directory: String get() = ModelStore.directory.absolutePath

  override fun configure(config: ModelStoreConfig) = ModelStore.configure(config)

  override fun getPackStatus(packId: String): ModelPackStatus = ModelStore.packStatus(ModelStore.pack(packId))

  override fun download(packIds: Array<String>, onProgress: (progress: PrepareProgress) -> Unit, requestId: Double): Promise<DownloadResult> =
    Requests.promise(scope, requestId) {
      val packs = packIds.map { ModelStore.pack(it) }
      val files = packs.flatMap { ModelStore.files(it, ModelStore.allRoles(), ModelStore.ORT_FORMATS) }
      val bytes = ModelStore.ensure(files, ProgressReporter(onProgress))
      DownloadResult(bytes.toDouble(), packIds)
    }

  override fun remove(packIds: Array<String>): Promise<Unit> =
    Requests.promise(scope, 0.0) { ModelStore.remove(packIds.toList()) }

  override fun prune(): Promise<Double> = Requests.promise(scope, 0.0) { ModelStore.prune().toDouble() }

  override fun cancel(requestId: Double) = Requests.cancel(requestId)
}
