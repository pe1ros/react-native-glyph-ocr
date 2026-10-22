#if GLYPHOCR_PADDLE
import CoreGraphics
import Foundation
import onnxruntime_objc

/**
 * PP-OCRv5/v6 text detection (DB) + recognition (CTC) on ONNX Runtime, with the optional text
 * line orientation classifier. The same pipeline as PaddleOcr.kt on Android; see TextLines.swift
 * for the line finder.
 */
final class PaddleOcr {
  struct Options {
    var detLimitSide: Int
    var detThresh: Float
    var boxThresh: Float
    var unclipRatio: Float
    var dropScore: Float
    var textlineOrientation: Bool
  }

  /** A word: `start`..`end` is its share (0..1) of the line's length, from CTC character positions. */
  struct Word {
    let text: String
    let score: Float
    let start: Float
    let end: Float
  }

  /** Bounds in the input image, px; `geometry` maps points along the line to the image. */
  struct Line {
    let text: String
    let score: Float
    let left: Float
    let top: Float
    let right: Float
    let bottom: Float
    let geometry: TextLine
    let words: [Word]
  }

  struct Output {
    let lines: [Line]
    let detMs: Double
    let recMs: Double
    let detWidth: Int
    let detHeight: Int
    let boxCount: Int
  }

  static let runtimeName = "onnxruntime-objc"
  private static let recH = 48
  private static let recMinW = 320
  private static let recMaxW = 3200
  private static let clsW = 160
  private static let clsH = 80
  private static let mean: [Float] = [0.485, 0.456, 0.406]
  private static let std: [Float] = [0.229, 0.224, 0.225]

  private let env: ORTEnv
  private let det: ORTSession
  private let rec: ORTSession
  private let cls: ORTSession?
  /** CTC classes: 0 is blank, then the dictionary, then a space. */
  private let classes: [String]

  init(detector: URL, recognizer: URL, orientation: URL?, dictionary: [String], threads: Int) throws {
    let env = try ORTEnv(loggingLevel: .error)
    self.env = env
    det = try Self.session(env, detector, threads)
    rec = try Self.session(env, recognizer, threads)
    // One thread: the classifier is tiny, more threads only add synchronization.
    cls = try orientation.map { try Self.session(env, $0, 1) }
    classes = [""] + dictionary + [" "]
  }

  private static func session(_ env: ORTEnv, _ url: URL, _ threads: Int) throws -> ORTSession {
    let options = try ORTSessionOptions()
    try options.setGraphOptimizationLevel(.all)
    if threads > 0 { try options.setIntraOpNumThreads(Int32(threads)) }
    return try ORTSession(env: env, modelPath: url.path, sessionOptions: options)
  }

  /** `checkCancelled` runs between lines and throws to stop. */
  func run(_ image: CGImage, _ o: Options, _ checkCancelled: () throws -> Void) throws -> Output {
    let t0 = DispatchTime.now().uptimeNanoseconds
    let srcW = image.width
    let srcH = image.height

    // --- Detection: PaddleOCR feeds BGR with ImageNet mean/std in RGB order.
    let ratio = Swift.min(1, Float(o.detLimitSide) / Float(Swift.max(srcW, srcH)))
    let detW = Swift.max(32, Int((Float(srcW) * ratio / 32).rounded()) * 32)
    let detH = Swift.max(32, Int((Float(srcH) * ratio / 32).rounded()) * 32)
    let detPixels = try Self.pixels(image, detW, detH)
    let plane = detW * detH
    var detInput = [Float](repeating: 0, count: 3 * plane)
    for i in 0..<plane {
      let p = detPixels[i]
      detInput[i] = (Float(p & 0xff) / 255 - Self.mean[0]) / Self.std[0]
      detInput[plane + i] = (Float((p >> 8) & 0xff) / 255 - Self.mean[1]) / Self.std[1]
      detInput[2 * plane + i] = (Float((p >> 16) & 0xff) / 255 - Self.mean[2]) / Self.std[2]
    }
    let (prob, _) = try Self.infer(det, detInput, [1, 3, detH, detW])
    let found = TextLineFinder.find(
      prob, detW, detH, srcW, srcH, thresh: o.detThresh, boxThresh: o.boxThresh, unclipRatio: o.unclipRatio)
    let t1 = DispatchTime.now().uptimeNanoseconds

    // --- Recognition, one line at a time.
    let src = try Self.pixels(image, srcW, srcH)
    // A label photographed upside down is upside down as a whole, and the classifier is unsure
    // about single lines: the decision is one vote of all lines, weighted by their length.
    var upsideDown = false
    if o.textlineOrientation, let cls {
      var weight: Float = 0
      var sum: Float = 0
      for line in found where !line.vertical && line.lengthSrc >= 1 && line.heightSrc >= 1 {
        sum += line.lengthSrc * (try Self.upsideDownProbability(cls, src, srcW, srcH, line))
        weight += line.lengthSrc
      }
      upsideDown = weight > 0 && sum / weight > 0.5
    }
    var lines: [Line] = []
    for detected in found {
      try checkCancelled()
      let line = upsideDown && !detected.vertical ? detected.flipped() : detected
      guard let recognized = try recognize(src, srcW, srcH, line) else { continue }
      if recognized.score >= o.dropScore && !recognized.text.trimmingCharacters(in: .whitespaces).isEmpty {
        lines.append(Self.bounds(line, recognized, srcW, srcH))
      }
    }
    let t2 = DispatchTime.now().uptimeNanoseconds
    return Output(
      lines: lines, detMs: Double(t1 - t0) / 1e6, recMs: Double(t2 - t1) / 1e6, detWidth: detW, detHeight: detH,
      boxCount: found.count)
  }

  private struct Decoded {
    let text: String
    let score: Float
    let words: [Word]
  }

  private func recognize(_ src: [UInt32], _ srcW: Int, _ srcH: Int, _ line: TextLine) throws -> Decoded? {
    var length = line.lengthSrc
    var height = line.heightSrc
    if line.vertical { swap(&length, &height) }
    if length < 1 || height < 1 { return nil }
    let outW = Swift.min(Self.recMaxW, Swift.max(1, Int((Float(Self.recH) * length / height).rounded(.up))))
    let padW = Swift.max(Self.recMinW, outW)
    let input = Self.sampleLine(src, srcW, srcH, line, outW, padW)
    let (probs, shape) = try Self.infer(rec, input, [1, 3, Self.recH, padW])
    let steps = shape[1]
    let numClasses = shape[2]
    // One CTC step covers padW / steps input columns; the text fills the first outW of them.
    return ctcDecode(probs, steps, numClasses, Float(padW) / Float(steps) / Float(outW))
  }

  /**
   * Greedy CTC: argmax per step, merge repeats, drop blanks; score = mean prob of kept chars.
   * Words are runs of non-space characters; `stepShare` is one step's share of the line length.
   */
  private func ctcDecode(_ probs: [Float], _ steps: Int, _ numClasses: Int, _ stepShare: Float) -> Decoded {
    var text = ""
    var scoreSum: Float = 0
    var kept = 0
    var prev = -1
    var words: [Word] = []
    var word = ""
    var wordScore: Float = 0
    var wordFirst = 0
    var wordLast = 0
    func endWord() {
      if word.isEmpty { return }
      words.append(Word(
        text: word, score: wordScore / Float(word.count),
        start: Swift.min(Swift.max(Float(wordFirst) * stepShare, 0), 1),
        end: Swift.min(Swift.max(Float(wordLast + 1) * stepShare, 0), 1)))
      word = ""
      wordScore = 0
    }
    for t in 0..<steps {
      let base = t * numClasses
      var best = 0
      var bestP = probs[base]
      for k in 1..<numClasses where probs[base + k] > bestP {
        bestP = probs[base + k]
        best = k
      }
      if best != 0 && best != prev && best < classes.count {
        let ch = classes[best]
        text += ch
        scoreSum += bestP
        kept += 1
        if ch.trimmingCharacters(in: .whitespaces).isEmpty {
          endWord()
        } else {
          if word.isEmpty { wordFirst = t }
          word += ch
          wordScore += bestP
          wordLast = t
        }
      } else if best != 0 && best == prev && !word.isEmpty {
        wordLast = t  // a repeated step still belongs to the character
      }
      prev = best
    }
    endWord()
    return Decoded(text: text, score: kept == 0 ? 0 : scoreSum / Float(kept), words: words)
  }

  /**
   * The recognizer input [3, 48, padW]: BGR, (x/255 - 0.5) / 0.5, zero right padding, sampled
   * straight from the source pixels along the line. Supersamples when shrinking.
   */
  private static func sampleLine(_ src: [UInt32], _ srcW: Int, _ srcH: Int, _ line: TextLine, _ outW: Int, _ padW: Int) -> [Float] {
    var length = line.lengthSrc
    var height = line.heightSrc
    if line.vertical { swap(&length, &height) }
    let scale = Swift.max(length / Float(outW), height / Float(recH))
    let ss = Swift.min(4, Swift.max(1, Int((scale - 0.5).rounded(.up))))
    let inv = 1 / Float(ss * ss)
    let plane = recH * padW
    var out = [Float](repeating: 0, count: 3 * plane)
    let du = line.u1 - line.u0
    let h2 = 2 * line.halfHeight
    // Output columns run along the text (u); rows run across it (v). Vertical lines read down the
    // image with their top facing +x, as after PaddleOCR's rot90 crop.
    let cols = outW * ss
    var us = [Float](repeating: 0, count: cols)
    var vTop = [Float](repeating: 0, count: cols)
    for k in 0..<cols {
      let u = line.u0 + (Float(k) + 0.5) / Float(cols) * du
      us[k] = u
      vTop[k] = line.vertical ? line.centerAt(u) + line.halfHeight : line.centerAt(u) - line.halfHeight
    }
    let vStep = line.vertical ? -h2 : h2
    for j in 0..<recH {
      for i in 0..<outW {
        var b: Float = 0
        var g: Float = 0
        var r: Float = 0
        for a in 0..<ss {
          let k = i * ss + a
          let u = us[k]
          for c in 0..<ss {
            let fj = (Float(j) + (Float(c) + 0.5) / Float(ss)) / Float(recH)
            let v = vTop[k] + fj * vStep
            let px = bilinear(src, srcW, srcH, line.srcX(u, v), line.srcY(u, v))
            b += px.0
            g += px.1
            r += px.2
          }
        }
        let idx = j * padW + i
        out[idx] = (b * inv / 255 - 0.5) / 0.5
        out[plane + idx] = (g * inv / 255 - 0.5) / 0.5
        out[2 * plane + idx] = (r * inv / 255 - 0.5) / 0.5
      }
    }
    return out
  }

  /**
   * PP-LCNet textline orientation: the probability that the line is upside down, from the middle
   * of the line at its own proportions (160 × 80, about two line heights long; BGR, ImageNet
   * mean/std, as PaddleOCR feeds it).
   */
  private static func upsideDownProbability(_ cls: ORTSession, _ src: [UInt32], _ srcW: Int, _ srcH: Int, _ line: TextLine) throws -> Float {
    let plane = clsH * clsW
    var input = [Float](repeating: 0, count: 3 * plane)
    let h2 = 2 * line.halfHeight
    let uc = (line.u0 + line.u1) / 2
    let half = h2 * Float(clsW) / Float(clsH) / 2
    let ua = Swift.max(line.u0, uc - half)
    let ub = Swift.min(line.u1, uc + half)
    for j in 0..<clsH {
      for i in 0..<clsW {
        let u = ua + (Float(i) + 0.5) / Float(clsW) * (ub - ua)
        let v = line.centerAt(u) - line.halfHeight + (Float(j) + 0.5) / Float(clsH) * h2
        let px = bilinear(src, srcW, srcH, line.srcX(u, v), line.srcY(u, v))
        let idx = j * clsW + i
        input[idx] = (px.0 / 255 - mean[0]) / std[0]
        input[plane + idx] = (px.1 / 255 - mean[1]) / std[1]
        input[2 * plane + idx] = (px.2 / 255 - mean[2]) / std[2]
      }
    }
    let (p, _) = try infer(cls, input, [1, 3, clsH, clsW])
    return p[1]
  }

  /** Bilinear sample of BGRA pixels; returns (B, G, R). */
  @inline(__always)
  private static func bilinear(_ src: [UInt32], _ w: Int, _ h: Int, _ xIn: Float, _ yIn: Float) -> (Float, Float, Float) {
    let x = Swift.min(Swift.max(xIn, 0), Float(w - 1))
    let y = Swift.min(Swift.max(yIn, 0), Float(h - 1))
    let x0 = Int(x)
    let y0 = Int(y)
    let x1 = Swift.min(x0 + 1, w - 1)
    let y1 = Swift.min(y0 + 1, h - 1)
    let fx = x - Float(x0)
    let fy = y - Float(y0)
    let p00 = src[y0 * w + x0]
    let p10 = src[y0 * w + x1]
    let p01 = src[y1 * w + x0]
    let p11 = src[y1 * w + x1]
    func ch(_ shift: UInt32) -> Float {
      let a = Float((p00 >> shift) & 0xff) * (1 - fx) + Float((p10 >> shift) & 0xff) * fx
      let b = Float((p01 >> shift) & 0xff) * (1 - fx) + Float((p11 >> shift) & 0xff) * fx
      return a * (1 - fy) + b * fy
    }
    return (ch(0), ch(8), ch(16))
  }

  private static func bounds(_ line: TextLine, _ recognized: Decoded, _ srcW: Int, _ srcH: Int) -> Line {
    var left = Float.greatestFiniteMagnitude
    var top = Float.greatestFiniteMagnitude
    var right = -Float.greatestFiniteMagnitude
    var bottom = -Float.greatestFiniteMagnitude
    let du = line.u1 - line.u0
    for k in 0...4 {
      let u = line.u0 + du * Float(k) / 4
      let c = line.centerAt(u)
      for v in [c - line.halfHeight, c + line.halfHeight] {
        let x = line.srcX(u, v)
        let y = line.srcY(u, v)
        left = Swift.min(left, x)
        right = Swift.max(right, x)
        top = Swift.min(top, y)
        bottom = Swift.max(bottom, y)
      }
    }
    let w = Float(srcW)
    let h = Float(srcH)
    return Line(
      text: recognized.text, score: recognized.score,
      left: Swift.min(Swift.max(left, 0), w), top: Swift.min(Swift.max(top, 0), h),
      right: Swift.min(Swift.max(right, 0), w), bottom: Swift.min(Swift.max(bottom, 0), h),
      geometry: line, words: recognized.words)
  }

  /** The image drawn at w × h as 32-bit pixels, little-endian BGRA: B in the low byte, as on Android. */
  private static func pixels(_ image: CGImage, _ w: Int, _ h: Int) throws -> [UInt32] {
    var out = [UInt32](repeating: 0, count: w * h)
    let ok = out.withUnsafeMutableBytes { buf -> Bool in
      guard let ctx = CGContext(
        data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
      else { return false }
      ctx.interpolationQuality = .high
      ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
      return true
    }
    if !ok { throw OcrError("internal", "Cannot draw the image") }
    return out
  }

  /** One input tensor in, the first output out with its shape. */
  private static func infer(_ session: ORTSession, _ input: [Float], _ shape: [Int]) throws -> ([Float], [Int]) {
    let data = input.withUnsafeBytes { NSMutableData(bytes: $0.baseAddress, length: $0.count) }
    let value = try ORTValue(tensorData: data, elementType: .float, shape: shape.map { NSNumber(value: $0) })
    guard let inputName = try session.inputNames().first, let outputName = try session.outputNames().first else {
      throw OcrError("model-load-failed", "The model has no inputs or outputs")
    }
    let outputs = try session.run(withInputs: [inputName: value], outputNames: [outputName], runOptions: nil)
    guard let out = outputs[outputName] else { throw OcrError("internal", "No output \(outputName)") }
    let bytes = try out.tensorData() as Data
    let outShape = try out.tensorTypeAndShapeInfo().shape.map { $0.intValue }
    let floats = bytes.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    return (floats, outShape)
  }
}
#endif
