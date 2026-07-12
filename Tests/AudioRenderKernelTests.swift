import Foundation
import AudioToolbox

private final class OwnedAudioBufferList {
    let list: UnsafeMutableAudioBufferListPointer
    private var storage: [UnsafeMutablePointer<Float>] = []

    init(_ buffers: [(channels: Int, samples: [Float])]) {
        list = AudioBufferList.allocate(maximumBuffers: buffers.count)
        list.count = buffers.count
        for (index, buffer) in buffers.enumerated() {
            precondition(buffer.channels > 0)
            let pointer = UnsafeMutablePointer<Float>.allocate(capacity: buffer.samples.count)
            pointer.initialize(from: buffer.samples, count: buffer.samples.count)
            storage.append(pointer)
            list[index] = AudioBuffer(
                mNumberChannels: UInt32(buffer.channels),
                mDataByteSize: UInt32(buffer.samples.count * MemoryLayout<Float>.size),
                mData: pointer
            )
        }
    }

    func samples(in buffer: Int) -> [Float] {
        let audioBuffer = list[buffer]
        guard let data = audioBuffer.mData else { return [] }
        let count = Int(audioBuffer.mDataByteSize) / MemoryLayout<Float>.size
        return Array(UnsafeBufferPointer(
            start: data.assumingMemoryBound(to: Float.self), count: count
        ))
    }

    deinit {
        for (index, pointer) in storage.enumerated() {
            let sampleCount = Int(list[index].mDataByteSize) / MemoryLayout<Float>.size
            pointer.deinitialize(count: sampleCount)
            pointer.deallocate()
        }
        list.unsafeMutablePointer.deallocate()
    }
}

private struct MixerState {
    let target: UnsafeMutablePointer<Float>
    let targets: UnsafeMutablePointer<UnsafeMutablePointer<Float>>
    let smoothed: UnsafeMutablePointer<Float>
    let count: Int

    init(targetValues: [Float], smoothedValues: [Float]) {
        precondition(targetValues.count == smoothedValues.count)
        count = targetValues.count
        target = .allocate(capacity: count)
        targets = .allocate(capacity: count)
        smoothed = .allocate(capacity: count)
        for index in 0..<count {
            target[index] = targetValues[index]
            targets[index] = target + index
            smoothed[index] = smoothedValues[index]
        }
    }

    func destroy() {
        target.deallocate()
        targets.deallocate()
        smoothed.deallocate()
    }
}

@main
private enum AudioRenderKernelTests {
    static func main() {
        testInterleavedInputAndMultichannelOutput()
        testGainRamp()
        testInputOffsetAndTapSumming()
        testSoftLimiterAndInvalidValues()
        testFormatValidation()
        print("AudioRenderKernelTests: all tests passed")
    }

    private static func render(
        input: OwnedAudioBufferList,
        output: OwnedAudioBufferList,
        state: MixerState,
        inputOffset: Int = 0,
        left: Int = 0,
        right: Int = 1
    ) {
        AudioRenderKernel.render(
            input: UnsafePointer(input.list.unsafeMutablePointer),
            output: output.list.unsafeMutablePointer,
            targetVolumes: UnsafePointer(state.targets),
            smoothedVolumes: state.smoothed,
            tapCount: state.count,
            inputBaseOffset: inputOffset,
            outLeftChannel: left,
            outRightChannel: right
        )
    }

    private static func testInterleavedInputAndMultichannelOutput() {
        let input = OwnedAudioBufferList([
            (2, [0.1, -0.1, 0.2, -0.2, 0.3, -0.3, 0.4, -0.4]),
        ])
        let output = OwnedAudioBufferList(Array(repeating: (1, [Float](repeating: 9, count: 4)), count: 4))
        let state = MixerState(targetValues: [0.5], smoothedValues: [0.5])
        defer { state.destroy() }

        render(input: input, output: output, state: state, left: 2, right: 3)
        assertClose(output.samples(in: 0), [0, 0, 0, 0])
        assertClose(output.samples(in: 1), [0, 0, 0, 0])
        assertClose(output.samples(in: 2), [0.05, 0.1, 0.15, 0.2])
        assertClose(output.samples(in: 3), [-0.05, -0.1, -0.15, -0.2])
    }

    private static func testGainRamp() {
        let input = OwnedAudioBufferList([(2, [1, 1, 1, 1, 1, 1, 1, 1])])
        let output = OwnedAudioBufferList([(2, [Float](repeating: 3, count: 8))])
        let state = MixerState(targetValues: [1], smoothedValues: [0])
        defer { state.destroy() }

        render(input: input, output: output, state: state)
        assertClose(output.samples(in: 0), [0, 0, 0.25, 0.25, 0.5, 0.5, 0.75, 0.75])
        assertClose(state.smoothed[0], 1)
    }

    private static func testInputOffsetAndTapSumming() {
        let input = OwnedAudioBufferList([
            (1, [0.9, 0.9]), // physical-device input channel: must be ignored
            (4, [
                0.1, 0.2, 0.3, 0.4,
                0.2, 0.3, 0.4, 0.5,
            ]),
        ])
        let output = OwnedAudioBufferList([(2, [Float](repeating: 0, count: 4))])
        let state = MixerState(targetValues: [0.5, 0.25], smoothedValues: [0.5, 0.25])
        defer { state.destroy() }

        render(input: input, output: output, state: state, inputOffset: 1)
        assertClose(output.samples(in: 0), [0.125, 0.2, 0.2, 0.275])
    }

    private static func testSoftLimiterAndInvalidValues() {
        assertClose(AudioRenderKernel.softLimitedSample(0.5), 0.5)
        let positive = AudioRenderKernel.softLimitedSample(2)
        assert(positive > 0.98 && positive < 1)
        assertClose(AudioRenderKernel.softLimitedSample(-2), -positive)
        assertClose(AudioRenderKernel.softLimitedSample(.nan), 0)
        assertClose(AudioRenderKernel.sanitizedGain(.nan), 1)
        assertClose(AudioRenderKernel.sanitizedGain(-2), 0)
        assertClose(AudioRenderKernel.sanitizedGain(4), 2)
    }

    private static func testFormatValidation() {
        let floatStereo = AudioStreamBasicDescription(
            mSampleRate: 48_000,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 8,
            mFramesPerPacket: 1,
            mBytesPerFrame: 8,
            mChannelsPerFrame: 2,
            mBitsPerChannel: 32,
            mReserved: 0
        )
        assert(floatStereo.isNativeFloat32PCM)

        var integerStereo = floatStereo
        integerStereo.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked
        assert(!integerStereo.isNativeFloat32PCM)
    }

    private static func assertClose(
        _ actual: [Float],
        _ expected: [Float],
        tolerance: Float = 0.000_01,
        file: StaticString = #file,
        line: UInt = #line
    ) {
        precondition(actual.count == expected.count, "Count mismatch", file: file, line: line)
        for (lhs, rhs) in zip(actual, expected) {
            precondition(abs(lhs - rhs) <= tolerance, "Expected \(rhs), got \(lhs)", file: file, line: line)
        }
    }

    private static func assertClose(
        _ actual: Float,
        _ expected: Float,
        tolerance: Float = 0.000_01,
        file: StaticString = #file,
        line: UInt = #line
    ) {
        precondition(abs(actual - expected) <= tolerance, "Expected \(expected), got \(actual)", file: file, line: line)
    }
}
