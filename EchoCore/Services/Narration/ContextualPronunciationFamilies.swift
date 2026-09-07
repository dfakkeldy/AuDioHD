// SPDX-License-Identifier: GPL-3.0-or-later

/// Fixed, Echo-owned choices for the first contextual pronunciation families.
/// Models select an opaque slot in later phases; IPA never becomes model output.
nonisolated enum ContextualPronunciationFamilies {
    static let candidatePackVersion = "context-candidates-v1"
    static let promptSchemaVersion = "context-shadow-v2"

    private static let bySpelling: [String: ContextualPronunciationFamily] = [
        "content": family(
            id: "content",
            spelling: "content",
            candidates: [
                candidate(
                    .a, "content.material", "kˈɑntɛnt",
                    sense: "material/information", role: "noun"),
                candidate(
                    .b, "content.satisfied", "kəntˈɛnt",
                    sense: "satisfied", role: "adjective"),
            ]),
        "read": family(
            id: "read",
            spelling: "read",
            candidates: [
                candidate(
                    .a, "read.present", "ɹˈid",
                    sense: "present/base", role: "verb"),
                candidate(
                    .b, "read.past", "ɹˈɛd",
                    sense: "past/participle", role: "verb"),
            ]),
        "live": family(
            id: "live",
            spelling: "live",
            candidates: [
                candidate(
                    .a, "live.adjective", "lˈIv",
                    sense: "not recorded", role: "adjective"),
                candidate(
                    .b, "live.verb", "lˈɪv",
                    sense: "reside/remain alive", role: "verb"),
            ]),
        "lives": family(
            id: "live",
            spelling: "lives",
            candidates: [
                candidate(
                    .a, "lives.noun", "lˈIvz",
                    sense: "existences", role: "plural noun"),
                candidate(
                    .b, "lives.verb", "lˈɪvz",
                    sense: "third-person", role: "verb"),
            ]),
        "record": family(
            id: "record",
            spelling: "record",
            candidates: [
                candidate(
                    .a, "record.noun", "ɹˈɛkəɹd",
                    sense: "stored account", role: "noun/adjective"),
                candidate(
                    .b, "record.verb", "ɹəkˈɔɹd",
                    sense: "capture", role: "verb"),
            ]),
    ]

    static func family(for spelling: String) -> ContextualPronunciationFamily? {
        let normalized = PronunciationAuditContext.normalizedWord(spelling)
        guard !normalized.contains(" ") else { return nil }
        return bySpelling[normalized]
    }

    private static func family(
        id: String,
        spelling: String,
        candidates: [ContextualPronunciationCandidate]
    ) -> ContextualPronunciationFamily {
        ContextualPronunciationFamily(
            familyID: id,
            normalizedSpelling: spelling,
            candidates: candidates,
            state: .shadow)
    }

    private static func candidate(
        _ slot: ContextualCandidateSlot,
        _ candidateID: String,
        _ ipa: String,
        sense: String,
        role: String
    ) -> ContextualPronunciationCandidate {
        ContextualPronunciationCandidate(
            slot: slot,
            candidateID: candidateID,
            ipa: ipa,
            senseLabel: sense,
            lexicalRole: role)
    }
}
