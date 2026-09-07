// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

@Suite struct NarrationFileNamingTests {
    @Test func renderVersionRegeneratesCachesForAtomicQualityRetry() {
        // v25 changes contextual content pronunciation and identifier normalization.
        // Earlier versions retagged sentence-initial imperative heteronyms as verbs before
        // lexicon lookup, so v23 audio and pronunciation evidence may not be
        // reused.
        #expect(NarrationFileNaming.renderVersion == 25)
        let current = NarrationFileNaming.chapterFileName(
            audiobookID: "book",
            chapterIndex: 0,
            voice: VoiceID("af_heart"),
            contentSignature: "0123456789abcdef")
        let previous = current.replacing("-v25.m4a", with: "-v24.m4a")

        #expect(current.hasSuffix("-v25.m4a"))
        #expect(
            NarrationFileNaming.isCurrentChapterCacheFileName(
                current,
                audiobookID: "book",
                chapterIndex: 0,
                voice: VoiceID("af_heart")))
        #expect(
            !NarrationFileNaming.isCurrentChapterCacheFileName(
                previous,
                audiobookID: "book",
                chapterIndex: 0,
                voice: VoiceID("af_heart")))
    }

    @Test func parsesChapterIndexFromFileName() {
        // Format: "{safeID}-ch{N}-{voice}.m4a" — safeID has no '-' (safeToken maps
        // non-alphanumerics to '_'), so "-ch" only marks the chapter separator.
        #expect(NarrationFileNaming.chapterIndex(fromFileName: "book_id-ch0-af_heart.m4a") == 0)
        #expect(NarrationFileNaming.chapterIndex(fromFileName: "x_y-ch12-bf_emma.m4a") == 12)
    }

    @Test func returnsNilForNonNarrationFileName() {
        #expect(NarrationFileNaming.chapterIndex(fromFileName: "cover.jpg") == nil)
        #expect(NarrationFileNaming.chapterIndex(fromFileName: "book-noch-af_heart.m4a") == nil)
    }

    @Test func segmentFileNameRoundTrips() {
        let name = NarrationFileNaming.segmentFileName(
            audiobookID: "file:///b/", chapterIndex: 3, segmentIndex: 2,
            voice: VoiceID("af_heart"))

        #expect(name.contains("-ch3-s2-af_heart-v\(NarrationFileNaming.renderVersion).m4a"))
        let location = NarrationFileNaming.segmentLocation(fromFileName: name)
        #expect(location?.chapterIndex == 3)
        #expect(location?.segmentIndex == 2)
        #expect(NarrationFileNaming.chapterIndex(fromFileName: name) == 3)
    }

    @Test func currentNamesAndLegacyLocationsKeepStableShapes() {
        let voice = VoiceID("af_heart")
        #expect(
            NarrationFileNaming.chapterFileName(
                audiobookID: "book", chapterIndex: 3, voice: voice,
                contentSignature: "abc")
                == "book-ch3-habc-af_heart-v25.m4a")
        #expect(
            NarrationFileNaming.segmentFileName(
                audiobookID: "book", chapterIndex: 3, segmentIndex: 2,
                voice: voice, contentSignature: "abc")
                == "book-ch3-s2-habc-af_heart-v25.m4a")
        #expect(
            NarrationFileNaming.location(fromFileName: "book-ch3-s2-habc-af_heart-v22.m4a")
                == NarrationCacheLocation(
                    chapterIndex: 3, stableChapterToken: nil, segmentIndex: 2))
        #expect(
            NarrationFileNaming.trackID(
                audiobookID: "book", chapterIndex: 3, sourceChapterKey: nil, segmentIndex: 2)
                == "syn-book-ch3-s2")
    }

    @Test func stableNameDoesNotChangeWhenChapterIndexChanges() {
        let entryKey = "75D4AA19-0B16-4B27-A2CD-D4E19ED6B20A"
        let first = NarrationFileNaming.segmentFileName(
            audiobookID: "book", chapterIndex: 1, sourceChapterKey: entryKey,
            segmentIndex: 0, voice: VoiceID("af_heart"), contentSignature: "abc")
        let reordered = NarrationFileNaming.segmentFileName(
            audiobookID: "book", chapterIndex: 9, sourceChapterKey: entryKey,
            segmentIndex: 0, voice: VoiceID("af_heart"), contentSignature: "abc")

        #expect(first == reordered)
        #expect(
            NarrationFileNaming.stableChapterToken(for: entryKey)
                == "97d14f79c9575b190d779d03e1448164")
        #expect(NarrationFileNaming.location(fromFileName: first)?.chapterIndex == nil)
        #expect(NarrationFileNaming.location(fromFileName: first)?.stableChapterToken?.count == 32)
        #expect(
            NarrationFileNaming.trackID(
                audiobookID: "book", chapterIndex: 9, sourceChapterKey: entryKey, segmentIndex: 0)
                == "syn-book-ck\(NarrationFileNaming.stableChapterToken(for: entryKey))-s0")
    }

    @Test func stableLocationRejectsMalformedOrAmbiguousNames() {
        let stablePrefix = "book-ck0123456789abcdef0123456789abcdef"
        #expect(NarrationFileNaming.location(fromFileName: "book-ckABC-s0-af_heart-v22.m4a") == nil)
        #expect(
            NarrationFileNaming.location(
                fromFileName: "book-ck0123456789abcdef0123456789abcdef-s-af_heart-v22.m4a") == nil)
        #expect(
            NarrationFileNaming.location(
                fromFileName:
                    "book-ck0123456789abcdef0123456789abcdef-s0-af_heart-v\(NarrationFileNaming.renderVersion - 1).m4a"
            ) == nil)
        #expect(
            NarrationFileNaming.location(fromFileName: "\(stablePrefix)-ch4-af_heart-v22.m4a")
                == nil)
        #expect(
            NarrationFileNaming.location(fromFileName: "\(stablePrefix)--ch-af_heart-v22.m4a")
                == nil)
        #expect(
            NarrationFileNaming.location(fromFileName: "\(stablePrefix)-s0-s1-af_heart-v22.m4a")
                == nil)
        #expect(NarrationFileNaming.location(fromFileName: "book-ch3-s-af_heart-v22.m4a") == nil)
        #expect(NarrationFileNaming.location(fromFileName: "book-ch3-ch4-af_heart-v22.m4a") == nil)
        #expect(NarrationFileNaming.location(fromFileName: "book-ch3--ch-af_heart-v22.m4a") == nil)
        #expect(
            NarrationFileNaming.location(fromFileName: "book-ch3-s0-s1-af_heart-v22.m4a") == nil)
        #expect(
            NarrationFileNaming.location(fromFileName: "book-ch3-plan-0123456789-v22.m4a") == nil)
        #expect(
            NarrationFileNaming.location(fromFileName: "book-ch3-plan-0123456789ag-v22.m4a") == nil)
        #expect(
            NarrationFileNaming.location(fromFileName: "\(stablePrefix)-plan-0123456789-v22.m4a")
                == nil)
        #expect(
            NarrationFileNaming.location(fromFileName: "\(stablePrefix)-plan-0123456789ag-v22.m4a")
                == nil)
        #expect(
            NarrationFileNaming.location(fromFileName: "book-ch3-af_heart-v22.m4a")?.chapterIndex
                == 3)
        #expect(
            NarrationFileNaming.location(fromFileName: "book-ch3-plan-0123456789ab-v22.m4a")?
                .chapterIndex == 3)
        #expect(
            NarrationFileNaming.location(
                fromFileName: "book-ck0123456789abcdef0123456789abcdef-af_heart-v25.m4a")?
                .stableChapterToken != nil)
        #expect(
            NarrationFileNaming.location(fromFileName: "\(stablePrefix)-plan-0123456789ab-v25.m4a")?
                .stableChapterToken != nil)
    }

    @Test func contentSignatureChangesWithRenderedTextBlockIdentityAndRenderParameters() {
        let spokenBlock = block(id: "b0", text: "Kubernetes ships.")
        let plain = NarrationFileNaming.contentSignature(
            spokenBlocks: [spokenBlock],
            renderedTexts: ["Kubernetes ships."],
            includeLeadOutPad: false,
            pronunciationPolicySignature: EnglishPronunciationPack.empty.productionPolicySignature)
        let overridden = NarrationFileNaming.contentSignature(
            spokenBlocks: [spokenBlock],
            renderedTexts: ["[Kubernetes](/ku:bərnetis/) ships."],
            includeLeadOutPad: false,
            pronunciationPolicySignature: EnglishPronunciationPack.empty.productionPolicySignature)
        let differentBlock = NarrationFileNaming.contentSignature(
            spokenBlocks: [block(id: "b1", text: "Kubernetes ships.")],
            renderedTexts: ["Kubernetes ships."],
            includeLeadOutPad: false,
            pronunciationPolicySignature: EnglishPronunciationPack.empty.productionPolicySignature)
        let padded = NarrationFileNaming.contentSignature(
            spokenBlocks: [spokenBlock],
            renderedTexts: ["Kubernetes ships."],
            includeLeadOutPad: true,
            pronunciationPolicySignature: EnglishPronunciationPack.empty.productionPolicySignature)
        let fmMode = NarrationFileNaming.contentSignature(
            spokenBlocks: [spokenBlock],
            renderedTexts: ["Kubernetes ships."],
            includeLeadOutPad: false,
            normalizationMode: "fm-auto-v\(FMNormalizer.signatureVersion)",
            pronunciationPolicySignature: EnglishPronunciationPack.empty.productionPolicySignature)

        #expect(plain.count == 16)
        #expect(plain != overridden)
        #expect(plain != differentBlock)
        #expect(plain != padded)
        #expect(plain != fmMode)
    }

    @Test func distinctShadowPlansProduceTheSameContentSignature() throws {
        let sourceBlock = block(id: "b0", text: "Please record this.")
        let occurrence = try #require(
            ContextualPronunciationDiscovery.discover(
                text: sourceBlock.text ?? "",
                blockID: sourceBlock.id
            ).first)
        let key = ContextualPronunciationKey(
            blockID: occurrence.blockID,
            wordStart: occurrence.wordStart,
            wordEnd: occurrence.wordEnd)
        func artifact(
            slot: ContextualCandidateSlot
        ) throws -> (plan: NarrationRenderPlan, signature: String) {
            let evidence = ContextualPronunciationEvidence(
                occurrenceID: occurrence.occurrenceID,
                familyID: occurrence.familyID,
                candidatePackVersion: ContextualPronunciationFamilies.candidatePackVersion,
                submittedCandidateIDs: occurrence.candidates.map(\.candidateID),
                deterministicCandidateID: occurrence.deterministicCandidateID,
                deterministicRuleID: occurrence.deterministicRuleID,
                deterministicStrength: occurrence.deterministicStrength,
                modelCandidateID: occurrence.candidates.first { $0.slot == slot }?.candidateID,
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
            let plan = try NarrationRenderPlanner.make(
                blocks: [sourceBlock],
                overrides: PronunciationOverrides(entries: [:]),
                contextualEvidence: [key: evidence])
            let renderedTexts = plan.blocks.map { plannedBlock in
                plannedBlock.synthesisChunks.map(\.g2pInputText).joined(separator: " ")
            }
            let signature = NarrationFileNaming.contentSignature(
                spokenBlocks: plan.blocks.map(\.originalBlock),
                renderedTexts: renderedTexts,
                includeLeadOutPad: false,
                pronunciationPolicySignature:
                    EnglishPronunciationPack.empty.productionPolicySignature)
            return (plan, signature)
        }
        let nounArtifact = try artifact(slot: .a)
        let verbArtifact = try artifact(slot: .b)
        let nounEvidence = nounArtifact.plan.blocks
            .flatMap(\.pronunciationDecisions)
            .compactMap(\.contextualEvidence)
        let verbEvidence = verbArtifact.plan.blocks
            .flatMap(\.pronunciationDecisions)
            .compactMap(\.contextualEvidence)

        #expect(nounEvidence != verbEvidence)
        #expect(!nounEvidence.isEmpty)
        #expect(nounArtifact.signature == verbArtifact.signature)
    }

    @Test func contentSignatureChangesWhenBlockKindChangesPlannedSilence() {
        let paragraph = block(id: "b0", kind: "paragraph", text: "Chapter title")
        let heading = block(id: "b0", kind: "heading", text: "Chapter title")
        let paragraphSignature = NarrationFileNaming.contentSignature(
            spokenBlocks: [paragraph],
            renderedTexts: ["Chapter title"],
            includeLeadOutPad: false,
            pronunciationPolicySignature: EnglishPronunciationPack.empty.productionPolicySignature)
        let headingSignature = NarrationFileNaming.contentSignature(
            spokenBlocks: [heading],
            renderedTexts: ["Chapter title"],
            includeLeadOutPad: false,
            pronunciationPolicySignature: EnglishPronunciationPack.empty.productionPolicySignature)

        #expect(paragraphSignature != headingSignature)
    }

    @Test func contentSignatureIncludesSnapshottedPronunciationPolicy() {
        let block = block(id: "b0", text: "No rewritten text here.")
        let baseline = NarrationFileNaming.contentSignature(
            spokenBlocks: [block],
            renderedTexts: ["No rewritten text here."],
            includeLeadOutPad: false,
            pronunciationPolicySignature:
                "pack-a|morphology-a|content-default-legacy-adjective-v1")
        let changedNormalizedEntries = NarrationFileNaming.contentSignature(
            spokenBlocks: [block],
            renderedTexts: ["No rewritten text here."],
            includeLeadOutPad: false,
            pronunciationPolicySignature:
                "pack-normalized-b|morphology-b|content-default-legacy-adjective-v1")
        let changedSourceSnapshot = NarrationFileNaming.contentSignature(
            spokenBlocks: [block],
            renderedTexts: ["No rewritten text here."],
            includeLeadOutPad: false,
            pronunciationPolicySignature:
                "pack-source-b|morphology-c|content-default-legacy-adjective-v1")
        let changedGeneratorBehavior = NarrationFileNaming.contentSignature(
            spokenBlocks: [block],
            renderedTexts: ["No rewritten text here."],
            includeLeadOutPad: false,
            pronunciationPolicySignature:
                "pack-generator-b|morphology-d|content-default-legacy-adjective-v1")
        let changedVocabulary = NarrationFileNaming.contentSignature(
            spokenBlocks: [block],
            renderedTexts: ["No rewritten text here."],
            includeLeadOutPad: false,
            pronunciationPolicySignature:
                "pack-a|morphology-vocabulary-b|content-default-legacy-adjective-v1")
        let changedMorphologyRule = NarrationFileNaming.contentSignature(
            spokenBlocks: [block],
            renderedTexts: ["No rewritten text here."],
            includeLeadOutPad: false,
            pronunciationPolicySignature:
                "pack-a|morphology-rule-b|content-default-legacy-adjective-v1")
        let changedExceptionSet = NarrationFileNaming.contentSignature(
            spokenBlocks: [block],
            renderedTexts: ["No rewritten text here."],
            includeLeadOutPad: false,
            pronunciationPolicySignature:
                "pack-a|morphology-exception-b|content-default-legacy-adjective-v1")
        let changedBaseEvidence = NarrationFileNaming.contentSignature(
            spokenBlocks: [block],
            renderedTexts: ["No rewritten text here."],
            includeLeadOutPad: false,
            pronunciationPolicySignature:
                "pack-a|morphology-base-policy-b|content-default-legacy-adjective-v1")

        #expect(
            Set([
                baseline,
                changedNormalizedEntries,
                changedSourceSnapshot,
                changedGeneratorBehavior,
                changedVocabulary,
                changedMorphologyRule,
                changedExceptionSet,
                changedBaseEvidence,
            ]).count == 8)
    }

    @Test func materialNounAndLegacyAdjectiveContentPoliciesCannotShareCacheOrCaptureIdentity() {
        let pack = EnglishPronunciationPack.emptyForTesting(
            packVersion:
                "sha256:0000000000000000000000000000000000000000000000000000000000000000",
            kokoroVocabularyVersion:
                "sha256:1111111111111111111111111111111111111111111111111111111111111111")
        let block = block(id: "b0", text: "Content")
        let currentPolicy = pack.productionPolicySignature
        let legacyPolicy = pack.productionPolicySignature(
            contentDefaultPolicyVersion: "content-default-legacy-adjective-v1")
        let currentSignature = NarrationFileNaming.contentSignature(
            spokenBlocks: [block],
            renderedTexts: ["Content"],
            includeLeadOutPad: false,
            pronunciationPolicySignature: currentPolicy)
        let legacySignature = NarrationFileNaming.contentSignature(
            spokenBlocks: [block],
            renderedTexts: ["Content"],
            includeLeadOutPad: false,
            pronunciationPolicySignature: legacyPolicy)

        #expect(currentPolicy.hasSuffix("|content-default-material-noun-v1"))
        #expect(legacyPolicy.hasSuffix("|content-default-legacy-adjective-v1"))
        #expect(currentSignature != legacySignature)
        #expect(
            HeadlessNarrationRunner.captureSetID(
                sourceFingerprint: "source",
                voice: VoiceID("af_heart"),
                renderVersion: NarrationFileNaming.renderVersion,
                rendererIdentity: NarrationFileNaming.rendererIdentity,
                normalizationMode: "deterministic",
                orderedChapterSignatures: ["0:\(currentSignature)"])
                != HeadlessNarrationRunner.captureSetID(
                    sourceFingerprint: "source",
                    voice: VoiceID("af_heart"),
                    renderVersion: NarrationFileNaming.renderVersion,
                    rendererIdentity: NarrationFileNaming.rendererIdentity,
                    normalizationMode: "deterministic",
                    orderedChapterSignatures: ["0:\(legacySignature)"]))
    }

    @Test func auditOnlyPackTimestampCannotChangeProductionPolicyOrContentSignature() {
        let first = EnglishPronunciationPack.emptyForTesting(
            packVersion:
                "sha256:0000000000000000000000000000000000000000000000000000000000000000",
            kokoroVocabularyVersion:
                "sha256:1111111111111111111111111111111111111111111111111111111111111111",
            generationTimestamp: "2026-07-29T00:00:00Z")
        let second = EnglishPronunciationPack.emptyForTesting(
            packVersion: first.packVersion,
            kokoroVocabularyVersion: first.kokoroVocabularyVersion,
            generationTimestamp: "2026-07-30T00:00:00Z")
        let block = block(id: "b0", text: "Stable text.")

        #expect(first.packVersion == second.packVersion)
        #expect(
            UniversalPronunciationResolver.morphologyCandidatePackVersion(for: first)
                == UniversalPronunciationResolver.morphologyCandidatePackVersion(for: second))
        #expect(first.productionPolicySignature == second.productionPolicySignature)
        #expect(
            NarrationFileNaming.contentSignature(
                spokenBlocks: [block],
                renderedTexts: ["Stable text."],
                includeLeadOutPad: false,
                pronunciationPolicySignature: first.productionPolicySignature)
                == NarrationFileNaming.contentSignature(
                    spokenBlocks: [block],
                    renderedTexts: ["Stable text."],
                    includeLeadOutPad: false,
                    pronunciationPolicySignature: second.productionPolicySignature))
    }

    @Test func auditPackVersionCannotChangeNarrationFilenameOrContentSignature() async {
        let production = EnglishPronunciationPack.emptyForTesting(
            packVersion:
                "sha256:0000000000000000000000000000000000000000000000000000000000000000",
            kokoroVocabularyVersion:
                "sha256:1111111111111111111111111111111111111111111111111111111111111111")
        let audit = await EnglishPronunciationAuditPack.bundledOrEmpty()
        let block = block(id: "b0", text: "Stable text.")
        func identity(for auditPack: EnglishPronunciationAuditPack) -> (String, String) {
            // The audit version is intentionally observed only here: shadow
            // evidence must not enter either production identity.
            _ = auditPack.auditPackVersion
            let signature = NarrationFileNaming.contentSignature(
                spokenBlocks: [block],
                renderedTexts: ["Stable text."],
                includeLeadOutPad: false,
                pronunciationPolicySignature: production.productionPolicySignature)
            return (
                signature,
                NarrationFileNaming.chapterFileName(
                    audiobookID: "book",
                    chapterIndex: 0,
                    voice: VoiceID("af_heart"),
                    contentSignature: signature)
            )
        }

        #expect(audit.auditPackVersion != EnglishPronunciationAuditPack.empty.auditPackVersion)
        #expect(identity(for: audit) == identity(for: .empty))
    }

    @Test func contentSignedFileNamesStillRoundTripLocations() {
        let signature = "0123456789abcdef"
        let segment = NarrationFileNaming.segmentFileName(
            audiobookID: "file:///b/",
            chapterIndex: 3,
            segmentIndex: 2,
            voice: VoiceID("af_heart"),
            contentSignature: signature)
        let chapter = NarrationFileNaming.chapterFileName(
            audiobookID: "file:///b/",
            chapterIndex: 3,
            voice: VoiceID("af_heart"),
            contentSignature: signature)

        #expect(
            segment.contains(
                "-ch3-s2-h\(signature)-af_heart-v\(NarrationFileNaming.renderVersion).m4a"))
        #expect(
            chapter.contains(
                "-ch3-h\(signature)-af_heart-v\(NarrationFileNaming.renderVersion).m4a"))
        #expect(NarrationFileNaming.segmentLocation(fromFileName: segment)?.chapterIndex == 3)
        #expect(NarrationFileNaming.segmentLocation(fromFileName: segment)?.segmentIndex == 2)
        #expect(NarrationFileNaming.chapterIndex(fromFileName: chapter) == 3)
    }

    @Test func currentChapterCacheFileNameMatchesSignedLegacyAndPartialChapterFilesOnly() {
        let signed = NarrationFileNaming.chapterFileName(
            audiobookID: "book",
            chapterIndex: 3,
            voice: VoiceID("af_heart"),
            contentSignature: "0123456789abcdef")
        let legacy = NarrationFileNaming.chapterFileName(
            audiobookID: "book",
            chapterIndex: 3,
            voice: VoiceID("af_heart"))
        let segment = NarrationFileNaming.segmentFileName(
            audiobookID: "book",
            chapterIndex: 3,
            segmentIndex: 0,
            voice: VoiceID("af_heart"),
            contentSignature: "0123456789abcdef")

        #expect(
            NarrationFileNaming.isCurrentChapterCacheFileName(
                signed,
                audiobookID: "book",
                chapterIndex: 3,
                voice: VoiceID("af_heart")))
        #expect(
            NarrationFileNaming.isCurrentChapterCacheFileName(
                legacy,
                audiobookID: "book",
                chapterIndex: 3,
                voice: VoiceID("af_heart")))
        #expect(
            NarrationFileNaming.isCurrentChapterCacheFileName(
                "\(signed).partial",
                audiobookID: "book",
                chapterIndex: 3,
                voice: VoiceID("af_heart"),
                includingPartial: true))
        #expect(
            NarrationFileNaming.isCurrentChapterCacheFileName(
                ".book-ch3-h0123456789abcdef-af_heart-v\(NarrationFileNaming.renderVersion)"
                    + ".partial.m4a",
                audiobookID: "book",
                chapterIndex: 3,
                voice: VoiceID("af_heart"),
                includingPartial: true))
        #expect(
            !NarrationFileNaming.isCurrentChapterCacheFileName(
                "\(signed).partial",
                audiobookID: "book",
                chapterIndex: 3,
                voice: VoiceID("af_heart")))
        #expect(
            !NarrationFileNaming.isCurrentChapterCacheFileName(
                segment,
                audiobookID: "book",
                chapterIndex: 3,
                voice: VoiceID("af_heart")))
        #expect(
            !NarrationFileNaming.isCurrentChapterCacheFileName(
                signed,
                audiobookID: "book",
                chapterIndex: 30,
                voice: VoiceID("af_heart")))
    }

    @Test func segmentLocationRejectsNonSegmentNames() {
        #expect(NarrationFileNaming.segmentLocation(fromFileName: "nope.m4a") == nil)
        #expect(
            NarrationFileNaming.segmentLocation(
                fromFileName: "book_id-ch0-af_heart-v\(NarrationFileNaming.renderVersion).m4a")
                == nil)
    }

    private func block(id: String, kind: String = "paragraph", text: String) -> EPubBlockRecord {
        EPubBlockRecord(
            id: id,
            audiobookID: "book",
            spineHref: "chapter.xhtml",
            spineIndex: 0,
            blockIndex: 0,
            sequenceIndex: 0,
            blockKind: kind,
            text: text,
            htmlContent: nil,
            cardColor: nil,
            chapterThemeColor: nil,
            imagePath: nil,
            chapterIndex: 0,
            isHidden: false,
            hiddenReason: nil,
            isFrontMatter: false,
            wordCount: nil,
            markers: nil,
            textFormats: nil,
            createdAt: nil,
            modifiedAt: nil)
    }
}
