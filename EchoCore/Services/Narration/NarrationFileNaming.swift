// SPDX-License-Identifier: GPL-3.0-or-later
import CryptoKit
import Foundation

nonisolated struct NarrationCacheLocation: Equatable, Sendable {
    let chapterIndex: Int?
    let stableChapterToken: String?
    let segmentIndex: Int?
}

/// Single source of truth for narration cache filenames, so the writer
/// (`NarrationService`) and the exporter (`NarrationCacheSource`) always agree —
/// and so a `file://`-URL `audiobookID` (which contains slashes/colons) becomes a
/// valid filename instead of breaking the write.
nonisolated enum NarrationFileNaming {
    /// Bump whenever the *rendered audio* changes (DSP, sample rate, lead-out…),
    /// so a cached chapter from an older render misses the cache and regenerates
    /// once, while everything else stays persisted. v1 = the original un-versioned
    /// render (no `-v` suffix); v2 = 8.5 kHz low-pass (reverted — it dulled the
    /// already-clean render without fixing the whine, which was a playback-side
    /// time-pitch artifact); v3 = low-pass removed, raw vocoder output again;
    /// v4 = 0.75 s lead-out silence so the final word isn't clipped on chapter
    /// advance (NarrationService.leadOutPadSeconds);
    /// v5 = fixed-shape mattmireles Kokoro CoreML pipeline + MisakiSwift G2P
    /// (replaces FluidAudio's dynamic-shape vocoder) — different model, DSP, and
    /// G2P produce different bytes, so every cached chapter re-renders once.
    /// v6 = ONNX Runtime (CPU) Kokoro engine replaces the fixed-shape CoreML
    /// pipeline on iOS (instant load, RTF ≈ 0.5 on A14, off-ANE) — different
    /// acoustic model, so cached v5 audio regenerates once. (macOS still renders
    /// via CoreML until the ONNX port; the shared version means it re-renders too.)
    /// v7 = segment-render cache layout groundwork. The renderer still writes
    /// chapter files until segment orchestration lands, but the cache version
    /// changes so v6 per-chapter files are swept when the segment layout takes over.
    /// v8 = render-time planned silence for paragraph, heading, and section
    /// breaks changes rendered audio bytes for the same source text.
    /// v9 = acoustic chunk quality retry/fallback guardrails; cached v8 files may
    /// contain already-rendered silent/truncated chunks and must regenerate once.
    /// v10 = pronunciation front-end refresh: CamelCase compound word breaks,
    /// fallback preflight reporting, and reviewed homograph/stress repairs.
    /// v11 = pronunciation planning moves before TTS so waveform, duration,
    /// quality retry, and silence recovery consume the same exact phoneme IDs.
    /// v12 = quality retries reuse frozen approved phoneme/ID slices instead of
    /// rerunning G2P, changing byte behavior for previously cached chapters.
    /// v13 = token-scoped acoustic normalization opens the schwa in final
    /// `-ble` / `-bles` pronunciations, and frozen quality retries prefer
    /// authored sentence/clause boundaries before Kokoro synthesis.
    /// v14 = unseen closed compounds can reuse one unambiguous pair of known
    /// lexical component pronunciations instead of the whole-token OOV guess.
    /// v15 = periods inside dotted identifiers stay within one authored word,
    /// keeping synthesis chunks and pronunciation evidence on the same indices.
    /// v16 = validated supplemental whole-word and bounded morphology
    /// pronunciations join the production front end.
    /// v17 = claimed by the concurrent spaced-dash normalization change, so this
    /// revision takes v18 rather than reuse a number another change holds.
    /// v18 = closed-compound resolution accepts semantic evidence from either
    /// constituent, so a compound with a familiar head (`boatlight`, `fogline`)
    /// is voiced from its known components instead of the whole-token guess.
    /// v19 = the spaced-dash normalization now lands on top of v18: the dash
    /// keeps its own authored word slot and adds a token to the rendered stream.
    /// v20 = common abbreviations are spelled out before G2P, so `km`, `hrs`,
    /// `Mt.`, `approx.`, and month abbreviations in date position are voiced as
    /// words instead of reaching the voice as unpronounceable letter strings.
    /// v21 = complete supported currency expressions are normalized to semantic
    /// spoken forms before G2P, changing narration bytes for the same source text.
    /// v22 = explicit-positive supported currency expressions retain their plus
    /// semantics through G2P, changing narration bytes for the same source text.
    /// v23 = acoustically rejected atomic chunks retry their frozen plan before
    /// fail-open audio fallback, changing accepted audio and evidence receipts.
    /// v24 = a sentence-initial heteronym directly followed by an object
    /// ("Permit me", "Close the door", "Project the image") is retagged as a
    /// verb before lexicon lookup, changing narration bytes for the same
    /// source text.
    /// v25 = linking-verb content disambiguation and validated identifier splits.
    /// v26 = explicit pronunciation spans bind to final Unicode string indices,
    /// preventing an already-instructed possessive suffix from being voiced twice.
    static let renderVersion = 26
    /// Stable renderer-family identity persisted beside headless captures. The
    /// cache render version tracks byte-affecting revisions within this family;
    /// this value prevents a different engine/G2P stack from inheriting them.
    static let rendererIdentity = "echo.kokoro-82m.onnx.misaki-us.v1"

    /// A filesystem-safe token for an audiobook id (which may be a folder-URL string).
    static func safeToken(_ audiobookID: String) -> String {
        let token = String(audiobookID.map { $0.isLetter || $0.isNumber ? $0 : "_" })
        return token.isEmpty ? "book" : token
    }

    /// A compact, stable identity for an anthology source chapter. The source key
    /// never appears in a cache filename, and keeping the first 128 SHA-256 bits
    /// makes a collision impractical while preserving readable file names.
    static func stableChapterToken(for sourceChapterKey: String) -> String {
        String(
            SHA256.hash(data: Data(sourceChapterKey.utf8))
                .map { String(format: "%02x", $0) }
                .joined()
                .prefix(32))
    }

    static func chapterFileName(
        audiobookID: String,
        chapterIndex: Int,
        voice: VoiceID,
        contentSignature: String? = nil
    ) -> String {
        chapterFileName(
            audiobookID: audiobookID,
            chapterIndex: chapterIndex,
            sourceChapterKey: nil,
            voice: voice,
            contentSignature: contentSignature)
    }

    static func chapterFileName(
        audiobookID: String,
        chapterIndex: Int,
        sourceChapterKey: String?,
        voice: VoiceID,
        contentSignature: String? = nil
    ) -> String {
        chapterFileName(
            audiobookID: audiobookID,
            chapterIndex: chapterIndex,
            sourceChapterKey: sourceChapterKey,
            renderIdentityToken: voice.rawValue,
            contentSignature: contentSignature)
    }

    /// The token naming the audio-render inputs for a chapter. Legacy callers
    /// continue to supply their voice raw value; source-bound block plans supply
    /// their resolved `plan-<12>` identity instead.
    static func chapterFileName(
        audiobookID: String,
        chapterIndex: Int,
        sourceChapterKey: String? = nil,
        renderIdentityToken identityToken: String,
        contentSignature: String? = nil
    ) -> String {
        let signature = signatureFragment(contentSignature)
        let token = renderIdentityToken(identityToken)
        if let sourceChapterKey {
            return
                "\(safeToken(audiobookID))-ck\(stableChapterToken(for: sourceChapterKey))\(signature)-\(token)-v\(renderVersion).m4a"
        }
        return
            "\(safeToken(audiobookID))-ch\(chapterIndex)\(signature)-\(token)-v\(renderVersion).m4a"
    }

    static func segmentFileName(
        audiobookID: String,
        chapterIndex: Int,
        segmentIndex: Int,
        voice: VoiceID,
        contentSignature: String? = nil
    ) -> String {
        segmentFileName(
            audiobookID: audiobookID,
            chapterIndex: chapterIndex,
            sourceChapterKey: nil,
            segmentIndex: segmentIndex,
            voice: voice,
            contentSignature: contentSignature)
    }

    static func segmentFileName(
        audiobookID: String,
        chapterIndex: Int,
        sourceChapterKey: String?,
        segmentIndex: Int,
        voice: VoiceID,
        contentSignature: String? = nil
    ) -> String {
        let signature = signatureFragment(contentSignature)
        if let sourceChapterKey {
            return
                "\(safeToken(audiobookID))-ck\(stableChapterToken(for: sourceChapterKey))-s\(segmentIndex)\(signature)-\(voice.rawValue)-v\(renderVersion).m4a"
        }
        return
            "\(safeToken(audiobookID))-ch\(chapterIndex)-s\(segmentIndex)\(signature)-\(voice.rawValue)-v\(renderVersion).m4a"
    }

    static func trackID(
        audiobookID: String,
        chapterIndex: Int,
        sourceChapterKey: String?,
        segmentIndex: Int?
    ) -> String {
        let chapterIdentity: String
        if let sourceChapterKey {
            chapterIdentity = "ck\(stableChapterToken(for: sourceChapterKey))"
        } else {
            chapterIdentity = "ch\(chapterIndex)"
        }
        let segmentSuffix = segmentIndex.map { "-s\($0)" } ?? ""
        return "syn-\(audiobookID)-\(chapterIdentity)\(segmentSuffix)"
    }

    static func trackID(
        audiobookID: String,
        chapterIndex: Int,
        segmentIndex: Int?
    ) -> String {
        trackID(
            audiobookID: audiobookID,
            chapterIndex: chapterIndex,
            sourceChapterKey: nil,
            segmentIndex: segmentIndex)
    }

    static func contentSignature(
        spokenBlocks: [EPubBlockRecord],
        renderedTexts: [String],
        includeLeadOutPad: Bool,
        normalizationMode: String = "deterministic",
        pronunciationPolicySignature: String
    ) -> String {
        var components: [String] = [
            "renderVersion=\(renderVersion)",
            "leadOut=\(includeLeadOutPad ? 1 : 0)",
            "normalizationMode=\(normalizationMode)",
            "pronunciationPolicySignature=\(pronunciationPolicySignature)",
            "blockCount=\(spokenBlocks.count)",
            "textCount=\(renderedTexts.count)",
        ]
        components.reserveCapacity(components.count + spokenBlocks.count * 3)
        for (offset, block) in spokenBlocks.enumerated() {
            components.append("blockID:\(block.id.count):\(block.id)")
            if let annotations = block.pronunciationAnnotations {
                components.append("epubPronunciationV1:\(annotations.utf8.count):\(annotations)")
            }
            components.append("blockKind:\(block.blockKind.count):\(block.blockKind)")
            let text = offset < renderedTexts.count ? renderedTexts[offset] : ""
            components.append("text:\(text.count):\(text)")
        }
        return String(FMNormalizationCache.key(for: components.joined(separator: "\n")).prefix(16))
    }

    /// Prefix matching every chapter file for a book (any chapter, any voice).
    static func chapterPrefix(audiobookID: String) -> String {
        "\(safeToken(audiobookID))-ch"
    }

    /// Recovers the chapter index from a name produced by `chapterFileName`,
    /// or `nil` if the name isn't a narration chapter file. Used to resume at the
    /// last-played chapter on reopen.
    static func chapterIndex(fromFileName fileName: String) -> Int? {
        guard let marker = fileName.range(of: "-ch") else { return nil }
        let digits = fileName[marker.upperBound...].prefix { $0.isNumber }
        return digits.isEmpty ? nil : Int(digits)
    }

    static func segmentLocation(fromFileName fileName: String) -> (
        chapterIndex: Int, segmentIndex: Int
    )? {
        guard let chapterMarker = fileName.range(of: "-ch") else { return nil }
        let chapterDigits = fileName[chapterMarker.upperBound...].prefix { $0.isNumber }
        guard let chapterIndex = Int(chapterDigits) else { return nil }
        guard
            let segmentMarker = fileName.range(
                of: "-s", range: chapterMarker.upperBound..<fileName.endIndex)
        else { return nil }
        let segmentDigits = fileName[segmentMarker.upperBound...].prefix { $0.isNumber }
        guard let segmentIndex = Int(segmentDigits) else { return nil }
        return (chapterIndex, segmentIndex)
    }

    /// Recovers either legacy EPUB-index placement or anthology stable placement
    /// from a complete, current narration cache file. Deliberately strict: a
    /// cache cleanup must never adopt a malformed name that merely contains
    /// `-ck` or `-s` as an incidental substring.
    static func location(fromFileName fileName: String) -> NarrationCacheLocation? {
        let range = NSRange(fileName.startIndex..., in: fileName)
        if let match = stableLocationPattern.firstMatch(in: fileName, range: range) {
            guard integerCapture(match, at: 4, in: fileName) == renderVersion,
                let identityToken = stringCapture(match, at: 3, in: fileName),
                isRecognizedRenderIdentity(identityToken)
            else {
                return nil
            }
            let tokenRange = Range(match.range(at: 1), in: fileName)!
            let segmentIndex = integerCapture(match, at: 2, in: fileName)
            return NarrationCacheLocation(
                chapterIndex: nil,
                stableChapterToken: String(fileName[tokenRange]),
                segmentIndex: segmentIndex)
        }
        if let match = legacyLocationPattern.firstMatch(in: fileName, range: range),
            let chapterIndex = integerCapture(match, at: 1, in: fileName),
            let identityToken = stringCapture(match, at: 3, in: fileName),
            isRecognizedRenderIdentity(identityToken)
        {
            return NarrationCacheLocation(
                chapterIndex: chapterIndex,
                stableChapterToken: nil,
                segmentIndex: integerCapture(match, at: 2, in: fileName))
        }
        return nil
    }

    static func isCurrentChapterCacheFileName(
        _ fileName: String,
        audiobookID: String,
        chapterIndex expectedChapterIndex: Int,
        voice: VoiceID,
        includingPartial: Bool = false
    ) -> Bool {
        let durableName: String
        if fileName.hasSuffix(".partial") {
            guard includingPartial else { return false }
            durableName = String(fileName.dropLast(".partial".count))
        } else if fileName.hasPrefix(".") && fileName.hasSuffix(".partial.m4a") {
            guard includingPartial else { return false }
            let partialName = fileName.dropFirst().dropLast(".partial.m4a".count)
            durableName = "\(partialName).m4a"
        } else {
            durableName = fileName
        }
        guard durableName.hasPrefix("\(safeToken(audiobookID))-ch") else { return false }
        guard chapterIndex(fromFileName: durableName) == expectedChapterIndex else { return false }
        guard segmentLocation(fromFileName: durableName) == nil else { return false }
        return durableName.hasSuffix("-\(voice.rawValue)-v\(renderVersion).m4a")
    }

    private static func signatureFragment(_ contentSignature: String?) -> String {
        guard let contentSignature else { return "" }
        let safe = contentSignature.filter { $0.isLetter || $0.isNumber }
        return safe.isEmpty ? "" : "-h\(safe)"
    }

    private static func renderIdentityToken(_ token: String) -> String {
        let safe = token.filter { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }
        return safe.isEmpty ? "voice" : safe
    }

    private static let stableLocationPattern = try! NSRegularExpression(
        pattern:
            "^[A-Za-z0-9_]+-ck([0-9a-f]{32})(?:-s([0-9]+))?(?:-h[A-Za-z0-9]+)?-([A-Za-z0-9_-]+)-v([0-9]+)\\.m4a$"
    )
    private static let legacyLocationPattern = try! NSRegularExpression(
        pattern:
            "^[A-Za-z0-9_]+-ch([0-9]+)(?:-s([0-9]+))?(?:-h[A-Za-z0-9]+)?-([A-Za-z0-9_-]+?)(?:-v[0-9]+)?\\.m4a$"
    )

    private static func isRecognizedRenderIdentity(_ token: String) -> Bool {
        VoiceCatalog.voice(for: VoiceID(token)) != nil
            || token.range(of: "^plan-[0-9a-f]{12}$", options: .regularExpression) != nil
    }

    private static func integerCapture(
        _ match: NSTextCheckingResult,
        at index: Int,
        in fileName: String
    ) -> Int? {
        let capture = match.range(at: index)
        guard capture.location != NSNotFound,
            let range = Range(capture, in: fileName)
        else { return nil }
        return Int(fileName[range])
    }

    private static func stringCapture(
        _ match: NSTextCheckingResult,
        at index: Int,
        in fileName: String
    ) -> String? {
        let capture = match.range(at: index)
        guard capture.location != NSNotFound,
            let range = Range(capture, in: fileName)
        else { return nil }
        return String(fileName[range])
    }
}

/// Pure helpers for keeping the rendered-narration directory tidy.
nonisolated enum NarrationCacheStore {
    /// Temporary compatibility entry point for the pre-plan narrator. File names
    /// belonging to `bookPrefix` that don't match the current voice
    /// *and* current render version — safe to delete when (re)rendering. This
    /// sweeps both stale-voice files and orphaned older-version renders (e.g. the
    /// un-versioned v1 files) so the cache doesn't grow without bound.
    static func staleVoiceFiles(
        _ fileNames: [String], bookPrefix: String, currentVoice: VoiceID
    ) -> [String] {
        let keepSuffix = "-\(currentVoice.rawValue)-v\(NarrationFileNaming.renderVersion).m4a"
        return fileNames.filter { $0.hasPrefix(bookPrefix) && !$0.hasSuffix(keepSuffix) }
    }

    /// The renderer owns cleanup only after it constructed a complete expected
    /// plan. Keeping every expected durable name lets an anthology use multiple
    /// voices while deleting stale voice, signature, version, and partial files.
    static func staleFiles(
        _ fileNames: [String],
        bookPrefix: String,
        expectedDurableFileNames: Set<String>
    ) -> [String] {
        // An empty expected set means plan construction failed or was skipped;
        // never turn that failure into deletion of a whole book's cache.
        guard !expectedDurableFileNames.isEmpty else { return [] }
        return fileNames.filter {
            ($0.hasPrefix(bookPrefix) || $0.hasPrefix(".\(bookPrefix)"))
                && !expectedDurableFileNames.contains($0)
        }
    }
}
