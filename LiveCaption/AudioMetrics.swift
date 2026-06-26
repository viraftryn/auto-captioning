import AVFoundation
import Accelerate

/// Format-agnostic audio helpers. We read the capture session's audio sample
/// buffers directly (Float32 or Int16, interleaved or not), so nothing in the
/// audio path depends on a sample-rate converter.
enum AudioMetrics {

    /// Mean of squared samples across all channels (≈ 0…1). Returns `nil` if the
    /// buffer carries no readable PCM data.
    static func meanSquare(of sampleBuffer: CMSampleBuffer) -> Float? {
        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc)?.pointee,
              CMSampleBufferGetNumSamples(sampleBuffer) > 0 else { return nil }

        var blockBuffer: CMBlockBuffer?
        var audioBufferList = AudioBufferList()
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: &audioBufferList,
            bufferListSize: MemoryLayout<AudioBufferList>.size,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &blockBuffer)
        guard status == noErr else { return nil }

        let buffers = UnsafeMutableAudioBufferListPointer(&audioBufferList)
        let isFloat = asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0
        let isSignedInt = asbd.mFormatFlags & kAudioFormatFlagIsSignedInteger != 0
        let bits = asbd.mBitsPerChannel

        var sumSquares: Float = 0
        var total = 0
        for buffer in buffers {
            guard let data = buffer.mData else { continue }
            let byteCount = Int(buffer.mDataByteSize)

            if isFloat && bits == 32 {
                let count = byteCount / MemoryLayout<Float>.size
                guard count > 0 else { continue }
                let ptr = data.assumingMemoryBound(to: Float.self)
                var ms: Float = 0
                vDSP_measqv(ptr, 1, &ms, vDSP_Length(count))
                sumSquares += ms * Float(count)
                total += count
            } else if isSignedInt && bits == 16 {
                let count = byteCount / MemoryLayout<Int16>.size
                guard count > 0 else { continue }
                let ptr = data.assumingMemoryBound(to: Int16.self)
                for i in 0..<count {
                    let v = Float(ptr[i]) / 32_768.0
                    sumSquares += v * v
                }
                total += count
            }
        }

        guard total > 0 else { return nil }
        return sumSquares / Float(total)
    }
}
