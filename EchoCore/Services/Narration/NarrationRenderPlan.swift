// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

enum NarrationRenderPlanError: Error, Equatable {
    case contextualEvidenceIdentityMismatch
}

struct NarrationRenderPlan: Equatable, Sendable {
    let blocks: [NarrationPlannedBlock]

    var pronunciationAuditDiagnostics: [PronunciationAuditDiagnostic] {
        blocks.flatMap(\.pronunciationAuditDiagnostics)
    }
}

struct NarrationPreparedBlock: Equatable, Sendable {
    let block: EPubBlockRecord
    let pronunciationDecisionSeeds: [PronunciationDecisionSeed]
}

struct NarrationPlannedBlock: Equatable, Sendable {
    let blockID: String
    let originalBlock: EPubBlockRecord
    let synthesisChunks: [PlannedSynthesisChunk]
    let pronunciationDecisions: [PronunciationAuditDecision]
    let pronunciationDecisionDiagnostics: [PronunciationAuditDiagnostic]
    let trailingSilence: NarrationPlannedSilence?

    var isSpeakable: Bool { !synthesisChunks.isEmpty }

    var pronunciationAuditDiagnostics: [PronunciationAuditDiagnostic] {
        pronunciationDecisionDiagnostics
            + synthesisChunks.enumerated().flatMap {
                chunkIndex, chunk in
                chunk.pronunciationAuditDiagnostics.map { diagnostic in
                    PronunciationAuditDiagnostic(
                        reason: diagnostic.reason,
                        blockID: blockID,
                        chunkIndex: chunkIndex,
                        chapterIndex: diagnostic.chapterIndex,
                        expectedDisplayText: diagnostic.expectedDisplayText,
                        reconstructedSpokenSurface: diagnostic.reconstructedSpokenSurface,
                        fallbackHits: diagnostic.fallbackHits,
                        finalPhonemes: diagnostic.finalPhonemes,
                        reconstructedTokenPhonemes: diagnostic.reconstructedTokenPhonemes)
                }
            }
            + synthesisChunks.enumerated().compactMap {
                chunkIndex, chunk in
                switch chunk.pronunciationEvidenceValidation {
                case .matched:
                    return nil
                case .mismatch(let expectedDisplayText, let reconstructedSpokenSurface):
                    return PronunciationAuditDiagnostic(
                        reason: .spokenSurfaceMismatch,
                        blockID: blockID,
                        chunkIndex: chunkIndex,
                        expectedDisplayText: expectedDisplayText,
                        reconstructedSpokenSurface: reconstructedSpokenSurface,
                        fallbackHits: chunk.pronunciationFallbackHits)
                case .phonemeSequenceMismatch(let finalPhonemes, let reconstructedTokenPhonemes):
                    return PronunciationAuditDiagnostic(
                        reason: .phonemeSequenceMismatch,
                        blockID: blockID,
                        chunkIndex: chunkIndex,
                        expectedDisplayText: chunk.displayText,
                        reconstructedSpokenSurface: chunk.displayText,
                        fallbackHits: chunk.pronunciationFallbackHits,
                        finalPhonemes: finalPhonemes,
                        reconstructedTokenPhonemes: reconstructedTokenPhonemes)
                }
            }
    }
}

enum NarrationPlannedSilence: Equatable, Sendable {
    case paragraph
    case heading
    case sectionBreak

    var duration: TimeInterval {
        switch self {
        case .paragraph:
            return 0.18
        case .heading:
            return 0.35
        case .sectionBreak:
            return 0.85
        }
    }
}

nonisolated enum NarrationRenderPlanner {
    static func make(
        blocks: [EPubBlockRecord],
        overrides: PronunciationOverrides,
        pronunciationPack: EnglishPronunciationPack = .empty,
        pronunciationAuditPack: EnglishPronunciationAuditPack = .empty,
        contextualEvidence: [ContextualPronunciationKey: ContextualPronunciationEvidence] = [:],
        requiresContextualEvidence: Bool = false,
        maxChars: Int = 350,
        maxPhonemes: Int = 420,
        pronunciationPlanner: PronunciationPlanner? = nil
    ) throws -> NarrationRenderPlan {
        try make(
            preparedBlocks: blocks.map { block in
                var preparedBlock = block
                if let cueText = NarrationCodeBlockCue.spokenText(for: block) {
                    preparedBlock.text = cueText
                }
                return NarrationPreparedBlock(
                    block: preparedBlock,
                    pronunciationDecisionSeeds: [])
            },
            overrides: overrides,
            pronunciationPack: pronunciationPack,
            pronunciationAuditPack: pronunciationAuditPack,
            contextualEvidence: contextualEvidence,
            requiresContextualEvidence: requiresContextualEvidence,
            maxChars: maxChars,
            maxPhonemes: maxPhonemes,
            pronunciationPlanner: pronunciationPlanner)
    }

    static func make(
        preparedBlocks: [NarrationPreparedBlock],
        overrides: PronunciationOverrides,
        pronunciationPack: EnglishPronunciationPack = .empty,
        pronunciationAuditPack: EnglishPronunciationAuditPack = .empty,
        contextualEvidence: [ContextualPronunciationKey: ContextualPronunciationEvidence] = [:],
        requiresContextualEvidence: Bool = false,
        maxChars: Int = 350,
        maxPhonemes: Int = 420,
        pronunciationPlanner: PronunciationPlanner? = nil
    ) throws -> NarrationRenderPlan {
        // One planner owns the single `KokoroG2P` (and its ~12 MB lexicon) for
        // this render unit; the chunker sizes splits via its phoneme count.
        let planner: PronunciationPlanner
        if let pronunciationPlanner {
            planner = pronunciationPlanner
        } else {
            planner = try PronunciationPlanner()
        }
        let candidateAnalyzer = PronunciationCandidateAnalyzer(
            productionPack: pronunciationPack,
            auditPack: pronunciationAuditPack)
        let resolvedPhonemeCount = planner.phonemeCount(for:)
        let candidates = preparedBlocks.filter { preparedBlock in
            let block = preparedBlock.block
            guard block.text?.isEmpty == false else { return false }
            return !block.isHidden
        }

        var planned: [NarrationPlannedBlock] = []
        var unusedContextualEvidence = contextualEvidence
        for preparedBlock in candidates {
            try Task.checkCancellation()
            let block = preparedBlock.block
            let isCode = EPubBlockRecord.Kind(rawValue: block.blockKind) == .code
            let normalized =
                isCode
                ? (block.text ?? "")
                : TextNormalizer.normalize(block.text ?? "")
            if !isCode, isDecorativeSeparator(normalized) {
                planned.append(
                    NarrationPlannedBlock(
                        blockID: block.id,
                        originalBlock: block,
                        synthesisChunks: [],
                        pronunciationDecisions: [],
                        pronunciationDecisionDiagnostics: [],
                        trailingSilence: .sectionBreak))
                continue
            }

            let resolved: String
            var decisionSeeds: [PronunciationDecisionSeed]
            if isCode {
                // The prepared text is already the exact spoken caption/fallback.
                // Keep code cues outside prose and pronunciation rewrites so the
                // synthesis input matches NarrationService's cache signature.
                resolved = normalized
                decisionSeeds = []
            } else {
                let overrideResult = overrides.rewrite(to: normalized, blockID: block.id)
                let universalResult = UniversalPronunciationResolver.rewrite(
                    to: overrideResult.text,
                    blockID: block.id,
                    pack: pronunciationPack,
                    basePronunciation: planner.validatedBaseIPA(for:))
                let homographResult = HomographPronunciationResolver.rewrite(
                    to: universalResult.text,
                    blockID: block.id)
                decisionSeeds = uniqueDecisionSeeds(
                    preparedBlock.pronunciationDecisionSeeds
                        + overrideResult.decisionSeeds
                        + universalResult.decisionSeeds
                        + homographResult.decisionSeeds)
                resolved = homographResult.text
            }
            let blockDisplayText = MisakiPronunciationMarkup.displayText(from: resolved)
            let fragments = NarrationTextChunker.splitResolved(
                resolved,
                maxPhonemes: maxPhonemes,
                phonemeCount: resolvedPhonemeCount)
            var synthesisChunks: [PlannedSynthesisChunk] = []
            var wordBase = 0
            for fragment in fragments {
                let chunk: PlannedSynthesisChunk
                do {
                    chunk = try planner.planResolved(fragment)
                } catch let error as PronunciationPlanner.PlanningError {
                    guard case .invalidRawG2POutput(let rawResult) = error else {
                        throw error
                    }
                    let rawTokenDecisionSeeds: [PronunciationDecisionSeed] =
                        rawResult.tokenEvidence.compactMap { evidence -> PronunciationDecisionSeed? in
                        let normalizedWord = PronunciationAuditContext.normalizedWord(evidence.text)
                        guard PronunciationAuditContext.isRejectedRawG2POutput(
                            evidence.selectedPhonemes)
                        else {
                            return nil
                        }
                        return PronunciationAuditContext.decisionSeed(
                            for: evidence,
                            blockID: block.id,
                            chunkDisplayText: MisakiPronunciationMarkup.displayText(from: fragment),
                            blockDisplayText: blockDisplayText,
                            wordBase: wordBase,
                            isComparisonCandidate:
                                !pronunciationAuditPack.alternatives(for: normalizedWord).isEmpty
                                    || (pronunciationPack.hasExplicitCandidate(for: normalizedWord)
                                        && pronunciationPack.automaticCandidate(
                                            for: normalizedWord) == nil))
                    }
                    decisionSeeds = uniqueDecisionSeeds(
                        decisionSeeds + prioritizingContextualFamilySeeds(
                            rawTokenDecisionSeeds,
                            contextualEvidence: unusedContextualEvidence))
                    let rescueChunk = try planner.planDeterministicSpellingRescue(
                        displayText: MisakiPronunciationMarkup.displayText(from: fragment))
                    synthesisChunks.append(rescueChunk)
                    wordBase += rescueChunk.wordCount
                    continue
                }
                let tokenDecisionSeeds = chunk.pronunciationTokenEvidence.compactMap { evidence in
                    let normalizedWord = PronunciationAuditContext.normalizedWord(evidence.text)
                    return PronunciationAuditContext.decisionSeed(
                        for: evidence,
                        blockID: block.id,
                        chunkDisplayText: chunk.displayText,
                        blockDisplayText: blockDisplayText,
                        wordBase: wordBase,
                        isComparisonCandidate:
                            !pronunciationAuditPack.alternatives(for: normalizedWord).isEmpty
                                || (pronunciationPack.hasExplicitCandidate(for: normalizedWord)
                                    && pronunciationPack.automaticCandidate(
                                        for: normalizedWord) == nil))
                }
                // Explicit rewrite-stage decisions remain first so they win any
                // collision with evidence emitted by the final G2P pass.
                decisionSeeds = uniqueDecisionSeeds(
                    decisionSeeds + prioritizingContextualFamilySeeds(
                        tokenDecisionSeeds,
                        contextualEvidence: unusedContextualEvidence))
                synthesisChunks.append(chunk)
                wordBase += chunk.wordCount
            }
            decisionSeeds = try decisionSeeds.map { seed in
                let key = ContextualPronunciationKey(
                    blockID: seed.blockID,
                    wordStart: seed.wordStart,
                    wordEnd: seed.wordEnd)
                guard
                    let evidence = unusedContextualEvidence.removeValue(
                        forKey: key)
                else {
                    return seed
                }
                try validateContextualEvidence(evidence, for: seed)
                return seed.attachingContextualEvidence(evidence)
            }
            let fallbackHits = synthesisChunks.flatMap(\.pronunciationFallbackHits)
            decisionSeeds = decisionSeeds.map { seed in
                guard let evidence = candidateAnalyzer.evidence(
                    for: seed,
                    fallbackHits: fallbackHits,
                    isWatchWord: PronunciationWatchVocabulary.words.contains(seed.normalizedWord))
                else {
                    return seed
                }
                return seed.attachingAdvisoryEvidence(evidence)
            }
            let pronunciationMaterialization = materializedPronunciationEvidence(
                from: decisionSeeds,
                synthesisChunks: synthesisChunks,
                requiresContextualEvidence: requiresContextualEvidence)
            planned.append(
                NarrationPlannedBlock(
                    blockID: block.id,
                    originalBlock: block,
                    synthesisChunks: synthesisChunks,
                    pronunciationDecisions: pronunciationMaterialization.decisions,
                    pronunciationDecisionDiagnostics: pronunciationMaterialization.diagnostics,
                    trailingSilence: nil))
        }

        guard unusedContextualEvidence.isEmpty else {
            throw NarrationRenderPlanError.contextualEvidenceIdentityMismatch
        }
        return NarrationRenderPlan(blocks: attachTrailingSilences(to: planned))
    }

    /// Binds portable rewrite metadata to the exact final phoneme and token-ID
    /// slice dispatched to Kokoro. A seed without one uniquely proven, matching
    /// slice is suppressed and diagnosed rather than attributed to unrelated audio.
    struct PronunciationDecisionMaterialization: Equatable {
        let decisions: [PronunciationAuditDecision]
        let diagnostics: [PronunciationAuditDiagnostic]
    }

    static func materializedPronunciationEvidence(
        from seeds: [PronunciationDecisionSeed],
        synthesisChunks: [PlannedSynthesisChunk],
        requiresContextualEvidence: Bool = false
    ) -> PronunciationDecisionMaterialization {
        var decisions: [PronunciationAuditDecision] = []
        var diagnostics: [PronunciationAuditDiagnostic] = []

        for seed in seeds {
            if requiresEvidenceOnlyMaterialization(seed) {
                decisions.append(seed.evidenceOnlyMaterialized())
                let owner = owningMatchedChunk(for: seed, in: synthesisChunks)
                diagnostics.append(
                    decisionEvidenceMismatchDiagnostic(
                        for: seed,
                        chunkIndex: owner?.index ?? -1,
                        fallbackHits: owner?.chunk.pronunciationFallbackHits ?? [],
                        finalIPA: nil))
                continue
            }

            var wordBase = 0
            var selections: [FinalPronunciationSelection] = []
            for (chunkIndex, chunk) in synthesisChunks.enumerated() {
                if let selection = finalPronunciationSelection(
                    for: seed,
                    in: chunk,
                    wordBase: wordBase,
                    chunkIndex: chunkIndex),
                    !selections.contains(selection)
                {
                    selections.append(selection)
                }
                wordBase += chunk.wordCount
            }

            guard selections.count == 1, let selection = selections.first else {
                if let owner = owningMatchedChunk(for: seed, in: synthesisChunks) {
                    diagnostics.append(
                        decisionEvidenceMismatchDiagnostic(
                            for: seed,
                            chunkIndex: owner.index,
                            fallbackHits: owner.chunk.pronunciationFallbackHits,
                            finalIPA: selections.first?.selectedIPA))
                }
                continue
            }

            let normalizedSeedIPA = dispatchNormalizedIPA(
                seed.selectedIPA,
                forWord: seed.normalizedWord)
            guard selection.selectedIPA == normalizedSeedIPA else {
                diagnostics.append(
                    decisionEvidenceMismatchDiagnostic(
                        for: seed,
                        chunkIndex: selection.chunkIndex,
                        fallbackHits: selection.fallbackHits,
                        finalIPA: selection.selectedIPA))
                continue
            }
            let decision = seed.materialized(
                selectedIPA: selection.selectedIPA,
                kokoroTokenIDs: selection.kokoroTokenIDs)
            decisions.append(decision)
            if requiresContextualEvidence,
                decision.contextualEvidence == nil,
                PronunciationAuditContext.requiresContextualEvidence(
                    normalizedWord: decision.normalizedWord,
                    source: decision.source)
            {
                diagnostics.append(
                    PronunciationAuditDiagnostic(
                        reason: .missingContextualEvidence,
                        blockID: decision.blockID,
                        chunkIndex: selection.chunkIndex,
                        expectedDisplayText: decision.sourceWord,
                        reconstructedSpokenSurface: "",
                        fallbackHits: selection.fallbackHits))
            }
        }

        return PronunciationDecisionMaterialization(
            decisions: decisions,
            diagnostics: diagnostics)
    }

    private static func requiresEvidenceOnlyMaterialization(
        _ seed: PronunciationDecisionSeed
    ) -> Bool {
        guard let advisoryEvidence = seed.advisoryEvidence else { return false }
        return InvalidG2PAuditReceipt.hasVerifiedProvenance(
            normalizedWord: seed.normalizedWord,
            sourceWord: seed.sourceWord,
            selectedIPA: seed.selectedIPA,
            source: seed.source,
            ruleID: seed.ruleID,
            candidateID: seed.candidateID,
            candidatePackVersion: seed.candidatePackVersion,
            derivationBase: seed.derivationBase,
            derivationRuleID: seed.derivationRuleID,
            contextualEvidence: seed.contextualEvidence,
            advisoryEvidence: advisoryEvidence)
    }

    private static func validateContextualEvidence(
        _ evidence: ContextualPronunciationEvidence,
        for seed: PronunciationDecisionSeed
    ) throws {
        guard
            ContextualPronunciationEvidenceValidator.isValidPhaseTwo(
                evidence,
                blockID: seed.blockID,
                wordStart: seed.wordStart,
                wordEnd: seed.wordEnd,
                normalizedWord: seed.normalizedWord,
                source: seed.source)
        else {
            throw NarrationRenderPlanError.contextualEvidenceIdentityMismatch
        }
    }

    private struct FinalPronunciationSelection: Equatable {
        let selectedIPA: String
        let kokoroTokenIDs: [Int32]
        let chunkIndex: Int
        let fallbackHits: [PronunciationFallbackHit]
    }

    private static func finalPronunciationSelection(
        for seed: PronunciationDecisionSeed,
        in chunk: PlannedSynthesisChunk,
        wordBase: Int,
        chunkIndex: Int
    ) -> FinalPronunciationSelection? {
        guard case .matched = chunk.pronunciationEvidenceValidation,
            chunk.phonemeIDs.count == chunk.phonemes.count + 2,
            !chunk.pronunciationTokenEvidence.isEmpty
        else {
            return nil
        }

        let evidence = chunk.pronunciationTokenEvidence
        let interiorIDs = Array(chunk.phonemeIDs.dropFirst().dropLast())
        var selections: [FinalPronunciationSelection] = []

        for lowerIndex in evidence.indices {
            guard !PronunciationAuditContext.normalizedWord(evidence[lowerIndex].text).isEmpty
            else {
                continue
            }

            for upperIndex in lowerIndex..<evidence.endIndex {
                guard !PronunciationAuditContext.normalizedWord(evidence[upperIndex].text).isEmpty
                else {
                    continue
                }

                let displayLowerBound =
                    evidence[lowerIndex].displayCharacterRange.lowerBound
                let displayUpperBound =
                    evidence[upperIndex].displayCharacterRange.upperBound
                let displayRange = displayLowerBound..<displayUpperBound
                guard displayRange.lowerBound >= 0,
                    displayRange.lowerBound < displayRange.upperBound,
                    displayRange.upperBound <= chunk.displayText.count,
                    PronunciationAuditContext.normalizedWord(
                        substring(chunk.displayText, characterRange: displayRange))
                        == seed.normalizedWord,
                    let localWordSpan = PronunciationAuditContext.wordSpan(
                        overlappingDisplayCharacterRange: displayRange,
                        in: chunk.displayText),
                    (wordBase + localWordSpan.lowerBound) == seed.wordStart,
                    (wordBase + localWordSpan.upperBound) == seed.wordEnd,
                    let phonemeRange = validatedPhonemeRange(
                        for: evidence[lowerIndex...upperIndex],
                        in: chunk.phonemes),
                    phonemeRange.lowerBound < phonemeRange.upperBound,
                    phonemeRange.upperBound <= interiorIDs.count
                else {
                    continue
                }

                let selection = FinalPronunciationSelection(
                    selectedIPA: substring(chunk.phonemes, characterRange: phonemeRange),
                    kokoroTokenIDs: Array(interiorIDs[phonemeRange]),
                    chunkIndex: chunkIndex,
                    fallbackHits: chunk.pronunciationFallbackHits)
                if !selections.contains(selection) {
                    selections.append(selection)
                }
            }
        }

        guard selections.count == 1 else { return nil }
        return selections[0]
    }

    private static func owningMatchedChunk(
        for seed: PronunciationDecisionSeed,
        in synthesisChunks: [PlannedSynthesisChunk]
    ) -> (index: Int, chunk: PlannedSynthesisChunk)? {
        var wordBase = 0
        for (chunkIndex, chunk) in synthesisChunks.enumerated() {
            let upperWordBound = wordBase + chunk.wordCount
            if seed.wordStart >= wordBase, seed.wordEnd < upperWordBound,
                case .matched = chunk.pronunciationEvidenceValidation
            {
                return (chunkIndex, chunk)
            }
            wordBase = upperWordBound
        }
        return nil
    }

    private static func decisionEvidenceMismatchDiagnostic(
        for seed: PronunciationDecisionSeed,
        chunkIndex: Int,
        fallbackHits: [PronunciationFallbackHit],
        finalIPA: String?
    ) -> PronunciationAuditDiagnostic {
        PronunciationAuditDiagnostic(
            reason: .decisionEvidenceMismatch,
            blockID: seed.blockID,
            chunkIndex: chunkIndex,
            expectedDisplayText: seed.sourceWord,
            reconstructedSpokenSurface: "",
            fallbackHits: fallbackHits,
            finalPhonemes: finalIPA,
            reconstructedTokenPhonemes: dispatchNormalizedIPA(
                seed.selectedIPA,
                forWord: seed.normalizedWord))
    }

    private static func dispatchNormalizedIPA(_ ipa: String, forWord word: String) -> String {
        let vocabularyNormalized = String(
            ipa.compactMap { character -> Character? in
                switch character {
                case KokoroPhonemeVocab.oovMarker:
                    return nil
                case "ɾ":
                    return "T"
                case "ʔ":
                    return "t"
                default:
                    return character
                }
            })
        return KokoroAcousticPronunciationNormalizer.normalize(
            vocabularyNormalized,
            forWord: word)
    }

    private static func validatedPhonemeRange(
        for evidence: ArraySlice<PronunciationTokenEvidence>,
        in finalPhonemes: String
    ) -> Range<Int>? {
        var previousDisplayUpperBound = -1
        var previousPhonemeUpperBound = -1
        var firstPhonemeLowerBound: Int?
        var lastPhonemeUpperBound: Int?

        for token in evidence {
            guard token.displayCharacterRange.lowerBound >= previousDisplayUpperBound,
                let phonemeRange = token.phonemeCharacterRange,
                phonemeRange.lowerBound >= previousPhonemeUpperBound,
                phonemeRange.lowerBound >= 0,
                phonemeRange.upperBound <= finalPhonemes.count,
                substring(finalPhonemes, characterRange: phonemeRange)
                    == token.selectedPhonemes.filter({
                        $0 != KokoroPhonemeVocab.oovMarker
                    })
            else {
                return nil
            }

            firstPhonemeLowerBound = firstPhonemeLowerBound ?? phonemeRange.lowerBound
            lastPhonemeUpperBound = phonemeRange.upperBound
            previousDisplayUpperBound = token.displayCharacterRange.upperBound
            previousPhonemeUpperBound = phonemeRange.upperBound
        }

        guard let firstPhonemeLowerBound, let lastPhonemeUpperBound else { return nil }
        return firstPhonemeLowerBound..<lastPhonemeUpperBound
    }

    private static func substring(_ source: String, characterRange: Range<Int>) -> String {
        let lowerBound = source.index(
            source.startIndex,
            offsetBy: characterRange.lowerBound)
        let upperBound = source.index(
            source.startIndex,
            offsetBy: characterRange.upperBound)
        return String(source[lowerBound..<upperBound])
    }

    private static func attachTrailingSilences(
        to blocks: [NarrationPlannedBlock]
    ) -> [NarrationPlannedBlock] {
        guard !blocks.isEmpty else { return [] }
        let lastSpeakableIndex = blocks.lastIndex(where: \.isSpeakable)
        return blocks.enumerated().map { index, block in
            if block.trailingSilence == .sectionBreak { return block }
            guard block.isSpeakable, index != lastSpeakableIndex else { return block }
            let nextIsSectionBreak =
                index + 1 < blocks.count
                && blocks[index + 1].trailingSilence == .sectionBreak
            guard !nextIsSectionBreak else { return block }
            let silence: NarrationPlannedSilence =
                isHeading(block.originalBlock) ? .heading : .paragraph
            return NarrationPlannedBlock(
                blockID: block.blockID,
                originalBlock: block.originalBlock,
                synthesisChunks: block.synthesisChunks,
                pronunciationDecisions: block.pronunciationDecisions,
                pronunciationDecisionDiagnostics: block.pronunciationDecisionDiagnostics,
                trailingSilence: silence)
        }
    }

    /// Contextual evidence is keyed by whitespace word span, and a hyphenated
    /// compound such as "re-read" emits one G2P token seed per component at
    /// that same span. Only the contextual-family component's seed can pass
    /// phase-two identity validation for the span's evidence, so it must be
    /// the seed that survives `uniqueDecisionSeeds` first-wins dedup; any
    /// other component winning the span (for example "re" minted as an
    /// audit-pack comparison candidate) fails validation and aborts the
    /// render with `contextualEvidenceIdentityMismatch`. Promotion is limited
    /// to spans that actually hold pending evidence: discovery deliberately
    /// emits no occurrence for words like plain URLs, and promoting a family
    /// component there (for example "content" inside a `/wp-content/` URL)
    /// would demand evidence that legitimately does not exist.
    private static func prioritizingContextualFamilySeeds(
        _ seeds: [PronunciationDecisionSeed],
        contextualEvidence: [ContextualPronunciationKey: ContextualPronunciationEvidence]
    ) -> [PronunciationDecisionSeed] {
        guard !contextualEvidence.isEmpty else { return seeds }
        func isEvidencedFamilySeed(_ seed: PronunciationDecisionSeed) -> Bool {
            ContextualPronunciationFamilies.family(for: seed.normalizedWord) != nil
                && contextualEvidence[ContextualPronunciationKey(
                    blockID: seed.blockID,
                    wordStart: seed.wordStart,
                    wordEnd: seed.wordEnd)] != nil
        }
        let familySeeds = seeds.filter(isEvidencedFamilySeed)
        guard !familySeeds.isEmpty else { return seeds }
        return familySeeds + seeds.filter { !isEvidencedFamilySeed($0) }
    }

    private static func uniqueDecisionSeeds(
        _ seeds: [PronunciationDecisionSeed]
    ) -> [PronunciationDecisionSeed] {
        struct Span: Hashable {
            let blockID: String
            let wordStart: Int
            let wordEnd: Int
        }

        var seen: Set<Span> = []
        return seeds.filter { seed in
            seen.insert(
                Span(
                    blockID: seed.blockID,
                    wordStart: seed.wordStart,
                    wordEnd: seed.wordEnd)
            ).inserted
        }.sorted { lhs, rhs in
            if lhs.wordStart != rhs.wordStart { return lhs.wordStart < rhs.wordStart }
            return lhs.wordEnd < rhs.wordEnd
        }
    }

    private static func isHeading(_ block: EPubBlockRecord) -> Bool {
        block.blockKind.localizedCaseInsensitiveContains("heading")
            || block.blockKind.localizedCaseInsensitiveContains("title")
    }

    private static func isDecorativeSeparator(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if trimmed.contains(where: { $0.isLetter || $0.isNumber }) { return false }
        let allowed = CharacterSet(charactersIn: "*-~•·. _")
        return trimmed.unicodeScalars.allSatisfy { allowed.contains($0) }
    }
}
