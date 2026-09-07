// SPDX-License-Identifier: GPL-3.0-or-later
import Testing

@testable import Echo

@Suite struct ContextualPronunciationFamiliesTests {
    @Test func contentCandidatesHaveStableSlotsOrderAndIPA() throws {
        let family = try #require(ContextualPronunciationFamilies.family(for: "content"))

        #expect(family.familyID == "content")
        #expect(family.state == .shadow)
        #expect(family.candidates.map(\.slot) == [.a, .b])
        #expect(
            family.candidates.map(\.candidateID)
                == ["content.material", "content.satisfied"])
        #expect(family.candidates.map(\.ipa) == ["kˈɑntɛnt", "kəntˈɛnt"])
        #expect(family.candidates.map(\.lexicalRole) == ["noun", "adjective"])
        #expect(family.candidates.map(\.senseLabel) == ["material/information", "satisfied"])
    }

    @Test func readCandidatesHaveStableSlotsOrderAndIPA() throws {
        let family = try #require(ContextualPronunciationFamilies.family(for: "read"))

        #expect(family.familyID == "read")
        #expect(family.state == .shadow)
        #expect(family.candidates.map(\.slot) == [.a, .b])
        #expect(family.candidates.map(\.candidateID) == ["read.present", "read.past"])
        #expect(family.candidates.map(\.ipa) == ["ɹˈid", "ɹˈɛd"])
        #expect(family.candidates.map(\.lexicalRole) == ["verb", "verb"])
        #expect(family.candidates.map(\.senseLabel) == ["present/base", "past/participle"])
    }

    @Test func liveSpellingsShareOneFamilyWithSpellingSpecificCandidates() throws {
        let live = try #require(ContextualPronunciationFamilies.family(for: "live"))
        let lives = try #require(ContextualPronunciationFamilies.family(for: "lives"))

        #expect(live.familyID == "live")
        #expect(lives.familyID == "live")
        #expect(live.state == .shadow)
        #expect(lives.state == .shadow)
        #expect(live.candidates.map(\.candidateID) == ["live.adjective", "live.verb"])
        #expect(live.candidates.map(\.ipa) == ["lˈIv", "lˈɪv"])
        #expect(lives.candidates.map(\.candidateID) == ["lives.noun", "lives.verb"])
        #expect(lives.candidates.map(\.ipa) == ["lˈIvz", "lˈɪvz"])
    }

    @Test func recordCandidatesHaveStableSlotsOrderAndIPA() throws {
        let family = try #require(ContextualPronunciationFamilies.family(for: "record"))

        #expect(family.familyID == "record")
        #expect(family.state == .shadow)
        #expect(family.candidates.map(\.slot) == [.a, .b])
        #expect(family.candidates.map(\.candidateID) == ["record.noun", "record.verb"])
        #expect(family.candidates.map(\.ipa) == ["ɹˈɛkəɹd", "ɹəkˈɔɹd"])
        #expect(family.candidates.map(\.lexicalRole) == ["noun/adjective", "verb"])
    }

    @Test func candidateAndPromptVersionsAreStableAndListsStayBounded() {
        #expect(ContextualPronunciationFamilies.candidatePackVersion == "context-candidates-v1")
        #expect(ContextualPronunciationFamilies.promptSchemaVersion == "context-shadow-v2")

        for spelling in ["content", "read", "live", "lives", "record"] {
            let candidates = ContextualPronunciationFamilies.family(for: spelling)?.candidates ?? []
            #expect(!candidates.isEmpty)
            #expect(candidates.count <= 4)
            #expect(candidates.map(\.slot) == [.a, .b])
        }
    }

    @Test func familyLookupIsNormalizedAndClosedToUnknownWords() {
        #expect(ContextualPronunciationFamilies.family(for: "READ")?.familyID == "read")
        #expect(ContextualPronunciationFamilies.family(for: "résumé") == nil)
        #expect(ContextualPronunciationFamilies.family(for: "records") == nil)
    }
}
