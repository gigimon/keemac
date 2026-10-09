import Foundation

/// Interface text from the UI module's string tables (`Resources/Localization/<language>.lproj`).
/// SwiftUI looks string literals up in the main bundle, which a Swift package can't fill, so views pass `L("…")`.
public func L(_ value: String.LocalizationValue) -> String {
    String(localized: value, bundle: UIResources.localized)
}

/// For English words with several meanings: a stable key with the English text as its default.
public func L(_ key: StaticString, default value: String.LocalizationValue) -> String {
    String(localized: key, defaultValue: value, bundle: UIResources.localized)
}

enum UIResources {
    /// The `.lproj` for the user's language (including the per-app language from System Settings).
    /// Picked explicitly: Foundation matches a package bundle to the main bundle's languages,
    /// and the unbundled `swift run` binary has none, so it would always fall back to English.
    static let localized: Bundle = {
        let language = Bundle.preferredLocalizations(from: Bundle.module.localizations, forPreferences: Locale.preferredLanguages).first
        return language.flatMap(localizationBundle(for:)) ?? .module
    }()

    static func localizationBundle(for language: String) -> Bundle? {
        Bundle.module.path(forResource: language, ofType: "lproj").flatMap(Bundle.init(path:))
    }
}
