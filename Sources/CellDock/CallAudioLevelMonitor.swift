import Combine
import Foundation

/// Feeds the in-call waveform. The voice transport hands it the audio of both
/// directions as it flows; ten times a second it turns what arrived into one
/// level per direction and publishes the recent history.
///
/// It only measures while a view is watching, so a call shown elsewhere costs
/// nothing.
final class CallAudioLevelMonitor: ObservableObject, @unchecked Sendable {
    static let shared = CallAudioLevelMonitor()

    /// One reading, and one waveform bar, per interval.
    static let readingInterval: TimeInterval = 0.1

    struct Reading: Equatable {
        var history = CallWaveformHistory()
        /// When the newest level was taken. The waveform slides between
        /// readings from this moment.
        var takenAt = Date.distantPast
    }

    @Published private(set) var reading = Reading()

    private let lock = NSLock()
    // Guarded by `lock`: written on the voice queues, read on the main thread.
    private var uplink = CallAudioLevelAccumulator()
    private var downlink = CallAudioLevelAccumulator()
    private var measuring = false
    // Main thread only.
    private var watchers = 0
    private var timer: Timer?
    private var silentReadings = 0

    /// The app uses `shared`. Tests and previews can start from a prepared
    /// reading.
    init(reading: Reading = Reading()) {
        self.reading = reading
    }

    /// The microphone audio sent to the module: 16-bit little-endian mono.
    /// Silence while muted.
    func appendUplink(_ pcm: Data) {
        lock.withLock {
            guard measuring else { return }
            uplink.add(pcm16LittleEndian: pcm)
        }
    }

    /// The other party's audio received from the module.
    func appendDownlink(_ pcm: Data) {
        lock.withLock {
            guard measuring else { return }
            downlink.add(pcm16LittleEndian: pcm)
        }
    }

    /// Starts measuring for a view that shows the waveform. Balance every
    /// call with `endWatching()`.
    func beginWatching() {
        dispatchPrecondition(condition: .onQueue(.main))
        watchers += 1
        guard timer == nil else { return }
        lock.withLock {
            uplink = CallAudioLevelAccumulator()
            downlink = CallAudioLevelAccumulator()
            measuring = true
        }
        silentReadings = 0
        let timer = Timer(timeInterval: Self.readingInterval, repeats: true) { [weak self] _ in
            self?.takeReading()
        }
        timer.tolerance = Self.readingInterval * 0.1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func endWatching() {
        dispatchPrecondition(condition: .onQueue(.main))
        watchers = max(0, watchers - 1)
        guard watchers == 0 else { return }
        timer?.invalidate()
        timer = nil
        lock.withLock { measuring = false }
        // The next call starts from an empty waveform.
        reading = Reading()
    }

    private func takeReading() {
        let levels = lock.withLock { (downlink.take(), uplink.take()) }
        // Once the whole waveform is flat there is nothing new to draw, for
        // example while the call is still ringing.
        if levels.0 == 0, levels.1 == 0 {
            silentReadings += 1
            if silentReadings > CallWaveformHistory.capacity + CallVoiceActivity.hangoverReadings {
                return
            }
        } else {
            silentReadings = 0
        }
        var next = reading
        next.history.push(remote: levels.0, local: levels.1)
        next.takenAt = Date()
        reading = next
    }
}
