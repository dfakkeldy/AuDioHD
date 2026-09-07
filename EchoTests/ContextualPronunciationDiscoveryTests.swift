// SPDX-License-Identifier: GPL-3.0-or-later
import Testing

@testable import Echo

@Suite struct ContextualPronunciationDiscoveryTests {
    @Test func discoveryUsesOnlyOneAdjacentSentencePerSide() throws {
        let occurrences = ContextualPronunciationDiscovery.discover(
            text: "First. Before. Yesterday I read it. After. Last.",
            blockID: "b1")

        let item = try #require(occurrences.first)
        #expect(occurrences.count == 1)
        #expect(item.precedingSentence == "Before.")
        #expect(item.targetSentence == "Yesterday I read it.")
        #expect(item.followingSentence == "After.")
    }

    @Test func linkedOverrideIsNotRediscovered() {
        let occurrences = ContextualPronunciationDiscovery.discover(
            text: "I [read](/ɹˈɛd/) it.",
            blockID: "b1")

        #expect(occurrences.isEmpty)
    }

    @Test func earlierAuthoredLinkDoesNotShiftCanonicalDisplayWordSpan() throws {
        let occurrences = ContextualPronunciationDiscovery.discover(
            text: "[Lead](/lˈid/) then I read it.",
            blockID: "b-markup")

        let item = try #require(occurrences.first)
        #expect(occurrences.count == 1)
        #expect(item.targetWord == "read")
        #expect(item.wordStart == 3)
        #expect(item.wordEnd == 3)
    }

    @Test func punctuationAttachedTargetsUseTheCanonicalWhitespaceWord() {
        let occurrences = ContextualPronunciationDiscovery.discover(
            text: "“Read,” then record what happened.",
            blockID: "b-punctuation")

        #expect(occurrences.map(\.targetWord) == ["Read", "record"])
        #expect(occurrences.map(\.wordStart) == [0, 2])
        #expect(occurrences.map(\.wordEnd) == [0, 2])
        #expect(
            occurrences.allSatisfy { $0.targetSentence == "“Read,” then record what happened." })
    }

    @Test func connectedFamilySpellingsDoNotShareOneCanonicalWordSpan() {
        let occurrences = ContextualPronunciationDiscovery.discover(
            text: "read/record",
            blockID: "b-connected")

        #expect(occurrences.isEmpty)
    }

    @Test func hyphenatedFamilySpellingKeepsItsOwnCanonicalWordSpan() throws {
        let occurrences = ContextualPronunciationDiscovery.discover(
            text: "Use read-only access.",
            blockID: "b-hyphenated")

        let item = try #require(occurrences.first)
        #expect(occurrences.count == 1)
        #expect(item.targetWord == "read")
        #expect(item.wordStart == 1)
        #expect(item.wordEnd == 1)
    }

    @Test func hyphenatedCanonicalWordWithTwoFamiliesIsNotAmbiguousAtOneIndex() {
        let occurrences = ContextualPronunciationDiscovery.discover(
            text: "read-record",
            blockID: "b-two-families")

        #expect(occurrences.isEmpty)
    }

    @Test func emDashJoinedFamilySpellingKeepsItsCanonicalWordSpan() throws {
        let occurrences = ContextualPronunciationDiscovery.discover(
            text: "Generate code or content—so it works.",
            blockID: "b-em-dash")

        let item = try #require(occurrences.first)
        #expect(occurrences.count == 1)
        #expect(item.targetWord == "content")
        #expect(item.wordStart == 3)
        #expect(item.wordEnd == 3)
    }

    @Test func plainURLComponentsAreExcludedFromDiscovery() {
        let occurrences = ContextualPronunciationDiscovery.discover(
            text:
                "The content is available at "
                + "https://example.com/wp-content/uploads/report.pdf.",
            blockID: "b-plain-url")

        #expect(occurrences.map(\.targetWord) == ["content"])
    }

    @Test func occurrenceIDIsTheSpecifiedIndependentSHA256() throws {
        let first = try #require(
            ContextualPronunciationDiscovery.discover(text: "read", blockID: "b1").first)
        let second = try #require(
            ContextualPronunciationDiscovery.discover(text: "read", blockID: "b1").first)
        let differentBlock = try #require(
            ContextualPronunciationDiscovery.discover(text: "read", blockID: "b2").first)

        #expect(
            first.occurrenceID
                == "ed3e920bcc956ebe419bfd4894cbc424262293101d20b8e8762aa66815e6f0d8")
        #expect(second.occurrenceID == first.occurrenceID)
        #expect(differentBlock.occurrenceID != first.occurrenceID)
    }

    @Test func discoveryCarriesIndependentDeterministicEvidenceWithoutRewriting() throws {
        let past = try #require(
            ContextualPronunciationDiscovery.discover(
                text: "I read the book yesterday.",
                blockID: "b-past"
            ).first)
        let satisfied = try #require(
            ContextualPronunciationDiscovery.discover(
                text: "I am content with the result.",
                blockID: "b-content"
            ).first)
        let abstained = try #require(
            ContextualPronunciationDiscovery.discover(
                text: "I read every day.",
                blockID: "b-present"
            ).first)

        #expect(past.deterministicCandidateID == "read.past")
        #expect(past.deterministicRuleID == "homograph.read.past.temporal-cue")
        #expect(past.deterministicStrength == .advisory)
        #expect(satisfied.deterministicCandidateID == "content.satisfied")
        #expect(satisfied.deterministicRuleID == "homograph.content.adjective.copula")
        #expect(satisfied.deterministicStrength == .definitive)
        #expect(abstained.deterministicCandidateID == nil)
        #expect(abstained.deterministicRuleID == nil)
        #expect(abstained.deterministicStrength == .abstained)
    }

    @Test func discoveryExcludesUnknownFamiliesAndEveryAuthoredTarget() {
        let occurrences = ContextualPronunciationDiscovery.discover(
            text: "resume arithmetic records [live](/lˈIv/) [content](/kˈɑntɛnt/).",
            blockID: "b-closed")

        #expect(occurrences.isEmpty)
    }

    @Test func discoveryExcludesProperNameRiskButAllowsTrueSentenceStartCapitalization() {
        let properName = ContextualPronunciationDiscovery.discover(
            text: "We met Read yesterday.",
            blockID: "b-name")
        let abbreviationName = ContextualPronunciationDiscovery.discover(
            text: "Dr. Read arrived.",
            blockID: "b-abbreviation")
        let allCaps = ContextualPronunciationDiscovery.discover(
            text: "Please ask READ now.",
            blockID: "b-caps")
        let sentenceStart = ContextualPronunciationDiscovery.discover(
            text: "Done. Read it now.",
            blockID: "b-sentence")

        #expect(properName.isEmpty)
        #expect(abbreviationName.isEmpty)
        #expect(allCaps.isEmpty)
        #expect(sentenceStart.map(\.targetWord) == ["Read"])
    }

    @Test func titleCaseRecordAfterDeterminerRetainsExactNounEvidence() throws {
        let occurrence = try #require(
            ContextualPronunciationDiscovery.discover(
                text: "The Record in Room 3B",
                blockID: "title-record"
            ).first)

        #expect(occurrence.targetWord == "Record")
        #expect(occurrence.familyID == "record")
        #expect(occurrence.deterministicCandidateID == "record.noun")
        #expect(occurrence.deterministicRuleID == "homograph.record.noun.preceder")
    }

    @Test func allCapsContentBeforeCorrectnessRetainsExactNounEvidence() throws {
        let occurrence = try #require(
            ContextualPronunciationDiscovery.discover(
                text: "CONTENT CORRECTNESS: NOT ASSESSED",
                blockID: "content-correctness"
            ).first)

        #expect(occurrence.targetWord == "CONTENT")
        #expect(occurrence.familyID == "content")
        #expect(occurrence.deterministicCandidateID == "content.material")
        #expect(occurrence.deterministicRuleID == "homograph.content.noun.follower")
    }

    @Test func titleCaseGovernanceNounsRetainContextualEvidence() {
        let labels = ContextualPronunciationDiscovery.discover(
            text: "Saye, Asha Ren, Mara Venn, Record Integrity, Harmful Content Containment.",
            blockID: "governance-labels")
        let checked = ContextualPronunciationDiscovery.discover(
            text: "Harmful Content had checked the phrase against abuse patterns.",
            blockID: "governance-checked")
        let recommended = ContextualPronunciationDiscovery.discover(
            text: "Harmful Content had recommended continued observability.",
            blockID: "governance-recommended")

        #expect(labels.map(\.targetWord) == ["Record", "Content"])
        #expect(labels.map(\.deterministicCandidateID) == ["record.noun", "content.material"])
        #expect(labels.map(\.deterministicRuleID) == [
            "homograph.record.noun.compound",
            "homograph.content.noun.follower",
        ])
        #expect(checked.map(\.targetWord) == ["Content"])
        #expect(checked.map(\.deterministicCandidateID) == ["content.material"])
        #expect(checked.map(\.deterministicRuleID) == ["homograph.content.noun.follower"])
        #expect(recommended.map(\.targetWord) == ["Content"])
        #expect(recommended.map(\.deterministicCandidateID) == ["content.material"])
        #expect(recommended.map(\.deterministicRuleID) == ["homograph.content.noun.follower"])
    }

    @Test func discoveryAdmitsExactWeatherLinkLiveProductEvidence() throws {
        let occurrence = try #require(
            ContextualPronunciationDiscovery.discover(
                text: "Request access to a Weather Link Live platform.",
                blockID: "weather-link-live"
            ).first)

        #expect(occurrence.targetWord == "Live")
        #expect(occurrence.familyID == "live")
        #expect(occurrence.deterministicCandidateID == "live.adjective")
        #expect(occurrence.deterministicRuleID == "homograph.live.product.weather-link-live")
    }

    @Test func titleCaseLiveBeforeAnAdjectiveFollowerRetainsExactEvidence() throws {
        let occurrence = try #require(
            ContextualPronunciationDiscovery.discover(
                text: "his hay and grain, and his Live Stock, consumed by fire",
                blockID: "live-stock"
            ).first)

        #expect(occurrence.targetWord == "Live")
        #expect(occurrence.familyID == "live")
        #expect(occurrence.deterministicCandidateID == "live.adjective")
        #expect(occurrence.deterministicRuleID == "homograph.live.adjective.follower")
    }

    @Test func hiddenAndCodeCueInputsAreExplicitlyExcluded() {
        #expect(
            ContextualPronunciationDiscovery.discover(
                text: "Read the content.",
                blockID: "b-hidden",
                isHidden: true
            ).isEmpty)
        #expect(
            ContextualPronunciationDiscovery.discover(
                text: "Read the content.",
                blockID: "b-code",
                isCodeBlock: true
            ).isEmpty)
    }

    @Test func occurrencesStayInSourceOrderWithSpellingSpecificCandidates() {
        let occurrences = ContextualPronunciationDiscovery.discover(
            text: "content read live lives record",
            blockID: "b-order")

        #expect(occurrences.map(\.targetWord) == ["content", "read", "live", "lives", "record"])
        #expect(occurrences.map(\.familyID) == ["content", "read", "live", "live", "record"])
        #expect(
            occurrences.map { $0.candidates.map(\.candidateID) }
                == [
                    ["content.material", "content.satisfied"],
                    ["read.present", "read.past"],
                    ["live.adjective", "live.verb"],
                    ["lives.noun", "lives.verb"],
                    ["record.noun", "record.verb"],
                ])
    }

    @Test func denseDiscoveryUsesOnePreparedSnapshotAndOneHomographTokenization() {
        let spellings = ["content", "read", "live", "lives", "record"]
        let repetitions = 24
        let source = Array(repeating: spellings, count: repetitions)
            .flatMap { $0 }
            .joined(separator: " ")
        let expectedCount = spellings.count * repetitions
        var operationCounts = ContextualPronunciationDiscovery.OperationCounts()

        let occurrences = ContextualPronunciationDiscovery.discover(
            text: source,
            blockID: "b-dense",
            operationCounts: &operationCounts)

        #expect(occurrences.count == expectedCount)
        #expect(operationCounts.sourceSnapshotConstructions == 1)
        #expect(operationCounts.homographTokenizations == 1)
        #expect(operationCounts.homographTokenVisits == expectedCount)
        #expect(operationCounts.candidateSpanLookups == expectedCount)
        #expect(operationCounts.homographSpanLookups == expectedCount)
        #expect(operationCounts.sentenceLookups == expectedCount)
    }

    @Test func unmatchedLinkTailsUseBoundedPreparedLinkInspection() {
        let source = String(repeating: "[", count: 2_048) + "read"
        var operationCounts = ContextualPronunciationDiscovery.OperationCounts()

        let occurrences = ContextualPronunciationDiscovery.discover(
            text: source,
            blockID: "b-unmatched-links",
            operationCounts: &operationCounts)

        #expect(occurrences.map(\.targetWord) == ["read"])
        #expect(operationCounts.sourceLinkInspections <= source.count * 12)
        #expect(operationCounts.sourceSnapshotConstructions == 1)
        #expect(operationCounts.homographTokenizations == 1)
    }

    @Test func preparedSnapshotPreservesMultipleLinksUnicodeAndCRLFCoordinates() {
        let source =
            "😀 [lead](/lˈid/) Café.\r\n"
            + "[record](/ɹˈɛkəɹd/) Read, then read; live lives content record."

        let occurrences = ContextualPronunciationDiscovery.discover(
            text: source,
            blockID: "b-unicode-links-crlf")

        #expect(
            occurrences.map(\.targetWord)
                == ["read", "live", "lives", "content", "record"])
        #expect(occurrences.map(\.wordStart) == [6, 7, 8, 9, 10])
        #expect(occurrences.map(\.wordEnd) == [6, 7, 8, 9, 10])
        #expect(Set(occurrences.map(\.occurrenceID)).count == occurrences.count)
        #expect(occurrences.allSatisfy { !$0.targetSentence.contains("\r") })
    }
}
