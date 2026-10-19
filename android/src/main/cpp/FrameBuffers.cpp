// Reads camera frames (AHardwareBuffer*, from VisionCamera's `frame.getNativeBuffer().pointer`)
// for FrameBuffers.kt: upright RGB pixels of a region for recognition, a small luma grid for
// OcrFrameMeter, and test frames made from photos. The AHardwareBuffer API is loaded with dlsym,
// because the module's minSdk (24) is below the API levels that introduced it (26, planes 29).
#include <jni.h>
#include <android/hardware_buffer.h>
#include <android/log.h>
#include <dlfcn.h>

#include <algorithm>
#include <cmath>
#include <cstdint>

namespace {

constexpr int kOk = 0;
constexpr int kNoApi = -1;       // below Android 10, or the symbols are missing
constexpr int kLockFailed = -2;  // not CPU-readable (`private` GPU buffers)
constexpr int kBadFormat = -3;
constexpr int kAllocFailed = -4;

struct Api {
  int (*allocate)(const AHardwareBuffer_Desc*, AHardwareBuffer**) = nullptr;
  void (*release)(AHardwareBuffer*) = nullptr;
  void (*describe)(const AHardwareBuffer*, AHardwareBuffer_Desc*) = nullptr;
  int (*lock)(AHardwareBuffer*, uint64_t, int32_t, const ARect*, void**) = nullptr;
  int (*lockPlanes)(AHardwareBuffer*, uint64_t, int32_t, const ARect*, AHardwareBuffer_Planes*) = nullptr;
  int (*unlock)(AHardwareBuffer*, int32_t*) = nullptr;
};

const Api& api() {
  static const Api instance = [] {
    Api a;
    void* lib = dlopen("libandroid.so", RTLD_NOW | RTLD_LOCAL);
    if (lib == nullptr) return a;
    a.allocate = reinterpret_cast<decltype(a.allocate)>(dlsym(lib, "AHardwareBuffer_allocate"));
    a.release = reinterpret_cast<decltype(a.release)>(dlsym(lib, "AHardwareBuffer_release"));
    a.describe = reinterpret_cast<decltype(a.describe)>(dlsym(lib, "AHardwareBuffer_describe"));
    a.lock = reinterpret_cast<decltype(a.lock)>(dlsym(lib, "AHardwareBuffer_lock"));
    a.lockPlanes = reinterpret_cast<decltype(a.lockPlanes)>(dlsym(lib, "AHardwareBuffer_lockPlanes"));
    a.unlock = reinterpret_cast<decltype(a.unlock)>(dlsym(lib, "AHardwareBuffer_unlock"));
    return a;
  }();
  return instance;
}

bool hasApi() {
  const Api& a = api();
  return a.describe && a.lock && a.lockPlanes && a.unlock && a.allocate && a.release;
}

bool isRgba(uint32_t format) {
  return format == AHARDWAREBUFFER_FORMAT_R8G8B8A8_UNORM || format == AHARDWAREBUFFER_FORMAT_R8G8B8X8_UNORM;
}

/**
 * A locked buffer: either three YUV planes or one RGBA plane. Sample coordinates are raw buffer
 * pixels; chroma is subsampled 2x2.
 */
class Locked {
 public:
  Locked(AHardwareBuffer* buffer, uint64_t usage) : buffer_(buffer) {
    AHardwareBuffer_Desc desc{};
    api().describe(buffer, &desc);
    width_ = static_cast<int>(desc.width);
    height_ = static_cast<int>(desc.height);
    rgba_ = isRgba(desc.format);
    if (rgba_) {
      void* data = nullptr;
      if (api().lock(buffer, usage, -1, nullptr, &data) != 0 || data == nullptr) {
        status_ = kLockFailed;
        return;
      }
      rgbaData_ = static_cast<uint8_t*>(data);
      rgbaStride_ = static_cast<int>(desc.stride) * 4;
    } else {
      AHardwareBuffer_Planes planes{};
      if (api().lockPlanes(buffer, usage, -1, nullptr, &planes) != 0) {
        status_ = kLockFailed;
        return;
      }
      if (planes.planeCount < 3) {
        api().unlock(buffer, nullptr);
        status_ = kBadFormat;
        return;
      }
      for (int i = 0; i < 3; i++) planes_[i] = planes.planes[i];
    }
    locked_ = true;
    status_ = kOk;
  }

  ~Locked() {
    if (locked_) api().unlock(buffer_, nullptr);
  }

  int status() const { return status_; }
  int width() const { return width_; }
  int height() const { return height_; }
  bool rgba() const { return rgba_; }

  int luma(int x, int y) const {
    if (rgba_) {
      const uint8_t* p = rgbaData_ + y * rgbaStride_ + x * 4;
      return (77 * p[0] + 150 * p[1] + 29 * p[2]) >> 8;
    }
    const auto& py = planes_[0];
    return static_cast<const uint8_t*>(py.data)[y * py.rowStride + x * py.pixelStride];
  }

  /** ARGB of one pixel; YUV is BT.601 full range (JFIF), what Android cameras produce. */
  int32_t argb(int x, int y, int yValue) const {
    int r, g, b;
    if (rgba_) {
      const uint8_t* p = rgbaData_ + y * rgbaStride_ + x * 4;
      r = p[0];
      g = p[1];
      b = p[2];
    } else {
      const auto& pu = planes_[1];
      const auto& pv = planes_[2];
      int cx = x / 2, cy = y / 2;
      int u = static_cast<const uint8_t*>(pu.data)[cy * pu.rowStride + cx * pu.pixelStride] - 128;
      int v = static_cast<const uint8_t*>(pv.data)[cy * pv.rowStride + cx * pv.pixelStride] - 128;
      r = yValue + ((359 * v) >> 8);
      g = yValue - ((88 * u + 183 * v) >> 8);
      b = yValue + ((454 * u) >> 8);
    }
    r = std::clamp(r, 0, 255);
    g = std::clamp(g, 0, 255);
    b = std::clamp(b, 0, 255);
    return static_cast<int32_t>(0xff000000u | (r << 16) | (g << 8) | b);
  }

 private:
  AHardwareBuffer* buffer_;
  int width_ = 0;
  int height_ = 0;
  bool rgba_ = false;
  bool locked_ = false;
  int status_ = kLockFailed;
  uint8_t* rgbaData_ = nullptr;
  int rgbaStride_ = 0;
  AHardwareBuffer_Plane planes_[3]{};
};

/**
 * Upright point -> raw buffer point for an EXIF orientation (1..8): how the stored pixels must be
 * turned to look upright. `w`, `h` are the upright size.
 */
inline void toRaw(int exif, float w, float h, float x, float y, float& rx, float& ry) {
  switch (exif) {
    case 2: rx = w - x; ry = y; break;
    case 3: rx = w - x; ry = h - y; break;
    case 4: rx = x; ry = h - y; break;
    case 5: rx = y; ry = x; break;
    case 6: rx = y; ry = w - x; break;
    case 7: rx = h - y; ry = w - x; break;
    case 8: rx = h - y; ry = x; break;
    default: rx = x; ry = y; break;
  }
}

inline bool sideways(int exif) { return exif >= 5; }

/**
 * Walks an upright region (x, y, w, h in upright px) as an outW x outH grid and calls
 * fn(index, rawX, rawY, samples) with up to k*k raw sample positions per cell.
 */
template <typename Fn>
void walk(const Locked& b, int exif, float x, float y, float w, float h, int outW, int outH, int k, Fn fn) {
  float uw = sideways(exif) ? b.height() : b.width();
  float uh = sideways(exif) ? b.width() : b.height();
  int maxX = b.width() - 1, maxY = b.height() - 1;
  float cellW = w / outW, cellH = h / outH;
  int xs[16], ys[16];
  for (int oy = 0; oy < outH; oy++) {
    for (int ox = 0; ox < outW; ox++) {
      int n = 0;
      for (int j = 0; j < k; j++) {
        for (int i = 0; i < k; i++) {
          float ux = x + (ox + (i + 0.5f) / k) * cellW;
          float uy = y + (oy + (j + 0.5f) / k) * cellH;
          float rx, ry;
          toRaw(exif, uw, uh, ux, uy, rx, ry);
          xs[n] = std::clamp(static_cast<int>(rx), 0, maxX);
          ys[n] = std::clamp(static_cast<int>(ry), 0, maxY);
          n++;
        }
      }
      fn(oy * outW + ox, xs, ys, n);
    }
  }
}

AHardwareBuffer* asBuffer(jlong pointer) { return reinterpret_cast<AHardwareBuffer*>(static_cast<intptr_t>(pointer)); }

}  // namespace

extern "C" {

/** [raw width, raw height, AHardwareBuffer format], or [] below Android 10. */
JNIEXPORT jintArray JNICALL
Java_com_margelo_nitro_purelyocr_FrameBuffers_describe(JNIEnv* env, jclass, jlong pointer) {
  if (!hasApi() || pointer == 0) return env->NewIntArray(0);
  AHardwareBuffer_Desc desc{};
  api().describe(asBuffer(pointer), &desc);
  jint values[3] = {static_cast<jint>(desc.width), static_cast<jint>(desc.height), static_cast<jint>(desc.format)};
  jintArray out = env->NewIntArray(3);
  env->SetIntArrayRegion(out, 0, 3, values);
  return out;
}

/** Upright ARGB of the region, outW x outH, into `out`. Returns 0 or a negative status. */
JNIEXPORT jint JNICALL
Java_com_margelo_nitro_purelyocr_FrameBuffers_readArgb(JNIEnv* env, jclass, jlong pointer, jint exif,
    jfloat x, jfloat y, jfloat w, jfloat h, jint outW, jint outH, jintArray out) {
  if (!hasApi()) return kNoApi;
  Locked b(asBuffer(pointer), AHARDWAREBUFFER_USAGE_CPU_READ_OFTEN);
  if (b.status() != kOk) return b.status();
  jint* pixels = env->GetIntArrayElements(out, nullptr);
  // Average luma over a few samples when shrinking; chroma from the cell's first sample.
  int k = std::clamp(static_cast<int>(std::lround(w / outW)), 1, 3);
  walk(b, exif, x, y, w, h, outW, outH, k, [&](int index, const int* xs, const int* ys, int n) {
    int sum = 0;
    for (int s = 0; s < n; s++) sum += b.luma(xs[s], ys[s]);
    int c = n / 2;
    pixels[index] = b.argb(xs[c], ys[c], sum / n);
  });
  env->ReleaseIntArrayElements(out, pixels, 0);
  return kOk;
}

/** Upright luma of the region, outW x outH, 0..255, into `out`. Returns 0 or a negative status. */
JNIEXPORT jint JNICALL
Java_com_margelo_nitro_purelyocr_FrameBuffers_readLuma(JNIEnv* env, jclass, jlong pointer, jint exif,
    jfloat x, jfloat y, jfloat w, jfloat h, jint outW, jint outH, jfloatArray out) {
  if (!hasApi()) return kNoApi;
  Locked b(asBuffer(pointer), AHARDWAREBUFFER_USAGE_CPU_READ_OFTEN);
  if (b.status() != kOk) return b.status();
  jfloat* grid = env->GetFloatArrayElements(out, nullptr);
  int k = std::clamp(static_cast<int>(std::ceil(w / outW)), 1, 3);
  walk(b, exif, x, y, w, h, outW, outH, k, [&](int index, const int* xs, const int* ys, int n) {
    int sum = 0;
    for (int s = 0; s < n; s++) sum += b.luma(xs[s], ys[s]);
    grid[index] = static_cast<float>(sum) / n;
  });
  env->ReleaseFloatArrayElements(out, grid, 0);
  return kOk;
}

/**
 * A test frame: allocates a YUV 4:2:0 buffer (RGBA if the device cannot) of rawW x rawH and fills
 * it from upright ARGB pixels (uprightW x uprightH) stored the way `exif` describes.
 * Returns the AHardwareBuffer* or a status -1..-4 (pointers may be negative as jlong: tagged).
 */
JNIEXPORT jlong JNICALL
Java_com_margelo_nitro_purelyocr_FrameBuffers_createTestFrame(JNIEnv* env, jclass, jintArray argb,
    jint uprightW, jint uprightH, jint exif) {
  if (!hasApi()) return kNoApi;
  int rawW = sideways(exif) ? uprightH : uprightW;
  int rawH = sideways(exif) ? uprightW : uprightH;
  AHardwareBuffer_Desc desc{};
  desc.width = static_cast<uint32_t>(rawW);
  desc.height = static_cast<uint32_t>(rawH);
  desc.layers = 1;
  desc.usage = AHARDWAREBUFFER_USAGE_CPU_READ_OFTEN | AHARDWAREBUFFER_USAGE_CPU_WRITE_OFTEN;
  desc.format = AHARDWAREBUFFER_FORMAT_Y8Cb8Cr8_420;
  AHardwareBuffer* buffer = nullptr;
  if (api().allocate(&desc, &buffer) != 0) {
    desc.format = AHARDWAREBUFFER_FORMAT_R8G8B8A8_UNORM;
    if (api().allocate(&desc, &buffer) != 0) return kAllocFailed;
  }
  AHardwareBuffer_Desc actual{};
  api().describe(buffer, &actual);
  jint* src = env->GetIntArrayElements(argb, nullptr);
  // raw pixel -> upright pixel, by walking upright pixels and writing where they are stored.
  auto uprightOf = [&](int ux, int uy) { return src[uy * uprightW + ux]; };
  int status = kOk;
  if (isRgba(actual.format)) {
    void* data = nullptr;
    if (api().lock(buffer, AHARDWAREBUFFER_USAGE_CPU_WRITE_OFTEN, -1, nullptr, &data) != 0) {
      status = kLockFailed;
    } else {
      auto* base = static_cast<uint8_t*>(data);
      int stride = static_cast<int>(actual.stride) * 4;
      for (int uy = 0; uy < uprightH; uy++) {
        for (int ux = 0; ux < uprightW; ux++) {
          float rx, ry;
          toRaw(exif, uprightW, uprightH, ux + 0.5f, uy + 0.5f, rx, ry);
          uint8_t* p = base + static_cast<int>(ry) * stride + static_cast<int>(rx) * 4;
          int32_t c = uprightOf(ux, uy);
          p[0] = (c >> 16) & 0xff;
          p[1] = (c >> 8) & 0xff;
          p[2] = c & 0xff;
          p[3] = 0xff;
        }
      }
      api().unlock(buffer, nullptr);
    }
  } else {
    AHardwareBuffer_Planes planes{};
    if (api().lockPlanes(buffer, AHARDWAREBUFFER_USAGE_CPU_WRITE_OFTEN, -1, nullptr, &planes) != 0 || planes.planeCount < 3) {
      status = kLockFailed;
    } else {
      auto& py = planes.planes[0];
      auto& pu = planes.planes[1];
      auto& pv = planes.planes[2];
      for (int uy = 0; uy < uprightH; uy++) {
        for (int ux = 0; ux < uprightW; ux++) {
          float rx, ry;
          toRaw(exif, uprightW, uprightH, ux + 0.5f, uy + 0.5f, rx, ry);
          int x = static_cast<int>(rx), y = static_cast<int>(ry);
          int32_t c = uprightOf(ux, uy);
          int r = (c >> 16) & 0xff, g = (c >> 8) & 0xff, b = c & 0xff;
          static_cast<uint8_t*>(py.data)[y * py.rowStride + x * py.pixelStride] =
              static_cast<uint8_t>(std::clamp((77 * r + 150 * g + 29 * b) >> 8, 0, 255));
          if ((x & 1) == 0 && (y & 1) == 0) {
            int u = 128 + ((-43 * r - 85 * g + 128 * b) >> 8);
            int v = 128 + ((128 * r - 107 * g - 21 * b) >> 8);
            static_cast<uint8_t*>(pu.data)[(y / 2) * pu.rowStride + (x / 2) * pu.pixelStride] =
                static_cast<uint8_t>(std::clamp(u, 0, 255));
            static_cast<uint8_t*>(pv.data)[(y / 2) * pv.rowStride + (x / 2) * pv.pixelStride] =
                static_cast<uint8_t>(std::clamp(v, 0, 255));
          }
        }
      }
      api().unlock(buffer, nullptr);
    }
  }
  env->ReleaseIntArrayElements(argb, src, JNI_ABORT);
  if (status != kOk) {
    api().release(buffer);
    return status;
  }
  return static_cast<jlong>(reinterpret_cast<intptr_t>(buffer));
}

JNIEXPORT void JNICALL
Java_com_margelo_nitro_purelyocr_FrameBuffers_release(JNIEnv*, jclass, jlong pointer) {
  if (hasApi() && pointer != 0) api().release(asBuffer(pointer));
}

}  // extern "C"
