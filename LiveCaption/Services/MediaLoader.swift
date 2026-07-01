import AVFoundation

/// Decodes a recorded file's audio track into 16 kHz mono Float samples, and its
/// video frames into pixel buffers, for the offline analysis path.
enum MediaLoader {

    static let sampleRate: Double = 16_000

    /// Pull the whole audio track into memory as 16 kHz mono Float32.
    /// `AVAssetReader` resamples + downmixes via the output settings.
    static func loadAudio(url: URL) throws -> [Float] {
        let asset = AVURLAsset(url: url)
        guard let track = asset.tracks(withMediaType: .audio).first else {
            throw error("That file has no audio track.")
        }

        let reader = try AVAssetReader(asset: asset)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw error("Can't read this audio format.") }
        reader.add(output)

        guard reader.startReading() else {
            throw reader.error ?? error("Couldn't start reading audio.")
        }

        var samples: [Float] = []
        while let sampleBuffer = output.copyNextSampleBuffer() {
            if let block = CMSampleBufferGetDataBuffer(sampleBuffer) {
                let length = CMBlockBufferGetDataLength(block)
                var chunk = [Float](repeating: 0, count: length / MemoryLayout<Float>.size)
                chunk.withUnsafeMutableBytes { raw in
                    _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length,
                                                   destination: raw.baseAddress!)
                }
                samples.append(contentsOf: chunk)
            }
            CMSampleBufferInvalidate(sampleBuffer)
        }

        if reader.status == .failed { throw reader.error ?? error("Audio read failed.") }
        return samples
    }

    private static func error(_ message: String) -> NSError {
        NSError(domain: "MediaLoader", code: 1,
                userInfo: [NSLocalizedDescriptionKey: message])
    }
}
