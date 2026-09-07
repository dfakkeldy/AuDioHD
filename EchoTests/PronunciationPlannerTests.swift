// SPDX-License-Identifier: GPL-3.0-or-later
import Testing

@testable import Echo

@Suite struct PronunciationPlannerTests {
    @Test func sizingAndPlanningReuseTheSameG2PResult() throws {
        var calls = 0
        let g2p = KokoroG2P()
        let planner = try PronunciationPlanner(g2pResult: { input, display in
            calls += 1
            return g2p.result(for: input, displayText: display)
        })
        let text = "We record the record."
        let count = planner.phonemeCount(for: text)
        let plan = try planner.planResolved(text)
        #expect(count == plan.phonemes.count)
        #expect(calls == 1)
        let differentDisplay = try planner.plan(displayText: "Different words", g2pInputText: text)
        #expect(differentDisplay.displayText == "Different words")
        #expect(calls == 2)
    }

    @Test func planCapturesExactResolvedInputsAndFallbackEvidence() throws {
        let plan = try PronunciationPlanner().plan(
            displayText: "The filesystem works.",
            g2pInputText: "The [filesystem](/fˈIl sˌɪstəm/) works."
        )
        #expect(plan.displayText == "The filesystem works.")
        #expect(plan.g2pInputText == "The [filesystem](/fˈIl sˌɪstəm/) works.")
        #expect(plan.phonemes.contains("fˈIl sˌɪstəm"))
        #expect(plan.phonemeIDs.first == KokoroPhonemeVocab.boundaryTokenId)
        #expect(plan.phonemeIDs.last == KokoroPhonemeVocab.boundaryTokenId)
        #expect(plan.wordCount == 3)
        #expect(plan.pronunciationFallbackHits.isEmpty)
    }

    @Test func verifiedUsesOrdinaryLexiconWithoutFallback() throws {
        let plan = try PronunciationPlanner().plan(
            displayText: "The result was verified.",
            g2pInputText: "The result was verified."
        )
        #expect(plan.phonemes.contains("vˈɛɹəfˌId"))
        #expect(plan.pronunciationFallbackHits.allSatisfy { $0.word.lowercased() != "verified" })
    }

    @Test func planCarriesTokenEvidenceFromTheFinalG2PPass() throws {
        let plan = try PronunciationPlanner().plan(
            displayText: "The result was verified.",
            g2pInputText: "The result was verified."
        )
        let token = try #require(
            plan.pronunciationTokenEvidence.first {
                $0.text.lowercased() == "verified"
            })

        #expect(token.selectedPhonemes == "vˈɛɹəfˌId")
        #expect(plan.phonemes.contains(token.selectedPhonemes))
        #expect(token.displayCharacterRange == 15..<23)
        let phonemeRange = try #require(token.phonemeCharacterRange)
        let lowerBound = plan.phonemes.index(
            plan.phonemes.startIndex,
            offsetBy: phonemeRange.lowerBound)
        let upperBound = plan.phonemes.index(
            plan.phonemes.startIndex,
            offsetBy: phonemeRange.upperBound)
        #expect(plan.phonemes[lowerBound..<upperBound] == token.selectedPhonemes)
        let interiorIDs = Array(plan.phonemeIDs.dropFirst().dropLast())
        let exactTokenIDs = Array(interiorIDs[phonemeRange])
        #expect(
            exactTokenIDs
                == (try PronunciationPlanner().phonemeIDs(forIPA: token.selectedPhonemes)))
        #expect(!token.usedFallback)
    }

    @Test func frozenRetrySlicesPreserveParentPhonemesIDsAndTokenEvidence() throws {
        let parent = try PronunciationPlanner().planResolved(
            "Jacqui met the verified filesystem while alpha beta gamma delta epsilon zeta eta theta iota kappa lambda mu."
        )

        let slices = parent.frozenRetrySlices(
            maxPhonemes: max(20, min(80, parent.phonemes.count / 2)))

        try #require(slices.count > 1)
        #expect(slices.allSatisfy { !$0.phonemes.isEmpty })
        #expect(
            slices.allSatisfy {
                $0.phonemeIDs.first == KokoroPhonemeVocab.boundaryTokenId
                    && $0.phonemeIDs.last == KokoroPhonemeVocab.boundaryTokenId
            })
        #expect(slices.map(\.phonemes).joined() == parent.phonemes)
        #expect(
            slices.flatMap { $0.phonemeIDs.dropFirst().dropLast() }
                == Array(parent.phonemeIDs.dropFirst().dropLast()))
        #expect(
            slices.flatMap { WordTokenizer.words(in: $0.displayText).map(String.init) }
                == WordTokenizer.words(in: parent.displayText).map(String.init))
        #expect(slices.reduce(0) { $0 + $1.wordCount } == parent.wordCount)

        var parentEvidenceIndex = 0
        var displayOffset = 0
        var phonemeOffset = 0
        for slice in slices {
            for evidence in slice.pronunciationTokenEvidence {
                let displayRange = evidence.displayCharacterRange
                #expect(displayRange.lowerBound >= 0)
                #expect(displayRange.upperBound <= slice.displayText.count)
                let displayLower = slice.displayText.index(
                    slice.displayText.startIndex,
                    offsetBy: displayRange.lowerBound)
                let displayUpper = slice.displayText.index(
                    slice.displayText.startIndex,
                    offsetBy: displayRange.upperBound)
                #expect(slice.displayText[displayLower..<displayUpper] == evidence.text)

                let range = try #require(evidence.phonemeCharacterRange)
                #expect(range.lowerBound >= 0)
                #expect(range.upperBound <= slice.phonemes.count)
                let lower = slice.phonemes.index(
                    slice.phonemes.startIndex,
                    offsetBy: range.lowerBound)
                let upper = slice.phonemes.index(
                    slice.phonemes.startIndex,
                    offsetBy: range.upperBound)
                #expect(
                    slice.phonemes[lower..<upper]
                        == evidence.selectedPhonemes.filter {
                            $0 != KokoroPhonemeVocab.oovMarker
                        })

                let parentEvidence = parent.pronunciationTokenEvidence[parentEvidenceIndex]
                #expect(evidence.text == parentEvidence.text)
                #expect(evidence.selectedPhonemes == parentEvidence.selectedPhonemes)
                #expect(evidence.lexicalTag == parentEvidence.lexicalTag)
                #expect(evidence.rating == parentEvidence.rating)
                #expect(evidence.usedFallback == parentEvidence.usedFallback)
                #expect(
                    (displayRange.lowerBound + displayOffset)..<(displayRange.upperBound
                        + displayOffset)
                        == parentEvidence.displayCharacterRange)
                let parentPhonemeRange = try #require(parentEvidence.phonemeCharacterRange)
                #expect(
                    (range.lowerBound + phonemeOffset)..<(range.upperBound + phonemeOffset)
                        == parentPhonemeRange)
                parentEvidenceIndex += 1
            }
            displayOffset += slice.displayText.count + 1
            phonemeOffset += slice.phonemes.count
        }
        #expect(parentEvidenceIndex == parent.pronunciationTokenEvidence.count)
        #expect(
            slices.flatMap(\.pronunciationFallbackHits)
                == parent.pronunciationFallbackHits)

        for fallbackWord in ["jacqui", "filesystem"] {
            let matchingSlices = slices.filter { slice in
                slice.pronunciationFallbackHits.contains {
                    $0.word.lowercased() == fallbackWord
                }
            }
            #expect(matchingSlices.count == 1)
            let matchingSlice = try #require(matchingSlices.first)
            #expect(
                matchingSlice.pronunciationTokenEvidence.contains { evidence in
                    evidence.usedFallback
                        && evidence.text.lowercased() == fallbackWord
                        && matchingSlice.pronunciationFallbackHits.contains { hit in
                            hit.word.lowercased() == fallbackWord
                                && hit.ipa == evidence.selectedPhonemes
                        }
                })
        }
    }

    @Test func frozenRetrySlicesPreferAuthoredSentenceAndClauseBoundaries() throws {
        struct BoundaryCase {
            let text: String
            let expectedFirstSlice: String
        }
        let cases = [
            BoundaryCase(
                text:
                    "One brief sentence ends here. Alpha beta gamma delta epsilon zeta eta theta iota kappa lambda mu.",
                expectedFirstSlice: "One brief sentence ends here."),
            BoundaryCase(
                text:
                    "Alpha beta gamma, delta epsilon zeta eta theta iota kappa lambda mu nu xi omicron.",
                expectedFirstSlice: "Alpha beta gamma,"),
        ]

        for boundaryCase in cases {
            let parent = try PronunciationPlanner().planResolved(boundaryCase.text)
            let boundary = try #require(
                parent.pronunciationTokenEvidence.first {
                    $0.displayCharacterRange.upperBound
                        == boundaryCase.expectedFirstSlice.count
                }?.phonemeCharacterRange)
            let maxPhonemes = min(boundary.upperBound + 20, parent.phonemes.count - 1)
            let slices = parent.frozenRetrySlices(maxPhonemes: maxPhonemes)

            try #require(slices.count > 1)
            #expect(slices.first?.displayText == boundaryCase.expectedFirstSlice)
            #expect(slices.map(\.phonemes).joined() == parent.phonemes)
            #expect(
                slices.flatMap { $0.phonemeIDs.dropFirst().dropLast() }
                    == Array(parent.phonemeIDs.dropFirst().dropLast()))
        }
    }

    @Test func planKeepsSynthesisButDropsUnvalidatedTokenRanges() throws {
        let plan = try PronunciationPlanner().plan(
            displayText: "different",
            g2pInputText: "verified"
        )

        #expect(!plan.phonemes.isEmpty)
        #expect(plan.pronunciationTokenEvidence.isEmpty)
        #expect(
            plan.pronunciationEvidenceValidation
                == .mismatch(
                    expectedDisplayText: "different",
                    reconstructedSpokenSurface: "verified"))
    }

    @Test func planResolvedPreservesSuppliedLinkAndDerivesDisplayText() throws {
        let resolved = "[record](/ɹəkˈɔɹd/)"
        let plan = try PronunciationPlanner().planResolved(resolved)

        #expect(plan.displayText == "record")
        #expect(plan.g2pInputText == resolved)
        #expect(plan.phonemes.contains("ɹəkˈɔɹd"))
    }

    @Test func planToleratesUnphonemizableGlyphsWithoutAbortingRender() throws {
        // Ordinary book text can contain glyphs the lexicon-only G2P can't
        // pronounce (symbols, emoji, even a literal ❓). Planning must never throw
        // and must never leave an unencodable marker for `validatedIDs` — the
        // whole-chapter-abort regression from PR #429. Today's MisakiSwift maps
        // these to a schwa or "" so the marker never actually reaches the strip,
        // but the end-to-end invariant this pins holds regardless of that: a weird
        // glyph never bricks the render.
        for input in ["hi 🎉 there", "the ❓ mark", "hi § there", "☭"] {
            let plan = try PronunciationPlanner().plan(
                displayText: input, g2pInputText: input)
            #expect(!plan.phonemes.contains(KokoroPhonemeVocab.oovMarker))
            #expect(plan.phonemeIDs.first == KokoroPhonemeVocab.boundaryTokenId)
            #expect(plan.phonemeIDs.last == KokoroPhonemeVocab.boundaryTokenId)
        }
    }
}
