import AVFoundation
import CModemBridge
import CUACProbe
import Foundation

/// Bridges raw PCM on USB interface 1 to the Mac microphone and speaker.
/// The modem side can be QPCMV option 0 or CellDock's QDC507 PCM helper.
/// USB waits and sample-rate conversion never run on the CoreAudio render thread.
final class VoiceAudioService {
    var onError: ((String) -> Void)?

    private struct DeferredUACCleanup {
        let pointer: OpaquePointer
        var lastCallbackSequence: UInt64
        var removedQuietPasses: Int
    }

    private let ioQueue = DispatchQueue(label: "app.celldock.mac.voice.usb", qos: .userInteractive)
    private let captureQueue = DispatchQueue(label: "app.celldock.mac.voice.capture", qos: .userInteractive)
    private let playbackQueue = DispatchQueue(label: "app.celldock.mac.voice.playback", qos: .userInteractive)
    private let stateLock = NSLock()
    private let uploadLock = NSLock()

    private var voice: OpaquePointer?
    private var activeUAC: OpaquePointer?
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var running = false
    private var mediaEnabled = false
    private var pcmFlowReady = true
    private var muted = false
    private var uacCleanupPending = false
    private var sessionGeneration: UInt64 = 0
    private var uploadBytes = Data()
    private var captureSamples: [Float] = []
    private var capturePosition = 0.0
    private var captureSampleRate = 0.0
    private var captureConditioner = VoiceCaptureConditioner()
    // Accessed only on ioQueue. A CoreAudio stop failure must retain the C
    // callback context until a later retry confirms IOProc quiescence.
    private var deferredUACCleanup: [DeferredUACCleanup] = []
    // A removed USB ancestor can make AudioDeviceStop permanently return
    // BadDevice. Once that exact IORegistry ancestor is definitively absent
    // and callbacks stay quiet, keep the context alive for process lifetime
    // without blocking a newly enumerated physical module.
    private var retiredUACTombstones: [OpaquePointer] = []
    private var uacCleanupRetryScheduled = false
    // Accessed only on playbackQueue. Caps queued audio at 400 ms so small
    // clock differences between the modem and CoreAudio cannot grow forever.
    private var scheduledPlaybackFrames = 0

    private let modemSampleRate = 8_000.0
    private let receiveChunkBytes = 640
    // ttyGS0 normally emits 256-byte PCM periods.  When the host is briefly
    // descheduled, g_serial can coalesce several periods into one bulk IN
    // transaction.  A 640-byte USB request then fails with kIOReturnOverrun
    // before any of that transaction is usable.  Keep the 40 ms playback
    // chunk above, but submit a larger transport buffer for backlog bursts.
    private let usbReceiveBufferBytes = 4_096
    private let transmitChunkBytes = 1_600
    private let maximumUploadBytes = 6_400
    private let uacTransferFrames = 512
    private let uacIdleInterval = 0.005
    private let uacCallbackStallNanoseconds: UInt64 = 3_000_000_000
    private let maximumScheduledPlaybackFrames = 3_200

    func requestMicrophoneAccess(completion: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            completion(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async { completion(granted) }
            }
        case .denied, .restricted:
            completion(false)
        @unknown default:
            completion(false)
        }
    }

    func start(
        matchingLocationID: UInt32,
        completion: @escaping (ModemActionResult) -> Void
    ) {
        guard matchingLocationID != 0 else {
            completion(.failure(L10n.tr("USB 语音接口缺少可绑定的 locationID。")))
            return
        }
        let session: UInt64? = stateLock.withLock {
            if running { return nil }
            sessionGeneration &+= 1
            return sessionGeneration
        }
        guard let session else {
            DispatchQueue.main.async { completion(.success()) }
            return
        }
        ioQueue.async { [weak self] in
            guard let self else { return }
            guard self.isCurrentSession(session) else {
                DispatchQueue.main.async {
                    completion(.failure(L10n.tr("语音启动已取消。")))
                }
                return
            }
            guard let voice = celldock_voice_create() else {
                DispatchQueue.main.async {
                    completion(.failure(L10n.tr("无法初始化 USB 语音接口。")))
                }
                return
            }
            let openResult = celldock_voice_open_for_location(voice, matchingLocationID)
            guard openResult == CELLDOCK_MODEM_OK else {
                let error = String(cString: celldock_voice_last_error(voice))
                celldock_voice_destroy(voice)
                DispatchQueue.main.async {
                    completion(.failure(
                        error.isEmpty ? L10n.tr("无法打开 USB interface 1 语音通道。") : error
                    ))
                }
                return
            }
            guard self.isCurrentSession(session) else {
                celldock_voice_destroy(voice)
                DispatchQueue.main.async {
                    completion(.failure(L10n.tr("语音启动已取消。")))
                }
                return
            }

            let voiceProcessingEnabled: Bool
            do {
                voiceProcessingEnabled = try self.startAudioEngine(session: session)
            } catch {
                celldock_voice_destroy(voice)
                DispatchQueue.main.async {
                    completion(.failure(
                        L10n.error("无法启动 Mac 麦克风/扬声器：%@", underlying: error)
                    ))
                }
                return
            }

            guard self.isCurrentSession(session) else {
                self.stopAudioEngine()
                celldock_voice_destroy(voice)
                DispatchQueue.main.async {
                    completion(.failure(L10n.tr("语音启动已取消。")))
                }
                return
            }

            self.stateLock.withLock {
                self.voice = voice
                self.running = true
                self.mediaEnabled = false
                self.muted = false
            }
            self.resetBuffers()
            let description = L10n.tr(
                "语音 #1 · OUT 0x%02X · IN 0x%02X%@",
                celldock_voice_output_endpoint(voice),
                celldock_voice_input_endpoint(voice),
                voiceProcessingEnabled ? L10n.tr(" · 回声消除") : ""
            )
            DispatchQueue.main.async { completion(.success(description)) }
            self.runUSBLoop(voice, session: session)
            self.stopAudioEngine()
            celldock_voice_destroy(voice)
            self.stateLock.withLock {
                if self.voice == voice {
                    self.voice = nil
                }
                if self.sessionGeneration == session {
                    self.running = false
                    self.mediaEnabled = false
                }
            }
            self.resetBuffers()
        }
    }

    func validateUAC(
        vendorID: UInt16,
        productID: UInt16,
        matchingLocationID: UInt32,
        completion: @escaping (ModemActionResult) -> Void
    ) {
        guard vendorID != 0, productID != 0, matchingLocationID != 0 else {
            completion(.failure(L10n.tr("UAC 语音接口缺少完整的 USB 身份。")))
            return
        }
        guard stateLock.withLock({ !running && activeUAC == nil }) else {
            completion(.failure(L10n.tr("已有语音媒体正在运行。")))
            return
        }
        ioQueue.async { [weak self] in
            guard let self else { return }
            self.reapDeferredUACCleanupNow()
            guard self.deferredUACCleanup.isEmpty else {
                DispatchQueue.main.async {
                    completion(.failure(L10n.tr("上一次 UAC IOProc 尚未完成清理，请稍后重试。")))
                }
                return
            }
            guard let uac = celldock_uac_probe_create() else {
                DispatchQueue.main.async {
                    completion(.failure(L10n.tr("无法初始化模块 UAC 音频通道。")))
                }
                return
            }
            let openResult = self.openUAC(
                uac,
                vendorID: vendorID,
                productID: productID,
                matchingLocationID: matchingLocationID,
                preferredUID: nil
            )
            guard openResult == CELLDOCK_UAC_OK else {
                let error = self.lastUACError(
                    uac,
                    fallback: L10n.tr("没有找到与模块匹配的 8 kHz UAC 设备。")
                )
                let cleanupError = self.disposeUACOrDefer(uac)
                DispatchQueue.main.async {
                    completion(.failure(
                        cleanupError.map { L10n.tr("%@\nUAC 清理失败：%@", error, $0) } ?? error
                    ))
                }
                return
            }
            let uid = celldock_uac_probe_uid(uac).map(String.init(cString:)) ?? ""
            guard !uid.isEmpty, celldock_uac_probe_usb_binding_verified(uac) != 0 else {
                let cleanupError = self.disposeUACOrDefer(uac)
                DispatchQueue.main.async {
                    completion(.failure(
                        cleanupError.map {
                            L10n.tr("UAC USB 身份校验失败，且清理未完成：%@", $0)
                        } ?? L10n.tr("UAC USB 身份校验失败。")
                    ))
                }
                return
            }
            let cleanupError = self.disposeUACOrDefer(uac)
            DispatchQueue.main.async {
                if let cleanupError {
                    completion(.failure(L10n.tr("UAC 预检后的清理未完成：%@", cleanupError)))
                } else {
                    completion(.success(uid))
                }
            }
        }
    }

    func startUAC(
        vendorID: UInt16,
        productID: UInt16,
        matchingLocationID: UInt32,
        preferredUID: String? = nil,
        completion: @escaping (ModemActionResult) -> Void
    ) {
        guard vendorID != 0, productID != 0, matchingLocationID != 0 else {
            completion(.failure(L10n.tr("UAC 语音接口缺少完整的 USB 身份。")))
            return
        }
        let session: UInt64? = stateLock.withLock {
            if running { return nil }
            sessionGeneration &+= 1
            return sessionGeneration
        }
        guard let session else {
            DispatchQueue.main.async { completion(.success()) }
            return
        }

        ioQueue.async { [weak self] in
            guard let self else { return }
            guard self.isCurrentSession(session) else {
                DispatchQueue.main.async {
                    completion(.failure(L10n.tr("语音启动已取消。")))
                }
                return
            }
            self.reapDeferredUACCleanupNow()
            guard self.deferredUACCleanup.isEmpty else {
                DispatchQueue.main.async {
                    completion(.failure(L10n.tr("上一次 UAC IOProc 尚未完成清理，请稍后重试。")))
                }
                return
            }
            guard let uac = celldock_uac_probe_create() else {
                DispatchQueue.main.async {
                    completion(.failure(L10n.tr("无法初始化模块 UAC 音频通道。")))
                }
                return
            }
            var audioEngineStarted = false
            var voiceProcessingEnabled = false

            func failStart(_ message: String) {
                celldock_uac_probe_flush_pcm(uac)
                if audioEngineStarted {
                    self.stopAudioEngine()
                }
                let cleanupError = self.disposeUACOrDefer(uac)
                self.resetBuffersSynchronously()
                let detail = cleanupError.map {
                    L10n.tr("%@\nUAC 清理将在后台重试：%@", message, $0)
                } ?? message
                DispatchQueue.main.async { completion(.failure(detail)) }
            }

            let openResult = self.openUAC(
                uac,
                vendorID: vendorID,
                productID: productID,
                matchingLocationID: matchingLocationID,
                preferredUID: preferredUID
            )
            guard openResult == CELLDOCK_UAC_OK else {
                failStart(self.lastUACError(
                    uac,
                    fallback: L10n.tr("没有找到与模块匹配的 8 kHz UAC 设备。")
                ))
                return
            }
            guard self.isCurrentSession(session) else {
                failStart(L10n.tr("语音启动已取消。"))
                return
            }

            self.resetBuffersSynchronously()
            do {
                voiceProcessingEnabled = try self.startAudioEngine(session: session)
                audioEngineStarted = true
            } catch {
                failStart(L10n.error("无法启动 Mac 麦克风/扬声器：%@", underlying: error))
                return
            }
            guard self.isCurrentSession(session) else {
                failStart(L10n.tr("语音启动已取消。"))
                return
            }

            let startResult = celldock_uac_probe_start_pcm_bridge(uac)
            guard startResult == CELLDOCK_UAC_OK else {
                failStart(self.lastUACError(
                    uac,
                    fallback: L10n.tr("无法启动模块 UAC PCM 通道。")
                ))
                return
            }
            guard self.isCurrentSession(session) else {
                failStart(L10n.tr("语音启动已取消。"))
                return
            }

            celldock_uac_probe_flush_pcm(uac)
            self.stateLock.withLock {
                self.running = true
                self.mediaEnabled = false
                self.muted = false
                self.activeUAC = uac
            }
            let uacName: String
            if let rawName = celldock_uac_probe_name(uac) {
                uacName = String(cString: rawName)
            } else {
                uacName = "QDC507 UAC"
            }
            DispatchQueue.main.async {
                completion(.success(
                    L10n.tr(
                        "UAC · %@ · 8 kHz%@",
                        uacName,
                        voiceProcessingEnabled ? L10n.tr(" · 回声消除") : ""
                    )
                ))
            }

            let fatalError = self.runUACLoop(uac, session: session)
            self.stateLock.withLock {
                if self.activeUAC == uac {
                    self.activeUAC = nil
                }
                if self.sessionGeneration == session {
                    self.running = false
                    self.mediaEnabled = false
                }
            }
            self.clearUploadBytes()
            celldock_uac_probe_flush_pcm(uac)
            self.stopAudioEngine()
            let stopError = self.disposeUACOrDefer(uac)
            self.resetBuffersSynchronously()

            if let fatalError {
                self.reportUACError(fatalError, session: session)
            } else if let stopError, self.isCurrentSession(session) {
                self.reportUACError(stopError, session: session)
            }
        }
    }

    func stop(completion: (() -> Void)? = nil) {
        stateLock.withLock {
            sessionGeneration &+= 1
            running = false
            mediaEnabled = false
            muted = false
            activeUAC = nil
        }
        clearUploadBytes()
        guard let completion else { return }
        ioQueue.async(execute: completion)
    }

    func setMediaEnabled(_ enabled: Bool) {
        stateLock.withLock { mediaEnabled = enabled }
        if !enabled { clearUploadBytes() }
    }

    func setPCMFlowReady(_ ready: Bool) {
        stateLock.withLock { pcmFlowReady = ready }
        trimUploadBytesToLatestChunk()
    }

    func setMuted(_ value: Bool) {
        stateLock.withLock { muted = value }
        if value { clearUploadBytes() }
    }

    var isRunning: Bool {
        stateLock.withLock { running }
    }

    var hasUnresolvedUACCleanup: Bool {
        stateLock.withLock { uacCleanupPending }
    }

    var uacMediaSnapshot: UACMediaSnapshot? {
        stateLock.withLock {
            guard let uac = activeUAC else { return nil }
            return UACMediaSnapshot(
                inputFrames: celldock_uac_probe_input_frames(uac),
                outputFrames: celldock_uac_probe_output_frames(uac),
                inputTotalSamples: celldock_uac_probe_input_total_samples(uac),
                inputSignalSamples: celldock_uac_probe_input_signal_samples(uac),
                inputPeakPCM16: celldock_uac_probe_input_peak_pcm16(uac),
                inputSignalThresholdPCM16: celldock_uac_probe_input_signal_threshold_pcm16(uac)
            )
        }
    }

    private func openUAC(
        _ uac: OpaquePointer,
        vendorID: UInt16,
        productID: UInt16,
        matchingLocationID: UInt32,
        preferredUID: String?
    ) -> Int32 {
        if let preferredUID {
            return preferredUID.withCString { uid in
                celldock_uac_probe_open_for_usb(
                    uac,
                    vendorID,
                    productID,
                    matchingLocationID,
                    uid
                )
            }
        }
        return celldock_uac_probe_open_for_usb(
            uac,
            vendorID,
            productID,
            matchingLocationID,
            nil
        )
    }

    private func startAudioEngine(session: UInt64) throws -> Bool {
        try playbackQueue.sync {
            scheduledPlaybackFrames = 0
            let engine = AVAudioEngine()
            let player = AVAudioPlayerNode()
            let playbackFormat = AVAudioFormat(
                standardFormatWithSampleRate: modemSampleRate,
                channels: 1
            )!
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: playbackFormat)

            let input = engine.inputNode
            let voiceProcessingEnabled: Bool
            do {
                try input.setVoiceProcessingEnabled(true)
                input.isVoiceProcessingBypassed = false
                input.isVoiceProcessingAGCEnabled = true
                voiceProcessingEnabled = input.isVoiceProcessingEnabled
            } catch {
                // Some split Bluetooth/USB device combinations cannot enter
                // VoiceProcessingIO. Keep calls usable and rely on the local
                // telephone-band conditioner instead.
                voiceProcessingEnabled = false
            }
            let inputFormat = input.outputFormat(forBus: 0)
            guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
                throw VoiceAudioError.microphoneUnavailable
            }
            // 20 ms capture periods reduce conversational latency compared
            // with the previous 50 ms microphone batches.
            let tapFrames = AVAudioFrameCount(max(256, Int(inputFormat.sampleRate / 50)))
            input.installTap(onBus: 0, bufferSize: tapFrames, format: inputFormat) { [weak self] buffer, _ in
                self?.copyMicrophoneSamples(buffer, session: session)
            }

            engine.prepare()
            try engine.start()
            player.play()
            self.engine = engine
            self.player = player
            return voiceProcessingEnabled
        }
    }

    private func stopAudioEngine() {
        playbackQueue.sync {
            if let engine {
                engine.inputNode.removeTap(onBus: 0)
                player?.stop()
                engine.stop()
            }
            self.player = nil
            self.engine = nil
            scheduledPlaybackFrames = 0
        }
    }

    private func copyMicrophoneSamples(_ buffer: AVAudioPCMBuffer, session: UInt64) {
        guard isCurrentSession(session) else { return }
        guard let channels = buffer.floatChannelData else { return }
        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        guard frameCount > 0, channelCount > 0 else { return }

        var mono = [Float](repeating: 0, count: frameCount)
        for channel in 0 ..< channelCount {
            let source = channels[channel]
            for frame in 0 ..< frameCount {
                mono[frame] += source[frame] / Float(channelCount)
            }
        }
        let sampleRate = buffer.format.sampleRate
        captureQueue.async { [weak self] in
            self?.resampleAndQueue(mono, sampleRate: sampleRate, session: session)
        }
    }

    private func resampleAndQueue(_ samples: [Float], sampleRate: Double, session: UInt64) {
        let state = stateLock.withLock {
            (sessionGeneration == session, running, mediaEnabled, muted)
        }
        guard state.0, state.1, state.2 else { return }
        if captureSampleRate != sampleRate {
            captureSamples.removeAll(keepingCapacity: true)
            capturePosition = 0
            captureSampleRate = sampleRate
        }
        let conditioned = captureConditioner.process(samples, sampleRate: sampleRate)
        captureSamples.append(contentsOf: conditioned)
        let step = sampleRate / modemSampleRate
        var pcm = Data()
        pcm.reserveCapacity(Int(Double(samples.count) / step) * 2 + 4)

        while capturePosition + 1 < Double(captureSamples.count) {
            let lower = Int(capturePosition)
            let fraction = Float(capturePosition - Double(lower))
            let value = captureSamples[lower] * (1 - fraction) + captureSamples[lower + 1] * fraction
            let scaled: Int16
            if state.3 {
                scaled = 0
            } else {
                scaled = Int16(max(-1, min(1, value)) * Float(Int16.max))
            }
            var littleEndian = scaled.littleEndian
            withUnsafeBytes(of: &littleEndian) { pcm.append(contentsOf: $0) }
            capturePosition += step
        }

        let consumed = max(0, min(Int(capturePosition), captureSamples.count - 1))
        if consumed > 0 {
            captureSamples.removeFirst(consumed)
            capturePosition -= Double(consumed)
        }
        CallAudioLevelMonitor.shared.appendUplink(pcm)
        appendUploadBytes(pcm)
    }

    private func runUACLoop(_ uac: OpaquePointer, session: UInt64) -> String? {
        var downlinkSamples = [Int16](repeating: 0, count: uacTransferFrames)
        var uplinkSamples = [Int16](repeating: 0, count: uacTransferFrames)
        var lastInputCallbacks = celldock_uac_probe_input_callbacks(uac)
        var lastOutputCallbacks = celldock_uac_probe_output_callbacks(uac)
        var inputProgressAt = DispatchTime.now().uptimeNanoseconds
        var outputProgressAt = inputProgressAt
        var mediaWasEnabled = false
        var muteWasEnabled = false

        while isActiveSession(session) {
            let state = stateLock.withLock {
                (sessionGeneration == session && running, mediaEnabled, muted)
            }
            guard state.0 else { break }

            let now = DispatchTime.now().uptimeNanoseconds
            guard state.1 else {
                clearUploadBytes()
                celldock_uac_probe_flush_pcm(uac)
                lastInputCallbacks = celldock_uac_probe_input_callbacks(uac)
                lastOutputCallbacks = celldock_uac_probe_output_callbacks(uac)
                inputProgressAt = now
                outputProgressAt = now
                mediaWasEnabled = false
                muteWasEnabled = false
                Thread.sleep(forTimeInterval: uacIdleInterval)
                continue
            }
            if !mediaWasEnabled {
                celldock_uac_probe_flush_pcm(uac)
                clearUploadBytes()
                lastInputCallbacks = celldock_uac_probe_input_callbacks(uac)
                lastOutputCallbacks = celldock_uac_probe_output_callbacks(uac)
                inputProgressAt = now
                outputProgressAt = now
                mediaWasEnabled = true
            }
            if state.2 != muteWasEnabled {
                clearUploadBytes()
                celldock_uac_probe_flush_uplink_pcm(uac)
            }
            muteWasEnabled = state.2

            let uplinkFrames = takeUploadSamples(into: &uplinkSamples)
            if uplinkFrames > 0 {
                let acceptedFrames = uplinkSamples.withUnsafeBufferPointer { samples in
                    celldock_uac_probe_write_uplink_pcm16(
                        uac,
                        samples.baseAddress,
                        uplinkFrames
                    )
                }
                if acceptedFrames > 0 {
                    let byteCount = min(acceptedFrames, uplinkFrames) * MemoryLayout<Int16>.size
                    let pcm = uplinkSamples.withUnsafeBytes { bytes in
                        Data(bytes: bytes.baseAddress!, count: byteCount)
                    }
                    CallRecordingCapture.shared.appendUplink(pcm)
                }
            }

            let downlinkFrames = downlinkSamples.withUnsafeMutableBufferPointer { samples in
                Int(celldock_uac_probe_read_downlink_pcm16(
                    uac,
                    samples.baseAddress,
                    samples.count
                ))
            }
            if downlinkFrames > 0 {
                let frameCount = min(downlinkFrames, downlinkSamples.count)
                let byteCount = frameCount * MemoryLayout<Int16>.size
                let pcm = downlinkSamples.withUnsafeBytes { bytes in
                    Data(bytes: bytes.baseAddress!, count: byteCount)
                }
                CallRecordingCapture.shared.appendDownlink(pcm)
                schedulePlayback(pcm, session: session)
            }

            if celldock_uac_probe_is_running(uac) == 0 {
                return lastUACError(uac, fallback: L10n.tr("模块 UAC IOProc 已停止。"))
            }
            let inputCallbacks = celldock_uac_probe_input_callbacks(uac)
            let outputCallbacks = celldock_uac_probe_output_callbacks(uac)
            let progressNow = DispatchTime.now().uptimeNanoseconds
            if inputCallbacks != lastInputCallbacks {
                lastInputCallbacks = inputCallbacks
                inputProgressAt = progressNow
            }
            if outputCallbacks != lastOutputCallbacks {
                lastOutputCallbacks = outputCallbacks
                outputProgressAt = progressNow
            }
            if progressNow >= inputProgressAt,
               progressNow - inputProgressAt >= uacCallbackStallNanoseconds {
                return L10n.tr("模块 UAC 下行 IOProc 长时间没有推进。")
            }
            if progressNow >= outputProgressAt,
               progressNow - outputProgressAt >= uacCallbackStallNanoseconds {
                return L10n.tr("模块 UAC 上行 IOProc 长时间没有推进。")
            }

            Thread.sleep(forTimeInterval: uacIdleInterval)
        }
        return nil
    }

    private func runUSBLoop(_ voice: OpaquePointer, session: UInt64) {
        var receiveBuffer = [UInt8](repeating: 0, count: usbReceiveBufferBytes)
        var downlinkBytes = Data()
        var nextTransmit = DispatchTime.now().uptimeNanoseconds + 100_000_000

        while isActiveSession(session) {
            let beforeRead = DispatchTime.now().uptimeNanoseconds
            let state = stateLock.withLock {
                (
                    sessionGeneration == session && running,
                    mediaEnabled,
                    pcmFlowReady
                )
            }
            guard state.0 else { break }

            if state.1, state.2, beforeRead >= nextTransmit {
                let chunk = takeUploadChunkOrSilence()
                let writeResult = chunk.withUnsafeBytes { rawBuffer -> Int32 in
                    let bytes = rawBuffer.bindMemory(to: UInt8.self)
                    return celldock_voice_write(voice, 80, bytes.baseAddress, bytes.count)
                }
                if writeResult != CELLDOCK_MODEM_OK {
                    reportTransportError(voice, session: session)
                    break
                }
                CallRecordingCapture.shared.appendUplink(chunk)
                nextTransmit &+= 100_000_000
                if beforeRead > nextTransmit + 100_000_000 {
                    nextTransmit = beforeRead + 100_000_000
                }
            } else if !state.1 || !state.2 {
                nextTransmit = beforeRead + 100_000_000
            }

            guard state.1 else {
                Thread.sleep(forTimeInterval: 0.01)
                continue
            }
            let readStart = DispatchTime.now().uptimeNanoseconds
            let untilTransmit = nextTransmit > readStart ? nextTransmit - readStart : 0
            if state.2, untilTransmit < 45_000_000 {
                if untilTransmit > 0 {
                    Thread.sleep(forTimeInterval: Double(untilTransmit) / 1_000_000_000)
                }
                continue
            }
            // Normal downlink cadence is 40 ms. A 75 ms ceiling gives USB and
            // scheduler jitter room; the short interval before each 100 ms
            // uplink deadline is slept instead of forcing a guaranteed timeout.
            let timeoutMs = state.2
                ? max(45, min(75, Int((untilTransmit + 999_999) / 1_000_000)))
                : 75
            let readResult = receiveBuffer.withUnsafeMutableBufferPointer { pointer in
                celldock_voice_read(voice, Int32(timeoutMs), pointer.baseAddress, pointer.count)
            }
            if readResult < 0 || (readResult > 0 && celldock_voice_is_open(voice) == 0) {
                reportTransportError(voice, session: session)
                break
            }
            if readResult > 0 {
                downlinkBytes.append(contentsOf: receiveBuffer.prefix(Int(readResult)))
                while downlinkBytes.count >= receiveChunkBytes {
                    let chunk = Data(downlinkBytes.prefix(receiveChunkBytes))
                    downlinkBytes.removeFirst(receiveChunkBytes)
                    CallRecordingCapture.shared.appendDownlink(chunk)
                    schedulePlayback(chunk, session: session)
                }
                if downlinkBytes.count > receiveChunkBytes * 8 {
                    downlinkBytes = Data(downlinkBytes.suffix(receiveChunkBytes))
                }
            }

        }
        stateLock.withLock {
            if sessionGeneration == session { running = false }
        }
    }

    private func schedulePlayback(_ pcm: Data, session: UInt64) {
        let shouldPlay = stateLock.withLock {
            sessionGeneration == session && running && mediaEnabled
        }
        guard shouldPlay else { return }
        CallAudioLevelMonitor.shared.appendDownlink(pcm)
        playbackQueue.async { [weak self] in
            guard let self,
                  self.isActiveSession(session),
                  let player = self.player else { return }
            let format = AVAudioFormat(
                standardFormatWithSampleRate: self.modemSampleRate,
                channels: 1
            )!
            let frames = pcm.count / 2
            guard frames > 0,
                  self.scheduledPlaybackFrames + frames <= self.maximumScheduledPlaybackFrames else {
                return
            }
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(frames)
            ), let output = buffer.floatChannelData?[0] else {
                return
            }
            buffer.frameLength = AVAudioFrameCount(frames)
            pcm.withUnsafeBytes { rawBuffer in
                let bytes = rawBuffer.bindMemory(to: UInt8.self)
                for frame in 0 ..< frames {
                    let raw = UInt16(bytes[frame * 2]) | UInt16(bytes[frame * 2 + 1]) << 8
                    output[frame] = Float(Int16(bitPattern: raw)) / 32_768.0
                }
            }
            self.scheduledPlaybackFrames += frames
            player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                self?.playbackQueue.async { [weak self] in
                    guard let self, self.isCurrentSession(session) else { return }
                    self.scheduledPlaybackFrames = max(0, self.scheduledPlaybackFrames - frames)
                }
            }
        }
    }

    private func appendUploadBytes(_ bytes: Data) {
        guard !bytes.isEmpty else { return }
        let limit = stateLock.withLock {
            pcmFlowReady ? maximumUploadBytes : transmitChunkBytes
        }
        uploadLock.withLock {
            uploadBytes.append(bytes)
            if uploadBytes.count > limit {
                uploadBytes.removeFirst(uploadBytes.count - limit)
            }
        }
    }

    private func takeUploadChunkOrSilence() -> Data {
        uploadLock.withLock {
            if uploadBytes.count >= transmitChunkBytes {
                let chunk = Data(uploadBytes.prefix(transmitChunkBytes))
                uploadBytes.removeFirst(transmitChunkBytes)
                return chunk
            }
            var chunk = uploadBytes
            uploadBytes.removeAll(keepingCapacity: true)
            chunk.append(Data(repeating: 0, count: transmitChunkBytes - chunk.count))
            return chunk
        }
    }

    private func takeUploadSamples(into samples: inout [Int16]) -> Int {
        guard !samples.isEmpty else { return 0 }
        return uploadLock.withLock {
            let frameCount = min(
                samples.count,
                uploadBytes.count / MemoryLayout<Int16>.size
            )
            guard frameCount > 0 else { return 0 }
            uploadBytes.withUnsafeBytes { rawBuffer in
                let bytes = rawBuffer.bindMemory(to: UInt8.self)
                for frame in 0 ..< frameCount {
                    let bits = UInt16(bytes[frame * 2]) |
                        UInt16(bytes[frame * 2 + 1]) << 8
                    samples[frame] = Int16(bitPattern: bits)
                }
            }
            uploadBytes.removeFirst(frameCount * MemoryLayout<Int16>.size)
            return frameCount
        }
    }

    private func clearUploadBytes() {
        uploadLock.withLock { uploadBytes.removeAll(keepingCapacity: true) }
    }

    private func trimUploadBytesToLatestChunk() {
        uploadLock.withLock {
            if uploadBytes.count > transmitChunkBytes {
                uploadBytes = Data(uploadBytes.suffix(transmitChunkBytes))
            }
        }
    }

    private func resetBuffers() {
        clearUploadBytes()
        playbackQueue.async { [weak self] in
            self?.scheduledPlaybackFrames = 0
        }
        captureQueue.async { [weak self] in
            self?.captureSamples.removeAll(keepingCapacity: true)
            self?.capturePosition = 0
            self?.captureSampleRate = 0
            self?.captureConditioner.reset()
        }
    }

    private func resetBuffersSynchronously() {
        clearUploadBytes()
        playbackQueue.sync {
            scheduledPlaybackFrames = 0
        }
        captureQueue.sync {
            captureSamples.removeAll(keepingCapacity: true)
            capturePosition = 0
            captureSampleRate = 0
            captureConditioner.reset()
        }
    }

    private func reportTransportError(_ voice: OpaquePointer, session: UInt64) {
        guard isCurrentSession(session) else { return }
        let raw = String(cString: celldock_voice_last_error(voice))
        let message = raw.isEmpty ? L10n.tr("USB 语音接口已断开。") : raw
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isCurrentSession(session) else { return }
            self.onError?(message)
        }
    }

    private func lastUACError(_ uac: OpaquePointer, fallback: String) -> String {
        guard let raw = celldock_uac_probe_last_error(uac) else { return fallback }
        let message = String(cString: raw)
        return message.isEmpty ? fallback : message
    }

    /// Must run on ioQueue. Returns nil only when the pointer was freed.
    private func disposeUACOrDefer(_ uac: OpaquePointer) -> String? {
        let result = celldock_uac_probe_try_destroy(uac)
        guard result != CELLDOCK_UAC_OK else { return nil }
        let error = lastUACError(
            uac,
            fallback: L10n.tr("模块 UAC IOProc 或采样率恢复尚未完成。")
        )
        if !deferredUACCleanup.contains(where: { $0.pointer == uac }) {
            deferredUACCleanup.append(
                DeferredUACCleanup(
                    pointer: uac,
                    lastCallbackSequence: celldock_uac_probe_callback_sequence(uac),
                    removedQuietPasses: 0
                )
            )
        }
        stateLock.withLock { uacCleanupPending = true }
        scheduleDeferredUACCleanup()
        return error
    }

    private func scheduleDeferredUACCleanup() {
        guard !uacCleanupRetryScheduled, !deferredUACCleanup.isEmpty else { return }
        uacCleanupRetryScheduled = true
        ioQueue.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self else { return }
            self.uacCleanupRetryScheduled = false
            self.reapDeferredUACCleanupNow()
            self.scheduleDeferredUACCleanup()
        }
    }

    private func reapDeferredUACCleanupNow() {
        var remaining: [DeferredUACCleanup] = []
        for var entry in deferredUACCleanup {
            let uac = entry.pointer
            let originalUSBPresence = celldock_uac_probe_original_usb_present(uac)
            if originalUSBPresence > 0 {
                entry.removedQuietPasses = 0
                if celldock_uac_probe_try_destroy(uac) == CELLDOCK_UAC_OK {
                    continue
                }
                entry.lastCallbackSequence = celldock_uac_probe_callback_sequence(uac)
                remaining.append(entry)
                continue
            }
            if originalUSBPresence < 0 {
                entry.removedQuietPasses = 0
                remaining.append(entry)
                continue
            }

            let sequence = celldock_uac_probe_callback_sequence(uac)
            let callbacksInFlight = celldock_uac_probe_callbacks_in_flight(uac)
            if callbacksInFlight == 0, sequence == entry.lastCallbackSequence {
                entry.removedQuietPasses += 1
            } else {
                entry.removedQuietPasses = 0
            }
            entry.lastCallbackSequence = sequence
            if entry.removedQuietPasses >= 3 {
                retiredUACTombstones.append(uac)
            } else {
                remaining.append(entry)
            }
        }
        deferredUACCleanup = remaining
        stateLock.withLock { uacCleanupPending = !remaining.isEmpty }
    }

    private func reportUACError(_ message: String, session: UInt64) {
        guard isCurrentSession(session) else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isCurrentSession(session) else { return }
            self.onError?(message)
        }
    }

    private func isCurrentSession(_ session: UInt64) -> Bool {
        stateLock.withLock { sessionGeneration == session }
    }

    private func isActiveSession(_ session: UInt64) -> Bool {
        stateLock.withLock { sessionGeneration == session && running }
    }
}

private enum VoiceAudioError: LocalizedError {
    case microphoneUnavailable

    var errorDescription: String? {
        L10n.tr("没有可用的麦克风输入设备")
    }
}

private extension NSLock {
    @discardableResult
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
