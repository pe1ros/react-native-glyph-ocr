# libexecutorch.so for the OCR module: the ExecuTorch runtime, the XNNPACK backend, only the kernels
# our programs run outside the delegate (selective build), and the JNI layer behind
# org.pytorch.executorch.Module. Configured by ../build-android.sh.
#
# ExecuTorch's own extension/android target links every portable or optimized kernel and builds
# with the static libc++. Here the JNI layer links the app's libc++_shared and fbjni instead, so the
# C++ exceptions it throws for Java (facebook::jni::JniException) reach fbjni's translator and
# arrive in Kotlin as ExecutorchRuntimeException instead of aborting in
# getJavaExceptionForCppException ('ptr').
cmake_minimum_required(VERSION 3.24)
project(glyphocr_executorch C CXX)

set(EXECUTORCH_SRC "" CACHE PATH "ExecuTorch checkout, in a directory named executorch")
set(FBJNI_PREFAB "" CACHE PATH "fbjni prefab module: include/ and libs/android.<abi>/libfbjni.so")

if(NOT ANDROID_STL STREQUAL "c++_shared")
  message(FATAL_ERROR "ANDROID_STL must be c++_shared, see the comment at the top")
endif()

# Sections for every library, XNNPACK's C sources included, so --gc-sections drops what nothing uses.
string(APPEND CMAKE_C_FLAGS " -ffunction-sections -fdata-sections")
string(APPEND CMAKE_CXX_FLAGS " -ffunction-sections -fdata-sections")

add_subdirectory(${EXECUTORCH_SRC} executorch)

add_library(fbjni SHARED IMPORTED)
set_target_properties(
  fbjni PROPERTIES IMPORTED_LOCATION ${FBJNI_PREFAB}/libs/android.${ANDROID_ABI}/libfbjni.so
                   INTERFACE_INCLUDE_DIRECTORIES ${FBJNI_PREFAB}/include
)

set(_jni ${EXECUTORCH_SRC}/extension/android/jni)
add_library(
  executorch_jni SHARED ${_jni}/jni_layer.cpp ${_jni}/jni_layer_runtime.cpp ${_jni}/jni_helper.cpp
                        ${_jni}/log.cpp
)
# Module.kt loads it as "executorch".
set_target_properties(executorch_jni PROPERTIES OUTPUT_NAME executorch)
target_compile_options(executorch_jni PRIVATE -fexceptions -frtti -Wno-deprecated-declarations)
# executorch, xnnpack_backend and executorch_selected_kernels carry --whole-archive themselves:
# kernels and backends register through static initializers.
target_link_libraries(
  executorch_jni
  PRIVATE executorch
          executorch_selected_kernels
          xnnpack_backend
          extension_module_static
          extension_data_loader
          extension_flat_tensor
          extension_named_data_map
          extension_runner_util
          extension_tensor
          extension_threadpool
          fbjni
          log
)
target_link_options(
  executorch_jni
  PRIVATE
  "LINKER:--version-script,${_jni}/version_script.txt"
  "LINKER:--gc-sections"
  "LINKER:--icf=all"
  "LINKER:--exclude-libs,ALL"
  # 16 KB pages (Android 15+ devices, required by Google Play)
  "LINKER:-z,max-page-size=16384"
)
