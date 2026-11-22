import Foundation
import SwiftUI

enum AppLanguage: String, CaseIterable, Identifiable {
    static let defaultsKey = "CellDock.AppLanguage.v1"

    case simplifiedChinese = "zh-Hans"
    case english = "en"
    case japanese = "ja"
    case french = "fr"

    var id: String { rawValue }

    var locale: Locale {
        Locale(identifier: rawValue)
    }

    /// Language names intentionally use their native spelling so the picker
    /// remains understandable even if the currently selected language is not.
    var nativeName: String {
        switch self {
        case .simplifiedChinese: return "中文"
        case .english: return "English"
        case .japanese: return "日本語"
        case .french: return "Français"
        }
    }

    static var storedPreference: AppLanguage {
        guard let rawValue = UserDefaults.standard.string(forKey: defaultsKey),
              let language = AppLanguage(rawValue: rawValue) else {
            return preferredSystemLanguage()
        }
        return language
    }

    static func preferredSystemLanguage(
        from identifiers: [String] = Locale.preferredLanguages
    ) -> AppLanguage {
        for identifier in identifiers {
            let normalized = identifier.replacingOccurrences(of: "_", with: "-").lowercased()
            if normalized == "zh" || normalized.hasPrefix("zh-hans") ||
                normalized.hasPrefix("zh-cn") || normalized.hasPrefix("zh-sg") {
                return .simplifiedChinese
            }
            if normalized == "en" || normalized.hasPrefix("en-") { return .english }
            if normalized == "ja" || normalized.hasPrefix("ja-") { return .japanese }
            if normalized == "fr" || normalized.hasPrefix("fr-") { return .french }
        }
        return .english
    }
}

extension Notification.Name {
    static let cellDockAppLanguageDidChange = Notification.Name(
        "CellDock.AppLanguageDidChange"
    )
}

/// Errors whose `errorDescription` is already localized in the selected app
/// language via `L10n.tr`. `L10n.error(_:underlying:)` preserves their message
/// instead of replacing it with an opaque NSError domain/code reference.
protocol AppLocalizedError: LocalizedError {}

enum L10n {
    static func tr(_ key: String, _ arguments: CVarArg...) -> String {
        let language = AppLanguage.storedPreference
        let bundle = localizedBundle(for: language) ?? .main
        let value = bundle.localizedString(forKey: key, value: key, table: nil)
        guard !arguments.isEmpty else { return value }
        return String(format: value, locale: language.locale, arguments: arguments)
    }

    static func bundle(for language: AppLanguage) -> Bundle? {
        localizedBundle(for: language)
    }

    /// Keeps user-facing failures in the selected app language. App-owned
    /// `AppLocalizedError` values already localize via `L10n.tr`, so their
    /// description is preserved; external or system errors fall back to a
    /// stable support reference instead.
    static func error(_ key: String, underlying error: Error) -> String {
        if let appError = error as? AppLocalizedError,
           let description = appError.errorDescription?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !description.isEmpty {
            return tr(key, description)
        }
        let nsError = error as NSError
        let reference = tr("错误代码 %@（%lld）", nsError.domain, Int64(nsError.code))
        return tr(key, reference)
    }

    private static func localizedBundle(for language: AppLanguage) -> Bundle? {
        guard let path = Bundle.main.path(forResource: language.rawValue, ofType: "lproj") else {
            return nil
        }
        return Bundle(path: path)
    }
}

@MainActor
final class AppLanguageController: ObservableObject {
    static let shared = AppLanguageController()

    @Published private(set) var selectedLanguage: AppLanguage

    private init() {
        selectedLanguage = .storedPreference
    }

    func select(_ language: AppLanguage) {
        guard language != selectedLanguage else { return }
        UserDefaults.standard.set(language.rawValue, forKey: AppLanguage.defaultsKey)
        selectedLanguage = language
        NotificationCenter.default.post(name: .cellDockAppLanguageDidChange, object: language)
    }
}

private struct AppLanguageEnvironmentModifier: ViewModifier {
    @ObservedObject private var languageController = AppLanguageController.shared

    func body(content: Content) -> some View {
        content.environment(\.locale, languageController.selectedLanguage.locale)
    }
}

extension View {
    func cellDockLanguageEnvironment() -> some View {
        modifier(AppLanguageEnvironmentModifier())
    }
}
