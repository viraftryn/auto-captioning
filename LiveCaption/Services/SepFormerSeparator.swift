import CoreML
import Accelerate
import Foundation

/// On-device 2-speaker separation with **SepFormer**
/// (`speechbrain/sepformer-whamr16k`) converted to CoreML — the learned,
/// *blind* replacement for the old harmonic comb mask.
///
/// The CoreML model is traced at a **fixed** window length `T`
/// (`mix[1,T] → sources[1,T,2]`), so a long clip is processed in overlapping
/// `T`-sample windows and stitched back together. Two consequences:
///
///  • **Blind / arbitrary order.** SepFormer emits two streams with no notion of
///    "which speaker," and the order can differ *per window*. We keep stream 0 =
///    the same physical voice across windows by correlating each window's leading
///    overlap region against the previous window's trailing one and swapping when
///    the cross-correlation says so (`alignSwap`).
///  • **Stitching.** Each separated window is tapered (raised-cosine ramps over the
///    overlap) and overlap-added, then normalised by the summed taper — an
///    equal-power cross-fade that avoids clicks at window seams.
///
/// The model is loaded by compiling the bundled `.mlpackage` at runtime (cached),
/// so the app builds and runs even before `tools/sepformer/convert_sepformer.py`
/// has produced the artifact — it just reports `.modelMissing` until then.
final class SepFormerSeparator {

    enum SeparationError: LocalizedError {
        case modelMissing
        case modelLoadFailed(String)
        case inferenceFailed(String)

        var errorDescription: String? {
            switch self {
            case .modelMissing:
                return "SepFormer model isn't bundled yet. Run tools/sepformer/convert_sepformer.py, "
                     + "then rebuild (xcodegen generate)."
            case .modelLoadFailed(let m): return "Couldn't load the SepFormer model: \(m)"
            case .inferenceFailed(let m): return "SepFormer inference failed: \(m)"
            }
        }
    }

    let sourceCount = 2
    let windowLength: Int          // T — read from the model's input shape
    let overlap: Int               // samples shared between consecutive windows

    private let model: MLModel
    private let inputName: String
    private let outputName: String
    private lazy var taper = Self.taperWindow(length: windowLength, ramp: overlap)

    /// Loads (and, first time, compiles) the bundled model. Throws `.modelMissing`
    /// if the artifact hasn't been produced yet — callers should surface that.
    init(overlap: Int = 16_000) throws {
        guard let packageURL = Self.bundledModelURL() else { throw SeparationError.modelMissing }
        do {
            let compiled = try Self.compiledModelURL(for: packageURL)
            let config = MLModelConfiguration()
            config.computeUnits = .all
            self.model = try MLModel(contentsOf: compiled, configuration: config)
        } catch let e as SeparationError {
            throw e
        } catch {
            throw SeparationError.modelLoadFailed(error.localizedDescription)
        }

        let desc = model.modelDescription
        guard let input = desc.inputDescriptionsByName.first,
              let shape = input.value.multiArrayConstraint?.shape,
              let lastDim = shape.last?.intValue,
              let output = desc.outputDescriptionsByName.first else {
            throw SeparationError.modelLoadFailed("unexpected model interface")
        }
        self.inputName = input.key
        self.outputName = output.key
        self.windowLength = lastDim
        self.overlap = min(max(0, overlap), lastDim / 2)
    }

    // MARK: - Separation

    /// Separate `audio` (mono 16 kHz) into `sourceCount` full-length streams, in a
    /// consistent (but still arbitrary — see `SourceAssignment`) order.
    func separate(_ audio: [Float]) throws -> [[Float]] {
        let n = audio.count
        guard n > 0 else { return Array(repeating: [], count: sourceCount) }

        let hop = max(1, windowLength - overlap)
        var out = Array(repeating: [Float](repeating: 0, count: n), count: sourceCount)
        var wsum = [Float](repeating: 0, count: n)

        var prev: [[Float]]?           // previous window's aligned streams (length T)
        var start = 0
        while start < n {
            let valid = min(windowLength, n - start)
            var window = [Float](repeating: 0, count: windowLength)
            window.withUnsafeMutableBufferPointer { dst in
                audio.withUnsafeBufferPointer { src in
                    dst.baseAddress!.update(from: src.baseAddress! + start, count: valid)
                }
            }

            var streams = try infer(window)               // [s0, s1], each length T

            // Keep stream order consistent with the previous window.
            if let prev, alignSwap(current: streams, previous: prev) {
                streams.swapAt(0, 1)
            }
            prev = streams

            // Tapered overlap-add into the valid region only (skip zero padding).
            for s in 0..<sourceCount {
                out[s].withUnsafeMutableBufferPointer { o in
                    streams[s].withUnsafeBufferPointer { src in
                        for t in 0..<valid { o[start + t] += src[t] * taper[t] }
                    }
                }
            }
            wsum.withUnsafeMutableBufferPointer { w in
                for t in 0..<valid { w[start + t] += taper[t] }
            }

            start += hop
        }

        // Normalise by the accumulated taper (equal-power cross-fade).
        for s in 0..<sourceCount {
            out[s].withUnsafeMutableBufferPointer { o in
                for i in 0..<n where wsum[i] > 1e-6 { o[i] /= wsum[i] }
            }
        }
        return out
    }

    /// Should the current window's two streams be swapped to match the previous
    /// window? Compares each window's leading overlap region (same time span) by
    /// normalised cross-correlation and picks the higher-scoring pairing.
    private func alignSwap(current: [[Float]], previous: [[Float]]) -> Bool {
        guard overlap > 0 else { return false }
        let tail = windowLength - overlap
        let curHead0 = Array(current[0][0..<overlap])
        let curHead1 = Array(current[1][0..<overlap])
        let prevTail0 = Array(previous[0][tail..<windowLength])
        let prevTail1 = Array(previous[1][tail..<windowLength])
        let keep  = Self.ncc(curHead0, prevTail0) + Self.ncc(curHead1, prevTail1)
        let swapd = Self.ncc(curHead0, prevTail1) + Self.ncc(curHead1, prevTail0)
        return swapd > keep
    }

    // MARK: - CoreML inference

    private func infer(_ window: [Float]) throws -> [[Float]] {
        do {
            let input = try MLMultiArray(shape: [1, NSNumber(value: windowLength)], dataType: .float32)
            window.withUnsafeBufferPointer { src in
                let dst = input.dataPointer.bindMemory(to: Float.self, capacity: windowLength)
                dst.update(from: src.baseAddress!, count: windowLength)
            }
            let provider = try MLDictionaryFeatureProvider(
                dictionary: [inputName: MLFeatureValue(multiArray: input)])
            let result = try model.prediction(from: provider)
            guard let array = result.featureValue(for: outputName)?.multiArrayValue else {
                throw SeparationError.inferenceFailed("model returned no '\(outputName)' output")
            }
            return deinterleave(array)
        } catch let e as SeparationError {
            throw e
        } catch {
            throw SeparationError.inferenceFailed(error.localizedDescription)
        }
    }

    /// Split the `[1, T, 2]` output tensor into `sourceCount` contiguous streams,
    /// honouring the array's strides. Fast path for float32 (the model's declared
    /// output dtype); a slow `NSNumber` fallback covers anything else.
    private func deinterleave(_ array: MLMultiArray) -> [[Float]] {
        let strides = array.strides.map { $0.intValue }
        // shape [1, T, 2] → strides [_, timeStride, sourceStride]
        let timeStride = strides.count >= 3 ? strides[strides.count - 2] : sourceCount
        let srcStride  = strides.count >= 3 ? strides[strides.count - 1] : 1
        var out = Array(repeating: [Float](repeating: 0, count: windowLength), count: sourceCount)

        if array.dataType == .float32 {
            let ptr = array.dataPointer.bindMemory(to: Float.self, capacity: array.count)
            for s in 0..<sourceCount {
                out[s].withUnsafeMutableBufferPointer { dst in
                    for t in 0..<windowLength { dst[t] = ptr[t * timeStride + s * srcStride] }
                }
            }
        } else {
            for s in 0..<sourceCount {
                for t in 0..<windowLength {
                    out[s][t] = array[t * timeStride + s * srcStride].floatValue
                }
            }
        }
        return out
    }

    // MARK: - Model loading helpers

    private static func bundledModelURL() -> URL? {
        Bundle.main.url(forResource: "SepFormer", withExtension: "mlpackage", subdirectory: "Models")
            ?? Bundle.main.url(forResource: "SepFormer", withExtension: "mlpackage")
    }

    /// Compile the `.mlpackage` to a `.mlmodelc`, caching it in Application Support
    /// so we only pay the (multi-second) compile once per model version.
    private static func compiledModelURL(for packageURL: URL) throws -> URL {
        let fm = FileManager.default
        let support = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                 appropriateFor: nil, create: true)
        let dir = support.appendingPathComponent("LiveCaption", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let cached = dir.appendingPathComponent("SepFormer.mlmodelc")

        let pkgDate = (try? packageURL.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate
        let cacheDate = (try? cached.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate
        if fm.fileExists(atPath: cached.path), let pkgDate, let cacheDate, cacheDate >= pkgDate {
            return cached
        }

        let compiled = try MLModel.compileModel(at: packageURL)
        if fm.fileExists(atPath: cached.path) { try? fm.removeItem(at: cached) }
        do { try fm.moveItem(at: compiled, to: cached) }
        catch { return compiled }   // fall back to the temp URL if caching failed
        return cached
    }

    // MARK: - DSP helpers

    /// Raised-cosine taper: ramps up over the first `ramp` samples, down over the
    /// last `ramp`, flat 1 in the middle. Strictly positive so normalisation never
    /// loses the signal at the very edges.
    private static func taperWindow(length: Int, ramp: Int) -> [Float] {
        var w = [Float](repeating: 1, count: length)
        guard ramp > 0, ramp * 2 <= length else { return w }
        for i in 0..<ramp {
            let v = Float(0.5 - 0.5 * cos(Double.pi * Double(i + 1) / Double(ramp + 1)))
            w[i] = v
            w[length - 1 - i] = v
        }
        return w
    }

    /// Normalised cross-correlation (cosine similarity) of two equal-length frames,
    /// the same voicing measure used in `PitchEstimator`.
    private static func ncc(_ a: [Float], _ b: [Float]) -> Float {
        let m = vDSP_Length(min(a.count, b.count))
        guard m > 0 else { return 0 }
        var dot: Float = 0, ea: Float = 0, eb: Float = 0
        a.withUnsafeBufferPointer { ap in
            b.withUnsafeBufferPointer { bp in
                vDSP_dotpr(ap.baseAddress!, 1, bp.baseAddress!, 1, &dot, m)
                vDSP_dotpr(ap.baseAddress!, 1, ap.baseAddress!, 1, &ea, m)
                vDSP_dotpr(bp.baseAddress!, 1, bp.baseAddress!, 1, &eb, m)
            }
        }
        return dot / ((ea * eb).squareRoot() + 1e-9)
    }
}
