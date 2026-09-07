// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import Foundation
import Testing

@testable import Echo

@Suite struct PronunciationListeningReelTests {
    private func decision(
        word: String,
        ipa: String? = nil,
        ruleID: String? = nil,
        source: PronunciationAuditDecision.Source = .monitoredLexicon,
        contextualEvidence: ContextualPronunciationEvidence? = nil,
        advisoryEvidence: PronunciationAdvisoryEvidence? = nil,
        range: PronunciationAuditDecision.AudioRange?,
        precision: PronunciationAuditDecision.TimingPrecision?
    ) -> PronunciationAuditDecision {
        PronunciationAuditDecision(
            blockID: "s0-b0",
            wordStart: 0,
            wordEnd: 0,
            normalizedWord: word,
            sourceWord: word,
            sourceContext: "Listen to \(word) in this context",
            selectedIPA: ipa ?? "ipa-\(word)",
            kokoroTokenIDs: [1, 2],
            source: source,
            ruleID: ruleID ?? "rule.\(word)",
            rationale: "Synthetic reel fixture.",
            contextualEvidence: contextualEvidence,
            advisoryEvidence: advisoryEvidence,
            chapterIndex: 0,
            chapterRelativeAudioRange: range,
            bookRelativeAudioRange: range,
            timingPrecision: precision)
    }

    private let sourceURL = URL(fileURLWithPath: "/tmp/public-synthetic.m4b")

    @Test func entriesCarryStructuredAdvisoryIdentityWithoutSourceContext() throws {
        let decision = decision(
            word: "record",
            ipa: "ɹəkˈɔɹd",
            source: .contextualHomograph,
            advisoryEvidence: PronunciationAdvisoryEvidence(
                category: .contextual,
                selectedAuthority: .qualified,
                selectedCandidateID: "record.verb",
                alternatives: [
                    .init(
                        candidateID: "record.verb",
                        ipa: "ɹəkˈɔɹd",
                        source: "fixture",
                        authority: .qualified,
                        validation: .shadow,
                        policyVersion: "policy-v1"),
                    .init(
                        candidateID: "record.noun",
                        ipa: "ɹˈɛkəɹd",
                        source: "fixture",
                        authority: .qualified,
                        validation: .shadow,
                        policyVersion: "policy-v1"),
                ],
                selectionReason: .qualifiedDeterministicContext,
                overrideSuppressedAutomation: false,
                policyVersion: "policy-v1"),
            range: .init(start: 1, end: 1.2),
            precision: .exactSynthesisWord)
        let entries = PronunciationListeningReel.entries(
            decisions: [decision],
            audiobookURL: sourceURL,
            sourceDuration: CMTime(seconds: 30, preferredTimescale: 600))
        let exports = PronunciationListeningReel.exportItems(
            decisions: [decision],
            audiobookURL: sourceURL,
            sourceDuration: CMTime(seconds: 30, preferredTimescale: 600))
        let entry = try #require(entries.first)

        #expect(entry.candidateIDs == ["record.noun", "record.verb"])
        #expect(entry.category == .contextual)
        #expect(entry.selectedAuthority == .qualified)
        #expect(entry.audioRange == .init(start: 0.75, end: 1.45))
        #expect(!entry.title.contains("Synthetic reel fixture"))
        #expect(exports == entries.map(\.exportItem))
    }

    private func shadowDisagreementEvidence() -> ContextualPronunciationEvidence {
        ContextualPronunciationEvidence(
            occurrenceID: ContextualPronunciationOccurrenceID.make(
                blockID: "s0-b0", wordStart: 0, wordEnd: 0, normalizedWord: "record"),
            familyID: "record",
            candidatePackVersion: ContextualPronunciationFamilies.candidatePackVersion,
            submittedCandidateIDs: ["record.noun", "record.verb"],
            deterministicCandidateID: "record.noun",
            deterministicRuleID: "record.noun.fixture",
            deterministicStrength: .definitive,
            modelCandidateID: "record.verb",
            modelAbstained: false,
            modelAvailability: .available,
            modelFailure: nil,
            familyState: .shadow,
            acceptanceReason: .shadowObserved,
            promptSchemaVersion: ContextualPronunciationFamilies.promptSchemaVersion,
            platform: "test",
            osBuild: "test-build",
            qualifiedRuntimeFamilyID: "test-runtime",
            humanCandidateID: nil,
            humanCorrectionScope: nil,
            isLimited: false)
    }

    private func shadowNeedsReviewEvidence() -> ContextualPronunciationEvidence {
        let evidence = shadowDisagreementEvidence()
        return ContextualPronunciationEvidence(
            occurrenceID: evidence.occurrenceID,
            familyID: evidence.familyID,
            candidatePackVersion: evidence.candidatePackVersion,
            submittedCandidateIDs: evidence.submittedCandidateIDs,
            deterministicCandidateID: evidence.deterministicCandidateID,
            deterministicRuleID: evidence.deterministicRuleID,
            deterministicStrength: evidence.deterministicStrength,
            modelCandidateID: nil,
            modelAbstained: true,
            modelAvailability: .available,
            modelFailure: nil,
            familyState: .shadow,
            acceptanceReason: .shadowNeedsReview,
            promptSchemaVersion: evidence.promptSchemaVersion,
            platform: evidence.platform,
            osBuild: evidence.osBuild,
            qualifiedRuntimeFamilyID: evidence.qualifiedRuntimeFamilyID,
            humanCandidateID: nil,
            humanCorrectionScope: nil,
            isLimited: false)
    }

    private func cancelledShadowFailureEvidence() -> ContextualPronunciationEvidence {
        let evidence = shadowDisagreementEvidence()
        return ContextualPronunciationEvidence(
            occurrenceID: evidence.occurrenceID,
            familyID: evidence.familyID,
            candidatePackVersion: evidence.candidatePackVersion,
            submittedCandidateIDs: evidence.submittedCandidateIDs,
            deterministicCandidateID: evidence.deterministicCandidateID,
            deterministicRuleID: evidence.deterministicRuleID,
            deterministicStrength: evidence.deterministicStrength,
            modelCandidateID: nil,
            modelAbstained: false,
            modelAvailability: .available,
            modelFailure: .cancelled,
            familyState: .shadow,
            acceptanceReason: .shadowModelFailure,
            promptSchemaVersion: evidence.promptSchemaVersion,
            platform: evidence.platform,
            osBuild: evidence.osBuild,
            qualifiedRuntimeFamilyID: evidence.qualifiedRuntimeFamilyID,
            humanCandidateID: nil,
            humanCorrectionScope: nil,
            isLimited: false)
    }

    @Test func selectionDeduplicatesAfterValidationAndPreservesReadingOrder() {
        let invalidFirst = decision(
            word: "verified", range: .init(start: 2, end: 2), precision: .exactSynthesisWord)
        let validLater = decision(
            word: "verified", range: .init(start: 1, end: 1.2), precision: .exactSynthesisWord)
        let duplicate = decision(
            word: "verified", range: .init(start: 3, end: 3.2), precision: .exactSynthesisWord)
        let filesystem = decision(
            word: "filesystem", range: .init(start: 4, end: 4.5), precision: .blockAnchorFallback)

        let items = PronunciationListeningReel.exportItems(
            decisions: [invalidFirst, validLater, duplicate, filesystem],
            audiobookURL: sourceURL,
            sourceDuration: CMTime(seconds: 10, preferredTimescale: 24_000))

        #expect(items.count == 2)
        #expect(items.map(\.url) == [sourceURL, sourceURL])
        #expect(items[0].title.contains("1"))
        #expect(items[0].title.contains("verified"))
        #expect(items[1].title.contains("2"))
        #expect(items[1].title.contains("filesystem"))
        #expect(abs((items[0].timeRange?.start.seconds ?? -1) - 0.75) < 0.000_01)
        #expect(abs((items[0].timeRange?.end.seconds ?? -1) - 1.45) < 0.000_01)
        #expect(abs((items[1].timeRange?.start.seconds ?? -1) - 4) < 0.000_01)
        #expect(abs((items[1].timeRange?.end.seconds ?? -1) - 4.5) < 0.000_01)
    }

    @Test func selectionCapsAtSixteenAndLabelsEveryChapter() {
        let decisions = (0..<18).map { index in
            decision(
                word: "word-\(index)",
                range: .init(start: Double(index), end: Double(index) + 0.1),
                precision: .blockAnchorFallback)
        }

        let items = PronunciationListeningReel.exportItems(
            decisions: decisions,
            audiobookURL: sourceURL,
            sourceDuration: CMTime(seconds: 30, preferredTimescale: 600))

        #expect(items.count == 16)
        for (index, item) in items.enumerated() {
            #expect(item.title.contains("\(index + 1)"))
            #expect(item.title.contains("word-\(index)"))
            #expect(item.title.contains("rule.word-\(index)"))
            #expect(item.title.contains("ipa-word-\(index)"))
        }
    }

    @Test func highRiskContextualSampleDisplacesLowerPriorityWhenBounded() {
        let lowPriority = (0..<16).map { index in
            decision(
                word: "ordinary-\(index)",
                source: .monitoredLexicon,
                range: .init(start: Double(index), end: Double(index) + 0.1),
                precision: .blockAnchorFallback)
        }
        let contextual = decision(
            word: "record",
            ipa: "ɹəkˈɔɹd",
            ruleID: "homograph.record.verb",
            source: .contextualHomograph,
            contextualEvidence: shadowDisagreementEvidence(),
            range: .init(start: 20, end: 20.2),
            precision: .exactSynthesisWord)

        let items = PronunciationListeningReel.exportItems(
            decisions: lowPriority + [contextual],
            audiobookURL: sourceURL,
            sourceDuration: CMTime(seconds: 30, preferredTimescale: 600))

        #expect(items.count == 16)
        #expect(items.first?.title.contains("record") == true)
        #expect(items.contains { $0.title.contains("ordinary-15") } == false)
    }

    @Test func shadowNeedsReviewDisplacesMonitoredSampleAtSixteenItemCap() {
        let monitored = (0..<16).map { index in
            decision(
                word: "ordinary-\(index)",
                source: .monitoredLexicon,
                range: .init(start: Double(index), end: Double(index) + 0.1),
                precision: .blockAnchorFallback)
        }
        let needsReview = decision(
            word: "record",
            ipa: "ɹəkˈɔɹd",
            ruleID: "homograph.record.verb",
            source: .contextualHomograph,
            contextualEvidence: shadowNeedsReviewEvidence(),
            range: .init(start: 20, end: 20.2),
            precision: .exactSynthesisWord)

        let items = PronunciationListeningReel.exportItems(
            decisions: monitored + [needsReview],
            audiobookURL: sourceURL,
            sourceDuration: CMTime(seconds: 30, preferredTimescale: 600))

        #expect(items.count == 16)
        #expect(items.first?.title.contains("record") == true)
        #expect(items.contains { $0.title.contains("ordinary-15") } == false)
    }

    @Test func malformedShadowEvidenceCannotElevateListeningPriority() {
        let monitored = (0..<16).map { index in
            decision(
                word: "ordinary-\(index)",
                source: .monitoredLexicon,
                range: .init(start: Double(index), end: Double(index) + 0.1),
                precision: .blockAnchorFallback)
        }
        let valid = shadowDisagreementEvidence()
        let malformed = ContextualPronunciationEvidence(
            occurrenceID: valid.occurrenceID,
            familyID: valid.familyID,
            candidatePackVersion: valid.candidatePackVersion,
            submittedCandidateIDs: valid.submittedCandidateIDs,
            deterministicCandidateID: valid.deterministicCandidateID,
            deterministicRuleID: valid.deterministicRuleID,
            deterministicStrength: valid.deterministicStrength,
            modelCandidateID: valid.modelCandidateID,
            modelAbstained: valid.modelAbstained,
            modelAvailability: valid.modelAvailability,
            modelFailure: valid.modelFailure,
            familyState: valid.familyState,
            acceptanceReason: valid.acceptanceReason,
            promptSchemaVersion: valid.promptSchemaVersion,
            platform: valid.platform,
            osBuild: valid.osBuild,
            qualifiedRuntimeFamilyID: valid.qualifiedRuntimeFamilyID,
            humanCandidateID: valid.humanCandidateID,
            humanCorrectionScope: valid.humanCorrectionScope,
            isLimited: true)
        let contextual = decision(
            word: "record",
            source: .contextualHomograph,
            contextualEvidence: malformed,
            range: .init(start: 20, end: 20.2),
            precision: .exactSynthesisWord)

        let items = PronunciationListeningReel.exportItems(
            decisions: monitored + [contextual],
            audiobookURL: sourceURL,
            sourceDuration: CMTime(seconds: 30, preferredTimescale: 600))

        #expect(items.count == 16)
        #expect(items.contains { $0.title.contains("record") } == false)
    }

    @Test func shadowEvidenceCannotChangePriorityForOverrideSources() {
        let sources: [PronunciationAuditDecision.Source] = [
            .occurrenceOverride,
            .bookOverride,
            .globalOverride,
            .builtInOverride,
            .contextualHomograph,
            .supplementalLexicon,
            .derivedMorphology,
            .monitoredLexicon,
            .fallback,
        ]
        let monitored = (0..<16).map { index in
            decision(
                word: "ordinary-\(index)",
                source: .monitoredLexicon,
                range: .init(start: Double(index), end: Double(index) + 0.1),
                precision: .blockAnchorFallback)
        }

        for source in sources {
            let withoutEvidence = decision(
                word: "record",
                source: source,
                range: .init(start: 20, end: 20.2),
                precision: .exactSynthesisWord)
            let withEvidence = decision(
                word: "record",
                source: source,
                contextualEvidence: shadowDisagreementEvidence(),
                range: .init(start: 20, end: 20.2),
                precision: .exactSynthesisWord)
            let baseline = PronunciationListeningReel.exportItems(
                decisions: monitored + [withoutEvidence],
                audiobookURL: sourceURL,
                sourceDuration: CMTime(seconds: 30, preferredTimescale: 600))
            let evidenced = PronunciationListeningReel.exportItems(
                decisions: monitored + [withEvidence],
                audiobookURL: sourceURL,
                sourceDuration: CMTime(seconds: 30, preferredTimescale: 600))

            switch source {
            case .occurrenceOverride, .bookOverride, .globalOverride, .builtInOverride, .fallback:
                #expect(baseline.map(\.title) == evidenced.map(\.title))
            default:
                #expect(baseline.map(\.title) != evidenced.map(\.title))
                #expect(evidenced.first?.title.contains("record") == true)
            }
        }
    }

    @Test func cancelledShadowFailureCannotChangeListeningPriority() {
        let monitored = (0..<16).map { index in
            decision(
                word: "ordinary-\(index)",
                source: .monitoredLexicon,
                range: .init(start: Double(index), end: Double(index) + 0.1),
                precision: .blockAnchorFallback)
        }
        let withoutEvidence = decision(
            word: "record",
            source: .contextualHomograph,
            range: .init(start: 20, end: 20.2),
            precision: .exactSynthesisWord)
        let withCancelledEvidence = decision(
            word: "record",
            source: .contextualHomograph,
            contextualEvidence: cancelledShadowFailureEvidence(),
            range: .init(start: 20, end: 20.2),
            precision: .exactSynthesisWord)

        let baseline = PronunciationListeningReel.exportItems(
            decisions: monitored + [withoutEvidence],
            audiobookURL: sourceURL,
            sourceDuration: CMTime(seconds: 30, preferredTimescale: 600))
        let cancelled = PronunciationListeningReel.exportItems(
            decisions: monitored + [withCancelledEvidence],
            audiobookURL: sourceURL,
            sourceDuration: CMTime(seconds: 30, preferredTimescale: 600))

        #expect(baseline.map(\.title) == cancelled.map(\.title))
    }

    @Test func uniquenessRemainsPronunciationSpecificAfterRiskSorting() {
        let noun = decision(
            word: "record",
            ipa: "ɹˈɛkəɹd",
            ruleID: "homograph.record.noun",
            range: .init(start: 1, end: 1.2),
            precision: .exactSynthesisWord)
        let verb = decision(
            word: "record",
            ipa: "ɹəkˈɔɹd",
            ruleID: "homograph.record.verb",
            source: .contextualHomograph,
            contextualEvidence: shadowDisagreementEvidence(),
            range: .init(start: 2, end: 2.2),
            precision: .exactSynthesisWord)

        let items = PronunciationListeningReel.exportItems(
            decisions: [noun, verb],
            audiobookURL: sourceURL,
            sourceDuration: CMTime(seconds: 10, preferredTimescale: 600))

        #expect(items.count == 2)
        #expect(items.contains { $0.title.contains("ɹˈɛkəɹd") })
        #expect(items.contains { $0.title.contains("ɹəkˈɔɹd") })
    }

    @Test func exactPaddingAndFallbackRangesClampToLoadedAssetDuration() {
        let exactAtStart = decision(
            word: "startable", range: .init(start: 0.1, end: 0.2), precision: .exactSynthesisWord)
        let exactAtEnd = decision(
            word: "verified", range: .init(start: 0.9, end: 1.2), precision: .exactSynthesisWord)
        let fallback = decision(
            word: "filesystem", range: .init(start: -0.2, end: 0.3), precision: .blockAnchorFallback
        )

        let items = PronunciationListeningReel.exportItems(
            decisions: [exactAtStart, exactAtEnd, fallback],
            audiobookURL: sourceURL,
            sourceDuration: CMTime(value: 24_000, timescale: 24_000))

        #expect(items.count == 3)
        #expect(items[0].timeRange?.start == .zero)
        #expect(abs((items[0].timeRange?.end.seconds ?? -1) - 0.45) < 0.000_01)
        #expect(abs((items[1].timeRange?.start.seconds ?? -1) - 0.65) < 0.000_01)
        #expect(items[1].timeRange?.end == CMTime(value: 24_000, timescale: 24_000))
        #expect(items[2].timeRange?.start == .zero)
        #expect(abs((items[2].timeRange?.end.seconds ?? -1) - 0.3) < 0.000_01)
    }

    @Test func invalidOrUntimedRangesNeverBecomeSamples() {
        let decisions = [
            decision(word: "missing", range: nil, precision: .exactSynthesisWord),
            decision(word: "unknown", range: .init(start: 0, end: 1), precision: nil),
            decision(
                word: "nan", range: .init(start: .nan, end: 1), precision: .exactSynthesisWord),
            decision(word: "zero", range: .init(start: 1, end: 1), precision: .blockAnchorFallback),
            decision(word: "past", range: .init(start: 2, end: 3), precision: .blockAnchorFallback),
            decision(
                word: "good", range: .init(start: 0, end: 0.2), precision: .blockAnchorFallback),
        ]

        let items = PronunciationListeningReel.exportItems(
            decisions: decisions,
            audiobookURL: sourceURL,
            sourceDuration: CMTime(seconds: 1, preferredTimescale: 600))

        #expect(items.count == 1)
        #expect(items.first?.title.contains("good") == true)
    }

    @MainActor
    @Test func zeroSampleGenerationRemovesStaleReelThenWritesFinalManifest() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let audiobookURL = tmp.appendingPathComponent("book.m4b")
        let auditURL = tmp.appendingPathComponent("book.pronunciation-audit.json")
        let reelURL = tmp.appendingPathComponent("book.pronunciation-reel.m4b")
        try Data("exact audiobook".utf8).write(to: audiobookURL)
        try Data("stale reel".utf8).write(to: reelURL)

        let outcome = try await PronunciationReviewArtifactGenerator.generate(
            PronunciationReviewRequest(
                audiobookURL: audiobookURL,
                auditURL: auditURL,
                reelURL: reelURL,
                renderVersion: 11,
                voice: VoiceID("af_heart"),
                captureCoverage: .complete,
                legacyChapterIndexes: [],
                decisions: [],
                diagnostics: [],
                watchWords: ["filesystem", "verified"]))

        #expect(outcome == .auditOnly(auditURL: auditURL))
        #expect(FileManager.default.fileExists(atPath: auditURL.path))
        #expect(!FileManager.default.fileExists(atPath: reelURL.path))
        let manifest = try JSONDecoder().decode(
            PronunciationAuditManifest.self, from: Data(contentsOf: auditURL))
        #expect(manifest.decisions.isEmpty)
        #expect(manifest.listeningReelFileName == nil)
        #expect(manifest.listeningReelSHA256 == nil)
        try manifest.validateArtifacts(audiobookURL: audiobookURL, reelURL: nil)
    }

    @MainActor
    @Test func validSampleGenerationReplacesStaleArtifactsAndReportsBothURLs() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let source = try await SilentAudioFixture.makeSilentM4A(seconds: 2)
        defer { try? FileManager.default.removeItem(at: source) }
        let audiobookURL = tmp.appendingPathComponent("book.m4b")
        let auditURL = tmp.appendingPathComponent("book.pronunciation-audit.json")
        let reelURL = tmp.appendingPathComponent("book.pronunciation-reel.m4b")
        try await AudioExportService().exportM4B(
            items: [ExportItem(title: "Book", url: source, timeRange: nil)],
            outputURL: audiobookURL)
        let staleAudit = Data("stale audit".utf8)
        let staleReel = Data("stale reel".utf8)
        try staleAudit.write(to: auditURL)
        try staleReel.write(to: reelURL)

        let verified = decision(
            word: "verified",
            ipa: "vɛɹɪfaɪd",
            ruleID: "g2p.lexicon.verified",
            range: .init(start: 0.5, end: 0.8),
            precision: .exactSynthesisWord)
        let outcome = try await PronunciationReviewArtifactGenerator.generate(
            PronunciationReviewRequest(
                audiobookURL: audiobookURL,
                auditURL: auditURL,
                reelURL: reelURL,
                renderVersion: 11,
                voice: VoiceID("af_heart"),
                captureCoverage: .complete,
                legacyChapterIndexes: [],
                decisions: [verified],
                diagnostics: [],
                watchWords: ["verified", "filesystem"]))

        #expect(outcome == .generated(auditURL: auditURL, reelURL: reelURL))
        #expect(try Data(contentsOf: auditURL) != staleAudit)
        #expect(try Data(contentsOf: reelURL) != staleReel)
        let manifest = try JSONDecoder().decode(
            PronunciationAuditManifest.self, from: Data(contentsOf: auditURL))
        #expect(manifest.listeningReelFileName == reelURL.lastPathComponent)
        #expect(manifest.listeningReelSHA256 != nil)
        #expect(manifest.decisions == [verified])
        try manifest.validateArtifacts(audiobookURL: audiobookURL, reelURL: reelURL)

        let audiobookData = try Data(contentsOf: audiobookURL)
        var mutatedAudiobook = audiobookData
        mutatedAudiobook[mutatedAudiobook.startIndex] ^= 0xff
        try mutatedAudiobook.write(to: audiobookURL)
        #expect(throws: Error.self) {
            try manifest.validateArtifacts(audiobookURL: audiobookURL, reelURL: reelURL)
        }
        try audiobookData.write(to: audiobookURL)

        let originalReelData = try Data(contentsOf: reelURL)
        var mutatedReel = originalReelData
        mutatedReel[mutatedReel.startIndex] ^= 0xff
        try mutatedReel.write(to: reelURL)
        #expect(throws: Error.self) {
            try manifest.validateArtifacts(audiobookURL: audiobookURL, reelURL: reelURL)
        }
        try originalReelData.write(to: reelURL)

        let reelAsset = AVURLAsset(url: reelURL)
        let duration = try await reelAsset.load(.duration)
        let locales = try await reelAsset.load(.availableChapterLocales)
        let groups = try await reelAsset.loadChapterMetadataGroups(
            bestMatchingPreferredLanguages: locales.map(\.identifier))
        let chapterTitle = groups.first?.items.first { $0.commonKey == .commonKeyTitle }
        let title = try await chapterTitle?.load(.stringValue)
        let reelData = try Data(contentsOf: reelURL)
        #expect(duration.seconds > 0.5)
        #expect(groups.count == 1)
        #expect(title?.contains("verified") == true)
        #expect(title?.contains("g2p.lexicon.verified") == true)
        #expect(reelData.range(of: Data("vɛɹɪfaɪd".utf8)) != nil)

        let siblings = try FileManager.default.contentsOfDirectory(
            at: tmp, includingPropertiesForKeys: nil)
        #expect(
            Set(siblings.map(\.lastPathComponent)) == [
                audiobookURL.lastPathComponent,
                auditURL.lastPathComponent,
                reelURL.lastPathComponent,
            ])
    }
}
