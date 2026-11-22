import Foundation

/// How loud one direction of a call is, on the 0…1 scale the in-call
/// waveform draws.
enum CallAudioLevel {
    /// Audio at or below this RMS level (dBFS) draws as silence. Comfort
    /// noise and an idle microphone sit below it.
    static let floorDecibels = -54.0
    /// Audio at or above this RMS level fills the lane. Ordinary telephone
    /// speech averages around -26 dBFS, so it lands in the upper half.
    static let ceilingDecibels = -16.0
    /// Bars at or above this level are drawn in the speaker's colour.
    static let voiced: Float = 0.16

    /// Maps the energy of 16-bit samples to 0…1, linear in decibels so quiet
    /// and loud speech are both visible.
    static func normalized(sumOfSquares: Double, sampleCount: Int) -> Float {
        guard sampleCount > 0, sumOfSquares > 0 else { return 0 }
        let rms = (sumOfSquares / Double(sampleCount)).squareRoot() / 32_768
        guard rms > 0 else { return 0 }
        let decibels = 20 * log10(rms)
        let position = (decibels - floorDecibels) / (ceilingDecibels - floorDecibels)
        return Float(max(0, min(1, position)))
    }
}

/// Collects the energy of the audio that passed since the last reading.
struct CallAudioLevelAccumulator: Equatable {
    private(set) var sumOfSquares = 0.0
    private(set) var sampleCount = 0

    /// Adds 16-bit little-endian mono PCM, the format both voice transports
    /// exchange with the module.
    mutating func add(pcm16LittleEndian data: Data) {
        let frames = data.count / 2
        guard frames > 0 else { return }
        var sum = 0.0
        data.withUnsafeBytes { rawBuffer in
            let bytes = rawBuffer.bindMemory(to: UInt8.self)
            for frame in 0 ..< frames {
                let bits = UInt16(bytes[frame * 2]) | UInt16(bytes[frame * 2 + 1]) << 8
                let sample = Double(Int16(bitPattern: bits))
                sum += sample * sample
            }
        }
        sumOfSquares += sum
        sampleCount += frames
    }

    /// The level of everything added since the last call, then starts over.
    /// Returns 0 when no audio arrived.
    mutating func take() -> Float {
        defer {
            sumOfSquares = 0
            sampleCount = 0
        }
        return CallAudioLevel.normalized(sumOfSquares: sumOfSquares, sampleCount: sampleCount)
    }
}

/// Decides whether someone is speaking from a stream of levels. It starts at
/// a higher level than it stops at and holds through the short gaps between
/// words, so the "speaking" label does not flicker.
struct CallVoiceActivity: Equatable {
    static let startLevel: Float = 0.24
    static let stopLevel: Float = CallAudioLevel.voiced
    /// How many quiet readings in a row end a stretch of speech.
    static let hangoverReadings = 4

    private(set) var isSpeaking = false
    private var quietReadings = 0

    @discardableResult
    mutating func update(level: Float) -> Bool {
        if level >= Self.startLevel {
            isSpeaking = true
            quietReadings = 0
        } else if isSpeaking {
            if level >= Self.stopLevel {
                quietReadings = 0
            } else {
                quietReadings += 1
                if quietReadings >= Self.hangoverReadings {
                    isSpeaking = false
                    quietReadings = 0
                }
            }
        }
        return isSpeaking
    }
}

enum CallSpeakingState: Equatable {
    case silent
    case remote
    case local
    case both
}

/// The recent levels of both directions of a call, oldest first. The
/// waveform scrolls through it one reading at a time.
struct CallWaveformHistory: Equatable {
    /// More than the widest lane can show, at one bar per reading.
    static let capacity = 96

    private(set) var remote: [Float]
    private(set) var local: [Float]
    private var remoteActivity = CallVoiceActivity()
    private var localActivity = CallVoiceActivity()

    init() {
        remote = Array(repeating: 0, count: Self.capacity)
        local = Array(repeating: 0, count: Self.capacity)
    }

    mutating func push(remote remoteLevel: Float, local localLevel: Float) {
        remote.removeFirst()
        remote.append(max(0, min(1, remoteLevel)))
        local.removeFirst()
        local.append(max(0, min(1, localLevel)))
        remoteActivity.update(level: remoteLevel)
        localActivity.update(level: localLevel)
    }

    var latestRemote: Float { remote.last ?? 0 }
    var latestLocal: Float { local.last ?? 0 }
    var remoteSpeaking: Bool { remoteActivity.isSpeaking }
    var localSpeaking: Bool { localActivity.isSpeaking }

    var speaking: CallSpeakingState {
        switch (remoteSpeaking, localSpeaking) {
        case (true, true): return .both
        case (true, false): return .remote
        case (false, true): return .local
        case (false, false): return .silent
        }
    }
}

/// The line under the waveform that says who is speaking.
enum CallSpeakingHint {
    static func text(speaking: CallSpeakingState, muted: Bool, audioActive: Bool) -> String {
        guard audioActive else { return L10n.tr("正在接通通话声音…") }
        if muted {
            return L10n.tr("你已静音，对方听不到你")
        }
        switch speaking {
        case .both: return L10n.tr("双方同时在说话")
        case .remote: return L10n.tr("对方正在说话")
        case .local: return L10n.tr("你正在说话")
        case .silent: return ""
        }
    }
}
