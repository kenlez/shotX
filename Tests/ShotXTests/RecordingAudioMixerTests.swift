import AVFoundation
import CoreMedia
import XCTest
@testable import ShotX

/// 覆盖「系统声音与麦克风同时开启」的混音管线逻辑（`RecordingAudioMixCore`）。
/// 核心纯逻辑不依赖真实硬件：注入绝对采样位置与合成 PCM 即可验证求和、时间对齐、
/// 单路 passthrough、结束/宽限行为。真实麦克风/扬声器硬件采集标注为手测（见交付评论）。
final class RecordingAudioMixerTests: XCTestCase {
    /// 生成一段交错立体声 float32 PCM。每帧两路；`value` 恒为常数便于断言求和。
    private func chunk(start: Int64, frames: Int, value: Float) -> RecordingAudioChunk {
        RecordingAudioChunk(startSample: start, samples: Array(repeating: value, count: frames * 2))
    }

    // MARK: - 双路同时开启：求和

    func testBothSourcesOverlapSumIntoSingleChunk() {
        var core = RecordingAudioMixCore()
        core.setSources(system: true, microphone: true)
        core.appendSystem(chunk(start: 0, frames: 480, value: 0.3))
        core.appendMicrophone(chunk(start: 0, frames: 480, value: 0.2))

        let out = core.drain()
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].startSample, 0)
        XCTAssertEqual(out[0].frameCount, 480)
        // 系统声 + 麦克风求合成单路，每个采样等于两者之和。
        XCTAssertEqual(out[0].samples[0], 0.5, accuracy: 1e-6)
        XCTAssertEqual(out[0].samples[1], 0.5, accuracy: 1e-6)
        XCTAssertEqual(out[0].samples.last!, 0.5, accuracy: 1e-6)
    }

    func testBothSourcesArePresentInMixedOutputNotJustOne() throws {
        var core = RecordingAudioMixCore()
        core.setSources(system: true, microphone: true)
        core.appendSystem(chunk(start: 0, frames: 100, value: 0.4))
        core.appendMicrophone(chunk(start: 0, frames: 100, value: 0.1))
        let out = core.drain()
        let first = try XCTUnwrap(out.first?.samples.first)
        XCTAssertEqual(Double(first), 0.5, accuracy: 1e-6)
    }

    // MARK: - 时间对齐

    func testTimeAlignedMicOffsetProducesSystemOnlyThenSum() {
        var core = RecordingAudioMixCore()
        core.setSources(system: true, microphone: true)
        // 系统声从 0 开始，麦克风从 240 帧（5ms @48k）开始，验证按 PTS 对齐。
        core.appendSystem(chunk(start: 0, frames: 480, value: 0.3))
        core.appendMicrophone(chunk(start: 240, frames: 240, value: 0.2))

        var out: [RecordingAudioChunk] = []
        out.append(contentsOf: core.drain())
        XCTAssertFalse(out.isEmpty)
        let totalFrames = out.reduce(0) { $0 + $1.frameCount }
        XCTAssertEqual(totalFrames, 480)
        // 前 240 帧只有系统声（0.3），后 240 帧为 0.3+0.2=0.5。
        let samples = out.flatMap(\.samples)
        XCTAssertEqual(Array(samples.prefix(240 * 2)), Array(repeating: 0.3, count: 480))
        let tail = Array(samples.suffix(240 * 2))
        XCTAssertEqual(tail, Array(repeating: 0.5, count: 480))
    }

    func testMicArrivingLateDoesNotLoseSystemAudioLeadingEdge() {
        var core = RecordingAudioMixCore()
        core.setSources(system: true, microphone: true)
        core.appendSystem(chunk(start: 0, frames: 960, value: 0.3))
        // 麦克风首包很晚才到（300 帧后），开头不应丢系统声。
        core.appendMicrophone(chunk(start: 300, frames: 660, value: 0.2))
        let out = core.drain()
        let frames = out.reduce(0) { $0 + $1.frameCount }
        XCTAssertEqual(frames, 960)
        let samples = out.flatMap(\.samples)
        XCTAssertEqual(Array(samples.prefix(300 * 2)), Array(repeating: 0.3, count: 600))
    }

    // MARK: - 单路（无麦克风/无系统声）不阻塞

    func testMicrophoneDisabledPassesSystemAudioThrough() {
        var core = RecordingAudioMixCore()
        core.setSources(system: true, microphone: false)
        core.appendSystem(chunk(start: 0, frames: 480, value: 0.5))
        let out = core.drain()
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].samples, Array(repeating: 0.5, count: 960))
    }

    func testSystemDisabledPassesMicrophoneThrough() {
        var core = RecordingAudioMixCore()
        core.setSources(system: false, microphone: true)
        core.appendMicrophone(chunk(start: 0, frames: 240, value: 0.4))
        let out = core.drain()
        XCTAssertEqual(out[0].samples, Array(repeating: 0.4, count: 480))
    }

    // MARK: - 麦克风未配置/设备不存在：不阻断系统声

    func testMicrophoneUnconfiguredNeverBlocksSystem() {
        var core = RecordingAudioMixCore()
        core.setSources(system: true, microphone: false)
        // 即使完全没有任何麦克风数据，系统声也应立即输出。
        core.appendSystem(chunk(start: 0, frames: 240, value: 0.6))
        XCTAssertEqual(core.drain().first?.samples, Array(repeating: 0.6, count: 480))
    }

    // MARK: - 源结束

    func testMicrophoneFinishedFlushesSystemRemainder() {
        var core = RecordingAudioMixCore()
        core.setSources(system: true, microphone: true)
        core.appendSystem(chunk(start: 0, frames: 480, value: 0.3))
        core.appendMicrophone(chunk(start: 0, frames: 240, value: 0.2))
        core.finishMicrophone() // 麦克风在 240 帧处断开
        let out = core.drain()
        let frames = out.reduce(0) { $0 + $1.frameCount }
        XCTAssertEqual(frames, 480)
        let samples = out.flatMap(\.samples)
        XCTAssertEqual(Array(samples.prefix(240 * 2)), Array(repeating: 0.5, count: 480))
        XCTAssertEqual(Array(samples.suffix(240 * 2)), Array(repeating: 0.3, count: 480))
    }

    // MARK: - 增量 drian 与单调推进

    func testIncrementalAppendAndDrainIsMonotonicAndLossless() {
        var core = RecordingAudioMixCore()
        core.setSources(system: true, microphone: true)
        var receivedFrames = 0
        var lastEnd: Int64 = 0
        for batch in 0..<5 {
            let start = Int64(batch * 480)
            core.appendSystem(chunk(start: start, frames: 480, value: 0.1))
            core.appendMicrophone(chunk(start: start, frames: 480, value: 0.2))
            for out in core.drain() {
                XCTAssertEqual(out.startSample, lastEnd)
                lastEnd = out.endSample
                receivedFrames += out.frameCount
            }
        }
        XCTAssertEqual(receivedFrames, 5 * 480)
        XCTAssertEqual(lastEnd, 5 * 480)
    }

    // MARK: - 静音宽限

    func testActiveMicWithNoDataYieldsToSystemAfterGrace() {
        var core = RecordingAudioMixCore()
        core.graceFrames = 480 // 10ms 宽限，便于测试
        core.setSources(system: true, microphone: true)
        // 麦克风启用但一直无数据：超过宽限期后系统声继续。
        core.appendSystem(chunk(start: 0, frames: 480, value: 0.5))
        let out = core.drain()
        XCTAssertEqual(out.first?.samples, Array(repeating: 0.5, count: 960))
    }

    // MARK: - AVFoundation 适配层（可注入合成 PCM CMSampleBuffer，无需真实硬件）

    /// 构造一个给定格式的合成 PCM CMSampleBuffer。
    private func makePCMBuffer(sampleRate: Double, channels: UInt32, isFloat: Bool, frames: Int, value: Float, ptsSeconds: Double) -> CMSampleBuffer {
        let formatFlags: AudioFormatFlags = isFloat ? kAudioFormatFlagsNativeFloatPacked : (kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked)
        var asbd = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: formatFlags,
            mBytesPerPacket: 4 * channels,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4 * channels,
            mChannelsPerFrame: channels,
            mBitsPerChannel: 32,
            mReserved: 0
        )
        let fmt = AVAudioFormat(streamDescription: &asbd)!
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(frames))!
        buf.frameLength = AVAudioFrameCount(frames)
        if isFloat, let d = buf.floatChannelData {
            for ch in 0..<Int(channels) { for i in 0..<frames { d[ch][i] = value } }
        }
        var formatDesc: CMAudioFormatDescription?
        var asbdVar = asbd
        CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &asbdVar, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &formatDesc)
        var sb: CMSampleBuffer?
        let status = buf.mutableAudioBufferList.withMemoryRebound(to: AudioBufferList.self, capacity: 1) { abl in
            CMAudioSampleBufferCreateWithPacketDescriptions(
                allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: false,
                makeDataReadyCallback: nil, refcon: nil,
                formatDescription: formatDesc!, sampleCount: frames,
                presentationTimeStamp: CMTime(seconds: ptsSeconds, preferredTimescale: 48000),
                packetDescriptions: nil, sampleBufferOut: &sb)
        }
        if status == noErr, var sb {
            let setStatus = CMSampleBufferSetDataBufferFromAudioBufferList(sb, blockBufferAllocator: kCFAllocatorDefault, blockBufferMemoryAllocator: kCFAllocatorDefault, flags: 0, bufferList: buf.mutableAudioBufferList)
            if setStatus == noErr { CMSampleBufferSetDataReady(sb) }
        }
        return sb!
    }

    func testAdapterConvertsMonoMicAndStereoSystemIntoOneTrack() {
        let mixer = RecordingAudioMixer()
        mixer.setAnchor(CMTime(seconds: 100, preferredTimescale: 48000))
        mixer.configure(system: true, microphoneConfigured: true)

        // 系统声：48k 立体声 float32，值 0.3；麦克风：48k 单声道 float32，值 0.2。
        mixer.appendSystem(makePCMBuffer(sampleRate: 48000, channels: 2, isFloat: true, frames: 480, value: 0.3, ptsSeconds: 100.0))
        mixer.appendMicrophone(makePCMBuffer(sampleRate: 48000, channels: 1, isFloat: true, frames: 480, value: 0.2, ptsSeconds: 100.0))

        let mixed = mixer.drain()
        XCTAssertEqual(mixed.count, 1)
        XCTAssertEqual(CMSampleBufferGetNumSamples(mixed[0]), 480)
        // 输出为单一混合 PCM 缓冲：系统声与麦克风求合成 0.5。
        var valid = false
        if let data = CMSampleBufferGetDataBuffer(mixed[0]) {
            let len = CMBlockBufferGetDataLength(data)
            var ptr: UnsafeMutablePointer<Int8>?
            CMBlockBufferGetDataPointer(data, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: nil, dataPointerOut: &ptr)
            if let raw = ptr {
                let floats = UnsafeBufferPointer(start: raw.withMemoryRebound(to: Float.self, capacity: len / 4) { $0 }, count: len / 4)
                XCTAssertEqual(Double(floats[0]), 0.5, accuracy: 1e-5)
                XCTAssertEqual(Double(floats[1]), 0.5, accuracy: 1e-5)
                valid = true
            }
        }
        XCTAssertTrue(valid)
    }

    func testAdapterWithoutMicConfiguredPassesSystemAudioThrough() {
        let mixer = RecordingAudioMixer()
        mixer.setAnchor(CMTime(seconds: 100, preferredTimescale: 48000))
        mixer.configure(system: true, microphoneConfigured: false)
        mixer.appendSystem(makePCMBuffer(sampleRate: 48000, channels: 2, isFloat: true, frames: 480, value: 0.5, ptsSeconds: 100.0))
        let mixed = mixer.drain()
        XCTAssertEqual(mixed.count, 1)
        XCTAssertEqual(CMSampleBufferGetNumSamples(mixed[0]), 480)
    }
}
