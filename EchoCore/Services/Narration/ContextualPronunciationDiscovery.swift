// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import NaturalLanguage

/// Finds known contextual ambiguities without changing narration text. The
/// returned sentence window is local evidence for Phase 2 shadow evaluation.
nonisolated enum ContextualPronunciationDiscovery {
    /// Keeps occurrence coordinates local to their block while supplying the
    /// closest visible prose at paragraph boundaries. Never crosses a chapter,
    /// spine item, hidden block, or code block.
    static func discover(
        blocks: [EPubBlockRecord], overrides: PronunciationOverrides
    ) -> [ContextualPronunciationOccurrence] {
        let texts: [String?] = blocks.map { block in
            guard !block.isHidden, block.blockKind != EPubBlockRecord.Kind.code.rawValue,
                let text = block.text, !text.isEmpty
            else { return nil }
            return overrides.rewrite(to: text, blockID: block.id).text
        }
        func neighbor(_ index: Int, of target: Int, first: Bool) -> String? {
            guard blocks.indices.contains(index),
                blocks[index].chapterIndex == blocks[target].chapterIndex,
                blocks[index].spineIndex == blocks[target].spineIndex,
                let text = texts[index]
            else { return nil }
            let display = MisakiPronunciationMarkup.displayText(from: text)
            let bounded = first ? String(display.prefix(600)) : String(display.suffix(600))
            let tokenizer = NLTokenizer(unit: .sentence)
            tokenizer.string = bounded
            var sentence: String?
            tokenizer.enumerateTokens(in: bounded.startIndex..<bounded.endIndex) { range, _ in
                sentence = String(bounded[range]).trimmingCharacters(in: .whitespacesAndNewlines)
                return !first
            }
            return sentence
        }
        return blocks.indices.flatMap { index -> [ContextualPronunciationOccurrence] in
            guard let text = texts[index] else { return [] }
            let previous = neighbor(index - 1, of: index, first: false)
            let following = neighbor(index + 1, of: index, first: true)
            return discover(text: text, blockID: blocks[index].id).map { occurrence in
                var result = occurrence
                result.precedingSentence =
                    occurrence.precedingSentence
                    ?? previous
                result.followingSentence =
                    occurrence.followingSentence
                    ?? following
                return result
            }
        }
    }

    struct OperationCounts {
        var sourceSnapshotConstructions = 0
        var sourceLinkInspections = 0
        var homographTokenizations = 0
        var homographTokenVisits = 0
        var candidateSpanLookups = 0
        var homographSpanLookups = 0
        var sentenceLookups = 0
    }

    /// One immutable authored-to-display coordinate map per discovery pass.
    /// Span and sentence lookups use precomputed UTF-16 ranges rather than
    /// rebuilding markup-free source prefixes for every occurrence.
    struct SourceSnapshot {
        struct AuthoredLink {
            let range: Range<String.Index>
            let displayRange: Range<String.Index>
        }

        let displayText: String
        let displayWords: [String]
        let authoredLinks: [AuthoredLink]
        let linkInspections: Int

        private let displayUTF16OffsetBySourceIndex: [String.Index: Int]
        private let displayWordRanges: [NSRange]
        private let sentenceRanges: [NSRange]

        init(source: String) {
            var inspections = 0
            var nextClosingSquareByIndex: [String.Index: String.Index] = [:]
            var nextClosingParenthesisByIndex: [String.Index: String.Index] = [:]
            var nextClosingSquare: String.Index?
            var nextClosingParenthesis: String.Index?
            var reverseIndex = source.endIndex
            while reverseIndex > source.startIndex {
                inspections += 1
                reverseIndex = source.index(before: reverseIndex)
                if source[reverseIndex] == "]" {
                    nextClosingSquare = reverseIndex
                } else if source[reverseIndex] == ")" {
                    nextClosingParenthesis = reverseIndex
                }
                if let nextClosingSquare {
                    nextClosingSquareByIndex[reverseIndex] = nextClosingSquare
                }
                if let nextClosingParenthesis {
                    nextClosingParenthesisByIndex[reverseIndex] =
                        nextClosingParenthesis
                }
            }

            func link(startingAt start: String.Index) -> AuthoredLink? {
                inspections += 1
                guard source[start] == "[" else { return nil }
                let displayStart = source.index(after: start)
                inspections += 1
                guard let displayEnd = nextClosingSquareByIndex[displayStart],
                    displayStart < displayEnd
                else {
                    return nil
                }
                let openParenthesis = source.index(after: displayEnd)
                inspections += 1
                guard openParenthesis < source.endIndex,
                    source[openParenthesis] == "("
                else {
                    return nil
                }
                let openingSlash = source.index(after: openParenthesis)
                inspections += 1
                guard openingSlash < source.endIndex,
                    source[openingSlash] == "/"
                else {
                    return nil
                }
                let ipaStart = source.index(after: openingSlash)
                inspections += 1
                guard
                    let closeParenthesis =
                        nextClosingParenthesisByIndex[ipaStart],
                    ipaStart < closeParenthesis
                else {
                    return nil
                }
                let closingSlash = source.index(before: closeParenthesis)
                inspections += 1
                guard closingSlash > openingSlash,
                    source[closingSlash] == "/"
                else {
                    return nil
                }
                return AuthoredLink(
                    range: start..<source.index(after: closeParenthesis),
                    displayRange: displayStart..<displayEnd)
            }

            var display = ""
            display.reserveCapacity(source.utf8.count)
            var offsets: [String.Index: Int] = [:]
            var links: [AuthoredLink] = []
            var displayUTF16Offset = 0
            var sourceIndex = source.startIndex
            while sourceIndex < source.endIndex {
                inspections += 1
                offsets[sourceIndex] = displayUTF16Offset
                if let link = link(startingAt: sourceIndex) {
                    let authoredDisplay = source[link.displayRange]
                    links.append(link)
                    display.append(contentsOf: authoredDisplay)
                    displayUTF16Offset += authoredDisplay.utf16.count
                    sourceIndex = link.range.upperBound
                    offsets[sourceIndex] = displayUTF16Offset
                    continue
                }
                let character = source[sourceIndex]
                display.append(character)
                displayUTF16Offset += String(character).utf16.count
                sourceIndex = source.index(after: sourceIndex)
            }
            offsets[source.endIndex] = displayUTF16Offset

            let wordRanges = WordTokenizer.wordRanges(in: display)
            let tokenizer = NLTokenizer(unit: .sentence)
            tokenizer.string = display
            var sentences: [NSRange] = []
            tokenizer.enumerateTokens(in: display.startIndex..<display.endIndex) {
                range, _ in
                sentences.append(NSRange(range, in: display))
                return true
            }

            displayText = display
            displayWords = wordRanges.map { String(display[$0]) }
            authoredLinks = links
            linkInspections = inspections
            displayUTF16OffsetBySourceIndex = offsets
            displayWordRanges = wordRanges.map { NSRange($0, in: display) }
            sentenceRanges = sentences
        }

        func wordSpan(
            containing sourceRange: Range<String.Index>
        ) -> ClosedRange<Int>? {
            guard let matchRange = displayRange(containing: sourceRange),
                let first = firstRangeOverlapping(
                    matchRange,
                    in: displayWordRanges)
            else {
                return nil
            }

            var low = first
            var high = displayWordRanges.count
            while low < high {
                let middle = (low + high) / 2
                if displayWordRanges[middle].location < NSMaxRange(matchRange) {
                    low = middle + 1
                } else {
                    high = middle
                }
            }
            return first...(low - 1)
        }

        func sentenceIndex(
            containing sourceRange: Range<String.Index>
        ) -> Int? {
            guard let matchRange = displayRange(containing: sourceRange) else {
                return nil
            }
            return firstRangeOverlapping(matchRange, in: sentenceRanges)
        }

        func sentence(before index: Int) -> String? {
            guard index > sentenceRanges.startIndex else { return nil }
            return sentenceText(at: index - 1)
        }

        func sentence(at index: Int) -> String {
            sentenceText(at: index)
        }

        func sentence(after index: Int) -> String? {
            let following = index + 1
            guard following < sentenceRanges.endIndex else { return nil }
            return sentenceText(at: following)
        }

        func sentenceWordIndex(forWord word: Int, sentenceIndex: Int) -> Int? {
            guard
                let firstWord = firstRangeOverlapping(
                    sentenceRanges[sentenceIndex], in: displayWordRanges)
            else { return nil }
            return word - firstWord
        }

        private func displayRange(
            containing sourceRange: Range<String.Index>
        ) -> NSRange? {
            guard let lower = displayUTF16OffsetBySourceIndex[sourceRange.lowerBound],
                let upper = displayUTF16OffsetBySourceIndex[sourceRange.upperBound],
                upper > lower
            else {
                return nil
            }
            return NSRange(location: lower, length: upper - lower)
        }

        private func firstRangeOverlapping(
            _ target: NSRange,
            in ranges: [NSRange]
        ) -> Int? {
            var low = 0
            var high = ranges.count
            while low < high {
                let middle = (low + high) / 2
                if NSMaxRange(ranges[middle]) <= target.location {
                    low = middle + 1
                } else {
                    high = middle
                }
            }
            guard low < ranges.count,
                ranges[low].location < NSMaxRange(target)
            else {
                return nil
            }
            return low
        }

        private func sentenceText(at index: Int) -> String {
            guard let range = Range(sentenceRanges[index], in: displayText) else {
                return ""
            }
            return String(displayText[range])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private struct SourceToken {
        let text: String
        let normalized: String
        let range: Range<String.Index>
        let isAuthoredLinkDisplay: Bool
    }

    private static let wordRegex = try! NSRegularExpression(pattern: #"\b[\p{L}]+\b"#)

    static func discover(
        text: String,
        blockID: String,
        isHidden: Bool = false,
        isCodeBlock: Bool = false
    ) -> [ContextualPronunciationOccurrence] {
        var operationCounts = OperationCounts()
        return discover(
            text: text,
            blockID: blockID,
            isHidden: isHidden,
            isCodeBlock: isCodeBlock,
            operationCounts: &operationCounts)
    }

    static func discover(
        text: String,
        blockID: String,
        isHidden: Bool = false,
        isCodeBlock: Bool = false,
        operationCounts: inout OperationCounts
    ) -> [ContextualPronunciationOccurrence] {
        operationCounts = OperationCounts()
        guard !isHidden, !isCodeBlock, !text.isEmpty else { return [] }

        let sourceSnapshot = SourceSnapshot(source: text)
        operationCounts.sourceSnapshotConstructions = 1
        operationCounts.sourceLinkInspections = sourceSnapshot.linkInspections
        let sourceTokens = tokens(
            in: text,
            authoredLinks: sourceSnapshot.authoredLinks)
        let protectedRanges = NarrationTextChunker.pronunciationProtectedRanges(in: text)
            .sorted {
                if $0.lowerBound == $1.lowerBound {
                    return $0.upperBound > $1.upperBound
                }
                return $0.lowerBound < $1.lowerBound
            }
        var protectedRangeIndex = 0
        let familyTokenIndexes = sourceTokens.indices.filter {
            let token = sourceTokens[$0]
            while protectedRangeIndex < protectedRanges.count,
                protectedRanges[protectedRangeIndex].upperBound <= token.range.lowerBound
            {
                protectedRangeIndex += 1
            }
            let isProtected =
                protectedRangeIndex < protectedRanges.count
                && protectedRanges[protectedRangeIndex].overlaps(token.range)
            return !isProtected
                && ContextualPronunciationFamilies.family(for: token.normalized) != nil
        }
        guard !familyTokenIndexes.isEmpty else { return [] }

        let familyRanges = familyTokenIndexes.map { sourceTokens[$0].range }
        let properNameRisks = UniversalPronunciationResolver.properNameRiskFlags(
            in: text,
            candidateRanges: familyRanges)
        var homographCounts =
            HomographPronunciationResolver.ContextualAnalysisOperationCounts()
        let homographContext =
            HomographPronunciationResolver.prepareContextualAnalysis(
                in: text,
                sourceSnapshot: sourceSnapshot,
                operationCounts: &homographCounts)
        operationCounts.homographTokenizations = homographCounts.tokenizations
        operationCounts.homographTokenVisits = homographCounts.tokenVisits
        operationCounts.homographSpanLookups = homographCounts.wordSpanLookups

        var occurrences: [ContextualPronunciationOccurrence] = []
        occurrences.reserveCapacity(familyTokenIndexes.count)
        for (familyOffset, tokenIndex) in familyTokenIndexes.enumerated() {
            let token = sourceTokens[tokenIndex]
            guard !token.isAuthoredLinkDisplay,
                let family = ContextualPronunciationFamilies.family(for: token.normalized)
            else {
                continue
            }
            operationCounts.candidateSpanLookups += 1
            let wordSpan = sourceSnapshot.wordSpan(containing: token.range)
            operationCounts.sentenceLookups += 1
            let sentenceIndex = sourceSnapshot.sentenceIndex(containing: token.range)
            guard let wordSpan,
                wordSpan.lowerBound == wordSpan.upperBound,
                sourceSnapshot.displayWords.indices.contains(wordSpan.lowerBound),
                canonicalWord(
                    sourceSnapshot.displayWords[wordSpan.lowerBound],
                    matches: token),
                let sentenceIndex
            else {
                continue
            }

            let analysis = homographContext.analysis(
                atWordStart: wordSpan.lowerBound)
            let hasExactProperNameContext =
                analysis.ruleID == "homograph.live.product.weather-link-live"
                || analysis.ruleID == "homograph.live.adjective.follower"
                || analysis.ruleID == "homograph.record.noun.preceder"
                || analysis.ruleID == "homograph.record.noun.compound"
                || analysis.ruleID == "homograph.content.noun.follower"
            guard !properNameRisks[familyOffset] || hasExactProperNameContext else {
                continue
            }
            occurrences.append(
                ContextualPronunciationOccurrence(
                    occurrenceID: ContextualPronunciationOccurrenceID.make(
                        blockID: blockID,
                        wordStart: wordSpan.lowerBound,
                        wordEnd: wordSpan.upperBound,
                        normalizedWord: token.normalized),
                    blockID: blockID,
                    wordStart: wordSpan.lowerBound,
                    wordEnd: wordSpan.upperBound,
                    targetWord: token.text,
                    precedingSentence: sourceSnapshot.sentence(before: sentenceIndex),
                    targetSentence: sourceSnapshot.sentence(at: sentenceIndex),
                    followingSentence: sourceSnapshot.sentence(after: sentenceIndex),
                    familyID: family.familyID,
                    candidates: family.candidates,
                    deterministicCandidateID: analysis.candidateID,
                    deterministicRuleID: analysis.ruleID,
                    deterministicStrength: analysis.strength,
                    targetSentenceWordIndex: sourceSnapshot.sentenceWordIndex(
                        forWord: wordSpan.lowerBound, sentenceIndex: sentenceIndex)))
        }
        return occurrences
    }

    private static func canonicalWord(
        _ canonicalWord: String,
        matches token: SourceToken
    ) -> Bool {
        if PronunciationAuditContext.normalizedWord(canonicalWord) == token.normalized {
            return true
        }

        let fullRange = NSRange(
            canonicalWord.startIndex..<canonicalWord.endIndex, in: canonicalWord)
        let monitoredComponents = wordRegex.matches(in: canonicalWord, range: fullRange).compactMap
        {
            match -> String? in
            guard let range = Range(match.range, in: canonicalWord) else { return nil }
            let normalized = PronunciationAuditContext.canonicalEnglishKeySpelling(
                String(canonicalWord[range]))
            return ContextualPronunciationFamilies.family(for: normalized) == nil
                ? nil : normalized
        }
        return monitoredComponents == [token.normalized]
    }

    private static func tokens(
        in text: String,
        authoredLinks: [SourceSnapshot.AuthoredLink]
    ) -> [SourceToken] {
        var result: [SourceToken] = []
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
        to tokens: inout [SourceToken]
    ) {
        let nsSearchRange = NSRange(searchRange, in: text)
        tokens.append(
            contentsOf: wordRegex.matches(in: text, range: nsSearchRange).compactMap { match in
                guard let range = Range(match.range, in: text) else { return nil }
                let value = String(text[range])
                return SourceToken(
                    text: value,
                    normalized: PronunciationAuditContext.canonicalEnglishKeySpelling(value),
                    range: range,
                    isAuthoredLinkDisplay: isAuthoredLinkDisplay)
            })
    }

}
