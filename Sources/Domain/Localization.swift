import Foundation

/// Text from the Domain module's string tables (`Resources/Localization`): error messages.
/// The language is picked explicitly, as in the UI module's `L`.
func L(_ value: String.LocalizationValue) -> String {
    String(localized: value, bundle: localizedBundle)
}

private let localizedBundle: Bundle = {
    let language = Bundle.preferredLocalizations(from: Bundle.module.localizations, forPreferences: Locale.preferredLanguages).first
    return language
        .flatMap { Bundle.module.path(forResource: $0, ofType: "lproj") }
        .flatMap(Bundle.init(path:)) ?? .module
}()
