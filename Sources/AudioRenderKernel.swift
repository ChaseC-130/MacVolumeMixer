import AudioToolbox
import Accelerate

/// Allocation-free DSP used by every device graph.
///
/// The graph validates its stream formats before installing the IOProc, so this
/// kernel only handles native-endian Float32 PCM. It deliberately discovers
/// channels from each callback's AudioBufferList instead of assuming either
/// interleaved or deinterleaved buffers.
enum AudioRenderKernel {
    static let maximumGain: Float = 2.0

    private static let limiterKnee: Float = 0.98
    private static let limiterHeadroom: Float = 1.0 - limiterKnee

    static func render(
        input: UnsafePointer<AudioBufferList>,
        output: UnsafeMutablePointer<AudioBufferList>,
        targetVolumes: UnsafePointer<UnsafeMutablePointer<Float>>,
        smoothedVolumes: UnsafeMutablePointer<Float>,
        tapCount: Int,
        inputBaseOffset: Int,
        outLeftChannel: Int,
        outRightChannel: Int
    ) {
        let inList = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let outList = UnsafeMutableAudioBufferListPointer(output)

        clear(outList)

        let outputChannelCount = channelCount(outList)
        guard outputChannelCount > 0, tapCount > 0 else { return }

        let leftIndex = min(max(outLeftChannel, 0), outputChannelCount - 1)
        let rightIndex = min(max(outRightChannel, 0), outputChannelCount - 1)
        guard let outLeft = channel(outList, at: leftIndex),
              let outRight = channel(outList, at: rightIndex) else { return }

        for tapIndex in 0..<tapCount {
            let target = sanitizedGain(targetVolumes[tapIndex].pointee)
            let previous = sanitizedGain(smoothedVolumes[tapIndex])
            defer { smoothedVolumes[tapIndex] = target }

            let leftInputIndex = inputBaseOffset + tapIndex * 2
            guard let inLeft = channel(inList, at: leftInputIndex),
                  let inRight = channel(inList, at: leftInputIndex + 1) else { continue }

            let frames = min(inLeft.frames, inRight.frames, outLeft.frames, outRight.frames)
            guard frames > 0 else { continue }

            // A one-buffer linear ramp removes slider zipper noise and mute
            // clicks. Separate ramp state variables keep this correct even when
            // L/R live in buffers with different strides.
            var step = (target - previous) / Float(frames)
            var leftStart = previous
            vDSP_vrampmuladd(
                inLeft.base, vDSP_Stride(inLeft.stride),
                &leftStart, &step,
                outLeft.base, vDSP_Stride(outLeft.stride),
                vDSP_Length(frames)
            )

            var rightStart = previous
            vDSP_vrampmuladd(
                inRight.base, vDSP_Stride(inRight.stride),
                &rightStart, &step,
                outRight.base, vDSP_Stride(outRight.stride),
                vDSP_Length(frames)
            )
        }

        softLimit(outList)
    }

    /// Transparent below -0.18 dBFS, then smoothly approaches full scale.
    /// Unlike hard clipping this has no slope discontinuity at the knee, which
    /// substantially reduces the harsh high-frequency products of boosted or
    /// summed audio. Samples below the knee are bit-for-bit unchanged.
    static func softLimitedSample(_ value: Float) -> Float {
        guard value.isFinite else { return 0 }
        let magnitude = abs(value)
        guard magnitude > limiterKnee else { return value }

        let excess = magnitude - limiterKnee
        let compressed = limiterKnee + limiterHeadroom * excess / (limiterHeadroom + excess)
        return value.sign == .minus ? -compressed : compressed
    }

    static func sanitizedGain(_ value: Float) -> Float {
        guard value.isFinite else { return 1.0 }
        return min(max(value, 0), maximumGain)
    }

    // MARK: - AudioBufferList helpers

    private struct ChannelRef {
        let base: UnsafeMutablePointer<Float>
        let stride: Int
        let frames: Int
    }

    private static func clear(_ list: UnsafeMutableAudioBufferListPointer) {
        for bufferIndex in 0..<list.count {
            let buffer = list[bufferIndex]
            guard let data = buffer.mData else { continue }
            let sampleCount = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
            vDSP_vclr(data.assumingMemoryBound(to: Float.self), 1, vDSP_Length(sampleCount))
        }
    }

    private static func softLimit(_ list: UnsafeMutableAudioBufferListPointer) {
        for bufferIndex in 0..<list.count {
            let buffer = list[bufferIndex]
            guard let data = buffer.mData else { continue }
            let samples = data.assumingMemoryBound(to: Float.self)
            let sampleCount = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
            for sampleIndex in 0..<sampleCount {
                samples[sampleIndex] = softLimitedSample(samples[sampleIndex])
            }
        }
    }

    private static func channelCount(_ list: UnsafeMutableAudioBufferListPointer) -> Int {
        var result = 0
        for bufferIndex in 0..<list.count {
            result += Int(list[bufferIndex].mNumberChannels)
        }
        return result
    }

    private static func channel(
        _ list: UnsafeMutableAudioBufferListPointer,
        at flatIndex: Int
    ) -> ChannelRef? {
        guard flatIndex >= 0 else { return nil }
        var remaining = flatIndex

        for bufferIndex in 0..<list.count {
            let buffer = list[bufferIndex]
            let channels = Int(buffer.mNumberChannels)
            guard channels > 0 else { continue }
            if remaining >= channels {
                remaining -= channels
                continue
            }
            guard let data = buffer.mData else { return nil }
            let frames = Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * channels)
            return ChannelRef(
                base: data.assumingMemoryBound(to: Float.self) + remaining,
                stride: channels,
                frames: frames
            )
        }
        return nil
    }
}
