import AppKit
import SwiftUI

/// The colours of one module: a soft gradient for avatars and a deeper solid
/// for badges, outgoing bubbles and send buttons.
struct ModuleTint: Equatable {
    let gradientStart: Color
    let gradientEnd: Color
    let face: Color
    let solid: Color

    private init(start: UInt32, end: UInt32, face: UInt32, solid: UInt32) {
        gradientStart = Color(appHex: start)
        gradientEnd = Color(appHex: end)
        self.face = Color(appHex: face)
        self.solid = Color(appHex: solid)
    }

    /// One entry per `ModuleAppearanceRegistry.colorCount`. Every solid keeps
    /// white badge text above 4.5:1 contrast.
    static let palette: [ModuleTint] = [
        ModuleTint(start: 0xD8EEFF, end: 0x8FC2F5, face: 0x1F4E86, solid: 0x2563EB), // blue
        ModuleTint(start: 0xD3F6E9, end: 0x7FD6C2, face: 0x17604F, solid: 0x0B7F73), // teal
        ModuleTint(start: 0xE6DEFF, end: 0xA99BF2, face: 0x40318A, solid: 0x7C3AED), // purple
        ModuleTint(start: 0xFFE0CA, end: 0xFF9F7A, face: 0x8A3A1C, solid: 0xB4471F), // coral
        ModuleTint(start: 0xFFDDD6, end: 0xFF9FAA, face: 0x8E2F45, solid: 0xC0267E), // pink
        ModuleTint(start: 0xFFEDB5, end: 0xFFB96E, face: 0x8A4A12, solid: 0xA15C07), // amber
    ]

    /// Records whose module is unplugged or unknown.
    static let detached = ModuleTint(start: 0xEEF0F4, end: 0xC6CBD6, face: 0x4A5060, solid: 0x6B6F78)

    static func tint(colorIndex: Int?) -> ModuleTint {
        guard let colorIndex else { return detached }
        return palette[((colorIndex % palette.count) + palette.count) % palette.count]
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

/// Eyes and a mouth drawn in a 36-unit square and scaled to the avatar.
struct ContactFaceShape: Shape {
    let face: ContactFace

    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width, rect.height) / 36
        let shift = CGFloat(face.glance) * 1.8
        // The face sits a little above centre so the line badge at the lower
        // right never covers the mouth.
        let lift: CGFloat = 2.2
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + (x + shift) * scale, y: rect.minY + (y - lift) * scale)
        }
        var path = Path()

        func smilingEye(_ x: CGFloat) {
            path.move(to: point(x - 2, 15.6))
            path.addQuadCurve(to: point(x + 2, 15.6), control: point(x, 13.0))
        }
        func restingEye(_ x: CGFloat) {
            path.move(to: point(x - 2, 14.4))
            path.addQuadCurve(to: point(x + 2, 14.4), control: point(x, 17.0))
        }
        func dotEye(_ x: CGFloat) {
            path.move(to: point(x, 13.8))
            path.addLine(to: point(x, 15.6))
        }
        func squareEye(_ x: CGFloat) {
            path.addRect(CGRect(
                x: rect.minX + (x - 1.6 + shift) * scale,
                y: rect.minY + (13.2 - lift) * scale,
                width: 3.2 * scale,
                height: 3.2 * scale
            ))
        }
        func smile(width: CGFloat, y: CGFloat, depth: CGFloat) {
            path.move(to: point(18 - width / 2, y))
            path.addQuadCurve(to: point(18 + width / 2, y), control: point(18, y + depth))
        }
        func flatMouth(width: CGFloat) {
            path.move(to: point(18 - width / 2, 21.6))
            path.addLine(to: point(18 + width / 2, 21.6))
        }

        switch face.expression {
        case .smile:
            smilingEye(12.5)
            smilingEye(23.5)
            smile(width: 8, y: 20.6, depth: 3.6)
        case .dots:
            dotEye(12.5)
            dotEye(23.5)
            smile(width: 8, y: 20.4, depth: 3.4)
        case .flat:
            dotEye(12.5)
            dotEye(23.5)
            flatMouth(width: 6)
        case .wink:
            smilingEye(12.5)
            dotEye(23.5)
            smile(width: 8, y: 20.4, depth: 3.4)
        case .surprised:
            dotEye(12.5)
            dotEye(23.5)
            path.addEllipse(in: CGRect(
                x: rect.minX + (18 - 1.7 + shift) * scale,
                y: rect.minY + (19.8 - lift) * scale,
                width: 3.4 * scale,
                height: 3.4 * scale
            ))
        case .sleepy:
            restingEye(12.5)
            restingEye(23.5)
            smile(width: 5, y: 21, depth: 2)
        case .robot:
            squareEye(12.6)
            squareEye(23.4)
            flatMouth(width: 8)
        }
        return path
    }
}

/// A number's avatar: a soft disc in the module's colour with the number's
/// face on it, and the line badge at the lower right.
struct ContactFaceAvatar: View {
    @Environment(\.colorScheme) private var colorScheme

    let address: String
    var size: CGFloat = AppMetrics.Avatar.row
    var tint: ModuleTint = .detached
    var badgeText: String? = nil
    /// Solid colour of another module this number has also used.
    var secondaryBadgeColor: Color? = nil

    var body: some View {
        disc
            .mask {
                Rectangle()
                    .overlay(alignment: .bottomTrailing) {
                        if showsBadge {
                            badgeFootprint
                                .offset(badgeOffset)
                                .blendMode(.destinationOut)
                        }
                    }
                    .compositingGroup()
            }
            .overlay(alignment: .bottomTrailing) {
                if showsBadge {
                    badgeGroup.offset(badgeOffset)
                }
            }
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }

    private var disc: some View {
        ZStack {
            Circle()
                .fill(LinearGradient(
                    colors: [tint.gradientStart, tint.gradientEnd],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ))
            ContactFaceShape(face: ContactFace.face(for: address))
                .stroke(
                    tint.face,
                    style: StrokeStyle(
                        lineWidth: size * 2.3 / 36,
                        lineCap: .round,
                        lineJoin: .round
                    )
                )
        }
        .frame(width: size, height: size)
        .brightness(colorScheme == .dark ? -0.08 : 0)
        .saturation(colorScheme == .dark ? 0.92 : 1)
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

    private var badgeGroup: some View {
        HStack(spacing: -badgeHeight * 0.6) {
            if let secondaryBadgeColor {
                Circle()
                    .fill(secondaryBadgeColor)
                    .frame(width: badgeHeight, height: badgeHeight)
            }
            LineBadge(text: badgeText ?? "", color: tint.solid, height: badgeHeight)
                .background {
                    if secondaryBadgeColor != nil {
                        Capsule()
                            .fill(Color(nsColor: .windowBackgroundColor))
                            .padding(-1.5)
                    }
                }
        }
    }

    /// The badge's outline grown by 2 pt, cut out of the disc so the badge
    /// stays separated from the avatar on any background.
    private var badgeFootprint: some View {
        HStack(spacing: -badgeHeight * 0.6) {
            if secondaryBadgeColor != nil {
                Circle()
                    .fill(Color.black)
                    .frame(width: badgeHeight, height: badgeHeight)
                    .overlay { Circle().stroke(Color.black, lineWidth: 4) }
            }
            LineBadge(text: badgeText ?? "", color: .black, height: badgeHeight)
                .overlay { Capsule().stroke(Color.black, lineWidth: 4) }
        }
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
