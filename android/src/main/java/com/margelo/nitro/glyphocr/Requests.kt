package com.margelo.nitro.glyphocr

import com.margelo.nitro.core.Promise
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Cancellable promises. The JS wrapper gives every call a process-wide `requestId` and maps
 * `AbortSignal` to `cancel(requestId)`; ids of all objects share this registry.
 */
internal object Requests {
  private val jobs = ConcurrentHashMap<Double, Job>()
  private val cancelled = ConcurrentHashMap.newKeySet<Double>()

  fun cancel(requestId: Double) {
    cancelled.add(requestId)
    jobs[requestId]?.cancel()
  }

  fun isCancelled(requestId: Double) = requestId in cancelled

  fun throwIfCancelled(requestId: Double) {
    if (requestId in cancelled) throw OcrException("cancelled", "Cancelled")
  }

  /** Runs `block` in `scope`; it rejects with `cancelled` if cancelled while queued or running. */
  fun <T> promise(scope: CoroutineScope, requestId: Double, block: suspend () -> T): Promise<T> {
    val promise = Promise<T>()
    val settled = AtomicBoolean(false)
    val job = scope.launch(start = CoroutineStart.LAZY) {
      try {
        throwIfCancelled(requestId)
        val result = block()
        if (settled.compareAndSet(false, true)) promise.resolve(result)
      } catch (t: Throwable) {
        if (settled.compareAndSet(false, true)) promise.reject(OcrException.wrap(t))
      }
    }
    if (requestId > 0) jobs[requestId] = job
    job.invokeOnCompletion {
      jobs.remove(requestId)
      cancelled.remove(requestId)
      // Cancelled before it ever ran.
      if (settled.compareAndSet(false, true)) promise.reject(OcrException("cancelled", "Cancelled"))
    }
    job.start()
    return promise
  }
}
