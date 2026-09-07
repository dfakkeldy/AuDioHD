// SPDX-License-Identifier: GPL-3.0-or-later
import Testing

@testable import Echo

@Suite struct TextNormalizerTests {
    @Test func modelNormalizationOnlySplitsExactIdentifierOccurrences() {
        let text = "Use PCalc, not AudioPlayer."
        let result = FMNormalizer.applying(
            [
                .init(wordIndex: 1, source: "PCalc,", spoken: "P Calc,"),
                .init(wordIndex: 3, source: "AudioPlayer.", spoken: "Audio Player."),
            ], to: text)
        #expect(result == "Use P Calc, not Audio Player.")
    }

    @Test func modelNormalizationProtectsAuthoredPronunciations() {
        let text = "Use [PCalc](/pˈi/) now."
        #expect(
            FMNormalizer.applying(
                [
                    .init(wordIndex: 1, source: "[PCalc](/pˈi/)", spoken: "[P Calc](/pˈi/)")
                ], to: text) == text)
    }

    @Test func modelNormalizationRejectsMeaningChangesAndWrongAddresses() {
        let text = "Do not use PCalc."
        for substitutions: [FMNormalizer.Substitution] in [
            [.init(wordIndex: 1, source: "not", spoken: "")],
            [.init(wordIndex: 3, source: "PCalc.", spoken: "Calculator.")],
            [.init(wordIndex: 2, source: "PCalc.", spoken: "P Calc.")],
        ] {
            #expect(FMNormalizer.applying(substitutions, to: text) == text)
        }
    }

    @Test(arguments: [
        ("Dr. Smith arrived.", "Doctor Smith arrived."),
        ("St. Mary on St. James St.", "Saint Mary on Saint James Street."),
        ("It cost 1,200 dollars.", "It cost one thousand two hundred dollars."),
        ("See e.g. chapter 3.", "See for example chapter 3."),
        // The comma keeps the dash's own whitespace-delimited slot (see
        // `spacedDashKeepsTheAuthoredWordCount`), so it stays a standalone token.
        ("A pause — then silence.", "A pause , then silence."),
        ("A pause – then silence.", "A pause , then silence."),  // spaced en dash
        ("A pause - then silence.", "A pause , then silence."),  // spaced ASCII hyphen
        ("Chapter IV begins.", "Chapter 4 begins."),
        ("It served 6,000 people.", "It served six thousand people."),
        ("The launch reached 10,000 readers.", "The launch reached ten thousand readers."),
        ("Completion hit 100%.", "Completion hit one hundred percent."),
        (
            "A 1.6% lift became 2500%.",
            "A one point six percent lift became two thousand five hundred percent."
        ),
        ("Mr. Smith met Mrs. Jones.", "Mister Smith met Missus Jones."),
        ("Prof. Adams, i.e. the chair, spoke.", "Professor Adams, that is the chair, spoke."),
        ("Cats vs. dogs, birds, etc. live here.", "Cats versus dogs, birds, et cetera live here."),
    ])
    func normalizes(_ input: String, _ expected: String) {
        #expect(TextNormalizer.normalize(input) == expected)
    }

    @Test(arguments: [
        ("1st", "first"), ("2nd", "second"), ("3rd", "third"), ("4th", "fourth"),
        ("11th", "eleventh"), ("21st", "twenty-first"), ("42nd", "forty-second"),
        ("100th", "one hundredth"),
    ])
    func expandsOrdinals(_ input: String, _ expected: String) {
        #expect(TextNormalizer.normalize(input) == expected)
    }

    @Test(arguments: [
        "$5", "$5.25", "$1.00", "$0.99", "$100 billion", "$5.50 million",
        "-$2 billion", "+£1 billion", "£1,234.56", "€2 trillion", "$2-3", "£2-3", "$2 bn", "€2 bn",
        "$2 quadrillion",
    ])
    func preservesCurrencyCandidatesForSemanticG2P(_ input: String) {
        #expect(TextNormalizer.normalize(input) == input)
    }

    @Test func normalizesProseAroundProtectedCurrencyCandidate() {
        #expect(
            TextNormalizer.normalize("Dr. Ada reported $100 billion at 3:30.")
                == "Doctor Ada reported $100 billion at three thirty."
        )
    }

    @Test(arguments: [
        ("Meet at 3:30.", "Meet at three thirty."),
        ("The bell rang at 12:05.", "The bell rang at twelve oh five."),
        ("Open from 9:00 to 10:15.", "Open from nine o'clock to ten fifteen."),
        ("3:07", "three oh seven"),
    ])
    func expandsProseFriendlyTimes(_ input: String, _ expected: String) {
        #expect(TextNormalizer.normalize(input) == expected)
    }

    @Test(arguments: [
        ("John 3:16 stays a citation.", "John 3:16 stays a citation."),
        ("Use a 3:30 ratio.", "Use a 3:30 ratio."),
        ("https://example.com/3:30/path", "https://example.com/3:30/path"),
    ])
    func leavesAmbiguousTimesAlone(_ input: String, _ expected: String) {
        #expect(TextNormalizer.normalize(input) == expected)
    }

    @Test(arguments: [
        ("Updated on 2026-06-30.", "Updated on June thirtieth, twenty twenty-six."),
        (
            "The archive starts on 1999-01-05.",
            "The archive starts on January fifth, nineteen ninety-nine."
        ),
    ])
    func expandsUnambiguousISODates(_ input: String, _ expected: String) {
        #expect(TextNormalizer.normalize(input) == expected)
    }

    @Test(arguments: [
        ("In 1999, the archive moved.", "In nineteen ninety-nine, the archive moved."),
        ("Since 2001, the project changed.", "Since two thousand one, the project changed."),
        ("By 2026, the tool matured.", "By twenty twenty-six, the tool matured."),
        ("The year 1905 was cold.", "The year nineteen oh five was cold."),
    ])
    func expandsLikelyStandaloneYears(_ input: String, _ expected: String) {
        #expect(TextNormalizer.normalize(input) == expected)
    }

    @Test(arguments: [
        ("A$5 stays unsupported.", "A$5 stays unsupported."),
        ("The malformed $5.2 stays literal.", "The malformed $5.2 stays literal."),
        ("The odd $5% token stays literal.", "The odd $5% token stays literal."),
        ("The 1999 files remain.", "The 1999 files remain."),
        ("The 2026-13-30 draft stays literal.", "The 2026-13-30 draft stays literal."),
        ("Version 2026-06 stays literal.", "Version 2026-06 stays literal."),
    ])
    func leavesAmbiguousNaturalnessFormsAlone(_ input: String, _ expected: String) {
        #expect(TextNormalizer.normalize(input) == expected)
    }

    @Test func malformedDollarGroupingRemainsForSemanticAudit() {
        let input = "The malformed $1,23 stays literal."
        #expect(TextNormalizer.normalize(input) == input)
    }

    /// Word-level read-along indexes timings by the SOURCE block's
    /// whitespace-delimited words, so normalization must never add or drop one.
    /// A spaced dash is its own authored word; collapsing it onto the previous
    /// word ("heard —" → "heard,") made the rendered text one word shorter than
    /// the source and cost that whole block its word timings.
    @Test(
        arguments: [
            "The seam has to be heard — even when it cannot be seen.",
            "The seam has to be heard – even when it cannot be seen.",
            "The seam has to be heard - even when it cannot be seen.",
        ])
    func spacedDashKeepsTheAuthoredWordCount(_ input: String) {
        let normalized = TextNormalizer.normalize(input)
        #expect(
            WordTokenizer.words(in: normalized).count
                == WordTokenizer.words(in: input).count)
        #expect(WordTokenizer.words(in: normalized).map(String.init)[6] == ",")
    }

    @Test func leavesIntraWordHyphenForTheG2P() {
        // A hyphenated compound (no surrounding spaces) is NOT a sentence pause —
        // it must pass through untouched so the G2P reads it as a word break.
        #expect(TextNormalizer.normalize("a rough-and-ready fix") == "a rough-and-ready fix")
    }

    @Test func expandsThousandsSeparatedNumbersToWords() {
        #expect(
            TextNormalizer.normalize("12,345,678")
                == "twelve million, three hundred and forty-five thousand, six hundred and seventy-eight"
        )
    }

    @Test(arguments: [
        ("World War II ended.", "World War 2 ended."),
        ("Part IV opens quietly.", "Part 4 opens quietly."),
        ("Act V begins now.", "Act 5 begins now."),
        ("Volume III gathers notes.", "Volume 3 gathers notes."),
        ("Henry VIII arrived.", "Henry the Eighth arrived."),
        ("Elizabeth II arrived.", "Elizabeth the Second arrived."),
        ("Louis XIV arrived.", "Louis the Fourteenth arrived."),
        ("George V arrived.", "George the Fifth arrived."),
    ])
    func normalizesCommonRomanNumeralBookContexts(_ input: String, _ expected: String) {
        #expect(TextNormalizer.normalize(input) == expected)
    }

    @Test(arguments: [
        ("Cats vs. dogs. Birds follow.", "Cats versus dogs. Birds follow."),
        ("Bring stamps, etc. The next day.", "Bring stamps, et cetera. The next day."),
        ("Main St. Their prices rose.", "Main Street. Their prices rose."),
        ("Old St. Paul's was rebuilt.", "Old Saint Paul's was rebuilt."),
        ("Old St. Paul’s was rebuilt.", "Old Saint Paul’s was rebuilt."),
        ("Old St. Paul's...", "Old Saint Paul's..."),
        ("Old St. Paul’s...", "Old Saint Paul’s..."),
        ("Yankees vs. Red Sox tonight.", "Yankees versus Red Sox tonight."),
        ("See e.g. Appendix A.", "See for example Appendix A."),
    ])
    func preservesSentenceEndingPeriodsWhenExpandingAbbreviations(
        _ input: String,
        _ expected: String
    ) {
        #expect(TextNormalizer.normalize(input) == expected)
    }

    @Test(arguments: [
        ("1,000th", "one thousandth"),
        ("12,345th", "twelve thousand, three hundred and forty-fifth"),
    ])
    func expandsCommaGroupedOrdinals(_ input: String, _ expected: String) {
        #expect(TextNormalizer.normalize(input) == expected)
    }

    /// Abbreviations that stand for a whole word must be spelled out before
    /// G2P. Left literal, `km` and `hrs` phonemize to the vowelless `km` and
    /// `hɹs` — consonant clusters the voice physically cannot say — while
    /// `Feb.` truncated to "feb" and `approx.` was read aloud as "approks".
    @Test(arguments: [
        ("Mt. Everest rose ahead.", "Mount Everest rose ahead."),
        ("The trail ran 40 km north.", "The trail ran 40 kilometers north."),
        ("The walk took 3 hrs.", "The walk took 3 hours."),
        ("Snow fell in Feb. 1987.", "Snow fell in February 1987."),
        ("It weighed approx. 40 pounds.", "It weighed approximately 40 pounds."),
    ])
    func expandsUnpronounceableAbbreviations(_ input: String, _ expected: String) {
        #expect(TextNormalizer.normalize(input) == expected)
    }

    /// A unit reads as a plural unless exactly one of it is being counted, so
    /// "1 km" cannot become "one kilometers". The singular is keyed to a
    /// standalone `1`; the `1` inside a longer number does not count.
    @Test(arguments: [
        ("Only 1 km remained.", "Only 1 kilometer remained."),
        ("Only 2 km remained.", "Only 2 kilometers remained."),
        ("Only 21 km remained.", "Only 21 kilometers remained."),
        ("It ran 1,200 km north.", "It ran one thousand two hundred kilometers north."),
    ])
    func picksUnitNumberFromTheCountBeforeIt(_ input: String, _ expected: String) {
        #expect(TextNormalizer.normalize(input) == expected)
    }

    /// Months whose abbreviation collides with a real lexicon word are the
    /// quietest instance of this bug: `Mar.` resolves confidently to "mar"
    /// and `Sept.` to "sept", so they never raise a G2P fallback the audit
    /// can surface — they simply narrate the wrong word.
    @Test(arguments: [
        ("Mar. 3 was cold.", "March 3 was cold."),
        ("Sept. 9 arrived.", "September 9 arrived."),
        ("Jun. 1 opened the season.", "June 1 opened the season."),
        ("Jan. 4 stayed dark.", "January 4 stayed dark."),
        ("Dec. 25 came quickly.", "December 25 came quickly."),
    ])
    func expandsMonthsThatSilentlyResolveToTheWrongWord(_ input: String, _ expected: String) {
        #expect(TextNormalizer.normalize(input) == expected)
    }

    /// Knowing when NOT to fire is half the feature. Every entry here is a
    /// form some abbreviation table would expand, and every expansion would
    /// corrupt ordinary prose.
    ///
    /// The month cases are why a day or year is required: outside date
    /// position, `Jan.` is a person's name and `Aug.` cannot be told from a
    /// sentence ending on an abbreviation. "The Sun. It burns." is the
    /// sharpest of all — capitalised, sentence-final, entirely innocent.
    @Test(arguments: [
        "The Sun. It burns.",
        "He sat. Then rose.",
        "Come in. The door is open.",
        "Say no. Then leave.",
        "It took 5 min. Then it ended.",
        "I spoke with Jan. She agreed.",
        "Deliveries resume in Aug.",
        "The thaw came late in Feb. The snow stayed.",
        "The KM ratio held.",
        "Set mt to zero.",
        "The 40km marker passed.",
        "An hr later, nothing.",
        "The mount was steep.",
    ])
    func leavesAmbiguousAbbreviationFormsAlone(_ input: String) {
        #expect(TextNormalizer.normalize(input) == input)
    }

    /// The load-bearing invariant: word-level read-along indexes timings by the
    /// SOURCE block's whitespace-delimited words, so an expansion that changes
    /// the token count costs that block every word timing it had. Each of these
    /// substitutes one authored word for exactly one spoken word.
    @Test(arguments: [
        "Mt. Everest rose ahead.",
        "The trail ran 40 km north.",
        "The walk took 3 hrs.",
        "Snow fell in Feb. 1987.",
        "It weighed approx. 40 pounds.",
        "Only 1 km remained.",
        // The probe sentence that surfaced every case at once.
        "Dr. Almond wrote to Mt. Pearl on Feb. 2. St. John's is 3 hrs away by road, approx. 240 km.",
    ])
    func abbreviationExpansionKeepsTheAuthoredWordCount(_ input: String) {
        let normalized = TextNormalizer.normalize(input)
        #expect(
            WordTokenizer.words(in: normalized).count
                == WordTokenizer.words(in: input).count)
    }

    @Test func leavesPlainProseUnchanged() {
        #expect(TextNormalizer.normalize("The quick brown fox.") == "The quick brown fox.")
    }

    @Test(arguments: [
        "Visit https://example.com/path?x=1.",
        // A unit symbol is a word only in prose. Inside a path or a compound
        // unit it is a path segment, so it must stay literal.
        "Visit https://example.com/km/path.",
        "Read docs/hrs/index.html for the schedule.",
        "The dial read 90 km/h steadily.",
        "Email me@example.com before launch.",
        "Run echo-cli qa --work-dir /tmp/render.",
        "Keep rough-and-ready and sourceBlockID stable.",
    ])
    func leavesCodeURLsAndEmailLikeTextStable(_ input: String) {
        #expect(TextNormalizer.normalize(input) == input)
    }
}
