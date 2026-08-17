import AVFoundation
import CoreMedia
import AudioToolbox

/// 一段已归一化的 PCM：绝对采样位置 + 交错立体声 float32 采样（48 kHz）。
/// 纯数据，用于混音核心的输入与输出；时间轴统一为 48000 Hz 采样帧。
struct RecordingAudioChunk: Equatable {
    var startSample: Int64
    var samples: [Float]
    var frameCount: Int { samples.count / 2 }
    var endSample: Int64 { startSample + Int64(frameCount) }
}

/// 把系统声音与麦克风两路 PCM 混成单路的时间对齐核心。
///
/// 设计：
/// - 输入为按 PTS 换算成绝对采样位置的 `RecordingAudioChunk`，不依赖真实硬件，可注入时钟/格式做单测。
/// - 输出在「两路都已交付」的安全前沿内求和时间对齐的单路样本，保证不丢头、不回插，同步误差仅取决于两路 PTS 对齐。
/// - 任一路未启用/已结束/长时间无数据（宽限期）时视为静音，不阻塞另一路（保留无麦克风录制）。
struct RecordingAudioMixCore {
    var sampleRate: Double = 48000
    /// 某路「已启用但迟迟无任何数据」时视为静音的宽限帧数（默认 0.5s）。
    var graceFrames: Int64 = 24_000

    private(set) var systemChunks: [RecordingAudioChunk] = []
    private(set) var micChunks: [RecordingAudioChunk] = []
    private(set) var systemDeliveredEnd: Int64 = 0
    private(set) var micDeliveredEnd: Int64 = 0
    private(set) var emittedThrough: Int64 = 0
    private(set) var systemActive = false
    private(set) var microphoneActive = false
    private(set) var systemFinished = false
    private(set) var microphoneFinished = false

    mutating func setSources(system: Bool, microphone: Bool) {
        systemActive = system
        microphoneActive = microphone
        if !system { systemFinished = true }
        if !microphone { microphoneFinished = true }
    }

    mutating func finishSystem() { systemFinished = true }
    mutating func finishMicrophone() { microphoneFinished = true }

    mutating func appendSystem(_ chunk: RecordingAudioChunk) {
        guard !chunk.samples.isEmpty else { return }
        systemChunks.append(chunk)
        systemDeliveredEnd = max(systemDeliveredEnd, chunk.endSample)
    }

    mutating func appendMicrophone(_ chunk: RecordingAudioChunk) {
        guard !chunk.samples.isEmpty else { return }
        micChunks.append(chunk)
        micDeliveredEnd = max(micDeliveredEnd, chunk.endSample)
    }

    /// 单路实际可交付的终点；未启用/已结束返回 +inf 表示不限制。
    private func effectiveEnd(active: Bool, finished: Bool, delivered: Int64, otherDelivered: Int64) -> Int64 {
        if !active || finished { return Int64.max }
        if delivered > emittedThrough { return delivered }
        // 已启用但尚无数据：若另一路已前进超过宽限期则视为静音（避免死等），否则等待首包保证开头对齐。
        if otherDelivered - emittedThrough >= graceFrames { return Int64.max }
        return emittedThrough
    }

    /// 输出 [emittedThrough, 安全前沿) 的单路混合样本，并推进游标。
    mutating func drain() -> [RecordingAudioChunk] {
        let sysEnd = effectiveEnd(active: systemActive, finished: systemFinished, delivered: systemDeliveredEnd, otherDelivered: micDeliveredEnd)
        let micEnd = effectiveEnd(active: microphoneActive, finished: microphoneFinished, delivered: micDeliveredEnd, otherDelivered: systemDeliveredEnd)
        var safeEnd = min(sysEnd, micEnd)
        // 已结束源不再限制，但输出不能超出已交付数据；clamp 到两路已交付的最大终点。
        safeEnd = min(safeEnd, max(systemDeliveredEnd, micDeliveredEnd))
        guard safeEnd > emittedThrough else { return [] }

        let base = emittedThrough
        var mixed = [Float](repeating: 0, count: Int(safeEnd - base) * 2)
        addContribution(&mixed, from: base, to: safeEnd, chunks: systemChunks)
        addContribution(&mixed, from: base, to: safeEnd, chunks: micChunks)
        for i in mixed.indices { mixed[i] = max(-1, min(1, mixed[i])) }

        var system = systemChunks
        var mic = micChunks
        trimConsumed(&system, to: safeEnd)
        trimConsumed(&mic, to: safeEnd)
        systemChunks = system
        micChunks = mic
        emittedThrough = safeEnd
        return [RecordingAudioChunk(startSample: base, samples: mixed)]
    }

    private func addContribution(_ out: inout [Float], from base: Int64, to safeEnd: Int64, chunks: [RecordingAudioChunk]) {
        for chunk in chunks {
            let start = max(chunk.startSample, base)
            let end = min(chunk.endSample, safeEnd)
            guard start < end else { continue }
            let srcOff = Int(start - chunk.startSample) * 2
            let dstOff = Int(start - base) * 2
            let n = Int(end - start) * 2
            for i in 0..<n { out[dstOff + i] += chunk.samples[srcOff + i] }
        }
    }

    private mutating func trimConsumed(_ chunks: inout [RecordingAudioChunk], to safeEnd: Int64) {
        while let first = chunks.first, first.endSample <= safeEnd { chunks.removeFirst() }
        if var first = chunks.first, first.startSample < safeEnd {
            let skip = Int(safeEnd - first.startSample) * 2
            first.samples.removeFirst(skip)
            first.startSample = safeEnd
            chunks[0] = first
        }
    }
}

/// AVFoundation 适配层：把系统声音（SCStream `.audio`）与麦克风（AVCaptureAudioDataOutput）的
/// CMSampleBuffer 各自转换到统一 PCM（float32 交错 48k 立体声），按 PTS 对齐喂给混音核心，
/// 并把混合结果包装成 PCM CMSampleBuffer 交给单一音频 writer input（由 AVAssetWriter 编码为 AAC）。
///
/// 与核心不同，本类型依赖真实采样硬件/格式，无法在单测中完全复现；格式转换与时间对齐逻辑尽量
/// 只读 `CMSampleBuffer` 的 format description 与 PTS，可在有硬件环境下手测。
final class RecordingAudioMixer {
    enum Source: Int { case system, microphone }

    /// 统一输出格式：float32 交错立体声 48 kHz。
    private let targetFormat: AVAudioFormat
    private var core = RecordingAudioMixCore()
    private var converters: [Source: AVAudioConverter] = [:]
    private var sourceFormats: [Source: AVAudioFormat] = [:]
    private var anchor: CMTime?
    /// 麦克风会话确实存在（设备可用）时为 true；设备不存在时当作未启用，避免死等。
    private var microphoneConfigured = false

    init() {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: 48000,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagsNativeFloatPacked,
            mBytesPerPacket: 8,
            mFramesPerPacket: 1,
            mBytesPerFrame: 8,
            mChannelsPerFrame: 2,
            mBitsPerChannel: 32,
            mReserved: 0
        )
        targetFormat = AVAudioFormat(streamDescription: &asbd)!
    }

    func setAnchor(_ time: CMTime) { anchor = time }
    func configure(system: Bool, microphoneConfigured: Bool) {
        self.microphoneConfigured = microphoneConfigured
        core.setSources(system: system, microphone: microphoneConfigured)
    }

    func appendSystem(_ sample: CMSampleBuffer) {
        guard let chunk = convert(sample, source: .system) else { return }
        core.appendSystem(chunk)
    }

    func appendMicrophone(_ sample: CMSampleBuffer) {
        guard microphoneConfigured, let chunk = convert(sample, source: .microphone) else { return }
        core.appendMicrophone(chunk)
    }

    func finishSystem() { core.finishSystem() }
    func finishMicrophone() { core.finishMicrophone() }

    /// 取出当前可安全输出的混合 PCM（float32 交错 48k 立体声），包装成 CMSampleBuffer。
    func drain() -> [CMSampleBuffer] {
        guard let anchor else { return [] }
        var out: [CMSampleBuffer] = []
        for chunk in core.drain() {
            if let sb = makePCMBuffer(chunk, anchor: anchor) { out.append(sb) }
        }
        return out
    }

    // MARK: - 格式转换

    private func convert(_ sample: CMSampleBuffer, source: Source) -> RecordingAudioChunk? {
        guard let anchor else { return nil }
        guard let fd = CMSampleBufferGetFormatDescription(sample) else { return nil }
        let srcFormat = AVAudioFormat(cmAudioFormatDescription: fd)

        let converter: AVAudioConverter
        if let existing = converters[source], sourceFormats[source] == srcFormat {
            converter = existing
        } else {
            guard let c = AVAudioConverter(from: srcFormat, to: targetFormat) else { return nil }
            converters[source] = c
            sourceFormats[source] = srcFormat
            converter = c
        }

        // 源为 PCM 时直接包 ABL；非 PCM（如未来 SCStream 输出 AAC）时跳过本缓冲，避免错误数据。
        guard srcFormat.streamDescription.pointee.mFormatID == kAudioFormatLinearPCM,
              let wrapped = wrapPCMInput(sample, format: srcFormat) else { return nil }
        let input = wrapped.buffer
        // 保持 ABL 底层内存（CMBlockBuffer）存活直到转换完成，防止悬垂指针。
        let retainedBlock = wrapped.block

        var outFloats: [Float] = []
        var provided = false
        var safety = 0
        while safety < 1000 {
            safety += 1
            let outBuf = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: 2048)!
            var err: NSError?
            let status = converter.convert(to: outBuf, error: &err) { _, outStatus in
                if !provided {
                    provided = true
                    outStatus.pointee = .haveData
                    return input
                }
                outStatus.pointee = .endOfStream
                return nil
            }
            if outBuf.frameLength > 0 {
                let n = Int(outBuf.frameLength) * 2
                if let mData = outBuf.audioBufferList.pointee.mBuffers.mData {
                    let ptr = mData.assumingMemoryBound(to: Float.self)
                    outFloats.append(contentsOf: UnsafeBufferPointer(start: ptr, count: n))
                }
            }
            if status == .error || status == .endOfStream { break }
            if outBuf.frameLength == 0 { break }
        }
        withExtendedLifetime(retainedBlock) {}
        guard !outFloats.isEmpty else { return nil }

        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        let delta = CMTimeGetSeconds(CMTimeSubtract(pts, anchor))
        let startSample = Int64((delta * 48000).rounded())
        return RecordingAudioChunk(startSample: max(0, startSample), samples: outFloats)
    }

    private func wrapPCMInput(_ sample: CMSampleBuffer, format: AVAudioFormat) -> (buffer: AVAudioPCMBuffer, block: CMBlockBuffer)? {
        var abl = AudioBufferList()
        var block: CMBlockBuffer?
        let st = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sample,
            bufferListSizeNeededOut: nil,
            bufferListOut: &abl,
            bufferListSize: MemoryLayout<AudioBufferList>.size,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: 0,
            blockBufferOut: &block
        )
        guard st == noErr, let block else { return nil }
        let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: &abl)
        buffer?.frameLength = AVAudioFrameCount(CMSampleBufferGetNumSamples(sample))
        guard let buffer else { return nil }
        return (buffer, block)
    }

    // MARK: - 输出

    private func makePCMBuffer(_ chunk: RecordingAudioChunk, anchor: CMTime) -> CMSampleBuffer? {
        let frameCount = chunk.frameCount
        guard frameCount > 0, chunk.samples.count >= frameCount * 2 else { return nil }
        var asbd = targetFormat.streamDescription.pointee
        var fd: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: 0, layout: nil,
            magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &fd
        )
        var block: CMBlockBuffer?
        let byteLen = frameCount * 2 * MemoryLayout<Float>.size
        let status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: byteLen,
            blockAllocator: nil, customBlockSource: nil, offsetToData: 0, dataLength: byteLen,
            flags: 0, blockBufferOut: &block
        )
        guard status == noErr, let block, let fd else { return nil }
        let slice = Array(chunk.samples.prefix(frameCount * 2))
        _ = slice.withUnsafeBytes { raw in
            CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: byteLen)
        }
        var sb: CMSampleBuffer?
        let pts = CMTimeAdd(anchor, CMTime(value: chunk.startSample, timescale: 48000))
        let sbStatus = CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: fd,
            sampleCount: frameCount, presentationTimeStamp: pts,
            packetDescriptions: nil, sampleBufferOut: &sb
        )
        return sbStatus == noErr ? sb : nil
    }
}
