// SPDX-License-Identifier: GPL-3.0-or-later
import Testing

@testable import Echo

@Suite struct HomographPronunciationResolverTests {
    @Test(arguments: [
        "She was more content with her life.",
        "She felt quite content.",
        "They are not content with the answer.",
        "I am content.",
    ])
    func satisfiedContentRecognizesLinkingVerbAndModifiers(_ source: String) {
        #expect(
            HomographPronunciationResolver.apply(to: source)
                == source.replacingOccurrences(of: "content", with: "[content](/kəntˈɛnt/)"))
    }

    @Test(arguments: [
        "There is more content with images.", "The app has more content.",
        "There will be more content.", "There should be more content.",
        "There has been more content.",
    ])
    func quantityContentRemainsNoun(_ source: String) {
        #expect(
            HomographPronunciationResolver.apply(to: source)
                == source.replacingOccurrences(of: "content", with: "[content](/kˈɑntɛnt/)"))
    }

    @Test func contextualBatchMatchesSingleAnalysisWithOneTokenization() {
        let source = "I am content with this. I read it yesterday. I read every day."
        let wordStarts = [2, 6, 10]
        var operationCounts =
            HomographPronunciationResolver.ContextualAnalysisOperationCounts()

        let batch = HomographPronunciationResolver.contextualAnalyses(
            in: source,
            wordStarts: wordStarts,
            operationCounts: &operationCounts)

        for wordStart in wordStarts {
            #expect(
                batch[wordStart]
                    == HomographPronunciationResolver.contextualAnalysis(
                        in: source,
                        wordStart: wordStart))
        }
        #expect(batch[2]?.strength == .definitive)
        #expect(batch[6]?.strength == .advisory)
        #expect(batch[10]?.strength == .abstained)
        #expect(operationCounts.tokenizations == 1)
        #expect(operationCounts.tokenVisits == 13)
        #expect(operationCounts.wordSpanLookups == 3)
    }

    @Test func contextualAnalysisExposesExactSatisfiedRuleWithoutChangingRewriteBehavior() {
        let source = "I am content with the result."

        let analysis = HomographPronunciationResolver.contextualAnalysis(
            in: source,
            wordStart: 2)

        #expect(analysis.candidateID == "content.satisfied")
        #expect(analysis.ruleID == "homograph.content.adjective.copula")
        #expect(analysis.strength == .definitive)
        #expect(
            HomographPronunciationResolver.apply(to: source)
                == "I am [content](/kəntˈɛnt/) with the result.")
    }

    @Test func contextualAnalysisClassifiesCueHeuristicAndAbstentionIndependently() {
        let advisory = HomographPronunciationResolver.contextualAnalysis(
            in: "I read the book yesterday.",
            wordStart: 1)
        let abstained = HomographPronunciationResolver.contextualAnalysis(
            in: "I read every day.",
            wordStart: 1)

        #expect(advisory.candidateID == "read.past")
        #expect(advisory.ruleID == "homograph.read.past.temporal-cue")
        #expect(advisory.strength == .advisory)
        #expect(abstained.candidateID == nil)
        #expect(abstained.ruleID == nil)
        #expect(abstained.strength == .abstained)
    }

    @Test func structuredResolutionMapsRegexTokensToCanonicalWhitespaceSpan() throws {
        let source = "That can't be where this subject lives."

        let result = HomographPronunciationResolver.rewrite(to: source, blockID: "b-natural")
        let decision = try #require(result.decisionSeeds.first)

        #expect(result.text == HomographPronunciationResolver.apply(to: source))
        #expect(decision.blockID == "b-natural")
        #expect(decision.wordStart == 6)
        #expect(decision.wordEnd == 6)
        #expect(decision.normalizedWord == "lives")
        #expect(decision.sourceWord == "lives")
        #expect(decision.sourceContext == "can't be where this subject lives.")
        #expect(decision.selectedIPA == "lˈɪvz")
        #expect(decision.source == .contextualHomograph)
        #expect(decision.ruleID == "homograph.lives.verb.subject")
        #expect(
            decision.rationale
                == "Verb pronunciation selected after subject cue “subject”.")
    }

    @Test func structuredResolutionNamesCompoundNounCue() throws {
        let result = HomographPronunciationResolver.rewrite(
            to: "Should record labels pay artists?",
            blockID: "b-record")
        let decision = try #require(result.decisionSeeds.first)

        #expect(decision.wordStart == 1)
        #expect(decision.selectedIPA == "ɹˈɛkəɹd")
        #expect(decision.ruleID == "homograph.record.noun.compound")
        #expect(
            decision.rationale == "Noun pronunciation selected before compound follower “labels”.")
    }

    @Test func resolvesPastTenseReadFromTemporalContext() {
        let out = HomographPronunciationResolver.apply(to: "I read the book yesterday.")

        #expect(out == "I [read](/ɹˈɛd/) the book yesterday.")
    }

    @Test func resolvesPassiveReadAfterBeAuxiliary() {
        let out = HomographPronunciationResolver.apply(to: "The book was read aloud.")

        #expect(out == "The book was [read](/ɹˈɛd/) aloud.")
    }

    @Test func leavesPresentTenseReadUnchanged() {
        #expect(
            HomographPronunciationResolver.apply(to: "I will read the book.")
                == "I will read the book.")
        #expect(
            HomographPronunciationResolver.apply(to: "I read every day.") == "I read every day.")
    }

    @Test func resolvesLiveVerbAndAdjectiveContexts() {
        #expect(
            HomographPronunciationResolver.apply(to: "They live nearby.")
                == "They [live](/lˈɪv/) nearby.")
        #expect(
            HomographPronunciationResolver.apply(to: "People live longer with clean audio.")
                == "People [live](/lˈɪv/) longer with clean audio.")
        #expect(
            HomographPronunciationResolver.apply(to: "It was a live show.")
                == "It was a [live](/lˈIv/) show.")
        #expect(
            HomographPronunciationResolver.apply(to: "The live content shipped today.")
                == "The [live](/lˈIv/) [content](/kˈɑntɛnt/) shipped today.")
        #expect(
            HomographPronunciationResolver.apply(to: "He lost his live stock in the fire.")
                == "He lost his [live](/lˈIv/) stock in the fire.")
    }

    @Test func resolvesWeatherLinkLiveProductName() throws {
        let source = "Align requested access to the Weather Link Live data."
        let result = HomographPronunciationResolver.rewrite(
            to: source,
            blockID: "weather-link-live")
        let decision = try #require(
            result.decisionSeeds.first { $0.normalizedWord == "live" })

        #expect(
            result.text
                == "Align requested access to the Weather Link [Live](/lˈIv/) data.")
        #expect(decision.selectedIPA == "lˈIv")
        #expect(decision.ruleID == "homograph.live.product.weather-link-live")
    }

    @Test func resolvesLivesVerbAndNounContexts() {
        #expect(
            HomographPronunciationResolver.apply(to: "She lives in Halifax.")
                == "She [lives](/lˈɪvz/) in Halifax.")
        #expect(
            HomographPronunciationResolver.apply(to: "The receipt lives in the archive.")
                == "The receipt [lives](/lˈɪvz/) in the archive.")
        #expect(
            HomographPronunciationResolver.apply(to: "The receipt lives securely.")
                == "The receipt [lives](/lˈɪvz/) securely.")
        #expect(
            HomographPronunciationResolver.apply(to: "The author lives alone.")
                == "The author [lives](/lˈɪvz/) alone.")
        #expect(
            HomographPronunciationResolver.apply(to: "Their lives changed.")
                == "Their [lives](/lˈIvz/) changed.")
        #expect(
            HomographPronunciationResolver.apply(to: "Their lives in Halifax changed.")
                == "Their [lives](/lˈIvz/) in Halifax changed.")
    }

    @Test func resolvesLivesNounInDescriptiveSuperlativePhrase() throws {
        let source = "This is one of the strangest lives in the story."
        let result = HomographPronunciationResolver.rewrite(
            to: source,
            blockID: "b-lives-superlative")
        let decision = try #require(result.decisionSeeds.first)

        #expect(result.text == "This is one of the strangest [lives](/lˈIvz/) in the story.")
        #expect(decision.selectedIPA == "lˈIvz")
        #expect(decision.ruleID == "homograph.lives.noun.one-of-superlative")
        #expect(
            decision.rationale
                == "Plural-noun pronunciation selected in the descriptive superlative phrase “one of the strangest lives”."
        )
        #expect(
            HomographPronunciationResolver.apply(
                to: "His was one of the greatest lives in the story.")
                == "His was one of the greatest [lives](/lˈIvz/) in the story.")
    }

    @Test func oneOfSubjectStillUsesLivesVerb() {
        #expect(
            HomographPronunciationResolver.apply(to: "One of the machines lives in Halifax.")
                == "One of the machines [lives](/lˈɪvz/) in Halifax.")
    }

    @Test func resolvesLivesVerbInNaturalWhereAndAsContexts() {
        #expect(
            HomographPronunciationResolver.apply(
                to: "That gap is where this entire subject lives.")
                == "That gap is where this entire subject [lives](/lˈɪvz/).")
        #expect(
            HomographPronunciationResolver.apply(
                to: "That gap is where this entire subject lives today.")
                == "That gap is where this entire subject [lives](/lˈɪvz/) today.")
        #expect(
            HomographPronunciationResolver.apply(
                to: "Every token lives as a point in semantic space.")
                == "Every token [lives](/lˈɪvz/) as a point in semantic space.")
        #expect(
            HomographPronunciationResolver.apply(to: "This is where hype lives.")
                == "This is where hype [lives](/lˈɪvz/).")
    }

    @Test func naturalLivesCuesPreserveNounAndAdjectiveReadings() {
        #expect(
            HomographPronunciationResolver.apply(to: "Their lives changed.")
                == "Their [lives](/lˈIvz/) changed.")
        #expect(
            HomographPronunciationResolver.apply(to: "Their lives as immigrants changed.")
                == "Their [lives](/lˈIvz/) as immigrants changed.")
        #expect(
            HomographPronunciationResolver.apply(to: "The live argument continued.")
                == "The [live](/lˈIv/) argument continued.")
    }

    @Test func previousTokenCuesDoNotCrossSentenceBoundaries() {
        #expect(
            HomographPronunciationResolver.apply(to: "Many. Lives here.")
                == "Many. [Lives](/lˈɪvz/) here.")
        #expect(
            HomographPronunciationResolver.apply(to: "They. Live show.")
                == "They. [Live](/lˈIv/) show.")
        #expect(
            HomographPronunciationResolver.apply(to: "Please. Record labels survived.")
                == "Please. [Record](/ɹˈɛkəɹd/) labels survived.")
    }

    @Test func genericFollowerCuesDoNotCrossSentenceBoundaries() {
        #expect(
            HomographPronunciationResolver.apply(to: "I read. Yesterday was quiet.")
                == "I read. Yesterday was quiet.")
    }

    @Test func livesWhereCueDoesNotCrossSentenceBoundary() {
        #expect(
            HomographPronunciationResolver.apply(to: "Where should we meet? Lives changed.")
                == "Where should we meet? Lives changed.")
    }

    @Test func livesWhereCuePreservesPluralNouns() {
        #expect(
            HomographPronunciationResolver.apply(to: "They remember where lives were lost.")
                == "They remember where lives were lost.")
        #expect(
            HomographPronunciationResolver.apply(
                to: "They remember where innocent lives were lost.")
                == "They remember where innocent lives were lost.")
        #expect(
            HomographPronunciationResolver.apply(
                to: "That gap is where this subject matters. Innocent lives were lost.")
                == "That gap is where this subject matters. Innocent lives were lost.")
        #expect(
            HomographPronunciationResolver.apply(
                to: "They report where civilian lives remain in danger.")
                == "They report where civilian lives remain in danger.")
        #expect(
            HomographPronunciationResolver.apply(
                to: "They ask where innocent lives still matter.")
                == "They ask where innocent lives still matter.")
        #expect(
            HomographPronunciationResolver.apply(
                to: "The study shows where lives can be saved.")
                == "The study shows where lives can be saved.")
        #expect(
            HomographPronunciationResolver.apply(
                to: "They ask where innocent lives today matter.")
                == "They ask where innocent lives today matter.")
    }

    @Test func resolvesRecordVerbNounAndCompoundNounContexts() {
        #expect(
            HomographPronunciationResolver.apply(to: "Please record the result.")
                == "Please [record](/ɹəkˈɔɹd/) the result.")
        #expect(
            HomographPronunciationResolver.apply(to: "Review the record before restart.")
                == "Review the [record](/ɹˈɛkəɹd/) before restart.")
        #expect(
            HomographPronunciationResolver.apply(to: "Record sales increased.")
                == "[Record](/ɹˈɛkəɹd/) sales increased.")
        #expect(
            HomographPronunciationResolver.apply(to: "Should record labels pay artists?")
                == "Should [record](/ɹˈɛkəɹd/) labels pay artists?")
    }

    @Test func recordRulesStayNarrowAndRespectCompoundPrecedence() {
        #expect(
            HomographPronunciationResolver.apply(to: "We should record tomorrow.")
                == "We should [record](/ɹəkˈɔɹd/) tomorrow.")
        #expect(
            HomographPronunciationResolver.apply(to: "We need to record tomorrow.")
                == "We need to [record](/ɹəkˈɔɹd/) tomorrow.")
        #expect(
            HomographPronunciationResolver.apply(to: "A record player waits nearby.")
                == "A [record](/ɹˈɛkəɹd/) player waits nearby.")
        #expect(
            HomographPronunciationResolver.apply(to: "Could record stores survive?")
                == "Could [record](/ɹˈɛkəɹd/) stores survive?")
        #expect(
            HomographPronunciationResolver.apply(to: "Record players became popular.")
                == "[Record](/ɹˈɛkəɹd/) players became popular.")
        #expect(
            HomographPronunciationResolver.apply(to: "They discussed record yesterday.")
                == "They discussed record yesterday.")
        #expect(
            HomographPronunciationResolver.apply(to: "This recording is clear.")
                == "This recording is clear.")
    }

    @Test func resolvesRecordVerbBeforeImmediateWhObjects() {
        #expect(
            HomographPronunciationResolver.apply(to: "Listen and record whatever it says.")
                == "Listen and [record](/ɹəkˈɔɹd/) whatever it says.")
        #expect(
            HomographPronunciationResolver.apply(to: "Record what the caller says.")
                == "[Record](/ɹəkˈɔɹd/) what the caller says.")
    }

    @Test func recordWhObjectCuePreservesNounsAndSentenceBoundaries() {
        #expect(
            HomographPronunciationResolver.apply(to: "The record labels agreed.")
                == "The [record](/ɹˈɛkəɹd/) labels agreed.")
        #expect(
            HomographPronunciationResolver.apply(to: "Vinyl and record stores survived.")
                == "Vinyl and [record](/ɹˈɛkəɹd/) stores survived.")
        #expect(
            HomographPronunciationResolver.apply(
                to: "Keep a record. Whatever happens matters.")
                == "Keep a [record](/ɹˈɛkəɹd/). Whatever happens matters.")
    }

    @Test func recordWhObjectCueDoesNotConsumeRelativeClauses() {
        #expect(
            HomographPronunciationResolver.apply(
                to: "They cited the world record, which still stands.")
                == "They cited the world record, which still stands.")
    }

    @Test func recordVerbBeatsCompoundNounGuardAfterVerbSignals() {
        // BUG 1: the compound-noun guard must not force the noun when `record`
        // is clearly the verb. Infinitival "to" is an unambiguous verb signal.
        #expect(
            HomographPronunciationResolver.apply(
                to: "The service is designed to record sales events.")
                == "The service is designed to [record](/ɹəkˈɔɹd/) sales events.")
        // A modal that is not fronting a question keeps the verb reading too.
        #expect(
            HomographPronunciationResolver.apply(to: "We will record sales today.")
                == "We will [record](/ɹəkˈɔɹd/) sales today.")
        // Tokenization ignores sentence boundaries, so the next sentence's noun
        // must not be treated as a compound-noun follower across the period.
        #expect(
            HomographPronunciationResolver.apply(to: "Please record. Players arrived.")
                == "Please [record](/ɹəkˈɔɹd/). Players arrived.")
        // Infinitival "to" is a verb signal even when it opens the sentence.
        #expect(
            HomographPronunciationResolver.apply(to: "To record sales, hire staff.")
                == "To [record](/ɹəkˈɔɹd/) sales, hire staff.")
        // A modal in the previous sentence must not leak across the boundary and
        // flip a genuinely attributive "record sales" into the verb.
        #expect(
            HomographPronunciationResolver.apply(to: "We should. Record sales fell.")
                == "We should. [Record](/ɹˈɛkəɹd/) sales fell.")

        // Regressions — genuine attributive compound nouns stay nouns.
        #expect(
            HomographPronunciationResolver.apply(to: "Record sales increased.")
                == "[Record](/ɹˈɛkəɹd/) sales increased.")
        #expect(
            HomographPronunciationResolver.apply(to: "Should record labels pay artists?")
                == "Should [record](/ɹˈɛkəɹd/) labels pay artists?")
        #expect(
            HomographPronunciationResolver.apply(to: "Could record stores survive?")
                == "Could [record](/ɹˈɛkəɹd/) stores survive?")
    }

    // A bare word before a guarded compound ("systems record sales") is
    // indistinguishable from a common attributive noun phrase ("major record
    // labels", "local record stores"): both are just <word> + compound. The
    // resolver deliberately keeps the noun for these rather than risk verbing
    // the far more common attributive phrases. Only an explicit verb signal
    // ("to", a mid-sentence modal) or a sentence boundary flips it.
    @Test func recordCompoundGuardStaysConservativeForAmbiguousPreceders() {
        #expect(
            HomographPronunciationResolver.apply(to: "Major record labels dominate.")
                == "Major [record](/ɹˈɛkəɹd/) labels dominate.")
        #expect(
            HomographPronunciationResolver.apply(to: "Local record stores closed.")
                == "Local [record](/ɹˈɛkəɹd/) stores closed.")
        #expect(
            HomographPronunciationResolver.apply(to: "Our systems record sales data.")
                == "Our systems [record](/ɹˈɛkəɹd/) sales data.")
    }

    @Test func resolvesContentNounAndSatisfiedContexts() {
        #expect(
            HomographPronunciationResolver.apply(to: "Content I found useful stayed here.")
                == "[Content](/kˈɑntɛnt/) I found useful stayed here.")
        #expect(
            HomographPronunciationResolver.apply(to: "The audio content shipped today.")
                == "The audio [content](/kˈɑntɛnt/) shipped today.")
        #expect(
            HomographPronunciationResolver.apply(to: "I am content with this narration.")
                == "I am [content](/kəntˈɛnt/) with this narration.")
    }

    @Test func contentNounBeatsSatisfiedGuardUnlessCopulaPreceder() {
        // BUG 2: "content to/with" is a noun unless a copula/linking verb
        // precedes. A following "to"/"with" alone must not flip it to the
        // satisfied adjective.
        #expect(
            HomographPronunciationResolver.apply(to: "Add content to the page.")
                == "Add content to the page.")
        #expect(
            HomographPronunciationResolver.apply(to: "The content with images loaded slowly.")
                == "The [content](/kˈɑntɛnt/) with images loaded slowly.")
        #expect(
            HomographPronunciationResolver.apply(to: "Upload content to the server.")
                == "Upload content to the server.")

        // Regression — a copula preceder keeps the satisfied adjective reading.
        #expect(
            HomographPronunciationResolver.apply(to: "I am content with this narration.")
                == "I am [content](/kəntˈɛnt/) with this narration.")
    }

    @Test func resolvesResumeDocumentContextsWithoutBreakingVerbContexts() {
        #expect(
            HomographPronunciationResolver.apply(to: "The resumes are attached.")
                == "The [resumes](/ɹˈɛzʊmˌAz/) are attached.")
        #expect(
            HomographPronunciationResolver.apply(to: "Resumes.")
                == "[Resumes](/ɹˈɛzʊmˌAz/).")
        #expect(
            HomographPronunciationResolver.apply(to: "The book resumes here.")
                == "The book resumes here.")
        #expect(
            HomographPronunciationResolver.apply(to: "Playback will resume shortly.")
                == "Playback will resume shortly.")
    }

    @Test func resolvesAccentedResumeDocuments() {
        #expect(
            HomographPronunciationResolver.apply(to: "Her résumé is attached.")
                == "Her [résumé](/ɹˈɛzʊmˌA/) is attached.")
        #expect(
            HomographPronunciationResolver.apply(to: "The résumés were submitted.")
                == "The [résumés](/ɹˈɛzʊmˌAz/) were submitted.")
    }

    @Test func resolvesArithmeticNounStressButKeepsTechnicalAdjectiveContexts() {
        #expect(
            HomographPronunciationResolver.apply(to: "Arithmetic is hard.")
                == "[Arithmetic](/əɹˈɪθmətˌɪk/) is hard.")
        #expect(
            HomographPronunciationResolver.apply(to: "The arithmetic mean is useful.")
                == "The arithmetic mean is useful.")
    }

    @Test func doesNotRewriteHyphenatedCompounds() {
        let text = "This is a read-only live-in record-breaking setup."

        #expect(HomographPronunciationResolver.apply(to: text) == text)
    }

    @Test func existingPronunciationOverrideWins() {
        let overridden = PronunciationOverrides(entries: ["read": "ɹˈid"])
            .apply(to: "I read the book yesterday.")

        #expect(
            HomographPronunciationResolver.apply(to: overridden)
                == "I [read](/ɹˈid/) the book yesterday.")
    }

    @Test func existingPronunciationOverrideProducesNoContextualDecision() {
        let overridden = PronunciationOverrides(entries: ["read": "ɹˈid"])
            .apply(to: "I read the book yesterday.")

        let result = HomographPronunciationResolver.rewrite(
            to: overridden,
            blockID: "b-read")

        #expect(result.text == overridden)
        #expect(result.decisionSeeds.isEmpty)
    }

    @Test func authoredRecordLinkWinsOverContextualRules() {
        let text = "Please [record](/ɹˈɛkəɹd/) the result."

        #expect(HomographPronunciationResolver.apply(to: text) == text)
    }

    @Test func authoredLinkDisplayContributesContextWithoutLeakingIPA() {
        #expect(
            HomographPronunciationResolver.apply(to: "[Please](/plˈiz/) record the result.")
                == "[Please](/plˈiz/) [record](/ɹəkˈɔɹd/) the result.")
        #expect(
            HomographPronunciationResolver.apply(to: "[The](/ðə/) record changed.")
                == "[The](/ðə/) [record](/ɹˈɛkəɹd/) changed.")
    }

    @Test func resolvedLinksReachG2PAsExactPhonemes() {
        let text = HomographPronunciationResolver.apply(to: "I read the book yesterday.")
        let phonemes = KokoroG2P().phonemes(for: text)

        #expect(phonemes.contains("ɹˈɛd"))
    }

    @Test func reportedEasyWordRepairsReachG2PAsExactPhonemes() {
        let text = HomographPronunciationResolver.apply(
            to: "The resumes are attached. Arithmetic is hard.")
        let phonemes = KokoroG2P().phonemes(for: text)

        #expect(phonemes.contains("ɹˈɛzʊmˌAz"))
        #expect(phonemes.contains("əɹˈɪθmətˌɪk"))
    }
}
