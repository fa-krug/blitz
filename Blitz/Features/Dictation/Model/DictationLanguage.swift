import Foundation

/// Which transcriber locale Dictation listens in; no choice follows the system's languages.
enum DictationLanguage {
    /// The chosen locale if the transcriber has it, else the first preferred language it covers.
    static func resolve(choice: String?, preferred: [String], supported: [Locale]) -> Locale? {
        if let choice, let chosen = supported.first(where: { matches($0, choice) }) {
            return chosen
        }
        for language in preferred {
            if let exact = supported.first(where: { matches($0, language) }) { return exact }
            let wanted = Locale(identifier: language)
            guard let code = wanted.language.languageCode else { continue }
            let sameLanguage = supported.filter { $0.language.languageCode == code }
            let sameRegion = sameLanguage.first { $0.region == wanted.region }
            if let match = sameRegion ?? sameLanguage.first { return match }
        }
        return nil
    }

    /// The picker's order: by name in the reader's own language.
    static func sorted(_ locales: [Locale], in display: Locale) -> [Locale] {
        locales.sorted {
            name(of: $0, in: display).localizedStandardCompare(name(of: $1, in: display))
                == .orderedAscending
        }
    }

    /// "English (United States)", as the reader's language spells it.
    static func name(of locale: Locale, in display: Locale) -> String {
        display.localizedString(forIdentifier: locale.identifier) ?? locale.identifier
    }

    /// `en_US` and `en-US` are one locale; how an identifier was written is no reason to miss it.
    static func matches(_ locale: Locale, _ identifier: String) -> Bool {
        locale.identifier(.bcp47) == Locale(identifier: identifier).identifier(.bcp47)
    }
}
