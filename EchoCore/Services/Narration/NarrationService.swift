// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import Foundation
import GRDB
import os.log

#if DEBUG
    import Synchronization
#endif

enum NarrationError: Error, Equatable {
    case synthesisFailed
    case audiobookNotFound
    /// A single sub-chunk exceeded the model's input length cap. Surfaced so a
    /// test double can exercise the "skip this sub-chunk, keep the chapter" path;
    /// the ONNX engine raises it when a chunk can't be synthesized within bounds.
    case lengthCapExceeded
    /// A CoreML model package failed to download/verify from Hugging Face.
    /// `underlying` is the transport error (or nil on a non-2xx HTTP status);
    /// kept optional + not compared for `Equatable` since the underlying error
    /// is not itself `Equatable`.
    case modelDownloadFailed(name: String, underlying: Error?)
    /// The narration engine was asked to synthesize before `prepare()` succeeded.
    case engineUnavailable

    static func == (lhs: NarrationError, rhs: NarrationError) -> Bool {
        switch (lhs, rhs) {
        case (.synthesisFailed, .synthesisFailed),
            (.audiobookNotFound, .audiobookNotFound),
            (.lengthCapExceeded, .lengthCapExceeded),
            (.engineUnavailable, .engineUnavailable):
            return true
        case (.modelDownloadFailed(let l, _), .modelDownloadFailed(let r, _)):
            return l == r
        default:
            return false
        }
    }
}

/// Renders narration one chapter at a time (render-then-play): synthesize each
/// block → write one AAC file → insert a TrackRecord + one `.synthesized`
/// AlignmentAnchorRecord per text block. Mirrors AutoAlignmentService.
@MainActor @Observable
final class NarrationService {
    private let logger = Logger(category: "Narration")
    /// Bounded recursion depth for the low-quality synthesis retry. Exposed
    /// (non-`private`) only so a test can assert the recursion stops at exactly
    /// this cap; nothing outside this type mutates it.
    static let maximumQualityRetryDepth = 3
    #if DEBUG
        /// Test-only instrumentation: how many times the bounded-retry-depth guard
        /// fired. Under the current phoneme-split budget the split-count guard stops
        /// the recursion at the SAME depth as this cap, so the black-box output is
        /// identical whether the cap or the split-count guard terminates. This
        /// counter is the only signal that distinguishes them, letting a test pin
        /// the depth-cap branch independently. Not compiled into release builds.
        private(set) var debugRetryDepthCapHits = 0
    #endif
    /// Trailing silence appended to every rendered chapter so the final word
    /// isn't clipped when the player advances to the next chapter. Kokoro ends a
    /// chunk right on the last phoneme (no ring-out) and the gapless engine
    /// schedules the next track a hair before `duration` elapses; padding the
    /// file closes both gaps. Exposed `static` so the render-duration test can
    /// assert the exact padded length. ~0.75 s ≈ 0.4 s of dead air even at 2×.
    nonisolated static let leadOutPadSeconds: TimeInterval = 0.75
    /// Shared, reused across renders — allocating an `ISO8601DateFormatter` per
    /// `renderChapter` call is wasteful (§7.2). `@MainActor`-isolated via the
    /// class, so there's no Sendable concern around the non-Sendable formatter.
    private static let iso8601 = ISO8601DateFormatter()
    private let db: DatabaseWriter
    private let audiobookID: String
    let tts: TTSEngine
    private let audioWriter: AudioFileWriting
    private let cacheDirectory: URL
    let state: NarrationState
    private let fmEnabledProvider: () -> Bool
    /// Session-scoped cache for FM-normalized text. One instance per narration
    /// run so the same paragraph is only FM-processed once, even across chapters
    /// and voices. FM-unavailable or FM-makes-no-changes → passthrough (no-op).
    private let fmCache = FMNormalizationCache()

    /// Whether FM pre-normalization is enabled for this narration run.
    /// Respects the `narrationQAClassifier` UserDefaults key: when set to
    /// "deterministic", FM is off for both QA and pre-normalization.
    private var fmEnabled: Bool {
        fmEnabledProvider()
    }

    /// Supplies the user pronunciation overrides applied to each block's text
    /// after `TextNormalizer` and before chunking/synthesis. Evaluated as a
    /// closure (not a stored value) so the live `PronunciationOverrideStore` is
    /// read at render time; defaults to an empty map, so callers and tests that
    /// don't pass one are unaffected by the feature.
    private let pronunciationOverrides: () -> PronunciationOverrides
    /// Supplies source-position pronunciation overrides accepted from narration QA.
    /// Read at render time for the same reason as the word dictionary above.
    private let pronunciationOccurrenceOverrides: () -> PronunciationOccurrenceOverrides
    /// Immutable pronunciation source snapshot shared by planning and cache identity.
    private let pronunciationPack: EnglishPronunciationPack
    /// Advisory-only pronunciation source snapshot. It is never part of cache identity.
    private let pronunciationAuditPack: EnglishPronunciationAuditPack
    private let contextualPronunciationEvaluator: ContextualPronunciationBatchEvaluator
    private let neuralEvaluator: NeuralEvaluator?
    /// Test seam for the non-blocking advisory report write. Production uses the
    /// origin-scoped DAO path below.
    private let advisoryReportWriter: (([NarrationQualityIssueRecord], [String]) throws -> Void)?
    /// Test seam for computing the fallback portion of an atomic report
    /// snapshot. Production uses `PronunciationFallbackDiscovery.records`.
    private let fallbackDiscoveryRecordBuilder:
        (
            (
                [RenderedPronunciationFallbackHit], String
            ) throws -> [NarrationQualityIssueRecord]
        )?

    init(
        db: DatabaseWriter, audiobookID: String, tts: TTSEngine,
        audioWriter: AudioFileWriting, cacheDirectory: URL, state: NarrationState,
        pronunciationOverrides: @escaping () -> PronunciationOverrides = {
            PronunciationOverrides(entries: [:])
        },
        pronunciationOccurrenceOverrides: @escaping () -> PronunciationOccurrenceOverrides = {
            .empty
        },
        pronunciationPack: EnglishPronunciationPack = .empty,
        pronunciationAuditPack: EnglishPronunciationAuditPack = .empty,
        contextualPronunciationEvaluator: @escaping ContextualPronunciationBatchEvaluator =
            FoundationModelsContextualPronunciationEvaluator.notRequestedEvaluator(),
        neuralEvaluator: NeuralEvaluator? = nil,
        advisoryReportWriter: (([NarrationQualityIssueRecord], [String]) throws -> Void)? = nil,
        fallbackDiscoveryRecordBuilder: (
            (
                [RenderedPronunciationFallbackHit], String
            ) throws -> [NarrationQualityIssueRecord]
        )? = nil,
        fmEnabled: @escaping () -> Bool = {
            UserDefaults.standard.string(forKey: "narrationQAClassifier") ?? "auto" == "auto"
        }
    ) {
        self.db = db
        self.audiobookID = audiobookID
        self.tts = tts
        self.audioWriter = audioWriter
        self.cacheDirectory = cacheDirectory
        self.state = state
        self.pronunciationOverrides = pronunciationOverrides
        self.pronunciationOccurrenceOverrides = pronunciationOccurrenceOverrides
        self.pronunciationPack = pronunciationPack
        self.pronunciationAuditPack = pronunciationAuditPack
        self.contextualPronunciationEvaluator = contextualPronunciationEvaluator
        self.neuralEvaluator = neuralEvaluator
        self.advisoryReportWriter = advisoryReportWriter
        self.fallbackDiscoveryRecordBuilder = fallbackDiscoveryRecordBuilder
        self.fmEnabledProvider = fmEnabled
    }

    struct RenderedNarrationFile: Sendable {
        let chapterIndex: Int
        let chapterDisplayNumber: Int
        let segmentIndex: Int?
        let fileURL: URL
        let duration: TimeInterval
        let anchors: [AlignmentAnchorRecord]
        let spokenBlockIDs: [String]
        /// All source blocks whose plan was audited for this render unit. This
        /// intentionally includes blocks that did not produce audio, so a later
        /// zero-row advisory refresh can clear their stale local findings.
        let auditedBlockIDs: [String]
        /// Per-block synthesized speech ranges captured from the render stream.
        /// These ranges exclude planned silence so generated read-along rows do
        /// not stretch words through intentional pauses.
        let speechRangesByBlock: [String: [NarrationSpeechRange]]
        /// Per-block file-relative word timings captured at synthesis (empty when
        /// the engine emitted none). Applied over the interpolated baseline.
        let synthesisWordTimingsByBlock: [String: [ChunkWordTiming]]
        /// OOV fallback words encountered while synthesizing this render unit.
        let pronunciationFallbackHits: [RenderedPronunciationFallbackHit]
        /// Immutable plan decisions enriched only with timing observed while
        /// rendering this exact file. Decisions for skipped source remain range-free.
        let pronunciationDecisions: [PronunciationAuditDecision]
        /// Plan validation and incomplete-render evidence, associated with the
        /// chapter without fabricating a pronunciation decision or audio range.
        let pronunciationAuditDiagnostics: [PronunciationAuditDiagnostic]

        init(
            chapterIndex: Int,
            chapterDisplayNumber: Int,
            segmentIndex: Int?,
            fileURL: URL,
            duration: TimeInterval,
            anchors: [AlignmentAnchorRecord],
            spokenBlockIDs: [String],
            auditedBlockIDs: [String]? = nil,
            speechRangesByBlock: [String: [NarrationSpeechRange]] = [:],
            synthesisWordTimingsByBlock: [String: [ChunkWordTiming]],
            pronunciationFallbackHits: [RenderedPronunciationFallbackHit] = [],
            pronunciationDecisions: [PronunciationAuditDecision] = [],
            pronunciationAuditDiagnostics: [PronunciationAuditDiagnostic] = []
        ) {
            self.chapterIndex = chapterIndex
            self.chapterDisplayNumber = chapterDisplayNumber
            self.segmentIndex = segmentIndex
            self.fileURL = fileURL
            self.duration = duration
            self.anchors = anchors
            self.spokenBlockIDs = spokenBlockIDs
            self.auditedBlockIDs = auditedBlockIDs ?? spokenBlockIDs
            self.speechRangesByBlock = speechRangesByBlock
            self.synthesisWordTimingsByBlock = synthesisWordTimingsByBlock
            self.pronunciationFallbackHits = pronunciationFallbackHits
            self.pronunciationDecisions = pronunciationDecisions
            self.pronunciationAuditDiagnostics = pronunciationAuditDiagnostics
        }
    }

    func chapterCacheURL(
        chapterIndex: Int,
        sourceChapterKey: String? = nil,
        blocks: [EPubBlockRecord],
        voice: VoiceID
    ) async -> URL {
        await chapterCacheURL(
            chapterIndex: chapterIndex,
            sourceChapterKey: sourceChapterKey,
            blocks: blocks,
            voice: voice,
            overrides: pronunciationOverrides(),
            occurrenceOverrides: pronunciationOccurrenceOverrides(),
            normalizationMode: Self.normalizationMode(fmEnabled: fmEnabled),
            pronunciationPack: pronunciationPack)
    }

    func segmentCacheURL(
        chapterIndex: Int,
        sourceChapterKey: String? = nil,
        segmentIndex: Int,
        blocks: [EPubBlockRecord],
        voice: VoiceID
    ) async -> URL {
        await segmentCacheURL(
            chapterIndex: chapterIndex,
            sourceChapterKey: sourceChapterKey,
            segmentIndex: segmentIndex,
            blocks: blocks,
            voice: voice,
            overrides: pronunciationOverrides(),
            occurrenceOverrides: pronunciationOccurrenceOverrides(),
            normalizationMode: Self.normalizationMode(fmEnabled: fmEnabled),
            pronunciationPack: pronunciationPack)
    }

    private func chapterCacheURL(
        chapterIndex: Int,
        sourceChapterKey: String? = nil,
        blocks: [EPubBlockRecord],
        voice: VoiceID,
        renderIdentityToken: String? = nil,
        overrides: PronunciationOverrides,
        occurrenceOverrides: PronunciationOccurrenceOverrides,
        normalizationMode: String,
        pronunciationPack: EnglishPronunciationPack
    ) async -> URL {
        let signature = await Self.contentSignatureOffMain(
            for: blocks,
            includeLeadOutPad: true,
            overrides: overrides,
            occurrenceOverrides: occurrenceOverrides,
            normalizationMode: normalizationMode,
            pronunciationPack: pronunciationPack)
        let fileName: String
        if let renderIdentityToken {
            fileName = NarrationFileNaming.chapterFileName(
                audiobookID: audiobookID,
                chapterIndex: chapterIndex,
                sourceChapterKey: sourceChapterKey,
                renderIdentityToken: renderIdentityToken,
                contentSignature: signature)
        } else {
            fileName = NarrationFileNaming.chapterFileName(
                audiobookID: audiobookID,
                chapterIndex: chapterIndex,
                sourceChapterKey: sourceChapterKey,
                voice: voice,
                contentSignature: signature)
        }
        return cacheDirectory.appendingPathComponent(fileName)
    }

    private func segmentCacheURL(
        chapterIndex: Int,
        sourceChapterKey: String? = nil,
        segmentIndex: Int,
        blocks: [EPubBlockRecord],
        voice: VoiceID,
        overrides: PronunciationOverrides,
        occurrenceOverrides: PronunciationOccurrenceOverrides,
        normalizationMode: String,
        pronunciationPack: EnglishPronunciationPack
    ) async -> URL {
        let signature = await Self.contentSignatureOffMain(
            for: blocks,
            includeLeadOutPad: false,
            overrides: overrides,
            occurrenceOverrides: occurrenceOverrides,
            normalizationMode: normalizationMode,
            pronunciationPack: pronunciationPack)
        return cacheDirectory.appendingPathComponent(
            NarrationFileNaming.segmentFileName(
                audiobookID: audiobookID,
                chapterIndex: chapterIndex,
                sourceChapterKey: sourceChapterKey,
                segmentIndex: segmentIndex,
                voice: voice,
                contentSignature: signature))
    }

    nonisolated static func contentSignature(
        for blocks: [EPubBlockRecord],
        includeLeadOutPad: Bool,
        overrides: PronunciationOverrides,
        occurrenceOverrides: PronunciationOccurrenceOverrides,
        normalizationMode: String,
        pronunciationPack: EnglishPronunciationPack
    ) -> String {
        let spoken = blocks.filter { $0.text?.isEmpty == false }
        var renderedTexts: [String] = []
        renderedTexts.reserveCapacity(spoken.count)
        for block in spoken {
            if let cueText = NarrationCodeBlockCue.spokenText(for: block) {
                // Code bypasses normalization and pronunciation overrides at
                // render time, so its cache identity must use that exact cue.
                renderedTexts.append(cueText)
                continue
            }
            let normalized =
                (block.pronunciationAnnotations == nil
                    ? TextNormalizer.normalize(block.text ?? "") : (block.text ?? ""))
            renderedTexts.append(
                Self.renderedText(
                    fromNormalized: normalized,
                    blockID: block.id,
                    overrides: overrides,
                    occurrenceOverrides: occurrenceOverrides))
        }
        return NarrationFileNaming.contentSignature(
            spokenBlocks: spoken,
            renderedTexts: renderedTexts,
            includeLeadOutPad: includeLeadOutPad,
            normalizationMode: normalizationMode,
            pronunciationPolicySignature: pronunciationPack.productionPolicySignature)
    }

    #if DEBUG
        /// Test-only observation seam: records whether the most recent
        /// `normalizeBlocksOffMain` call executed its body on the main thread.
        /// Mutex-protected (not `nonisolated(unsafe)`) because this seam is NOT
        /// single-writer in practice: production `prepareBlocksForRenderPlan`
        /// calls `normalizeBlocksOffMain` too, and several tests in
        /// `NarrationOffMainPlanningTests` call it directly. Nothing races
        /// today only because the Makefile pins `-parallel-testing-enabled NO`
        /// (Makefile:91,99) — there's no `.xctestplan` enforcing that for an
        /// Xcode-UI test run, so the mutex is what actually keeps this correct
        /// rather than an assumption about how tests happen to be invoked.
        /// Exists so the off-main guarantee is verified empirically instead of
        /// trusted from the `@concurrent` annotation alone.
        nonisolated static let debugNormalizeBlocksRanOnMainThread = Mutex<Bool?>(nil)
        /// Same seam for `contentSignatureOffMain`.
        nonisolated static let debugContentSignatureOffMainRanOnMainThread = Mutex<Bool?>(nil)
        /// Same empirical executor seam for cached-file validation.
        nonisolated static let debugCacheValidationRanOnMainThread = Mutex<Bool?>(nil)
        /// Records the executor at the invalid-cache deletion point separately,
        /// so validation cannot move off-main while deletion drifts back onto it.
        nonisolated static let debugInvalidCacheDeletionRanOnMainThread = Mutex<Bool?>(nil)
        /// `Thread.isMainThread` is `NS_SWIFT_UNAVAILABLE_FROM_ASYNC` — reading it
        /// directly inside an `async` function body doesn't compile. This
        /// synchronous wrapper is the sanctioned way to read it from async code.
        nonisolated private static func debugIsMainThread() -> Bool { Thread.isMainThread }
    #endif

    /// Runs TextNormalizer over every spoken, non-code block OFF the main
    /// actor. `@concurrent` is what actually moves this onto the cooperative
    /// pool: this project builds with `SWIFT_APPROACHABLE_CONCURRENCY = YES`,
    /// which enables `NonisolatedNonsendingByDefault` — under that mode a
    /// plain `nonisolated async` function runs ON the caller's actor, not off
    /// it. Do not drop `@concurrent` under the assumption that `nonisolated
    /// async` alone suspends off-main; it does not, here. Returns
    /// blockID → normalized text.
    @concurrent
    nonisolated static func normalizeBlocksOffMain(
        _ blocks: [EPubBlockRecord]
    ) async -> [String: String] {
        #if DEBUG
            let isMainThread = Self.debugIsMainThread()
            Self.debugNormalizeBlocksRanOnMainThread.withLock { $0 = isMainThread }
        #endif
        var result: [String: String] = [:]
        result.reserveCapacity(blocks.count)
        for block in blocks {
            guard let text = block.text, !text.isEmpty, !block.isHidden,
                NarrationCodeBlockCue.spokenText(for: block) == nil
            else { continue }
            result[block.id] =
                block.pronunciationAnnotations == nil ? TextNormalizer.normalize(text) : text
        }
        return result
    }

    /// Off-main wrapper for contentSignature — same output, computed on the
    /// cooperative pool instead of the main thread. See
    /// `normalizeBlocksOffMain`'s doc comment: `@concurrent` (not plain
    /// `nonisolated async`) is what makes that true under this project's
    /// `SWIFT_APPROACHABLE_CONCURRENCY` build setting.
    @concurrent
    nonisolated static func contentSignatureOffMain(
        for blocks: [EPubBlockRecord],
        includeLeadOutPad: Bool,
        overrides: PronunciationOverrides,
        occurrenceOverrides: PronunciationOccurrenceOverrides,
        normalizationMode: String,
        pronunciationPack: EnglishPronunciationPack
    ) async -> String {
        #if DEBUG
            let isMainThread = Self.debugIsMainThread()
            Self.debugContentSignatureOffMainRanOnMainThread.withLock { $0 = isMainThread }
        #endif
        return contentSignature(
            for: blocks, includeLeadOutPad: includeLeadOutPad, overrides: overrides,
            occurrenceOverrides: occurrenceOverrides, normalizationMode: normalizationMode,
            pronunciationPack: pronunciationPack)
    }

    nonisolated private static func renderedText(
        fromNormalized normalized: String,
        blockID: String,
        overrides: PronunciationOverrides,
        occurrenceOverrides: PronunciationOccurrenceOverrides
    ) -> String {
        let occurrenceSpecific = occurrenceOverrides.apply(to: normalized, blockID: blockID)
        return HomographPronunciationResolver.apply(to: overrides.apply(to: occurrenceSpecific))
    }

    static func normalizationMode(fmEnabled: Bool) -> String {
        fmEnabled ? "fm-auto-v\(FMNormalizer.signatureVersion)" : "deterministic"
    }

    private func partialCacheURL(for fileURL: URL) -> URL {
        let baseName = fileURL.deletingPathExtension().lastPathComponent
        let partialName = ".\(baseName).partial"
        let directory = fileURL.deletingLastPathComponent()
        let partialURL = directory.appendingPathComponent(partialName)
        let pathExtension = fileURL.pathExtension
        return pathExtension.isEmpty ? partialURL : partialURL.appendingPathExtension(pathExtension)
    }

    /// Render one chapter. Cancellable between blocks; on cancel, nothing is persisted.
    /// Idempotent: re-rendering the same chapter (e.g. a voice change) upserts in place.
    ///
    /// `chapterIndex` is the mutable EPUB order used for presentation; anthology
    /// callers supply `sourceChapterKey` to keep cache and track identity stable.
    /// `chapterNumber` is the human-facing
    /// 1-based position among *narratable* chapters (front matter excluded), used
    /// only for the title and status text so the first real chapter reads
    /// "Chapter 1". Defaults to `chapterIndex + 1` when omitted (tests that don't
    /// exercise numbering).
    /// Render one chapter using the selected voice for each original EPUB block.
    @discardableResult
    func renderChapter(
        chapterIndex: Int, sourceChapterKey: String? = nil, chapterNumber: Int? = nil,
        blocks: [EPubBlockRecord], voice: VoiceID,
        blockVoice: @escaping @Sendable (String) -> VoiceID,
        renderIdentityToken: String? = nil,
        chapterTitle: String? = nil,
        onBlockProgress: (@MainActor (NarrationRenderProgress) -> Void)? = nil
    ) async throws -> RenderedNarrationFile {
        let displayNumber = chapterNumber ?? (chapterIndex + 1)
        let savedTitle = Self.savedTitle(
            displayNumber: displayNumber, blocks: blocks, chapterTitle: chapterTitle)
        let chapterStart = Date()
        let overrides = pronunciationOverrides()
        let occurrenceOverrides = pronunciationOccurrenceOverrides()
        let fmEnabled = fmEnabled
        let fileURL = await chapterCacheURL(
            chapterIndex: chapterIndex,
            sourceChapterKey: sourceChapterKey,
            blocks: blocks,
            voice: voice,
            renderIdentityToken: renderIdentityToken,
            overrides: overrides,
            occurrenceOverrides: occurrenceOverrides,
            normalizationMode: Self.normalizationMode(fmEnabled: fmEnabled),
            pronunciationPack: pronunciationPack)
        let rendered = try await renderNarrationFile(
            chapterIndex: chapterIndex,
            chapterDisplayNumber: displayNumber,
            segmentIndex: nil,
            blocks: blocks,
            voice: voice,
            blockVoice: blockVoice,
            fileURL: fileURL,
            includeLeadOutPad: true,
            reportsProgress: true,
            overrides: overrides,
            occurrenceOverrides: occurrenceOverrides,
            fmEnabled: fmEnabled,
            onBlockProgress: onBlockProgress)
        try await persistRenderedNarration(
            rendered,
            trackID: NarrationFileNaming.trackID(
                audiobookID: audiobookID,
                chapterIndex: chapterIndex,
                sourceChapterKey: sourceChapterKey,
                segmentIndex: nil),
            title: savedTitle,
            sortOrder: chapterIndex,
            voice: voice)

        logger.notice(
            "Chapter \(displayNumber) rendered: \(rendered.anchors.count) anchors, ~\(Int(rendered.duration))s audio, in \(Int(Date().timeIntervalSince(chapterStart)))s."
        )
        return rendered
    }

    /// Render and persist one segment as a playable synthesized track. Anchors
    /// remain segment-local (0-based) and the matching timeline rows are stamped
    /// with `segment_key` so read-along can disambiguate same-chapter time
    /// collisions when segment files are eventually queued for playback.
    @discardableResult
    func renderSegment(
        chapterIndex: Int,
        sourceChapterKey: String? = nil,
        chapterDisplayNumber: Int,
        segmentIndex: Int,
        blocks: [EPubBlockRecord],
        voice: VoiceID,
        chapterTitle: String? = nil,
        onBlockProgress: (@MainActor (NarrationRenderProgress) -> Void)? = nil
    ) async throws -> RenderedNarrationFile {
        let savedTitle = Self.savedTitle(
            displayNumber: chapterDisplayNumber, blocks: blocks, chapterTitle: chapterTitle)
        let rendered = try await renderSegmentFile(
            chapterIndex: chapterIndex,
            sourceChapterKey: sourceChapterKey,
            chapterDisplayNumber: chapterDisplayNumber,
            segmentIndex: segmentIndex,
            blocks: blocks,
            voice: voice,
            onBlockProgress: onBlockProgress)

        try await persistRenderedNarration(
            rendered,
            trackID: NarrationFileNaming.trackID(
                audiobookID: audiobookID,
                chapterIndex: chapterIndex,
                sourceChapterKey: sourceChapterKey,
                segmentIndex: segmentIndex),
            title: savedTitle,
            sortOrder: chapterIndex * 1000 + segmentIndex,
            voice: voice,
            segmentKey: ReaderActiveBlockResolver.segmentKey(
                forChapter: chapterIndex,
                segment: segmentIndex))
        return rendered
    }

    /// Reconciles persisted metadata for a validated cache file.
    ///
    /// Returns `false` after removing an invalid cache candidate so the caller
    /// can run its normal, observable rendering path.
    @discardableResult
    func updateCachedNarrationTitle(
        chapterIndex: Int,
        sourceChapterKey: String? = nil,
        chapterDisplayNumber: Int,
        segmentIndex: Int? = nil,
        blocks: [EPubBlockRecord],
        voice: VoiceID,
        chapterTitle: String? = nil
    ) async throws -> Bool {
        let savedTitle = Self.savedTitle(
            displayNumber: chapterDisplayNumber, blocks: blocks, chapterTitle: chapterTitle)
        let fileURL: URL
        if let segmentIndex {
            fileURL = await segmentCacheURL(
                chapterIndex: chapterIndex,
                sourceChapterKey: sourceChapterKey,
                segmentIndex: segmentIndex,
                blocks: blocks,
                voice: voice)
        } else {
            fileURL = await chapterCacheURL(
                chapterIndex: chapterIndex,
                sourceChapterKey: sourceChapterKey,
                blocks: blocks,
                voice: voice)
        }
        let trackID = NarrationFileNaming.trackID(
            audiobookID: audiobookID,
            chapterIndex: chapterIndex,
            sourceChapterKey: sourceChapterKey,
            segmentIndex: segmentIndex)
        let sortOrder = segmentIndex.map { chapterIndex * 1000 + $0 } ?? chapterIndex

        guard
            let duration = try await Self.validatedDurationOrRemoveInvalidCache(
                ofCachedFile: fileURL)
        else {
            return false
        }
        try Task.checkCancellation()
        try await db.write { db in
            let existing =
                try TrackRecord
                .filter(Column("id") == trackID && Column("audiobook_id") == audiobookID)
                .fetchOne(db)
            var track = TrackRecord(
                id: trackID,
                audiobookID: audiobookID,
                title: savedTitle,
                duration: duration,
                filePath: fileURL.path,
                isEnabled: existing?.isEnabled ?? true,
                sortOrder: sortOrder,
                playlistPosition: existing?.playlistPosition,
                narrationVoice: voice.rawValue)
            try track.save(db)
        }
        return true
    }

    /// Validates and, when invalid, removes a published cache file off the main
    /// actor. `@concurrent` is required because this project enables
    /// `NonisolatedNonsendingByDefault`; plain `nonisolated async` would inherit
    /// the caller's executor and leave synchronous resource metadata and deletion
    /// on `MainActor`.
    @concurrent
    private nonisolated static func validatedDurationOrRemoveInvalidCache(
        ofCachedFile fileURL: URL
    ) async throws -> TimeInterval? {
        #if DEBUG
            let validationRanOnMainThread = Self.debugIsMainThread()
            Self.debugCacheValidationRanOnMainThread.withLock {
                $0 = validationRanOnMainThread
            }
        #endif
        do {
            let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else {
                throw CocoaError(.fileReadNoSuchFile)
            }
            let duration = CMTimeGetSeconds(try await AVURLAsset(url: fileURL).load(.duration))
            guard duration.isFinite, duration > 0 else {
                throw NarrationError.synthesisFailed
            }
            return duration
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // A durable filename can survive process death after publish but before
            // persistence. Reuse only when AVFoundation proves the file duration;
            // otherwise discard the untrusted cache. The player owns rerendering so
            // progress, backpressure, and lifecycle events stay truthful.
            #if DEBUG
                let deletionRanOnMainThread = Self.debugIsMainThread()
                Self.debugInvalidCacheDeletionRanOnMainThread.withLock {
                    $0 = deletionRanOnMainThread
                }
            #endif
            try? FileManager.default.removeItem(at: fileURL)
            return nil
        }
    }

    /// Render one complete segment file without mutating playback, alignment, or
    /// chapter-render state. This is the safe primitive for the hybrid streaming
    /// path: orchestration can prove segment files first, then opt into track,
    /// read-along, and export semantics in later slices.
    func renderSegmentFile(
        chapterIndex: Int,
        sourceChapterKey: String? = nil,
        chapterDisplayNumber: Int,
        segmentIndex: Int,
        blocks: [EPubBlockRecord],
        voice: VoiceID,
        onBlockProgress: (@MainActor (NarrationRenderProgress) -> Void)? = nil
    ) async throws -> RenderedNarrationFile {
        let overrides = pronunciationOverrides()
        let occurrenceOverrides = pronunciationOccurrenceOverrides()
        let fmEnabled = fmEnabled
        let fileURL = await segmentCacheURL(
            chapterIndex: chapterIndex,
            sourceChapterKey: sourceChapterKey,
            segmentIndex: segmentIndex,
            blocks: blocks,
            voice: voice,
            overrides: overrides,
            occurrenceOverrides: occurrenceOverrides,
            normalizationMode: Self.normalizationMode(fmEnabled: fmEnabled),
            pronunciationPack: pronunciationPack)
        return try await renderNarrationFile(
            chapterIndex: chapterIndex,
            chapterDisplayNumber: chapterDisplayNumber,
            segmentIndex: segmentIndex,
            blocks: blocks,
            voice: voice,
            blockVoice: { _ in voice },
            fileURL: fileURL,
            includeLeadOutPad: false,
            reportsProgress: false,
            overrides: overrides,
            occurrenceOverrides: occurrenceOverrides,
            fmEnabled: fmEnabled,
            onBlockProgress: onBlockProgress)
    }

    private func persistRenderedNarration(
        _ rendered: RenderedNarrationFile,
        trackID: String,
        title: String,
        sortOrder: Int,
        voice: VoiceID,
        segmentKey: String? = nil
    ) async throws {
        try Task.checkCancellation()  // last gate before any DB write

        let track = TrackRecord(
            id: trackID,
            audiobookID: audiobookID,
            title: title,
            duration: rendered.duration,
            filePath: rendered.fileURL.path,
            isEnabled: true,
            sortOrder: sortOrder,
            playlistPosition: nil,
            narrationVoice: voice.rawValue)

        // One atomic, idempotent transaction off the main thread: upsert the track
        // + every anchor so a re-render (e.g. a voice change) updates in place
        // instead of throwing on a duplicate primary key, and a failure can't
        // leave a half-written render unit.
        let anchorsToSave = rendered.anchors
        try await db.write { db in
            var savedTrack = track
            try savedTrack.save(db)
            for var anchor in anchorsToSave { try anchor.save(db) }
        }

        // Propagate the just-saved `.synthesized` anchors into `timeline_item`:
        // that table — not `alignment_anchor` — is what the reader reads
        // (`WHERE audio_start_time >= 0`), so without this the reader shows no
        // timestamps and never highlights. Runs AFTER the anchor transaction
        // (recalc opens its own `db.write`, so it must not be nested). A recalc
        // failure must not fail the render — the audio is already on disk and the
        // anchors persisted; log and continue.
        let reportCreatedAt = Self.iso8601.string(from: Date())
        let advisoryRecords = PronunciationAdvisoryIssueBuilder().records(
            audiobookID: audiobookID,
            decisions: rendered.pronunciationDecisions,
            diagnostics: rendered.pronunciationAuditDiagnostics,
            createdAt: reportCreatedAt)
        let advisoryPreflightRecords = advisoryRecords.filter {
            $0.origin == NarrationQualityIssueOrigin.pronunciationPreflight.rawValue
        }
        let fallbackRecords: [NarrationQualityIssueRecord]?
        do {
            if let fallbackDiscoveryRecordBuilder {
                fallbackRecords = try fallbackDiscoveryRecordBuilder(
                    rendered.pronunciationFallbackHits, reportCreatedAt)
            } else {
                fallbackRecords = PronunciationFallbackDiscovery.records(
                    audiobookID: audiobookID,
                    hits: rendered.pronunciationFallbackHits,
                    createdAt: reportCreatedAt,
                    excluding: advisoryPreflightRecords)
            }
        } catch {
            state.record(
                .init(
                    category: .error,
                    severity: .warning,
                    message: String(localized: "Narration diagnostics could not be saved"),
                    developerMessage: "pronunciation fallback discovery failed",
                    privateDetail: error.localizedDescription))
            fallbackRecords = nil
        }

        if let fallbackRecords {
            do {
                let preflightRecords = advisoryPreflightRecords + fallbackRecords
                let acousticRecords = advisoryRecords.filter {
                    $0.origin == NarrationQualityIssueOrigin.acoustic.rawValue
                }
                if let advisoryReportWriter {
                    try advisoryReportWriter(
                        preflightRecords + acousticRecords,
                        rendered.auditedBlockIDs)
                } else {
                    try NarrationQualityIssueDAO(db: db).replaceOpen(
                        for: audiobookID,
                        blockIDs: rendered.auditedBlockIDs,
                        replacements: [
                            .init(origin: .pronunciationPreflight, records: preflightRecords),
                            .init(origin: .acoustic, records: acousticRecords),
                        ])
                }
            } catch {
                state.record(
                    .init(
                        category: .error,
                        severity: .warning,
                        message: String(localized: "Narration diagnostics could not be saved"),
                        developerMessage: "advisory report write failed",
                        privateDetail: error.localizedDescription))
            }
        }

        do {
            // `anchoredOnly`: only rendered blocks are anchored, so the global
            // synthetic-boundary + interpolation pass must be skipped — otherwise
            // un-narrated front matter gets a near-zero interpolated
            // `audio_start_time`, passes the reader's `>= 0` filter, and the
            // reader highlights front matter instead of the narrated unit.
            //
            // `materializeWordTimings: false`: the default would wipe & rebuild the
            // WHOLE book's `word_timing` table here — run once per render unit is
            // O(chapters²) over a render run. Instead we materialize just this
            // unit's words below, so per-word read-along lights up incrementally.
            try AlignmentService(db: db, audiobookID: audiobookID)
                .recalculateTimeline(anchoredOnly: true, materializeWordTimings: false)
            // Word rows are keyed to the source words the reader shows; the
            // mapping reports which of them were spoken as several words so the
            // synthesis timings can be folded onto the same basis below.
            var expansionCountsByBlock: [String: [Int]] = [:]
            if rendered.speechRangesByBlock.isEmpty {
                try WordTimingMaterializer.materializeChapter(
                    audiobookID: audiobookID, blockIDs: rendered.spokenBlockIDs, writer: db)
            } else {
                expansionCountsByBlock = try WordTimingMaterializer.materializeSynthesizedChapter(
                    audiobookID: audiobookID,
                    speechRangesByBlock: rendered.speechRangesByBlock,
                    writer: db)
            }
            let overridden = try WordTimingMaterializer.refineWithSynthesis(
                audiobookID: audiobookID,
                synthesisByBlock: rendered.synthesisWordTimingsByBlock,
                expansionCountsByBlock: expansionCountsByBlock,
                writer: db)
            if !rendered.synthesisWordTimingsByBlock.isEmpty {
                logger.notice(
                    "Synthesis word timing: \(overridden, privacy: .public)/\(rendered.synthesisWordTimingsByBlock.count, privacy: .public) blocks overrode interpolation (rest fell back)."
                )
            }
            // A block whose narration cannot be folded back onto its source
            // words keeps rows on the spoken basis. Those rows still match the
            // synthesis timings one-for-one, so the counter above reports them
            // as successes and only the sidecar export drops them — exactly the
            // silent partial application `applySidecarWords` was taught to log.
            let unalignable = rendered.speechRangesByBlock.count - expansionCountsByBlock.count
            if unalignable > 0 {
                logger.notice(
                    "Synthesis word timing: \(unalignable, privacy: .public) block(s) could not map narrated words back to source words; their word rows stay on the spoken basis and are omitted from the sidecar."
                )
            }
            if let segmentKey {
                let audioEndTimesByBlockID = Dictionary(
                    uniqueKeysWithValues: rendered.anchors.compactMap { anchor in
                        anchor.audioEndTime.map { (anchor.epubBlockID, $0) }
                    })
                try TimelineDAO(db: db).setSegmentKey(
                    audiobookID: audiobookID,
                    blockIDs: rendered.spokenBlockIDs,
                    segmentKey: segmentKey,
                    audioEndTimesByBlockID: audioEndTimesByBlockID)
                try TimelineDAO(db: db).restoreSegmentAudioEndTimesFromAnchors(
                    audiobookID: audiobookID)
            }
        } catch {
            let unitLabel =
                rendered.segmentIndex.map {
                    "chapter \(rendered.chapterIndex) segment \($0)"
                } ?? "chapter \(rendered.chapterIndex)"
            logger.error(
                "Timeline recalc after \(unitLabel) failed: \(error.localizedDescription)"
            )
        }

        // Tell the reader to reload so the newly-materialized timeline rows
        // light up read-along incrementally as each render unit lands. Mirrors
        // EPUBAutoImportScanner's post; the reader gates on the audiobookID.
        NotificationCenter.default.post(
            name: .timelineItemsIngested,
            object: nil,
            userInfo: ["audiobookID": audiobookID]
        )
    }

    private static func savedTitle(
        displayNumber: Int,
        blocks: [EPubBlockRecord],
        chapterTitle: String?
    ) -> String {
        let title = chapterTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let title, !title.isEmpty else {
            return NarrationChapterPlanner.title(displayNumber: displayNumber, blocks: blocks)
        }
        return title
    }

    private func renderNarrationFile(
        chapterIndex: Int,
        chapterDisplayNumber: Int,
        segmentIndex: Int?,
        blocks: [EPubBlockRecord],
        voice: VoiceID,
        blockVoice: @escaping @Sendable (String) -> VoiceID,
        fileURL: URL,
        includeLeadOutPad: Bool,
        reportsProgress: Bool,
        overrides: PronunciationOverrides,
        occurrenceOverrides: PronunciationOccurrenceOverrides,
        fmEnabled: Bool,
        onBlockProgress: (@MainActor (NarrationRenderProgress) -> Void)?
    ) async throws -> RenderedNarrationFile {
        let plan = try await renderPlan(
            for: blocks,
            overrides: overrides,
            occurrenceOverrides: occurrenceOverrides,
            fmEnabled: fmEnabled)
        let speakableBlockIDs = plan.blocks.filter(\.isSpeakable).map(\.blockID)
        var renderedSpeakableBlocks = 0
        let renderStartedAt = Date()
        if reportsProgress {
            state.transitionRender(
                to: .rendering(
                    NarrationRenderUnitStatus(
                        chapterDisplayNumber: chapterDisplayNumber,
                        segmentIndex: segmentIndex,
                        voiceID: voice,
                        completedBlocks: renderedSpeakableBlocks,
                        totalBlocks: speakableBlockIDs.count,
                        startedAt: renderStartedAt,
                        lastProgressAt: renderStartedAt)),
                event: nil,
                at: renderStartedAt)
        }
        onBlockProgress?(
            NarrationRenderProgress(
                chapterDisplayNumber: chapterDisplayNumber,
                segmentIndex: segmentIndex,
                voiceID: voice,
                completedBlocks: renderedSpeakableBlocks,
                totalBlocks: speakableBlockIDs.count,
                timestamp: renderStartedAt))
        let unitLabel =
            segmentIndex.map {
                "Chapter \(chapterDisplayNumber) segment \($0 + 1)"
            } ?? "Chapter \(chapterDisplayNumber)"
        logger.notice("\(unitLabel): synthesizing \(speakableBlockIDs.count) block(s)…")
        var anchors: [AlignmentAnchorRecord] = []
        var spokenBlockIDs: [String] = []
        var speechRangesByBlock: [String: [NarrationSpeechRange]] = [:]
        var synthesisWordTimingsByBlock: [String: [ChunkWordTiming]] = [:]
        var pronunciationFallbackHits: [RenderedPronunciationFallbackHit] = []
        var renderedOriginalChunks: [RenderedOriginalSynthesisChunk] = []
        var pronunciationAuditDiagnostics = plan.pronunciationAuditDiagnostics.map {
            $0.attachingChapter(chapterIndex)
        }
        var cursor: TimeInterval = 0
        let now = Self.iso8601.string(from: Date())

        // Stream-to-sink: encode each synthesized sub-chunk straight to a hidden
        // sibling partial, then publish the durable cache file only after finalize()
        // succeeds. The partial keeps an .m4a extension for AVFoundation, while
        // its non-canonical name keeps playback/export from reusing it.
        let partialURL = partialCacheURL(for: fileURL)
        let fm = FileManager.default
        try? fm.removeItem(at: partialURL)
        var didPublishFinalFile = false
        let stream = try audioWriter.makeStream(to: partialURL, sampleRate: 24_000)
        defer {
            if !didPublishFinalFile {
                try? fm.removeItem(at: partialURL)
            }
        }

        for plannedBlock in plan.blocks {
            try Task.checkCancellation()
            let block = plannedBlock.originalBlock
            let selectedVoice = plannedBlock.isSpeakable ? blockVoice(plannedBlock.blockID) : voice

            // Bound each synthesize call under Kokoro's ~510-phoneme context window
            // (see NarrationTextChunker for the budget). One anchor per ORIGINAL
            // block (keyed on block.id) is preserved by spanning the summed sub-chunk
            // durations, so read-along is unchanged regardless of how it sub-chunks.
            var blockDuration: TimeInterval = 0
            var timing = NarrationSynthesisTiming(blockID: plannedBlock.blockID, blockStart: cursor)
            var blockChunkTimings: [(timings: [ChunkWordTiming]?, startInFile: TimeInterval)] = []
            var originalWordBase = 0
            for (originalChunkIndex, synthesisChunk) in plannedBlock.synthesisChunks.enumerated() {
                try Task.checkCancellation()
                let identity = OriginalSynthesisChunkIdentity(
                    blockID: plannedBlock.blockID,
                    chunkIndex: originalChunkIndex,
                    wordBase: originalWordBase,
                    wordCount: synthesisChunk.wordCount)
                do {
                    let synthesisResult = try await synthesizeWithQualityRetry(
                        synthesisChunk,
                        voice: selectedVoice
                    )
                    let synthesizedChunks = synthesisResult.chunks
                    let originalChunkStartInFile = cursor + blockDuration
                    var renderedChildren: [RenderedSynthesisChild] = []
                    renderedChildren.reserveCapacity(synthesizedChunks.count)
                    for synthesized in synthesizedChunks {
                        let chunk = synthesized.audio
                        let chunkStartInFile = cursor + blockDuration
                        try await stream.append(chunk)
                        timing.appendSpeech(
                            text: synthesized.plan.displayText,
                            duration: chunk.duration)
                        blockChunkTimings.append((chunk.wordTimings, chunkStartInFile))
                        pronunciationFallbackHits.append(
                            contentsOf: chunk.pronunciationFallbackHits.map {
                                RenderedPronunciationFallbackHit(
                                    blockID: block.id,
                                    audioStartTime: chunkStartInFile,
                                    audioEndTime: chunkStartInFile + chunk.duration,
                                    fallback: $0)
                            })
                        blockDuration += chunk.duration
                        renderedChildren.append(
                            RenderedSynthesisChild(
                                plan: synthesized.plan,
                                audio: chunk,
                                startInFile: chunkStartInFile))
                    }
                    let renderedDuration = cursor + blockDuration - originalChunkStartInFile
                    if synthesisResult.allAccepted,
                        renderedDuration.isFinite, renderedDuration > 0, identity.wordCount > 0
                    {
                        renderedOriginalChunks.append(
                            RenderedOriginalSynthesisChunk(
                                identity: identity,
                                exactWordRanges: Self.exactWordRanges(
                                    parent: synthesisChunk,
                                    children: renderedChildren) ?? [:]))
                    } else if !synthesisResult.allAccepted {
                        pronunciationAuditDiagnostics.append(
                            .qualityRejected(
                                blockID: plannedBlock.blockID,
                                chunkIndex: originalChunkIndex,
                                chapterIndex: chapterIndex,
                                expectedDisplayText: synthesisChunk.displayText,
                                fallbackHits: synthesisChunk.pronunciationFallbackHits))
                    }
                } catch is CancellationError {
                    throw CancellationError()
                } catch let error where Self.isLengthCapError(error) {
                    // A length-cap throw from one sub-chunk must not abort the
                    // whole render unit — skip it and keep going.
                    logger.error(
                        "Skipping over-long sub-chunk in block \(block.id): \(error.localizedDescription)"
                    )
                    pronunciationAuditDiagnostics.append(
                        .incompleteRender(
                            blockID: plannedBlock.blockID,
                            chunkIndex: originalChunkIndex,
                            chapterIndex: chapterIndex,
                            expectedDisplayText: synthesisChunk.displayText,
                            fallbackHits: synthesisChunk.pronunciationFallbackHits))
                }
                // Stable source identity advances by the immutable planned word
                // count even when a child timing is missing or the chunk was skipped.
                originalWordBase += synthesisChunk.wordCount
            }
            if let assembled = NarrationWordTimingAssembler.assemble(blockChunkTimings) {
                synthesisWordTimingsByBlock[block.id] = assembled
            }
            if !timing.speechRanges.isEmpty {
                speechRangesByBlock[plannedBlock.blockID] = timing.speechRanges
            }

            if plannedBlock.isSpeakable {
                if blockDuration > 0 {
                    anchors.append(
                        AlignmentAnchorRecord(
                            id: "syn-\(audiobookID)-\(block.id)",
                            audiobookID: audiobookID, epubBlockID: block.id,
                            audioTime: cursor, audioEndTime: cursor + blockDuration,
                            anchorKind: AlignmentAnchorRecord.AnchorKind.point.rawValue,
                            source: AlignmentAnchorRecord.Source.synthesized.rawValue,
                            note: nil, createdAt: now, modifiedAt: now))
                    cursor += blockDuration
                    spokenBlockIDs.append(block.id)
                }
                renderedSpeakableBlocks += 1
                logger.notice(
                    "  \(unitLabel): block \(renderedSpeakableBlocks)/\(speakableBlockIDs.count) synthesized"
                )
                let progressAt = Date()
                if reportsProgress {
                    state.transitionRender(
                        to: .rendering(
                            NarrationRenderUnitStatus(
                                chapterDisplayNumber: chapterDisplayNumber,
                                segmentIndex: segmentIndex,
                                voiceID: voice,
                                completedBlocks: renderedSpeakableBlocks,
                                totalBlocks: speakableBlockIDs.count,
                                startedAt: renderStartedAt,
                                lastProgressAt: progressAt)),
                        event: nil,
                        at: progressAt)
                }
                onBlockProgress?(
                    NarrationRenderProgress(
                        chapterDisplayNumber: chapterDisplayNumber,
                        segmentIndex: segmentIndex,
                        voiceID: voice,
                        completedBlocks: renderedSpeakableBlocks,
                        totalBlocks: speakableBlockIDs.count,
                        timestamp: progressAt))
            }
            if let silence = plannedBlock.trailingSilence {
                try await stream.append(.silence(seconds: silence.duration, sampleRate: 24_000))
                cursor += silence.duration
            }
        }

        // Lead-out pad: append trailing silence so the last word has room to ring
        // out and the player can't advance to the next file mid-word. Added AFTER
        // the anchor loop, so the silence is unanchored dead air.
        if includeLeadOutPad, cursor > 0 {
            try await stream.append(
                .silence(seconds: Self.leadOutPadSeconds, sampleRate: 24_000))
        }

        try Task.checkCancellation()
        let duration = try await stream.finalize()
        try Task.checkCancellation()
        if fm.fileExists(atPath: partialURL.path) {
            if fm.fileExists(atPath: fileURL.path) {
                _ = try fm.replaceItemAt(fileURL, withItemAt: partialURL)
            } else {
                try fm.moveItem(at: partialURL, to: fileURL)
            }
        }
        didPublishFinalFile = true

        let pronunciationDecisions = Self.renderedPronunciationDecisions(
            plan: plan,
            chapterIndex: chapterIndex,
            renderedFileDuration: duration,
            anchors: anchors,
            renderedOriginalChunks: renderedOriginalChunks)

        return RenderedNarrationFile(
            chapterIndex: chapterIndex,
            chapterDisplayNumber: chapterDisplayNumber,
            segmentIndex: segmentIndex,
            fileURL: fileURL,
            duration: duration,
            anchors: anchors,
            spokenBlockIDs: spokenBlockIDs,
            auditedBlockIDs: plan.blocks.map(\.blockID),
            speechRangesByBlock: speechRangesByBlock,
            synthesisWordTimingsByBlock: synthesisWordTimingsByBlock,
            pronunciationFallbackHits: pronunciationFallbackHits,
            pronunciationDecisions: pronunciationDecisions,
            pronunciationAuditDiagnostics: pronunciationAuditDiagnostics)
    }

    func renderPlan(
        for blocks: [EPubBlockRecord],
        overrides: PronunciationOverrides,
        occurrenceOverrides: PronunciationOccurrenceOverrides,
        fmEnabled: Bool
    ) async throws -> NarrationRenderPlan {
        let preparedBlocks = await prepareBlocksForRenderPlan(
            blocks,
            occurrenceOverrides: occurrenceOverrides,
            fmEnabled: fmEnabled)
        return try await Self.planPreparedBlocks(
            preparedBlocks, overrides: overrides, pronunciationPack: pronunciationPack,
            pronunciationAuditPack: pronunciationAuditPack,
            contextualPronunciationEvaluator: contextualPronunciationEvaluator,
            neuralEvaluator: neuralEvaluator)
    }

    #if DEBUG
        nonisolated static let debugRenderPlanningRanOnMainThread = Mutex<Bool?>(nil)
    #endif

    /// A render unit owns its planner and mutable G2P cache entirely on the
    /// cooperative executor. Only immutable Sendable inputs cross from the UI.
    @concurrent
    private nonisolated static func planPreparedBlocks(
        _ preparedBlocks: [NarrationPreparedBlock],
        overrides: PronunciationOverrides,
        pronunciationPack: EnglishPronunciationPack,
        pronunciationAuditPack: EnglishPronunciationAuditPack,
        contextualPronunciationEvaluator: ContextualPronunciationBatchEvaluator,
        neuralEvaluator: NeuralEvaluator?
    ) async throws -> NarrationRenderPlan {
        try Task.checkCancellation()
        #if DEBUG
            let isMain = Self.debugIsMainThread()
            debugRenderPlanningRanOnMainThread.withLock { $0 = isMain }
        #endif
        let discoveryBlocks = try preparedBlocks.map { prepared in
            var block = prepared.block
            let userText = overrides.explicitUserEntries.apply(to: block.text ?? "")
            block.text = try EPUBPronunciationRewriter.rewrite(userText, block: block).text
            return block
        }
        let contextualOccurrences = ContextualPronunciationDiscovery.discover(
            blocks: discoveryBlocks, overrides: overrides)
        let contextualEvidence = try await ContextualPronunciationPreflight.run(
            occurrences: contextualOccurrences,
            evaluator: contextualPronunciationEvaluator,
            environment: FoundationModelsContextualPronunciationEvaluator.runtime)
        let contextualEvidenceByKey = try Self.contextualEvidenceByKey(
            contextualEvidence,
            occurrences: contextualOccurrences)
        try Task.checkCancellation()
        let deterministicPlan = try NarrationRenderPlanner.make(
            preparedBlocks: preparedBlocks,
            overrides: overrides,
            pronunciationPack: pronunciationPack,
            pronunciationAuditPack: pronunciationAuditPack,
            contextualEvidence: contextualEvidenceByKey,
            requiresContextualEvidence: true)
        guard let neuralEvaluator else { return deterministicPlan }
        try Task.checkCancellation()
        return try await NarrationPronunciationPreflight.applyingNeuralShadow(
            to: deterministicPlan,
            evaluator: neuralEvaluator)
    }

    private nonisolated static func contextualEvidenceByKey(
        _ evidence: [ContextualPronunciationEvidence],
        occurrences: [ContextualPronunciationOccurrence]
    ) throws -> [ContextualPronunciationKey: ContextualPronunciationEvidence] {
        var occurrencesByID: [String: ContextualPronunciationOccurrence] = [:]
        occurrencesByID.reserveCapacity(occurrences.count)
        for occurrence in occurrences {
            guard
                occurrencesByID.updateValue(
                    occurrence,
                    forKey: occurrence.occurrenceID) == nil
            else {
                throw NarrationRenderPlanError.contextualEvidenceIdentityMismatch
            }
        }

        guard evidence.count == occurrencesByID.count else {
            throw NarrationRenderPlanError.contextualEvidenceIdentityMismatch
        }
        var evidenceByKey: [ContextualPronunciationKey: ContextualPronunciationEvidence] = [:]
        evidenceByKey.reserveCapacity(evidence.count)
        for envelope in evidence {
            guard
                let occurrence = occurrencesByID.removeValue(
                    forKey: envelope.occurrenceID),
                ContextualPronunciationEvidenceValidator.isValidPhaseTwo(
                    envelope,
                    for: occurrence)
            else {
                throw NarrationRenderPlanError.contextualEvidenceIdentityMismatch
            }
            let key = ContextualPronunciationKey(
                blockID: occurrence.blockID,
                wordStart: occurrence.wordStart,
                wordEnd: occurrence.wordEnd)
            guard evidenceByKey.updateValue(envelope, forKey: key) == nil else {
                throw NarrationRenderPlanError.contextualEvidenceIdentityMismatch
            }
        }
        guard occurrencesByID.isEmpty else {
            throw NarrationRenderPlanError.contextualEvidenceIdentityMismatch
        }
        return evidenceByKey
    }

    private func prepareBlocksForRenderPlan(
        _ blocks: [EPubBlockRecord],
        occurrenceOverrides: PronunciationOccurrenceOverrides,
        fmEnabled: Bool
    ) async -> [NarrationPreparedBlock] {
        let normalizedByID = await Self.normalizeBlocksOffMain(blocks)
        var prepared: [NarrationPreparedBlock] = []
        prepared.reserveCapacity(blocks.count)

        for block in blocks {
            guard block.text?.isEmpty == false, !block.isHidden else {
                prepared.append(
                    NarrationPreparedBlock(block: block, pronunciationDecisionSeeds: []))
                continue
            }

            // Code blocks speak their short cue, never the code — skip
            // TextNormalizer/FM/occurrence overrides entirely.
            if let cueText = NarrationCodeBlockCue.spokenText(for: block) {
                var preparedBlock = block
                preparedBlock.text = cueText
                prepared.append(
                    NarrationPreparedBlock(block: preparedBlock, pronunciationDecisionSeeds: []))
                continue
            }

            let normalized =
                normalizedByID[block.id]
                ?? (block.pronunciationAnnotations == nil
                    ? TextNormalizer.normalize(block.text ?? "") : (block.text ?? ""))
            let refined =
                fmEnabled && block.pronunciationAnnotations == nil
                ? await FMNormalizer.refine(normalized, cache: fmCache) : normalized
            if refined != normalized {
                do {
                    try await db.write { db in
                        try db.execute(
                            sql: "UPDATE epub_block SET narration_text = ? WHERE id = ?",
                            arguments: [refined, block.id])
                    }
                } catch {
                    logger.error(
                        "Failed to persist FM-refined text for block \(block.id): \(error.localizedDescription)"
                    )
                }
            }

            let occurrenceResult = occurrenceOverrides.rewrite(
                to: refined,
                blockID: block.id)
            var preparedBlock = block
            preparedBlock.text = occurrenceResult.text
            preparedBlock.narrationText = refined == normalized ? block.narrationText : refined
            prepared.append(
                NarrationPreparedBlock(
                    block: preparedBlock,
                    pronunciationDecisionSeeds: occurrenceResult.decisionSeeds))
        }

        return prepared
    }

    private struct PlannedSynthesisOutput {
        let plan: PlannedSynthesisChunk
        let audio: TTSChunk
    }

    /// Stable source identity for one chunk from the immutable render plan.
    /// Retry children never replace this identity; they only provide audio for it.
    private struct OriginalSynthesisChunkIdentity {
        let blockID: String
        let chunkIndex: Int
        let wordBase: Int
        let wordCount: Int

        var wordRange: Range<Int> {
            wordBase..<(wordBase + wordCount)
        }
    }

    private struct RenderedSynthesisChild {
        let plan: PlannedSynthesisChunk
        let audio: TTSChunk
        let startInFile: TimeInterval
    }

    private struct RenderedOriginalSynthesisChunk {
        let identity: OriginalSynthesisChunkIdentity
        /// Parent-local word index to chapter-relative range. Empty means the
        /// original span rendered, but strict child timing identity was not proven.
        let exactWordRanges: [Int: PronunciationAuditDecision.AudioRange]
    }

    private struct BlockWordIdentity: Hashable {
        let blockID: String
        let wordIndex: Int
    }

    /// Validates timing against planned words, not emitted timing count. Retry
    /// children must reconstruct the parent's token sequence exactly before any
    /// timing can be called source-word precise.
    private static func exactWordRanges(
        parent: PlannedSynthesisChunk,
        children: [RenderedSynthesisChild]
    ) -> [Int: PronunciationAuditDecision.AudioRange]? {
        guard !children.isEmpty, parent.wordCount > 0 else { return nil }
        let parentWords = WordTokenizer.words(in: parent.displayText).map(String.init)
        guard parentWords.count == parent.wordCount else { return nil }

        var reconstructedWords: [String] = []
        reconstructedWords.reserveCapacity(parent.wordCount)
        var ranges: [Int: PronunciationAuditDecision.AudioRange] = [:]
        ranges.reserveCapacity(parent.wordCount)
        var childWordBase = 0

        for child in children {
            let childWords = WordTokenizer.words(in: child.plan.displayText).map(String.init)
            guard child.plan.wordCount > 0, childWords.count == child.plan.wordCount,
                child.audio.duration.isFinite, child.audio.duration > 0,
                child.startInFile.isFinite, child.startInFile >= 0,
                let timings = child.audio.wordTimings,
                timings.count == child.plan.wordCount
            else {
                return nil
            }

            reconstructedWords.append(contentsOf: childWords)
            for expectedIndex in 0..<child.plan.wordCount {
                let timing = timings[expectedIndex]
                guard timing.wordIndex == expectedIndex,
                    timing.start.isFinite, timing.end.isFinite,
                    timing.start >= 0, timing.end > timing.start,
                    timing.end <= child.audio.duration
                else {
                    return nil
                }

                let parentLocalWordIndex = childWordBase + expectedIndex
                guard ranges[parentLocalWordIndex] == nil else { return nil }
                let start = child.startInFile + timing.start
                let end = child.startInFile + timing.end
                guard start.isFinite, end.isFinite, start >= 0, end > start else {
                    return nil
                }
                ranges[parentLocalWordIndex] = PronunciationAuditDecision.AudioRange(
                    start: start,
                    end: end)
            }
            // Never trust the emitted timing count as source identity.
            childWordBase += child.plan.wordCount
        }

        guard reconstructedWords == parentWords,
            childWordBase == parent.wordCount,
            ranges.count == parent.wordCount
        else {
            return nil
        }
        return ranges
    }

    private static func renderedPronunciationDecisions(
        plan: NarrationRenderPlan,
        chapterIndex: Int,
        renderedFileDuration: TimeInterval,
        anchors: [AlignmentAnchorRecord],
        renderedOriginalChunks: [RenderedOriginalSynthesisChunk]
    ) -> [PronunciationAuditDecision] {
        var renderedSpansByBlock: [String: [Range<Int>]] = [:]
        var exactRangesByWord: [BlockWordIdentity: [PronunciationAuditDecision.AudioRange]] =
            [:]
        for rendered in renderedOriginalChunks {
            let identity = rendered.identity
            renderedSpansByBlock[identity.blockID, default: []].append(identity.wordRange)
            for (parentLocalWordIndex, range) in rendered.exactWordRanges {
                guard
                    let validatedRange = validatedReceiptRange(
                        range,
                        renderedFileDuration: renderedFileDuration)
                else {
                    continue
                }
                let key = BlockWordIdentity(
                    blockID: identity.blockID,
                    wordIndex: identity.wordBase + parentLocalWordIndex)
                exactRangesByWord[key, default: []].append(validatedRange)
            }
        }

        var positiveAnchorsByBlock: [String: PronunciationAuditDecision.AudioRange] = [:]
        for anchor in anchors {
            guard let end = anchor.audioEndTime else {
                continue
            }
            let range = PronunciationAuditDecision.AudioRange(
                start: anchor.audioTime,
                end: end)
            guard
                let validatedRange = validatedReceiptRange(
                    range,
                    renderedFileDuration: renderedFileDuration)
            else {
                continue
            }
            positiveAnchorsByBlock[anchor.epubBlockID] =
                validatedRange
        }

        return plan.blocks.flatMap { plannedBlock in
            plannedBlock.pronunciationDecisions.map { decision in
                guard !decision.isEvidenceOnlyInvalidOutputAdvisory else {
                    return decision.attachingRenderTiming(
                        chapterIndex: chapterIndex,
                        chapterRelativeAudioRange: nil,
                        timingPrecision: nil)
                }
                let spans = renderedSpansByBlock[decision.blockID] ?? []
                guard decision.wordStart >= 0, decision.wordEnd >= decision.wordStart,
                    (decision.wordStart...decision.wordEnd).allSatisfy({ wordIndex in
                        spans.contains { $0.contains(wordIndex) }
                    })
                else {
                    return decision.attachingRenderTiming(
                        chapterIndex: chapterIndex,
                        chapterRelativeAudioRange: nil,
                        timingPrecision: nil)
                }

                if decision.wordStart == decision.wordEnd {
                    let exactRanges =
                        exactRangesByWord[
                            BlockWordIdentity(
                                blockID: decision.blockID,
                                wordIndex: decision.wordStart)
                        ] ?? []
                    if exactRanges.count == 1, let exactRange = exactRanges.first {
                        return decision.attachingRenderTiming(
                            chapterIndex: chapterIndex,
                            chapterRelativeAudioRange: exactRange,
                            timingPrecision: .exactSynthesisWord)
                    }
                }

                guard let blockRange = positiveAnchorsByBlock[decision.blockID] else {
                    return decision.attachingRenderTiming(
                        chapterIndex: chapterIndex,
                        chapterRelativeAudioRange: nil,
                        timingPrecision: nil)
                }
                return decision.attachingRenderTiming(
                    chapterIndex: chapterIndex,
                    chapterRelativeAudioRange: blockRange,
                    timingPrecision: .blockAnchorFallback)
            }
        }
    }

    private static func validatedReceiptRange(
        _ range: PronunciationAuditDecision.AudioRange,
        renderedFileDuration: TimeInterval
    ) -> PronunciationAuditDecision.AudioRange? {
        guard renderedFileDuration.isFinite, renderedFileDuration >= 0,
            range.start.isFinite, range.end.isFinite,
            range.start >= 0, range.end > range.start
        else {
            return nil
        }

        // The writer and anchor cursor sum the same chunk durations in slightly
        // different groupings. Clamp only sub-microsecond rounding drift; a
        // material overshoot means the timing cannot describe the finalized file.
        let finalizationTolerance = 1e-6
        guard range.end <= renderedFileDuration + finalizationTolerance else {
            return nil
        }
        let end = min(range.end, renderedFileDuration)
        guard end > range.start else { return nil }
        return PronunciationAuditDecision.AudioRange(start: range.start, end: end)
    }

    private struct QualityRetryResult {
        let chunks: [PlannedSynthesisOutput]
        let allAccepted: Bool
    }

    private func synthesizeWithQualityRetry(
        _ plan: PlannedSynthesisChunk,
        voice: VoiceID
    ) async throws -> QualityRetryResult {
        let first = try await synthesize(plan, voice: voice)
        guard
            case .rejected(let reason) = NarrationChunkQuality.evaluate(
                first.audio,
                text: plan.displayText)
        else {
            return QualityRetryResult(chunks: [first], allAccepted: true)
        }

        return try await recoverRejectedSynthesis(
            first,
            fallback: first,
            reason: reason,
            voice: voice,
            retryDepth: 0)
    }

    private func synthesize(
        _ plan: PlannedSynthesisChunk,
        voice: VoiceID
    ) async throws -> PlannedSynthesisOutput {
        try Task.checkCancellation()
        return PlannedSynthesisOutput(
            plan: plan,
            audio: try await tts.synthesize(plan, voice: voice))
    }

    private func recoverRejectedSynthesis(
        _ rejected: PlannedSynthesisOutput,
        fallback: PlannedSynthesisOutput,
        reason: NarrationChunkQuality.RejectionReason,
        voice: VoiceID,
        retryDepth: Int
    ) async throws -> QualityRetryResult {
        guard retryDepth < Self.maximumQualityRetryDepth else {
            #if DEBUG
                debugRetryDepthCapHits += 1
            #endif
            logger.error(
                "Low-quality narration retry reached the bounded retry depth; publishing the original chunk with incomplete evidence: \(String(describing: reason), privacy: .public)"
            )
            return QualityRetryResult(chunks: [fallback], allAccepted: false)
        }

        let retryMaxPhonemes = max(20, min(80, rejected.plan.phonemes.count / 2))
        let retryPlans = rejected.plan.frozenRetrySlices(maxPhonemes: retryMaxPhonemes)
        guard retryPlans.count > 1 else {
            logger.warning(
                "Retrying low-quality atomic narration chunk with its frozen plan: \(String(describing: reason), privacy: .public)"
            )
            let retry: PlannedSynthesisOutput
            do {
                retry = try await synthesize(rejected.plan, voice: voice)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                logger.error(
                    "Low-quality atomic narration retry failed; publishing the original chunk with incomplete evidence: \(error.localizedDescription)"
                )
                return QualityRetryResult(chunks: [fallback], allAccepted: false)
            }
            switch NarrationChunkQuality.evaluate(
                retry.audio,
                text: retry.plan.displayText
            ) {
            case .acceptable:
                return QualityRetryResult(chunks: [retry], allAccepted: true)
            case .rejected(let retryReason):
                return try await recoverRejectedSynthesis(
                    retry,
                    fallback: fallback,
                    reason: retryReason,
                    voice: voice,
                    retryDepth: retryDepth + 1)
            }
        }

        logger.warning(
            "Retrying low-quality narration chunk as \(retryPlans.count, privacy: .public) frozen piece(s): \(String(describing: reason), privacy: .public)"
        )
        var retryChunks: [PlannedSynthesisOutput] = []
        retryChunks.reserveCapacity(retryPlans.count)
        for retryPlan in retryPlans {
            try Task.checkCancellation()
            let retry: PlannedSynthesisOutput
            do {
                retry = try await synthesize(retryPlan, voice: voice)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                logger.error(
                    "Low-quality narration retry piece failed; publishing the original chunk with incomplete evidence: \(error.localizedDescription)"
                )
                return QualityRetryResult(chunks: [fallback], allAccepted: false)
            }
            switch NarrationChunkQuality.evaluate(retry.audio, text: retryPlan.displayText) {
            case .acceptable:
                retryChunks.append(retry)
            case .rejected(let retryReason):
                let recovered = try await recoverRejectedSynthesis(
                    retry,
                    fallback: fallback,
                    reason: retryReason,
                    voice: voice,
                    retryDepth: retryDepth + 1)
                guard recovered.allAccepted else { return recovered }
                retryChunks.append(contentsOf: recovered.chunks)
            }
        }

        guard !retryChunks.isEmpty else {
            return QualityRetryResult(chunks: [fallback], allAccepted: false)
        }
        return QualityRetryResult(chunks: retryChunks, allAccepted: true)
    }

    #if DEBUG && os(iOS)
        /// One-tap on-device smoke test: render the first 3 paragraphs of the
        /// loaded book's chapter 1 with the real Kokoro engine and play them.
        /// Returns an `AVAudioPlayer` so the caller can keep a reference alive.
        @discardableResult
        static func testRenderAndPlayChapterOne(
            databaseWriter: DatabaseWriter,
            audiobookID: String
        ) async throws -> AVAudioPlayer {
            let logger = Logger(category: "NarrationTest")
            var texts: [String] = []
            texts =
                (try? EPubBlockDAO(db: databaseWriter)
                    .blocks(for: audiobookID, chapterIndex: 0)
                    .compactMap { $0.text }
                    .filter { !$0.isEmpty }) ?? []

            if texts.isEmpty {
                logger.info("No EPUB blocks loaded — narrating a sample paragraph instead.")
                texts = [
                    "Alice was beginning to get very tired of sitting by her sister on the bank, and of having nothing to do.",
                    "Once or twice she had peeped into the book her sister was reading, but it had no pictures or conversations in it.",
                    "And what is the use of a book, thought Alice, without pictures or conversations?",
                ]
            }
            let snippet = Array(texts.prefix(3))

            logger.info("Preparing narration engine via factory (honors the DEBUG ONNX toggle)…")
            let engine = NarrationEngineFactory.make()
            var chunks: [TTSChunk] = []
            for text in snippet {
                // Chunk before synthesize, mirroring NarrationService.renderChapter:
                // bound every synthesize call under Kokoro's ~510-phoneme context
                // (see NarrationTextChunker for the budget rationale).
                for subText in NarrationTextChunker.split(TextNormalizer.normalize(text)) {
                    chunks.append(
                        try await engine.synthesize(subText, voice: VoiceID("af_heart")))
                }
            }

            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("narration-test.m4a")
            try? FileManager.default.removeItem(at: url)
            _ = try await AVFoundationAudioWriter().write(chunks, to: url)

            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
            try AVAudioSession.sharedInstance().setActive(true)
            let player = try AVAudioPlayer(contentsOf: url)
            player.play()
            logger.info("Playing \(chunks.count) blocks.")
            return player
        }
    #endif

    /// True for an error that means a single sub-chunk overran the model's input
    /// length cap, so the caller should skip it rather than abort the chapter.
    /// The ONNX engine usually signals this via `NarrationError.lengthCapExceeded`.
    /// Some malformed long fragments surface directly from ONNX Runtime as an
    /// Expand-node shape error; treat that the same way so one bad fragment does
    /// not discard an otherwise rendered chapter.
    private static func isLengthCapError(_ error: Error) -> Bool {
        if case NarrationError.lengthCapExceeded = error { return true }
        let nsError = error as NSError
        let message =
            "\(nsError.domain) \(nsError.localizedDescription) \(String(describing: error))"
        if message.localizedCaseInsensitiveContains("invalid expand shape") {
            return true
        }
        return false
    }
}
