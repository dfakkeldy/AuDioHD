import Foundation
import Testing
@testable import MisakiSwift

@Test(arguments: [
  (20, "twenty"),
  (21, "twenty-one"),
  (22, "twenty-two"),
  (29, "twenty-nine"),
])
func cardinalTwentyRange(value: Int, expected: String) {
  #expect(EnglishNum2Word().convert(Decimal(value)) == expected)
}

@Test(arguments: [
  (1_000_000, "one million"),
  (1_000_000_000, "one billion"),
])
func cardinalHighNumberCards(value: Int, expected: String) {
  #expect(EnglishNum2Word().convert(Decimal(value)) == expected)
}

let texts: [(originalText: String, requiredPhonemes: [String])] = [
  (
    "[Misaki](/misˈɑki/) is a G2P engine designed for [Kokoro](/kˈOkəɹO/) models.",
    ["misˈɑki", "kˈOkəɹO"]
  ),
  (
    "“To James Mortimer, M.R.C.S., from his friends of the C.C.H.,” was engraved upon it, with the date “1884.”",
    []
  )
]

@Test func testStrings_BritishPhonetization() async throws {
  let englishG2P = EnglishG2P(british: true)
  
  for pair in texts {
    let result = englishG2P.phonemize(text: pair.originalText).0
    #expect(!result.isEmpty)
    #expect(!result.contains("❓"))
    for phoneme in pair.requiredPhonemes {
      #expect(result.contains(phoneme))
    }
  }
}

@Test func testStrings_AmericanPhonetization() async throws {
  let englishG2P = EnglishG2P(british: false)

  for pair in texts {
    let result = englishG2P.phonemize(text: pair.originalText).0
    #expect(!result.isEmpty)
    #expect(!result.contains("❓"))
    for phoneme in pair.requiredPhonemes {
      #expect(result.contains(phoneme))
    }
  }
}

// Retokenize Currency Index Fix Tests
@Test func testRetokenize_CurrencyWithFollowingTokens() async throws {
  let englishG2P = EnglishG2P(british: false)
  let (result, _) = englishG2P.phonemize(text: "$50 is the price for this item")
  #expect(!result.isEmpty)
  #expect(result.contains("dˈɑləɹ"))  // "dollar" phoneme should be present
}

// Currency appearing mid-sentence with multiple tokens before and after
@Test func testRetokenize_CurrencyInMiddleOfSentence() async throws {
  let englishG2P = EnglishG2P(british: false)
  let (result, _) = englishG2P.phonemize(text: "The total cost was $100 and we paid it yesterday")
  #expect(!result.isEmpty)
  #expect(result.contains("dˈɑləɹz"))  // American "dollar" phoneme
}

// Multiple currency symbols trigger the currency code path multiple times
@Test func testRetokenize_MultipleCurrenciesInText() async throws {
  let englishG2P = EnglishG2P(british: false)
  let (result, _) = englishG2P.phonemize(text: "I exchanged $200 for €150 at the bank today")
  #expect(!result.isEmpty)
  #expect(result.contains("dˈɑləɹ"))  // "dollar" phoneme
  #expect(result.contains("jˈʊɹOz"))  // "euro" phoneme
}

@Test func testPastTense_IedVerbsUseKnownYStem() async throws {
  let englishG2P = EnglishG2P(british: false)
  let result = englishG2P.phonemizeWithMetadata(text: "verified")

  #expect(result.phonemes == "vˈɛɹəfˌId")
  #expect(result.fallbackHits.isEmpty)
}

@Test func testCamelCaseCompoundsPreserveKnownWordBreaks() async throws {
  let englishG2P = EnglishG2P(british: false)
  let result = englishG2P.phonemizeWithMetadata(text: "CarPlay")

  #expect(result.phonemes == "kˈɑɹ plˈA")
  #expect(result.fallbackHits.isEmpty)
}

@Test func testCamelCaseDoesNotSplitMcSurnamePrefix() async throws {
  let englishG2P = EnglishG2P(british: false)
  let result = englishG2P.phonemizeWithMetadata(text: "McDonald")

  #expect(!result.phonemes.contains(" "))
}

@Test func testClosedCompoundResolutionRejectsDerivedAndAccidentalSplits() async throws {
  let englishG2P = EnglishG2P(british: false)

  for word in [
    "admittable", "abandonable", "acerate", "cancellate", "camerate", "adherescent",
  ] {
    let result = englishG2P.phonemizeWithMetadata(text: word)
    let hit = try #require(result.fallbackHits.first)
    #expect(hit.word.lowercased() == word)
    #expect(hit.phonemes == EnglishFallbackNetwork.phonemes(for: word))
  }
}

@Test func testClosedCompoundsReuseKnownLexicalComponents() async throws {
  let englishG2P = EnglishG2P(british: false)

  for word in ["filesystem", "webpage", "knowledgebase", "questionmachine", "worktree"] {
    let result = englishG2P.phonemizeWithMetadata(text: word)
    let hit = try #require(result.fallbackHits.first)
    #expect(hit.word.lowercased() == word)
    #expect(hit.phonemes != EnglishFallbackNetwork.phonemes(for: word))
  }
}

/// A closed compound whose *head* is a productive constituent must resolve even
/// when its modifier is not itself a curated root — the gate used to consult the
/// left component only, so `fog`/`tide`/`boat` compounds fell through to the
/// whole-token OOV guess (dropping the `g` of `fogline` entirely).
@Test func testClosedCompoundsResolveFromProductiveHeads() async throws {
  let englishG2P = EnglishG2P(british: false)
  let expected = [
    "fogline": "fˈɔɡlˌIn",
    "tidewatcher": "tˈIdwˌɑʧəɹ",
    "boatlight": "bˈOtlˌIt",
  ]

  for (word, ipa) in expected {
    let result = englishG2P.phonemizeWithMetadata(text: word)
    let hit = try #require(result.fallbackHits.first, Comment(rawValue: word))
    #expect(hit.word.lowercased() == word)
    #expect(hit.phonemes == ipa, Comment(rawValue: "\(word) phonemes"))
    #expect(result.tokens.first?.`_`.compoundComponents != nil)
  }
}

/// The head set is semantic evidence, so it must never contain a derivational
/// suffix: `bookless` is `book` + the suffix `-less`, not a compound with the
/// head `less`. Those words still resolve through the left-constituent path,
/// which measurably beats the whole-token guess; what must not happen is a
/// suffix qualifying a split on its own.
@Test func testProductiveHeadsExcludeDerivationalSuffixes() async throws {
  let suffixes: Set<String> = [
    "able", "ally", "ance", "ate", "ence", "hood", "ible", "ing", "ion", "ism",
    "ist", "ity", "ive", "less", "like", "ling", "ment", "ness", "ous", "ward",
    "wise",
  ]

  #expect(Lexicon.compoundHeads.intersection(suffixes).isEmpty)
  // A head shorter than four characters can never satisfy the minimum
  // right-component length, so it would be dead weight in the set.
  #expect(Lexicon.compoundHeads.allSatisfy { $0.count >= 4 })
}

/// Two qualifying splits are not evidence of anything — the resolver must
/// abstain rather than pick one, which is what keeps the widened gate honest.
@Test func testClosedCompoundResolutionAbstainsOnAmbiguousSplits() async throws {
  let englishG2P = EnglishG2P(british: false)

  for word in ["carpetshoprope", "handbookstone"] {
    let result = englishG2P.phonemizeWithMetadata(text: word)
    let hit = try #require(result.fallbackHits.first, Comment(rawValue: word))
    #expect(
      hit.phonemes == EnglishFallbackNetwork.phonemes(for: word),
      Comment(rawValue: "\(word) has multiple qualifying splits"))
  }
}

@Test func testMultiwordExplicitPronunciationIsAppliedOnce() async throws {
  let englishG2P = EnglishG2P(british: false)
  let phrasePhonemes = "nˈu jˈɔɹk"
  let result = englishG2P.phonemizeWithMetadata(
    text: "Visit [New York](/nˈu jˈɔɹk/) today."
  )

  #expect(result.phonemes.components(separatedBy: phrasePhonemes).count == 2)
  let phraseToken = try #require(result.tokens.first { $0.text == "New York" })
  #expect(phraseToken.phonemes == phrasePhonemes)
}

@Test func testArithmeticKeepsNounAndTechnicalAdjectiveStress() async throws {
  let englishG2P = EnglishG2P(british: false)
  let noun = englishG2P.phonemizeWithMetadata(text: "Arithmetic is hard.")
  let adjective = englishG2P.phonemizeWithMetadata(text: "The arithmetic mean is useful.")

  #expect(noun.phonemes.hasPrefix("əɹˈɪθmətˌɪk "))
  #expect(adjective.phonemes.contains("ˌɛɹɪθmˈɛTɪk mˈin"))
  #expect(noun.fallbackHits.isEmpty)
  #expect(adjective.fallbackHits.isEmpty)
}

@Test(arguments: ["", "“", "🐈 ", "Cafe\u{301} "])
func testExplicitPossessivePronunciationIsAppliedOnce(prefix: String) throws {
  let result = EnglishG2P(british: false).phonemizeWithMetadata(
    text: "\(prefix)[Caesar’s](/ˈsiːzɚz/) wife."
  )
  #expect(result.tokens.map { $0.text + $0.whitespace }.joined() == "\(prefix)Caesar’s wife.")
  let token = try #require(result.tokens.first { $0.text == "Caesar’s" })
  #expect(token.text == "Caesar’s")
  #expect(token.phonemes == "ˈsiːzɚz")
  #expect(token.whitespace == " ")
  #expect(result.tokens.filter { $0.text == "’s" }.isEmpty)
}

@Test func testRepeatedUnicodeAndPhrasePronunciationsKeepTheirOwnRanges() throws {
  let result = EnglishG2P(british: false).phonemizeWithMetadata(
    text: "“[Caesar’s](/ˈsiːzɚz/) [New York](/nˈu jˈɔɹk/) map,” [Brutus’s](/ˈbɹuːtəsɪz/) [Caesar’s](/ˈsiːzɚz/) map."
  )
  let fixed = result.tokens.filter { $0._.rating == 5 }
  #expect(fixed.map(\.text) == ["Caesar’s", "New York", "Brutus’s", "Caesar’s"])
  #expect(fixed.map(\.phonemes) == ["ˈsiːzɚz", "nˈu jˈɔɹk", "ˈbɹuːtəsɪz", "ˈsiːzɚz"])
  #expect(result.tokens.map { $0.text + $0.whitespace }.joined()
    == "“Caesar’s New York map,” Brutus’s Caesar’s map.")
}
