// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB
import Synchronization
import Testing

@testable import Echo

extension NarrationService {
    /// Keeps unrelated legacy tests focused on their own behavior while production
    /// callers must provide the block-voice selection closure.
    @discardableResult
    func renderChapter(
        chapterIndex: Int,
        sourceChapterKey: String? = nil,
        chapterNumber: Int? = nil,
        blocks: [EPubBlockRecord],
        voice: VoiceID,
        chapterTitle: String? = nil,
        onBlockProgress: (@MainActor (NarrationRenderProgress) -> Void)? = nil
    ) async throws -> RenderedNarrationFile {
        try await renderChapter(
            chapterIndex: chapterIndex,
            sourceChapterKey: sourceChapterKey,
            chapterNumber: chapterNumber,
            blocks: blocks,
            voice: voice,
            blockVoice: { _ in voice },
            chapterTitle: chapterTitle,
            onBlockProgress: onBlockProgress)
    }
}

private enum ShadowEvaluatorOutcome: Sendable {
    case selection(ContextualCandidateSlot)
    case unavailable
    case failure
}

private actor ShadowEvaluatorRecorder {
    private var targetWords: [String] = []

    func record(_ request: ContextualPronunciationBatchRequest) {
        targetWords.append(contentsOf: request.occurrences.map(\.targetWord))
    }

    func recordedTargetWords() -> [String] {
        targetWords
    }
}

@MainActor
@Suite struct NarrationServiceTests {

    private final class DeterministicWordTimingEngine: TTSEngine, @unchecked Sendable {
        private(set) var calls: [(text: String, voice: VoiceID)] = []

        func prepare() async throws {}

        func synthesize(_ text: String, voice: VoiceID) async throws -> TTSChunk {
            calls.append((text, voice))
            let duration = Double(text.count) * 0.1
            let wordCount = WordTokenizer.words(in: text).count
            let wordDuration = duration / Double(max(wordCount, 1))
            let timings = (0..<wordCount).map { index in
                ChunkWordTiming(
                    wordIndex: index,
                    start: Double(index) * wordDuration,
                    end: Double(index + 1) * wordDuration)
            }
            let samples = (0..<max(1, text.count)).map { index in
                index.isMultiple(of: 2) ? Float(0.05) : Float(-0.05)
            }
            return TTSChunk(
                samples: samples,
                sampleRate: 24_000,
                duration: duration,
                wordTimings: timings)
        }
    }

    enum SkippableRetryChildError: CaseIterable, Sendable {
        case lengthCap
        case invalidExpand

        func configure(_ engine: MockTTSEngine, on text: String) {
            switch self {
            case .lengthCap:
                engine.lengthCapOnText = text
            case .invalidExpand:
                engine.invalidExpandShapeOnText = text
            }
        }
    }

    private func blocks(_ audiobookID: String, _ texts: [String?]) -> [EPubBlockRecord] {
        texts.enumerated().map { i, t in
            block(audiobookID, id: "blk\(i)", seq: i, text: t)
        }
    }

    private func block(
        _ audiobookID: String,
        id: String,
        seq: Int,
        kind: String = "paragraph",
        text: String?,
        chapterIndex: Int = 0
    ) -> EPubBlockRecord {
        EPubBlockRecord(
            id: id, audiobookID: audiobookID, spineHref: "c.xhtml",
            spineIndex: 0, blockIndex: seq, sequenceIndex: seq,
            blockKind: kind, text: text, htmlContent: nil, cardColor: nil,
            chapterThemeColor: nil, imagePath: nil, chapterIndex: chapterIndex,
            isHidden: false, hiddenReason: nil, isFrontMatter: false,
            wordCount: nil, markers: nil, textFormats: nil,
            createdAt: nil, modifiedAt: nil)
    }

    /// Inserts the audiobook row plus the blocks (so `alignment_anchor`'s
    /// `epub_block_id` foreign key is satisfied) and returns the blocks.
    private func seed(_ db: DatabaseService, _ texts: [String?]) throws -> [EPubBlockRecord] {
        return try seed(db, records: blocks("b1", texts))
    }

    private func seed(
        _ db: DatabaseService,
        records: [EPubBlockRecord]
    ) throws -> [EPubBlockRecord] {
        try db.write { db in
            try db.execute(
                sql:
                    "INSERT INTO audiobook (id, title, duration, added_at) VALUES ('b1','Book',0,'2026-06-13T00:00:00Z')"
            )
        }
        try EPubBlockDAO(db: db.writer).insertAll(records)
        return records
    }

    private func makeService(_ db: DatabaseService, tts: TTSEngine, writer: AudioFileWriting)
        -> NarrationService
    {
        NarrationService(
            db: db.writer, audiobookID: "b1",
            tts: tts, audioWriter: writer,
            cacheDirectory: FileManager.default.temporaryDirectory,
            state: NarrationState(),
            fmEnabled: { false })
    }

    /// Overload that injects a pronunciation-override closure so the override→
    /// link-syntax rewrite can be exercised through the real render path.
    private func makeService(
        _ db: DatabaseService, tts: TTSEngine, writer: AudioFileWriting,
        overrides: @escaping () -> PronunciationOverrides
    ) -> NarrationService {
        makeService(
            db,
            tts: tts,
            writer: writer,
            overrides: overrides,
            occurrenceOverrides: { .empty })
    }

    private func makeService(
        _ db: DatabaseService,
        tts: TTSEngine,
        writer: AudioFileWriting,
        overrides: @escaping () -> PronunciationOverrides,
        occurrenceOverrides: @escaping () -> PronunciationOccurrenceOverrides
    ) -> NarrationService {
        NarrationService(
            db: db.writer, audiobookID: "b1",
            tts: tts, audioWriter: writer,
            cacheDirectory: FileManager.default.temporaryDirectory,
            state: NarrationState(),
            pronunciationOverrides: overrides,
            pronunciationOccurrenceOverrides: occurrenceOverrides,
            fmEnabled: { false })
    }

    /// Counts non-overlapping occurrences of `needle` across every synthesized
    /// sub-chunk — robust to however the chunker groups the rewritten text.
    private func linkOccurrences(_ calls: [(text: String, voice: VoiceID)], _ needle: String)
        -> Int
    {
        calls.reduce(0) { $0 + $1.text.components(separatedBy: needle).count - 1 }
    }

    @Test func writesOneTrackPerChapterWithVoiceAndDuration() async throws {
        let db = try DatabaseService(inMemory: ())
        let blocks = try seed(db, ["abcd", "ef"])
        let svc = makeService(
            db, tts: MockTTSEngine(secondsPerChar: 0.1), writer: MockAudioWriter())

        try await svc.renderChapter(
            chapterIndex: 0, blocks: blocks,
            voice: VoiceID("af_warm"))

        let track = try db.read { db in
            try TrackRecord.filter(Column("audiobook_id") == "b1").fetchOne(db)
        }
        #expect(track?.sortOrder == 0)
        // (4+2)×0.1 spoken + a paragraph pause + the chapter lead-out pad.
        let expectedDuration =
            0.6 + NarrationPlannedSilence.paragraph.duration
            + NarrationService.leadOutPadSeconds
        #expect(track.map { abs($0.duration - expectedDuration) < 0.0001 } == true)
        // Direct column check — proves narration_voice mapping:
        let voiceCol = try db.read { db in
            try String.fetchOne(
                db, sql: "SELECT narration_voice FROM track WHERE audiobook_id = 'b1'")
        }
        #expect(voiceCol == "af_warm")
    }

    @Test func renderChapterPersistsDerivedChapterTitle() async throws {
        let db = try DatabaseService(inMemory: ())
        let records = [
            block("b1", id: "h0", seq: 0, kind: "heading", text: "Chapter 1: A Door Opens"),
            block("b1", id: "blk0", seq: 1, text: "abcd"),
        ]
        let blocks = try seed(db, records: records)
        let svc = makeService(
            db, tts: MockTTSEngine(secondsPerChar: 0.1), writer: MockAudioWriter())

        try await svc.renderChapter(
            chapterIndex: 0,
            chapterNumber: 1,
            blocks: blocks,
            voice: VoiceID("af_warm"))

        let title = try db.read { db in
            try String.fetchOne(
                db, sql: "SELECT title FROM track WHERE audiobook_id = 'b1'")
        }
        #expect(title == "ch. 1: A Door Opens")
    }

    @Test func writesSynthesizedAnchorPerTextBlockInOrder() async throws {
        let db = try DatabaseService(inMemory: ())
        let blocks = try seed(db, ["abcd", "ef"])
        let svc = makeService(
            db, tts: MockTTSEngine(secondsPerChar: 0.1), writer: MockAudioWriter())
        try await svc.renderChapter(
            chapterIndex: 0, blocks: blocks,
            voice: VoiceID("af_warm"))
        let anchors = try db.read { db in
            try AlignmentAnchorRecord.filter(Column("audiobook_id") == "b1")
                .order(Column("audio_time")).fetchAll(db)
        }
        #expect(anchors.count == 2)
        #expect(anchors.allSatisfy { $0.source == "synthesized" })
        #expect(anchors[0].epubBlockID == "blk0")
        #expect(abs(anchors[0].audioTime - 0.0) < 0.0001)
        #expect(
            abs(anchors[1].audioTime - (0.4 + NarrationPlannedSilence.paragraph.duration))
                < 0.0001)
    }

    /// A block voice is selected once before that original block's chunks are
    /// synthesized. This catches resolving inside the chunk loop (or falling
    /// back to the chapter voice) without changing the established anchor and
    /// timing semantics.
    @Test func renderChapterUsesOneSelectedVoiceForEveryChunkOfEachOriginalBlock()
        async throws
    {
        let db = try DatabaseService(inMemory: ())
        let firstBlockText =
            String(repeating: "alpha ", count: 50) + ". "
            + String(repeating: "bravo ", count: 50) + "."
        let blocks = try seed(
            db,
            records: [
                block("b1", id: "s0-b0", seq: 0, text: firstBlockText),
                block("b1", id: "s0-b1", seq: 1, text: "Charlie arrives."),
            ])
        let engine = DeterministicWordTimingEngine()
        let service = makeService(db, tts: engine, writer: MockAudioWriter())
        let selections = Mutex<[String: Int]>([:])

        let rendered = try await service.renderChapter(
            chapterIndex: 0,
            blocks: blocks,
            voice: VoiceID("af_heart"),
            blockVoice: { blockID in
                selections.withLock { counts in counts[blockID, default: 0] += 1 }
                return blockID == "s0-b0" ? VoiceID("am_michael") : VoiceID("bf_emma")
            })

        #expect(
            engine.calls.map(\.voice) == [
                VoiceID("am_michael"), VoiceID("am_michael"), VoiceID("bf_emma"),
            ])
        #expect(selections.withLock { $0 } == ["s0-b0": 1, "s0-b1": 1])
        #expect(rendered.anchors.map(\.epubBlockID) == ["s0-b0", "s0-b1"])
        #expect(rendered.anchors.allSatisfy { ($0.audioEndTime ?? $0.audioTime) > $0.audioTime })
        #expect(
            zip(rendered.anchors, rendered.anchors.dropFirst()).allSatisfy {
                ($0.audioEndTime ?? $0.audioTime) <= $1.audioTime
            })

        let words = try WordTimingDAO(db: db.writer).words(forAudiobook: "b1")
        let firstBlockWords = try WordTimingDAO(db: db.writer).words(
            forAudiobook: "b1", blockID: "s0-b0")
        let secondBlockWords = try WordTimingDAO(db: db.writer).words(
            forAudiobook: "b1", blockID: "s0-b1")
        #expect(firstBlockWords.count == WordTokenizer.words(in: firstBlockText).count)
        #expect(secondBlockWords.count == 2)
        #expect(words.count == firstBlockWords.count + secondBlockWords.count)
        #expect(words.map(\.source).allSatisfy { $0 == "synthesis" })
        #expect(words.map(\.epubBlockID).allSatisfy { $0 == "s0-b0" || $0 == "s0-b1" })
        #expect(
            zip(words, words.dropFirst()).allSatisfy {
                $0.audioStartTime <= $0.audioEndTime && $0.audioEndTime <= $1.audioStartTime
            })
        #expect(
            (try #require(firstBlockWords.last)).audioEndTime
                <= (try #require(secondBlockWords.first)).audioStartTime)
    }

    @Test func plannedParagraphPauseAdvancesNextAnchorWithoutStretchingPreviousAnchor()
        async throws
    {
        let db = try DatabaseService(inMemory: ())
        let blocks = try seed(db, ["abcd", "ef"])
        let svc = makeService(
            db, tts: MockTTSEngine(secondsPerChar: 0.1), writer: MockAudioWriter())

        try await svc.renderChapter(
            chapterIndex: 0, blocks: blocks, voice: VoiceID("af_warm"))

        let anchors = try db.read { db in
            try AlignmentAnchorRecord.filter(Column("audiobook_id") == "b1")
                .order(Column("audio_time")).fetchAll(db)
        }

        #expect(anchors.count == 2)
        #expect(abs(anchors[0].audioTime - 0.0) < 0.0001)
        #expect(abs((anchors[0].audioEndTime ?? -1) - 0.4) < 0.0001)
        #expect(
            abs(anchors[1].audioTime - (0.4 + NarrationPlannedSilence.paragraph.duration))
                < 0.0001)
        #expect(
            abs(
                (anchors[1].audioEndTime ?? -1)
                    - (0.6 + NarrationPlannedSilence.paragraph.duration)) < 0.0001)
    }

    @Test func decorativeSectionBreakCreatesSilenceButNoAnchor() async throws {
        let db = try DatabaseService(inMemory: ())
        let records = [
            block("b1", id: "blk0", seq: 0, text: "first"),
            block("b1", id: "sep", seq: 1, text: "* * *"),
            block("b1", id: "blk2", seq: 2, text: "next"),
        ]
        let blocks = try seed(db, records: records)
        let writer = MockAudioWriter()
        let svc = makeService(
            db, tts: MockTTSEngine(secondsPerChar: 0.1), writer: writer)

        try await svc.renderChapter(
            chapterIndex: 0, blocks: blocks, voice: VoiceID("af_warm"))

        let anchors = try db.read { db in
            try AlignmentAnchorRecord.filter(Column("audiobook_id") == "b1")
                .order(Column("audio_time")).fetchAll(db)
        }

        #expect(anchors.map(\.epubBlockID) == ["blk0", "blk2"])
        #expect(abs((anchors[0].audioEndTime ?? -1) - 0.5) < 0.0001)
        #expect(
            abs(anchors[1].audioTime - (0.5 + NarrationPlannedSilence.sectionBreak.duration))
                < 0.0001)
        #expect(writer.chunkCounts == [4])
    }

    /// Read-along write-side: rendering a chapter must propagate its synthesized
    /// anchors into `timeline_item` (via AlignmentService.recalculateTimeline),
    /// because that table — not `alignment_anchor` — is what the reader queries
    /// (`WHERE audio_start_time >= 0`). Without the recalc the reader shows no
    /// timestamps and never highlights. Asserts the exact read-side predicate.
    @Test func renderChapterPopulatesTimelineItemForReadAlong() async throws {
        let db = try DatabaseService(inMemory: ())
        let blocks = try seed(db, ["abcd", "ef"])
        let svc = makeService(
            db, tts: MockTTSEngine(secondsPerChar: 0.1), writer: MockAudioWriter())

        try await svc.renderChapter(
            chapterIndex: 0, blocks: blocks,
            voice: VoiceID("af_warm"))

        // Mirror ReaderFeedViewModel.reload()'s exact predicate.
        let rows = try db.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT epub_block_id, audio_start_time FROM timeline_item
                    WHERE audiobook_id = 'b1'
                      AND epub_block_id IS NOT NULL
                      AND audio_start_time >= 0
                    ORDER BY audio_start_time
                    """)
        }
        // One timeline_item per rendered block, each with a non-negative start.
        #expect(rows.count == 2)
        let blockIDs = rows.compactMap { $0["epub_block_id"] as String? }
        #expect(blockIDs == ["blk0", "blk1"])
        let starts = rows.compactMap { $0["audio_start_time"] as Double? }
        #expect(starts.allSatisfy { $0 >= 0 })
        // Per-chapter 0-based: the first block starts at 0, matching its anchor.
        #expect(abs((starts.first ?? -1) - 0.0) < 0.0001)
    }

    @Test func synthesizedWordTimingUsesSpeechRangesNotPauseGaps() async throws {
        let db = try DatabaseService(inMemory: ())
        let blocks = try seed(db, ["First words.", "* * *", "Second words."])
        let svc = makeService(
            db, tts: MockTTSEngine(secondsPerChar: 0.1), writer: MockAudioWriter())

        try await svc.renderChapter(chapterIndex: 0, blocks: blocks, voice: VoiceID("af_heart"))

        let firstRows = try WordTimingDAO(db: db.writer).words(forAudiobook: "b1", blockID: "blk0")
        let secondRows = try WordTimingDAO(db: db.writer).words(forAudiobook: "b1", blockID: "blk2")
        let firstEnd = try #require(firstRows.map(\.audioEndTime).max())
        let secondStart = try #require(secondRows.map(\.audioStartTime).min())

        #expect(!firstRows.isEmpty)
        #expect(!secondRows.isEmpty)
        #expect(firstEnd < secondStart)
        #expect(firstRows.map(\.source).allSatisfy { $0 == "synthesized" })
    }

    @Test func renderSegmentFileWritesSegmentCacheWithoutPersistingPlaybackState() async throws {
        let db = try DatabaseService(inMemory: ())
        let blocks = try seed(db, ["first", "second", "third"])
        let writer = MockAudioWriter()
        let svc = makeService(
            db, tts: MockTTSEngine(secondsPerChar: 0.1), writer: writer)
        let now = Date(timeIntervalSince1970: 100)
        let activity = NarrationRenderActivity.rendering(
            NarrationRenderUnitStatus(
                chapterDisplayNumber: 7,
                segmentIndex: 1,
                voiceID: VoiceID("af_heart"),
                completedBlocks: 2,
                totalBlocks: 5,
                startedAt: now,
                lastProgressAt: now))
        svc.state.transitionRender(to: activity, event: nil)

        let rendered = try await svc.renderSegmentFile(
            chapterIndex: 0,
            chapterDisplayNumber: 1,
            segmentIndex: 2,
            blocks: Array(blocks[1...2]),
            voice: VoiceID("af_warm"))

        let expectedName = rendered.fileURL.lastPathComponent
        #expect(expectedName.contains("-ch0-s2-h"))
        #expect(expectedName.hasSuffix("-af_warm-v\(NarrationFileNaming.renderVersion).m4a"))
        #expect(
            writer.writtenURLs.map(\.lastPathComponent) == [partialCacheFileName(for: expectedName)]
        )
        #expect(rendered.chapterIndex == 0)
        #expect(rendered.chapterDisplayNumber == 1)
        #expect(rendered.segmentIndex == 2)

        let secondDuration = Double("second".count) * 0.1
        let expectedDuration =
            secondDuration + NarrationPlannedSilence.paragraph.duration
            + Double("third".count) * 0.1
        #expect(abs(rendered.duration - expectedDuration) < 0.0001)
        #expect(writer.chunkCounts == [3])
        #expect(rendered.anchors.map(\.epubBlockID) == ["blk1", "blk2"])
        #expect(abs(rendered.anchors[0].audioTime - 0.0) < 0.0001)
        #expect(
            abs(
                rendered.anchors[1].audioTime
                    - (secondDuration + NarrationPlannedSilence.paragraph.duration)) < 0.0001)

        let trackCount = try db.read { db in try TrackRecord.fetchCount(db) }
        let persistedAnchorCount = try db.read { db in
            try AlignmentAnchorRecord.filter(Column("audiobook_id") == "b1").fetchCount(db)
        }
        let alignedTimelineRows = try db.read { db in
            try Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*) FROM timeline_item
                    WHERE audiobook_id = 'b1' AND audio_start_time >= 0
                    """) ?? -1
        }
        #expect(trackCount == 0)
        #expect(persistedAnchorCount == 0)
        #expect(alignedTimelineRows == 0)
        #expect(svc.state.snapshot.render == activity)
    }

    @Test func renderChapterPublishesStructuredBlockProgressWithoutCompletingSession()
        async throws
    {
        let db = try DatabaseService(inMemory: ())
        let blocks = try seed(db, ["first", "second"])
        let svc = makeService(
            db, tts: MockTTSEngine(secondsPerChar: 0.1), writer: MockAudioWriter())

        _ = try await svc.renderChapter(
            chapterIndex: 0,
            blocks: blocks,
            voice: VoiceID("af_heart"))

        guard case .rendering(let unit) = svc.state.snapshot.render else {
            Issue.record("Expected structured render-unit progress after chapter rendering.")
            return
        }
        #expect(unit.chapterDisplayNumber == 1)
        #expect(unit.segmentIndex == nil)
        #expect(unit.voiceID == VoiceID("af_heart"))
        #expect(unit.completedBlocks == 2)
        #expect(unit.totalBlocks == 2)
        #expect(svc.state.phase == .preparingChapter)
    }

    @Test func renderSegmentFileCacheNameChangesWhenPronunciationOverrideChangesSpokenText()
        async throws
    {
        let plainDB = try DatabaseService(inMemory: ())
        let plainBlocks = try seed(plainDB, ["Deploying Kubernetes carefully."])
        let plainService = makeService(
            plainDB,
            tts: MockTTSEngine(secondsPerChar: 0.1),
            writer: MockAudioWriter())
        let plain = try await plainService.renderSegmentFile(
            chapterIndex: 0,
            chapterDisplayNumber: 1,
            segmentIndex: 0,
            blocks: plainBlocks,
            voice: VoiceID("af_heart"))

        let overrideDB = try DatabaseService(inMemory: ())
        let overrideBlocks = try seed(overrideDB, ["Deploying Kubernetes carefully."])
        let overrideService = makeService(
            overrideDB,
            tts: MockTTSEngine(secondsPerChar: 0.1),
            writer: MockAudioWriter()
        ) {
            PronunciationOverrides(entries: ["Kubernetes": "ku:bərnetis"])
        }
        let overridden = try await overrideService.renderSegmentFile(
            chapterIndex: 0,
            chapterDisplayNumber: 1,
            segmentIndex: 0,
            blocks: overrideBlocks,
            voice: VoiceID("af_heart"))

        #expect(plain.fileURL.lastPathComponent != overridden.fileURL.lastPathComponent)
        #expect(overridden.fileURL.lastPathComponent.contains("-h"))
    }

    @Test func chapterCacheNameChangesWhenFMNormalizationModeChanges() async throws {
        let db = try DatabaseService(inMemory: ())
        let blocks = try seed(db, ["Deploying Kubernetes carefully."])
        let deterministic = NarrationService(
            db: db.writer,
            audiobookID: "b1",
            tts: MockTTSEngine(),
            audioWriter: MockAudioWriter(),
            cacheDirectory: FileManager.default.temporaryDirectory,
            state: NarrationState(),
            fmEnabled: { false })
        let fmBacked = NarrationService(
            db: db.writer,
            audiobookID: "b1",
            tts: MockTTSEngine(),
            audioWriter: MockAudioWriter(),
            cacheDirectory: FileManager.default.temporaryDirectory,
            state: NarrationState(),
            fmEnabled: { true })

        let deterministicURL = await deterministic.chapterCacheURL(
            chapterIndex: 0,
            blocks: blocks,
            voice: VoiceID("af_heart"))
        let fmURL = await fmBacked.chapterCacheURL(
            chapterIndex: 0,
            blocks: blocks,
            voice: VoiceID("af_heart"))

        #expect(deterministicURL.lastPathComponent != fmURL.lastPathComponent)
    }

    @Test func serviceUsesOneInjectedPackForPlanAndCacheIdentity() async throws {
        let db = try DatabaseService(inMemory: ())
        let blocks = try seed(db, ["A foobar appeared."])
        let pack = EnglishPronunciationPack.emptyForTesting(
            packVersion:
                "sha256:0000000000000000000000000000000000000000000000000000000000000000",
            kokoroVocabularyVersion:
                "sha256:1111111111111111111111111111111111111111111111111111111111111111",
            automaticEntries: [
                "foobar": ("cmudict.foobar.fixture", "fˈubɑɹ")
            ])
        let service = NarrationService(
            db: db.writer,
            audiobookID: "b1",
            tts: MockTTSEngine(),
            audioWriter: MockAudioWriter(),
            cacheDirectory: FileManager.default.temporaryDirectory,
            state: NarrationState(),
            pronunciationPack: pack,
            fmEnabled: { false })

        let plan = try await service.renderPlan(
            for: blocks,
            overrides: PronunciationOverrides(entries: [:]),
            occurrenceOverrides: .empty,
            fmEnabled: false)
        let cacheURL = await service.chapterCacheURL(
            chapterIndex: 0,
            blocks: blocks,
            voice: VoiceID("af_heart"))
        let expectedSignature = NarrationService.contentSignature(
            for: blocks,
            includeLeadOutPad: true,
            overrides: PronunciationOverrides(entries: [:]),
            occurrenceOverrides: .empty,
            normalizationMode: "deterministic",
            pronunciationPack: pack)

        #expect(
            plan.blocks.first?.synthesisChunks.first?.g2pInputText
                == "A [foobar](/fˈubɑɹ/) appeared.")
        #expect(cacheURL.lastPathComponent.contains("-h\(expectedSignature)-"))
    }

    @Test func auditPackAddsAdvisoryEvidenceWithoutChangingPlanOrCacheIdentity() async throws {
        let db = try DatabaseService(inMemory: ())
        let blocks = try seed(db, ["Please record enough words."])
        let auditPack = await EnglishPronunciationAuditPack.bundledOrEmpty()
        let evaluator: ContextualPronunciationBatchEvaluator = { _ in
            ContextualPronunciationBatchResult(
                availability: .deviceNotEligible,
                selections: [],
                failure: nil,
                runtime: ContextualModelRuntime(
                    platform: "test",
                    osBuild: "test-build",
                    qualifiedRuntimeFamilyID: "test-runtime"))
        }
        func service(auditPack: EnglishPronunciationAuditPack) -> NarrationService {
            NarrationService(
                db: db.writer,
                audiobookID: "b1",
                tts: MockTTSEngine(),
                audioWriter: MockAudioWriter(),
                cacheDirectory: FileManager.default.temporaryDirectory,
                state: NarrationState(),
                pronunciationPack: .empty,
                pronunciationAuditPack: auditPack,
                contextualPronunciationEvaluator: evaluator,
                fmEnabled: { false })
        }

        let audited = service(auditPack: auditPack)
        let unaudited = service(auditPack: .empty)
        let auditedPlan = try await audited.renderPlan(
            for: blocks,
            overrides: PronunciationOverrides(entries: [:]),
            occurrenceOverrides: .empty,
            fmEnabled: false)
        let unauditedPlan = try await unaudited.renderPlan(
            for: blocks,
            overrides: PronunciationOverrides(entries: [:]),
            occurrenceOverrides: .empty,
            fmEnabled: false)
        let auditedDecision = try #require(
            auditedPlan.blocks.first?.pronunciationDecisions.first {
                $0.normalizedWord == "enough"
            })
        let selectedCandidateID = try #require(auditedDecision.candidateID)
        #expect(selectedCandidateID.hasPrefix("misaki.us.lexicon.v1.sha256:"))
        #expect(auditedDecision.source == .monitoredLexicon)
        #expect(
            auditedPlan.blocks.first?.synthesisChunks.map(\.phonemes)
                == unauditedPlan.blocks.first?.synthesisChunks.map(\.phonemes))
        #expect(auditedDecision.advisoryEvidence?.alternatives.isEmpty == false)

        _ = try await audited.renderChapter(
            chapterIndex: 0, blocks: blocks, voice: VoiceID("af_heart"))
        let persistedIssue = try #require(
            NarrationQualityIssueDAO(db: db.writer).issues(
                for: "b1", status: NarrationQAIssueStatus.open.rawValue
            ).first {
                $0.origin == NarrationQualityIssueOrigin.pronunciationPreflight.rawValue
                    && $0.expectedText == auditedDecision.sourceWord
            })
        let evidenceData = try #require(persistedIssue.evidenceJSON?.data(using: .utf8))
        let persistedEvidence = try JSONDecoder().decode(
            PronunciationAdvisoryIssueEvidence.self, from: evidenceData)
        #expect(persistedEvidence.advisoryEvidence == auditedDecision.advisoryEvidence)
        #expect(persistedEvidence.isValid())
        #expect(persistedEvidence.occurrenceCount == 1)
        #expect(persistedEvidence.advisoryEvidence.selectedCandidateID == selectedCandidateID)
        #expect(persistedEvidence.selectedCandidate?.candidateID == selectedCandidateID)
        #expect(persistedEvidence.selectedCandidate?.ipa == auditedDecision.selectedIPA)
        #expect(persistedEvidence.selectedCandidate?.source == .monitoredLexicon)
        #expect(persistedEvidence.selectedCandidate?.authority == .trusted)
        #expect(persistedEvidence.selectedCandidate?.validation == .eligible)
        let suggestedFix = try JSONDecoder().decode(
            SuggestedFix.self,
            from: try #require(persistedIssue.suggestedFixJSON?.data(using: .utf8)))
        #expect(suggestedFix.spokenForm == auditedDecision.sourceWord)
        #expect(suggestedFix.ipa == auditedDecision.selectedIPA)

        let auditedCacheURL = await audited.chapterCacheURL(
            chapterIndex: 0,
            blocks: blocks,
            voice: VoiceID("af_heart"))
        let unauditedCacheURL = await unaudited.chapterCacheURL(
            chapterIndex: 0,
            blocks: blocks,
            voice: VoiceID("af_heart"))

        #expect(auditedCacheURL == unauditedCacheURL)
    }

    @Test func neuralShadowOutcomesCannotChangeProductionCacheSignatureOrFileURL()
        async throws
    {
        enum InjectedFailure: Error { case inference }
        let db = try DatabaseService(inMemory: ())
        let sourceBlocks = try seed(db, ["Xyzqwf appears in this synthetic fixture."])
        let cacheDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true)
        let voice = VoiceID("af_heart")
        let candidate = NeuralG2PCandidate(
            candidateID:
                "sha256:aa7069d4801f3e5e6b7b2685b844cc249b3feec9d1c1ab5fc532959948344fbe",
            ipa: "zizkwf",
            modelRevision: MiniBARTG2PEngine.modelRevision,
            conversionPolicyVersion: ARPAbetToKokoroIPA.policyVersion,
            validationPolicyVersion: MiniBARTG2PEngine.validationPolicyVersion,
            selectionPolicyVersion: MiniBARTG2PEngine.selectionPolicyVersion)
        let evaluators: [NeuralEvaluator?] = [
            nil,
            { _ in .candidate(candidate) },
            { _ in .rejected(.unavailable) },
            { _ in throw InjectedFailure.inference },
        ]
        var plans: [NarrationRenderPlan] = []
        var signatures: [String] = []
        var cacheURLs: [URL] = []

        for evaluator in evaluators {
            let service = NarrationService(
                db: db.writer,
                audiobookID: "b1",
                tts: MockTTSEngine(),
                audioWriter: MockAudioWriter(),
                cacheDirectory: cacheDirectory,
                state: NarrationState(),
                neuralEvaluator: evaluator,
                fmEnabled: { false })
            plans.append(
                try await service.renderPlan(
                    for: sourceBlocks,
                    overrides: PronunciationOverrides(entries: [:]),
                    occurrenceOverrides: .empty,
                    fmEnabled: false))
            let signature = NarrationService.contentSignature(
                for: sourceBlocks,
                includeLeadOutPad: true,
                overrides: PronunciationOverrides(entries: [:]),
                occurrenceOverrides: .empty,
                normalizationMode: "deterministic",
                pronunciationPack: .empty)
            signatures.append(signature)
            let actualURL = await service.chapterCacheURL(
                chapterIndex: 0,
                blocks: sourceBlocks,
                voice: voice)
            let expectedURL = cacheDirectory.appendingPathComponent(
                NarrationFileNaming.chapterFileName(
                    audiobookID: "b1",
                    chapterIndex: 0,
                    voice: voice,
                    contentSignature: signature))
            #expect(actualURL == expectedURL)
            cacheURLs.append(actualURL)
        }

        let decisions = try plans.map { plan in
            try #require(
                plan.blocks.flatMap(\.pronunciationDecisions).first {
                    $0.normalizedWord == "xyzqwf"
                })
        }
        #expect(decisions.map(\.selectedIPA).allSatisfy { $0 == decisions[0].selectedIPA })
        #expect(decisions.map(\.kokoroTokenIDs).allSatisfy { $0 == decisions[0].kokoroTokenIDs })
        #expect(
            decisions.map { $0.advisoryEvidence?.selectionReason } == [
                .deterministicFallback,
                .shadowCandidate,
                .modelUnavailable,
                .modelInferenceFailure,
            ])
        #expect(decisions[1].advisoryEvidence?.alternatives.count == 1)
        #expect(decisions[0].advisoryEvidence != decisions[1].advisoryEvidence)
        #expect(decisions[1].advisoryEvidence != decisions[2].advisoryEvidence)
        #expect(decisions[2].advisoryEvidence != decisions[3].advisoryEvidence)
        #expect(plans[0] != plans[1])
        #expect(plans[1] != plans[2])
        #expect(plans[2] != plans[3])
        #expect(Set(signatures).count == 1)
        #expect(Set(cacheURLs).count == 1)
    }

    @Test func renderPlanSurfacesBoundedNeuralInstabilityWithoutChangingProductionAuthority()
        async throws
    {
        actor Sequence {
            private var invocation = 0

            func next(for word: String) -> NeuralG2PShadowResult {
                invocation += 1
                let ipa = invocation == 1 ? "zizkwf" : "zizkwəf"
                return .candidate(
                    NeuralG2PCandidate(
                        candidateID: NeuralG2PGovernedIdentity.candidateID(
                            normalizedWord: word,
                            ipa: ipa)!,
                        ipa: ipa,
                        modelRevision: NeuralG2PGovernedIdentity.modelRevision,
                        conversionPolicyVersion:
                            NeuralG2PGovernedIdentity.conversionPolicyVersion,
                        validationPolicyVersion:
                            NeuralG2PGovernedIdentity.validationPolicyVersion,
                        selectionPolicyVersion:
                            NeuralG2PGovernedIdentity.selectionPolicyVersion))
            }
        }

        let db = try DatabaseService(inMemory: ())
        let sourceBlocks = try seed(db, ["Xyzqwf appears in this synthetic fixture."])
        let deterministic = NarrationService(
            db: db.writer,
            audiobookID: "b1",
            tts: MockTTSEngine(),
            audioWriter: MockAudioWriter(),
            cacheDirectory: FileManager.default.temporaryDirectory,
            state: NarrationState(),
            neuralEvaluator: nil,
            fmEnabled: { false })
        let sequence = Sequence()
        let observed = NarrationService(
            db: db.writer,
            audiobookID: "b1",
            tts: MockTTSEngine(),
            audioWriter: MockAudioWriter(),
            cacheDirectory: FileManager.default.temporaryDirectory,
            state: NarrationState(),
            neuralEvaluator: { word in await sequence.next(for: word) },
            fmEnabled: { false })

        let deterministicPlan = try await deterministic.renderPlan(
            for: sourceBlocks,
            overrides: PronunciationOverrides(entries: [:]),
            occurrenceOverrides: .empty,
            fmEnabled: false)
        let observedPlan = try await observed.renderPlan(
            for: sourceBlocks,
            overrides: PronunciationOverrides(entries: [:]),
            occurrenceOverrides: .empty,
            fmEnabled: false)
        let baseline = try #require(
            deterministicPlan.blocks.flatMap(\.pronunciationDecisions).first {
                $0.normalizedWord == "xyzqwf"
            })
        let unstable = try #require(
            observedPlan.blocks.flatMap(\.pronunciationDecisions).first {
                $0.normalizedWord == "xyzqwf"
            })

        #expect(unstable.advisoryEvidence?.neuralShadowObservation == .unstableEvaluation)
        #expect(unstable.selectedIPA == baseline.selectedIPA)
        #expect(unstable.kokoroTokenIDs == baseline.kokoroTokenIDs)
        #expect(unstable.candidateID == baseline.candidateID)
        #expect(
            observedPlan.blocks.flatMap(\.synthesisChunks)
                == deterministicPlan.blocks.flatMap(\.synthesisChunks))
    }

    @Test func ordinaryRenderRecordsThatShadowInferenceWasNotRequested() async throws {
        let service = NarrationService(
            db: try DatabaseService(inMemory: ()).writer, audiobookID: "b1",
            tts: MockTTSEngine(), audioWriter: MockAudioWriter(),
            cacheDirectory: FileManager.default.temporaryDirectory, state: NarrationState(),
            fmEnabled: { false })
        let plan = try await service.renderPlan(
            for: [block("b1", id: "plain", seq: 0, text: "The content is useful.")],
            overrides: PronunciationOverrides(entries: [:]), occurrenceOverrides: .empty,
            fmEnabled: false)
        let evidence = try #require(
            plan.blocks.flatMap(\.pronunciationDecisions)
                .compactMap(\.contextualEvidence).first)
        #expect(NarrationService.debugRenderPlanningRanOnMainThread.withLock { $0 } == false)
        #expect(evidence.modelAvailability == .notRequested)
        #expect(evidence.acceptanceReason == .shadowNotRequested)
    }

    @Test func contextCrossesParagraphsWithoutChangingOccurrenceCoordinates() throws {
        let blocks = [
            block("b1", id: "before", seq: 0, text: "Yesterday we went to the library."),
            block("b1", id: "target", seq: 1, text: "I read the record."),
            block("b1", id: "after", seq: 2, text: "Then we went home."),
        ]
        let occurrences = ContextualPronunciationDiscovery.discover(
            blocks: blocks, overrides: PronunciationOverrides(entries: [:]))
        let target = try #require(occurrences.first { $0.targetWord == "read" })
        #expect(target.precedingSentence == blocks[0].text)
        #expect(target.followingSentence == blocks[2].text)
        #expect(target.wordStart == 1)
        #expect(target.targetSentenceWordIndex == 1)
        let local = try #require(
            ContextualPronunciationDiscovery.discover(
                text: blocks[1].text!, blockID: "target"
            ).first { $0.targetWord == "read" })
        #expect(local.occurrenceID == target.occurrenceID)
        var separated = blocks
        separated[0].isHidden = true
        separated[2].chapterIndex = 99
        let isolated = try #require(
            ContextualPronunciationDiscovery.discover(
                blocks: separated, overrides: PronunciationOverrides(entries: [:])
            )
            .first { $0.targetWord == "read" })
        #expect(isolated.precedingSentence == nil)
        #expect(isolated.followingSentence == nil)
    }

    @Test func contextualShadowOutcomesCannotChangeNarrationOrCacheIdentity() async throws {
        let sourceBlocks = [
            block(
                "b1",
                id: "shadow",
                seq: 0,
                text: "The content was live. I read the record.")
        ]
        let outcomes: [ShadowEvaluatorOutcome] = [
            .selection(.a),
            .selection(.b),
            .selection(.needsReview),
            .unavailable,
            .failure,
        ]
        var plans: [NarrationRenderPlan] = []
        var fileNames: [String] = []

        for outcome in outcomes {
            let db = try DatabaseService(inMemory: ())
            let service = NarrationService(
                db: db.writer,
                audiobookID: "b1",
                tts: MockTTSEngine(),
                audioWriter: MockAudioWriter(),
                cacheDirectory: FileManager.default.temporaryDirectory,
                state: NarrationState(),
                contextualPronunciationEvaluator: { request in
                    let runtime = ContextualModelRuntime(
                        platform: "test",
                        osBuild: "test-build",
                        qualifiedRuntimeFamilyID: "test-runtime")
                    switch outcome {
                    case .selection(let slot):
                        return ContextualPronunciationBatchResult(
                            availability: .available,
                            selections: request.occurrences.map {
                                ContextualModelSelection(
                                    occurrenceID: $0.occurrenceID,
                                    slot: slot)
                            },
                            failure: nil,
                            runtime: runtime)
                    case .unavailable:
                        return ContextualPronunciationBatchResult(
                            availability: .deviceNotEligible,
                            selections: [],
                            failure: nil,
                            runtime: runtime)
                    case .failure:
                        return ContextualPronunciationBatchResult(
                            availability: .available,
                            selections: [],
                            failure: .guardrail,
                            runtime: runtime)
                    }
                },
                fmEnabled: { false })
            plans.append(
                try await service.renderPlan(
                    for: sourceBlocks,
                    overrides: PronunciationOverrides(entries: [:]),
                    occurrenceOverrides: .empty,
                    fmEnabled: false))
            fileNames.append(
                await service.chapterCacheURL(
                    chapterIndex: 0,
                    blocks: sourceBlocks,
                    voice: VoiceID("af_heart")
                ).lastPathComponent)
        }

        let baseline = try #require(plans.first)
        for plan in plans.dropFirst() {
            #expect(
                plan.blocks.map(\.originalBlock.text) == baseline.blocks.map(\.originalBlock.text))
            #expect(plan.blocks.map(\.synthesisChunks) == baseline.blocks.map(\.synthesisChunks))
            #expect(
                productionDecisionFingerprints(plan)
                    == productionDecisionFingerprints(baseline))
        }
        #expect(Set(fileNames).count == 1)

        let evidence = plans.map {
            $0.blocks.flatMap(\.pronunciationDecisions).compactMap(\.contextualEvidence)
        }
        #expect(evidence.allSatisfy { $0.count == 4 })
        #expect(
            evidence[0].allSatisfy {
                $0.modelCandidateID?.hasSuffix(".material") == true
                    || $0.modelCandidateID?.hasSuffix(".adjective") == true
                    || $0.modelCandidateID?.hasSuffix(".present") == true
                    || $0.modelCandidateID?.hasSuffix(".noun") == true
            })
        #expect(evidence[0] != evidence[1])
        #expect(evidence[2].allSatisfy { $0.modelAbstained })
        #expect(evidence[3].allSatisfy { $0.modelAvailability == .deviceNotEligible })
        #expect(evidence[4].allSatisfy { $0.modelFailure == .guardrail })
    }

    @Test func overrideLayersAndUnspeakableBlocksAreExcludedFromShadowDiscovery() async throws {
        let recorder = ShadowEvaluatorRecorder()
        let service = NarrationService(
            db: try DatabaseService(inMemory: ()).writer,
            audiobookID: "b1",
            tts: MockTTSEngine(),
            audioWriter: MockAudioWriter(),
            cacheDirectory: FileManager.default.temporaryDirectory,
            state: NarrationState(),
            contextualPronunciationEvaluator: { request in
                await recorder.record(request)
                return ContextualPronunciationBatchResult(
                    availability: .available,
                    selections: request.occurrences.map {
                        ContextualModelSelection(
                            occurrenceID: $0.occurrenceID,
                            slot: .needsReview)
                    },
                    failure: nil,
                    runtime: ContextualModelRuntime(
                        platform: "test",
                        osBuild: "test-build",
                        qualifiedRuntimeFamilyID: "test-runtime"))
            },
            fmEnabled: { false })
        let occurrenceOverrides = PronunciationOccurrenceOverrides(entries: [
            PronunciationOccurrenceOverride(
                blockID: "prose",
                wordStart: 0,
                wordEnd: 0,
                word: "content",
                ipa: "kˈɑntɛnt")
        ])
        let global = PronunciationOverrides(
            entries: ["live": "lˈIv"],
            source: .globalOverride)
        let layered = PronunciationOverrides.merging(
            global: global,
            book: ["read": "ɹˈid"])
        let prose = block(
            "b1",
            id: "prose",
            seq: 0,
            text: "content live read record")
        let code = block(
            "b1",
            id: "code",
            seq: 1,
            kind: "code",
            text: "content live read record")
        let empty = block("b1", id: "empty", seq: 2, text: "")

        let plan = try await service.renderPlan(
            for: [prose, code, empty],
            overrides: layered,
            occurrenceOverrides: occurrenceOverrides,
            fmEnabled: false)

        #expect(await recorder.recordedTargetWords() == ["record"])
        #expect(
            plan.blocks.flatMap(\.pronunciationDecisions)
                .compactMap(\.contextualEvidence).map(\.familyID) == ["record"])
        #expect(plan.pronunciationAuditDiagnostics.isEmpty)
    }

    @Test func plainURLMonitoredComponentDoesNotCreateContextualEvidenceIdentityMismatch()
        async throws
    {
        let recorder = ShadowEvaluatorRecorder()
        let service = NarrationService(
            db: try DatabaseService(inMemory: ()).writer,
            audiobookID: "b1",
            tts: MockTTSEngine(),
            audioWriter: MockAudioWriter(),
            cacheDirectory: FileManager.default.temporaryDirectory,
            state: NarrationState(),
            contextualPronunciationEvaluator: { request in
                await recorder.record(request)
                return ContextualPronunciationBatchResult(
                    availability: .available,
                    selections: request.occurrences.map {
                        ContextualModelSelection(
                            occurrenceID: $0.occurrenceID,
                            slot: .needsReview)
                    },
                    failure: nil,
                    runtime: ContextualModelRuntime(
                        platform: "test",
                        osBuild: "test-build",
                        qualifiedRuntimeFamilyID: "test-runtime"))
            },
            fmEnabled: { false })
        let sourceBlock = block(
            "b1",
            id: "plain-url",
            seq: 0,
            text: "https://example.com/wp-content/uploads/report.pdf")

        let plan = try await service.renderPlan(
            for: [sourceBlock],
            overrides: PronunciationOverrides(entries: [:]),
            occurrenceOverrides: .empty,
            fmEnabled: false)

        #expect(await recorder.recordedTargetWords().isEmpty)
        #expect(plan.pronunciationAuditDiagnostics.isEmpty)
    }

    @Test func contextualFamilyWinsOverLeadingAuditComponentInHyphenatedCompound()
        async throws
    {
        // Real acceptance repro: ``harmful-content`` is one whitespace word
        // span, but G2P emits both `harmful` and `content`. The bundled audit
        // pack watches the leading `harmful`, while contextual preflight owns
        // evidence only for the family word `content`.
        let recorder = ShadowEvaluatorRecorder()
        let service = NarrationService(
            db: try DatabaseService(inMemory: ()).writer,
            audiobookID: "b1",
            tts: MockTTSEngine(),
            audioWriter: MockAudioWriter(),
            cacheDirectory: FileManager.default.temporaryDirectory,
            state: NarrationState(),
            pronunciationAuditPack: await EnglishPronunciationAuditPack.bundledOrEmpty(),
            contextualPronunciationEvaluator: { request in
                await recorder.record(request)
                return ContextualPronunciationBatchResult(
                    availability: .available,
                    selections: request.occurrences.map {
                        ContextualModelSelection(
                            occurrenceID: $0.occurrenceID,
                            slot: .needsReview)
                    },
                    failure: nil,
                    runtime: ContextualModelRuntime(
                        platform: "test",
                        osBuild: "test-build",
                        qualifiedRuntimeFamilyID: "test-runtime"))
            },
            fmEnabled: { false })
        let sourceBlock = block(
            "b1",
            id: "harmful-content",
            seq: 0,
            text: "harmful-content containment.")

        let plan = try await service.renderPlan(
            for: [sourceBlock],
            overrides: PronunciationOverrides(entries: [:]),
            occurrenceOverrides: .empty,
            fmEnabled: false)

        #expect(await recorder.recordedTargetWords() == ["content"])
        let decision = try #require(
            plan.blocks.first?.pronunciationDecisions.first {
                $0.normalizedWord == "content"
            })
        #expect(decision.wordStart == 0)
        #expect(decision.wordEnd == 0)
        #expect(decision.source == .monitoredLexicon)
        #expect(decision.contextualEvidence?.familyID == "content")
        #expect(plan.pronunciationAuditDiagnostics.isEmpty)
    }

    @Test func contextualCancellationStopsBeforeNarrationPlanFinalization() async throws {
        let service = NarrationService(
            db: try DatabaseService(inMemory: ()).writer,
            audiobookID: "b1",
            tts: MockTTSEngine(),
            audioWriter: MockAudioWriter(),
            cacheDirectory: FileManager.default.temporaryDirectory,
            state: NarrationState(),
            contextualPronunciationEvaluator: { _ in
                throw CancellationError()
            },
            fmEnabled: { false })

        await #expect(throws: CancellationError.self) {
            try await service.renderPlan(
                for: [block("b1", id: "cancel", seq: 0, text: "Read this record.")],
                overrides: PronunciationOverrides(entries: [:]),
                occurrenceOverrides: .empty,
                fmEnabled: false)
        }
    }

    @Test func cacheLookupDoesNotRunShadowPreflightButNewPlanDoes() async throws {
        let recorder = ShadowEvaluatorRecorder()
        let db = try DatabaseService(inMemory: ())
        let sourceBlocks = [
            block("b1", id: "existing", seq: 0, text: "Please record this.")
        ]
        let service = NarrationService(
            db: db.writer,
            audiobookID: "b1",
            tts: MockTTSEngine(),
            audioWriter: MockAudioWriter(),
            cacheDirectory: FileManager.default.temporaryDirectory,
            state: NarrationState(),
            contextualPronunciationEvaluator: { request in
                await recorder.record(request)
                return ContextualPronunciationBatchResult(
                    availability: .available,
                    selections: request.occurrences.map {
                        ContextualModelSelection(
                            occurrenceID: $0.occurrenceID,
                            slot: .needsReview)
                    },
                    failure: nil,
                    runtime: ContextualModelRuntime(
                        platform: "test",
                        osBuild: "test-build",
                        qualifiedRuntimeFamilyID: "test-runtime"))
            },
            fmEnabled: { false })

        _ = await service.chapterCacheURL(
            chapterIndex: 0,
            blocks: sourceBlocks,
            voice: VoiceID("af_heart"))
        let afterLookup = await recorder.recordedTargetWords()
        #expect(afterLookup.isEmpty)

        _ = try await service.renderPlan(
            for: sourceBlocks,
            overrides: PronunciationOverrides(entries: [:]),
            occurrenceOverrides: .empty,
            fmEnabled: false)
        #expect(await recorder.recordedTargetWords() == ["record"])
    }

    private func productionDecisionFingerprints(
        _ plan: NarrationRenderPlan
    ) -> [String] {
        plan.blocks.flatMap(\.pronunciationDecisions).map {
            [
                $0.blockID,
                String($0.wordStart),
                String($0.wordEnd),
                $0.normalizedWord,
                $0.selectedIPA,
                $0.kokoroTokenIDs.map(String.init).joined(separator: ","),
                $0.source.rawValue,
                $0.ruleID,
            ].joined(separator: "\u{0}")
        }
    }

    @Test func renderFailureRemovesInProgressPartialAndLeavesNoFinalAudioFile() async throws {
        let db = try DatabaseService(inMemory: ())
        let blocks = try seed(db, ["Kaboom"])
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let tts = MockTTSEngine()
        tts.throwOnText = "Kaboom"
        let writer = TouchingAudioWriter()
        let service = NarrationService(
            db: db.writer,
            audiobookID: "b1",
            tts: tts,
            audioWriter: writer,
            cacheDirectory: tmp,
            state: NarrationState(),
            fmEnabled: { false })

        await #expect(throws: NarrationError.synthesisFailed) {
            try await service.renderChapter(
                chapterIndex: 0,
                blocks: blocks,
                voice: VoiceID("af_heart"))
        }

        let openedURL = try #require(writer.openedURLs.first)
        let finalURL = await service.chapterCacheURL(
            chapterIndex: 0,
            blocks: blocks,
            voice: VoiceID("af_heart"))
        #expect(openedURL.pathExtension == "m4a")
        #expect(
            openedURL.lastPathComponent == partialCacheFileName(for: finalURL.lastPathComponent))
        #expect(!FileManager.default.fileExists(atPath: openedURL.path))
        #expect(!FileManager.default.fileExists(atPath: finalURL.path))
    }

    @Test func renderSuccessPublishesPartialToFinalAndReplacesExistingAudioFile() async throws {
        let db = try DatabaseService(inMemory: ())
        let blocks = try seed(db, ["Success"])
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let writer = TouchingAudioWriter()
        let service = NarrationService(
            db: db.writer,
            audiobookID: "b1",
            tts: MockTTSEngine(),
            audioWriter: writer,
            cacheDirectory: tmp,
            state: NarrationState(),
            fmEnabled: { false })
        let finalURL = await service.chapterCacheURL(
            chapterIndex: 0,
            blocks: blocks,
            voice: VoiceID("af_heart"))
        _ = FileManager.default.createFile(atPath: finalURL.path, contents: Data("old".utf8))

        try await service.renderChapter(
            chapterIndex: 0,
            blocks: blocks,
            voice: VoiceID("af_heart"))

        let openedURL = try #require(writer.openedURLs.first)
        #expect(
            openedURL.lastPathComponent == partialCacheFileName(for: finalURL.lastPathComponent))
        #expect(!FileManager.default.fileExists(atPath: openedURL.path))
        #expect(FileManager.default.fileExists(atPath: finalURL.path))
        #expect(FileManager.default.contents(atPath: finalURL.path) == Data("partial".utf8))
    }

    @Test func renderSegmentPersistsTrackTimelineAndSegmentKey() async throws {
        let db = try DatabaseService(inMemory: ())
        let blocks = try seed(db, ["first", "second", "third"])
        let writer = MockAudioWriter()
        let svc = makeService(
            db, tts: MockTTSEngine(secondsPerChar: 0.1), writer: writer)

        try await svc.renderSegment(
            chapterIndex: 0,
            chapterDisplayNumber: 1,
            segmentIndex: 0,
            blocks: Array(blocks[0...1]),
            voice: VoiceID("af_warm"),
            chapterTitle: "ch. 1: Opening")
        try await svc.renderSegment(
            chapterIndex: 0,
            chapterDisplayNumber: 1,
            segmentIndex: 1,
            blocks: [blocks[2]],
            voice: VoiceID("af_warm"),
            chapterTitle: "ch. 1: Opening")

        let tracks = try TrackDAO(db: db.writer).tracks(for: "b1")
        #expect(tracks.map(\.id) == ["syn-b1-ch0-s0", "syn-b1-ch0-s1"])
        #expect(tracks.map(\.title) == ["ch. 1: Opening", "ch. 1: Opening"])
        #expect(tracks.map(\.sortOrder) == [0, 1])
        #expect(tracks.map(\.narrationVoice) == ["af_warm", "af_warm"])
        #expect(
            abs(
                (tracks.first?.duration ?? -1)
                    - (1.1 + NarrationPlannedSilence.paragraph.duration)) < 0.0001)
        #expect(abs((tracks.last?.duration ?? -1) - 0.5) < 0.0001)

        let expectedNames = tracks.map {
            partialCacheFileName(for: URL(fileURLWithPath: $0.filePath).lastPathComponent)
        }
        #expect(writer.writtenURLs.map(\.lastPathComponent) == expectedNames)

        let anchors = try db.read { db in
            try AlignmentAnchorRecord
                .filter(Column("audiobook_id") == "b1")
                .order(Column("epub_block_id"))
                .fetchAll(db)
        }
        #expect(anchors.map(\.epubBlockID) == ["blk0", "blk1", "blk2"])
        #expect(
            anchors.map(\.audioTime) == [
                0.0, 0.5 + NarrationPlannedSilence.paragraph.duration, 0.0,
            ])

        let rows = try db.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT epub_block_id, audio_start_time, audio_end_time, segment_key
                    FROM timeline_item
                    WHERE audiobook_id = 'b1'
                      AND epub_block_id IS NOT NULL
                      AND audio_start_time >= 0
                    ORDER BY epub_block_id
                    """)
        }
        #expect(rows.compactMap { $0["epub_block_id"] as String? } == ["blk0", "blk1", "blk2"])
        #expect(rows.compactMap { $0["segment_key"] as String? } == ["0-0", "0-0", "0-1"])
        #expect(
            rows.compactMap { $0["audio_start_time"] as Double? } == [
                0.0, 0.5 + NarrationPlannedSilence.paragraph.duration, 0.0,
            ])
        #expect(
            rows.compactMap { $0["audio_end_time"] as Double? } == [
                0.5, 1.1 + NarrationPlannedSilence.paragraph.duration, 0.5,
            ])
    }

    @Test func renderSegmentReportsZeroThenEachSpeakableBlock() async throws {
        let db = try DatabaseService(inMemory: ())
        let chapterBlocks = try seed(db, ["One.", "Two.", "Three."])
        let service = makeService(
            db,
            tts: MockTTSEngine(secondsPerChar: 0.1),
            writer: MockAudioWriter())
        var values: [NarrationRenderProgress] = []

        _ = try await service.renderSegment(
            chapterIndex: 0,
            chapterDisplayNumber: 1,
            segmentIndex: 0,
            blocks: chapterBlocks,
            voice: VoiceID("af_heart"),
            onBlockProgress: { values.append($0) })

        #expect(values.map(\.completedBlocks) == [0, 1, 2, 3])
        #expect(values.allSatisfy { $0.totalBlocks == 3 })
        #expect(values.allSatisfy { $0.chapterDisplayNumber == 1 })
        #expect(values.allSatisfy { $0.segmentIndex == 0 })
        #expect(values.allSatisfy { $0.voiceID == VoiceID("af_heart") })
    }

    @Test func renderSegmentReturnsPersistedRenderedMetadata() async throws {
        let db = try DatabaseService(inMemory: ())
        let blocks = try seed(db, ["Metadata"])
        let service = makeService(
            db,
            tts: MockTTSEngine(secondsPerChar: 0.1),
            writer: MockAudioWriter())

        let rendered = try await service.renderSegment(
            chapterIndex: 4,
            chapterDisplayNumber: 5,
            segmentIndex: 2,
            blocks: blocks,
            voice: VoiceID("bm_daniel"))

        #expect(rendered.chapterIndex == 4)
        #expect(rendered.chapterDisplayNumber == 5)
        #expect(rendered.segmentIndex == 2)
        #expect(rendered.duration == 0.8)
        let tracks = try TrackDAO(db: db.writer).tracks(for: "b1")
        #expect(tracks.map(\.filePath) == [rendered.fileURL.path])
    }

    @Test func stableCachedSegmentReorderUpdatesSortOrderWithoutSynthesizing() async throws {
        let db = try DatabaseService(inMemory: ())
        let blocks = try seed(db, ["first"])
        let tts = MockTTSEngine(secondsPerChar: 0.1)
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let service = NarrationService(
            db: db.writer, audiobookID: "b1", tts: tts,
            audioWriter: AVFoundationAudioWriter(), cacheDirectory: tmp,
            state: NarrationState(), fmEnabled: { false })
        let sourceChapterKey = "75D4AA19-0B16-4B27-A2CD-D4E19ED6B20A"

        try await service.renderSegment(
            chapterIndex: 1,
            sourceChapterKey: sourceChapterKey,
            chapterDisplayNumber: 2,
            segmentIndex: 0,
            blocks: blocks,
            voice: VoiceID("af_heart"),
            chapterTitle: "Before reorder")
        let synthesisCount = tts.calls.count

        try await service.updateCachedNarrationTitle(
            chapterIndex: 9,
            sourceChapterKey: sourceChapterKey,
            chapterDisplayNumber: 10,
            segmentIndex: 0,
            blocks: blocks,
            voice: VoiceID("af_heart"),
            chapterTitle: "After reorder")

        let tracks = try TrackDAO(db: db.writer).tracks(for: "b1")
        #expect(tts.calls.count == synthesisCount)
        #expect(tracks.count == 1)
        #expect(
            tracks.first?.id
                == NarrationFileNaming.trackID(
                    audiobookID: "b1", chapterIndex: 9,
                    sourceChapterKey: sourceChapterKey, segmentIndex: 0))
        #expect(tracks.first?.title == "After reorder")
        #expect(tracks.first?.sortOrder == 9_000)
        #expect(tracks.first?.narrationVoice == "af_heart")
    }

    @Test func validPublishedCacheWithoutTrackRowIsReconciledByUpsert() async throws {
        let db = try DatabaseService(inMemory: ())
        let blocks = try seed(db, ["crash window"])
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let tts = MockTTSEngine(secondsPerChar: 0.1)
        let service = NarrationService(
            db: db.writer, audiobookID: "b1", tts: tts,
            audioWriter: AVFoundationAudioWriter(), cacheDirectory: tmp,
            state: NarrationState(), fmEnabled: { false })
        let sourceChapterKey = "75D4AA19-0B16-4B27-A2CD-D4E19ED6B20A"
        let voice = VoiceID("af_heart")
        let fileURL = await service.segmentCacheURL(
            chapterIndex: 4, sourceChapterKey: sourceChapterKey,
            segmentIndex: 0, blocks: blocks, voice: voice)
        let samples = [Float](repeating: 0.1, count: 2_400)
        _ = try await AVFoundationAudioWriter().write(
            [TTSChunk(samples: samples, sampleRate: 24_000, duration: 0.1)],
            to: fileURL)

        let reused = try await service.updateCachedNarrationTitle(
            chapterIndex: 4,
            sourceChapterKey: sourceChapterKey,
            chapterDisplayNumber: 2,
            segmentIndex: 0,
            blocks: blocks,
            voice: voice,
            chapterTitle: "Recovered cache")

        let track = try #require(TrackDAO(db: db.writer).tracks(for: "b1").first)
        #expect(tts.calls.isEmpty)
        #expect(track.filePath == fileURL.path)
        #expect(track.duration > 0)
        #expect(track.title == "Recovered cache")
        #expect(track.sortOrder == 4_000)
        #expect(track.narrationVoice == voice.rawValue)
        #expect(reused)
    }

    @Test func invalidCachedSegmentIsRemovedAndReportedForCallerRender() async throws {
        let db = try DatabaseService(inMemory: ())
        let blocks = try seed(db, ["invalid cache"])
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let tts = MockTTSEngine(secondsPerChar: 0.1)
        let service = NarrationService(
            db: db.writer, audiobookID: "b1", tts: tts,
            audioWriter: MockAudioWriter(), cacheDirectory: tmp,
            state: NarrationState(), fmEnabled: { false })
        let voice = VoiceID("af_heart")
        let fileURL = await service.segmentCacheURL(
            chapterIndex: 4,
            segmentIndex: 0,
            blocks: blocks,
            voice: voice)
        try Data("not an audio file".utf8).write(to: fileURL)

        let reused = try await service.updateCachedNarrationTitle(
            chapterIndex: 4,
            chapterDisplayNumber: 5,
            segmentIndex: 0,
            blocks: blocks,
            voice: voice,
            chapterTitle: "Invalid cache")

        #expect(reused == false)
        #expect(FileManager.default.fileExists(atPath: fileURL.path) == false)
        #expect(tts.calls.isEmpty)
    }

    @Test func invalidCacheValidationAndDeletionRunOffTheMainThread() async throws {
        NarrationService.debugCacheValidationRanOnMainThread.withLock { $0 = nil }
        NarrationService.debugInvalidCacheDeletionRanOnMainThread.withLock { $0 = nil }
        let db = try DatabaseService(inMemory: ())
        let blocks = try seed(db, ["off-main invalid cache"])
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let service = NarrationService(
            db: db.writer, audiobookID: "b1", tts: MockTTSEngine(secondsPerChar: 0.1),
            audioWriter: MockAudioWriter(), cacheDirectory: tmp,
            state: NarrationState(), fmEnabled: { false })
        let voice = VoiceID("af_heart")
        let fileURL = await service.segmentCacheURL(
            chapterIndex: 4,
            segmentIndex: 0,
            blocks: blocks,
            voice: voice)
        try Data("not an audio file".utf8).write(to: fileURL)

        let reused = try await service.updateCachedNarrationTitle(
            chapterIndex: 4,
            chapterDisplayNumber: 5,
            segmentIndex: 0,
            blocks: blocks,
            voice: voice,
            chapterTitle: "Invalid cache")

        let validationRanOnMainThread = NarrationService.debugCacheValidationRanOnMainThread
            .withLock { $0 }
        let deletionRanOnMainThread = NarrationService.debugInvalidCacheDeletionRanOnMainThread
            .withLock { $0 }
        #expect(reused == false)
        #expect(validationRanOnMainThread == false)
        #expect(deletionRanOnMainThread == false)
        #expect(FileManager.default.fileExists(atPath: fileURL.path) == false)
    }

    @Test func cachedSegmentDatabaseFailurePropagatesWithoutDeletingValidAudio() async throws {
        let db = try DatabaseService(inMemory: ())
        let blocks = try seed(db, ["preserve valid cache"])
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let service = NarrationService(
            db: db.writer, audiobookID: "b1", tts: MockTTSEngine(secondsPerChar: 0.1),
            audioWriter: AVFoundationAudioWriter(), cacheDirectory: tmp,
            state: NarrationState(), fmEnabled: { false })
        let voice = VoiceID("af_heart")
        let fileURL = await service.segmentCacheURL(
            chapterIndex: 4,
            segmentIndex: 0,
            blocks: blocks,
            voice: voice)
        let samples = [Float](repeating: 0.1, count: 2_400)
        _ = try await AVFoundationAudioWriter().write(
            [TTSChunk(samples: samples, sampleRate: 24_000, duration: 0.1)],
            to: fileURL)
        try db.write { database in
            try database.execute(sql: "DROP TABLE track")
        }

        do {
            _ = try await service.updateCachedNarrationTitle(
                chapterIndex: 4,
                chapterDisplayNumber: 5,
                segmentIndex: 0,
                blocks: blocks,
                voice: voice,
                chapterTitle: "Database failure")
            Issue.record("Expected the track persistence failure to propagate.")
        } catch is GRDB.DatabaseError {
            // Expected: persistence failures must not be mistaken for invalid audio.
        } catch {
            Issue.record("Expected a GRDB database error, got \(error).")
        }

        #expect(FileManager.default.fileExists(atPath: fileURL.path))
    }

    @Test func stableSegmentVoiceChangeCreatesOnlyThatChaptersNewCacheFile() async throws {
        let db = try DatabaseService(inMemory: ())
        let blocks = try seed(db, ["first"])
        let writer = MockAudioWriter()
        let service = makeService(
            db, tts: MockTTSEngine(secondsPerChar: 0.1), writer: writer)
        let sourceChapterKey = "75D4AA19-0B16-4B27-A2CD-D4E19ED6B20A"
        let otherSourceChapterKey = "FC46FC66-FBDF-4D70-8F99-47ABCA675B86"

        let first = try await service.renderSegmentFile(
            chapterIndex: 1,
            sourceChapterKey: sourceChapterKey,
            chapterDisplayNumber: 2,
            segmentIndex: 0,
            blocks: blocks,
            voice: VoiceID("af_heart"))
        let unaffected = try await service.renderSegmentFile(
            chapterIndex: 2,
            sourceChapterKey: otherSourceChapterKey,
            chapterDisplayNumber: 3,
            segmentIndex: 0,
            blocks: blocks,
            voice: VoiceID("af_heart"))
        let changedVoice = try await service.renderSegmentFile(
            chapterIndex: 9,
            sourceChapterKey: sourceChapterKey,
            chapterDisplayNumber: 10,
            segmentIndex: 0,
            blocks: blocks,
            voice: VoiceID("bf_emma"))

        #expect(first.fileURL.lastPathComponent != changedVoice.fileURL.lastPathComponent)
        #expect(
            first.fileURL.lastPathComponent.hasPrefix(
                "b1-ck\(NarrationFileNaming.stableChapterToken(for: sourceChapterKey))-s0"))
        #expect(
            unaffected.fileURL.lastPathComponent.hasPrefix(
                "b1-ck\(NarrationFileNaming.stableChapterToken(for: otherSourceChapterKey))-s0"))
        #expect(!unaffected.fileURL.lastPathComponent.contains("bf_emma"))
        #expect(writer.writtenURLs.count == 3)
    }

    @Test func skipsBlocksWithNoText() async throws {
        let db = try DatabaseService(inMemory: ())
        let blocks = try seed(db, ["hello", nil, ""])
        let tts = MockTTSEngine()
        let svc = makeService(db, tts: tts, writer: MockAudioWriter())
        try await svc.renderChapter(
            chapterIndex: 0, blocks: blocks,
            voice: VoiceID("af_warm"))
        let anchorCount = try db.read { db in
            try AlignmentAnchorRecord.filter(Column("audiobook_id") == "b1").fetchCount(db)
        }
        #expect(anchorCount == 1)
        #expect(tts.calls.count == 1)
    }

    @Test func cancellationStopsBeforeWritingTrack() async throws {
        let db = try DatabaseService(inMemory: ())
        let blocks = try seed(db, ["abcd", "ef"])
        let svc = makeService(db, tts: MockTTSEngine(), writer: MockAudioWriter())
        let task = Task {
            try await svc.renderChapter(
                chapterIndex: 0,
                blocks: blocks, voice: VoiceID("af_warm"))
        }
        task.cancel()
        _ = try? await task.value
        let trackCount = try db.read { db in try TrackRecord.fetchCount(db) }
        #expect(trackCount == 0)
    }

    /// A long multi-sentence block whose sentences are all DISTINCT, so the
    /// chunker's merged sub-chunks are unique strings (a duplicate would let a
    /// single `lengthCapOnText` match — and skip — more than one sub-chunk).
    private func longDistinctBlockText() -> String {
        (1...8).map { i in
            "Sentence number \(i) describes the quick brown fox jumping over a lazy dog."
        }.joined(separator: " ")
    }

    private func plannedSpeechSegments(for blocks: [EPubBlockRecord]) throws -> [String] {
        try NarrationRenderPlanner.make(
            blocks: blocks,
            overrides: PronunciationOverrides(entries: [:])
        ).blocks.flatMap { block in
            block.synthesisChunks.map(\.g2pInputText)
        }
    }

    @Test func multiSubChunkBlockStillYieldsOneAnchorSpanningSummedDuration() async throws {
        let db = try DatabaseService(inMemory: ())
        // A long multi-sentence block that the chunker splits into several
        // sub-chunks (> 200 chars). It must still produce exactly ONE anchor,
        // spanning the sum of every sub-chunk's duration.
        let long = longDistinctBlockText()
        let blocks = try seed(db, [long])

        let subChunks = try plannedSpeechSegments(for: blocks)
        #expect(subChunks.count > 1)  // guard: the block really does fan out

        let secondsPerChar = 0.1
        let mock = MockTTSEngine(secondsPerChar: secondsPerChar)
        let writer = MockAudioWriter()
        let svc = makeService(db, tts: mock, writer: writer)

        try await svc.renderChapter(chapterIndex: 0, blocks: blocks, voice: VoiceID("af_warm"))

        let anchors = try db.read { db in
            try AlignmentAnchorRecord.filter(Column("audiobook_id") == "b1").fetchAll(db)
        }
        #expect(anchors.count == 1)  // ONE anchor per original block, not per sub-chunk
        #expect(anchors[0].epubBlockID == "blk0")

        // The single anchor spans the SUM of every sub-chunk's duration.
        let expectedDuration = subChunks.reduce(0.0) { $0 + Double($1.count) * secondsPerChar }
        let span = (anchors[0].audioEndTime ?? 0) - anchors[0].audioTime
        #expect(abs(span - expectedDuration) < 0.0001)

        // Every sub-chunk was synthesized and handed to the writer; the writer
        // also receives the trailing lead-out silence (one extra append, no TTS
        // call), so the chunk count is sub-chunks + 1.
        #expect(mock.calls.count == subChunks.count)
        #expect(writer.chunkCounts == [subChunks.count + 1])
    }

    @Test func lengthCapSubChunkIsSkippedWithoutAbortingTheChapter() async throws {
        let db = try DatabaseService(inMemory: ())
        let long = longDistinctBlockText()
        let blocks = try seed(db, [long])

        let subChunks = try plannedSpeechSegments(for: blocks)
        #expect(subChunks.count > 1)

        let secondsPerChar = 0.1
        let mock = MockTTSEngine(secondsPerChar: secondsPerChar)
        // Make the FIRST sub-chunk raise the length-cap error. The chapter must
        // still complete with the remaining sub-chunks.
        mock.lengthCapOnText = subChunks[0]
        let writer = MockAudioWriter()
        let svc = makeService(db, tts: mock, writer: writer)

        try await svc.renderChapter(chapterIndex: 0, blocks: blocks, voice: VoiceID("af_warm"))

        // Track + anchor still written (chapter not aborted).
        let trackCount = try db.read { db in try TrackRecord.fetchCount(db) }
        #expect(trackCount == 1)
        let anchors = try db.read { db in
            try AlignmentAnchorRecord.filter(Column("audiobook_id") == "b1").fetchAll(db)
        }
        #expect(anchors.count == 1)

        // The skipped sub-chunk's duration is excluded from the span; only the
        // surviving sub-chunks were written.
        let survivors = Array(subChunks.dropFirst())
        let expectedDuration = survivors.reduce(0.0) { $0 + Double($1.count) * secondsPerChar }
        let span = (anchors[0].audioEndTime ?? 0) - anchors[0].audioTime
        #expect(abs(span - expectedDuration) < 0.0001)
        // Surviving sub-chunks + the trailing lead-out silence.
        #expect(writer.chunkCounts == [survivors.count + 1])
    }

    @Test func onnxInvalidExpandShapeSubChunkIsSkippedWithoutAbortingTheChapter() async throws {
        let db = try DatabaseService(inMemory: ())
        let long = longDistinctBlockText()
        let blocks = try seed(db, [long])

        let subChunks = try plannedSpeechSegments(for: blocks)
        #expect(subChunks.count > 1)

        let secondsPerChar = 0.1
        let mock = MockTTSEngine(secondsPerChar: secondsPerChar)
        mock.invalidExpandShapeOnText = subChunks[0]
        let writer = MockAudioWriter()
        let svc = makeService(db, tts: mock, writer: writer)

        try await svc.renderChapter(chapterIndex: 0, blocks: blocks, voice: VoiceID("af_warm"))

        let trackCount = try db.read { db in try TrackRecord.fetchCount(db) }
        #expect(trackCount == 1)
        let anchors = try db.read { db in
            try AlignmentAnchorRecord.filter(Column("audiobook_id") == "b1").fetchAll(db)
        }
        #expect(anchors.count == 1)

        let survivors = Array(subChunks.dropFirst())
        let expectedDuration = survivors.reduce(0.0) { $0 + Double($1.count) * secondsPerChar }
        let span = (anchors[0].audioEndTime ?? 0) - anchors[0].audioTime
        #expect(abs(span - expectedDuration) < 0.0001)
        #expect(writer.chunkCounts == [survivors.count + 1])
    }

    @Test func skippedOnlySpeechChunkDoesNotCreateZeroLengthAnchor() async throws {
        let db = try DatabaseService(inMemory: ())
        let text = "too long"
        let blocks = try seed(db, [text])
        let mock = MockTTSEngine(secondsPerChar: 0.1)
        mock.lengthCapOnText = text
        let writer = MockAudioWriter()
        let svc = makeService(db, tts: mock, writer: writer)

        try await svc.renderChapter(chapterIndex: 0, blocks: blocks, voice: VoiceID("af_warm"))

        let anchors = try db.read { db in
            try AlignmentAnchorRecord.filter(Column("audiobook_id") == "b1").fetchAll(db)
        }
        #expect(anchors.isEmpty)
        #expect(writer.chunkCounts == [0])
    }

    @Test func silentSpeechChunkRetriesWithSmallerPieces() async throws {
        let db = try DatabaseService(inMemory: ())
        let text = "alpha beta gamma delta epsilon zeta eta theta iota kappa lambda mu."
        let blocks = try seed(db, [text])
        let mock = MockTTSEngine(secondsPerChar: 0.1)
        mock.silentOnText = try NarrationRenderPlanner.make(
            blocks: blocks,
            overrides: PronunciationOverrides(entries: [:])
        ).blocks[0].synthesisChunks[0].g2pInputText
        let svc = makeService(db, tts: mock, writer: MockAudioWriter())

        try await svc.renderChapter(chapterIndex: 0, blocks: blocks, voice: VoiceID("af_heart"))

        let retryCalls = mock.calls.dropFirst()
        #expect(!retryCalls.isEmpty)
        #expect(retryCalls.allSatisfy { $0.text.count < text.count })
    }

    @Test func renderChapterDispatchesApprovedPlanThroughTTSEngine() async throws {
        let db = try DatabaseService(inMemory: ())
        let blocks = try seed(db, ["The filesystem stores the verified result."])
        let engine = MockTTSEngine(secondsPerChar: 0.01)
        let service = makeService(
            db, tts: engine, writer: MockAudioWriter(),
            overrides: { PronunciationOverrides(entries: ["filesystem": "fˈIl sˌɪstəm"]) }
        )

        try await service.renderChapter(
            chapterIndex: 0, blocks: blocks, voice: VoiceID("am_michael"))

        let call = try #require(engine.plannedCalls.first)
        #expect(call.chunk.g2pInputText.contains("[filesystem](/fˈIl sˌɪstəm/)"))
        #expect(call.chunk.phonemes.contains("fˈIl sˌɪstəm"))
        #expect(call.chunk.displayText == "The filesystem stores the verified result.")
    }

    @Test func renderChapterReturnsFrozenDecisionWithBlockAnchorFallback() async throws {
        let db = try DatabaseService(inMemory: ())
        let blocks = try seed(db, ["The filesystem stores the result."])
        let engine = MockTTSEngine(secondsPerChar: 0.01)
        var overrideReads = 0
        let service = makeService(
            db,
            tts: engine,
            writer: MockAudioWriter(),
            overrides: {
                overrideReads += 1
                let ipa = overrideReads == 1 ? "fˈIl sˌɪstəm" : "fˈaɪl sˌɪstəm"
                return PronunciationOverrides(entries: ["filesystem": ipa])
            })

        let rendered = try await service.renderChapter(
            chapterIndex: 3,
            blocks: blocks,
            voice: VoiceID("am_michael"))

        #expect(overrideReads == 1)
        let decision = try #require(rendered.pronunciationDecisions.first)
        let anchor = try #require(rendered.anchors.first)
        let range = try #require(decision.chapterRelativeAudioRange)
        #expect(rendered.pronunciationDecisions.count == 1)
        #expect(decision.chapterIndex == 3)
        #expect(decision.selectedIPA == "fˈIl sˌɪstəm")
        #expect(decision.timingPrecision == .blockAnchorFallback)
        #expect(abs(range.start - anchor.audioTime) < 0.0001)
        #expect(abs(range.end - (anchor.audioEndTime ?? -1)) < 0.0001)
        #expect(range.end > range.start)
        #expect(decision.bookRelativeAudioRange == nil)
        #expect(engine.plannedCalls.first?.chunk.g2pInputText.contains("fˈIl sˌɪstəm") == true)
    }

    @Test func renderChapterPreservesPlanEvidenceDiagnosticWithoutFabricatingDecision()
        async throws
    {
        let db = try DatabaseService(inMemory: ())
        let blocks = try seed(db, ["verified [site](https://example.com)"])
        let service = makeService(
            db,
            tts: MockTTSEngine(secondsPerChar: 0.01),
            writer: MockAudioWriter())

        let rendered = try await service.renderChapter(
            chapterIndex: 4,
            blocks: blocks,
            voice: VoiceID("am_michael"))

        #expect(rendered.pronunciationDecisions.isEmpty)
        let diagnostic = try #require(rendered.pronunciationAuditDiagnostics.first)
        #expect(rendered.pronunciationAuditDiagnostics.count == 1)
        #expect(diagnostic.reason == .spokenSurfaceMismatch)
        #expect(diagnostic.blockID == "blk0")
        #expect(diagnostic.chunkIndex == 0)
        #expect(diagnostic.chapterIndex == 4)
        #expect(diagnostic.expectedDisplayText == "verified [site](https://example.com)")
        #expect(diagnostic.reconstructedSpokenSurface == "verified site")
    }

    @Test func skippedPlannedChunkLeavesItsDecisionRangeFreeAndDiagnosesIncompleteRender()
        async throws
    {
        let db = try DatabaseService(inMemory: ())
        let text = "Verified. \(longDistinctBlockText())"
        let blocks = try seed(db, [text])
        let plan = try NarrationRenderPlanner.make(
            blocks: blocks,
            overrides: PronunciationOverrides(entries: [:]))
        let plannedBlock = try #require(plan.blocks.first)
        let skippedChunkIndex = try #require(
            plannedBlock.synthesisChunks.firstIndex {
                WordTokenizer.words(in: $0.displayText).contains {
                    PronunciationAuditContext.normalizedWord(String($0)) == "verified"
                }
            })
        try #require(plannedBlock.synthesisChunks.count > 1)
        let skippedChunk = plannedBlock.synthesisChunks[skippedChunkIndex]
        let engine = MockTTSEngine(secondsPerChar: 0.01)
        engine.lengthCapOnText = skippedChunk.g2pInputText
        let service = makeService(db, tts: engine, writer: MockAudioWriter())

        let rendered = try await service.renderChapter(
            chapterIndex: 2,
            blocks: blocks,
            voice: VoiceID("am_michael"))

        let decision = try #require(
            rendered.pronunciationDecisions.first { $0.normalizedWord == "verified" })
        #expect(decision.chapterIndex == 2)
        #expect(decision.chapterRelativeAudioRange == nil)
        #expect(decision.bookRelativeAudioRange == nil)
        #expect(decision.timingPrecision == nil)
        let anchor = try #require(rendered.anchors.first)
        #expect((anchor.audioEndTime ?? 0) > anchor.audioTime)

        let diagnostic = try #require(
            rendered.pronunciationAuditDiagnostics.first { $0.reason == .incompleteRender })
        #expect(diagnostic.blockID == "blk0")
        #expect(diagnostic.chunkIndex == skippedChunkIndex)
        #expect(diagnostic.chapterIndex == 2)
        #expect(diagnostic.expectedDisplayText == skippedChunk.displayText)
        #expect(diagnostic.reconstructedSpokenSurface.isEmpty)
    }

    @Test func servicePreparedBlocksCarryOccurrenceDecisionIntoRenderPlan() async throws {
        let db = try DatabaseService(inMemory: ())
        let blocks = try seed(db, ["The content stays here."])
        let service = makeService(db, tts: MockTTSEngine(), writer: MockAudioWriter())
        let occurrenceOverrides = PronunciationOccurrenceOverrides(entries: [
            PronunciationOccurrenceOverride(
                blockID: "blk0",
                wordStart: 1,
                wordEnd: 1,
                word: "content",
                ipa: "kˈɑntɛnt")
        ])

        let plan = try await service.renderPlan(
            for: blocks,
            overrides: PronunciationOverrides(
                entries: ["content": "kəntˈɛnt"],
                source: .bookOverride),
            occurrenceOverrides: occurrenceOverrides,
            fmEnabled: false)
        let plannedBlock = try #require(plan.blocks.first)
        let decision = try #require(plannedBlock.pronunciationDecisions.first)

        #expect(plannedBlock.pronunciationDecisions.count == 1)
        #expect(decision.blockID == "blk0")
        #expect(decision.wordStart == 1)
        #expect(decision.source == .occurrenceOverride)
        #expect(decision.selectedIPA == "kˈɑntɛnt")
        #expect(
            plannedBlock.synthesisChunks.map(\.g2pInputText)
                == ["The [content](/kˈɑntɛnt/) stays here."])
    }

    @Test func structuredPlanningLeavesLegacyContentSignatureUnchanged() async throws {
        let db = try DatabaseService(inMemory: ())
        let blocks = try seed(db, ["The content lives here."])
        let overrides = PronunciationOverrides(entries: ["content": "kˈɑntɛnt"])
        let occurrences = PronunciationOccurrenceOverrides(entries: [
            PronunciationOccurrenceOverride(
                blockID: "blk0",
                wordStart: 2,
                wordEnd: 2,
                word: "lives",
                ipa: "lˈIvz")
        ])
        let service = makeService(
            db,
            tts: MockTTSEngine(),
            writer: MockAudioWriter(),
            overrides: { overrides },
            occurrenceOverrides: { occurrences })

        let normalized = TextNormalizer.normalize(blocks[0].text ?? "")
        let occurrenceText = occurrences.apply(to: normalized, blockID: "blk0")
        let renderedText = HomographPronunciationResolver.apply(
            to: overrides.apply(to: occurrenceText))
        let signature = NarrationFileNaming.contentSignature(
            spokenBlocks: blocks,
            renderedTexts: [renderedText],
            includeLeadOutPad: true,
            normalizationMode: "deterministic",
            pronunciationPolicySignature: EnglishPronunciationPack.empty.productionPolicySignature)
        let expectedName = NarrationFileNaming.chapterFileName(
            audiobookID: "b1",
            chapterIndex: 0,
            voice: VoiceID("af_heart"),
            contentSignature: signature)

        let actual = await service.chapterCacheURL(
            chapterIndex: 0,
            blocks: blocks,
            voice: VoiceID("af_heart"))

        #expect(actual.lastPathComponent == expectedName)
    }

    @Test func plannedQualityEvaluationUsesDisplayTextInsteadOfPronunciationMarkup() async throws {
        let db = try DatabaseService(inMemory: ())
        let blocks = try seed(db, ["filesystem"])
        let spacedIPA = "f ˈI l s ˌɪ s t ə m"
        let engine = MockTTSEngine(secondsPerChar: 0.01)
        let service = makeService(
            db, tts: engine, writer: MockAudioWriter(),
            overrides: { PronunciationOverrides(entries: ["filesystem": spacedIPA]) }
        )

        try await service.renderChapter(
            chapterIndex: 0, blocks: blocks, voice: VoiceID("am_michael"))

        #expect(engine.plannedCalls.count == 1)
        #expect(engine.plannedCalls.first?.chunk.displayText == "filesystem")
    }

    @Test func qualityRetrySplitsOnlyTheResolvedPronunciationFragment() async throws {
        let db = try DatabaseService(inMemory: ())
        let text =
            "The filesystem stores alpha beta gamma delta epsilon zeta eta theta iota kappa lambda mu."
        let blocks = try seed(db, [text])
        let planned = try #require(
            NarrationRenderPlanner.make(
                blocks: blocks,
                overrides: PronunciationOverrides(entries: ["filesystem": "fˈIl sˌɪstəm"])
            ).blocks.first?.synthesisChunks.first)
        let engine = MockTTSEngine(secondsPerChar: 0.1)
        engine.silentOnText = planned.g2pInputText
        let service = makeService(
            db, tts: engine, writer: MockAudioWriter(),
            overrides: { PronunciationOverrides(entries: ["filesystem": "fˈIl sˌɪstəm"]) }
        )

        try await service.renderChapter(
            chapterIndex: 0, blocks: blocks, voice: VoiceID("am_michael"))

        let retryCalls = engine.plannedCalls.dropFirst()
        let link = "[filesystem](/fˈIl sˌɪstəm/)"
        #expect(retryCalls.count > 1)

        // Computed before the assertions on purpose: `#expect` captures its whole
        // condition as one instrumented expression tree, so folding a `reduce` or
        // `allSatisfy` over the labeled `(chunk:voice:)` tuples into the condition
        // costs enough to exhaust the constraint solver on some Xcode 26.x
        // toolchains ("unable to type-check this expression in reasonable time").
        // The explicit `Int` pins `reduce`'s result so the literals and `+`/`-`
        // overloads resolve immediately. Keep these hoisted.
        let linkOccurrences: Int = retryCalls.reduce(0) { total, call in
            total + call.chunk.g2pInputText.components(separatedBy: link).count - 1
        }
        #expect(linkOccurrences == 1)

        let everyRetryKeepsTheLinkIntact = retryCalls.allSatisfy { call in
            let text = call.chunk.g2pInputText
            return text.contains("[filesystem]") == false || text.contains(link)
        }
        #expect(everyRetryKeepsTheLinkIntact)
    }

    @Test(.timeLimit(.minutes(1)))
    func qualityRetryTerminatesWhenOneAtomicLinkExceedsTheRetryBudget() async throws {
        let db = try DatabaseService(inMemory: ())
        let blocks = try seed(db, ["filesystem"])
        let longIPA = Array(repeating: "f", count: 40).joined(separator: " ")
        let planned = try #require(
            NarrationRenderPlanner.make(
                blocks: blocks,
                overrides: PronunciationOverrides(entries: ["filesystem": longIPA])
            ).blocks.first?.synthesisChunks.first)
        let engine = MockTTSEngine(secondsPerChar: 0.01)
        engine.silentOnText = planned.g2pInputText
        let service = makeService(
            db, tts: engine, writer: MockAudioWriter(),
            overrides: { PronunciationOverrides(entries: ["filesystem": longIPA]) }
        )

        try await service.renderChapter(
            chapterIndex: 0, blocks: blocks, voice: VoiceID("am_michael"))

        #expect(
            engine.plannedCalls.count == NarrationService.maximumQualityRetryDepth + 1)
        #expect(engine.plannedCalls.allSatisfy { $0.chunk == planned })
    }

    @Test func retryAggregatesOnlyAcceptedPlannedFallbackEvidenceOnce() async throws {
        let db = try DatabaseService(inMemory: ())
        let text = "Jacqui met alpha beta gamma delta epsilon zeta eta theta iota kappa lambda mu."
        let blocks = try seed(db, [text])
        let planned = try #require(
            NarrationRenderPlanner.make(
                blocks: blocks,
                overrides: PronunciationOverrides(entries: [:])
            ).blocks.first?.synthesisChunks.first)
        let fallback = try #require(
            planned.pronunciationFallbackHits.first { $0.word.lowercased() == "jacqui" })
        let engine = MockTTSEngine(secondsPerChar: 0.1)
        engine.silentOnText = planned.g2pInputText
        let service = makeService(db, tts: engine, writer: MockAudioWriter())

        let rendered = try await service.renderSegmentFile(
            chapterIndex: 0,
            chapterDisplayNumber: 1,
            segmentIndex: 0,
            blocks: blocks,
            voice: VoiceID("am_michael"))

        #expect(engine.plannedCalls.count > 1)
        #expect(rendered.pronunciationFallbackHits.map(\.fallback) == [fallback])
    }

    @Test func qualityRetryDispatchesFrozenWatchedAndFallbackPlanIntoReceipt() async throws {
        let db = try DatabaseService(inMemory: ())
        let text =
            "Jacqui met the verified result. Alpha beta gamma delta epsilon zeta eta theta iota kappa lambda mu."
        let blocks = try seed(db, [text])
        let parent = try #require(
            NarrationRenderPlanner.make(
                blocks: blocks,
                overrides: PronunciationOverrides(entries: [:])
            ).blocks.first?.synthesisChunks.first)
        let expectedChildren = parent.frozenRetrySlices(
            maxPhonemes: max(20, min(80, parent.phonemes.count / 2)))
        try #require(expectedChildren.count > 1)
        #expect(expectedChildren.first?.displayText == "Jacqui met the verified result.")
        let engine = MockTTSEngine(secondsPerChar: 0.1)
        engine.silentOnText = parent.g2pInputText
        let service = makeService(db, tts: engine, writer: MockAudioWriter())

        let receipt = try await service.renderSegmentFile(
            chapterIndex: 0,
            chapterDisplayNumber: 1,
            segmentIndex: 0,
            blocks: blocks,
            voice: VoiceID("am_michael"))

        let acceptedChildren = Array(engine.plannedCalls.dropFirst().map(\.chunk))
        #expect(acceptedChildren == expectedChildren)
        let verified = try #require(
            receipt.pronunciationDecisions.first { $0.normalizedWord == "verified" })
        let verifiedChild = try #require(
            acceptedChildren.first {
                $0.pronunciationTokenEvidence.contains {
                    $0.text.lowercased() == "verified"
                }
            })
        let verifiedToken = try #require(
            verifiedChild.pronunciationTokenEvidence.first {
                $0.text.lowercased() == "verified"
            })
        #expect(verified.selectedIPA == verifiedToken.selectedPhonemes)
        #expect(verifiedChild.phonemes.contains(verified.selectedIPA))
        #expect(
            Array(verifiedChild.phonemeIDs.dropFirst().dropLast())
                .containsContiguous(verified.kokoroTokenIDs))
        #expect(
            acceptedChildren.flatMap(\.pronunciationFallbackHits)
                == parent.pronunciationFallbackHits)
    }

    @Test func qualityRetryPreservesFrozenDerivedCandidateProvenanceByteForByte() async throws {
        let db = try DatabaseService(inMemory: ())
        let text =
            "The process is startable. Alpha beta gamma delta epsilon zeta eta theta iota kappa lambda mu."
        let blocks = try seed(db, [text])
        let pack = EnglishPronunciationPack.emptyForTesting(
            packVersion:
                "sha256:0000000000000000000000000000000000000000000000000000000000000000",
            kokoroVocabularyVersion:
                "sha256:1111111111111111111111111111111111111111111111111111111111111111")
        let service = NarrationService(
            db: db.writer,
            audiobookID: "b1",
            tts: MockTTSEngine(secondsPerChar: 0.1),
            audioWriter: MockAudioWriter(),
            cacheDirectory: FileManager.default.temporaryDirectory,
            state: NarrationState(),
            pronunciationPack: pack,
            fmEnabled: { false })
        let plan = try await service.renderPlan(
            for: blocks,
            overrides: PronunciationOverrides(entries: [:]),
            occurrenceOverrides: .empty,
            fmEnabled: false)
        let parent = try #require(plan.blocks.first?.synthesisChunks.first)
        let expected = try #require(
            plan.blocks.first?.pronunciationDecisions.first {
                $0.normalizedWord == "startable"
            })
        let children = parent.frozenRetrySlices(
            maxPhonemes: max(20, min(80, parent.phonemes.count / 2)))
        try #require(children.count > 1)
        let engine = try #require(service.tts as? MockTTSEngine)
        engine.silentOnText = parent.g2pInputText

        let rendered = try await service.renderSegmentFile(
            chapterIndex: 0,
            chapterDisplayNumber: 1,
            segmentIndex: 0,
            blocks: blocks,
            voice: VoiceID("am_michael"))
        let actual = try #require(
            rendered.pronunciationDecisions.first {
                $0.normalizedWord == "startable"
            })

        #expect(engine.plannedCalls.count > 1)
        #expect(actual.selectedIPA == expected.selectedIPA)
        #expect(actual.candidateID == expected.candidateID)
        #expect(actual.candidatePackVersion == expected.candidatePackVersion)
        #expect(actual.derivationBase == expected.derivationBase)
        #expect(actual.derivationRuleID == expected.derivationRuleID)
        #expect(actual.candidateID?.hasPrefix("morphology.startable.") == true)
        #expect(actual.derivationBase == "start")
        #expect(actual.derivationRuleID == "morphology.able.exact-base.v1")
    }

    @Test func laterRejectedRetryChildRollsBackEarlierAcceptedSiblingsAtomically() async throws {
        let db = try DatabaseService(inMemory: ())
        let text =
            "Jacqui discusses alpha beta gamma delta epsilon zeta eta theta iota kappa lambda mu. startable"
        let blocks = try seed(db, [text])
        let parentPlan = try #require(
            NarrationRenderPlanner.make(
                blocks: blocks,
                overrides: PronunciationOverrides(entries: [:])
            ).blocks.first?.synthesisChunks.first)
        let retryMaxPhonemes = max(20, min(80, parentPlan.phonemes.count / 2))
        let retryPlans = parentPlan.frozenRetrySlices(maxPhonemes: retryMaxPhonemes)
        try #require(retryPlans.count > 1)
        let laterPlan = try #require(retryPlans.last)
        try #require(laterPlan.displayText.contains("startable"))
        try #require(
            parentPlan.pronunciationFallbackHits.contains {
                $0.word.lowercased() == "jacqui"
            })
        try #require(
            laterPlan.pronunciationFallbackHits.contains {
                $0.word.lowercased() == "startable"
            })

        let secondsPerChar = 0.1
        let engine = MockTTSEngine(secondsPerChar: secondsPerChar)
        var rejectedTexts: Set<String> = [parentPlan.g2pInputText]
        func addRejectedDescendants(_ plan: PlannedSynthesisChunk, depth: Int) {
            rejectedTexts.insert(plan.g2pInputText)
            guard depth < NarrationService.maximumQualityRetryDepth else { return }
            let children = plan.frozenRetrySlices(
                maxPhonemes: max(20, min(80, plan.phonemes.count / 2)))
            for child in children {
                addRejectedDescendants(child, depth: depth + 1)
            }
        }
        addRejectedDescendants(laterPlan, depth: 1)
        engine.silentTexts = rejectedTexts
        let writer = MockAudioWriter()
        let service = makeService(db, tts: engine, writer: writer)

        let rendered = try await service.renderSegmentFile(
            chapterIndex: 0,
            chapterDisplayNumber: 1,
            segmentIndex: 0,
            blocks: blocks,
            voice: VoiceID("am_michael"))

        let expectedDuration = Double(parentPlan.g2pInputText.count) * secondsPerChar
        #expect(rendered.anchors.count == 1)
        let anchor = try #require(rendered.anchors.first)
        let childTexts = engine.plannedCalls.dropFirst().map(\.chunk.g2pInputText)
        let rejectedChildIndex = try #require(childTexts.firstIndex(of: laterPlan.g2pInputText))
        #expect(rejectedChildIndex > 0)
        #expect(writer.chunkCounts == [1])
        #expect(abs(rendered.duration - expectedDuration) < 0.0001)
        #expect(abs(anchor.audioTime) < 0.0001)
        #expect(abs((anchor.audioEndTime ?? -1) - expectedDuration) < 0.0001)
        #expect(
            rendered.pronunciationFallbackHits.map(\.fallback)
                == parentPlan.pronunciationFallbackHits)
    }

    @Test(arguments: SkippableRetryChildError.allCases)
    func laterSkippableRetryChildKeepsOriginalParentAtomically(
        _ childError: SkippableRetryChildError
    ) async throws {
        let db = try DatabaseService(inMemory: ())
        let text =
            "Jacqui discusses alpha beta gamma delta epsilon zeta eta theta iota kappa lambda mu. startable"
        let blocks = try seed(db, [text])
        let parentPlan = try #require(
            NarrationRenderPlanner.make(
                blocks: blocks,
                overrides: PronunciationOverrides(entries: [:])
            ).blocks.first?.synthesisChunks.first)
        let retryMaxPhonemes = max(20, min(80, parentPlan.phonemes.count / 2))
        let retryPlans = parentPlan.frozenRetrySlices(maxPhonemes: retryMaxPhonemes)
        try #require(retryPlans.count > 1)
        let laterPlan = try #require(retryPlans.last)
        try #require(parentPlan.pronunciationFallbackHits.isEmpty == false)

        let secondsPerChar = 0.1
        let engine = MockTTSEngine(secondsPerChar: secondsPerChar)
        engine.silentOnText = parentPlan.g2pInputText
        childError.configure(engine, on: laterPlan.g2pInputText)
        let writer = MockAudioWriter()
        let service = makeService(db, tts: engine, writer: writer)

        let rendered = try await service.renderSegmentFile(
            chapterIndex: 0,
            chapterDisplayNumber: 1,
            segmentIndex: 0,
            blocks: blocks,
            voice: VoiceID("am_michael"))

        let expectedDuration = Double(parentPlan.g2pInputText.count) * secondsPerChar
        let childTexts = engine.plannedCalls.dropFirst().map(\.chunk.g2pInputText)
        let failedChildIndex = try #require(childTexts.firstIndex(of: laterPlan.g2pInputText))
        #expect(failedChildIndex > 0)
        #expect(writer.chunkCounts == [1])
        #expect(abs(rendered.duration - expectedDuration) < 0.0001)
        #expect(rendered.anchors.count == 1)
        let anchor = try #require(rendered.anchors.first)
        #expect(abs(anchor.audioTime) < 0.0001)
        #expect(abs((anchor.audioEndTime ?? -1) - expectedDuration) < 0.0001)

        let speechRanges = try #require(rendered.speechRangesByBlock["blk0"])
        #expect(
            speechRanges
                == [
                    NarrationSpeechRange(
                        blockID: "blk0",
                        text: parentPlan.displayText,
                        start: 0,
                        end: expectedDuration)
                ])
        #expect(rendered.synthesisWordTimingsByBlock.isEmpty)
        #expect(
            rendered.pronunciationFallbackHits.map(\.fallback)
                == parentPlan.pronunciationFallbackHits)
        #expect(
            rendered.pronunciationFallbackHits.allSatisfy {
                $0.blockID == "blk0" && abs($0.audioStartTime) < 0.0001
                    && abs($0.audioEndTime - expectedDuration) < 0.0001
            })
    }

    @Test func exhaustedLowQualityRetryFallsBackToOriginalChunk() async throws {
        let db = try DatabaseService(inMemory: ())
        let text = "alpha beta gamma delta epsilon zeta eta theta iota kappa lambda mu."
        let blocks = try seed(db, [text])
        let firstSegment = try NarrationRenderPlanner.make(
            blocks: blocks,
            overrides: PronunciationOverrides(entries: [:])
        ).blocks[0].synthesisChunks[0].g2pInputText

        let mock = MockTTSEngine(secondsPerChar: 0.1)
        mock.returnsSilenceForAllText = true
        let writer = MockAudioWriter()
        let svc = makeService(db, tts: mock, writer: writer)

        try await svc.renderChapter(chapterIndex: 0, blocks: blocks, voice: VoiceID("af_heart"))

        let anchors = try db.read { db in
            try AlignmentAnchorRecord.filter(Column("audiobook_id") == "b1").fetchAll(db)
        }
        let span = (anchors[0].audioEndTime ?? 0) - anchors[0].audioTime
        #expect(abs(span - Double(firstSegment.count) * 0.1) < 0.0001)
        #expect(writer.chunkCounts == [2])
        #expect((2...4).contains(mock.plannedCalls.count))
    }

    /// Companion to `exhaustedLowQualityRetryFallsBackToOriginalChunk`, which
    /// terminates at a shallow depth via the split-count guard. This drives the
    /// recursion all the way to the bounded depth cap (`maximumQualityRetryDepth`) —
    /// a branch that test never reaches — and asserts the ORIGINAL chunk is
    /// preserved (no source text dropped).
    ///
    /// The input is engineered so every fragment on the first retry path splits
    /// into ≥2 units at depths 0…2, so the recursion is guaranteed to descend to
    /// the depth where the cap fires. Under the current phoneme-split budget the
    /// split-count guard happens to bottom out at that SAME depth, so the black-box
    /// output (planned calls, anchors, writer) is identical whichever guard returns
    /// first. The DEBUG `debugRetryDepthCapHits` counter is what proves the
    /// depth-cap branch is the one that fired — independent of the split-count
    /// backstop, which is the whole point of this test.
    @Test(.timeLimit(.minutes(1)))
    func qualityRetryStopsAtRecursionDepthCapPreservingOriginalChunk() async throws {
        let db = try DatabaseService(inMemory: ())
        // One top-level synthesis chunk (short enough to stay a single chunk) whose
        // phoneme budget is large enough to keep splitting into ≥2 pieces through
        // the full depth cap.
        let text =
            "alpha beta gamma delta epsilon zeta eta theta iota kappa lambda mu "
            + "nu xi omicron pi rho sigma tau upsilon phi chi psi omega and eleven "
            + "zebras gallop swiftly."
        let blocks = try seed(db, [text])

        // Reconstruct the deterministic retry-split tree the service walks, so we
        // can prove the first path splits at depths 0…2 (guaranteeing it descends
        // to the depth cap) and predict the exact synthesized fragments.
        let topChunks = try NarrationRenderPlanner.make(
            blocks: blocks,
            overrides: PronunciationOverrides(entries: [:])
        ).blocks[0].synthesisChunks
        try #require(topChunks.count == 1)  // one quality-retry recursion, not many
        let level0 = topChunks[0]

        func firstSplitPlan(_ plan: PlannedSynthesisChunk) throws -> PlannedSynthesisChunk? {
            let fragments = plan.frozenRetrySlices(
                maxPhonemes: max(20, min(80, plan.phonemes.count / 2)))
            // >1 proves this level splits, so the split-count guard does NOT fire
            // here — the recursion must descend to the next depth.
            try #require(fragments.count > 1)
            return fragments.first
        }
        let level1 = try #require(try firstSplitPlan(level0))
        let level2 = try #require(try firstSplitPlan(level1))
        let level3 = try #require(try firstSplitPlan(level2))

        let mock = MockTTSEngine(secondsPerChar: 0.1)
        mock.returnsSilenceForAllText = true  // every chunk is rejected → always retries
        let writer = MockAudioWriter()
        let svc = makeService(db, tts: mock, writer: writer)

        try await svc.renderChapter(chapterIndex: 0, blocks: blocks, voice: VoiceID("af_heart"))

        // Each recovery level short-circuits on its first still-rejected child, so
        // the recursion synthesizes exactly the original plus one first-fragment per
        // level until `retryDepth` hits the cap — i.e. cap + 1 planned synth calls.
        #expect(
            mock.plannedCalls.map(\.chunk.g2pInputText) == [
                level0.g2pInputText,
                level1.g2pInputText,
                level2.g2pInputText,
                level3.g2pInputText,
            ])
        #expect(mock.plannedCalls.count == NarrationService.maximumQualityRetryDepth + 1)

        // The distinguishing assertion: the depth-cap guard branch actually fired.
        // Black-box output above is identical whether the cap or the split-count
        // guard returns first (they bottom out at the same depth), so a 0 here would
        // mean the recursion terminated on the split-count backstop instead — i.e.
        // the cap is dead. This is what pins the depth-cap branch independently.
        #expect(svc.debugRetryDepthCapHits >= 1)

        // Original chunk preserved: one anchor spanning the WHOLE original
        // duration, and the writer received the kept original chunk + lead-out
        // silence (never a truncated fragment).
        let anchors = try db.read { db in
            try AlignmentAnchorRecord.filter(Column("audiobook_id") == "b1").fetchAll(db)
        }
        #expect(anchors.count == 1)
        let span = (anchors[0].audioEndTime ?? 0) - anchors[0].audioTime
        #expect(abs(span - Double(level0.g2pInputText.count) * 0.1) < 0.0001)
        #expect(writer.chunkCounts == [2])
    }

    @Test func rerenderingAChapterIsIdempotentAndUpdatesVoice() async throws {
        let db = try DatabaseService(inMemory: ())
        let blocks = try seed(db, ["abcd", "ef"])
        let svc = makeService(
            db, tts: MockTTSEngine(secondsPerChar: 0.1), writer: MockAudioWriter())

        try await svc.renderChapter(chapterIndex: 0, blocks: blocks, voice: VoiceID("af_heart"))
        // Re-render the same chapter with a different voice — must upsert in place,
        // not throw on the duplicate anchor primary key or create duplicate rows.
        try await svc.renderChapter(chapterIndex: 0, blocks: blocks, voice: VoiceID("bf_emma"))

        let anchorCount = try db.read { db in
            try AlignmentAnchorRecord.filter(Column("audiobook_id") == "b1").fetchCount(db)
        }
        let trackCount = try db.read { db in try TrackRecord.fetchCount(db) }
        let voiceCol = try db.read { db in
            try String.fetchOne(
                db, sql: "SELECT narration_voice FROM track WHERE audiobook_id = 'b1'")
        }
        #expect(anchorCount == 2)  // 2, not 4 — upserted
        #expect(trackCount == 1)  // 1, not 2
        #expect(voiceCol == "bf_emma")  // re-render updated the voice
    }

    // MARK: - Pronunciation overrides (Part B / B3)

    private static let kubeNeedle = "[Kubernetes](/kuːbərˈnɛtɪs/)"

    /// The injected override must reach the engine wrapped in Misaki link syntax —
    /// not the bare word — so G2P pronounces it from the user's IPA.
    @Test func pronunciationOverrideReachesEngineAsLinkSyntax() async throws {
        let db = try DatabaseService(inMemory: ())
        let blocks = try seed(db, ["Deploying Kubernetes to production now."])
        let mock = MockTTSEngine(secondsPerChar: 0.1)
        let svc = makeService(db, tts: mock, writer: MockAudioWriter()) {
            PronunciationOverrides(entries: ["Kubernetes": "kuːbərˈnɛtɪs"])
        }

        try await svc.renderChapter(chapterIndex: 0, blocks: blocks, voice: VoiceID("af_heart"))

        // The engine saw the rewritten link, never the un-wrapped word.
        #expect(linkOccurrences(mock.calls, Self.kubeNeedle) == 1)
        #expect(!mock.calls.contains { $0.text.contains("Deploying Kubernetes to") })
    }

    /// A long multi-sentence block fans out through the sentence-merge chunk path.
    /// Every occurrence of the override word must reach the engine as an intact
    /// link — none bisected by a sub-chunk boundary.
    @Test func overrideLinkSurvivesSentenceMergeChunking() async throws {
        let db = try DatabaseService(inMemory: ())
        let long = (1...6).map {
            "Sentence number \($0) talks about deploying Kubernetes carefully."
        }.joined(separator: " ")
        let blocks = try seed(db, [long])
        // Guard: the block really does fan out into multiple sub-chunks.
        #expect(NarrationTextChunker.split(TextNormalizer.normalize(long)).count > 1)

        let mock = MockTTSEngine(secondsPerChar: 0.1)
        let svc = makeService(db, tts: mock, writer: MockAudioWriter()) {
            PronunciationOverrides(entries: ["Kubernetes": "kuːbərˈnɛtɪs"])
        }

        try await svc.renderChapter(chapterIndex: 0, blocks: blocks, voice: VoiceID("af_heart"))

        // All six occurrences arrive intact; no half-formed link survives.
        #expect(linkOccurrences(mock.calls, Self.kubeNeedle) == 6)
        #expect(
            !mock.calls.contains {
                $0.text.contains("[Kubernetes]") && !$0.text.contains(Self.kubeNeedle)
            })
    }

    /// One terminator-free run longer than `maxChars` forces the chunker into the
    /// word-wrap (space-splitting) fallback — the path most likely to bisect a
    /// token. The link has no internal space, so it must stay atomic.
    @Test func overrideLinkSurvivesWordWrapFallback() async throws {
        let db = try DatabaseService(inMemory: ())
        let filler = Array(repeating: "padding", count: 40).joined(separator: " ")
        let long = "\(filler) Kubernetes \(filler)"  // >200 chars, no sentence break
        let blocks = try seed(db, [long])

        let mock = MockTTSEngine(secondsPerChar: 0.1)
        let svc = makeService(db, tts: mock, writer: MockAudioWriter()) {
            PronunciationOverrides(entries: ["Kubernetes": "kuːbərˈnɛtɪs"])
        }

        try await svc.renderChapter(chapterIndex: 0, blocks: blocks, voice: VoiceID("af_heart"))

        #expect(linkOccurrences(mock.calls, Self.kubeNeedle) == 1)
        #expect(
            !mock.calls.contains {
                $0.text.contains("[Kubernetes]") && !$0.text.contains(Self.kubeNeedle)
            })
    }

    /// The default (no-override) closure must leave text untouched, so existing
    /// callers and the macOS/iOS default paths are unaffected by the feature.
    @Test func defaultEmptyOverridesLeaveTextUnchanged() async throws {
        let db = try DatabaseService(inMemory: ())
        let blocks = try seed(db, ["Plain text here."])
        let mock = MockTTSEngine(secondsPerChar: 0.1)
        let svc = makeService(db, tts: mock, writer: MockAudioWriter())  // default overrides

        try await svc.renderChapter(chapterIndex: 0, blocks: blocks, voice: VoiceID("af_heart"))

        #expect(mock.calls.map(\.text) == ["Plain text here."])
    }

    @Test func occurrenceOverrideReachesOnlyMatchingBlockAsLinkSyntax() async throws {
        let db = try DatabaseService(inMemory: ())
        let blocks = try seed(db, ["The content stays here.", "The content changes here."])
        let mock = MockTTSEngine(secondsPerChar: 0.1)
        let svc = makeService(
            db,
            tts: mock,
            writer: MockAudioWriter(),
            overrides: { PronunciationOverrides(entries: ["content": "kəntˈɛnt"]) },
            occurrenceOverrides: {
                PronunciationOccurrenceOverrides(entries: [
                    PronunciationOccurrenceOverride(
                        blockID: "blk1",
                        wordStart: 1,
                        wordEnd: 1,
                        word: "content",
                        ipa: "kˈɑntɛnt")
                ])
            })

        try await svc.renderChapter(chapterIndex: 0, blocks: blocks, voice: VoiceID("af_heart"))

        #expect(linkOccurrences(mock.calls, "[content](/kˈɑntɛnt/)") == 1)
        #expect(linkOccurrences(mock.calls, "[content](/kəntˈɛnt/)") == 1)
    }

    @Test func renderChapterRecordsDedupedFallbackPronunciationSuggestion() async throws {
        let db = try DatabaseService(inMemory: ())
        let blocks = try seed(db, ["Jacqui met Jacqui.", "Jacqui returned."])
        let fallback = PronunciationFallbackHit(word: "Jacqui", ipa: "ʤˈækɪ")
        let mock = MockTTSEngine(secondsPerChar: 0.1)
        mock.pronunciationFallbackHitsByText = [
            "Jacqui met Jacqui.": [fallback, fallback],
            "Jacqui returned.": [fallback],
        ]
        let svc = makeService(db, tts: mock, writer: MockAudioWriter())

        try await svc.renderChapter(chapterIndex: 0, blocks: blocks, voice: VoiceID("af_heart"))
        try await svc.renderChapter(chapterIndex: 0, blocks: blocks, voice: VoiceID("af_heart"))

        let issueDAO = NarrationQualityIssueDAO(db: db.writer)
        let issues = try issueDAO.issues(
            for: "b1",
            status: NarrationQAIssueStatus.open.rawValue)
        // Same-block fallback hits collapse, while separate render units keep
        // distinct durable rows in the preflight lane.
        #expect(issues.count == 2)
        #expect(Set(issues.map(\.sourceBlockID)) == ["blk0", "blk1"])
        #expect(Set(issues.map(\.id)).count == 2)
        #expect(
            issues.allSatisfy {
                $0.origin == NarrationQualityIssueOrigin.pronunciationPreflight.rawValue
            })
        let issue = try #require(issues.first)
        #expect(issue.issueType == NarrationQAIssueType.pronunciation.rawValue)
        #expect(issue.sourceBlockID == "blk0")
        #expect(issue.expectedText == "Jacqui")
        #expect(issue.origin == NarrationQualityIssueOrigin.pronunciationPreflight.rawValue)
        let fixData = try #require(issue.suggestedFixJSON?.data(using: .utf8))
        let fix = try JSONDecoder().decode(SuggestedFix.self, from: fixData)
        #expect(fix == SuggestedFix(spokenForm: "Jacqui", ipa: "ʤˈækɪ"))

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let store = PronunciationOverrideStore(directory: tmp)
        var renderedChapters: [Int] = []
        var qaChapters: [Int] = []
        let repair = PronunciationRepairService(
            store: store,
            issueDAO: issueDAO,
            db: db.writer,
            cacheDirectory: tmp,
            voice: VoiceID("af_heart"),
            renderChapter: { renderedChapters.append($0) },
            reRunQA: { qaChapters.append($0) })

        try await repair.applyFix(issue: issue, scope: .book("b1"))

        #expect(store.overrides(forBookID: "b1").entries["Jacqui"] == "ʤˈækɪ")
        #expect(renderedChapters == [0])
        #expect(qaChapters == [0])
        let remaining = try issueDAO.issues(for: "b1", status: NarrationQAIssueStatus.open.rawValue)
        #expect(remaining.count == 1)
        #expect(!remaining.contains { $0.sourceBlockID == "blk0" })
        #expect(remaining.first?.sourceBlockID == "blk1")
    }

    @Test func advisoryReportWriteFailureDoesNotBlockTheRenderedChapter() async throws {
        enum ReportWriteFailure: Error { case unavailable }

        let db = try DatabaseService(inMemory: ())
        let blocks = try seed(db, ["A rendered chapter survives report persistence failure."])
        let state = NarrationState()
        let service = NarrationService(
            db: db.writer,
            audiobookID: "b1",
            tts: MockTTSEngine(secondsPerChar: 0.1),
            audioWriter: MockAudioWriter(),
            cacheDirectory: FileManager.default.temporaryDirectory,
            state: state,
            advisoryReportWriter: { _, _ in throw ReportWriteFailure.unavailable },
            fmEnabled: { false })

        _ = try await service.renderChapter(
            chapterIndex: 0, blocks: blocks, voice: VoiceID("af_heart"))

        let persistedTrack = try db.read { db in
            try TrackRecord.filter(Column("audiobook_id") == "b1").fetchOne(db)
        }
        #expect(persistedTrack != nil)
        let event = try #require(state.events.last)
        #expect(event.category == .error)
        #expect(event.severity == .warning)
        #expect(event.message == "Narration diagnostics could not be saved")
        #expect(event.descriptor.developerMessage == "advisory report write failed")
        #expect(event.descriptor.privateDetail?.isEmpty == false)
        #expect(
            event.descriptor.developerMessage.contains(event.descriptor.privateDetail ?? "")
                == false)
    }

    @Test func cancellationDuringPersistenceDoesNotRecordWarningIntoReplacementSession()
        async throws
    {
        enum FallbackFailure: Error { case unavailable }

        let db = try DatabaseService(inMemory: ())
        let blocks = try seed(db, ["A cancelled render must not diagnose its replacement."])
        let writeGate = NarrationPersistenceWriteGate()
        try db.write { database in
            database.add(
                function: DatabaseFunction(
                    "task8_pause_narration_persist", argumentCount: 0, pure: false
                ) { _ in
                    writeGate.signalEnteredAndWaitForRelease()
                    return 0
                })
            try database.execute(
                sql: """
                    CREATE TEMP TRIGGER task8_pause_narration_persist
                    BEFORE INSERT ON track
                    BEGIN
                        SELECT task8_pause_narration_persist();
                    END
                    """)
        }

        let state = NarrationState()
        state.beginSession(defaultVoiceID: VoiceID("af_heart"))
        let service = NarrationService(
            db: db.writer,
            audiobookID: "b1",
            tts: MockTTSEngine(secondsPerChar: 0.1),
            audioWriter: MockAudioWriter(),
            cacheDirectory: FileManager.default.temporaryDirectory,
            state: state,
            fallbackDiscoveryRecordBuilder: { _, _ in throw FallbackFailure.unavailable },
            fmEnabled: { false })

        let renderTask = Task {
            try await service.renderChapter(
                chapterIndex: 0, blocks: blocks, voice: VoiceID("af_heart"))
        }
        await writeGate.waitUntilEntered()

        renderTask.cancel()
        state.beginSession(defaultVoiceID: VoiceID("bf_emma"))
        writeGate.release()

        await #expect(throws: CancellationError.self) {
            try await renderTask.value
        }
        let persistedTrackCount = try db.read { database in
            try TrackRecord.fetchCount(database)
        }
        #expect(persistedTrackCount == 0)
        #expect(state.snapshot.defaultVoiceID == VoiceID("bf_emma"))
        #expect(
            state.events.map(\.descriptor.developerMessage) == ["narration requested"])
    }

    @Test func fallbackDiscoveryFailureDoesNotBlockTheRenderedChapter() async throws {
        enum FallbackFailure: Error { case unavailable }
        let db = try DatabaseService(inMemory: ())
        let blocks = try seed(db, ["A rendered chapter survives fallback persistence failure."])
        let issueDAO = NarrationQualityIssueDAO(db: db.writer)
        let oldPreflight = NarrationQualityIssueRecord(
            id: "old-preflight", audiobookID: "b1", sourceBlockID: "blk0",
            sourceWordStart: nil, sourceWordEnd: nil,
            audioStartTime: 0, audioEndTime: 1,
            expectedText: "legacy", heardText: "G2P fallback",
            issueType: NarrationQAIssueType.pronunciation.rawValue,
            confidence: 0.25, suggestedFixJSON: nil,
            origin: NarrationQualityIssueOrigin.pronunciationPreflight.rawValue,
            evidenceJSON: nil, status: NarrationQAIssueStatus.open.rawValue,
            createdAt: "old", resolvedAt: nil)
        let oldAcoustic = NarrationQualityIssueRecord(
            id: "old-acoustic", audiobookID: "b1", sourceBlockID: "blk0",
            sourceWordStart: nil, sourceWordEnd: nil,
            audioStartTime: 0, audioEndTime: 1,
            expectedText: "legacy", heardText: "qualityRejected",
            issueType: NarrationQAIssueType.pronunciation.rawValue,
            confidence: 0, suggestedFixJSON: nil,
            origin: NarrationQualityIssueOrigin.acoustic.rawValue,
            evidenceJSON: nil, status: NarrationQAIssueStatus.open.rawValue,
            createdAt: "old", resolvedAt: nil)
        try issueDAO.insert([oldPreflight, oldAcoustic])
        let state = NarrationState()
        let service = NarrationService(
            db: db.writer, audiobookID: "b1", tts: MockTTSEngine(secondsPerChar: 0.1),
            audioWriter: MockAudioWriter(), cacheDirectory: FileManager.default.temporaryDirectory,
            state: state,
            fallbackDiscoveryRecordBuilder: { _, _ in throw FallbackFailure.unavailable },
            fmEnabled: { false })
        _ = try await service.renderChapter(
            chapterIndex: 0, blocks: blocks, voice: VoiceID("af_heart"))
        let track = try db.read { database in
            try TrackRecord.filter(Column("audiobook_id") == "b1").fetchOne(database)
        }
        #expect(track != nil)
        let event = try #require(state.events.last)
        #expect(event.category == .error)
        #expect(event.severity == .warning)
        #expect(event.message == "Narration diagnostics could not be saved")
        #expect(event.descriptor.developerMessage == "pronunciation fallback discovery failed")
        #expect(event.descriptor.privateDetail?.isEmpty == false)
        #expect(
            event.descriptor.developerMessage.contains(event.descriptor.privateDetail ?? "")
                == false)
        #expect(
            Set(try issueDAO.issues(for: "b1").map(\.id)) == [
                oldPreflight.id, oldAcoustic.id,
            ])
    }

    @Test func fallbackSnapshotInsertFailureRollsBackEveryReportLane() async throws {
        let db = try DatabaseService(inMemory: ())
        let blocks = try seed(db, ["A rendered chapter survives atomic report rollback."])
        try await db.writer.write { database in
            try database.execute(
                sql: "INSERT INTO audiobook (id, title, duration) VALUES (?, ?, ?)",
                arguments: ["b2", "Other", 1.0])
        }
        let issueDAO = NarrationQualityIssueDAO(db: db.writer)
        func record(
            id: String,
            book: String,
            origin: NarrationQualityIssueOrigin
        ) -> NarrationQualityIssueRecord {
            NarrationQualityIssueRecord(
                id: id, audiobookID: book, sourceBlockID: "blk0",
                sourceWordStart: nil, sourceWordEnd: nil,
                audioStartTime: 0, audioEndTime: 1,
                expectedText: "legacy", heardText: "report",
                issueType: NarrationQAIssueType.pronunciation.rawValue,
                confidence: 0.25, suggestedFixJSON: nil,
                origin: origin.rawValue, evidenceJSON: nil,
                status: NarrationQAIssueStatus.open.rawValue,
                createdAt: "old", resolvedAt: nil)
        }
        let oldPreflight = record(
            id: "old-preflight", book: "b1", origin: .pronunciationPreflight)
        let oldAcoustic = record(id: "old-acoustic", book: "b1", origin: .acoustic)
        let conflictingExisting = record(id: "conflict", book: "b2", origin: .asr)
        try issueDAO.insert([oldPreflight, oldAcoustic, conflictingExisting])
        let conflictingFallback = record(
            id: conflictingExisting.id,
            book: "b1",
            origin: .pronunciationPreflight)
        let state = NarrationState()
        let service = NarrationService(
            db: db.writer, audiobookID: "b1", tts: MockTTSEngine(secondsPerChar: 0.1),
            audioWriter: MockAudioWriter(), cacheDirectory: FileManager.default.temporaryDirectory,
            state: state,
            fallbackDiscoveryRecordBuilder: { _, _ in [conflictingFallback] },
            fmEnabled: { false })

        _ = try await service.renderChapter(
            chapterIndex: 0, blocks: blocks, voice: VoiceID("af_heart"))

        #expect(
            Set(try issueDAO.issues(for: "b1").map(\.id)) == [
                oldPreflight.id, oldAcoustic.id,
            ])
        #expect(try issueDAO.issues(for: "b2").map(\.id) == [conflictingExisting.id])
        let event = try #require(state.events.last)
        #expect(event.category == .error)
        #expect(event.severity == .warning)
        #expect(event.message == "Narration diagnostics could not be saved")
        #expect(event.descriptor.developerMessage == "advisory report write failed")
        #expect(event.descriptor.privateDetail?.isEmpty == false)
        let track = try db.read { database in
            try TrackRecord.filter(Column("audiobook_id") == "b1").fetchOne(database)
        }
        #expect(track != nil)
    }

    @Test func renderedFileKeepsAuditedBlocksWhenNoBlockProducedAudio() {
        let rendered = NarrationService.RenderedNarrationFile(
            chapterIndex: 0,
            chapterDisplayNumber: 1,
            segmentIndex: nil,
            fileURL: URL(fileURLWithPath: "/tmp/empty.m4a"),
            duration: 0,
            anchors: [],
            spokenBlockIDs: [],
            auditedBlockIDs: ["invalid-g2p"],
            synthesisWordTimingsByBlock: [:])

        #expect(rendered.spokenBlockIDs.isEmpty)
        #expect(rendered.auditedBlockIDs == ["invalid-g2p"])
    }
}

extension Array where Element: Equatable {
    fileprivate func containsContiguous(_ candidate: [Element]) -> Bool {
        guard !candidate.isEmpty, candidate.count <= count else { return false }
        return indices.dropLast(candidate.count - 1).contains { start in
            Array(self[start..<(start + candidate.count)]) == candidate
        }
    }
}

private nonisolated final class NarrationPersistenceWriteGate: @unchecked Sendable {
    private let entered = DispatchSemaphore(value: 0)
    private let releaseWriter = DispatchSemaphore(value: 0)

    func signalEnteredAndWaitForRelease() {
        entered.signal()
        releaseWriter.wait()
    }

    func waitUntilEntered() async {
        await Task.detached {
            self.blockingWaitUntilEntered()
        }.value
    }

    func release() {
        releaseWriter.signal()
    }

    private func blockingWaitUntilEntered() {
        entered.wait()
    }
}

private func partialCacheFileName(for finalName: String) -> String {
    let finalURL = URL(fileURLWithPath: finalName)
    let baseName = finalURL.deletingPathExtension().lastPathComponent
    let pathExtension = finalURL.pathExtension
    return pathExtension.isEmpty ? ".\(baseName).partial" : ".\(baseName).partial.\(pathExtension)"
}

private final class TouchingAudioWriter: AudioFileWriting, @unchecked Sendable {
    private(set) var openedURLs: [URL] = []

    func write(_ chunks: [TTSChunk], to url: URL) async throws -> TimeInterval {
        let stream = try makeStream(to: url, sampleRate: chunks.first?.sampleRate ?? 24_000)
        for chunk in chunks {
            try await stream.append(chunk)
        }
        return try await stream.finalize()
    }

    func makeStream(to url: URL, sampleRate: Double) throws -> any AudioFileStream {
        openedURLs.append(url)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        _ = FileManager.default.createFile(atPath: url.path, contents: Data("partial".utf8))
        return TouchingAudioStream()
    }
}

private final class TouchingAudioStream: AudioFileStream, @unchecked Sendable {
    func append(_ chunk: TTSChunk) async throws {}

    func finalize() async throws -> TimeInterval {
        0
    }
}
