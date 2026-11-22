import AppKit
import SwiftUI

/// The solid colour of one module, used for its line badges, outgoing
/// message bubbles and send button.
struct ModuleTint: Equatable {
    let solid: Color

    private init(solid: UInt32) {
        self.solid = Color(appHex: solid)
    }

    /// One entry per `ModuleAppearanceRegistry.colorCount`. Every colour
    /// keeps white badge text above 4.5:1 contrast.
    static let palette: [ModuleTint] = [
        ModuleTint(solid: 0x2563EB), // blue
        ModuleTint(solid: 0x0B7F73), // teal
        ModuleTint(solid: 0x7C3AED), // purple
        ModuleTint(solid: 0xB4471F), // coral
        ModuleTint(solid: 0xC0267E), // pink
        ModuleTint(solid: 0xA15C07), // amber
    ]

    /// Records whose module is unplugged or unknown.
    static let detached = ModuleTint(solid: 0x6B6F78)

    static func tint(colorIndex: Int?) -> ModuleTint {
        guard let colorIndex else { return detached }
        return palette[((colorIndex % palette.count) + palette.count) % palette.count]
    }
}

/// The colours of one avatar: a soft gradient for the disc and a deeper tone
/// of the same hue for the face. A number picks its colour by itself, so a
/// list of numbers on one line is not a wall of a single colour.
struct AvatarTint: Equatable {
    let gradientStart: Color
    let gradientEnd: Color
    let face: Color

    private init(start: UInt32, end: UInt32, face: UInt32) {
        gradientStart = Color(appHex: start)
        gradientEnd = Color(appHex: end)
        self.face = Color(appHex: face)
    }

    /// One entry per `ContactFace.paletteCount`.
    static let palette: [AvatarTint] = [
        AvatarTint(start: 0xD8EEFF, end: 0x8FC2F5, face: 0x1F4E86), // blue
        AvatarTint(start: 0xD3F6E9, end: 0x7FD6C2, face: 0x17604F), // teal
        AvatarTint(start: 0xE6DEFF, end: 0xA99BF2, face: 0x40318A), // purple
        AvatarTint(start: 0xFFE0CA, end: 0xFF9F7A, face: 0x8A3A1C), // coral
        AvatarTint(start: 0xFFDDD6, end: 0xFF9FAA, face: 0x8E2F45), // pink
        AvatarTint(start: 0xFFEDB5, end: 0xFFB96E, face: 0x8A4A12), // amber
        AvatarTint(start: 0xCEF2F3, end: 0x74C9D6, face: 0x155B66), // cyan
        AvatarTint(start: 0xF8DAF6, end: 0xD79DE9, face: 0x6B2D80), // lilac
    ]

    static func tint(for face: ContactFace) -> AvatarTint {
        palette[((face.paletteIndex % palette.count) + palette.count) % palette.count]
    }
}

extension Color {
    fileprivate init(appHex value: UInt32) {
        self.init(
            .sRGB,
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255,
            opacity: 1
        )
    }
}

extension LineAppearance {
    var tint: ModuleTint { .tint(colorIndex: colorIndex) }
}

/// The numbered capsule that says which line carried a record.
struct LineBadge: View {
    let text: String
    let color: Color
    var height: CGFloat = 16

    var body: some View {
        Text(verbatim: text)
            .font(height >= 20 ? Font.appCallout.weight(.semibold) : .appMicro)
            .monospacedDigit()
            .foregroundStyle(.white)
            .lineLimit(1)
            .padding(.horizontal, height * 0.28)
            .frame(minWidth: height)
            .frame(height: height)
            .background(color, in: Capsule())
            .fixedSize()
    }
}

/// One layer of a face, drawn in a 36-unit square and scaled to the avatar.
/// Lines, filled shapes and blush are separate layers because each is painted
/// differently.
struct ContactFaceShape: Shape {
    enum Layer {
        /// Smiling eyes and line mouths.
        case strokes
        /// Round, oval and square eyes, and the open grin.
        case fills
        case blush
    }

    let face: ContactFace
    let layer: Layer

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let gap = CGFloat(face.eyeGap)
        let eyeY = CGFloat(face.eyeY)
        let mouthY = CGFloat(face.mouthY)
        let mouthWidth = CGFloat(face.mouthWidth)

        func eye(_ x: CGFloat, smiling: Bool, radiusX: CGFloat, radiusY: CGFloat) {
            if smiling {
                guard layer == .strokes else { return }
                path.move(to: CGPoint(x: x - 1.6, y: eyeY + 0.5))
                path.addQuadCurve(
                    to: CGPoint(x: x + 1.6, y: eyeY + 0.5),
                    control: CGPoint(x: x, y: eyeY - 1.7)
                )
            } else if layer == .fills {
                path.addEllipse(in: CGRect(
                    x: x - radiusX,
                    y: eyeY - radiusY,
                    width: radiusX * 2,
                    height: radiusY * 2
                ))
            }
        }
        func squareEye(_ x: CGFloat) {
            guard layer == .fills else { return }
            path.addRect(CGRect(x: x - 1.15, y: eyeY - 1.15, width: 2.3, height: 2.3))
        }
        func curve(width: CGFloat, y: CGFloat, depth: CGFloat, closed: Bool) {
            path.move(to: CGPoint(x: 18 - width / 2, y: y))
            path.addQuadCurve(
                to: CGPoint(x: 18 + width / 2, y: y),
                control: CGPoint(x: 18, y: y + depth)
            )
            if closed { path.closeSubpath() }
        }

        let left = 18 - gap
        let right = 18 + gap
        switch face.eyes {
        case .dot:
            eye(left, smiling: false, radiusX: 1.05, radiusY: 1.05)
            eye(right, smiling: false, radiusX: 1.05, radiusY: 1.05)
        case .oval:
            eye(left, smiling: false, radiusX: 0.95, radiusY: 1.45)
            eye(right, smiling: false, radiusX: 0.95, radiusY: 1.45)
        case .smiling:
            eye(left, smiling: true, radiusX: 0, radiusY: 0)
            eye(right, smiling: true, radiusX: 0, radiusY: 0)
        case .winkLeft:
            eye(left, smiling: true, radiusX: 0, radiusY: 0)
            eye(right, smiling: false, radiusX: 1.05, radiusY: 1.05)
        case .winkRight:
            eye(left, smiling: false, radiusX: 1.05, radiusY: 1.05)
            eye(right, smiling: true, radiusX: 0, radiusY: 0)
        case .square:
            squareEye(left)
            squareEye(right)
        }

        switch (face.mouth, layer) {
        case (.smile, .strokes):
            curve(width: mouthWidth, y: mouthY, depth: 2.4, closed: false)
        case (.wide, .strokes):
            curve(width: mouthWidth + 1.4, y: mouthY - 0.3, depth: 3.6, closed: false)
        case (.grin, .fills):
            curve(width: mouthWidth + 0.6, y: mouthY - 0.2, depth: 4.4, closed: true)
        case (.cat, .strokes):
            path.move(to: CGPoint(x: 18 - mouthWidth / 2, y: mouthY))
            path.addQuadCurve(
                to: CGPoint(x: 18, y: mouthY),
                control: CGPoint(x: 18 - mouthWidth / 4, y: mouthY + 2)
            )
            path.addQuadCurve(
                to: CGPoint(x: 18 + mouthWidth / 2, y: mouthY),
                control: CGPoint(x: 18 + mouthWidth / 4, y: mouthY + 2)
            )
        default:
            break
        }

        if layer == .blush, face.hasBlush {
            for x in [left - 2.5, right + 2.5] {
                path.addEllipse(in: CGRect(x: x - 1.9, y: eyeY + 3.3 - 1.15, width: 3.8, height: 2.3))
            }
        }

        // The whole face tilts about its centre, then moves to where it looks.
        let scale = min(rect.width, rect.height) / 36
        let transform = CGAffineTransform(translationX: rect.minX, y: rect.minY)
            .scaledBy(x: scale, y: scale)
            .translatedBy(x: CGFloat(face.gazeX), y: CGFloat(face.gazeY))
            .translatedBy(x: 18, y: 17)
            .rotated(by: CGFloat(face.tilt) * .pi / 180)
            .translatedBy(x: -18, y: -17)
        return path.applying(transform)
    }
}

/// A number's avatar: a softly lit disc with the number's face on it.
///
/// Lists show one line at a time, so their avatars carry no badge. Places
/// that show a single call, such as the dialer and the in-call view, pass the
/// line badge of that call.
struct ContactFaceAvatar: View {
    @Environment(\.colorScheme) private var colorScheme

    let address: String
    var size: CGFloat = AppMetrics.Avatar.row
    var badgeText: String? = nil
    var badgeColor: Color = ModuleTint.detached.solid

    var body: some View {
        let face = ContactFace.face(for: address)
        disc(face, tint: AvatarTint.tint(for: face))
            .mask {
                Rectangle()
                    .overlay(alignment: .bottomTrailing) {
                        if showsBadge {
                            LineBadge(text: badgeText ?? "", color: .black, height: badgeHeight)
                                .overlay { Capsule().stroke(Color.black, lineWidth: 4) }
                                .offset(badgeOffset)
                                .blendMode(.destinationOut)
                        }
                    }
                    .compositingGroup()
            }
            .shadow(color: .black.opacity(0.14), radius: size * 0.035, y: size * 0.03)
            .overlay(alignment: .bottomTrailing) {
                if showsBadge {
                    LineBadge(text: badgeText ?? "", color: badgeColor, height: badgeHeight)
                        .offset(badgeOffset)
                }
            }
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }

    private func disc(_ face: ContactFace, tint: AvatarTint) -> some View {
        let unit = size / 36
        return ZStack {
            Circle()
                .fill(LinearGradient(
                    colors: [tint.gradientStart, tint.gradientEnd],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ))
            // A highlight at the upper left and a soft shade along the lower
            // edge give the flat disc some volume.
            Circle()
                .fill(RadialGradient(
                    colors: [Color.white.opacity(0.55), Color.white.opacity(0)],
                    center: UnitPoint(x: 0.30, y: 0.24),
                    startRadius: 0,
                    endRadius: size * 0.5
                ))
            Circle()
                .fill(RadialGradient(
                    stops: [
                        .init(color: Color.black.opacity(0), location: 0.72),
                        .init(color: Color.black.opacity(0.13), location: 1),
                    ],
                    center: UnitPoint(x: 0.5, y: 0.42),
                    startRadius: 0,
                    endRadius: size * 0.6
                ))
            ZStack {
                ContactFaceShape(face: face, layer: .blush)
                    .fill(Color(appHex: 0xFF5C7A).opacity(0.3))
                ContactFaceShape(face: face, layer: .fills)
                    .fill(tint.face)
                ContactFaceShape(face: face, layer: .fills)
                    .stroke(tint.face, style: StrokeStyle(lineWidth: unit * 0.7, lineJoin: .round))
                ContactFaceShape(face: face, layer: .strokes)
                    .stroke(
                        tint.face,
                        style: StrokeStyle(lineWidth: unit * 1.9, lineCap: .round, lineJoin: .round)
                    )
            }
            .shadow(color: .black.opacity(0.18), radius: unit * 0.35, y: unit * 0.45)
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .brightness(colorScheme == .dark ? -0.06 : 0)
    }

    private var showsBadge: Bool {
        badgeText != nil && size >= AppMetrics.Avatar.row
    }

    private var badgeHeight: CGFloat {
        if size >= AppMetrics.Avatar.hero { return 22 }
        if size >= AppMetrics.Avatar.large { return 20 }
        return 16
    }

    private var badgeOffset: CGSize {
        size >= AppMetrics.Avatar.large
            ? CGSize(width: 8, height: 3)
            : CGSize(width: 7, height: 4)
    }
}

/// A line shown as a small glass capsule: badge plus carrier or line name.
struct LineChip: View {
    let appearance: LineAppearance

    var body: some View {
        HStack(spacing: 5) {
            if let badgeText = appearance.badgeText {
                LineBadge(text: badgeText, color: appearance.tint.solid)
            }
            Text(verbatim: appearance.carrier ?? appearance.title)
                .font(.appCaptionStrong)
                .lineLimit(1)
        }
        .padding(.leading, appearance.badgeText == nil ? 9 : 3)
        .padding(.trailing, 9)
        .frame(height: AppMetrics.Control.chip)
        .adaptiveGlassSurface(
            cornerRadius: AppMetrics.Control.chip / 2,
            treatment: .clear
        )
        .help(appearance.fullTitle)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(appearance.fullTitle)
    }
}
