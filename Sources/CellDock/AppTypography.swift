import SwiftUI

/// The app-wide type scale.
///
/// Every text style in CellDock comes from these eight tokens so sizes and
/// weights stay consistent between pages. Only three weights are used
/// (regular, medium, semibold), and no text is smaller than 10 pt.
///
/// The one exception is text that scales with its control, such as the digits
/// on a dial-pad key: those derive their size from the key instead.
extension Font {
    /// 26 pt semibold: dial-pad number, call timer.
    static let appDisplay = Font.system(size: 26, weight: .semibold)

    /// 20 pt semibold: main title of a detail page.
    static let appTitle = Font.system(size: 20, weight: .semibold)

    /// 15 pt semibold: pane, card and settings-group titles.
    static let appHeadline = Font.system(size: 15, weight: .semibold)

    /// 13 pt regular: list primary line, message text, form content, buttons.
    static let appBody = Font.system(size: 13)

    /// 13 pt semibold: emphasized body text such as an unread row.
    static let appBodyStrong = Font.system(size: 13, weight: .semibold)

    /// 12 pt regular: list secondary line, field names, explanations.
    static let appCallout = Font.system(size: 12)

    /// 12 pt medium: emphasized callout such as a chip or tab label.
    static let appCalloutStrong = Font.system(size: 12, weight: .medium)

    /// 11 pt regular: timestamps, group captions, hints.
    static let appCaption = Font.system(size: 11)

    /// 11 pt medium: emphasized caption such as a group caption.
    static let appCaptionStrong = Font.system(size: 11, weight: .medium)

    /// 10 pt semibold: line badges and counters.
    static let appMicro = Font.system(size: 10, weight: .semibold)

    /// 12 pt monospaced: AT console, IMEI, ICCID, file names.
    static let appMono = Font.system(size: 12, design: .monospaced)

    /// An SF Symbol size from the icon scale. Symbols are sized with fonts,
    /// so they get their own seven steps instead of borrowing text styles.
    static func appSymbol(_ size: AppMetrics.SymbolSize, weight: Font.Weight = .medium) -> Font {
        .system(size: size.rawValue, weight: weight)
    }
}

/// Shared sizes for avatars, rows, controls, corner radii and spacing.
enum AppMetrics {
    enum SymbolSize: CGFloat {
        /// Chevrons, direction arrows and other marks beside text.
        case indicator = 10
        /// Icons inside a line of text.
        case inline = 12
        /// Icons in compact rows and small buttons.
        case small = 14
        /// Icons in regular buttons.
        case button = 16
        /// The window rail and feature icons.
        case rail = 20
        /// Icons that head a card or sheet.
        case large = 24
        /// Empty states and placeholders.
        case hero = 32
    }

    /// Avatar diameters. Line badges only appear from `row` upwards.
    enum Avatar {
        static let header: CGFloat = 28
        static let row: CGFloat = 36
        static let large: CGFloat = 48
        static let hero: CGFloat = 64
    }

    enum Row {
        static let single: CGFloat = 36
        static let header: CGFloat = 52
        static let double: CGFloat = 56
    }

    enum Control {
        static let chip: CGFloat = 22
        static let regular: CGFloat = 28
        static let bar: CGFloat = 36
        static let play: CGFloat = 40
    }

    enum Radius {
        static let control: CGFloat = 6
        static let row: CGFloat = 8
        static let card: CGFloat = 16
        static let bubble: CGFloat = 17
    }

    enum Spacing {
        static let xSmall: CGFloat = 4
        static let small: CGFloat = 8
        static let medium: CGFloat = 12
        static let large: CGFloat = 16
        static let xLarge: CGFloat = 24
    }
}
