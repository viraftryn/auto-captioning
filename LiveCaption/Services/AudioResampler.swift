import AVFoundation
import CoreMedia

/// Converts capture-session audio sample buffers (whatever PCM format the mic
/// delivers — typically 44.1/48 kHz Float32 or Int16, mono or stereo) into
/// **16 kHz mono Float32**, matching `MediaLoader`'s offline output so the live
/// and Analyze-File paths hand Whisper identical audio.
///
/// An `AVAudioConverter` is built lazily from the first buffer's actual format
/// (and rebuilt if the format ever changes), so we get proper anti-aliased
/// resampling + down-mix without hard-coding the hardware rate. Used only on the
/// capture audio queue (serial), so it needs no locking.
final class AudioResampler {

    private let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                             sampleRate: 16_000, channels: 1,
                                             interleaved: false)!
    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?

    /// Returns the buffer's audio as 16 kHz mono Float32, or `[]` if it can't be
    /// read/converted (the caller just skips that buffer).
    func resample(_ sampleBuffer: CMSampleBuffer) -> [Float] {
        let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frameCount > 0,
              let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) else {
            return []
        }

        // (Re)build the converter on the first buffer or if the mic format changes.
        if inputFormat == nil
            || inputFormat!.sampleRate != asbd.pointee.mSampleRate
            || inputFormat!.channelCount != asbd.pointee.mChannelsPerFrame {
            guard let inFormat = AVAudioFormat(streamDescription: asbd) else { return [] }
            inputFormat = inFormat
            converter = AVAudioConverter(from: inFormat, to: outputFormat)
        }
        guard let converter, let inputFormat else { return [] }

        // Wrap the sample buffer's PCM into an AVAudioPCMBuffer of the input format.
        guard let inBuffer = AVAudioPCMBuffer(pcmFormat: inputFormat,
                                              frameCapacity: AVAudioFrameCount(frameCount)) else { return [] }
        inBuffer.frameLength = AVAudioFrameCount(frameCount)
        let copyStatus = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer, at: 0, frameCount: Int32(frameCount),
            into: inBuffer.mutableAudioBufferList)
        guard copyStatus == noErr else { return [] }

        // Room for the resampled frames, plus headroom for converter latency.
        let ratio = outputFormat.sampleRate / inputFormat.sampleRate
        let outCapacity = AVAudioFrameCount(Double(frameCount) * ratio) + 1024
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat,
                                               frameCapacity: outCapacity) else { return [] }

        var fed = false
        var convError: NSError?
        let result = converter.convert(to: outBuffer, error: &convError) { _, inStatus in
            if fed { inStatus.pointee = .noDataNow; return nil }
            fed = true
            inStatus.pointee = .haveData
            return inBuffer
        }
        guard result != .error, convError == nil,
              let channel = outBuffer.floatChannelData else { return [] }

        let n = Int(outBuffer.frameLength)
        guard n > 0 else { return [] }
        return Array(UnsafeBufferPointer(start: channel[0], count: n))
    }
}
