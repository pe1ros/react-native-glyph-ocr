#include <jni.h>
#include <fbjni/fbjni.h>
#include <sched.h>
#include <cerrno>
#include "NitroGlyphOcrOnLoad.hpp"

JNIEXPORT jint JNICALL JNI_OnLoad(JavaVM* vm, void*) {
  return facebook::jni::initialize(vm, []() {
    margelo::nitro::glyphocr::registerAllNatives();
  });
}

// Pins the calling thread to the given CPU cores (0-based). Returns 0 or errno.
extern "C" JNIEXPORT jint JNICALL
Java_com_margelo_nitro_glyphocr_CpuAffinity_setCurrentThreadCpus(JNIEnv* env, jclass, jintArray cpus) {
  cpu_set_t set;
  CPU_ZERO(&set);
  jsize count = env->GetArrayLength(cpus);
  jint* ids = env->GetIntArrayElements(cpus, nullptr);
  for (jsize i = 0; i < count; i++) {
    CPU_SET(ids[i], &set);
  }
  env->ReleaseIntArrayElements(cpus, ids, JNI_ABORT);
  return sched_setaffinity(0, sizeof(set), &set) == 0 ? 0 : errno;
}
