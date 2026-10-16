#include <jni.h>
#include <fbjni/fbjni.h>
#include "NitroPurelyOcrOnLoad.hpp"

JNIEXPORT jint JNICALL JNI_OnLoad(JavaVM* vm, void*) {
  return facebook::jni::initialize(vm, []() {
    margelo::nitro::purelyocr::registerAllNatives();
  });
}
