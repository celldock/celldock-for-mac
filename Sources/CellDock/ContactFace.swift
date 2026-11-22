import Foundation

/// The face drawn on a number's avatar.
///
/// It is derived from the number alone, so the same number shows the same
/// face in Messages, Recents and Recordings, whichever module carried the
/// record. Every trait is drawn separately from the number's hash, which
/// gives thousands of faces instead of a handful of fixed expressions, and
/// every one of them smiles. Coordinates are in a 36-unit square.
struct ContactFace: Equatable {
    enum Eyes: Equatable {
        case dot
        case oval
        case smiling
        case winkLeft
        case winkRight
        /// Automated senders: a friendly robot instead of a person.
        case square
    }

    enum Mouth: Equatable {
        case smile
        case wide
        case grin
        case cat
    }

    let eyes: Eyes
    let mouth: Mouth
    /// Half the distance between the eyes.
    let eyeGap: Double
    let eyeY: Double
    let mouthY: Double
    let mouthWidth: Double
    /// Where the face looks: an offset of the whole face from the centre.
    let gazeX: Double
    let gazeY: Double
    /// Head tilt in degrees, clockwise.
    let tilt: Double
    let hasBlush: Bool
    /// Index into the avatar colour palette.
    let paletteIndex: Int

    static let paletteCount = 8

    private enum EyeKind { case dot, oval, smiling, wink }

    static func face(for address: String) -> ContactFace {
        let identity = PhoneNumberNormalizer.conversationID(for: address)
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in identity.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        // SplitMix64 turns the one hash into an independent value per trait.
        var state = hash
        func next() -> Double {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            z ^= z >> 31
            return Double(z >> 11) / 9_007_199_254_740_992
        }

        let automated = isAutomatedSender(address)
        // Repeated entries weight the choice.
        let eyeKinds: [EyeKind] = [.dot, .dot, .oval, .oval, .smiling, .smiling, .wink]
        let mouths: [Mouth] = [.smile, .smile, .wide, .grin, .grin, .cat]
        let eyeKind: EyeKind? = automated ? nil : eyeKinds[Int(next() * Double(eyeKinds.count))]
        let mouth: Mouth = automated ? .smile : mouths[Int(next() * Double(mouths.count))]
        let eyeGap = 4.0 + next() * 1.0
        let eyeY = 14.6 + (next() - 0.5) * 0.8
        let mouthY = eyeY + 5.0 + next() * 0.7
        let mouthWidth = 4.8 + next() * 1.6
        let gazeX = automated ? 0 : (next() - 0.5) * 4.4
        let gazeY = automated ? 0 : (next() - 0.5) * 1.4 - 0.2
        let tilt = automated ? 0 : (next() - 0.5) * 16
        let hasBlush = automated ? false : next() < 0.4
        let winkLeft = next() < 0.5

        let eyes: Eyes
        switch eyeKind {
        case .none: eyes = .square
        case .dot: eyes = .dot
        case .oval: eyes = .oval
        case .smiling: eyes = .smiling
        case .wink: eyes = winkLeft ? .winkLeft : .winkRight
        }
        return ContactFace(
            eyes: eyes,
            mouth: mouth,
            eyeGap: eyeGap,
            eyeY: eyeY,
            mouthY: mouthY,
            mouthWidth: mouthWidth,
            gazeX: gazeX,
            gazeY: gazeY,
            tilt: tilt,
            hasBlush: hasBlush,
            paletteIndex: Int(hash % UInt64(paletteCount))
        )
    }

    /// Service numbers and sender IDs that no person answers: short codes,
    /// SMS gateways, toll-free hotlines and alphanumeric senders.
    static func isAutomatedSender(_ address: String) -> Bool {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if trimmed.contains(where: \.isLetter) { return true }
        var digits = PhoneNumberNormalizer.normalized(trimmed)
        if digits.hasPrefix("+") { digits.removeFirst() }
        guard !digits.isEmpty else { return false }
        if digits.count <= 6 { return true }
        if digits.hasPrefix("106") { return true }
        if digits.count == 10, digits.hasPrefix("400") || digits.hasPrefix("800") { return true }
        if digits.count <= 8, digits.hasPrefix("95") || digits.hasPrefix("96") { return true }
        return false
    }
}
