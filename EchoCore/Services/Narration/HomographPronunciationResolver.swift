// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Applies narrow, deterministic pronunciation hints for English homographs that
/// the lexicon cannot reliably disambiguate from local part-of-speech tags alone.
nonisolated enum HomographPronunciationResolver {
    private struct Resolution {
        let ipa: String
        let ruleID: String
        let rationale: String
    }

    private struct Token {
        let text: String
        let lowercased: String
        let range: Range<String.Index>
        let nsRange: NSRange
        let isAuthoredLinkDisplay: Bool
        /// True when this token opens a new sentence (nothing but a sentence
        /// terminator or the start of the text precedes it). Lets the contextual
        /// rules avoid reading across sentence boundaries that the word tokenizer
        /// otherwise ignores.
        let startsSentence: Bool
    }

    struct ContextualAnalysisOperationCounts {
        var tokenizations = 0
        var tokenVisits = 0
        var wordSpanLookups = 0
    }

    struct ContextualAnalysisContext {
        private let analysisByWordStart: [Int: ContextualDeterministicAnalysis]

        fileprivate init(
            analysisByWordStart: [Int: ContextualDeterministicAnalysis]
        ) {
            self.analysisByWordStart = analysisByWordStart
        }

        func analysis(
            atWordStart wordStart: Int
        ) -> ContextualDeterministicAnalysis {
            analysisByWordStart[wordStart] ?? .abstained
        }
    }

    private enum IPA {
        static let readPast = "ɹˈɛd"
        static let liveAdjective = "lˈIv"
        static let liveVerb = "lˈɪv"
        static let livesNoun = "lˈIvz"
        static let livesVerb = "lˈɪvz"
        static let recordNoun = "ɹˈɛkəɹd"
        static let recordVerb = "ɹəkˈɔɹd"
        static let contentNoun = "kˈɑntɛnt"
        static let contentSatisfied = "kəntˈɛnt"
        static let resumeDocument = "ɹˈɛzʊmˌA"
        static let resumesDocuments = "ɹˈɛzʊmˌAz"
        static let arithmeticNoun = "əɹˈɪθmətˌɪk"
    }

    private static let wordRegex = try! NSRegularExpression(pattern: #"\b[\p{L}]+\b"#)
    private static let hyphens: Set<Character> = ["-", "‑"]
    private static let sentenceTerminators: Set<Character> = [
        ".", "!", "?", "…", ";", "\n", "\r",
    ]

    private static let pastReadPreceders: Set<String> = [
        "am", "are", "be", "been", "being", "get", "gets", "got", "gotten",
        "had", "has", "have", "having", "is", "was", "were",
    ]
    private static let pastReadFollowers: Set<String> = [
        "ago", "already", "earlier", "last", "previously", "yesterday",
    ]

    private static let liveVerbPreceders: Set<String> = [
        "can", "children", "could", "i", "may", "might", "must", "people", "readers",
        "shall", "should", "they", "to", "we", "will", "would", "you",
    ]
    private static let liveVerbFollowers: Set<String> = [
        "alone", "at", "downtown", "elsewhere", "forever", "here", "in", "inside",
        "longer", "near", "nearby", "on", "outside", "there", "together", "upstairs",
        "well", "with",
    ]
    private static let liveAdjectiveFollowers: Set<String> = [
        "argument", "asset", "assets", "audience", "broadcast", "broadcasts", "content",
        "coverage", "demo", "demos", "event", "events", "feed", "feeds", "lesson",
        "lessons", "lecture", "lectures", "music", "performance", "performances",
        "recording", "recordings", "session", "sessions", "show", "shows", "stock",
        "stream", "streams", "update", "updates", "wire", "wires",
    ]

    private static let livesNounPreceders: Set<String> = [
        "all", "her", "his", "many", "my", "our", "several", "their", "these",
        "those", "whose", "your",
    ]
    private static let livesVerbPreceders: Set<String> = [
        "everyone", "he", "hype", "it", "nobody", "one", "receipt", "she",
        "somebody", "someone", "subject", "that", "who",
    ]

    private static let recordNounPreceders: Set<String> = [
        "a", "an", "another", "each", "every", "her", "his", "its", "my", "our",
        "that", "the", "their", "these", "this", "those", "your",
    ]
    private static let recordNounCompoundFollowers: Set<String> = [
        "integrity", "label", "labels", "player", "players", "sales", "store", "stores",
    ]
    private static let recordVerbPreceders: Set<String> = [
        "can", "could", "may", "might", "must", "please", "shall", "should", "to", "will",
        "would", "i", "we", "you", "they",
    ]
    private static let recordVerbWhObjectFollowers: Set<String> = [
        "what", "whatever",
    ]

    private static let contentNounPreceders: Set<String> = [
        "all", "any", "app", "audio", "book", "chapter", "course", "digital", "educational",
        "her", "his", "its", "more", "my", "new", "our", "page", "site", "some",
        "story", "that", "the", "their", "these", "this", "those", "training", "video",
        "web", "your",
    ]
    private static let contentNounFollowers: Set<String> = [
        "changed", "containment", "correctness", "had", "includes", "is", "lives", "ships",
        "shipped", "stayed", "stays", "was",
    ]
    private static let contentNounSentenceStartFollowers: Set<String> = [
        "i", "it", "that", "they", "this", "we", "you",
    ]
    private static let contentSatisfiedFollowers: Set<String> = [
        "to", "with",
    ]
    /// Copula / linking verbs that make a following `content` the "satisfied"
    /// adjective ("I am content with…", "she felt content"). Without one of
    /// these a bare "content to"/"content with" is the noun, not the adjective.
    private static let contentAdjectivePreceders: Set<String> = [
        "am", "appear", "appeared", "appears", "are", "be", "became", "become",
        "becomes", "been", "being", "feel", "feeling", "feels", "felt", "is",
        "look", "looked", "looks", "m", "remain", "remained", "remains", "seem",
        "seemed", "seems", "stay", "stayed", "stays", "was", "were",
    ]
    private static let resumeDocumentPreceders: Set<String> = [
        "all", "applicant", "applicants", "candidate", "candidates", "her", "his",
        "many", "my", "our", "several", "the", "their", "these", "those", "your",
    ]
    private static let resumeDocumentFollowers: Set<String> = [
        "attached", "changed", "includes", "is", "lists", "mentions", "shows",
        "submitted", "was",
    ]
    private static let resumesDocumentFollowers: Set<String> = [
        "are", "attached", "include", "list", "mention", "show", "submitted", "were",
    ]
    private static let resumeVerbPreceders: Set<String> = [
        "can", "could", "does", "may", "might", "must", "should", "to", "will",
        "would",
    ]
    private static let arithmeticAdjectiveFollowers: Set<String> = [
        "mean", "means", "operation", "operations", "operator", "operators",
        "progression", "progressions", "sequence", "sequences",
    ]

    static func apply(to text: String) -> String {
        rewrite(to: text, blockID: "").text
    }

    /// Exposes the existing grammatical rule result as independent evidence.
    /// It never rewrites text and has no model input or model-selected value.
    static func contextualAnalysis(
        in text: String,
        wordStart: Int
    ) -> ContextualDeterministicAnalysis {
        var operationCounts = ContextualAnalysisOperationCounts()
        return contextualAnalyses(
            in: text,
            wordStarts: [wordStart],
            operationCounts: &operationCounts
        )[wordStart] ?? .abstained
    }

    static func contextualAnalyses(
        in text: String,
        wordStarts: [Int],
        operationCounts: inout ContextualAnalysisOperationCounts
    ) -> [Int: ContextualDeterministicAnalysis] {
        let sourceSnapshot =
            ContextualPronunciationDiscovery.SourceSnapshot(source: text)
        let context = prepareContextualAnalysis(
            in: text,
            sourceSnapshot: sourceSnapshot,
            operationCounts: &operationCounts)
        var result: [Int: ContextualDeterministicAnalysis] = [:]
        result.reserveCapacity(wordStarts.count)
        for wordStart in wordStarts {
            result[wordStart] = context.analysis(atWordStart: wordStart)
        }
        return result
    }

    static func prepareContextualAnalysis(
        in text: String,
        sourceSnapshot: ContextualPronunciationDiscovery.SourceSnapshot,
        operationCounts: inout ContextualAnalysisOperationCounts
    ) -> ContextualAnalysisContext {
        operationCounts = ContextualAnalysisOperationCounts()
        let tokens = tokens(
            in: text,
            authoredLinks: sourceSnapshot.authoredLinks)
        operationCounts.tokenizations = 1
        var analysisByWordStart: [Int: ContextualDeterministicAnalysis] = [:]
        for index in tokens.indices {
            operationCounts.tokenVisits += 1
            let token = tokens[index]
            guard !token.isAuthoredLinkDisplay,
                !isHyphenated(token.range, in: text),
                let family = ContextualPronunciationFamilies.family(for: token.lowercased)
            else {
                continue
            }

            operationCounts.wordSpanLookups += 1
            guard let wordSpan = sourceSnapshot.wordSpan(containing: token.range) else {
                continue
            }
            let analysis: ContextualDeterministicAnalysis
            if let resolution = resolution(for: token, at: index, tokens: tokens),
                let candidateID = family.candidates.first(where: {
                    $0.ipa == resolution.ipa
                })?.candidateID
            {
                analysis = ContextualDeterministicAnalysis(
                    candidateID: candidateID,
                    ruleID: resolution.ruleID,
                    strength: deterministicStrength(for: resolution.ruleID))
            } else {
                analysis = .abstained
            }
            for wordStart in wordSpan
            where analysisByWordStart[wordStart] == nil {
                analysisByWordStart[wordStart] = analysis
            }
        }
        return ContextualAnalysisContext(
            analysisByWordStart: analysisByWordStart)
    }

    static func rewrite(to text: String, blockID: String) -> PronunciationRewriteResult {
        let tokens = tokens(in: text)
        guard !tokens.isEmpty else {
            return PronunciationRewriteResult(text: text, decisionSeeds: [])
        }

        var replacements:
            [(
                range: NSRange,
                token: Token,
                resolution: Resolution,
                decisionSeed: PronunciationDecisionSeed
            )] = []
        for index in tokens.indices {
            let token = tokens[index]
            guard !token.isAuthoredLinkDisplay else { continue }
            guard !isHyphenated(token.range, in: text) else { continue }
            guard let resolution = resolution(for: token, at: index, tokens: tokens)
            else { continue }
            guard
                let wordSpan = PronunciationAuditContext.wordSpan(
                    containing: token.range,
                    in: text)
            else {
                continue
            }

            replacements.append(
                (
                    range: token.nsRange,
                    token: token,
                    resolution: resolution,
                    decisionSeed: PronunciationDecisionSeed(
                        blockID: blockID,
                        wordStart: wordSpan.lowerBound,
                        wordEnd: wordSpan.upperBound,
                        normalizedWord: token.lowercased,
                        sourceWord: token.text,
                        sourceContext: PronunciationAuditContext.sourceContext(
                            in: text,
                            wordStart: wordSpan.lowerBound,
                            wordEnd: wordSpan.upperBound),
                        selectedIPA: resolution.ipa,
                        source: .contextualHomograph,
                        ruleID: resolution.ruleID,
                        rationale: resolution.rationale)
                ))
        }

        var result = text
        for replacement in replacements.reversed() {
            guard let range = Range(replacement.range, in: result) else { continue }
            result.replaceSubrange(
                range,
                with: "[\(replacement.token.text)](/\(replacement.resolution.ipa)/)")
        }
        return PronunciationRewriteResult(
            text: result,
            decisionSeeds: replacements.map { $0.decisionSeed })
    }

    private static func resolution(
        for token: Token,
        at index: Int,
        tokens: [Token]
    ) -> Resolution? {
        switch token.lowercased {
        case "read":
            return readResolution(at: index, tokens: tokens)
        case "live":
            return liveResolution(at: index, tokens: tokens)
        case "lives":
            return livesResolution(at: index, tokens: tokens)
        case "record":
            return recordResolution(at: index, tokens: tokens)
        case "content":
            return contentResolution(at: index, tokens: tokens)
        case "resume":
            return resumeResolution(at: index, tokens: tokens)
        case "resumes":
            return resumesResolution(at: index, tokens: tokens)
        case "résumé":
            return Resolution(
                ipa: IPA.resumeDocument,
                ruleID: "homograph.resume.noun.accented-spelling",
                rationale: "Document pronunciation selected from the accented spelling “résumé”.")
        case "résumés":
            return Resolution(
                ipa: IPA.resumesDocuments,
                ruleID: "homograph.resumes.noun.accented-spelling",
                rationale: "Document pronunciation selected from the accented spelling “résumés”.")
        case "arithmetic":
            return arithmeticResolution(at: index, tokens: tokens)
        default:
            return nil
        }
    }

    /// Phase 2 promotes only the exact satisfied-content construction. Existing
    /// lexical cue rules remain useful shadow evidence but are conservatively
    /// advisory until their families complete corpus qualification.
    private static func deterministicStrength(
        for ruleID: String
    ) -> DeterministicRuleStrength {
        ruleID == "homograph.content.adjective.copula" ? .definitive : .advisory
    }

    private static func readResolution(at index: Int, tokens: [Token]) -> Resolution? {
        if let cue = previousLowercased(tokens, index), pastReadPreceders.contains(cue) {
            return Resolution(
                ipa: IPA.readPast,
                ruleID: "homograph.read.past.preceder",
                rationale: "Past-tense pronunciation selected after “\(cue)”.")
        }

        if let cue = nextLowercased(tokens, index, limit: 4).first(
            where: pastReadFollowers.contains)
        {
            return Resolution(
                ipa: IPA.readPast,
                ruleID: "homograph.read.past.temporal-cue",
                rationale: "Past-tense pronunciation selected from temporal cue “\(cue)”.")
        }

        return nil
    }

    private static func contentResolution(at index: Int, tokens: [Token]) -> Resolution? {
        let previous = previousLowercased(tokens, index)
        let next = nextLowercased(tokens, index, limit: 1)

        // Resolve a linking verb through a bounded run of degree/negation
        // modifiers before the quantity rule for "more content" can win.
        // Existential "there is more content" remains a material noun.
        let modifiers: Set<String> = [
            "more", "less", "quite", "very", "perfectly", "entirely",
            "fully", "completely", "not", "never", "still", "always", "so", "rather",
        ]
        var cursor = index
        var skipped = 0
        while cursor > tokens.startIndex, !tokens[cursor].startsSentence, skipped < 3,
            modifiers.contains(tokens[cursor - 1].lowercased)
        {
            cursor -= 1
            skipped += 1
        }
        if let linkingVerb = previousLowercased(tokens, cursor),
            contentAdjectivePreceders.contains(linkingVerb)
        {
            let auxiliaries: Set<String> = [
                "will", "would", "can", "could", "may", "might",
                "shall", "should", "must", "has", "have", "had", "not", "never", "always", "still",
            ]
            var subjectCursor = cursor - 1
            var subject = previousLowercased(tokens, subjectCursor)
            while subjectCursor > 0, let word = subject, auxiliaries.contains(word) {
                subjectCursor -= 1
                subject = previousLowercased(tokens, subjectCursor)
            }
            let nounSubject = ["there", "here", "this", "that"].contains(subject ?? "")
            let personalSubject = ["i", "you", "we", "they", "he", "she"].contains(subject ?? "")
            let satisfiedFollower = next.contains(where: contentSatisfiedFollowers.contains)
            // Do not defeat the quantity noun on an uncertain subject, e.g.
            // "There will also be more content" or "The answer is more content".
            if !nounSubject, personalSubject || (skipped == 0 && satisfiedFollower),
                next.isEmpty || satisfiedFollower
            {
                return Resolution(
                    ipa: IPA.contentSatisfied,
                    ruleID: "homograph.content.adjective.copula",
                    rationale:
                        "Satisfied-adjective pronunciation selected after a linking verb and optional modifiers."
                )
            }
        }

        // A noun preceder ("the content", "audio content") wins outright, even
        // when a "to"/"with" follows: "Add content to the page." is the noun.
        if let cue = previous, contentNounPreceders.contains(cue) {
            return Resolution(
                ipa: IPA.contentNoun,
                ruleID: "homograph.content.noun.preceder",
                rationale: "Noun pronunciation selected after “\(cue)”.")
        }

        if let cue = next.first(where: contentNounFollowers.contains) {
            return Resolution(
                ipa: IPA.contentNoun,
                ruleID: "homograph.content.noun.follower",
                rationale: "Noun pronunciation selected before “\(cue)”.")
        }

        if index == tokens.startIndex,
            let cue = next.first(where: contentNounSentenceStartFollowers.contains)
        {
            return Resolution(
                ipa: IPA.contentNoun,
                ruleID: "homograph.content.noun.sentence-start",
                rationale: "Noun pronunciation selected at sentence start before “\(cue)”.")
        }

        return nil
    }

    private static func resumeResolution(at index: Int, tokens: [Token]) -> Resolution? {
        if previousLowercased(tokens, index).map(resumeVerbPreceders.contains) == true {
            return nil
        }

        let next = nextLowercased(tokens, index, limit: 1)
        if let cue = previousLowercased(tokens, index), resumeDocumentPreceders.contains(cue) {
            return Resolution(
                ipa: IPA.resumeDocument,
                ruleID: "homograph.resume.noun.preceder",
                rationale: "Document pronunciation selected after “\(cue)”.")
        }

        if let cue = next.first(where: resumeDocumentFollowers.contains) {
            return Resolution(
                ipa: IPA.resumeDocument,
                ruleID: "homograph.resume.noun.follower",
                rationale: "Document pronunciation selected before “\(cue)”.")
        }

        return nil
    }

    private static func resumesResolution(at index: Int, tokens: [Token]) -> Resolution? {
        let next = nextLowercased(tokens, index, limit: 1)
        if let cue = previousLowercased(tokens, index), resumeDocumentPreceders.contains(cue) {
            return Resolution(
                ipa: IPA.resumesDocuments,
                ruleID: "homograph.resumes.noun.preceder",
                rationale: "Document pronunciation selected after “\(cue)”.")
        }

        if let cue = next.first(where: resumesDocumentFollowers.contains) {
            return Resolution(
                ipa: IPA.resumesDocuments,
                ruleID: "homograph.resumes.noun.follower",
                rationale: "Document pronunciation selected before “\(cue)”.")
        }

        if index == tokens.startIndex, next.isEmpty {
            return Resolution(
                ipa: IPA.resumesDocuments,
                ruleID: "homograph.resumes.noun.standalone",
                rationale: "Document pronunciation selected for standalone “resumes”.")
        }

        return nil
    }

    private static func arithmeticResolution(at index: Int, tokens: [Token]) -> Resolution? {
        let next = nextLowercased(tokens, index, limit: 1)
        if next.contains(where: arithmeticAdjectiveFollowers.contains) {
            return nil
        }

        return Resolution(
            ipa: IPA.arithmeticNoun,
            ruleID: "homograph.arithmetic.noun.default",
            rationale:
                "Noun pronunciation selected because no technical adjective follower matched.")
    }

    private static func liveResolution(at index: Int, tokens: [Token]) -> Resolution? {
        if index >= 2 {
            let weather = tokens[index - 2]
            let link = tokens[index - 1]
            let live = tokens[index]
            if !link.startsSentence,
                !live.startsSentence,
                weather.lowercased == "weather",
                link.lowercased == "link"
            {
                return Resolution(
                    ipa: IPA.liveAdjective,
                    ruleID: "homograph.live.product.weather-link-live",
                    rationale:
                        "Adjective pronunciation selected in the product name “Weather Link Live”.")
            }
        }

        if let cue = previousLowercased(tokens, index), liveVerbPreceders.contains(cue) {
            return Resolution(
                ipa: IPA.liveVerb,
                ruleID: "homograph.live.verb.preceder",
                rationale: "Verb pronunciation selected after “\(cue)”.")
        }

        if let cue = nextLowercased(tokens, index, limit: 1).first(
            where: liveVerbFollowers.contains)
        {
            return Resolution(
                ipa: IPA.liveVerb,
                ruleID: "homograph.live.verb.location-follower",
                rationale: "Verb pronunciation selected before “\(cue)”.")
        }

        if let cue = nextLowercased(tokens, index, limit: 1).first(
            where: liveAdjectiveFollowers.contains)
        {
            return Resolution(
                ipa: IPA.liveAdjective,
                ruleID: "homograph.live.adjective.follower",
                rationale: "Adjective pronunciation selected before “\(cue)”.")
        }

        return nil
    }

    private static func livesResolution(at index: Int, tokens: [Token]) -> Resolution? {
        if let cue = previousLowercased(tokens, index), livesNounPreceders.contains(cue) {
            return Resolution(
                ipa: IPA.livesNoun,
                ruleID: "homograph.lives.noun.preceder",
                rationale: "Plural-noun pronunciation selected after “\(cue)”.")
        }

        if let phrase = oneOfSuperlativeLivesPhrase(at: index, tokens: tokens) {
            return Resolution(
                ipa: IPA.livesNoun,
                ruleID: "homograph.lives.noun.one-of-superlative",
                rationale:
                    "Plural-noun pronunciation selected in the descriptive superlative phrase “\(phrase)”."
            )
        }

        if let cue = previousLowercased(tokens, index), livesVerbPreceders.contains(cue) {
            return Resolution(
                ipa: IPA.livesVerb,
                ruleID: "homograph.lives.verb.subject",
                rationale: "Verb pronunciation selected after subject cue “\(cue)”.")
        }

        if let cue = nextLowercased(tokens, index, limit: 1).first(
            where: liveVerbFollowers.contains)
        {
            return Resolution(
                ipa: IPA.livesVerb,
                ruleID: "homograph.lives.verb.location-follower",
                rationale: "Verb pronunciation selected before “\(cue)”.")
        }

        if nextSameSentenceLowercased(tokens, index) == "as" {
            return Resolution(
                ipa: IPA.livesVerb,
                ruleID: "homograph.lives.verb.as-clause",
                rationale: "Verb pronunciation selected before same-clause cue “as”.")
        }

        return nil
    }

    /// Recognizes the narrow plural-noun construction “one of the <…est> lives”.
    /// The ordered, adjacent tokens avoid turning the singular-subject phrase
    /// “one of the authors lives…” into a noun.
    private static func oneOfSuperlativeLivesPhrase(
        at index: Int,
        tokens: [Token]
    ) -> String? {
        guard index >= 4, !tokens[index].startsSentence else { return nil }
        let modifier = tokens[index - 1]
        let determiner = tokens[index - 2]
        let of = tokens[index - 3]
        let one = tokens[index - 4]
        guard !modifier.startsSentence,
            !determiner.startsSentence,
            !of.startsSentence,
            modifier.lowercased.hasSuffix("est"),
            determiner.lowercased == "the",
            of.lowercased == "of",
            one.lowercased == "one"
        else {
            return nil
        }
        return "one of the \(modifier.lowercased) lives"
    }

    private static func recordResolution(at index: Int, tokens: [Token]) -> Resolution? {
        let previous = previousLowercased(tokens, index)

        // The attributive compound-noun guard ("record sales", "record labels")
        // only applies to a follower in the *same* sentence. Word tokenization
        // ignores punctuation, so without this a period between clauses
        // ("Please record. Players arrived.") would pull the next sentence's
        // noun into the guard and mis-read the verb as the noun.
        let followerIsSameSentenceCompoundNoun: Bool = {
            let followerIndex = tokens.index(after: index)
            guard followerIndex < tokens.endIndex else { return false }
            let follower = tokens[followerIndex]
            guard !follower.startsSentence else { return false }
            return recordNounCompoundFollowers.contains(follower.lowercased)
        }()

        // A strong verb signal immediately before `record` overrides that guard:
        // infinitival "to" ("designed to record sales") or a modal that is not
        // fronting a question ("We will record sales"). A sentence-initial modal
        // is question inversion where "record labels" is the subject, so it keeps
        // the attributive noun ("Should record labels pay artists?"). Requiring
        // `record` itself to be mid-sentence stops a modal in the previous
        // sentence from leaking across a boundary.
        let precederIsVerbSignal: Bool = {
            guard index > tokens.startIndex, !tokens[index].startsSentence else { return false }
            let preceder = tokens[tokens.index(before: index)]
            if ["to", "i", "we", "you", "they"].contains(preceder.lowercased) { return true }
            return recordVerbPreceders.contains(preceder.lowercased) && !preceder.startsSentence
        }()

        if followerIsSameSentenceCompoundNoun, !precederIsVerbSignal {
            let follower = tokens[tokens.index(after: index)].lowercased
            return Resolution(
                ipa: IPA.recordNoun,
                ruleID: "homograph.record.noun.compound",
                rationale: "Noun pronunciation selected before compound follower “\(follower)”.")
        }

        if let previous, recordNounPreceders.contains(previous) {
            return Resolution(
                ipa: IPA.recordNoun,
                ruleID: "homograph.record.noun.preceder",
                rationale: "Noun pronunciation selected after “\(previous)”.")
        }

        if let previous, recordVerbPreceders.contains(previous) {
            return Resolution(
                ipa: IPA.recordVerb,
                ruleID: "homograph.record.verb.preceder",
                rationale: "Verb pronunciation selected after “\(previous)”.")
        }

        if let follower = nextSameSentenceLowercased(tokens, index),
            recordVerbWhObjectFollowers.contains(follower)
        {
            return Resolution(
                ipa: IPA.recordVerb,
                ruleID: "homograph.record.verb.wh-object",
                rationale: "Verb pronunciation selected before wh-object “\(follower)”.")
        }

        return nil
    }

    private static func tokens(in text: String) -> [Token] {
        var result: [Token] = []
        var plainTextStart = text.startIndex
        var index = text.startIndex

        while index < text.endIndex {
            guard let link = MisakiPronunciationMarkup.link(in: text, startingAt: index) else {
                index = text.index(after: index)
                continue
            }

            appendTokens(
                in: plainTextStart..<link.range.lowerBound,
                of: text,
                isAuthoredLinkDisplay: false,
                to: &result)
            appendTokens(
                in: link.displayText.startIndex..<link.displayText.endIndex,
                of: text,
                isAuthoredLinkDisplay: true,
                to: &result)
            index = link.range.upperBound
            plainTextStart = index
        }

        appendTokens(
            in: plainTextStart..<text.endIndex,
            of: text,
            isAuthoredLinkDisplay: false,
            to: &result)
        return result
    }

    private static func tokens(
        in text: String,
        authoredLinks: [ContextualPronunciationDiscovery.SourceSnapshot.AuthoredLink]
    ) -> [Token] {
        var result: [Token] = []
        var plainTextStart = text.startIndex
        for link in authoredLinks {
            appendTokens(
                in: plainTextStart..<link.range.lowerBound,
                of: text,
                isAuthoredLinkDisplay: false,
                to: &result)
            appendTokens(
                in: link.displayRange,
                of: text,
                isAuthoredLinkDisplay: true,
                to: &result)
            plainTextStart = link.range.upperBound
        }
        appendTokens(
            in: plainTextStart..<text.endIndex,
            of: text,
            isAuthoredLinkDisplay: false,
            to: &result)
        return result
    }

    private static func appendTokens(
        in searchRange: Range<String.Index>,
        of text: String,
        isAuthoredLinkDisplay: Bool,
        to tokens: inout [Token]
    ) {
        let nsSearchRange = NSRange(searchRange, in: text)
        tokens.append(
            contentsOf: wordRegex.matches(in: text, range: nsSearchRange).compactMap {
                match in
                guard let range = Range(match.range, in: text) else { return nil }
                let value = String(text[range])
                return Token(
                    text: value,
                    lowercased: value.lowercased(),
                    range: range,
                    nsRange: match.range,
                    isAuthoredLinkDisplay: isAuthoredLinkDisplay,
                    startsSentence: startsSentence(before: range, in: text))
            })
    }

    /// Whether `range` begins a new sentence: scanning left from it we reach a
    /// sentence terminator (or the start of the text) before any letter/number.
    private static func startsSentence(before range: Range<String.Index>, in text: String) -> Bool {
        var index = range.lowerBound
        while index > text.startIndex {
            index = text.index(before: index)
            let character = text[index]
            if sentenceTerminators.contains(character) { return true }
            if character.isLetter || character.isNumber { return false }
        }
        return true
    }

    private static func previousLowercased(_ tokens: [Token], _ index: Int) -> String? {
        guard index > tokens.startIndex, !tokens[index].startsSentence else { return nil }
        return tokens[tokens.index(before: index)].lowercased
    }

    private static func nextLowercased(_ tokens: [Token], _ index: Int, limit: Int) -> [String] {
        guard limit > 0 else { return [] }
        var result: [String] = []
        var candidateIndex = tokens.index(after: index)
        while candidateIndex < tokens.endIndex, result.count < limit {
            let candidate = tokens[candidateIndex]
            guard !candidate.startsSentence else { break }
            result.append(candidate.lowercased)
            candidateIndex = tokens.index(after: candidateIndex)
        }
        return result
    }

    private static func nextSameSentenceLowercased(_ tokens: [Token], _ index: Int) -> String? {
        let followerIndex = tokens.index(after: index)
        guard followerIndex < tokens.endIndex else { return nil }
        let follower = tokens[followerIndex]
        guard !follower.startsSentence else { return nil }
        return follower.lowercased
    }

    private static func precedingSameSentenceLowercased(
        _ tokens: [Token],
        _ index: Int
    ) -> Set<String> {
        guard index > tokens.startIndex, !tokens[index].startsSentence else { return [] }
        var result: Set<String> = []
        var candidateIndex = tokens.index(before: index)

        while true {
            let candidate = tokens[candidateIndex]
            result.insert(candidate.lowercased)
            if candidate.startsSentence || candidateIndex == tokens.startIndex {
                return result
            }
            candidateIndex = tokens.index(before: candidateIndex)
        }
    }

    private static func isHyphenated(_ range: Range<String.Index>, in text: String) -> Bool {
        if range.lowerBound > text.startIndex {
            let previous = text[text.index(before: range.lowerBound)]
            if hyphens.contains(previous) { return true }
        }

        if range.upperBound < text.endIndex {
            let next = text[range.upperBound]
            if hyphens.contains(next) { return true }
        }

        return false
    }

}
