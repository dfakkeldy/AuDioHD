// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Pure text rewriter that injects user-supplied pronunciations into Misaki's
/// native `[word](/ipa/)` link syntax before G2P. Misaki parses such links with
/// `rating: 5` (highest confidence), bypassing both the lexicon and the (removed)
/// BART fallback — so an override always wins.
///
/// Case-insensitive whole-word match; substring matches are rejected ("use" must
/// not match inside "user"). Per-book entries override global entries on conflict.
nonisolated struct PronunciationOverrides: Equatable, Sendable {
    private struct ScopedEntry: Equatable, Sendable {
        let word: String
        let ipa: String
        let source: PronunciationAuditDecision.Source
    }

    let entries: [String: String]
    private let scopedEntries: [ScopedEntry]

    init(entries: [String: String]) {
        self.init(entries: entries, source: .globalOverride)
    }

    init(entries: [String: String], source: PronunciationAuditDecision.Source) {
        self.entries = entries
        self.scopedEntries =
            entries
            .map { ScopedEntry(word: $0.key, ipa: $0.value, source: source) }
            .sorted { $0.word.localizedStandardCompare($1.word) == .orderedAscending }
    }

    private init(scopedEntries: [ScopedEntry]) {
        self.scopedEntries = scopedEntries
        self.entries = Dictionary(
            uniqueKeysWithValues: scopedEntries.map { ($0.word, $0.ipa) })
    }

    /// EPUB instructions outrank automatic built-ins, but never user entries.
    var explicitUserEntries: PronunciationOverrides {
        PronunciationOverrides(
            scopedEntries: scopedEntries.filter { $0.source != .builtInOverride })
    }

    /// Apply overrides to `text`, wrapping each matched whole word in link syntax.
    func apply(to text: String) -> String {
        rewrite(to: text, blockID: "").text
    }

    func rewrite(to text: String, blockID: String) -> PronunciationRewriteResult {
        guard !scopedEntries.isEmpty else {
            return PronunciationRewriteResult(text: text, decisionSeeds: [])
        }
        // One combined regex alternation, case-insensitive, word-boundary guarded.
        // Escape regex metacharacters in keys and skip empty values.
        let escaped =
            scopedEntries
            .map(\.word)
            .filter { !$0.isEmpty }
            .map(NSRegularExpression.escapedPattern(for:))
            .sorted { $0.count > $1.count }  // longest-first so "Postgres" beats "Post"
        guard !escaped.isEmpty else {
            return PronunciationRewriteResult(text: text, decisionSeeds: [])
        }
        let pattern = "\\b(?:" + escaped.joined(separator: "|") + ")\\b"
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        else {
            return PronunciationRewriteResult(text: text, decisionSeeds: [])
        }
        let fullRange = NSRange(location: 0, length: (text as NSString).length)
        let matches = re.matches(in: text, range: fullRange)
        var replacements:
            [(
                range: NSRange,
                matched: String,
                ipa: String,
                decisionSeed: PronunciationDecisionSeed
            )] = []
        replacements.reserveCapacity(matches.count)

        for match in matches {
            guard let range = Range(match.range, in: text) else { continue }
            let matched = String(text[range])
            guard
                let scopedEntry = scopedEntries.first(where: {
                    $0.word.caseInsensitiveCompare(matched) == .orderedSame
                })
            else {
                continue
            }
            if hasContractionApostrophe(in: text, before: range.lowerBound) { continue }
            if isInsideLink(text, at: range.lowerBound) { continue }
            guard
                let wordSpan = PronunciationAuditContext.wordSpan(
                    containing: range,
                    in: text)
            else {
                continue
            }

            replacements.append(
                (
                    range: match.range,
                    matched: matched,
                    ipa: scopedEntry.ipa,
                    decisionSeed: PronunciationDecisionSeed(
                        blockID: blockID,
                        wordStart: wordSpan.lowerBound,
                        wordEnd: wordSpan.upperBound,
                        normalizedWord: PronunciationAuditContext.normalizedWord(matched),
                        sourceWord: matched,
                        sourceContext: PronunciationAuditContext.sourceContext(
                            in: text,
                            wordStart: wordSpan.lowerBound,
                            wordEnd: wordSpan.upperBound),
                        selectedIPA: scopedEntry.ipa,
                        source: scopedEntry.source,
                        ruleID: ruleID(for: scopedEntry),
                        rationale: rationale(for: scopedEntry, matched: matched))
                ))
        }

        // Process replacements right-to-left so index offsets stay valid.
        var result = text
        for replacement in replacements.reversed() {
            guard let range = Range(replacement.range, in: result) else { continue }
            result.replaceSubrange(
                range,
                with: "[\(replacement.matched)](/\(replacement.ipa)/)")
        }
        return PronunciationRewriteResult(
            text: result,
            decisionSeeds: replacements.map { $0.decisionSeed })
    }

    private func hasContractionApostrophe(in text: String, before index: String.Index) -> Bool {
        guard index > text.startIndex else { return false }
        let apostropheIndex = text.index(before: index)
        let previous = text[apostropheIndex]
        guard previous == "'" || previous == "’" else { return false }
        guard apostropheIndex > text.startIndex else { return false }
        return text[text.index(before: apostropheIndex)].isLetter
    }

    /// True if `index` falls inside a `[...](/.../)` link's display text.
    private func isInsideLink(_ s: String, at index: String.Index) -> Bool {
        // Walk back to the nearest '[' that has no following ']' before `index`.
        var i = index
        while i > s.startIndex {
            i = s.index(before: i)
            if s[i] == "]" { return false }  // closed before us → not in a link
            if s[i] == "[" { return true }  // open bracket → we're inside display text
        }
        return false
    }

    /// Merge two maps case-insensitively; `book` wins on conflict.
    static func merging(global: [String: String], book: [String: String]) -> PronunciationOverrides
    {
        merging(global: PronunciationOverrides(entries: global), book: book)
    }

    static func merging(
        global: PronunciationOverrides,
        book: [String: String]
    ) -> PronunciationOverrides {
        var merged = global.scopedEntries
        for (word, ipa) in book.sorted(by: { $0.key < $1.key }) {
            let foldedWord = word.lowercased()
            merged.removeAll { $0.word.lowercased() == foldedWord }
            merged.append(ScopedEntry(word: word, ipa: ipa, source: .bookOverride))
        }
        return PronunciationOverrides(scopedEntries: merged)
    }

    /// Pronunciations Echo always knows, independent of the user's dictionary.
    /// These cover names/terms the bundled English lexicon doesn't have — most
    /// importantly the app author's surname, which a generic OOV approximation
    /// would otherwise mangle or (on older builds) skip entirely. IPA only, no
    /// surrounding slashes — `apply` wraps them in Misaki `[word](/ipa/)` syntax.
    static let builtInDefaults: [String: String] = [
        // "Fakkeldy" → FAK-uhl-dee. Tweakable any time via Settings ▸ Pronunciation
        // (a user entry for the same word always wins — see `withBuiltInDefaults`).
        "Fakkeldy": "fˈækəldi",
        "Campbell": "kˈæmbəl",
        "DeepMind's": "dˈipmˌIndz",
        "DeepMind’s": "dˈipmˌIndz",
        "DeepMind": "dˈipmˌInd",
        "Xcode": "ˈɛks kˈOd",
        "xcassets": "ˈɛks sˈi ˈæsˌɛts",
        "timeframe": "tˈImfɹˌAm",
        "startable": "stˈɑɹɾəbəl",
        "filesystem": "fˈIl sˌɪstəm",
        "lifecycle": "lˈIfsˌIkəl",
        "validator": "vˈælɪdˌAɾəɹ",
        "validators": "vˈælɪdˌAɾəɹz",
        "Pictou": "pˈɪktO",
        "super": "sˈuːpɚ",
        "supercomputer": "sˌuːpɚkəmpjˈuɾəɹ",
        "supercomputers": "sˌuːpɚkəmpjˈuɾəɹz",
        "superforecasters": "sˌuːpɚfˈɔɹkˌæstəɹz",
        "superhuman": "sˌuːpɚhjˈumən",
        "superimposed": "sˌuːpɚɪmpˈOzd",
        "superintelligence": "sˌuːpɚɪntˈɛləʤᵊns",
        "supernatural": "sˌuːpɚnˈæʧəɹəl",
        "superposition": "sˌuːpɚpəzˈɪʃən",
        "supervised": "sˈuːpɚvˌIzd",
        "supervising": "sˈuːpɚvˌIzɪŋ",
        "unsupervised": "ˌʌnsˈuːpɚvˌIzd",
        "re": "ɹi",
        "README": "ɹˈid mˌi",
        "readme": "ɹˈid mˌi",
    ]

    /// The built-in defaults with the user's `entries` layered on top. Matching
    /// is case-insensitive, so a user entry for a word fully replaces the
    /// built-in for that word — no duplicate or ambiguous keys reach `apply`.
    static func withBuiltInDefaults(_ user: [String: String]) -> PronunciationOverrides {
        let userKeysLower = Set(user.keys.map { $0.lowercased() })
        var merged =
            builtInDefaults
            .filter { !userKeysLower.contains($0.key.lowercased()) }
            .map { ScopedEntry(word: $0.key, ipa: $0.value, source: .builtInOverride) }
        merged.append(
            contentsOf: user.map {
                ScopedEntry(word: $0.key, ipa: $0.value, source: .globalOverride)
            })
        return PronunciationOverrides(scopedEntries: merged)
    }

    private func ruleID(for entry: ScopedEntry) -> String {
        let scope: String
        switch entry.source {
        case .bookOverride:
            scope = "book"
        case .globalOverride:
            scope = "global"
        case .builtInOverride:
            scope = "built-in"
        default:
            scope = entry.source.rawValue
        }
        return "override.\(scope).\(PronunciationAuditContext.ruleComponent(entry.word))"
    }

    private func rationale(for entry: ScopedEntry, matched: String) -> String {
        let scope: String
        switch entry.source {
        case .bookOverride:
            scope = "Book"
        case .globalOverride:
            scope = "Global"
        case .builtInOverride:
            scope = "Built-in"
        default:
            scope = entry.source.rawValue
        }
        return "\(scope) override matched “\(matched)”."
    }
}
