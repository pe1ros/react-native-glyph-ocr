#!/usr/bin/env bash
# Builds a minimal ExecuTorch for the OCR module (Android arm64-v8a) from the v1.4.0 sources, the
# version of the executorch Python package that exports our models: the runtime, the XNNPACK
# backend, only the kernels the given programs run outside the delegate, and the JNI layer behind
# org.pytorch.executorch.Module, linked against the app's libc++_shared and fbjni (see
# android/CMakeLists.txt). No LLM runner, tokenizers, training, devtools, Vulkan or other backends.
#
# Writes into $OUT, by default android/executorch of this package (git-ignored),
# which the module's build.gradle picks up:
#   jni/arm64-v8a/libexecutorch.so   stripped
#   java/org/pytorch/executorch/     the Kotlin API of the same tag (Module, Tensor, EValue, ...)
#   ops.txt                          the selected operators
#
# usage: scripts/executorch/build-android.sh <work dir> <.pte> [<.pte> ...]
#   <work dir>  ExecuTorch checkout and build tree (~1 GB), reused between runs
#   <.pte>      programs whose non-delegated operators to keep; rebuild when they change
# env:
#   PYTHON          python with requirements.txt installed (codegen needs executorch and torchgen)
#   ANDROID_NDK     default: $ANDROID_HOME/ndk/27.1.12297006, the app's ndkVersion
#   ET_CMAKE_ARGS   extra cmake arguments, e.g. "-DXNNPACK_ENABLE_ARM_SME2=OFF"
#   OUT             output directory
set -euo pipefail
WORK="${1:?work dir}"
shift
[ $# -gt 0 ] || { echo "no .pte given" >&2; exit 1; }
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
OUT="${OUT:-$ROOT/android/executorch}"
PYTHON="${PYTHON:-python3}"
ANDROID_HOME="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
ANDROID_NDK="${ANDROID_NDK:-$ANDROID_HOME/ndk/27.1.12297006}"
ABI=arm64-v8a
ET_TAG=v1.4.0
FBJNI_VERSION=0.7.0 # react-native's, see node_modules/react-native/gradle/libs.versions.toml

mkdir -p "$WORK"
WORK="$(cd "$WORK" && pwd)"
# ExecuTorch includes itself as <executorch/...>: the checkout must be named executorch.
SRC="$WORK/executorch"
if [ ! -d "$SRC/.git" ]; then
  git clone --depth 1 --branch "$ET_TAG" https://github.com/pytorch/executorch.git "$SRC"
fi
[ "$(git -C "$SRC" describe --tags)" = "$ET_TAG" ] || { echo "$SRC is not at $ET_TAG" >&2; exit 1; }
git -C "$SRC" submodule update --init --depth 1 \
  backends/xnnpack/third-party/FP16 backends/xnnpack/third-party/FXdiv \
  backends/xnnpack/third-party/XNNPACK backends/xnnpack/third-party/cpuinfo \
  backends/xnnpack/third-party/pthreadpool third-party/flatbuffers third-party/flatcc \
  third-party/json third-party/gflags # added by third-party/CMakeLists.txt unconditionally

OPS="$("$PYTHON" -I "$HERE/list_ops.py" "$@")"
echo "selected operators: $OPS"

FBJNI="$WORK/fbjni-$FBJNI_VERSION"
if [ ! -f "$FBJNI/prefab/modules/fbjni/libs/android.$ABI/libfbjni.so" ]; then
  mkdir -p "$FBJNI"
  curl -fsSL -o "$FBJNI/fbjni.aar" \
    "https://repo1.maven.org/maven2/com/facebook/fbjni/fbjni/$FBJNI_VERSION/fbjni-$FBJNI_VERSION.aar"
  unzip -oq "$FBJNI/fbjni.aar" -d "$FBJNI"
fi

NINJA="$(command -v ninja || ls "$ANDROID_HOME"/cmake/*/bin/ninja | tail -1)"
# XNNPACK configures its KleidiAI download as a nested Ninja project: ninja must be on PATH.
export PATH="$PATH:$(dirname "$NINJA")" # after the cmake in PATH (3.24+)
BUILD="$WORK/build-$ABI"
# shellcheck disable=SC2086
cmake -S "$HERE/android" -B "$BUILD" -G Ninja -DCMAKE_MAKE_PROGRAM="$NINJA" \
  -DCMAKE_TOOLCHAIN_FILE="$ANDROID_NDK/build/cmake/android.toolchain.cmake" \
  -DANDROID_ABI=$ABI -DANDROID_PLATFORM=android-24 -DANDROID_STL=c++_shared \
  -DCMAKE_BUILD_TYPE=Release \
  -DPYTHON_EXECUTABLE="$(command -v "$PYTHON")" \
  -DEXECUTORCH_SRC="$SRC" -DFBJNI_PREFAB="$FBJNI/prefab/modules/fbjni" \
  -DEXECUTORCH_SELECT_OPS_LIST="$OPS" \
  -DEXECUTORCH_PAL_DEFAULT=android \
  -DEXECUTORCH_ENABLE_LOGGING=ON -DEXECUTORCH_LOG_LEVEL=Info \
  -DEXECUTORCH_BUILD_XNNPACK=ON \
  -DEXECUTORCH_XNNPACK_ENABLE_WEIGHT_CACHE=ON -DEXECUTORCH_XNNPACK_SHARED_WORKSPACE=ON \
  -DEXECUTORCH_BUILD_EXTENSION_DATA_LOADER=ON -DEXECUTORCH_BUILD_EXTENSION_FLAT_TENSOR=ON \
  -DEXECUTORCH_BUILD_EXTENSION_NAMED_DATA_MAP=ON -DEXECUTORCH_BUILD_EXTENSION_MODULE=ON \
  -DEXECUTORCH_BUILD_EXTENSION_RUNNER_UTIL=ON -DEXECUTORCH_BUILD_EXTENSION_TENSOR=ON \
  -DEXECUTORCH_BUILD_KERNELS_OPTIMIZED=OFF -DEXECUTORCH_BUILD_KERNELS_QUANTIZED=OFF \
  -DEXECUTORCH_BUILD_KERNELS_LLM=OFF -DEXECUTORCH_BUILD_EXTENSION_LLM=OFF \
  -DEXECUTORCH_BUILD_EXTENSION_LLM_RUNNER=OFF -DEXECUTORCH_BUILD_EXTENSION_TRAINING=OFF \
  -DEXECUTORCH_BUILD_DEVTOOLS=OFF -DEXECUTORCH_BUILD_EXECUTOR_RUNNER=OFF \
  -DEXECUTORCH_BUILD_ANDROID_JNI=OFF -DEXECUTORCH_BUILD_VULKAN=OFF -DBUILD_TESTING=OFF \
  -DFLATCC_ALLOW_WERROR=OFF \
  ${ET_CMAKE_ARGS:-}
cmake --build "$BUILD" --target executorch_jni

STRIP="$(ls "$ANDROID_NDK"/toolchains/llvm/prebuilt/*/bin/llvm-strip)"
rm -rf "$OUT/jni" "$OUT/java" "$OUT/ops.txt"
mkdir -p "$OUT/jni/$ABI" "$OUT/java/org/pytorch/executorch/annotations"
"$STRIP" --strip-unneeded -o "$OUT/jni/$ABI/libexecutorch.so" "$BUILD/libexecutorch.so"
API="$SRC/extension/android/executorch_android/src/main/java/org/pytorch/executorch"
cp "$API"/{DType,EValue,ExecuTorchRuntime,ExecutorchRuntimeException,MethodMetadata,Module,Tensor}.kt \
  "$OUT/java/org/pytorch/executorch/"
cp "$API/annotations/Experimental.kt" "$OUT/java/org/pytorch/executorch/annotations/"
echo "$OPS" | tr , '\n' >"$OUT/ops.txt"

SO="$OUT/jni/$ABI/libexecutorch.so"
echo "$SO: $(wc -c <"$SO" | tr -d ' ') bytes, gzip -9 $(gzip -9c "$SO" | wc -c | tr -d ' ') bytes"
