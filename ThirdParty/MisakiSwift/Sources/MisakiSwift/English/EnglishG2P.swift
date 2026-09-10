import Foundation
import NaturalLanguage

public struct EnglishG2PFallbackHit: Equatable, Hashable {
  public let word: String
  public let phonemes: String

  public init(word: String, phonemes: String) {
    self.word = word
    self.phonemes = phonemes
  }
}

public struct EnglishG2PResult {
  public let phonemes: String
  public let tokens: [MToken]
  public let fallbackHits: [EnglishG2PFallbackHit]

  public init(
    phonemes: String,
    tokens: [MToken],
    fallbackHits: [EnglishG2PFallbackHit]
  ) {
    self.phonemes = phonemes
    self.tokens = tokens
    self.fallbackHits = fallbackHits
  }
}

// Main G2P pipeline for English text
final public class EnglishG2P {
  private let british: Bool
  private let tagger: NLTagger
  private let lexicon: Lexicon
  private let fallback: EnglishFallbackNetwork
  private let unk: String
    
  static let punctuationTags: Set<NLTag> =  Set([.openQuote, .closeQuote, .openParenthesis, .closeParenthesis, .punctuation, .sentenceTerminator, .otherPunctuation])
  static let punctuactions: Set<Character> = Set(";:,.!?—…\"“”")
  static let currencyExpressionTerminators = punctuactions.union(Set("–)]}"))
  static let currencyExpressionLeadingBoundaries = currencyExpressionTerminators.union(Set("([{"))
  
  // spaCy-style punctuation tags https://github.com/explosion/spaCy/blob/master/spacy/glossary.py
  static let punctuationTagPhonemes: [String: String] = [
      "``": String(UnicodeScalar(8220)!),     // Left double quotation mark
      "\"\"": String(UnicodeScalar(8221)!),   // Right double quotation mark
      "''": String(UnicodeScalar(8221)!)      // Right double quotation mark
  ]
  
  static let nonQuotePunctuations: Set<Character> = Set(punctuactions.filter { !"\"\"\"".contains($0) })
  static let vowels: Set<Character> = Set("AIOQWYaiuæɑɒɔəɛɜɪʊʌᵻ")
  static let consonants: Set<Character> = Set("bdfhjklmnpstvwzðŋɡɹɾʃʒʤʧθ")
  static let subTokenJunks: Set<Character> = Set("',-._''/")
  static let stresses = "ˌˈ"
  static let primaryStress = stresses[stresses.index(stresses.startIndex, offsetBy: 1)]
  static let secondaryStress = stresses[stresses.index(stresses.startIndex, offsetBy: 0)]
  static let arithmeticAdjectiveFollowers: Set<String> = [
    "mean", "means", "operation", "operations", "operator", "operators",
    "progression", "progressions", "sequence", "sequences",
  ]
  // Splits words into subtokens such as acronym boundaries, signs, commas, decimals, multiple quotes, camelCase boundaries and so forth.
  static let subtokenizeRegexPattern = #"^[''']+|\p{Lu}(?=\p{Lu}\p{Ll})|(?:^-)?(?:\d?[,.]?\d)+|[-_]+|[''']{2,}|\p{L}*?(?:[''']\p{L})*?\p{Ll}(?=\p{Lu})|\p{L}+(?:[''']\p{L})*|[^-_\p{L}'''\d]|[''']+$"#
  static let subtokenizeRegex = try! NSRegularExpression(pattern: EnglishG2P.subtokenizeRegexPattern, options: [])
  
  struct PreprocessFeature {
    enum Value {
      case int(Int)
      case double(Double)
      case string(String)
    }
    
    let value: Value
    let tokenRange: Range<String.Index>
  }

  public init(british: Bool = false, unk: String = "❓") {
    self.british = british
    self.tagger = NLTagger(tagSchemes: [.nameTypeOrLexicalClass])
    self.lexicon = Lexicon(british: british)
    self.fallback = EnglishFallbackNetwork(british: british)
    self.unk = unk
  }

  private func tokenContext(_ ctx: TokenContext, ps: String?, token: MToken) -> TokenContext {
    var vowel = ctx.futureVowel
    
    if let ps = ps {
      for c in ps {
        if EnglishG2P.nonQuotePunctuations.contains(c) {
          vowel = nil
          break
        }
        
        if EnglishG2P.vowels.contains(c) {
          vowel = true
          break
        }
        
        if EnglishG2P.consonants.contains(c) {
          vowel = false
          break
        }
      }
    }
    let futureTo = (token.text == "to" || token.text == "To") || (token.text == "TO" && (token.tag == .particle || token.tag == .preposition))
    return TokenContext(futureVowel: vowel, futureTo: futureTo)
  }
  
  func stressWeight(_ phonemes: String?) -> Int {
    let dipthongs = Set("AIOQWYʤʧ")
    guard let phonemes else { return 0 }
    return phonemes.reduce(0) { sum, character in
      sum + (dipthongs.contains(character) ? 2 : 1)
    }
  }
  
  private func resolveTokens(_ tokens: inout [MToken]) {
    let text = tokens.dropLast().map { $0.text + $0.whitespace }.joined() + (tokens.last?.text ?? "")
    let hasExplicitWordBreak = tokens.contains { $0.`_`.prespace }
    let prespace = hasExplicitWordBreak || text.contains(" ") || text.contains("/") || Set(text.compactMap { c -> Int? in
      if EnglishG2P.subTokenJunks.contains(c) { return nil }
      
      if c.isLetter { return 0 }
      if c.isNumber { return 1 }
      return 2
    }).count > 1
        
    for i in 0..<tokens.count {
      if tokens[i].phonemes == nil {
        if i == tokens.count - 1, let last = tokens[i].text.last, EnglishG2P.nonQuotePunctuations.contains(last) {
          tokens[i].phonemes = tokens[i].text
          tokens[i].`_`.rating = 3
        } else if tokens[i].text.allSatisfy({ EnglishG2P.subTokenJunks.contains($0) }) {
          tokens[i].phonemes = nil
          tokens[i].`_`.rating = 3
        }
      } else if i > 0 {
          tokens[i].`_`.prespace = tokens[i].`_`.prespace || prespace
      }
    }
    
    guard !prespace else { return }
    
    var indices: [(Bool, Int, Int)] = []
    for (i, tk) in tokens.enumerated() {
      if let ps = tk.phonemes, !ps.isEmpty {
        indices.append((ps.contains(Lexicon.primaryStress), stressWeight(ps), i))
      }
    }
    if indices.count == 2, tokens[indices[0].2].text.count == 1 {
        let i = indices[1].2
      tokens[i].phonemes = Lexicon.applyStress(tokens[i].phonemes, stress: -0.5)
        return
    } else if indices.count < 2 || indices.map({ $0.0 ? 1 : 0 }).reduce(0, +) <= (indices.count + 1) / 2 {
        return
    }
    indices.sort { ($0.0 ? 1 : 0, $0.1) < ($1.0 ? 1 : 0, $1.1) }
    let cut = indices.prefix(indices.count / 2)

    for x in cut {
      let i = x.2
      tokens[i].phonemes = Lexicon.applyStress(tokens[i].phonemes, stress: -0.5)
    }
  }
    
  // Text pre-processing tuple for easing the tokenization
  typealias PreprocessTuple = (text: String, tokens: [String], features: [PreprocessFeature])
    
  /// Preprocesses the string in case there are some parts where the pronounciation or stress is pre-dictated using Markdown-like link format, e.g.
  /// "[Misaki](/misˈɑki/) is a G2P engine designed for [Kokoro](/kˈOkəɹO/) models."
  private func preprocess(text: String) -> PreprocessTuple {
    // Matches the pattern of form [link text](url) and captures the two parts
    let linkRegex = try! NSRegularExpression(pattern: #"\[([^\]]+)\]\(([^\)]*)\)"#, options: [])

    var result = ""
    var tokens: [String] = []
    // Appending NSString-derived graphemes can change String's backing encoding.
    // Keep offsets until the display string is complete; indices captured during
    // construction cannot be compared with the final NLTagger token indices.
    var features: [(value: PreprocessFeature.Value, range: NSRange)] = []

    let input = text.trimmingCharacters(in: .whitespacesAndNewlines)
    var lastEnd = input.startIndex
    let ns = input as NSString
    let fullRange = NSRange(location: 0, length: ns.length)
 
    linkRegex.enumerateMatches(in: input, options: [], range: fullRange) { match, _, _ in
      guard let m = match else { return }

      guard let range = Range(m.range, in: input) else { return }
      let start = range.lowerBound
      let end = range.upperBound

      result += String(input[lastEnd..<start])
      tokens.append(contentsOf: String(input[lastEnd..<start]).split(separator: " ").map(String.init))

      let grapheme = ns.substring(with: m.range(at: 1))
      let phoneme = ns.substring(with: m.range(at: 2))
      
      let tokenRange = NSRange(location: result.utf16.count, length: grapheme.utf16.count)
      result += grapheme

      if let intValue = Int(phoneme) {
        features.append((value: .int(intValue), range: tokenRange))
      } else if ["0.5", "+0.5"].contains(phoneme) {
        features.append((value: .double(0.5), range: tokenRange))
      } else if phoneme == "-0.5" {
        features.append((value: .double(-0.5), range: tokenRange))
      } else if phoneme.count > 1 && phoneme.first == "/" && phoneme.last == "/" {
        features.append((value: .string(String(phoneme.dropLast())), range: tokenRange))
      } else if phoneme.count > 1 && phoneme.first == "#" && phoneme.last == "#" {
        features.append((value: .string(String(phoneme.dropLast())), range: tokenRange))
      }

      tokens.append(grapheme)
      lastEnd = end
    }
    
    if lastEnd < input.endIndex {
      result += String(input[lastEnd...])
      tokens.append(contentsOf: String(input[lastEnd...]).split(separator: " ").map(String.init))
    }
    
    result.makeContiguousUTF8()
    let boundFeatures = features.map { feature in
      let lower = String.Index(utf16Offset: feature.range.location, in: result)
      let upper = String.Index(utf16Offset: NSMaxRange(feature.range), in: result)
      return PreprocessFeature(value: feature.value, tokenRange: lower..<upper)
    }
    return (text: result, tokens: tokens, features: boundFeatures)
  }
    
  private func tokenize(preprocessedText: PreprocessTuple) -> [MToken] {
    var mutableTokens: [MToken] = []

    func appendSurface(_ range: Range<String.Index>, tag: NLTag?) {
      guard !range.isEmpty else { return }
      let surface = String(preprocessedText.text[range])
      if surface.allSatisfy(\.isWhitespace), let lastToken = mutableTokens.last {
        lastToken.whitespace += surface
      } else {
        mutableTokens.append(
          MToken(text: surface, tokenRange: range, tag: tag, whitespace: "")
        )
      }
    }
    
    // Tokenize and perform part-of-speech tagging
    tagger.string = preprocessedText.text
    tagger.setLanguage(.english, range: preprocessedText.text.startIndex..<preprocessedText.text.endIndex)
    let options: NLTagger.Options = []
    var cursor = preprocessedText.text.startIndex
    tagger.enumerateTags(
      in: preprocessedText.text.startIndex..<preprocessedText.text.endIndex,
      unit: .word,
      scheme: .nameTypeOrLexicalClass,
      options: options) { tag, tokenRange in
      if cursor < tokenRange.lowerBound {
        appendSurface(cursor..<tokenRange.lowerBound, tag: nil)
      }

      appendSurface(tokenRange, tag: tag)
      cursor = max(cursor, tokenRange.upperBound)
        
      return true
    }

    if cursor < preprocessedText.text.endIndex {
      appendSurface(cursor..<preprocessedText.text.endIndex, tag: nil)
    }
                            
    // Simplistic alignment by index to add stress and pre-phonemization features to tokens
    // TO_DO: Doesn't match the capability of spacy.training.Alignment.from_strings()
    for feature in preprocessedText.features {
      var assignedFixedPhonemes = false
      for token in mutableTokens {
        if token.tokenRange.contains(feature.tokenRange) || feature.tokenRange.contains(token.tokenRange) {
          switch feature.value {
            case .int(let int):
              token.`_`.stress = Double(int)
            case .double(let double):
              token.`_`.stress = double
            case .string(let string):
              if string.hasPrefix("/") {
                // One fixed IPA belongs to the whole Markdown link. Fold every
                // overlapping NL token into one phrase token and emit it once.
                token.`_`.is_head = !assignedFixedPhonemes
                token.phonemes = assignedFixedPhonemes ? "" : String(string.dropFirst())
                token.`_`.rating = 5
                assignedFixedPhonemes = true
              } else if string.hasPrefix("#") {
                token.`_`.num_flags = String(string.dropFirst())
              }
          }
        }
      }
    }

    return mutableTokens
  }
  
  func mergeTokens(_ tokens: [MToken], unk: String? = nil) -> MToken {
    let stressSet = Set(tokens.compactMap { $0._.stress })
    let currencySet = Set(tokens.compactMap { $0._.currency })
    let currencyExpressionSourceSet = Set(tokens.compactMap { $0._.currencyExpressionSource })
    let ratings: Set<Int?> = Set(tokens.map { $0._.rating })
        
    var phonemes: String? = nil
    if let unk {
      var phonemeBuilder = ""
      for token in tokens {
        if token._.prespace,
           !phonemeBuilder.isEmpty,
           !(phonemeBuilder.last?.isWhitespace ?? false),
           token.phonemes != nil {
          phonemeBuilder += " "
        }
        phonemeBuilder += token.phonemes ?? unk
      }
      phonemes = phonemeBuilder
    }
    
    // Concatenate surface text and whitespace
    let mergedText = tokens.dropLast().map { $0.text + $0.whitespace }.joined() + (tokens.last?.text ?? "")

    // Choose tag from token with highest casing score
    func score(_ t: MToken) -> Int {
      return t.text.reduce(0) { $0 + (String($1) == String($1).lowercased() ? 1 : 2) }
    }
    let tagSource = tokens.max(by: { score($0) < score($1) })
    
    let tokenRangeStart = tokens.first!.tokenRange.lowerBound
    let tokenRangeEnd = tokens.last!.tokenRange.upperBound
    let flagChars = Set(tokens.flatMap { Array($0._.num_flags) })
    
    return MToken(
      text: mergedText,
      tokenRange: Range<String.Index>(uncheckedBounds: (lower: tokenRangeStart, upper: tokenRangeEnd)),
      tag: tagSource?.tag,
      whitespace: tokens.last?.whitespace ?? "",
      phonemes: phonemes,
      start_ts: tokens.first?.start_ts,
      end_ts: tokens.last?.end_ts,
      underscore: Underscore(
        is_head: tokens.first?._.is_head ?? false,
        alias: nil,
        stress: (stressSet.count == 1 ? stressSet.first : nil),
        currency: currencySet.max(),
        currencyExpressionSource: currencyExpressionSourceSet.count == 1
          ? currencyExpressionSourceSet.first
          : nil,
        num_flags: String(flagChars.sorted()),
        prespace: tokens.first?._.prespace ?? false,
        rating: ratings.contains(where: { $0 == nil }) ? nil : ratings.compactMap { $0 }.min()
      )
    )
  }
    
  func foldLeft(_ tokens: [MToken]) -> [MToken] {
    var result: [MToken] = []
    for token in tokens {
      if let last = result.last, !token.`_`.is_head {
        _ = result.popLast()
        let merged = mergeTokens([last, token], unk: unk)
        result.append(merged)
      } else {
        result.append(token)
      }
    }
    return result
  }
  
  func subtokenize(word: String) -> [String] {
    let nsString = word as NSString
    let range = NSRange(location: 0, length: nsString.length)
    let matches = EnglishG2P.subtokenizeRegex.matches(in: word, options: [], range: range)

    var parts: [String] = []
    var cursor = 0
    for match in matches {
      if cursor < match.range.location {
        parts.append(
          nsString.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
        )
      }
      parts.append(nsString.substring(with: match.range))
      cursor = NSMaxRange(match.range)
    }
    if cursor < nsString.length {
      parts.append(
        nsString.substring(with: NSRange(location: cursor, length: nsString.length - cursor))
      )
    }
    return parts
  }

  private func flattenInitialSplitTokens(_ tokens: [MToken]) -> [MToken] {
    var flattened: [MToken] = []
    for token in tokens {
      let needsSplit = (token.`_`.alias == nil && token.phonemes == nil)
      var subtokens: [MToken] = []
      if needsSplit {
        let parts = subtokenize(word: token.text)
        subtokens = parts.map { part in
          let t = MToken(copying: token)
          t.text = part
          t.whitespace = ""
          t.`_`.is_head = true
          t.`_`.prespace = false
          return t
        }
        preserveCamelCaseWordBreaks(in: &subtokens, original: token.text)
      } else {
        subtokens = [token]
      }
      subtokens.last?.whitespace = token.whitespace

      flattened.append(contentsOf: subtokens)
    }
    return flattened
  }

  private func semanticCurrencyTokens(_ tokens: [MToken]) -> [MToken] {
    var result: [MToken] = []
    var index = 0

    while index < tokens.count {
      guard let endIndex = currencyExpressionEnd(in: tokens, startingAt: index) else {
        result.append(tokens[index])
        index += 1
        continue
      }

      let consumed = Array(tokens[index...endIndex])
      let source = consumed.dropLast().map { $0.text + $0.whitespace }.joined()
        + (consumed.last?.text ?? "")
      guard let expression = EnglishCurrencyExpression.parse(source) else {
        result.append(tokens[index])
        index += 1
        continue
      }
      let spokenPhonemes = phonemizeWithMetadata(text: expression.spokenForm).phonemes

      let first = consumed[0]
      let last = consumed[consumed.count - 1]
      result.append(
        MToken(
          text: source,
          tokenRange: Range<String.Index>(
            uncheckedBounds: (
              lower: first.tokenRange.lowerBound,
              upper: last.tokenRange.upperBound
            )
          ),
          tag: first.tag,
          whitespace: last.whitespace,
          phonemes: spokenPhonemes,
          start_ts: first.start_ts,
          end_ts: last.end_ts,
          underscore: Underscore(
            is_head: first.`_`.is_head,
            alias: expression.spokenForm,
            stress: first.`_`.stress,
            currencyExpressionSource: source,
            num_flags: first.`_`.num_flags,
            prespace: first.`_`.prespace,
            rating: 4
          )
        )
      )
      index = endIndex + 1
    }

    return result
  }

  private func currencyExpressionEnd(in tokens: [MToken], startingAt startIndex: Int) -> Int? {
    let supportedSymbols = Set(Lexicon.currencies.keys)
    let unsupportedMagnitudeWords: Set<String> = [
      "m", "mm", "b", "bn", "k", "tn", "trn", "quadrillion",
      "usd", "gbp", "eur",
    ]

    if startIndex > 0 {
      let previous = tokens[startIndex - 1]
      let hasLeadingBoundary = !previous.whitespace.isEmpty
        || (!previous.text.isEmpty && previous.text.allSatisfy {
          EnglishG2P.currencyExpressionLeadingBoundaries.contains($0)
        })
      guard hasLeadingBoundary else { return nil }
    }

    var cursor = startIndex

    if tokens[cursor].text == "-" || tokens[cursor].text == "+" {
      guard tokens[cursor].whitespace.isEmpty else { return nil }
      cursor += 1
      guard cursor < tokens.count else { return nil }
    }

    guard supportedSymbols.contains(tokens[cursor].text),
          tokens[cursor].whitespace.isEmpty else {
      return nil
    }
    cursor += 1
    guard cursor < tokens.count else { return nil }

    if tokens[cursor].text == "-" {
      guard tokens[cursor].whitespace.isEmpty else { return nil }
      cursor += 1
      guard cursor < tokens.count else { return nil }
    }

    let amountStart = cursor
    while cursor < tokens.count {
      let allowsLeadingSign = cursor == amountStart
      let characters = Array(tokens[cursor].text)
      let isAmountFragment = characters.contains(where: { $0.isNumber })
        && characters.enumerated().allSatisfy { offset, character in
          character.isNumber || character == "," || character == "."
            || (allowsLeadingSign && offset == 0 && character == "-")
        }
      guard isAmountFragment else { break }

      cursor += 1
      if !tokens[cursor - 1].whitespace.isEmpty { break }
    }
    guard cursor > amountStart else { return nil }

    var endIndex = cursor - 1
    if cursor < tokens.count, tokens[cursor].text.contains(where: \.isLetter) {
      guard !tokens[endIndex].whitespace.isEmpty else { return nil }
      let followingWord = tokens[cursor].text.lowercased()
      if EnglishCurrencyExpression.Magnitude(rawValue: followingWord) != nil {
        guard tokens[endIndex].whitespace == " " else { return nil }
        endIndex = cursor
      } else if unsupportedMagnitudeWords.contains(followingWord) {
        return nil
      }
    }

    let boundaryIndex = endIndex + 1
    if boundaryIndex < tokens.count, tokens[endIndex].whitespace.isEmpty {
      let boundaryText = tokens[boundaryIndex].text
      let isSentencePunctuation = !boundaryText.isEmpty && boundaryText.allSatisfy {
        EnglishG2P.currencyExpressionTerminators.contains($0)
      }
      guard isSentencePunctuation else { return nil }
    }

    return endIndex
  }

  func retokenize(_ tokens: [MToken]) -> [Any] {
    var words: [Any] = []
    let subtokens = semanticCurrencyTokens(flattenInitialSplitTokens(tokens))

    for j in 0..<subtokens.count {
      let token = subtokens[j]

      if token.`_`.alias != nil || token.phonemes != nil {
        // Do nothing at his point
      } else if token.tag == .dash || (token.tag == .punctuation && token.text == "–") {
        // A plain hyphen ("-") joins word parts in a compound like
        // "rough-and-ready" and must read as a brief word break, NOT the long
        // em-dash pause "—". Only a real em/en dash is a pause. (Spaced dashes
        // used as sentence pauses are normalized to commas upstream.)
        let isRealDash = token.text.contains("—") || token.text.contains("–")
        token.phonemes = isRealDash ? "—" : " "
        token.`_`.rating = 3
      } else if let tag = token.tag, EnglishG2P.punctuationTags.contains(tag), !token.text.lowercased().unicodeScalars.allSatisfy({ (97...122).contains(Int($0.value)) }) {
        if let val = EnglishG2P.punctuationTagPhonemes[token.text] {
          token.phonemes = val
        } else {
          token.phonemes = token.text.filter { EnglishG2P.punctuactions.contains($0) }
        }
        token.`_`.rating = 4
      } else if j > 0 && j < subtokens.count - 1 && token.text == "2" {
        let prev = subtokens[j - 1].text
        let next = subtokens[j + 1].text
        if subtokens[j - 1].whitespace.isEmpty,
           token.whitespace.isEmpty,
           ((prev.last.map { String($0) } ?? "" + (next.first.map { String($0) } ?? "")).allSatisfy({ $0.isLetter }) ||
            (prev == "-" && next == "-")) {
          token.`_`.alias = "to"
        }
      }

      if token.`_`.alias != nil || token.phonemes != nil {
        words.append(token)
      } else if let last = words.last as? [MToken], last.last?.whitespace.isEmpty == true {
        var arr = last
        token.`_`.is_head = false
        arr.append(token)
        _ = words.popLast()
        words.append(arr)
      } else {
        if token.whitespace.isEmpty { words.append([token]) } else { words.append(token) }
      }
    }
                
    return words.map { item in
      if let arr = item as? [MToken], arr.count == 1 { return arr[0] }
      return item
    }
  }

  private func preserveCamelCaseWordBreaks(in subtokens: inout [MToken], original: String) {
    guard subtokens.count > 1, hasCamelCaseBoundary(original) else { return }

    for index in subtokens.indices.dropFirst() {
      let previous = subtokens[subtokens.index(before: index)].text
      let current = subtokens[index].text
      guard shouldSeparateCamelCase(previous: previous, current: current) else { continue }
      subtokens[index].`_`.prespace = true
    }
  }

  private func hasCamelCaseBoundary(_ word: String) -> Bool {
    let characters = Array(word)
    guard characters.count > 1 else { return false }

    for index in 1..<characters.count {
      if characters[index].isUppercase, characters[index - 1].isLowercase {
        return true
      }
      if index + 1 < characters.count,
         characters[index - 1].isUppercase,
         characters[index].isUppercase,
         characters[index + 1].isLowercase {
        return true
      }
    }

    return false
  }

  private func shouldSeparateCamelCase(previous: String, current: String) -> Bool {
    guard previous.contains(where: \.isLetter), current.contains(where: \.isLetter) else {
      return false
    }

    // "McDonald" is a surname prefix, not a product-style compound.
    if previous.lowercased() == "mc" { return false }

    return true
  }

  private func normalizeContextualTag(_ token: MToken, followingWord: String?) {
    guard token.text.lowercased() == "arithmetic" else { return }

    if let followingWord,
       Self.arithmeticAdjectiveFollowers.contains(followingWord.lowercased()) {
      return
    }

    token.tag = .noun
  }

  // MARK: - Sentence-initial imperative retagging

  /// Object-like words that can directly follow a sentence-initial verb. A bare
  /// noun cannot be followed by one of these without a relative clause, so
  /// `<heteronym> <follower>` at sentence start reads as an imperative (or an
  /// inverted question). Relative markers (`that`, `which`) and subject
  /// pronouns are deliberately absent: "Content that is useful…" and
  /// "Progress we made…" are nouns.
  private static let imperativeObjectFollowers: Set<String> = [
    "the", "a", "an", "this", "these", "those",
    "my", "your", "his", "her", "its", "our", "their",
    "each", "every", "all", "some", "any", "no", "another", "both", "either", "neither",
    "me", "it", "us", "them", "him", "one",
    "myself", "yourself", "yourselves", "himself", "herself", "itself", "ourselves", "themselves",
    "everything", "something", "anything", "nothing",
    "everyone", "someone", "anyone", "everybody", "somebody", "anybody", "nobody",
    "what", "whatever",
  ]

  private static let sentenceTerminators: Set<Character> = [".", "!", "?", "…"]

  /// Apple's tagger reads a capitalised sentence-initial heteronym as a noun,
  /// adjective, or adverb even when an object follows — "Permit me…",
  /// "Close the door.", "Project the image…", "Separate the eggs." — which
  /// selects the wrong lexicon entry. Measured: the same words tag as verbs as
  /// soon as anything precedes them ("Please permit me…"), and a preceding
  /// sentence does not help, so this is a sentence-initial prior, not missing
  /// context. Retag that shape as a verb before lookup; the lexicon's `VERB`
  /// entry (or its verb-form `DEFAULT`) then wins. Only the gold lexicon's
  /// part-of-speech heteronyms are eligible, authored pronunciations are never
  /// touched, and punctuation or a line break between the word and its
  /// follower disqualifies the pair.
  private func applyImperativeVerbTags(to words: [Any]) {
    let tokens: [MToken] = words.flatMap { item -> [MToken] in
      if let token = item as? MToken { return [token] }
      return (item as? [MToken]) ?? []
    }
    var atSentenceStart = true
    for (index, token) in tokens.enumerated() {
      let text = token.text
      if text.contains(where: { $0.isLetter || $0.isNumber }) {
        if atSentenceStart {
          atSentenceStart = false
          let follower = index + 1 < tokens.count ? tokens[index + 1] : nil
          if isSentenceInitialImperative(token, followedBy: follower) {
            token.tag = .verb
          }
        }
      } else if text.contains(where: { Self.sentenceTerminators.contains($0) }) {
        atSentenceStart = true
      }
      if token.whitespace.contains(where: \.isNewline) {
        atSentenceStart = true
      }
    }
  }

  private func isSentenceInitialImperative(_ token: MToken, followedBy follower: MToken?) -> Bool {
    guard token.phonemes == nil, token.`_`.alias == nil, token.tag != .verb else { return false }
    let text = token.text
    guard text.count > 1,
          text.allSatisfy(\.isLetter),
          text != text.uppercased(),
          lexicon.hasPartOfSpeechVariants(text.lowercased())
    else { return false }
    guard let follower,
          !token.whitespace.contains(where: \.isNewline),
          follower.text.allSatisfy(\.isLetter)
    else { return false }
    return Self.imperativeObjectFollowers.contains(follower.text.lowercased())
  }

  private func nextWordText(in words: [Any], after index: Int) -> String? {
    guard index + 1 < words.count else { return nil }

    for item in words[(index + 1)...] {
      if let token = item as? MToken, token.text.contains(where: \.isLetter) {
        return token.text
      }

      if let tokens = item as? [MToken],
         let token = tokens.first(where: { $0.text.contains(where: \.isLetter) }) {
        return token.text
      }
    }

    return nil
  }

  /// The compound resolution and the whole-token guess share the same OOV
  /// rating, so the components are reported separately — otherwise a
  /// component-built pronunciation is indistinguishable from a blind guess.
  private func fallbackTranscription(
    for token: MToken,
    ctx: TokenContext
  ) -> (phoneme: String, rating: Int, compoundComponents: String?) {
    if let compound = lexicon.transcribeClosedCompound(token, ctx: ctx) {
      return (compound.phonemes, compound.rating, compound.components)
    }
    let guess = fallback(token)
    return (guess.phoneme, guess.rating, nil)
  }
   
  /// Never-voiceless guarantee for a single token's phonemes.
  ///
  /// Returns phonemes that can never reach the TTS vocab as a dropped `unk`
  /// (`❓`) marker — which would render a real word as silence. If `current` is
  /// missing (`nil`) or still contains the `unk` marker AND `text` has at least
  /// one letter, the word is approximated by the deterministic grapheme→IPA
  /// fallback (effectively spelling it out) instead of being silently skipped.
  /// Letter-less tokens (punctuation, whitespace) legitimately contribute
  /// nothing and are left as `current ?? ""`.
  func needsVoicedFallback(text: String, current: String?) -> Bool {
    let isVoiceless = current == nil || current!.range(of: unk) != nil
    return isVoiceless && text.contains(where: { $0.isLetter })
  }

  func voicedPhonemes(text: String, current: String?) -> String {
    guard needsVoicedFallback(text: text, current: current) else {
      return current ?? ""
    }
    return EnglishFallbackNetwork.phonemes(for: text)
  }

  // Turns the text into phonemes that can then be fed to text-to-speech (TTS) engine for converting to audio
  public func phonemize(text: String, performPreprocess: Bool = true) -> (String, [MToken]) {
    let result = phonemizeWithMetadata(text: text, performPreprocess: performPreprocess)
    return (result.phonemes, result.tokens)
  }

  /// Turns text into phonemes and exposes every deterministic fallback used for
  /// out-of-vocabulary words. `phonemize` remains the compatibility wrapper.
  public func phonemizeWithMetadata(text: String, performPreprocess: Bool = true) -> EnglishG2PResult {
    let pre: PreprocessTuple
    if performPreprocess {
        pre = self.preprocess(text: text)
    } else {
        pre = (text: text, tokens: [], features: [])
    }

    var tokens = tokenize(preprocessedText: pre)
    tokens = foldLeft(tokens)
    
    let words = retokenize(tokens)
    applyImperativeVerbTags(to: words)
    
    var ctx = TokenContext()
    var fallbackHits: [EnglishG2PFallbackHit] = []
    for i in stride(from: words.count - 1, through: 0, by: -1) {
      if let w = words[i] as? MToken {
        normalizeContextualTag(w, followingWord: nextWordText(in: words, after: i))
        if w.phonemes == nil {
          let out = lexicon.transcribe(w, ctx: ctx)
          w.phonemes = out.0
          w.`_`.rating = out.1
        }
        
        if w.phonemes == nil {
          let out = fallbackTranscription(for: w, ctx: ctx)
          w.phonemes = out.0
          w.`_`.rating = out.1
          w.`_`.compoundComponents = out.compoundComponents
          fallbackHits.append(EnglishG2PFallbackHit(word: w.text, phonemes: out.0))
        }
        
        ctx = tokenContext(ctx, ps: w.phonemes, token: w)
      } else if var arr = words[i] as? [MToken] {
        if arr.contains(where: { $0.`_`.prespace }) {
          for j in stride(from: arr.count - 1, through: 0, by: -1) {
            let token = arr[j]
            if token.phonemes == nil {
              let out = lexicon.transcribe(token, ctx: ctx)
              token.phonemes = out.0
              token.`_`.rating = out.1
            }

            if token.phonemes == nil {
              let out = fallbackTranscription(for: token, ctx: ctx)
              token.phonemes = out.0
              token.`_`.rating = out.1
              token.`_`.compoundComponents = out.compoundComponents
              fallbackHits.append(EnglishG2PFallbackHit(word: token.text, phonemes: out.0))
            }

            ctx = tokenContext(ctx, ps: token.phonemes, token: token)
            arr[j] = token
          }
          resolveTokens(&arr)
        } else {
          var left = 0
          var right = arr.count
          var shouldFallback = false
          while left < right {
            let hasFixed = arr[left..<right].contains { $0.`_`.alias != nil || $0.phonemes != nil }
            let token: MToken? = hasFixed ? nil : mergeTokens(Array(arr[left..<right]))
            let res: (String?, Int?) = (token == nil) ? (nil, nil) : lexicon.transcribe(token!, ctx: ctx)

            if let phonemes = res.0 {
              arr[left].phonemes = phonemes
              arr[left].`_`.rating = res.1
              for j in (left + 1)..<right {
                arr[j].phonemes = ""
                arr[j].`_`.rating = res.1
              }
              ctx = tokenContext(ctx, ps: phonemes, token: token!)
              right = left
              left = 0
            } else if left + 1 < right {
              left += 1
            } else {
              right -= 1
              let last = arr[right]
              if last.phonemes == nil {
                if last.text.allSatisfy({ EnglishG2P.subTokenJunks.contains($0) }) {
                  last.phonemes = ""
                  last.`_`.rating = 3
                } else {
                  shouldFallback = true
                  break
                }
              }
              left = 0
              arr[right] = last
            }
          }

          if shouldFallback {
            let token = mergeTokens(arr)
            let first = arr[0]
            let out = fallbackTranscription(for: token, ctx: ctx)
            first.phonemes = out.0
            first.`_`.rating = out.1
            first.`_`.compoundComponents = out.compoundComponents
            fallbackHits.append(EnglishG2PFallbackHit(word: token.text, phonemes: out.0))
            arr[0] = first
            if arr.count > 1 {
              for j in 1..<arr.count {
                arr[j].phonemes = ""
                arr[j].`_`.rating = out.1
              }
            }
          } else {
            resolveTokens(&arr)
          }
        }
      }
    }
    
    let finalTokens: [MToken] = words.map { item in
      if let arr = item as? [MToken] { return mergeTokens(arr, unk: self.unk) }
      return item as! MToken
    }
        
    for i in 0..<finalTokens.count {
      if var ps = finalTokens[i].phonemes, !ps.isEmpty {
        ps = ps.replacingOccurrences(of: "ɾ", with: "T").replacingOccurrences(of: "ʔ", with: "t")
        finalTokens[i].phonemes = ps
      }
    }

    // Never-voiceless guarantee: a letter-bearing word the lexicon and OOV
    // fallback still left unvoiced (nil, or the dropped `❓` unk marker) is
    // approximated here so it is spoken, never silently skipped downstream.
    for token in finalTokens {
      let current = token.phonemes
      let usesFallback = needsVoicedFallback(text: token.text, current: current)
      let phonemes = voicedPhonemes(text: token.text, current: current)
      if usesFallback {
        token.`_`.rating = 1
        fallbackHits.append(EnglishG2PFallbackHit(word: token.text, phonemes: phonemes))
      }
      token.phonemes = phonemes
    }

    let result = finalTokens.map { ( $0.phonemes ?? self.unk ) + $0.whitespace }.joined()
    return EnglishG2PResult(phonemes: result, tokens: finalTokens, fallbackHits: fallbackHits)
  }
}
