// SPDX-License-Identifier: GPL-3.0-or-later
import Testing

@testable import Echo

private enum PreflightFixtureError: Error {
    case failed
}

private enum InvalidSelectionShape: Sendable {
    case missing
    case duplicate
    case invalidSlot
}

private actor PreflightCallRecorder {
    private(set) var batchIDs: [[String]] = []

    func record(_ request: ContextualPronunciationBatchRequest) -> Int {
        batchIDs.append(request.occurrences.map(\.occurrenceID))
        return batchIDs.count
    }

    func batchCounts() -> [Int] {
        batchIDs.map(\.count)
    }
}

/// Reproduces the measured Foundation Models fault: one transient generation
/// error, after which `SystemLanguageModel.contextSize` reports 0 for the rest
/// of the process. The probe routes through the production guard helpers so the
/// test exercises the real recovery path rather than a restatement of it.
private actor PoisonedContextWindowProbe {
    private let reportedContextSizes: [Int]
    private var callCount = 0
    private var lastKnownGood = 0

    init(reportedContextSizes: [Int]) {
        self.reportedContextSizes = reportedContextSizes
    }

    func evaluate(
        _ request: ContextualPronunciationBatchRequest
    ) -> ContextualPronunciationBatchResult {
        let reported = reportedContextSizes[
            min(callCount, reportedContextSizes.count - 1)]
        callCount += 1

        let contextSize =
            FoundationModelsContextualPronunciationEvaluator
            .resolvedContextSize(reported: reported, lastKnownGood: lastKnownGood)
        if contextSize > 0 {
            lastKnownGood = contextSize
        }

        if let failure =
            FoundationModelsContextualPronunciationEvaluator
            .contextWindowFailure(
                promptCharacterCount: 1_651,
                contextSize: contextSize)
        {
            return PreflightFixtures.failure(failure)
        }

        // The first live call is the transient generation error that poisons
        // the window; it surfaces as `.unknown` because the underlying
        // `LanguageModelError -1` does not cast to a documented case.
        if callCount == 1 {
            return PreflightFixtures.failure(.unknown)
        }
        return PreflightFixtures.success(for: request)
    }
}

private actor SerialPreflightProbe {
    private var activeCalls = 0
    private(set) var maximumActiveCalls = 0
    private(set) var batchIDs: [[String]] = []

    func begin(_ request: ContextualPronunciationBatchRequest) {
        activeCalls += 1
        maximumActiveCalls = max(maximumActiveCalls, activeCalls)
        batchIDs.append(request.occurrences.map(\.occurrenceID))
    }

    func end() {
        activeCalls -= 1
    }

    func snapshot() -> (maximumActiveCalls: Int, batchIDs: [[String]]) {
        (maximumActiveCalls, batchIDs)
    }
}

private nonisolated enum PreflightFixtures {
    static let runtime = ContextualModelRuntime(
        platform: "test",
        osBuild: "test-build",
        qualifiedRuntimeFamilyID: "test-runtime")

    static func occurrences(
        count: Int,
        targetSentence: String = "I read it."
    ) -> [ContextualPronunciationOccurrence] {
        (0..<count).map { index in
            ContextualPronunciationOccurrence(
                occurrenceID: "occurrence-\(index)",
                blockID: "block-\(index)",
                wordStart: 0,
                wordEnd: 4,
                targetWord: "read",
                precedingSentence: "Before.",
                targetSentence: targetSentence,
                followingSentence: "After.",
                familyID: "read",
                candidates: [
                    .init(
                        slot: .a,
                        candidateID: "read-present",
                        ipa: "ɹiːd",
                        senseLabel: "present tense",
                        lexicalRole: "verb"),
                    .init(
                        slot: .b,
                        candidateID: "read-past",
                        ipa: "ɹɛd",
                        senseLabel: "past tense",
                        lexicalRole: "verb"),
                ],
                deterministicCandidateID: nil,
                deterministicRuleID: nil,
                deterministicStrength: .abstained)
        }
    }

    static func success(
        for request: ContextualPronunciationBatchRequest,
        slot: ContextualCandidateSlot = .a,
        runtime: ContextualModelRuntime = runtime
    ) -> ContextualPronunciationBatchResult {
        ContextualPronunciationBatchResult(
            availability: .available,
            selections: request.occurrences.map {
                .init(occurrenceID: $0.occurrenceID, slot: slot)
            },
            failure: nil,
            runtime: runtime)
    }

    static func failure(
        _ failure: ContextualModelFailure,
        runtime: ContextualModelRuntime = runtime
    ) -> ContextualPronunciationBatchResult {
        ContextualPronunciationBatchResult(
            availability: .available,
            selections: [],
            failure: failure,
            runtime: runtime)
    }
}

@Suite struct ContextualPronunciationPreflightTests {
    @Test func countBatchesPreserveOrderAndInvokeEvaluatorSerially() async throws {
        let occurrences = PreflightFixtures.occurrences(count: 17)
        let probe = SerialPreflightProbe()
        let evaluator: ContextualPronunciationBatchEvaluator = { request in
            await probe.begin(request)
            await Task.yield()
            await probe.end()
            return PreflightFixtures.success(for: request)
        }

        let evidence = try await ContextualPronunciationPreflight.run(
            occurrences: occurrences,
            evaluator: evaluator,
            environment: PreflightFixtures.runtime)
        let snapshot = await probe.snapshot()

        #expect(snapshot.maximumActiveCalls == 1)
        #expect(snapshot.batchIDs.map(\.count) == [8, 8, 1])
        #expect(snapshot.batchIDs.flatMap { $0 } == occurrences.map(\.occurrenceID))
        #expect(evidence.map(\.occurrenceID) == occurrences.map(\.occurrenceID))
    }

    @Test func characterBudgetSplitsBeforeCombinedPromptExceedsLimit() async throws {
        let occurrences = PreflightFixtures.occurrences(count: 3)
        let recorder = PreflightCallRecorder()
        let evaluator: ContextualPronunciationBatchEvaluator = { request in
            _ = await recorder.record(request)
            return PreflightFixtures.success(for: request)
        }

        let evidence = try await ContextualPronunciationPreflight.run(
            occurrences: occurrences,
            evaluator: evaluator,
            environment: PreflightFixtures.runtime,
            configuration: .init(
                maximumBatchCount: 8,
                maximumPromptCharacters: 350))

        #expect(await recorder.batchCounts() == [1, 1, 1])
        #expect(evidence.count == 3)
    }

    @Test func characterBudgetKeepsOversizedOccurrencesAsSingleBatches() async throws {
        let occurrences = PreflightFixtures.occurrences(
            count: 2,
            targetSentence: String(repeating: "context ", count: 30))
        let recorder = PreflightCallRecorder()
        let evaluator: ContextualPronunciationBatchEvaluator = { request in
            _ = await recorder.record(request)
            return PreflightFixtures.success(for: request)
        }

        let evidence = try await ContextualPronunciationPreflight.run(
            occurrences: occurrences,
            evaluator: evaluator,
            environment: PreflightFixtures.runtime,
            configuration: .init(
                maximumBatchCount: 8,
                maximumPromptCharacters: 100))

        #expect(await recorder.batchCounts() == [1, 1])
        #expect(evidence.count == 2)
    }

    @Test func validSelectionsAndAbstentionsProduceAuditReadyShadowEvidence() async throws {
        let runtime = ContextualModelRuntime(
            platform: "iOS",
            osBuild: "26A1",
            qualifiedRuntimeFamilyID: "fm-test")
        let evaluator: ContextualPronunciationBatchEvaluator = { request in
            ContextualPronunciationBatchResult(
                availability: .available,
                selections: [
                    .init(occurrenceID: request.occurrences[0].occurrenceID, slot: .b),
                    .init(
                        occurrenceID: request.occurrences[1].occurrenceID,
                        slot: .needsReview),
                ],
                failure: nil,
                runtime: runtime)
        }

        let evidence = try await ContextualPronunciationPreflight.run(
            occurrences: PreflightFixtures.occurrences(count: 2),
            evaluator: evaluator,
            environment: PreflightFixtures.runtime)

        #expect(evidence[0].modelCandidateID == "read-past")
        #expect(evidence[0].modelAbstained == false)
        #expect(evidence[0].acceptanceReason == .shadowObserved)
        #expect(evidence[1].modelCandidateID == nil)
        #expect(evidence[1].modelAbstained)
        #expect(evidence[1].acceptanceReason == .shadowNeedsReview)
        #expect(
            evidence.allSatisfy { evidence in
                evidence.candidatePackVersion == "context-candidates-v1"
                    && evidence.promptSchemaVersion == "context-shadow-v2"
                    && evidence.submittedCandidateIDs == ["read-present", "read-past"]
                    && evidence.familyState == .shadow
                    && evidence.platform == "iOS"
                    && evidence.osBuild == "26A1"
                    && evidence.qualifiedRuntimeFamilyID == "fm-test"
                    && evidence.humanCandidateID == nil
                    && evidence.humanCorrectionScope == nil
                    && evidence.isLimited == false
            })
    }

    @Test func invalidBatchRejectsEverySelectionAtomically() async throws {
        let occurrences = PreflightFixtures.occurrences(count: 2)
        let evaluator: ContextualPronunciationBatchEvaluator = { request in
            ContextualPronunciationBatchResult(
                availability: .available,
                selections: [
                    .init(occurrenceID: request.occurrences[0].occurrenceID, slot: .a),
                    .init(occurrenceID: "unknown", slot: .b),
                ],
                failure: nil,
                runtime: PreflightFixtures.runtime)
        }

        let evidence = try await ContextualPronunciationPreflight.run(
            occurrences: occurrences,
            evaluator: evaluator,
            environment: PreflightFixtures.runtime)

        #expect(evidence.count == 2)
        #expect(evidence.allSatisfy { $0.modelCandidateID == nil })
        #expect(evidence.allSatisfy { $0.modelFailure == .invalidBatch })
    }

    @Test func duplicateSubmittedOccurrenceIDsFailClosedBeforeEvaluation() async throws {
        let fixtures = PreflightFixtures.occurrences(count: 9)
        let first = fixtures[0]
        let duplicate = ContextualPronunciationOccurrence(
            occurrenceID: first.occurrenceID,
            blockID: "second-block",
            wordStart: 5,
            wordEnd: 9,
            targetWord: first.targetWord,
            precedingSentence: first.precedingSentence,
            targetSentence: first.targetSentence,
            followingSentence: first.followingSentence,
            familyID: "second-family",
            candidates: first.candidates,
            deterministicCandidateID: "second-deterministic-candidate",
            deterministicRuleID: "second-deterministic-rule",
            deterministicStrength: .definitive)
        let occurrences = Array(fixtures.dropLast()) + [duplicate]
        let recorder = PreflightCallRecorder()
        let evaluator: ContextualPronunciationBatchEvaluator = { request in
            _ = await recorder.record(request)
            return PreflightFixtures.success(for: request)
        }

        let evidence = try await ContextualPronunciationPreflight.run(
            occurrences: occurrences,
            evaluator: evaluator,
            environment: PreflightFixtures.runtime)

        #expect(await recorder.batchCounts().isEmpty)
        #expect(evidence.count == 9)
        #expect(
            evidence.map(\.occurrenceID) == [
                "occurrence-0",
                "occurrence-1",
                "occurrence-2",
                "occurrence-3",
                "occurrence-4",
                "occurrence-5",
                "occurrence-6",
                "occurrence-7",
                "occurrence-0",
            ])
        #expect(
            evidence.map(\.familyID) == [
                "read", "read", "read", "read", "read", "read", "read", "read",
                "second-family",
            ])
        #expect(
            evidence.allSatisfy {
                $0.modelCandidateID == nil
                    && $0.modelFailure == .invalidBatch
                    && $0.modelAvailability == .available
                    && $0.acceptanceReason == .shadowModelFailure
                    && $0.platform == "test"
                    && $0.osBuild == "test-build"
                    && $0.qualifiedRuntimeFamilyID == "test-runtime"
            })
    }

    @Test func missingDuplicateAndInvalidSlotSelectionsRejectWholeBatches() async throws {
        let occurrences = PreflightFixtures.occurrences(count: 2)
        for shape in [
            InvalidSelectionShape.missing,
            .duplicate,
            .invalidSlot,
        ] {
            let evaluator: ContextualPronunciationBatchEvaluator = { request in
                let selections: [ContextualModelSelection]
                switch shape {
                case .missing:
                    selections = []
                case .duplicate:
                    selections = [
                        .init(
                            occurrenceID: request.occurrences[0].occurrenceID,
                            slot: .a),
                        .init(
                            occurrenceID: request.occurrences[0].occurrenceID,
                            slot: .b),
                    ]
                case .invalidSlot:
                    selections = request.occurrences.map {
                        .init(occurrenceID: $0.occurrenceID, slot: .c)
                    }
                }
                return ContextualPronunciationBatchResult(
                    availability: .available,
                    selections: selections,
                    failure: nil,
                    runtime: PreflightFixtures.runtime)
            }
            let evidence = try await ContextualPronunciationPreflight.run(
                occurrences: occurrences,
                evaluator: evaluator,
                environment: PreflightFixtures.runtime)

            #expect(
                evidence.allSatisfy {
                    $0.modelCandidateID == nil && $0.modelFailure == .invalidBatch
                })
        }
    }

    @Test func invalidBatchRetriesOnceSmallerAndCanRecover() async throws {
        let occurrences = PreflightFixtures.occurrences(count: 4)
        let recorder = PreflightCallRecorder()
        let evaluator: ContextualPronunciationBatchEvaluator = { request in
            let call = await recorder.record(request)
            if call == 1 {
                return ContextualPronunciationBatchResult(
                    availability: .available,
                    selections: [],
                    failure: nil,
                    runtime: PreflightFixtures.runtime)
            }
            return PreflightFixtures.success(for: request)
        }

        let evidence = try await ContextualPronunciationPreflight.run(
            occurrences: occurrences,
            evaluator: evaluator,
            environment: PreflightFixtures.runtime)

        #expect(await recorder.batchCounts() == [4, 2, 2])
        #expect(evidence.allSatisfy { $0.modelCandidateID == "read-present" })
    }

    @Test func inconsistentAvailabilityAndFailureIsAnInvalidBatch() async throws {
        let evaluator: ContextualPronunciationBatchEvaluator = { _ in
            ContextualPronunciationBatchResult(
                availability: .deviceNotEligible,
                selections: [],
                failure: .timeout,
                runtime: PreflightFixtures.runtime)
        }

        let evidence = try await ContextualPronunciationPreflight.run(
            occurrences: PreflightFixtures.occurrences(count: 1),
            evaluator: evaluator,
            environment: PreflightFixtures.runtime)

        #expect(evidence.single?.modelFailure == .invalidBatch)
        #expect(evidence.single?.modelCandidateID == nil)
    }

    @Test func invalidSingleEvidencePreservesEvaluatorRuntime() async throws {
        let evaluatedRuntime = ContextualModelRuntime(
            platform: "evaluated-platform",
            osBuild: "evaluated-build",
            qualifiedRuntimeFamilyID: "evaluated-runtime")
        let evaluator: ContextualPronunciationBatchEvaluator = { _ in
            ContextualPronunciationBatchResult(
                availability: .available,
                selections: [],
                failure: nil,
                runtime: evaluatedRuntime)
        }

        let evidence = try await ContextualPronunciationPreflight.run(
            occurrences: PreflightFixtures.occurrences(count: 1),
            evaluator: evaluator,
            environment: PreflightFixtures.runtime)

        #expect(evidence.single?.modelFailure == .invalidBatch)
        #expect(evidence.single?.platform == "evaluated-platform")
        #expect(evidence.single?.osBuild == "evaluated-build")
        #expect(evidence.single?.qualifiedRuntimeFamilyID == "evaluated-runtime")
    }

    @Test func contextTooLargeHalvesSeriallyDownToSuccessfulSingles() async throws {
        let recorder = PreflightCallRecorder()
        let evaluator: ContextualPronunciationBatchEvaluator = { request in
            _ = await recorder.record(request)
            if request.occurrences.count > 1 {
                return PreflightFixtures.failure(.contextTooLarge)
            }
            return PreflightFixtures.success(for: request)
        }

        let evidence = try await ContextualPronunciationPreflight.run(
            occurrences: PreflightFixtures.occurrences(count: 4),
            evaluator: evaluator,
            environment: PreflightFixtures.runtime)

        #expect(await recorder.batchCounts() == [4, 2, 1, 1, 2, 1, 1])
        #expect(evidence.allSatisfy { $0.modelCandidateID == "read-present" })
    }

    @Test func aTransientFirstBatchFailureLeavesLaterBatchesEvaluable() async throws {
        // Call 1 sees a healthy window and hits the transient generation error;
        // every later call sees the poisoned 0 report the fault leaves behind.
        let probe = PoisonedContextWindowProbe(reportedContextSizes: [4_096, 0])
        let evaluator: ContextualPronunciationBatchEvaluator = { request in
            await probe.evaluate(request)
        }

        let evidence = try await ContextualPronunciationPreflight.run(
            occurrences: PreflightFixtures.occurrences(count: 16),
            evaluator: evaluator,
            environment: PreflightFixtures.runtime)

        let secondBatch = evidence.suffix(8)
        #expect(secondBatch.allSatisfy { $0.modelCandidateID == "read-present" })
        #expect(secondBatch.allSatisfy { $0.acceptanceReason == .shadowObserved })
        #expect(secondBatch.allSatisfy { $0.modelFailure == nil })
    }

    @Test func aPoisonedWindowIsNeverReportedAsAnOversizedPrompt() async throws {
        let probe = PoisonedContextWindowProbe(reportedContextSizes: [0])
        let evaluator: ContextualPronunciationBatchEvaluator = { request in
            await probe.evaluate(request)
        }

        let evidence = try await ContextualPronunciationPreflight.run(
            occurrences: PreflightFixtures.occurrences(count: 2),
            evaluator: evaluator,
            environment: PreflightFixtures.runtime)

        #expect(evidence.allSatisfy { $0.modelFailure == .contextWindowUnavailable })
        #expect(evidence.allSatisfy { $0.modelFailure != .contextTooLarge })
    }

    @Test func aPoisonedRetryDoesNotOverwriteTheOriginalFailureReason() async throws {
        let recorder = PreflightCallRecorder()
        let evaluator: ContextualPronunciationBatchEvaluator = { request in
            let call = await recorder.record(request)
            if call == 1 {
                return PreflightFixtures.failure(.unknown)
            }
            return PreflightFixtures.failure(.contextWindowUnavailable)
        }

        let evidence = try await ContextualPronunciationPreflight.run(
            occurrences: PreflightFixtures.occurrences(count: 4),
            evaluator: evaluator,
            environment: PreflightFixtures.runtime)

        #expect(await recorder.batchCounts() == [4, 2, 2])
        #expect(evidence.allSatisfy { $0.modelFailure == .unknown })
    }

    @Test func anUnavailableWindowEarnsOneFreshRetryWithoutHalving() async throws {
        let recorder = PreflightCallRecorder()
        let evaluator: ContextualPronunciationBatchEvaluator = { request in
            let call = await recorder.record(request)
            if call == 1 {
                return PreflightFixtures.failure(.contextWindowUnavailable)
            }
            return PreflightFixtures.success(for: request)
        }

        let evidence = try await ContextualPronunciationPreflight.run(
            occurrences: PreflightFixtures.occurrences(count: 2),
            evaluator: evaluator,
            environment: PreflightFixtures.runtime)

        #expect(await recorder.batchCounts() == [2, 2])
        #expect(evidence.allSatisfy { $0.modelCandidateID == "read-present" })
    }

    @Test func contextTooLargeAtOneOccurrenceEmitsFailureEvidence() async throws {
        let recorder = PreflightCallRecorder()
        let evaluator: ContextualPronunciationBatchEvaluator = { request in
            _ = await recorder.record(request)
            return PreflightFixtures.failure(.contextTooLarge)
        }

        let evidence = try await ContextualPronunciationPreflight.run(
            occurrences: PreflightFixtures.occurrences(count: 1),
            evaluator: evaluator,
            environment: PreflightFixtures.runtime)

        #expect(await recorder.batchCounts() == [1])
        #expect(evidence.single?.modelFailure == .contextTooLarge)
    }

    @Test func transientFailuresReceiveOneFreshRetry() async throws {
        for failure in [
            ContextualModelFailure.timeout,
            .rateLimited,
            .assetsUnavailable,
        ] {
            let recorder = PreflightCallRecorder()
            let evaluator: ContextualPronunciationBatchEvaluator = { request in
                let call = await recorder.record(request)
                if call == 1 {
                    return PreflightFixtures.failure(failure)
                }
                return PreflightFixtures.success(for: request)
            }

            let evidence = try await ContextualPronunciationPreflight.run(
                occurrences: PreflightFixtures.occurrences(count: 2),
                evaluator: evaluator,
                environment: PreflightFixtures.runtime)

            #expect(await recorder.batchCounts() == [2, 2])
            #expect(evidence.allSatisfy { $0.modelCandidateID == "read-present" })
        }
    }

    @Test func repeatedTransientFailureStopsAfterOneRetry() async throws {
        let recorder = PreflightCallRecorder()
        let evaluator: ContextualPronunciationBatchEvaluator = { request in
            _ = await recorder.record(request)
            return PreflightFixtures.failure(.timeout)
        }

        let evidence = try await ContextualPronunciationPreflight.run(
            occurrences: PreflightFixtures.occurrences(count: 2),
            evaluator: evaluator,
            environment: PreflightFixtures.runtime)

        #expect(await recorder.batchCounts() == [2, 2])
        #expect(evidence.allSatisfy { $0.modelFailure == .timeout })
    }

    @Test func guardrailRefusalAndUnsupportedLocaleNeverRetry() async throws {
        for failure in [
            ContextualModelFailure.guardrail,
            .refusal,
            .unsupportedLanguageOrLocale,
        ] {
            let recorder = PreflightCallRecorder()
            let evaluator: ContextualPronunciationBatchEvaluator = { request in
                _ = await recorder.record(request)
                return PreflightFixtures.failure(failure)
            }

            let evidence = try await ContextualPronunciationPreflight.run(
                occurrences: PreflightFixtures.occurrences(count: 2),
                evaluator: evaluator,
                environment: PreflightFixtures.runtime)

            #expect(await recorder.batchCounts() == [2])
            #expect(evidence.allSatisfy { $0.modelFailure == failure })
        }
    }

    @Test func unavailableModelsEmitUnavailableEvidenceWithoutRetry() async throws {
        for availability in [
            ContextualModelAvailability.unsupportedOS,
            .deviceNotEligible,
            .appleIntelligenceNotEnabled,
            .modelNotReady,
            .unknown,
        ] {
            let recorder = PreflightCallRecorder()
            let evaluator: ContextualPronunciationBatchEvaluator = { request in
                _ = await recorder.record(request)
                return ContextualPronunciationBatchResult(
                    availability: availability,
                    selections: [],
                    failure: nil,
                    runtime: PreflightFixtures.runtime)
            }

            let evidence = try await ContextualPronunciationPreflight.run(
                occurrences: PreflightFixtures.occurrences(count: 2),
                evaluator: evaluator,
                environment: PreflightFixtures.runtime)

            #expect(await recorder.batchCounts() == [2])
            #expect(
                evidence.allSatisfy {
                    $0.modelAvailability == availability
                        && $0.modelFailure == nil
                        && $0.acceptanceReason == .shadowModelUnavailable
                })
        }
    }

    @Test func concurrentRequestGetsExactlyOneSmallerSerialRetryThenFailure() async throws {
        let recorder = PreflightCallRecorder()
        let evaluator: ContextualPronunciationBatchEvaluator = { request in
            _ = await recorder.record(request)
            return PreflightFixtures.failure(.concurrentRequest)
        }

        let evidence = try await ContextualPronunciationPreflight.run(
            occurrences: PreflightFixtures.occurrences(count: 4),
            evaluator: evaluator,
            environment: PreflightFixtures.runtime)

        #expect(await recorder.batchCounts() == [4, 2, 2])
        #expect(evidence.allSatisfy { $0.modelFailure == .concurrentRequest })
    }

    @Test func parsingAndUnknownGetOneSmallerRetryThenFailure() async throws {
        for failure in [
            ContextualModelFailure.parsing,
            .unknown,
        ] {
            let recorder = PreflightCallRecorder()
            let evaluator: ContextualPronunciationBatchEvaluator = { request in
                _ = await recorder.record(request)
                return PreflightFixtures.failure(failure)
            }

            let evidence = try await ContextualPronunciationPreflight.run(
                occurrences: PreflightFixtures.occurrences(count: 4),
                evaluator: evaluator,
                environment: PreflightFixtures.runtime)

            #expect(await recorder.batchCounts() == [4, 2, 2])
            #expect(evidence.allSatisfy { $0.modelFailure == failure })
        }
    }

    @Test func thrownNonCancellationErrorUsesBoundedUnknownFallback() async throws {
        let recorder = PreflightCallRecorder()
        let evaluator: ContextualPronunciationBatchEvaluator = { request in
            _ = await recorder.record(request)
            throw PreflightFixtureError.failed
        }

        let evidence = try await ContextualPronunciationPreflight.run(
            occurrences: PreflightFixtures.occurrences(count: 2),
            evaluator: evaluator,
            environment: PreflightFixtures.runtime)

        #expect(await recorder.batchCounts() == [2, 1, 1])
        #expect(
            evidence.allSatisfy {
                $0.modelFailure == .unknown
                    && $0.platform == PreflightFixtures.runtime.platform
            })
    }

    @Test func cancellationNeverBecomesFallbackEvidence() async {
        let evaluator: ContextualPronunciationBatchEvaluator = { _ in
            throw CancellationError()
        }

        await #expect(throws: CancellationError.self) {
            try await ContextualPronunciationPreflight.run(
                occurrences: PreflightFixtures.occurrences(count: 1),
                evaluator: evaluator,
                environment: PreflightFixtures.runtime)
        }
    }

    @Test func cancellationAfterEvaluationPreventsThePendingRetry() async {
        let recorder = PreflightCallRecorder()
        let evaluator: ContextualPronunciationBatchEvaluator = { request in
            _ = await recorder.record(request)
            withUnsafeCurrentTask { task in
                task?.cancel()
            }
            return PreflightFixtures.failure(.timeout)
        }
        let operation = Task {
            try await ContextualPronunciationPreflight.run(
                occurrences: PreflightFixtures.occurrences(count: 1),
                evaluator: evaluator,
                environment: PreflightFixtures.runtime)
        }

        await #expect(throws: CancellationError.self) {
            try await operation.value
        }
        #expect(await recorder.batchCounts() == [1])
    }

    @Test func cancelledResultNeverBecomesFallbackEvidence() async {
        let evaluator: ContextualPronunciationBatchEvaluator = { _ in
            PreflightFixtures.failure(.cancelled)
        }

        await #expect(throws: CancellationError.self) {
            try await ContextualPronunciationPreflight.run(
                occurrences: PreflightFixtures.occurrences(count: 1),
                evaluator: evaluator,
                environment: PreflightFixtures.runtime)
        }
    }

    @Test func emptyInputDoesNotInvokeEvaluator() async throws {
        let recorder = PreflightCallRecorder()
        let evaluator: ContextualPronunciationBatchEvaluator = { request in
            _ = await recorder.record(request)
            return PreflightFixtures.success(for: request)
        }

        let evidence = try await ContextualPronunciationPreflight.run(
            occurrences: [],
            evaluator: evaluator,
            environment: PreflightFixtures.runtime)

        #expect(evidence.isEmpty)
        #expect(await recorder.batchCounts().isEmpty)
    }
}

extension Collection {
    fileprivate var single: Element? {
        count == 1 ? first : nil
    }
}
