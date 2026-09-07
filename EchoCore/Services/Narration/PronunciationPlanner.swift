// SPDX-License-Identifier: GPL-3.0-or-later

nonisolated final class PronunciationPlanner {
    enum PlanningError: Error {
        case invalidRawG2POutput(KokoroG2P.Result)
    }

    private let g2p: KokoroG2P
    private let injectedG2PResult: ((String, String) -> KokoroG2P.Result)?
    private let vocab: KokoroPhonemeVocab
    private struct ResultKey: Hashable {
        let input: String
        let display: String
    }
    // Render-unit scoped. Bound both count and text size so long chapters or
    // split probes cannot retain an unbounded set of token evidence.
    private var results: [ResultKey: KokoroG2P.Result] = [:]

    init() throws {
        self.g2p = KokoroG2P()
        self.injectedG2PResult = nil
        self.vocab = try KokoroPhonemeVocab()
    }

    /// Concrete G2P-result injection for planner integration tests. The
    /// renderer still owns all chunking, audit, and synthesis decisions.
    init(
        g2pResult: @escaping (String, String) -> KokoroG2P.Result
    ) throws {
        self.g2p = KokoroG2P()
        self.injectedG2PResult = g2pResult
        self.vocab = try KokoroPhonemeVocab()
    }

    func plan(displayText: String, g2pInputText: String) throws -> PlannedSynthesisChunk {
        let result = result(for: g2pInputText, displayText: displayText)
        // Defense-in-depth: drop MisakiSwift's out-of-vocabulary marker before
        // validation so a stray unencodable glyph can never abort the whole chapter
        // render via `validatedIDs`. In today's MisakiSwift the fallback network
        // already maps unphonemizable tokens to a schwa or "" (never `❓`), so this
        // is future-proofing against `unk` leakage rather than a currently-reachable
        // path — the real protection against a bricked render is entry-time IPA
        // validation in `PronunciationOverrideStore`, which keeps unsupported
        // characters out of overrides. `validatedIDs` stays strict for everything
        // else, so a genuine authoring bug (e.g. a bad built-in default) still fails
        // loudly. Dropping the marker matches the historical lenient `ids()` behavior.
        let phonemes = result.phonemes.filter { $0 != KokoroPhonemeVocab.oovMarker }
        let phonemeIDs: [Int32]
        do {
            phonemeIDs = try vocab.validatedIDs(forPhonemes: phonemes)
        } catch {
            guard case .matched = result.pronunciationEvidenceValidation,
                result.tokenEvidence.contains(where: {
                    PronunciationAuditContext.isRejectedRawG2POutput(
                        $0.selectedPhonemes)
                })
            else {
                throw error
            }
            throw PlanningError.invalidRawG2POutput(result)
        }
        return PlannedSynthesisChunk(
            displayText: displayText,
            g2pInputText: g2pInputText,
            phonemes: phonemes,
            phonemeIDs: phonemeIDs,
            wordCount: WordTokenizer.words(in: displayText).count,
            pronunciationFallbackHits: result.fallbackHits,
            pronunciationTokenEvidence: result.tokenEvidence,
            pronunciationEvidenceValidation: result.pronunciationEvidenceValidation,
            pronunciationAuditDiagnostics: result.diagnostics)
    }

    /// Plans text whose pronunciation choices have already been resolved.
    func planResolved(_ resolvedText: String) throws -> PlannedSynthesisChunk {
        try plan(
            displayText: MisakiPronunciationMarkup.displayText(from: resolvedText),
            g2pInputText: resolvedText
        )
    }

    /// Last-resort speech preservation for a verified invalid raw G2P result.
    /// The authored surface remains the chunk display text, while the trusted
    /// bundled engine speaks its words letter by letter. Token evidence is
    /// intentionally omitted because the spelling input does not address the
    /// authored word ranges; the rejected raw result remains the audit receipt.
    func planDeterministicSpellingRescue(displayText: String) throws -> PlannedSynthesisChunk {
        let spellingInput = WordTokenizer.words(in: displayText)
            .map { word in
                word.filter { $0.isLetter || $0.isNumber }
                    .map(String.init)
                    .joined(separator: " ")
            }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
        guard !spellingInput.isEmpty else {
            throw PlanningError.invalidRawG2POutput(
                KokoroG2P.Result(
                    phonemes: "",
                    fallbackHits: [],
                    tokenEvidence: [],
                    pronunciationEvidenceValidation: .matched))
        }

        let result = g2p.result(for: spellingInput)
        let phonemes = result.phonemes.filter { $0 != KokoroPhonemeVocab.oovMarker }
        let phonemeIDs = try vocab.validatedIDs(forPhonemes: phonemes)
        return PlannedSynthesisChunk(
            displayText: displayText,
            g2pInputText: spellingInput,
            phonemes: phonemes,
            phonemeIDs: phonemeIDs,
            wordCount: WordTokenizer.words(in: displayText).count,
            pronunciationFallbackHits: [],
            pronunciationEvidenceValidation: .matched)
    }

    /// Phoneme count for `text`, reusing the planner's already-loaded G2P.
    ///
    /// Chunkers need this to size splits; routing it through the planner keeps
    /// the ~12 MB Misaki lexicon loaded exactly once per render unit instead of
    /// forcing every caller to construct a second `KokoroG2P`.
    func phonemeCount(for text: String) -> Int {
        result(for: text, displayText: MisakiPronunciationMarkup.displayText(from: text)).phonemes
            .count
    }

    func validatedBaseIPA(for normalizedWord: String) -> String? {
        let result = g2p.result(for: normalizedWord)
        guard case .matched = result.pronunciationEvidenceValidation,
            result.tokenEvidence.count == 1,
            let evidence = result.tokenEvidence.first,
            !evidence.usedFallback,
            let rating = evidence.rating,
            rating >= 3,
            PronunciationAuditContext.normalizedWord(evidence.text) == normalizedWord,
            !evidence.selectedPhonemes.isEmpty
        else {
            return nil
        }
        return evidence.selectedPhonemes
    }

    /// Kokoro vocabulary IDs for an already-selected IPA value, excluding the
    /// synthetic boundary tokens required around a complete synthesis request.
    func phonemeIDs(forIPA ipa: String) throws -> [Int32] {
        Array(try vocab.validatedIDs(forPhonemes: ipa).dropFirst().dropLast())
    }

    private func result(for input: String, displayText: String) -> KokoroG2P.Result {
        let key = ResultKey(input: input, display: displayText)
        if let cached = results[key] { return cached }
        let value: KokoroG2P.Result
        if let injectedG2PResult {
            value = injectedG2PResult(input, displayText)
        } else {
            value = g2p.result(for: input, displayText: displayText)
        }
        if input.utf8.count + displayText.utf8.count <= 8_192 {
            if results.count >= 64 { results.removeAll(keepingCapacity: true) }
            results[key] = value
        }
        return value
    }
}
