// SPDX-License-Identifier: GPL-3.0-or-later

nonisolated enum ContextualPronunciationPreflight {
    static func run(
        occurrences: [ContextualPronunciationOccurrence],
        evaluator: ContextualPronunciationBatchEvaluator,
        environment: ContextualModelRuntime,
        configuration: ContextualPronunciationPreflightConfiguration = .phaseTwo
    ) async throws -> [ContextualPronunciationEvidence] {
        guard occurrenceIDsAreUnique(occurrences) else {
            try Task.checkCancellation()
            return makeFailureEvidence(
                for: occurrences,
                failure: .invalidBatch,
                runtime: environment)
        }

        var evidence: [ContextualPronunciationEvidence] = []
        for batch in plannedBatches(occurrences, configuration: configuration) {
            try Task.checkCancellation()
            let batchEvidence = try await process(
                batch,
                evaluator: evaluator,
                environment: environment)
            evidence.append(contentsOf: batchEvidence)
        }
        return evidence
    }

    private static func process(
        _ occurrences: [ContextualPronunciationOccurrence],
        evaluator: ContextualPronunciationBatchEvaluator,
        environment: ContextualModelRuntime
    ) async throws -> [ContextualPronunciationEvidence] {
        let result = try await evaluate(
            occurrences,
            evaluator: evaluator,
            environment: environment)

        if result.failure == .cancelled {
            throw CancellationError()
        }

        guard isInternallyConsistent(result) else {
            return try await retrySmallerOnce(
                occurrences,
                evaluator: evaluator,
                environment: environment,
                terminalFailure: .invalidBatch,
                terminalRuntime: result.runtime)
        }

        guard result.availability == .available else {
            return makeEvidence(
                for: occurrences,
                result: result,
                validatedSelections: nil)
        }

        if let failure = result.failure {
            switch failure {
            case .contextTooLarge:
                guard occurrences.count > 1 else {
                    return makeEvidence(
                        for: occurrences,
                        result: result,
                        validatedSelections: nil)
                }
                return try await processSmallerBatches(
                    occurrences,
                    evaluator: evaluator,
                    environment: environment,
                    finalAttempt: false,
                    terminalFailure: failure)

            // A missing context window is transient, not a size problem, so it
            // earns a fresh attempt at the same batch size rather than the
            // pointless halving that an oversized prompt would deserve.
            case .timeout, .rateLimited, .assetsUnavailable,
                .contextWindowUnavailable:
                try Task.checkCancellation()
                return try await processFinalAttempt(
                    occurrences,
                    evaluator: evaluator,
                    environment: environment)

            case .concurrentRequest, .parsing, .unknown:
                return try await retrySmallerOnce(
                    occurrences,
                    evaluator: evaluator,
                    environment: environment,
                    terminalFailure: failure,
                    terminalRuntime: result.runtime)

            case .guardrail, .refusal, .unsupportedLanguageOrLocale,
                .invalidBatch:
                return makeEvidence(
                    for: occurrences,
                    result: result,
                    validatedSelections: nil)

            case .cancelled:
                throw CancellationError()
            }
        }

        guard let selections = validatedSelections(result, for: occurrences) else {
            return try await retrySmallerOnce(
                occurrences,
                evaluator: evaluator,
                environment: environment,
                terminalFailure: .invalidBatch,
                terminalRuntime: result.runtime)
        }

        return makeEvidence(
            for: occurrences,
            result: result,
            validatedSelections: selections)
    }

    private static func retrySmallerOnce(
        _ occurrences: [ContextualPronunciationOccurrence],
        evaluator: ContextualPronunciationBatchEvaluator,
        environment: ContextualModelRuntime,
        terminalFailure: ContextualModelFailure,
        terminalRuntime: ContextualModelRuntime
    ) async throws -> [ContextualPronunciationEvidence] {
        guard occurrences.count > 1 else {
            return makeFailureEvidence(
                for: occurrences,
                failure: terminalFailure,
                runtime: terminalRuntime)
        }

        return try await processSmallerBatches(
            occurrences,
            evaluator: evaluator,
            environment: environment,
            finalAttempt: true,
            terminalFailure: terminalFailure)
    }

    private static func processSmallerBatches(
        _ occurrences: [ContextualPronunciationOccurrence],
        evaluator: ContextualPronunciationBatchEvaluator,
        environment: ContextualModelRuntime,
        finalAttempt: Bool,
        terminalFailure: ContextualModelFailure
    ) async throws -> [ContextualPronunciationEvidence] {
        var evidence: [ContextualPronunciationEvidence] = []
        for batch in halfSizeBatches(occurrences) {
            try Task.checkCancellation()
            let batchEvidence: [ContextualPronunciationEvidence]
            if finalAttempt {
                batchEvidence = try await processFinalAttempt(
                    batch,
                    evaluator: evaluator,
                    environment: environment,
                    terminalFailure: terminalFailure)
            } else {
                batchEvidence = try await process(
                    batch,
                    evaluator: evaluator,
                    environment: environment)
            }
            evidence.append(contentsOf: batchEvidence)
        }
        return evidence
    }

    private static func processFinalAttempt(
        _ occurrences: [ContextualPronunciationOccurrence],
        evaluator: ContextualPronunciationBatchEvaluator,
        environment: ContextualModelRuntime,
        terminalFailure: ContextualModelFailure? = nil
    ) async throws -> [ContextualPronunciationEvidence] {
        let result = try await evaluate(
            occurrences,
            evaluator: evaluator,
            environment: environment)

        if result.failure == .cancelled {
            throw CancellationError()
        }

        guard isInternallyConsistent(result) else {
            return makeFailureEvidence(
                for: occurrences,
                failure: terminalFailure ?? .invalidBatch,
                runtime: result.runtime)
        }

        guard result.availability == .available else {
            return makeEvidence(
                for: occurrences,
                result: result,
                validatedSelections: nil)
        }

        if let retryFailure = result.failure {
            // Report the failure that started the retry, not the one the retry
            // happened to hit. A retry that trips a *different* guard would
            // otherwise erase the original cause from the audit.
            return makeFailureEvidence(
                for: occurrences,
                failure: terminalFailure ?? retryFailure,
                runtime: result.runtime)
        }

        guard let selections = validatedSelections(result, for: occurrences) else {
            return makeFailureEvidence(
                for: occurrences,
                failure: terminalFailure ?? .invalidBatch,
                runtime: result.runtime)
        }

        return makeEvidence(
            for: occurrences,
            result: result,
            validatedSelections: selections)
    }

    private static func evaluate(
        _ occurrences: [ContextualPronunciationOccurrence],
        evaluator: ContextualPronunciationBatchEvaluator,
        environment: ContextualModelRuntime
    ) async throws -> ContextualPronunciationBatchResult {
        try Task.checkCancellation()
        do {
            let result = try await evaluator(.init(occurrences: occurrences))
            try Task.checkCancellation()
            return result
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            return ContextualPronunciationBatchResult(
                availability: .available,
                selections: [],
                failure: .unknown,
                runtime: environment)
        }
    }

    private static func plannedBatches(
        _ occurrences: [ContextualPronunciationOccurrence],
        configuration: ContextualPronunciationPreflightConfiguration
    ) -> [[ContextualPronunciationOccurrence]] {
        let maximumBatchCount = max(1, configuration.maximumBatchCount)
        let maximumPromptCharacters = max(1, configuration.maximumPromptCharacters)
        var batches: [[ContextualPronunciationOccurrence]] = []
        var batch: [ContextualPronunciationOccurrence] = []
        var characterCount = 0

        for occurrence in occurrences {
            let occurrenceCharacterCount = estimatedPromptCharacters(for: occurrence)
            if !batch.isEmpty,
                batch.count == maximumBatchCount
                    || characterCount + occurrenceCharacterCount > maximumPromptCharacters
            {
                batches.append(batch)
                batch = []
                characterCount = 0
            }

            batch.append(occurrence)
            characterCount += occurrenceCharacterCount

            if occurrenceCharacterCount > maximumPromptCharacters {
                batches.append(batch)
                batch = []
                characterCount = 0
            }
        }

        if !batch.isEmpty {
            batches.append(batch)
        }
        return batches
    }

    private static func occurrenceIDsAreUnique(
        _ occurrences: [ContextualPronunciationOccurrence]
    ) -> Bool {
        var occurrenceIDs: Set<String> = []
        for occurrence in occurrences {
            guard occurrenceIDs.insert(occurrence.occurrenceID).inserted else {
                return false
            }
        }
        return true
    }

    private static func estimatedPromptCharacters(
        for occurrence: ContextualPronunciationOccurrence
    ) -> Int {
        fieldCharacters("occurrenceID", occurrence.occurrenceID)
            + fieldCharacters("spelling", occurrence.targetWord)
            + fieldCharacters("precedingSentence", occurrence.precedingSentence ?? "")
            + fieldCharacters("targetSentence", occurrence.targetSentence)
            + fieldCharacters("followingSentence", occurrence.followingSentence ?? "")
            + occurrence.candidates.reduce(into: 0) { count, candidate in
                count += fieldCharacters("slot", candidate.slot.rawValue)
                count += fieldCharacters("meaning", candidate.senseLabel)
                count += fieldCharacters("lexicalRole", candidate.lexicalRole)
            }
    }

    private static func fieldCharacters(_ name: String, _ value: String) -> Int {
        name.count + value.count + 2
    }

    private static func halfSizeBatches(
        _ occurrences: [ContextualPronunciationOccurrence]
    ) -> [[ContextualPronunciationOccurrence]] {
        let batchSize = max(1, occurrences.count / 2)
        return stride(from: 0, to: occurrences.count, by: batchSize).map { start in
            Array(occurrences[start..<min(start + batchSize, occurrences.count)])
        }
    }

    private static func isInternallyConsistent(
        _ result: ContextualPronunciationBatchResult
    ) -> Bool {
        if result.availability == .available {
            return result.failure == nil || result.selections.isEmpty
        }
        return result.failure == nil && result.selections.isEmpty
    }

    private static func validatedSelections(
        _ result: ContextualPronunciationBatchResult,
        for occurrences: [ContextualPronunciationOccurrence]
    ) -> [String: ContextualCandidateSlot]? {
        guard result.availability == .available,
            result.failure == nil,
            result.selections.count == occurrences.count
        else {
            return nil
        }

        var occurrencesByID: [String: ContextualPronunciationOccurrence] = [:]
        for occurrence in occurrences {
            guard occurrencesByID[occurrence.occurrenceID] == nil else {
                return nil
            }
            occurrencesByID[occurrence.occurrenceID] = occurrence
        }
        var selectionsByID: [String: ContextualCandidateSlot] = [:]

        for selection in result.selections {
            guard let occurrence = occurrencesByID[selection.occurrenceID],
                selectionsByID[selection.occurrenceID] == nil,
                selection.slot == .needsReview
                    || occurrence.candidates.contains(where: {
                        $0.slot == selection.slot
                    })
            else {
                return nil
            }
            selectionsByID[selection.occurrenceID] = selection.slot
        }

        guard selectionsByID.count == occurrences.count else {
            return nil
        }
        return selectionsByID
    }

    private static func makeFailureEvidence(
        for occurrences: [ContextualPronunciationOccurrence],
        failure: ContextualModelFailure,
        runtime: ContextualModelRuntime
    ) -> [ContextualPronunciationEvidence] {
        makeEvidence(
            for: occurrences,
            result: ContextualPronunciationBatchResult(
                availability: .available,
                selections: [],
                failure: failure,
                runtime: runtime),
            validatedSelections: nil)
    }

    private static func makeEvidence(
        for occurrences: [ContextualPronunciationOccurrence],
        result: ContextualPronunciationBatchResult,
        validatedSelections: [String: ContextualCandidateSlot]?
    ) -> [ContextualPronunciationEvidence] {
        var batchEvidence: [ContextualPronunciationEvidence] = []
        batchEvidence.reserveCapacity(occurrences.count)

        for occurrence in occurrences {
            let selection = validatedSelections?[occurrence.occurrenceID]
            let selectedCandidateID = occurrence.candidates.first(where: {
                $0.slot == selection
            })?.candidateID
            let abstained = selection == .needsReview
            let acceptanceReason: ContextualAcceptanceReason
            if result.availability == .notRequested {
                acceptanceReason = .shadowNotRequested
            } else if result.availability != .available {
                acceptanceReason = .shadowModelUnavailable
            } else if result.failure != nil {
                acceptanceReason = .shadowModelFailure
            } else if abstained {
                acceptanceReason = .shadowNeedsReview
            } else {
                acceptanceReason = .shadowObserved
            }

            batchEvidence.append(
                ContextualPronunciationEvidence(
                    occurrenceID: occurrence.occurrenceID,
                    familyID: occurrence.familyID,
                    candidatePackVersion: ContextualPronunciationFamilies.candidatePackVersion,
                    submittedCandidateIDs: occurrence.candidates.map(\.candidateID),
                    deterministicCandidateID: occurrence.deterministicCandidateID,
                    deterministicRuleID: occurrence.deterministicRuleID,
                    deterministicStrength: occurrence.deterministicStrength,
                    modelCandidateID: selectedCandidateID,
                    modelAbstained: abstained,
                    modelAvailability: result.availability,
                    modelFailure: result.failure,
                    familyState: .shadow,
                    acceptanceReason: acceptanceReason,
                    promptSchemaVersion: ContextualPronunciationFamilies.promptSchemaVersion,
                    platform: result.runtime.platform,
                    osBuild: result.runtime.osBuild,
                    qualifiedRuntimeFamilyID: result.runtime.qualifiedRuntimeFamilyID,
                    humanCandidateID: nil,
                    humanCorrectionScope: nil,
                    isLimited: false))
        }
        return batchEvidence
    }
}
