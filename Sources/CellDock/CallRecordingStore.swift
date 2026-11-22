import AppKit
import AudioToolbox
import AVFoundation
import Foundation
import UniformTypeIdentifiers

enum CallRecordingPhase: Equatable {
    case idle
    case recording
    case finalizing
}

struct CallRecordingRecord: Identifiable, Codable, Equatable {
    let id: UUID
    let callID: UUID?
    let number: String
    let direction: CallDirection
    let startedAt: Date
    let endedAt: Date
    let duration: TimeInterval
    let fileName: String
    let isIncomplete: Bool
    var title: String?
    /// Module and SIM slot of the recorded call. Older recordings have
    /// neither and fall back to their call-history record.
    var moduleID: CellularModuleID? = nil
    var simSlot: Int? = nil
}

@MainActor
final class CallRecordingStore: ObservableObject {
    static let shared = CallRecordingStore()

    @Published private(set) var phase: CallRecordingPhase = .idle
    @Published private(set) var records: [CallRecordingRecord] = []
    @Published private(set) var activeRecordingStartedAt: Date?
    @Published private(set) var playingRecordingID: UUID?
    @Published private(set) var isPlaybackPlaying = false
    @Published private(set) var playbackPosition: TimeInterval = 0
    @Published private(set) var playbackDuration: TimeInterval = 0
    @Published private(set) var playbackRate: Float = 1
    @Published private(set) var playbackVolume: Float = 1
    @Published private(set) var lastError: String?

    private let directoryURL: URL
    private let metadataURL: URL
    private var activeContext: (
        id: UUID,
        callID: UUID?,
        number: String,
        direction: CallDirection,
        startedAt: Date,
        moduleID: CellularModuleID?,
        simSlot: Int?
    )?
    private var player: AVAudioPlayer?
    private var playbackTimer: Timer?
    private var idleActions: [() -> Void] = []

    private init(fileManager: FileManager = .default) {
        let root = AppDataDirectory.userApplicationSupport(fileManager: fileManager)
        directoryURL = root.appendingPathComponent("Recordings", isDirectory: true)
        metadataURL = root.appendingPathComponent("recordings.json")
        try? fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        load()
    }

    var isRecording: Bool {
        phase == .recording
    }

    func start(
        localNumber: String?,
        number: String,
        direction: CallDirection,
        callID: UUID?,
        moduleID: CellularModuleID? = nil,
        simSlot: Int? = nil
    ) {
        guard phase == .idle else { return }
        lastError = nil
        let id = UUID()
        let startedAt = Date()
        let outputURL = availableRecordingURL(
            localNumber: localNumber,
            remoteNumber: number,
            startedAt: startedAt
        )
        do {
            try CallRecordingCapture.shared.start(
                id: id,
                startedAt: startedAt,
                outputURL: outputURL
            )
            activeContext = (id, callID, number, direction, startedAt, moduleID, simSlot)
            activeRecordingStartedAt = startedAt
            phase = .recording
        } catch {
            lastError = error.localizedDescription
        }
    }

    func stop(completion: ((CallRecordingRecord?) -> Void)? = nil) {
        guard phase == .recording, let context = activeContext else {
            completion?(nil)
            return
        }
        phase = .finalizing
        CallRecordingCapture.shared.stop { [weak self] result in
            DispatchQueue.main.async {
                guard let self else {
                    completion?(nil)
                    return
                }
                self.phase = .idle
                self.activeContext = nil
                self.activeRecordingStartedAt = nil
                switch result {
                case let .success(capture):
                    let record = CallRecordingRecord(
                        id: context.id,
                        callID: context.callID,
                        number: context.number,
                        direction: context.direction,
                        startedAt: context.startedAt,
                        endedAt: capture.endedAt,
                        duration: capture.duration,
                        fileName: capture.outputURL.lastPathComponent,
                        isIncomplete: capture.isIncomplete,
                        title: nil,
                        moduleID: context.moduleID,
                        simSlot: context.simSlot
                    )
                    self.records.insert(record, at: 0)
                    self.save()
                    completion?(record)
                case let .failure(error):
                    self.lastError = error.localizedDescription
                    completion?(nil)
                }
                self.runIdleActions()
            }
        }
    }

    func performWhenIdle(_ action: @escaping () -> Void) {
        if phase == .idle {
            action()
        } else {
            idleActions.append(action)
        }
    }

    func play(_ record: CallRecordingRecord) {
        do {
            try preparePlayback(for: record)
            guard let player else { return }
            if player.isPlaying {
                player.pause()
                isPlaybackPlaying = false
                stopPlaybackTimer()
            } else {
                if player.currentTime >= player.duration {
                    player.currentTime = 0
                    playbackPosition = 0
                }
                player.play()
                isPlaybackPlaying = true
                startPlaybackTimer()
            }
        } catch {
            playingRecordingID = nil
            isPlaybackPlaying = false
            lastError = error.localizedDescription
        }
    }

    func stopPlayback() {
        stopPlaybackTimer()
        player?.stop()
        player = nil
        playingRecordingID = nil
        isPlaybackPlaying = false
        playbackPosition = 0
        playbackDuration = 0
    }

    func seekPlayback(to time: TimeInterval) {
        guard let player else { return }
        let clamped = min(max(0, time), player.duration)
        player.currentTime = clamped
        playbackPosition = clamped
    }

    func seekPlayback(_ record: CallRecordingRecord, to time: TimeInterval) {
        do {
            try preparePlayback(for: record)
            seekPlayback(to: time)
        } catch {
            lastError = error.localizedDescription
        }
    }

    func skipPlayback(by interval: TimeInterval) {
        seekPlayback(to: playbackPosition + interval)
    }

    func setPlaybackRate(_ rate: Float) {
        let supportedRates: [Float] = [0.75, 1, 1.25, 1.5, 2]
        let resolved = supportedRates.min(by: { abs($0 - rate) < abs($1 - rate) }) ?? 1
        playbackRate = resolved
        player?.enableRate = true
        player?.rate = resolved
    }

    func setPlaybackVolume(_ volume: Float) {
        let resolved = min(max(0, volume), 1)
        playbackVolume = resolved
        player?.volume = resolved
    }

    func reveal(_ record: CallRecordingRecord) {
        NSWorkspace.shared.activateFileViewerSelecting([fileURL(for: record)])
    }

    func export(_ record: CallRecordingRecord) {
        let source = fileURL(for: record)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedExportName(for: record)
        panel.allowedContentTypes = [.mpeg4Audio]
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: source, to: destination)
        } catch {
            lastError = error.localizedDescription
        }
    }

    func rename(_ record: CallRecordingRecord, title: String) {
        guard let index = records.firstIndex(where: { $0.id == record.id }) else { return }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        records[index].title = trimmed.isEmpty ? nil : trimmed
        save()
    }

    /// Detaches recordings from a line whose history is being removed. The
    /// audio stays; the recordings just no longer name that line.
    func forgetLine(moduleID: CellularModuleID, simSlot: Int?) {
        var changed = false
        for index in records.indices
        where records[index].moduleID == moduleID && records[index].simSlot == simSlot {
            records[index].moduleID = nil
            records[index].simSlot = nil
            changed = true
        }
        if changed { save() }
    }

    func delete(_ record: CallRecordingRecord) {
        if playingRecordingID == record.id { stopPlayback() }
        try? FileManager.default.removeItem(at: fileURL(for: record))
        records.removeAll { $0.id == record.id }
        save()
    }

    private func startPlaybackTimer() {
        stopPlaybackTimer()
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.updatePlaybackProgress()
            }
        }
        playbackTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func preparePlayback(for record: CallRecordingRecord) throws {
        guard playingRecordingID != record.id || player == nil else { return }
        stopPlayback()
        let preparedPlayer = try AVAudioPlayer(contentsOf: fileURL(for: record))
        preparedPlayer.enableRate = true
        preparedPlayer.rate = playbackRate
        preparedPlayer.volume = playbackVolume
        preparedPlayer.prepareToPlay()
        player = preparedPlayer
        playingRecordingID = record.id
        isPlaybackPlaying = false
        playbackPosition = 0
        playbackDuration = preparedPlayer.duration
    }

    private func stopPlaybackTimer() {
        playbackTimer?.invalidate()
        playbackTimer = nil
    }

    private func updatePlaybackProgress() {
        guard let player, playingRecordingID != nil else {
            stopPlaybackTimer()
            return
        }
        playbackPosition = player.currentTime
        playbackDuration = player.duration
        isPlaybackPlaying = player.isPlaying
        if !player.isPlaying, player.currentTime >= max(0, player.duration - 0.05) {
            stopPlayback()
        }
    }

    func fileURL(for record: CallRecordingRecord) -> URL {
        directoryURL.appendingPathComponent(record.fileName)
    }

    private func suggestedExportName(for record: CallRecordingRecord) -> String {
        let base = record.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let base, !base.isEmpty {
            return "\(base).m4a"
        }
        let storedBaseName = URL(fileURLWithPath: record.fileName)
            .deletingPathExtension()
            .lastPathComponent
        if UUID(uuidString: storedBaseName) == nil {
            return record.fileName
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let fallback = L10n.tr(
            "通话录音-%@-%@",
            record.number,
            formatter.string(from: record.startedAt)
        )
        return "\(fallback).m4a"
    }

    nonisolated static func recordingFileName(
        localNumber: String?,
        remoteNumber: String,
        startedAt: Date,
        timeZone: TimeZone = .current
    ) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let local = fileNameComponent(localNumber, fallback: "unknown-local-number")
        let remote = fileNameComponent(remoteNumber, fallback: "unknown-number")
        return "\(local)_\(remote)_\(formatter.string(from: startedAt)).m4a"
    }

    private func availableRecordingURL(
        localNumber: String?,
        remoteNumber: String,
        startedAt: Date
    ) -> URL {
        let fileName = Self.recordingFileName(
            localNumber: localNumber,
            remoteNumber: remoteNumber,
            startedAt: startedAt
        )
        let preferredURL = directoryURL.appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: preferredURL.path) else {
            return preferredURL
        }

        let baseName = preferredURL.deletingPathExtension().lastPathComponent
        var suffix = 2
        while true {
            let candidate = directoryURL.appendingPathComponent("\(baseName)_\(suffix).m4a")
            if !FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
            suffix += 1
        }
    }

    nonisolated private static func fileNameComponent(
        _ value: String?,
        fallback: String
    ) -> String {
        guard let value else { return fallback }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return fallback }

        let invalid = CharacterSet(charactersIn: "/\\:*?\"<>|")
            .union(.controlCharacters)
        var sanitized = ""
        for scalar in trimmed.unicodeScalars {
            if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                continue
            }
            if invalid.contains(scalar) {
                sanitized.append("-")
            } else {
                sanitized.unicodeScalars.append(scalar)
            }
        }
        while sanitized.hasPrefix("+") {
            sanitized.removeFirst()
        }
        return sanitized.isEmpty ? fallback : sanitized
    }

    private func load() {
        guard let data = try? Data(contentsOf: metadataURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let decoded = try? decoder.decode([CallRecordingRecord].self, from: data) else { return }
        records = decoded
            .filter { FileManager.default.fileExists(atPath: fileURL(for: $0).path) }
            .sorted { $0.startedAt > $1.startedAt }
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(records) else { return }
        try? data.write(to: metadataURL, options: .atomic)
    }

    private func runIdleActions() {
        let actions = idleActions
        idleActions.removeAll()
        actions.forEach { $0() }
    }
}

final class CallRecordingCapture: @unchecked Sendable {
    struct FinalizedCapture {
        let outputURL: URL
        let endedAt: Date
        let duration: TimeInterval
        let isIncomplete: Bool
    }

    static let shared = CallRecordingCapture()

    private struct ActiveCapture {
        let id: UUID
        let startedAt: Date
        let outputURL: URL
        let temporaryDirectory: URL
        let uplinkURL: URL
        let downlinkURL: URL
        let uplinkHandle: FileHandle
        let downlinkHandle: FileHandle
        var firstUplinkAt: Date?
        var firstDownlinkAt: Date?
        var pendingBytes = 0
        var accepting = true
        var incomplete = false
    }

    private enum Channel {
        case uplink
        case downlink
    }

    private let queue = DispatchQueue(label: "app.celldock.mac.call-recording", qos: .utility)
    private let lock = NSLock()
    private var active: ActiveCapture?
    private let maximumPendingBytes = 2 * 1_024 * 1_024
    private let sampleRate = 8_000.0

    private init() {}

    func start(id: UUID, startedAt: Date, outputURL: URL) throws {
        try queue.sync {
            guard lock.withLock({ active == nil }) else {
                throw RecordingCaptureError.alreadyRecording
            }
            let temporaryDirectory = FileManager.default.temporaryDirectory
                .appendingPathComponent("CellDock-recording-\(id.uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(
                at: temporaryDirectory,
                withIntermediateDirectories: true
            )
            let uplinkURL = temporaryDirectory.appendingPathComponent("uplink.pcm")
            let downlinkURL = temporaryDirectory.appendingPathComponent("downlink.pcm")
            FileManager.default.createFile(atPath: uplinkURL.path, contents: nil)
            FileManager.default.createFile(atPath: downlinkURL.path, contents: nil)
            let uplinkHandle = try FileHandle(forWritingTo: uplinkURL)
            let downlinkHandle = try FileHandle(forWritingTo: downlinkURL)
            lock.withLock {
                active = ActiveCapture(
                    id: id,
                    startedAt: startedAt,
                    outputURL: outputURL,
                    temporaryDirectory: temporaryDirectory,
                    uplinkURL: uplinkURL,
                    downlinkURL: downlinkURL,
                    uplinkHandle: uplinkHandle,
                    downlinkHandle: downlinkHandle
                )
            }
        }
    }

    func appendUplink(_ pcm: Data, at timestamp: Date = Date()) {
        append(pcm, channel: .uplink, timestamp: timestamp)
    }

    func appendDownlink(_ pcm: Data, at timestamp: Date = Date()) {
        append(pcm, channel: .downlink, timestamp: timestamp)
    }

    func stop(completion: @escaping (Result<FinalizedCapture, Error>) -> Void) {
        let captureID: UUID? = lock.withLock {
            guard var active, active.accepting else { return nil }
            active.accepting = false
            self.active = active
            return active.id
        }
        guard let captureID else {
            completion(.failure(RecordingCaptureError.notRecording))
            return
        }

        queue.async { [weak self] in
            guard let self else { return }
            guard let capture: ActiveCapture = self.lock.withLock({
                guard self.active?.id == captureID else { return nil }
                let capture = self.active
                self.active = nil
                return capture
            }) else {
                completion(.failure(RecordingCaptureError.notRecording))
                return
            }

            do {
                defer { try? FileManager.default.removeItem(at: capture.temporaryDirectory) }
                try capture.uplinkHandle.close()
                try capture.downlinkHandle.close()
                let result = try self.finalize(capture)
                completion(.success(result))
            } catch {
                try? capture.uplinkHandle.close()
                try? capture.downlinkHandle.close()
                try? FileManager.default.removeItem(at: capture.outputURL)
                completion(.failure(error))
            }
        }
    }

    private func append(_ pcm: Data, channel: Channel, timestamp: Date) {
        guard !pcm.isEmpty else { return }
        let captureID: UUID? = lock.withLock {
            guard var active, active.accepting else { return nil }
            guard active.pendingBytes + pcm.count <= maximumPendingBytes else {
                active.incomplete = true
                self.active = active
                return nil
            }
            active.pendingBytes += pcm.count
            switch channel {
            case .uplink:
                if active.firstUplinkAt == nil { active.firstUplinkAt = timestamp }
            case .downlink:
                if active.firstDownlinkAt == nil { active.firstDownlinkAt = timestamp }
            }
            self.active = active
            return active.id
        }
        guard let captureID else { return }

        queue.async { [weak self] in
            guard let self else { return }
            defer {
                self.lock.withLock {
                    guard var active = self.active, active.id == captureID else { return }
                    active.pendingBytes = max(0, active.pendingBytes - pcm.count)
                    self.active = active
                }
            }
            let handle: FileHandle? = self.lock.withLock {
                guard let active = self.active, active.id == captureID else { return nil }
                return channel == .uplink ? active.uplinkHandle : active.downlinkHandle
            }
            do {
                try handle?.write(contentsOf: pcm)
            } catch {
                self.lock.withLock {
                    guard var active = self.active, active.id == captureID else { return }
                    active.incomplete = true
                    self.active = active
                }
            }
        }
    }

    private func finalize(_ capture: ActiveCapture) throws -> FinalizedCapture {
        let uplink = try Data(contentsOf: capture.uplinkURL, options: .mappedIfSafe)
        let downlink = try Data(contentsOf: capture.downlinkURL, options: .mappedIfSafe)
        let uplinkFrames = uplink.count / MemoryLayout<Int16>.size
        let downlinkFrames = downlink.count / MemoryLayout<Int16>.size
        let uplinkOffset = frameOffset(capture.firstUplinkAt, from: capture.startedAt)
        let downlinkOffset = frameOffset(capture.firstDownlinkAt, from: capture.startedAt)
        let totalFrames = max(uplinkOffset + uplinkFrames, downlinkOffset + downlinkFrames)
        guard totalFrames > 0 else { throw RecordingCaptureError.noAudio }

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 32_000
        ]
        let output = try AVAudioFile(forWriting: capture.outputURL, settings: settings)
        let format = output.processingFormat
        let chunkFrames = 4_096

        try uplink.withUnsafeBytes { uplinkRaw in
            try downlink.withUnsafeBytes { downlinkRaw in
                var frame = 0
                while frame < totalFrames {
                    let count = min(chunkFrames, totalFrames - frame)
                    guard let buffer = AVAudioPCMBuffer(
                        pcmFormat: format,
                        frameCapacity: AVAudioFrameCount(count)
                    ), let channels = buffer.floatChannelData else {
                        throw RecordingCaptureError.cannotCreateBuffer
                    }
                    buffer.frameLength = AVAudioFrameCount(count)
                    for localFrame in 0 ..< count {
                        let absoluteFrame = frame + localFrame
                        // Left: remote/downlink. Right: local/uplink.
                        channels[0][localFrame] = sample(
                            from: downlinkRaw,
                            frame: absoluteFrame - downlinkOffset,
                            availableFrames: downlinkFrames
                        )
                        channels[1][localFrame] = sample(
                            from: uplinkRaw,
                            frame: absoluteFrame - uplinkOffset,
                            availableFrames: uplinkFrames
                        )
                    }
                    try output.write(from: buffer)
                    frame += count
                }
            }
        }

        return FinalizedCapture(
            outputURL: capture.outputURL,
            endedAt: Date(),
            duration: Double(totalFrames) / sampleRate,
            isIncomplete: capture.incomplete
        )
    }

    private func frameOffset(_ date: Date?, from startedAt: Date) -> Int {
        guard let date else { return 0 }
        return max(0, Int(date.timeIntervalSince(startedAt) * sampleRate))
    }

    private func sample(
        from bytes: UnsafeRawBufferPointer,
        frame: Int,
        availableFrames: Int
    ) -> Float {
        guard frame >= 0, frame < availableFrames else { return 0 }
        let offset = frame * 2
        let low = UInt16(bytes[offset])
        let high = UInt16(bytes[offset + 1]) << 8
        return Float(Int16(bitPattern: low | high)) / 32_768
    }
}

private enum RecordingCaptureError: LocalizedError {
    case alreadyRecording
    case notRecording
    case noAudio
    case cannotCreateBuffer

    var errorDescription: String? {
        switch self {
        case .alreadyRecording: return L10n.tr("已有通话录音正在进行。")
        case .notRecording: return L10n.tr("当前没有正在进行的通话录音。")
        case .noAudio: return L10n.tr("本次录音没有收到可保存的通话音频。")
        case .cannotCreateBuffer: return L10n.tr("无法创建录音音频缓冲区。")
        }
    }
}
