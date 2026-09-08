// SPDX-License-Identifier: GPL-3.0-or-later
import CryptoKit
import Foundation

/// Immutable token-level evidence copied from Misaki's final mutable token list.
/// Character offsets are half-open and address the chunk's markup-free display text.
nonisolated struct PronunciationTokenEvidence: Codable, Equatable, Sendable {
    let text: String
    let selectedPhonemes: String
    let lexicalTag: String?
    let rating: Int?
    let displayCharacterRange: Range<Int>
    /// Half-open character range in the exact filtered phoneme string sent to
    /// Kokoro. Optional keeps captures written before frozen retry slicing
    /// decodable; a missing range means the evidence cannot be safely sliced.
    let phonemeCharacterRange: Range<Int>?
    let usedFallback: Bool
    /// `"left+right"` when an unlisted closed compound was voiced from two known
    /// lexical components, otherwise `nil`. A component-built pronunciation
    /// carries the same OOV rating as the whole-token guess, so this is the only
    /// thing that separates "reused two known words" from "guessed the spelling".
    /// Optional keeps captures written before compound provenance decodable.
    let compoundComponents: String?

    init(
        text: String,
        selectedPhonemes: String,
        lexicalTag: String?,
        rating: Int?,
        displayCharacterRange: Range<Int>,
        phonemeCharacterRange: Range<Int>? = nil,
        usedFallback: Bool,
        compoundComponents: String? = nil
    ) {
        self.text = text
        self.selectedPhonemes = selectedPhonemes
        self.lexicalTag = lexicalTag
        self.rating = rating
        self.displayCharacterRange = displayCharacterRange
        self.phonemeCharacterRange = phonemeCharacterRange
        self.usedFallback = usedFallback
        self.compoundComponents = compoundComponents
    }
}

/// Whether Misaki's final token surface safely addresses the chunk display text.
/// A mismatch preserves synthesis and aggregate fallback context, but invalidates
/// every token range because those ranges no longer address authored text.
nonisolated enum PronunciationEvidenceValidation: Codable, Equatable, Sendable {
    case matched
    case mismatch(
        expectedDisplayText: String,
        reconstructedSpokenSurface: String)
    case phonemeSequenceMismatch(
        finalPhonemes: String,
        reconstructedTokenPhonemes: String)
}

/// Range-free evidence that a planned chunk could not produce safe token ranges.
/// This is intentionally portable so a later manifest layer can report an
/// incomplete pronunciation audit without fabricating a source-word span.
nonisolated struct PronunciationAuditDiagnostic: Codable, Equatable, Sendable {
    enum Reason: String, Codable, Equatable, Sendable {
        case spokenSurfaceMismatch
        case phonemeSequenceMismatch
        case decisionEvidenceMismatch
        case incompleteRender
        case qualityRejected
        case missingContextualEvidence
        case currencyNormalizationRejected
    }

    let reason: Reason
    let blockID: String
    let chunkIndex: Int
    let chapterIndex: Int?
    let expectedDisplayText: String
    let reconstructedSpokenSurface: String
    let fallbackHits: [PronunciationFallbackHit]
    let finalPhonemes: String?
    let reconstructedTokenPhonemes: String?

    init(
        reason: Reason,
        blockID: String,
        chunkIndex: Int,
        chapterIndex: Int? = nil,
        expectedDisplayText: String,
        reconstructedSpokenSurface: String,
        fallbackHits: [PronunciationFallbackHit],
        finalPhonemes: String? = nil,
        reconstructedTokenPhonemes: String? = nil
    ) {
        self.reason = reason
        self.blockID = blockID
        self.chunkIndex = chunkIndex
        self.chapterIndex = chapterIndex
        self.expectedDisplayText = expectedDisplayText
        self.reconstructedSpokenSurface = reconstructedSpokenSurface
        self.fallbackHits = fallbackHits
        self.finalPhonemes = finalPhonemes
        self.reconstructedTokenPhonemes = reconstructedTokenPhonemes
    }

    func attachingChapter(_ chapterIndex: Int) -> PronunciationAuditDiagnostic {
        PronunciationAuditDiagnostic(
            reason: reason,
            blockID: blockID,
            chunkIndex: chunkIndex,
            chapterIndex: chapterIndex,
            expectedDisplayText: expectedDisplayText,
            reconstructedSpokenSurface: reconstructedSpokenSurface,
            fallbackHits: fallbackHits,
            finalPhonemes: finalPhonemes,
            reconstructedTokenPhonemes: reconstructedTokenPhonemes)
    }

    static func incompleteRender(
        blockID: String,
        chunkIndex: Int,
        chapterIndex: Int,
        expectedDisplayText: String,
        fallbackHits: [PronunciationFallbackHit]
    ) -> PronunciationAuditDiagnostic {
        PronunciationAuditDiagnostic(
            reason: .incompleteRender,
            blockID: blockID,
            chunkIndex: chunkIndex,
            chapterIndex: chapterIndex,
            expectedDisplayText: expectedDisplayText,
            reconstructedSpokenSurface: "",
            fallbackHits: fallbackHits)
    }

    static func qualityRejected(
        blockID: String,
        chunkIndex: Int,
        chapterIndex: Int,
        expectedDisplayText: String,
        fallbackHits: [PronunciationFallbackHit]
    ) -> PronunciationAuditDiagnostic {
        PronunciationAuditDiagnostic(
            reason: .qualityRejected,
            blockID: blockID,
            chunkIndex: chunkIndex,
            chapterIndex: chapterIndex,
            expectedDisplayText: expectedDisplayText,
            reconstructedSpokenSurface: "",
            fallbackHits: fallbackHits)
    }
}

/// Portable evidence for one pronunciation choice made before synthesis.
nonisolated struct PronunciationAuditDecision: Codable, Equatable, Sendable {
    enum Source: String, Codable, Equatable, Sendable {
        case occurrenceOverride
        case bookOverride
        case globalOverride
        case builtInOverride
        case epubInline
        case epubLexicon
        case contextualHomograph
        case supplementalLexicon
        case derivedMorphology
        case monitoredLexicon
        case fallback
    }

    enum TimingPrecision: String, Codable, Equatable, Sendable {
        case exactSynthesisWord
        case blockAnchorFallback
    }

    struct AudioRange: Codable, Equatable, Sendable {
        let start: TimeInterval
        let end: TimeInterval
    }

    let blockID: String
    let wordStart: Int
    let wordEnd: Int
    let normalizedWord: String
    let sourceWord: String
    let sourceContext: String
    let selectedIPA: String
    /// IDs for `selectedIPA` only. Kokoro's synthetic BOS/EOS tokens are excluded.
    let kokoroTokenIDs: [Int32]
    let source: Source
    let ruleID: String
    let rationale: String
    let candidateID: String?
    let candidatePackVersion: String?
    let derivationBase: String?
    let derivationRuleID: String?
    let contextualEvidence: ContextualPronunciationEvidence?
    let advisoryEvidence: PronunciationAdvisoryEvidence?
    let chapterIndex: Int?
    let chapterRelativeAudioRange: AudioRange?
    let bookRelativeAudioRange: AudioRange?
    let timingPrecision: TimingPrecision?

    init(
        blockID: String,
        wordStart: Int,
        wordEnd: Int,
        normalizedWord: String,
        sourceWord: String,
        sourceContext: String,
        selectedIPA: String,
        kokoroTokenIDs: [Int32],
        source: Source,
        ruleID: String,
        rationale: String,
        candidateID: String? = nil,
        candidatePackVersion: String? = nil,
        derivationBase: String? = nil,
        derivationRuleID: String? = nil,
        contextualEvidence: ContextualPronunciationEvidence? = nil,
        advisoryEvidence: PronunciationAdvisoryEvidence? = nil,
        chapterIndex: Int? = nil,
        chapterRelativeAudioRange: AudioRange? = nil,
        bookRelativeAudioRange: AudioRange? = nil,
        timingPrecision: TimingPrecision? = nil
    ) {
        self.blockID = blockID
        self.wordStart = wordStart
        self.wordEnd = wordEnd
        self.normalizedWord = normalizedWord
        self.sourceWord = sourceWord
        self.sourceContext = sourceContext
        self.selectedIPA = selectedIPA
        self.kokoroTokenIDs = kokoroTokenIDs
        self.source = source
        self.ruleID = ruleID
        self.rationale = rationale
        self.candidateID = candidateID
        self.candidatePackVersion = candidatePackVersion
        self.derivationBase = derivationBase
        self.derivationRuleID = derivationRuleID
        self.contextualEvidence = contextualEvidence
        self.advisoryEvidence = advisoryEvidence
        self.chapterIndex = chapterIndex
        self.chapterRelativeAudioRange = chapterRelativeAudioRange
        self.bookRelativeAudioRange = bookRelativeAudioRange
        self.timingPrecision = timingPrecision
    }

    func attachingRenderTiming(
        chapterIndex: Int,
        chapterRelativeAudioRange: AudioRange?,
        timingPrecision: TimingPrecision?
    ) -> PronunciationAuditDecision {
        PronunciationAuditDecision(
            blockID: blockID,
            wordStart: wordStart,
            wordEnd: wordEnd,
            normalizedWord: normalizedWord,
            sourceWord: sourceWord,
            sourceContext: sourceContext,
            selectedIPA: selectedIPA,
            kokoroTokenIDs: kokoroTokenIDs,
            source: source,
            ruleID: ruleID,
            rationale: rationale,
            candidateID: candidateID,
            candidatePackVersion: candidatePackVersion,
            derivationBase: derivationBase,
            derivationRuleID: derivationRuleID,
            contextualEvidence: contextualEvidence,
            advisoryEvidence: advisoryEvidence,
            chapterIndex: chapterIndex,
            chapterRelativeAudioRange: chapterRelativeAudioRange,
            bookRelativeAudioRange: bookRelativeAudioRange,
            timingPrecision: timingPrecision)
    }

    /// Preserves the chapter-relative receipt while projecting it into the
    /// completed audiobook's timebase. The capture filename's chapter index is
    /// canonical during resume assembly, so it replaces any stale embedded index.
    func attachingBookTiming(
        chapterIndex: Int,
        chapterOffset: TimeInterval
    ) -> PronunciationAuditDecision {
        let bookRelativeAudioRange = chapterRelativeAudioRange.map {
            AudioRange(
                start: chapterOffset + $0.start,
                end: chapterOffset + $0.end)
        }
        return PronunciationAuditDecision(
            blockID: blockID,
            wordStart: wordStart,
            wordEnd: wordEnd,
            normalizedWord: normalizedWord,
            sourceWord: sourceWord,
            sourceContext: sourceContext,
            selectedIPA: selectedIPA,
            kokoroTokenIDs: kokoroTokenIDs,
            source: source,
            ruleID: ruleID,
            rationale: rationale,
            candidateID: candidateID,
            candidatePackVersion: candidatePackVersion,
            derivationBase: derivationBase,
            derivationRuleID: derivationRuleID,
            contextualEvidence: contextualEvidence,
            advisoryEvidence: advisoryEvidence,
            chapterIndex: chapterIndex,
            chapterRelativeAudioRange: chapterRelativeAudioRange,
            bookRelativeAudioRange: bookRelativeAudioRange,
            timingPrecision: timingPrecision)
    }

    /// An advisory receipt for raw G2P output that could not be safely
    /// dispatched to Kokoro. It remains reviewable in the audit, but has no
    /// token IDs or audio timing and therefore cannot produce a listening-reel
    /// sample or bypass ordinary capture validation.
    var isEvidenceOnlyInvalidOutputAdvisory: Bool {
        guard let advisoryEvidence,
            advisoryEvidence.isValid(),
            kokoroTokenIDs.isEmpty,
            chapterRelativeAudioRange == nil,
            bookRelativeAudioRange == nil,
            timingPrecision == nil
        else {
            return false
        }
        return InvalidG2PAuditReceipt.hasVerifiedProvenance(
            normalizedWord: normalizedWord,
            sourceWord: sourceWord,
            selectedIPA: selectedIPA,
            source: source,
            ruleID: ruleID,
            candidateID: candidateID,
            candidatePackVersion: candidatePackVersion,
            derivationBase: derivationBase,
            derivationRuleID: derivationRuleID,
            contextualEvidence: contextualEvidence,
            advisoryEvidence: advisoryEvidence)
    }
}

/// Shared integrity boundary for a no-synthesis receipt of raw G2P output.
/// The permitted shapes are exactly the ones `decisionSeed(for:)` can create
/// directly from Misaki token evidence; rewrite and override provenance cannot
/// enter this audit-only path.
nonisolated enum InvalidG2PAuditReceipt {
    enum Classification: Equatable {
        case verified(expectedSelectionReason: PronunciationAdvisoryEvidence.SelectionReason)
        case invalid
    }

    static func hasVerifiedProvenance(
        normalizedWord: String,
        sourceWord: String,
        selectedIPA: String,
        source: PronunciationAuditDecision.Source,
        ruleID: String,
        candidateID: String?,
        candidatePackVersion: String?,
        derivationBase: String?,
        derivationRuleID: String?,
        contextualEvidence: ContextualPronunciationEvidence?,
        advisoryEvidence: PronunciationAdvisoryEvidence
    ) -> Bool {
        guard
            case .verified(let expectedSelectionReason) = classification(
                normalizedWord: normalizedWord,
                sourceWord: sourceWord,
                selectedIPA: selectedIPA,
                source: source,
                ruleID: ruleID,
                candidateID: candidateID,
                candidatePackVersion: candidatePackVersion,
                derivationBase: derivationBase,
                derivationRuleID: derivationRuleID,
                contextualEvidence: contextualEvidence,
                advisoryEvidence: advisoryEvidence)
        else {
            return false
        }
        return advisoryEvidence.selectionReason == expectedSelectionReason
    }

    static func classification(
        normalizedWord: String,
        sourceWord: String,
        selectedIPA: String,
        source: PronunciationAuditDecision.Source,
        ruleID: String,
        candidateID: String?,
        candidatePackVersion: String?,
        derivationBase: String?,
        derivationRuleID: String?,
        contextualEvidence: ContextualPronunciationEvidence?,
        advisoryEvidence: PronunciationAdvisoryEvidence,
        advisoryEvidenceIsValid: Bool? = nil
    ) -> Classification? {
        guard PronunciationAuditContext.isRejectedRawG2POutput(selectedIPA) else {
            return nil
        }
        guard
            PronunciationAuditContext.normalizedWord(sourceWord) == normalizedWord,
            advisoryEvidenceIsValid ?? advisoryEvidence.isValid(),
            advisoryEvidence.category == .lexical,
            advisoryEvidence.selectedCandidateID == nil,
            !advisoryEvidence.overrideSuppressedAutomation,
            candidateID == nil,
            candidatePackVersion == nil,
            derivationBase == nil,
            derivationRuleID == nil,
            contextualEvidence == nil
        else {
            return .invalid
        }

        switch source {
        case .fallback:
            guard
                ruleID == "g2p.fallback.\(PronunciationAuditContext.ruleComponent(sourceWord))",
                advisoryEvidence.selectedAuthority == .uncertain
            else {
                return .invalid
            }
            return .verified(expectedSelectionReason: .deterministicFallback)
        case .monitoredLexicon:
            guard
                ruleID == "g2p.lexicon.\(PronunciationAuditContext.ruleComponent(sourceWord))",
                advisoryEvidence.selectedAuthority == .trusted
            else {
                return .invalid
            }
            return .verified(
                expectedSelectionReason: advisoryEvidence.alternatives.isEmpty
                    ? .trustedLexicon : .sourceDisagreement)
        case .occurrenceOverride, .bookOverride, .globalOverride, .epubInline, .epubLexicon,
            .builtInOverride,
            .contextualHomograph, .supplementalLexicon, .derivedMorphology:
            return .invalid
        }
    }
}

/// Whether every completed chapter capture contains the exact render receipt.
/// Legacy captures remain usable for audio/sidecar resume, but cannot prove
/// pronunciation coverage retroactively.
nonisolated enum PronunciationAuditCoverage: String, Codable, Equatable, Sendable {
    case complete
    case incompleteLegacyCapture
    case incompleteEvidence
}

nonisolated struct PronunciationBlockVoiceProvenance: Equatable, Sendable {
    let voicePlanSHA256: String
    let blockVoices: [String: VoiceID]
}

/// Schema-versioned local receipt for every pronunciation choice used by one
/// completed narration render. File references deliberately contain names only:
/// the manifest can move with its sibling audiobook without leaking a local path.
nonisolated struct PronunciationAuditManifest: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 6
    static let planSchemaVersion = 7

    let schemaVersion: Int
    let renderVersion: Int
    let voice: String
    /// Complete raw EPUB chapter-index to voice mapping for mixed-voice runs.
    /// Empty only for legacy/internal callers that do not supply chapter provenance.
    let chapterVoices: [String: String]
    let voicePlanSHA256: String?
    let blockVoices: [String: String]?
    let coverage: PronunciationAuditCoverage
    let legacyChapterIndexes: [Int]
    let audiobookFileName: String
    /// Lowercase SHA-256 of the exact raw final-audiobook bytes.
    let audiobookSHA256: String
    let listeningReelFileName: String?
    /// Present exactly when `listeningReelFileName` is present.
    let listeningReelSHA256: String?
    let watchCounts: [String: Int]
    let decisions: [PronunciationAuditDecision]
    let diagnostics: [PronunciationAuditDiagnostic]

    static func make(
        renderVersion: Int,
        voice: VoiceID,
        chapterVoices: [Int: VoiceID] = [:],
        captureCoverage: PronunciationAuditCoverage,
        legacyChapterIndexes: [Int],
        audiobookURL: URL,
        reelURL: URL?,
        audiobookSHA256: String,
        listeningReelSHA256: String?,
        watchWords: [String],
        decisions: [PronunciationAuditDecision],
        diagnostics: [PronunciationAuditDiagnostic]
    ) -> PronunciationAuditManifest {
        make(
            renderVersion: renderVersion, voice: voice, chapterVoices: chapterVoices,
            blockVoiceProvenance: nil, captureCoverage: captureCoverage,
            legacyChapterIndexes: legacyChapterIndexes, audiobookURL: audiobookURL,
            reelURL: reelURL,
            audiobookSHA256: audiobookSHA256, listeningReelSHA256: listeningReelSHA256,
            watchWords: watchWords, decisions: decisions, diagnostics: diagnostics)
    }

    static func make(
        renderVersion: Int,
        voice: VoiceID,
        chapterVoices: [Int: VoiceID] = [:],
        blockVoiceProvenance: PronunciationBlockVoiceProvenance?,
        captureCoverage: PronunciationAuditCoverage,
        legacyChapterIndexes: [Int],
        audiobookURL: URL,
        reelURL: URL?,
        audiobookSHA256: String,
        listeningReelSHA256: String?,
        watchWords: [String],
        decisions: [PronunciationAuditDecision],
        diagnostics: [PronunciationAuditDiagnostic]
    ) -> PronunciationAuditManifest {
        let normalizedWatchWords = Set(
            watchWords.map(PronunciationAuditContext.normalizedWord).filter { !$0.isEmpty })
        let countedWords = normalizedWatchWords.union(decisions.map(\.normalizedWord))
        var watchCounts = Dictionary(
            uniqueKeysWithValues: countedWords.map { ($0, 0) })
        for decision in decisions {
            watchCounts[decision.normalizedWord, default: 0] += 1
        }

        let normalizedLegacyChapterIndexes = Array(Set(legacyChapterIndexes)).sorted()
        let effectiveCoverage: PronunciationAuditCoverage
        if !normalizedLegacyChapterIndexes.isEmpty
            || captureCoverage == .incompleteLegacyCapture
        {
            effectiveCoverage = .incompleteLegacyCapture
        } else if !diagnostics.isEmpty
            || Self.hasMissingOrInvalidCurrentContextualEvidence(decisions)
            || captureCoverage == .incompleteEvidence
        {
            effectiveCoverage = .incompleteEvidence
        } else {
            effectiveCoverage = .complete
        }

        let resolvedBlockVoices = blockVoiceProvenance.map { provenance in
            Dictionary(
                uniqueKeysWithValues: provenance.blockVoices.map { ($0.key, $0.value.rawValue) })
        }
        let resolvedVoice: String
        if let resolvedBlockVoices {
            let distinctVoices = Set(resolvedBlockVoices.values)
            resolvedVoice =
                distinctVoices.count == 1 ? distinctVoices.first ?? voice.rawValue : "mixed"
        } else {
            resolvedVoice = voice.rawValue
        }

        return PronunciationAuditManifest(
            schemaVersion: blockVoiceProvenance == nil ? currentSchemaVersion : planSchemaVersion,
            renderVersion: renderVersion,
            voice: resolvedVoice,
            chapterVoices: blockVoiceProvenance == nil
                ? Dictionary(
                    uniqueKeysWithValues: chapterVoices.map { (String($0.key), $0.value.rawValue) })
                : [:],
            voicePlanSHA256: blockVoiceProvenance?.voicePlanSHA256,
            blockVoices: resolvedBlockVoices,
            coverage: effectiveCoverage,
            legacyChapterIndexes: normalizedLegacyChapterIndexes,
            audiobookFileName: audiobookURL.lastPathComponent,
            audiobookSHA256: audiobookSHA256,
            listeningReelFileName: reelURL?.lastPathComponent,
            listeningReelSHA256: listeningReelSHA256,
            watchCounts: watchCounts,
            decisions: decisions,
            diagnostics: diagnostics)
    }

    func encoded() throws -> Data {
        try validateFields()
        try currentSchemaEncodingProjection().validateFields()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    /// Verifies both manifest schema and the exact raw sibling bytes. Callers
    /// pass explicit URLs so the portable manifest never persists local paths.
    func validateArtifacts(audiobookURL: URL, reelURL: URL?) throws {
        try validateArtifacts(
            audiobookURL: audiobookURL,
            reelURL: reelURL,
            expectedBlockVoiceProvenance: nil)
    }

    /// Verifies the final sibling bytes and, for schema-7 receipts, the exact
    /// resolved voice-plan provenance that authorized the render.
    func validateArtifacts(
        audiobookURL: URL,
        reelURL: URL?,
        expectedBlockVoiceProvenance: PronunciationBlockVoiceProvenance?
    ) throws {
        try validateFields()
        switch schemaVersion {
        case Self.planSchemaVersion:
            guard let expectedBlockVoiceProvenance else {
                throw PronunciationArtifactIntegrity.IntegrityError.mismatch(
                    "plan pronunciation audit requires resolved voice-plan provenance")
            }
            let expectedBlockVoices = Dictionary(
                uniqueKeysWithValues: expectedBlockVoiceProvenance.blockVoices.map {
                    ($0.key, $0.value.rawValue)
                })
            guard voicePlanSHA256 == expectedBlockVoiceProvenance.voicePlanSHA256,
                blockVoices == expectedBlockVoices
            else {
                throw PronunciationArtifactIntegrity.IntegrityError.mismatch(
                    "plan pronunciation audit does not match the resolved voice plan")
            }
        default:
            guard expectedBlockVoiceProvenance == nil else {
                throw PronunciationArtifactIntegrity.IntegrityError.mismatch(
                    "legacy pronunciation audit cannot validate resolved voice-plan provenance")
            }
        }
        guard audiobookFileName == audiobookURL.lastPathComponent else {
            throw PronunciationArtifactIntegrity.IntegrityError.mismatch(
                "audiobook filename does not match the manifest")
        }
        guard
            try PronunciationArtifactIntegrity.sha256Hex(of: audiobookURL)
                == audiobookSHA256
        else {
            throw PronunciationArtifactIntegrity.IntegrityError.mismatch(
                "audiobook SHA-256 does not match the manifest")
        }

        switch (listeningReelFileName, listeningReelSHA256, reelURL) {
        case (nil, nil, nil):
            break
        case (.some(let fileName), .some(let expectedSHA256), .some(let reelURL)):
            guard fileName == reelURL.lastPathComponent else {
                throw PronunciationArtifactIntegrity.IntegrityError.mismatch(
                    "listening-reel filename does not match the manifest")
            }
            guard try PronunciationArtifactIntegrity.sha256Hex(of: reelURL) == expectedSHA256 else {
                throw PronunciationArtifactIntegrity.IntegrityError.mismatch(
                    "listening-reel SHA-256 does not match the manifest")
            }
        default:
            throw PronunciationArtifactIntegrity.IntegrityError.mismatch(
                "listening-reel filename, SHA-256, and file must be paired")
        }
    }

    private func validateFields() throws {
        guard (3...Self.planSchemaVersion).contains(schemaVersion) else {
            throw PronunciationArtifactIntegrity.IntegrityError.mismatch(
                "unsupported pronunciation-audit schema \(schemaVersion)")
        }
        if schemaVersion == Self.planSchemaVersion {
            guard let voicePlanSHA256, let blockVoices, !blockVoices.isEmpty else {
                throw PronunciationArtifactIntegrity.IntegrityError.mismatch(
                    "plan pronunciation audit requires complete block voice provenance")
            }
            guard chapterVoices.isEmpty else {
                throw PronunciationArtifactIntegrity.IntegrityError.mismatch(
                    "plan pronunciation audit cannot contain chapter voices")
            }
            guard PronunciationArtifactIntegrity.isLowercaseSHA256(voicePlanSHA256) else {
                throw PronunciationArtifactIntegrity.IntegrityError.mismatch(
                    "voice-plan SHA-256 is not 64 lowercase hexadecimal characters")
            }
            for (blockID, blockVoice) in blockVoices {
                guard Self.isPortableBlockID(blockID),
                    VoiceCatalog.voice(for: VoiceID(blockVoice)) != nil
                else {
                    throw PronunciationArtifactIntegrity.IntegrityError.mismatch(
                        "plan pronunciation audit contains an invalid block voice")
                }
            }
            let voices = Set(blockVoices.values)
            let expectedVoice = voices.count == 1 ? voices.first! : "mixed"
            guard voice == expectedVoice else {
                throw PronunciationArtifactIntegrity.IntegrityError.mismatch(
                    "plan pronunciation audit disagrees with block voices")
            }
            for decision in decisions
            where blockVoices[AlignmentSidecar.portableSuffix(of: decision.blockID)] == nil {
                throw PronunciationArtifactIntegrity.IntegrityError.mismatch(
                    "pronunciation decision references a block absent from the voice plan")
            }
        } else {
            guard voicePlanSHA256 == nil, blockVoices == nil else {
                throw PronunciationArtifactIntegrity.IntegrityError.mismatch(
                    "legacy pronunciation audit cannot contain block voice provenance")
            }
            for (chapterIndex, chapterVoice) in chapterVoices {
                guard let parsedIndex = Int(chapterIndex),
                    parsedIndex >= 0,
                    String(parsedIndex) == chapterIndex
                else {
                    throw PronunciationArtifactIntegrity.IntegrityError.mismatch(
                        "pronunciation audit contains an invalid chapter voice key")
                }
                guard VoiceCatalog.voice(for: VoiceID(chapterVoice)) != nil else {
                    throw PronunciationArtifactIntegrity.IntegrityError.mismatch(
                        "pronunciation audit contains an unknown chapter voice")
                }
            }
            let distinctChapterVoices = Set(chapterVoices.values)
            guard voice != "mixed" || distinctChapterVoices.count > 1 else {
                throw PronunciationArtifactIntegrity.IntegrityError.mismatch(
                    "mixed pronunciation audit requires more than one chapter voice")
            }
            guard
                voice == "mixed" || distinctChapterVoices.isEmpty
                    || distinctChapterVoices == Set([voice])
            else {
                throw PronunciationArtifactIntegrity.IntegrityError.mismatch(
                    "uniform pronunciation audit disagrees with chapter voices")
            }
        }
        guard PronunciationArtifactIntegrity.isLowercaseSHA256(audiobookSHA256) else {
            throw PronunciationArtifactIntegrity.IntegrityError.mismatch(
                "audiobook SHA-256 is not 64 lowercase hexadecimal characters")
        }
        guard (listeningReelFileName == nil) == (listeningReelSHA256 == nil) else {
            throw PronunciationArtifactIntegrity.IntegrityError.mismatch(
                "listening-reel filename and SHA-256 must be paired")
        }
        if let listeningReelSHA256,
            !PronunciationArtifactIntegrity.isLowercaseSHA256(listeningReelSHA256)
        {
            throw PronunciationArtifactIntegrity.IntegrityError.mismatch(
                "listening-reel SHA-256 is not 64 lowercase hexadecimal characters")
        }
        for decision in decisions {
            switch decision.source {
            case .supplementalLexicon:
                guard Self.isPresent(decision.candidateID),
                    Self.isPresent(decision.candidatePackVersion),
                    decision.derivationBase == nil,
                    decision.derivationRuleID == nil
                else {
                    throw PronunciationArtifactIntegrity.IntegrityError.mismatch(
                        "supplemental pronunciation evidence is incomplete")
                }
            case .derivedMorphology:
                guard Self.isPresent(decision.candidateID),
                    Self.isPresent(decision.candidatePackVersion),
                    Self.isPresent(decision.derivationBase),
                    Self.isPresent(decision.derivationRuleID)
                else {
                    throw PronunciationArtifactIntegrity.IntegrityError.mismatch(
                        "derived pronunciation evidence is incomplete")
                }
            default:
                break
            }
            if let evidence = decision.contextualEvidence {
                guard
                    ContextualPronunciationEvidenceValidator.isValidPhaseTwo(
                        evidence,
                        blockID: decision.blockID,
                        wordStart: decision.wordStart,
                        wordEnd: decision.wordEnd,
                        normalizedWord: decision.normalizedWord,
                        source: decision.source)
                else {
                    throw PronunciationArtifactIntegrity.IntegrityError.mismatch(
                        "contextual pronunciation evidence is incomplete")
                }
            }
            if let evidence = decision.advisoryEvidence {
                let isValidEvidence: Bool
                switch schemaVersion {
                case 5:
                    isValidEvidence = evidence.isValidLegacySchemaFive(for: decision)
                case Self.currentSchemaVersion, Self.planSchemaVersion:
                    isValidEvidence = evidence.isValid(for: decision)
                default:
                    isValidEvidence = true
                }
                if !isValidEvidence {
                    throw PronunciationArtifactIntegrity.IntegrityError.mismatch(
                        "advisory pronunciation evidence is invalid")
                }
            }
            if PronunciationAuditContext.isRejectedRawG2POutput(decision.selectedIPA) {
                let hasValidReceipt: Bool
                switch schemaVersion {
                case 5:
                    hasValidReceipt =
                        decision.advisoryEvidence?
                        .isValidLegacySchemaFive(for: decision) == true
                case Self.currentSchemaVersion, Self.planSchemaVersion:
                    hasValidReceipt = decision.isEvidenceOnlyInvalidOutputAdvisory
                default:
                    hasValidReceipt = true
                }
                if !hasValidReceipt {
                    throw PronunciationArtifactIntegrity.IntegrityError.mismatch(
                        "rejected raw G2P output has invalid audit provenance")
                }
            }
        }
    }

    private static func hasMissingOrInvalidCurrentContextualEvidence(
        _ decisions: [PronunciationAuditDecision]
    ) -> Bool {
        decisions.contains { decision in
            if let evidence = decision.contextualEvidence {
                return !ContextualPronunciationEvidenceValidator.isValidPhaseTwo(
                    evidence,
                    blockID: decision.blockID,
                    wordStart: decision.wordStart,
                    wordEnd: decision.wordEnd,
                    normalizedWord: decision.normalizedWord,
                    source: decision.source)
            }
            return PronunciationAuditContext.requiresContextualEvidence(
                normalizedWord: decision.normalizedWord,
                source: decision.source)
        }
    }

    private static func isPresent(_ value: String?) -> Bool {
        guard let value else { return false }
        return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func isPortableBlockID(_ value: String) -> Bool {
        let components = value.split(separator: "-", omittingEmptySubsequences: false)
        guard components.count == 2,
            components[0].first == "s", components[1].first == "b"
        else { return false }
        return components[0].dropFirst().unicodeScalars.allSatisfy(Self.isASCIIDigit)
            && components[1].dropFirst().unicodeScalars.allSatisfy(Self.isASCIIDigit)
            && components[0].count > 1 && components[1].count > 1
    }

    private static func isASCIIDigit(_ scalar: Unicode.Scalar) -> Bool {
        (48...57).contains(scalar.value)
    }

    /// Writes through a unique sibling, then atomically promotes it over the
    /// prior receipt so readers never observe a partially encoded manifest.
    func write(to destinationURL: URL, fileManager: FileManager = .default) throws {
        let parent = destinationURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        let temporaryURL = parent.appendingPathComponent(
            ".\(destinationURL.lastPathComponent).\(UUID().uuidString).tmp")
        defer { try? fileManager.removeItem(at: temporaryURL) }

        try encoded().write(to: temporaryURL)
        if fileManager.fileExists(atPath: destinationURL.path) {
            _ = try fileManager.replaceItemAt(destinationURL, withItemAt: temporaryURL)
        } else {
            try fileManager.moveItem(at: temporaryURL, to: destinationURL)
        }
    }
}

extension PronunciationAuditManifest {
    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case renderVersion
        case voice
        case chapterVoices
        case voicePlanSHA256
        case blockVoices
        case coverage
        case legacyChapterIndexes
        case audiobookFileName
        case audiobookSHA256
        case listeningReelFileName
        case listeningReelSHA256
        case watchCounts
        case decisions
        case diagnostics
    }

    /// Schemas 3 and 4 predate advisory evidence. Decode their decision shape
    /// explicitly so an injected future field is ignored rather than preserved
    /// or allowed to make an otherwise-valid legacy receipt undecodable.
    private struct LegacyDecision: Decodable {
        private enum CodingKeys: String, CodingKey {
            case blockID
            case wordStart
            case wordEnd
            case normalizedWord
            case sourceWord
            case sourceContext
            case selectedIPA
            case kokoroTokenIDs
            case source
            case ruleID
            case rationale
            case candidateID
            case candidatePackVersion
            case derivationBase
            case derivationRuleID
            case contextualEvidence
            case chapterIndex
            case chapterRelativeAudioRange
            case bookRelativeAudioRange
            case timingPrecision
        }

        let decision: PronunciationAuditDecision

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            decision = PronunciationAuditDecision(
                blockID: try container.decode(String.self, forKey: .blockID),
                wordStart: try container.decode(Int.self, forKey: .wordStart),
                wordEnd: try container.decode(Int.self, forKey: .wordEnd),
                normalizedWord: try container.decode(String.self, forKey: .normalizedWord),
                sourceWord: try container.decode(String.self, forKey: .sourceWord),
                sourceContext: try container.decode(String.self, forKey: .sourceContext),
                selectedIPA: try container.decode(String.self, forKey: .selectedIPA),
                kokoroTokenIDs: try container.decode([Int32].self, forKey: .kokoroTokenIDs),
                source: try container.decode(
                    PronunciationAuditDecision.Source.self,
                    forKey: .source),
                ruleID: try container.decode(String.self, forKey: .ruleID),
                rationale: try container.decode(String.self, forKey: .rationale),
                candidateID: try container.decodeIfPresent(String.self, forKey: .candidateID),
                candidatePackVersion: try container.decodeIfPresent(
                    String.self,
                    forKey: .candidatePackVersion),
                derivationBase: try container.decodeIfPresent(
                    String.self,
                    forKey: .derivationBase),
                derivationRuleID: try container.decodeIfPresent(
                    String.self,
                    forKey: .derivationRuleID),
                contextualEvidence: try container.decodeIfPresent(
                    ContextualPronunciationEvidence.self,
                    forKey: .contextualEvidence),
                chapterIndex: try container.decodeIfPresent(Int.self, forKey: .chapterIndex),
                chapterRelativeAudioRange: try container.decodeIfPresent(
                    PronunciationAuditDecision.AudioRange.self,
                    forKey: .chapterRelativeAudioRange),
                bookRelativeAudioRange: try container.decodeIfPresent(
                    PronunciationAuditDecision.AudioRange.self,
                    forKey: .bookRelativeAudioRange),
                timingPrecision: try container.decodeIfPresent(
                    PronunciationAuditDecision.TimingPrecision.self,
                    forKey: .timingPrecision))
        }
    }

    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        guard (3...Self.planSchemaVersion).contains(schemaVersion) else {
            throw DecodingError.dataCorruptedError(
                forKey: .schemaVersion,
                in: container,
                debugDescription:
                    "Unsupported pronunciation-audit schema \(schemaVersion).")
        }

        let storedCoverage = try container.decode(
            PronunciationAuditCoverage.self,
            forKey: .coverage)
        self.schemaVersion = schemaVersion
        renderVersion = try container.decode(Int.self, forKey: .renderVersion)
        voice = try container.decode(String.self, forKey: .voice)
        chapterVoices = try container.decode(
            [String: String].self,
            forKey: .chapterVoices)
        voicePlanSHA256 = try container.decodeIfPresent(String.self, forKey: .voicePlanSHA256)
        blockVoices = try container.decodeIfPresent([String: String].self, forKey: .blockVoices)
        legacyChapterIndexes = try container.decode(
            [Int].self,
            forKey: .legacyChapterIndexes)
        audiobookFileName = try container.decode(
            String.self,
            forKey: .audiobookFileName)
        audiobookSHA256 = try container.decode(
            String.self,
            forKey: .audiobookSHA256)
        listeningReelFileName = try container.decodeIfPresent(
            String.self,
            forKey: .listeningReelFileName)
        listeningReelSHA256 = try container.decodeIfPresent(
            String.self,
            forKey: .listeningReelSHA256)
        watchCounts = try container.decode(
            [String: Int].self,
            forKey: .watchCounts)
        if schemaVersion >= 5 {
            decisions = try container.decode(
                [PronunciationAuditDecision].self,
                forKey: .decisions)
        } else {
            decisions = try container.decode(
                [LegacyDecision].self,
                forKey: .decisions
            )
            .map(\.decision)
        }
        diagnostics = try container.decode(
            [PronunciationAuditDiagnostic].self,
            forKey: .diagnostics)
        if storedCoverage == .incompleteLegacyCapture {
            coverage = .incompleteLegacyCapture
        } else if schemaVersion == 3
            || !diagnostics.isEmpty
            || Self.hasMissingOrInvalidCurrentContextualEvidence(decisions)
        {
            coverage = .incompleteEvidence
        } else {
            coverage = storedCoverage
        }
        try validateFields()
    }

    nonisolated func encode(to encoder: Encoder) throws {
        try currentSchemaEncodingProjection().validateFields()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(
            voicePlanSHA256 == nil ? Self.currentSchemaVersion : Self.planSchemaVersion,
            forKey: .schemaVersion)
        try container.encode(renderVersion, forKey: .renderVersion)
        try container.encode(voice, forKey: .voice)
        try container.encode(chapterVoices, forKey: .chapterVoices)
        try container.encodeIfPresent(voicePlanSHA256, forKey: .voicePlanSHA256)
        try container.encodeIfPresent(blockVoices, forKey: .blockVoices)
        try container.encode(coverage, forKey: .coverage)
        try container.encode(legacyChapterIndexes, forKey: .legacyChapterIndexes)
        try container.encode(audiobookFileName, forKey: .audiobookFileName)
        try container.encode(audiobookSHA256, forKey: .audiobookSHA256)
        try container.encodeIfPresent(
            listeningReelFileName,
            forKey: .listeningReelFileName)
        try container.encodeIfPresent(
            listeningReelSHA256,
            forKey: .listeningReelSHA256)
        try container.encode(watchCounts, forKey: .watchCounts)
        try container.encode(decisions, forKey: .decisions)
        try container.encode(diagnostics, forKey: .diagnostics)
    }

    /// Encoding always writes the current schema number, so validate the exact
    /// current-schema projection before making that claim for a legacy receipt.
    nonisolated private func currentSchemaEncodingProjection() -> PronunciationAuditManifest {
        PronunciationAuditManifest(
            schemaVersion: voicePlanSHA256 == nil
                ? Self.currentSchemaVersion : Self.planSchemaVersion,
            renderVersion: renderVersion,
            voice: voice,
            chapterVoices: chapterVoices,
            voicePlanSHA256: voicePlanSHA256,
            blockVoices: blockVoices,
            coverage: coverage,
            legacyChapterIndexes: legacyChapterIndexes,
            audiobookFileName: audiobookFileName,
            audiobookSHA256: audiobookSHA256,
            listeningReelFileName: listeningReelFileName,
            listeningReelSHA256: listeningReelSHA256,
            watchCounts: watchCounts,
            decisions: decisions,
            diagnostics: diagnostics)
    }
}

/// Rewrite-stage provenance. The render planner binds this metadata to an exact
/// final chunk phoneme and Kokoro-ID slice before exposing a portable decision.
nonisolated struct PronunciationDecisionSeed: Equatable, Sendable {
    let blockID: String
    let wordStart: Int
    let wordEnd: Int
    let normalizedWord: String
    let sourceWord: String
    let sourceContext: String
    let selectedIPA: String
    let source: PronunciationAuditDecision.Source
    let ruleID: String
    let rationale: String
    let candidateID: String?
    let candidatePackVersion: String?
    let derivationBase: String?
    let derivationRuleID: String?
    let contextualEvidence: ContextualPronunciationEvidence?
    let advisoryEvidence: PronunciationAdvisoryEvidence?

    init(
        blockID: String,
        wordStart: Int,
        wordEnd: Int,
        normalizedWord: String,
        sourceWord: String,
        sourceContext: String,
        selectedIPA: String,
        source: PronunciationAuditDecision.Source,
        ruleID: String,
        rationale: String,
        candidateID: String? = nil,
        candidatePackVersion: String? = nil,
        derivationBase: String? = nil,
        derivationRuleID: String? = nil,
        contextualEvidence: ContextualPronunciationEvidence? = nil,
        advisoryEvidence: PronunciationAdvisoryEvidence? = nil
    ) {
        self.blockID = blockID
        self.wordStart = wordStart
        self.wordEnd = wordEnd
        self.normalizedWord = normalizedWord
        self.sourceWord = sourceWord
        self.sourceContext = sourceContext
        self.selectedIPA = selectedIPA
        self.source = source
        self.ruleID = ruleID
        self.rationale = rationale
        self.candidateID = candidateID
        self.candidatePackVersion = candidatePackVersion
        self.derivationBase = derivationBase
        self.derivationRuleID = derivationRuleID
        self.contextualEvidence = contextualEvidence
        self.advisoryEvidence = advisoryEvidence
    }

    func materialized(
        selectedIPA: String,
        kokoroTokenIDs: [Int32]
    ) -> PronunciationAuditDecision {
        PronunciationAuditDecision(
            blockID: blockID,
            wordStart: wordStart,
            wordEnd: wordEnd,
            normalizedWord: normalizedWord,
            sourceWord: sourceWord,
            sourceContext: sourceContext,
            selectedIPA: selectedIPA,
            kokoroTokenIDs: kokoroTokenIDs,
            source: source,
            ruleID: ruleID,
            rationale: rationale,
            candidateID: candidateID,
            candidatePackVersion: candidatePackVersion,
            derivationBase: derivationBase,
            derivationRuleID: derivationRuleID,
            contextualEvidence: contextualEvidence,
            advisoryEvidence: advisoryEvidence)
    }

    /// Produces an audit-only receipt for empty or unencodable G2P output.
    /// Unlike `materialized(selectedIPA:kokoroTokenIDs:)`, this does not claim
    /// a final synthesis-token slice.
    func evidenceOnlyMaterialized() -> PronunciationAuditDecision {
        materialized(selectedIPA: selectedIPA, kokoroTokenIDs: [])
    }

    func attachingContextualEvidence(
        _ contextualEvidence: ContextualPronunciationEvidence
    ) -> PronunciationDecisionSeed {
        PronunciationDecisionSeed(
            blockID: blockID,
            wordStart: wordStart,
            wordEnd: wordEnd,
            normalizedWord: normalizedWord,
            sourceWord: sourceWord,
            sourceContext: sourceContext,
            selectedIPA: selectedIPA,
            source: source,
            ruleID: ruleID,
            rationale: rationale,
            candidateID: candidateID,
            candidatePackVersion: candidatePackVersion,
            derivationBase: derivationBase,
            derivationRuleID: derivationRuleID,
            contextualEvidence: contextualEvidence,
            advisoryEvidence: advisoryEvidence)
    }

    func attachingAdvisoryEvidence(
        _ advisoryEvidence: PronunciationAdvisoryEvidence
    ) -> PronunciationDecisionSeed {
        PronunciationDecisionSeed(
            blockID: blockID,
            wordStart: wordStart,
            wordEnd: wordEnd,
            normalizedWord: normalizedWord,
            sourceWord: sourceWord,
            sourceContext: sourceContext,
            selectedIPA: selectedIPA,
            source: source,
            ruleID: ruleID,
            rationale: rationale,
            candidateID: candidateID,
            candidatePackVersion: candidatePackVersion,
            derivationBase: derivationBase,
            derivationRuleID: derivationRuleID,
            contextualEvidence: contextualEvidence,
            advisoryEvidence: advisoryEvidence)
    }
}

nonisolated struct PronunciationRewriteResult: Equatable, Sendable {
    let text: String
    let decisionSeeds: [PronunciationDecisionSeed]
}

/// One deterministic declaration for every pronunciation Echo actively watches.
/// Built-in keys remain owned by `PronunciationOverrides`; the contextual list
/// mirrors every target handled by `HomographPronunciationResolver`; ordinary
/// lexicon regressions are added explicitly here.
nonisolated enum PronunciationWatchVocabulary {
    private static let contextualHomographWords: Set<String> = [
        "arithmetic",
        "content",
        "live",
        "lives",
        "read",
        "record",
        "resume",
        "resumes",
        "résumé",
        "résumés",
    ]
    private static let monitoredOrdinaryLexiconWords: Set<String> = [
        "able",
        "available",
        "comfortable",
        "possible",
        "reliable",
        "stable",
        "table",
        "verified",
    ]

    static let words: Set<String> = {
        let builtIns = PronunciationOverrides.builtInDefaults.keys.map {
            PronunciationAuditContext.normalizedWord($0)
        }
        return Set(builtIns)
            .union(contextualHomographWords)
            .union(monitoredOrdinaryLexiconWords)
    }()
}

/// Shared source-mapping rules for occurrence, dictionary, and regex rewriters.
nonisolated enum PronunciationAuditContext {
    private static let contextRadius = 5

    static func requiresContextualEvidence(
        normalizedWord: String,
        source: PronunciationAuditDecision.Source
    ) -> Bool {
        guard
            ContextualPronunciationFamilies.family(
                for: normalizedWord)?.state == .shadow
        else {
            return false
        }
        switch source {
        case .occurrenceOverride, .bookOverride, .globalOverride, .epubInline, .epubLexicon,
            .builtInOverride:
            return false
        default:
            return true
        }
    }

    static func canonicalEnglishKeySpelling(_ sourceWord: String) -> String {
        sourceWord.lowercased()
            .replacingOccurrences(of: "’", with: "'")
    }

    static func normalizedWord(_ sourceWord: String) -> String {
        let display = MisakiPronunciationMarkup.displayText(from: sourceWord)
        return WordTokenizer.words(in: display)
            .map { word in
                canonicalEnglishKeySpelling(
                    String(word)
                        .trimmingCharacters(in: CharacterSet.alphanumerics.inverted))
            }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    static func ruleComponent(_ sourceWord: String) -> String {
        let normalized = normalizedWord(sourceWord)
        var result = ""
        var needsSeparator = false
        for character in normalized {
            if character.isLetter || character.isNumber {
                if needsSeparator, !result.isEmpty { result.append("-") }
                result.append(contentsOf: character.lowercased())
                needsSeparator = false
            } else {
                needsSeparator = true
            }
        }
        return result
    }

    static func sourceContext(
        in sourceText: String,
        wordStart: Int,
        wordEnd: Int
    ) -> String {
        let displayText = MisakiPronunciationMarkup.displayText(from: sourceText)
        let words = WordTokenizer.words(in: displayText)
        guard !words.isEmpty,
            wordStart >= 0,
            wordEnd >= wordStart,
            wordStart < words.count
        else {
            return ""
        }

        let boundedEnd = min(wordEnd, words.count - 1)
        let lower = max(0, wordStart - contextRadius)
        let upper = min(words.count - 1, boundedEnd + contextRadius)
        return words[lower...upper].map(String.init).joined(separator: " ")
    }

    /// Maps a source regex range onto the canonical whitespace-token span of the
    /// markup-free display text. This deliberately does not use a resolver loop index.
    static func wordSpan(
        containing sourceRange: Range<String.Index>,
        in sourceText: String
    ) -> ClosedRange<Int>? {
        let displayText = MisakiPronunciationMarkup.displayText(from: sourceText)
        let displayPrefix = MisakiPronunciationMarkup.displayText(
            from: String(sourceText[..<sourceRange.lowerBound]))
        let displayThroughMatch = MisakiPronunciationMarkup.displayText(
            from: String(sourceText[..<sourceRange.upperBound]))
        let matchRange = NSRange(
            location: displayPrefix.utf16.count,
            length: displayThroughMatch.utf16.count - displayPrefix.utf16.count)
        guard matchRange.length > 0 else { return nil }

        let matchingIndexes = WordTokenizer.wordRanges(in: displayText).enumerated().compactMap {
            index, wordRange in
            let range = NSRange(wordRange, in: displayText)
            return NSIntersectionRange(range, matchRange).length > 0 ? index : nil
        }
        guard let first = matchingIndexes.first, let last = matchingIndexes.last else {
            return nil
        }
        return first...last
    }

    /// Maps a validated token range in chunk display characters onto that chunk's
    /// canonical whitespace-token span. Misaki's own token indices are deliberately
    /// excluded because they address its preprocessed string, not authored markup.
    static func wordSpan(
        overlappingDisplayCharacterRange characterRange: Range<Int>,
        in displayText: String
    ) -> ClosedRange<Int>? {
        guard
            characterRange.lowerBound >= 0,
            characterRange.lowerBound < characterRange.upperBound,
            characterRange.upperBound <= displayText.count
        else {
            return nil
        }

        let lowerBound = displayText.index(
            displayText.startIndex,
            offsetBy: characterRange.lowerBound)
        let upperBound = displayText.index(
            displayText.startIndex,
            offsetBy: characterRange.upperBound)
        let tokenRange = lowerBound..<upperBound
        let matchingIndexes = WordTokenizer.wordRanges(in: displayText).enumerated().compactMap {
            index, wordRange in
            wordRange.overlaps(tokenRange) ? index : nil
        }
        guard let first = matchingIndexes.first, let last = matchingIndexes.last else {
            return nil
        }
        return first...last
    }

    static func decisionSeed(
        for evidence: PronunciationTokenEvidence,
        blockID: String,
        chunkDisplayText: String,
        blockDisplayText: String,
        wordBase: Int,
        isComparisonCandidate: Bool = false
    ) -> PronunciationDecisionSeed? {
        let normalizedWord = normalizedWord(evidence.text)
        guard
            !normalizedWord.isEmpty,
            !isIntentionalOOVMarkerOutput(evidence.selectedPhonemes),
            evidence.usedFallback || isComparisonCandidate
                || PronunciationWatchVocabulary.words.contains(normalizedWord)
                || isAcronym(evidence.text)
                || isRejectedRawG2POutput(evidence.selectedPhonemes),
            let localWordSpan = wordSpan(
                overlappingDisplayCharacterRange: evidence.displayCharacterRange,
                in: chunkDisplayText)
        else {
            return nil
        }

        let wordStart = wordBase + localWordSpan.lowerBound
        let wordEnd = wordBase + localWordSpan.upperBound
        let source: PronunciationAuditDecision.Source =
            evidence.usedFallback ? .fallback : .monitoredLexicon
        // A closed compound reuses two known lexical components, so it must not
        // read as a blind whole-token guess in the audit even though it shares
        // the fallback's OOV rating.
        let ruleKind: String
        let rationale: String
        if let components = evidence.compoundComponents {
            ruleKind = "compound"
            rationale =
                "Closed-compound pronunciation built from known components "
                + "“\(components)” for “\(evidence.text)”."
        } else if evidence.usedFallback {
            ruleKind = "fallback"
            rationale = "Deterministic G2P fallback selected for “\(evidence.text)”."
        } else {
            ruleKind = "lexicon"
            rationale =
                "Watched ordinary-lexicon pronunciation selected for “\(evidence.text)”."
        }
        let selectedIdentity = selectedCandidateIdentity(
            normalizedWord: normalizedWord,
            selectedIPA: evidence.selectedPhonemes,
            source: source)
        return PronunciationDecisionSeed(
            blockID: blockID,
            wordStart: wordStart,
            wordEnd: wordEnd,
            normalizedWord: normalizedWord,
            sourceWord: evidence.text,
            sourceContext: sourceContext(
                in: blockDisplayText,
                wordStart: wordStart,
                wordEnd: wordEnd),
            selectedIPA: evidence.selectedPhonemes,
            source: source,
            ruleID: "g2p.\(ruleKind).\(ruleComponent(evidence.text))",
            rationale: rationale,
            candidateID: selectedIdentity?.candidateID,
            candidatePackVersion: selectedIdentity?.packVersion)
    }

    private static func selectedCandidateIdentity(
        normalizedWord: String,
        selectedIPA: String,
        source: PronunciationAuditDecision.Source
    ) -> (candidateID: String, packVersion: String)? {
        let packVersion = "misaki.us.lexicon.v1"
        let normalizedIPA = selectedIPA.precomposedStringWithCanonicalMapping
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard source == .monitoredLexicon,
            !normalizedWord.isEmpty,
            !normalizedIPA.isEmpty,
            !isRejectedRawG2POutput(normalizedIPA),
            !isIntentionalOOVMarkerOutput(normalizedIPA)
        else {
            return nil
        }
        let payload = [packVersion, normalizedWord, normalizedIPA]
            .joined(separator: "\u{1F}")
        let digest = SHA256.hash(data: Data(payload.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return ("\(packVersion).sha256:\(digest)", packVersion)
    }

    /// Invalid raw token output is audit-worthy even when it did not arise from
    /// an ordinary fallback/watch/comparison route. This is a receipt-only
    /// predicate; `PronunciationPlanner` remains the strict synthesis boundary.
    nonisolated static func hasUnencodableSelectedOutput(_ phonemes: String) -> Bool {
        guard !phonemes.isEmpty else { return true }
        guard let vocabulary = try? KokoroPhonemeVocab() else { return true }
        return (try? vocabulary.validatedIDs(forPhonemes: phonemes)) == nil
    }

    /// The marker is deliberately stripped by `PronunciationPlanner` before
    /// strict vocabulary validation. Any nonempty raw output whose marker-
    /// stripped remainder is empty therefore carries no audit decision at all:
    /// it is neither a rejected raw G2P receipt nor a normal materialized
    /// pronunciation.
    nonisolated static func isIntentionalOOVMarkerOutput(_ phonemes: String) -> Bool {
        !phonemes.isEmpty
            && phonemes.allSatisfy { $0 == KokoroPhonemeVocab.oovMarker }
    }

    nonisolated static func isRejectedRawG2POutput(_ phonemes: String) -> Bool {
        guard !phonemes.isEmpty else { return true }
        let markerStrippedPhonemes = phonemes.filter {
            $0 != KokoroPhonemeVocab.oovMarker
        }
        guard !markerStrippedPhonemes.isEmpty else { return false }
        return hasUnencodableSelectedOutput(markerStrippedPhonemes)
    }

    private static func isAcronym(_ word: String) -> Bool {
        let letters = word.filter(\.isLetter)
        guard letters.count > 1 else { return false }
        return letters.allSatisfy(\.isUppercase)
    }
}
