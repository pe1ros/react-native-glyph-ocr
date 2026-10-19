import CoreGraphics
import CoreVideo
import Foundation

/** Camera frames (`CVPixelBufferRef`) read on the CPU: the luma grid of FrameMeter and test frames. */
enum FrameBuffers {
  static func pixelBuffer(_ pointer: UInt64) throws -> CVPixelBuffer {
    guard let raw = UnsafeRawPointer(bitPattern: UInt(pointer)) else {
      throw OcrError("frame-unsupported", "Null buffer pointer")
    }
    return Unmanaged<CVPixelBuffer>.fromOpaque(raw).takeUnretainedValue()
  }

  /**
   * Upright luma (0..255) of the upright region (x, y, w, h), resampled to outW x outH with a few
   * samples per cell. YUV buffers use their Y plane, BGRA ones a weighted sum.
   */
  static func luma(_ buffer: CVPixelBuffer, _ exif: Int, _ area: RectD, _ outW: Int, _ outH: Int) throws -> [Float] {
    let format = CVPixelBufferGetPixelFormatType(buffer)
    let yuv = [
      kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
      kCVPixelFormatType_420YpCbCr8Planar, kCVPixelFormatType_420YpCbCr8PlanarFullRange,
    ].contains(format)
    guard yuv || format == kCVPixelFormatType_32BGRA else {
      throw OcrError("frame-unsupported", "Unsupported pixel format \(fourCC(format)); use pixelFormat 'yuv'", ["format": fourCC(format)])
    }
    CVPixelBufferLockBaseAddress(buffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    let rawW = CVPixelBufferGetWidth(buffer)
    let rawH = CVPixelBufferGetHeight(buffer)
    let base = yuv ? CVPixelBufferGetBaseAddressOfPlane(buffer, 0) : CVPixelBufferGetBaseAddress(buffer)
    guard let base else { throw OcrError("frame-unsupported", "The frame has no CPU memory") }
    let stride = yuv ? CVPixelBufferGetBytesPerRowOfPlane(buffer, 0) : CVPixelBufferGetBytesPerRow(buffer)
    let p = base.assumingMemoryBound(to: UInt8.self)
    let uw = Double(Exif.sideways(exif) ? rawH : rawW)
    let uh = Double(Exif.sideways(exif) ? rawW : rawH)
    let k = Swift.max(1, Swift.min(3, Int((area.w / Double(outW)).rounded(.up))))
    // Each raw coordinate depends on one upright coordinate only (EXIF turns are axis swaps and
    // flips), so the sample positions are two small tables instead of a transform per sample.
    let swap = Exif.sideways(exif)
    func index(_ u: Double, _ isX: Bool) -> Int {
      let r = isX ? Exif.toRaw(exif, uw, uh, u, 0) : Exif.toRaw(exif, uw, uh, 0, u)
      // The upright x feeds the raw x unless the image is sideways, and vice versa.
      let v = isX == !swap ? r.x : r.y
      let limit = (isX == !swap ? rawW : rawH) - 1
      return Swift.min(limit, Swift.max(0, Int(v)))
    }
    let cols = (0..<(outW * k)).map { c in index(area.x + (Double(c / k) + (Double(c % k) + 0.5) / Double(k)) * area.w / Double(outW), true) }
    let rows = (0..<(outH * k)).map { r in index(area.y + (Double(r / k) + (Double(r % k) + 0.5) / Double(k)) * area.h / Double(outH), false) }
    var out = [Float](repeating: 0, count: outW * outH)
    let samples = Float(k * k)
    out.withUnsafeMutableBufferPointer { grid in
      cols.withUnsafeBufferPointer { cx in
        rows.withUnsafeBufferPointer { ry in
          for oy in 0..<outH {
            for ox in 0..<outW {
              var sum = 0
              for j in 0..<k {
                let r = ry[oy * k + j]
                for i in 0..<k {
                  let c = cx[ox * k + i]
                  let x = swap ? r : c
                  let y = swap ? c : r
                  if yuv {
                    sum += Int(p[y * stride + x])
                  } else {
                    let q = p + y * stride + x * 4
                    sum += (29 * Int(q[0]) + 150 * Int(q[1]) + 77 * Int(q[2])) >> 8
                  }
                }
              }
              grid[oy * outW + ox] = Float(sum) / samples
            }
          }
        }
      }
    }
    return out
  }

  static func fourCC(_ code: OSType) -> String {
    let bytes = [UInt8((code >> 24) & 0xff), UInt8((code >> 16) & 0xff), UInt8((code >> 8) & 0xff), UInt8(code & 0xff)]
    return String(bytes: bytes, encoding: .ascii) ?? "\(code)"
  }

  /**
   * A 420f buffer (what the camera gives with pixelFormat 'yuv') holding an upright image stored
   * as `exif` says. Returned retained: release it with `release`.
   */
  static func testFrame(_ image: CGImage, _ exif: Int) throws -> UInt64 {
    // Even sides, as camera buffers have (the top left part of an odd-sized photo).
    let w = image.width & ~1
    let h = image.height & ~1
    guard w >= 2, h >= 2 else { throw OcrError("invalid-argument", "The photo is too small for a frame") }
    guard let ctx = ImageSource.context(w, h) else { throw OcrError("out-of-memory", "Cannot allocate \(w)x\(h)") }
    ctx.draw(image, in: CGRect(x: 0, y: h - image.height, width: image.width, height: image.height))
    guard let rgba = ctx.data?.assumingMemoryBound(to: UInt8.self) else { throw OcrError("internal", "No pixels") }
    let rgbaStride = ctx.bytesPerRow
    let rawW = Exif.sideways(exif) ? h : w
    let rawH = Exif.sideways(exif) ? w : h
    var out: CVPixelBuffer?
    let attrs: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
    guard CVPixelBufferCreate(nil, rawW, rawH, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, attrs as CFDictionary, &out) == kCVReturnSuccess,
      let buffer = out
    else { throw OcrError("out-of-memory", "Cannot allocate a \(rawW)x\(rawH) pixel buffer") }
    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    guard let yBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 0), let uvBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 1) else {
      throw OcrError("internal", "No planes")
    }
    let yp = yBase.assumingMemoryBound(to: UInt8.self)
    let uvp = uvBase.assumingMemoryBound(to: UInt8.self)
    let yStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
    let uvStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
    for uy in 0..<h {
      for ux in 0..<w {
        let r = Exif.toRaw(exif, Double(w), Double(h), Double(ux) + 0.5, Double(uy) + 0.5)
        let x = Int(r.x)
        let y = Int(r.y)
        let q = rgba + uy * rgbaStride + ux * 4
        let R = Int(q[0]), G = Int(q[1]), B = Int(q[2])
        yp[y * yStride + x] = UInt8(Swift.min(255, Swift.max(0, (77 * R + 150 * G + 29 * B) >> 8)))
        if x & 1 == 0 && y & 1 == 0 {
          let u = 128 + ((-43 * R - 85 * G + 128 * B) >> 8)
          let v = 128 + ((128 * R - 107 * G - 21 * B) >> 8)
          uvp[(y / 2) * uvStride + (x / 2) * 2] = UInt8(Swift.min(255, Swift.max(0, u)))
          uvp[(y / 2) * uvStride + (x / 2) * 2 + 1] = UInt8(Swift.min(255, Swift.max(0, v)))
        }
      }
    }
    return UInt64(UInt(bitPattern: Unmanaged.passRetained(buffer).toOpaque()))
  }

  static func release(_ pointer: UInt64) {
    guard let raw = UnsafeRawPointer(bitPattern: UInt(pointer)) else { return }
    Unmanaged<CVPixelBuffer>.fromOpaque(raw).release()
  }
}

final class HybridOcrFrameMeter: HybridOcrFrameMeterSpec {
  private let lock = NSLock()
  private var previous: [Float]?

  func measure(nativeBufferPointer: UInt64, orientation: FrameOrientation, roi: OcrRect?) throws -> FrameQuality {
    let buffer = try FrameBuffers.pixelBuffer(nativeBufferPointer)
    let exif = Exif.of(orientation, mirrored: false)
    let rawW = CVPixelBufferGetWidth(buffer)
    let rawH = CVPixelBufferGetHeight(buffer)
    let w = Exif.sideways(exif) ? rawH : rawW
    let h = Exif.sideways(exif) ? rawW : rawH
    let area = try Regions.resolve(roi, w, h) ?? RectD(x: 0, y: 0, w: Double(w), h: Double(h))
    let (gw, gh) = FrameMetrics.gridSize(area.w, area.h)
    let grid = try FrameBuffers.luma(buffer, exif, area, gw, gh)
    return lock.locked {
      let q = FrameMetrics.measure(grid, gw, gh, previous)
      previous = grid
      return q
    }
  }

  func reset() throws {
    lock.locked { previous = nil }
  }
}
