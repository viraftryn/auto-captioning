import SwiftUI
import AppKit
import Accelerate

/// Renders a complex spectrogram to an image (time on X, frequency on Y, low
/// frequencies at the bottom), log-magnitude with a simple heat colormap.
enum SpectrogramImage {

    static func make(from spec: STFTProcessor.Spectrogram, maxWidth: Int = 900) -> NSImage? {
        let height = spec.bins / 2          // positive frequencies only
        let frames = spec.frameCount
        guard frames > 0, height > 0 else { return nil }

        let stride = max(1, frames / maxWidth)
        var columns: [[Float]] = []
        var globalMax: Float = -.greatestFiniteMagnitude

        var f = 0
        while f < frames {
            let mag = STFTProcessor.magnitude(real: spec.real[f], imag: spec.imag[f])
            var dB = [Float](repeating: 0, count: height)
            for k in 0..<height {
                let v = 20 * log10f(mag[k] + 1e-7)
                dB[k] = v
                if v > globalMax { globalMax = v }
            }
            columns.append(dB)
            f += stride
        }

        let width = columns.count
        let dynamicRange: Float = 80
        let minDB = globalMax - dynamicRange

        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for x in 0..<width {
            let dB = columns[x]
            for y in 0..<height {
                let norm = max(0, min(1, (dB[y] - minDB) / dynamicRange))
                let (r, g, b) = heat(norm)
                let row = height - 1 - y     // flip: low freq at bottom
                let idx = (row * width + x) * 4
                pixels[idx + 0] = r
                pixels[idx + 1] = g
                pixels[idx + 2] = b
                pixels[idx + 3] = 255
            }
        }
        return image(from: &pixels, width: width, height: height)
    }

    /// Black → purple → orange → yellow.
    private static func heat(_ t: Float) -> (UInt8, UInt8, UInt8) {
        let r = min(1, max(0, 1.6 * t))
        let g = min(1, max(0, 1.6 * t - 0.6))
        let b = min(1, max(0, 0.7 - 1.4 * abs(t - 0.35)))
        return (UInt8(r * 255), UInt8(g * 255), UInt8(b * 255))
    }

    private static func image(from pixels: inout [UInt8], width: Int, height: Int) -> NSImage? {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let info = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let ctx = CGContext(data: &pixels, width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: width * 4,
                                  space: colorSpace, bitmapInfo: info),
              let cg = ctx.makeImage() else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: width, height: height))
    }
}
