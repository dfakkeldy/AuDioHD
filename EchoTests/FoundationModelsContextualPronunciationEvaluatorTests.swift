// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

#if canImport(FoundationModels) && (os(iOS) || os(macOS))
    import FoundationModels
#endif

private enum ContextualEvaluatorFixtureError: Error {
    case unknown
}

private nonisolated enum ContextualEvaluatorFixtures {
    static let runtime = ContextualModelRuntime(
        platform: "test",
        osBuild: "test-build",
        qualifiedRuntimeFamilyID: "test-runtime")

    static let request = ContextualPronunciationBatchRequest(
        occurrences: [
            ContextualPronunciationOccurrence(
                occurrenceID: "occ-1",
                blockID: "/private/book-path/title-by-author-override-data",
                wordStart: 12,
                wordEnd: 16,
                targetWord: "read",
                precedingSentence: "Yesterday was different.",
                targetSentence: "I read this every morning.",
                followingSentence: "Tomorrow may be different.",
                familyID: "read",
                candidates: [
                    .init(
                        slot: .a,
                        candidateID: "read.present.private-candidate-id",
                        ipa: "ɹˈid",
                        senseLabel: "present/base",
                        lexicalRole: "verb"),
                    .init(
                        slot: .b,
                        candidateID: "read.past.private-candidate-id",
                        ipa: "ɹˈɛd",
                        senseLabel: "past/participle",
                        lexicalRole: "verb"),
                ],
                deterministicCandidateID: "read.present.private-candidate-id",
                deterministicRuleID: "ruleID-private-answer",
                deterministicStrength: .definitive),
            ContextualPronunciationOccurrence(
                occurrenceID: "occ-2",
                blockID: "block-private-metadata",
                wordStart: 4,
                wordEnd: 11,
                targetWord: "content",
                precedingSentence: nil,
                targetSentence: "The content is useful.",
                followingSentence: nil,
                familyID: "content",
                candidates: [
                    .init(
                        slot: .a,
                        candidateID: "content.material.private-candidate-id",
                        ipa: "kˈɑntɛnt",
                        senseLabel: "material/information",
                        lexicalRole: "noun"),
                    .init(
                        slot: .b,
                        candidateID: "content.satisfied.private-candidate-id",
                        ipa: "kəntˈɛnt",
                        senseLabel: "satisfied",
                        lexicalRole: "adjective"),
                ],
                deterministicCandidateID: nil,
                deterministicRuleID: nil,
                deterministicStrength: .abstained),
        ])
}

@Suite struct FoundationModelsContextualPronunciationEvaluatorTests {
    @Test func repeatedSpellingMarksEachExactOccurrence() throws {
        let occurrences = ContextualPronunciationDiscovery.discover(
            text: "We record the record.", blockID: "mixed")
        #expect(occurrences.count == 2)
        let prompts = occurrences.map {
            FoundationModelsContextualPronunciationEvaluator.prompt(for: .init(occurrences: [$0]))
        }
        #expect(prompts[0].contains("We <target>record</target> the record."))
        #expect(prompts[1].contains("We record the <target>record.</target>"))
    }

    @Test func promptContainsOnlyApprovedContextAndOpaqueChoices() {
        let prompt = FoundationModelsContextualPronunciationEvaluator.prompt(
            for: ContextualEvaluatorFixtures.request)

        #expect(prompt.contains("Occurrence: occ-1"))
        #expect(prompt.contains("Spelling: read"))
        #expect(prompt.contains("Previous sentence: Yesterday was different."))
        #expect(prompt.contains("Target sentence: I read this every morning."))
        #expect(prompt.contains("Next sentence: Tomorrow may be different."))
        #expect(prompt.contains("A: present/base verb"))
        #expect(prompt.contains("B: past/participle verb"))
        #expect(prompt.contains("Occurrence: occ-2"))
        #expect(prompt.contains("A: material/information noun"))
        #expect(prompt.contains("B: satisfied adjective"))

        for forbidden in [
            "ɹˈid",
            "ɹˈɛd",
            "kˈɑntɛnt",
            "kəntˈɛnt",
            "private-candidate-id",
            "deterministic",
            "ruleID",
            "definitive",
            "frequency",
            "override-data",
            "title-by-author",
            "/private/book-path",
            "block-private-metadata",
            "wordStart",
            "wordEnd",
            "familyID",
        ] {
            #expect(!prompt.contains(forbidden))
        }
    }

    @Test func promptUsesAtMostOneSentenceOnEachSide() {
        let prompt = FoundationModelsContextualPronunciationEvaluator.prompt(
            for: ContextualEvaluatorFixtures.request)

        #expect(prompt.components(separatedBy: "Previous sentence:").count == 2)
        #expect(prompt.components(separatedBy: "Target sentence:").count == 3)
        #expect(prompt.components(separatedBy: "Next sentence:").count == 2)
    }

    @Test func responseValidatorCanonicalizesSourceOrder() {
        let validated =
            FoundationModelsContextualPronunciationEvaluator.validatedSelections(
                [
                    .init(occurrenceID: "occ-2", slot: .a),
                    .init(occurrenceID: "occ-1", slot: .b),
                ],
                for: ContextualEvaluatorFixtures.request)

        #expect(
            validated
                == [
                    .init(occurrenceID: "occ-1", slot: .b),
                    .init(occurrenceID: "occ-2", slot: .a),
                ])
    }

    @Test(arguments: [
        [ContextualModelSelection(occurrenceID: "occ-1", slot: .a)],
        [
            ContextualModelSelection(occurrenceID: "occ-1", slot: .a),
            ContextualModelSelection(occurrenceID: "occ-1", slot: .b),
        ],
        [
            ContextualModelSelection(occurrenceID: "occ-1", slot: .a),
            ContextualModelSelection(occurrenceID: "unknown", slot: .b),
        ],
        [
            ContextualModelSelection(occurrenceID: "occ-1", slot: .c),
            ContextualModelSelection(occurrenceID: "occ-2", slot: .a),
        ],
    ])
    func responseValidatorRejectsMalformedOrInvalidBatches(
        _ selections: [ContextualModelSelection]
    ) {
        #expect(
            FoundationModelsContextualPronunciationEvaluator.validatedSelections(
                selections,
                for: ContextualEvaluatorFixtures.request) == nil)
    }

    @Test func responseValidatorAcceptsNeedsReviewWithoutAConfiguredCandidate() {
        let validated =
            FoundationModelsContextualPronunciationEvaluator.validatedSelections(
                [
                    .init(occurrenceID: "occ-1", slot: .needsReview),
                    .init(occurrenceID: "occ-2", slot: .b),
                ],
                for: ContextualEvaluatorFixtures.request)

        #expect(validated?.first?.slot == .needsReview)
    }

    @Test func responseValidatorAcceptsEveryFixedChoiceWhenSupplied() {
        let occurrence = ContextualPronunciationOccurrence(
            occurrenceID: "all-slots",
            blockID: "block",
            wordStart: 0,
            wordEnd: 4,
            targetWord: "test",
            precedingSentence: nil,
            targetSentence: "A synthetic test.",
            followingSentence: nil,
            familyID: "synthetic",
            candidates: [.a, .b, .c, .d].map { slot in
                .init(
                    slot: slot,
                    candidateID: "candidate-\(slot.rawValue)",
                    ipa: "test",
                    senseLabel: "meaning",
                    lexicalRole: "role")
            },
            deterministicCandidateID: nil,
            deterministicRuleID: nil,
            deterministicStrength: .abstained)
        let request = ContextualPronunciationBatchRequest(occurrences: [occurrence])

        let fixedChoices: [ContextualCandidateSlot] = [.a, .b, .c, .d, .needsReview]
        for slot in fixedChoices {
            let validated =
                FoundationModelsContextualPronunciationEvaluator.validatedSelections(
                    [.init(occurrenceID: occurrence.occurrenceID, slot: slot)],
                    for: request)
            #expect(validated?.first?.slot == slot)
        }
    }

    @Test func unsupportedOSFallbackIsStableAndDoesNotNeedFoundationModels() {
        let result = FoundationModelsContextualPronunciationEvaluator.unsupportedOSResult()

        #expect(result.availability == .unsupportedOS)
        #expect(result.selections.isEmpty)
        #expect(result.failure == nil)
        #expect(!result.runtime.platform.isEmpty)
        #expect(!result.runtime.osBuild.isEmpty)
        #expect(
            result.runtime.qualifiedRuntimeFamilyID
                == "foundation-models-system-v1")
    }

    @Test func deploymentFloorClosureReturnsUnsupportedWithoutFoundationModels() async throws {
        if #unavailable(iOS 26, macOS 26) {
            let result =
                try await FoundationModelsContextualPronunciationEvaluator
                .makeBatchEvaluator()(ContextualEvaluatorFixtures.request)

            #expect(result.availability == .unsupportedOS)
            #expect(result.selections.isEmpty)
            #expect(result.failure == nil)
        }
    }

    @Test func contextGuardBudgetsThreeCharactersPerContextToken() {
        #expect(
            FoundationModelsContextualPronunciationEvaluator.contextWindowFailure(
                promptCharacterCount: 12_288,
                contextSize: 4_096) == nil)
        #expect(
            FoundationModelsContextualPronunciationEvaluator.contextWindowFailure(
                promptCharacterCount: 12_289,
                contextSize: 4_096) == .contextTooLarge)
    }

    @Test func contextGuardAdmitsPromptsMeasuredToFitTheRealWindow() {
        // A 14,393-character prompt was answered successfully at batch size 8
        // against a 4,096-token window, so the guard must not reject prompts of
        // the size real batches actually reach (1,650-3,400 characters).
        #expect(
            FoundationModelsContextualPronunciationEvaluator.contextWindowFailure(
                promptCharacterCount: 3_400,
                contextSize: 4_096) == nil)
    }

    @Test func unknownContextWindowIsNotReportedAsAnOversizedPrompt() {
        #expect(
            FoundationModelsContextualPronunciationEvaluator.contextWindowFailure(
                promptCharacterCount: 1,
                contextSize: 0) == .contextWindowUnavailable)
        #expect(
            FoundationModelsContextualPronunciationEvaluator.contextWindowFailure(
                promptCharacterCount: 1,
                contextSize: -1) == .contextWindowUnavailable)
    }

    @Test func negativePromptLengthsAreRejectedWithoutClaimingAnOversizedPrompt() {
        #expect(
            FoundationModelsContextualPronunciationEvaluator.contextWindowFailure(
                promptCharacterCount: -1,
                contextSize: 4_096) == .unknown)
    }

    @Test func aNonPositiveContextReportFallsBackToTheLastKnownGoodWindow() {
        #expect(
            FoundationModelsContextualPronunciationEvaluator.resolvedContextSize(
                reported: 4_096,
                lastKnownGood: 0) == 4_096)
        #expect(
            FoundationModelsContextualPronunciationEvaluator.resolvedContextSize(
                reported: 0,
                lastKnownGood: 4_096) == 4_096)
        #expect(
            FoundationModelsContextualPronunciationEvaluator.resolvedContextSize(
                reported: 4_096,
                lastKnownGood: 8_192) == 4_096)
        #expect(
            FoundationModelsContextualPronunciationEvaluator.resolvedContextSize(
                reported: 0,
                lastKnownGood: 0) == 0)
    }

    @Test func theRememberedWindowSurvivesALaterZeroReport() {
        let seeded =
            FoundationModelsContextualPronunciationEvaluator
            .rememberedContextSize(reporting: 4_096)
        let afterPoisoning =
            FoundationModelsContextualPronunciationEvaluator
            .rememberedContextSize(reporting: 0)

        #expect(seeded == 4_096)
        #expect(afterPoisoning == 4_096)
    }

    @Test func runtimeProvenanceIsNonUserSpecific() {
        let runtime = FoundationModelsContextualPronunciationEvaluator.runtime

        #expect(!runtime.platform.isEmpty)
        #expect(runtime.osBuild == ProcessInfo.processInfo.operatingSystemVersionString)
        #expect(runtime.qualifiedRuntimeFamilyID == "foundation-models-system-v1")
        #expect(!runtime.platform.contains("/"))
        #expect(!runtime.osBuild.contains("/Users/"))
    }

    @Test func cancellationIsRethrownBeforeErrorClassification() {
        #expect(throws: CancellationError.self) {
            _ = try FoundationModelsContextualPronunciationEvaluator.modelFailure(
                for: CancellationError())
        }
    }

    @Test func unknownErrorsMapToUnknown() throws {
        let failure = try FoundationModelsContextualPronunciationEvaluator.modelFailure(
            for: ContextualEvaluatorFixtureError.unknown)

        #expect(failure == .unknown)
    }

    #if canImport(FoundationModels) && (os(iOS) || os(macOS))
        @Test func availabilityMappingCoversEveryDocumentedState() {
            if #available(iOS 26, macOS 26, *) {
                #expect(
                    FoundationModelsContextualPronunciationEvaluator.modelAvailability(
                        for: .available) == .available)
                #expect(
                    FoundationModelsContextualPronunciationEvaluator.modelAvailability(
                        for: .unavailable(.deviceNotEligible)) == .deviceNotEligible)
                #expect(
                    FoundationModelsContextualPronunciationEvaluator.modelAvailability(
                        for: .unavailable(.appleIntelligenceNotEnabled))
                        == .appleIntelligenceNotEnabled)
                #expect(
                    FoundationModelsContextualPronunciationEvaluator.modelAvailability(
                        for: .unavailable(.modelNotReady)) == .modelNotReady)
            }
        }

        @Test func generationErrorMappingCoversEveryDocumentedStableCategory() throws {
            if #available(iOS 26, macOS 26, *) {
                let context = LanguageModelSession.GenerationError.Context(
                    debugDescription: "synthetic")
                let cases: [(LanguageModelSession.GenerationError, ContextualModelFailure)] = [
                    (.exceededContextWindowSize(context), .contextTooLarge),
                    (.assetsUnavailable(context), .assetsUnavailable),
                    (.guardrailViolation(context), .guardrail),
                    (.unsupportedLanguageOrLocale(context), .unsupportedLanguageOrLocale),
                    (.decodingFailure(context), .parsing),
                    (.rateLimited(context), .rateLimited),
                    (.concurrentRequests(context), .concurrentRequest),
                    (
                        .refusal(.init(transcriptEntries: []), context),
                        .refusal
                    ),
                    (.unsupportedGuide(context), .unknown),
                ]

                for (error, expected) in cases {
                    #expect(
                        try FoundationModelsContextualPronunciationEvaluator.modelFailure(
                            for: error) == expected)
                }
            }
        }
    #endif
}
