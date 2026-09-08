// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB
import Testing

@testable import Echo

@MainActor
struct EPUBPronunciationTests {
    private func fixture() -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Tools/Pronunciation/fixtures/epub-pronunciation")
    }

    @Test func importedInstructionsReachExactSynthesisPhonemes() throws {
        let parsed = try parseEPUBBlocks(audiobookID: "proof", epubURL: fixture())
        let plan = try NarrationRenderPlanner.make(
            blocks: parsed.blocks, overrides: .init(entries: [:]))
        let chunks = plan.blocks.flatMap(\.synthesisChunks)
        #expect(chunks.map(\.displayText) == parsed.blocks.compactMap(\.text))
        let selected = plan.blocks.flatMap(\.pronunciationDecisions)
        #expect(
            selected.filter { $0.sourceWord == "Portia" }.map(\.selectedIPA) == [
                "ˈpɔɹʃə", "ˈpɔɹʃə",
            ])
        #expect(
            selected.filter { $0.sourceWord == "New York" }.map(\.selectedIPA) == ["ˌnjuː ˈjɔɹk"])
        #expect(selected.filter { $0.sourceWord == "bass" }.map(\.selectedIPA) == ["bæs", "bAs"])
        #expect(plan.pronunciationAuditDiagnostics.isEmpty)
    }
    private func copyFixture(body: String? = nil, lexicon: String? = nil) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.copyItem(at: fixture(), to: root)
        if let body {
            let xhtml = """
                <html xmlns="http://www.w3.org/1999/xhtml" xmlns:ssml="http://www.w3.org/2001/10/synthesis" ssml:alphabet="ipa">
                <head><title>Proof</title><link rel="pronunciation" type="application/pls+xml" href="names.pls"/></head>
                <body><h1>Proof</h1>\(body)</body></html>
                """
            try xhtml.write(
                to: root.appendingPathComponent("EPUB/chapter.xhtml"), atomically: true,
                encoding: .utf8)
        }
        if let lexicon {
            try lexicon.write(
                to: root.appendingPathComponent("EPUB/names.pls"), atomically: true, encoding: .utf8
            )
        }
        return root
    }

    @Test func databaseImportAndServicePreserveOriginalWordsWithFMEnabled() async throws {
        let db = try DatabaseService(inMemory: ())
        let root = try copyFixture(
            body: "<p>Dr. <span ssml:ph=\"ˈpɔɹʃə\">Portia</span> read README at 12:30.</p>")
        defer { try? FileManager.default.removeItem(at: root) }
        try db.write {
            try $0.execute(
                sql: "INSERT INTO audiobook (id, title, duration) VALUES ('proof', 'Proof', 0)")
        }
        let importer = EPUBImportService(assetStorage: EPUBAssetStorage(databaseService: db))
        _ = try await importer.import(
            audiobookID: "proof", epubURL: root, chapters: [], bookDuration: nil)
        let blocks = try EPubBlockDAO(db: db.writer).blocks(for: "proof").sorted {
            $0.sequenceIndex < $1.sequenceIndex
        }
        let parsed = try parseEPUBBlocks(audiobookID: "proof", epubURL: root)
        #expect(
            blocks.map(\.pronunciationAnnotations) == parsed.blocks.map(\.pronunciationAnnotations))
        #expect(blocks.map(\.text) == parsed.blocks.map(\.text))
        let service = NarrationService(
            db: db.writer, audiobookID: "proof", tts: MockTTSEngine(),
            audioWriter: MockAudioWriter(), cacheDirectory: root, state: NarrationState())
        let plan = try await service.renderPlan(
            for: blocks, overrides: .init(entries: [:]), occurrenceOverrides: .empty,
            fmEnabled: true)
        #expect(
            plan.blocks.flatMap(\.synthesisChunks).last?.displayText
                == "Dr. Portia read README at 12:30.")
        #expect(plan.pronunciationAuditDiagnostics.isEmpty)
    }

    @Test func inlinePrecedesPLSAndUserCorrectionsPrecedeInline() async throws {
        let root = try copyFixture(
            body: "<p>Portia met <span ssml:ph=\"pɔɹˈtiə\">Portia</span>.</p>")
        defer { try? FileManager.default.removeItem(at: root) }
        let blocks = try parseEPUBBlocks(audiobookID: "proof", epubURL: root).blocks
        let plain = try NarrationRenderPlanner.make(blocks: blocks, overrides: .init(entries: [:]))
        #expect(
            plain.blocks.flatMap(\.pronunciationDecisions).filter { $0.sourceWord == "Portia" }.map(
                \.selectedIPA) == ["ˈpɔɹʃə", "pɔɹˈtiə"])
        let db = try DatabaseService(inMemory: ())
        let service = NarrationService(
            db: db.writer, audiobookID: "proof", tts: MockTTSEngine(),
            audioWriter: MockAudioWriter(), cacheDirectory: root, state: NarrationState())
        let paragraph = try #require(blocks.last)
        let overrides = PronunciationOverrides.merging(
            global: ["Portia": "pɔɹtiə"], book: ["Portia": "pɔɹʃə"])
        let occurrence = PronunciationOccurrenceOverrides(entries: [
            .init(blockID: paragraph.id, wordStart: 2, wordEnd: 2, word: "Portia", ipa: "pɔɹtʃə")
        ])
        let plan = try await service.renderPlan(
            for: blocks, overrides: overrides, occurrenceOverrides: occurrence, fmEnabled: false)
        let decisions = plan.blocks.flatMap(\.pronunciationDecisions).filter {
            $0.sourceWord == "Portia"
        }
        #expect(decisions.map(\.source) == [.bookOverride, .occurrenceOverride])
        #expect(decisions.map(\.selectedIPA) == ["pɔɹʃə", "pɔɹtʃə"])
    }

    @Test func explicitUserGlobalsWinButBuiltInsDoNotBeatEPUB() throws {
        let root = try copyFixture(body: "<p><span ssml:ph=\"kæmˈbɛl\">Campbell</span> smiled.</p>")
        defer { try? FileManager.default.removeItem(at: root) }
        let blocks = try parseEPUBBlocks(audiobookID: "proof", epubURL: root).blocks
        let builtIns = try NarrationRenderPlanner.make(
            blocks: blocks, overrides: .withBuiltInDefaults([:]))
        let authored = try #require(
            builtIns.blocks.flatMap(\.pronunciationDecisions).first { $0.sourceWord == "Campbell" })
        #expect(authored.source == .epubInline)
        #expect(authored.selectedIPA == "kæmˈbɛl")
        let user = try NarrationRenderPlanner.make(
            blocks: blocks, overrides: .withBuiltInDefaults(["Campbell": "kæmbəl"]))
        let corrected = try #require(
            user.blocks.flatMap(\.pronunciationDecisions).first { $0.sourceWord == "Campbell" })
        #expect(corrected.source == .globalOverride)
        #expect(corrected.selectedIPA == "kæmbəl")
    }

    @Test func phrasesRemainAtomicAcrossSmallChunks() throws {
        let blocks = try parseEPUBBlocks(audiobookID: "proof", epubURL: fixture()).blocks
        let plan = try NarrationRenderPlanner.make(
            blocks: blocks, overrides: .init(entries: [:]), maxPhonemes: 14)
        #expect(
            plan.blocks.flatMap(\.synthesisChunks).contains {
                $0.displayText.contains("New York")
                    && $0.g2pInputText.contains("[New York](/ˌnjuː ˈjɔɹk/)")
            })
        #expect(
            plan.blocks.flatMap(\.synthesisChunks).reduce(0) { $0 + $1.wordCount }
                == blocks.compactMap(\.text).reduce(0) { $0 + WordTokenizer.words(in: $1).count })
        #expect(plan.pronunciationAuditDiagnostics.isEmpty)
    }

    @Test func annotationOnlyChangesInvalidateOnlyAffectedContentSignature() throws {
        var blocks = try parseEPUBBlocks(audiobookID: "proof", epubURL: fixture()).blocks
        func signature(_ blocks: [EPubBlockRecord]) -> String {
            NarrationService.contentSignature(
                for: blocks, includeLeadOutPad: true, overrides: .init(entries: [:]),
                occurrenceOverrides: .empty, normalizationMode: "deterministic",
                pronunciationPack: .empty)
        }
        let before = signature(blocks)
        let heading = signature([blocks[0]])
        let index = try #require(blocks.firstIndex { $0.pronunciationAnnotations != nil })
        blocks[index].pronunciationAnnotations = blocks[index].pronunciationAnnotations?
            .replacingOccurrences(of: "ˈpɔɹʃə", with: "pɔɹˈtiə")
        #expect(before != signature(blocks))
        #expect(heading == signature([blocks[0]]))
    }

    @Test(arguments: ["", "ˈpɔɹʃə❓", "/pɔɹʃə/", "pɔɹʃə̃", "bAs", "pɔɹʃə)", "ˈː"])
    func unsupportedIPAIsRejected(ipa: String) {
        #expect(throws: EPUBPronunciationError.self) { try EPUBPronunciationIPA.normalize(ipa) }
    }

    @Test func standardIPAMapsToSupportedVocabulary() throws {
        let normalized = try EPUBPronunciationIPA.normalize("t͡ʃ d͜ʒ aɪ aʊ eɪ oʊ ɔɪ g ɝ ɾ ʔ")
        #expect(normalized == "ʧ ʤ I W A O Y ɡ ɜɹ T t")
        #expect(try KokoroPhonemeVocab().unsupportedCharacters(in: normalized).isEmpty)
    }

    @Test(arguments: [
        "<p><span ssml:ph=\"bæs\"><em ssml:ph=\"beɪs\">bass</em></span></p>",
        "<div ssml:ph=\"bæs\"><p>bass</p><p>bass</p></div>",
        "<p><span ssml:alphabet=\"x-sampa\" ssml:ph=\"bæs\">bass</span></p>",
        "<p><span ssml:ph=\"bæs\"></span></p>",
        "<pre ssml:ph=\"bæs\">bass</pre>",
        "<p><span xmlns:ssml=\"urn:wrong\" ssml:ph=\"bæs\">bass</span></p>",
    ])
    func invalidInlineFailsImport(body: String) throws {
        let root = try copyFixture(body: body)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(throws: EPUBPronunciationError.self) {
            try parseEPUBBlocks(audiobookID: "proof", epubURL: root)
        }
    }

    @Test func aliasNamespaceEntitiesAndWhitespaceKeepOffsets() throws {
        let root = try copyFixture(
            body:
                "<p>  <span xmlns:s=\"http://www.w3.org/2001/10/synthesis\" s:ph=\"ˈpɔɹʃə\">Por<em>ti</em>a</span> &amp; Portia. </p>"
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let blocks = try parseEPUBBlocks(audiobookID: "proof", epubURL: root).blocks
        let plan = try NarrationRenderPlanner.make(blocks: blocks, overrides: .init(entries: [:]))
        #expect(plan.blocks.last?.synthesisChunks.first?.displayText == "Portia & Portia.")
        #expect(
            plan.blocks.last?.pronunciationDecisions.filter { $0.sourceWord == "Portia" }.count == 2
        )
    }

    @Test func httpsSSMLNamespaceIsAlsoAccepted() throws {
        let root = try copyFixture(
            body:
                "<p><span xmlns:s=\"https://www.w3.org/2001/10/synthesis\" s:alphabet=\"ipa\" s:ph=\"bæs\">bass</span></p>"
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let blocks = try parseEPUBBlocks(audiobookID: "proof", epubURL: root).blocks
        let plan = try NarrationRenderPlanner.make(blocks: blocks, overrides: .init(entries: [:]))
        #expect(plan.blocks.last?.pronunciationDecisions.first?.source == .epubInline)
    }

    @Test func remoteUndeclaredAndEscapingLexiconsAreRejected() throws {
        let root = try copyFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("EPUB/chapter.xhtml")
        let original = try String(contentsOf: url, encoding: .utf8)
        for href in [
            "https://example.com/names.pls", "../../names.pls", "missing.pls", "names.pls?x=1",
            "names.pls#fragment",
        ] {
            try original.replacingOccurrences(of: "href=\"names.pls\"", with: "href=\"\(href)\"")
                .write(to: url, atomically: true, encoding: .utf8)
            #expect(throws: EPUBPronunciationError.self) {
                try parseEPUBBlocks(audiobookID: "proof", epubURL: root)
            }
        }
    }

    @Test func malformedFirstAnnotationCannotDisappearSilently() throws {
        let root = try copyFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let xml = """
            <html xmlns="http://www.w3.org/1999/xhtml" xmlns:ssml="http://www.w3.org/2001/10/synthesis" ssml:alphabet="ipa">
            <head><title>Proof</title></head><body><p><span ssml:ph="pɔɹ&bad;">Portia</span></p></body></html>
            """
        for encoding in [String.Encoding.utf8, .utf16LittleEndian, .utf16BigEndian] {
            try xml.data(using: encoding)!.write(
                to: root.appendingPathComponent("EPUB/chapter.xhtml"))
            #expect(throws: EPUBPronunciationError.self) {
                try parseEPUBBlocks(audiobookID: "proof", epubURL: root)
            }
        }
    }

    @Test func inlineDoesNotConsumeAnAdjacentShorterLexiconEntry() throws {
        let pls = """
            <lexicon xmlns="http://www.w3.org/2005/01/pronunciation-lexicon" version="1.0" alphabet="ipa" xml:lang="en-US">
            <lexeme><grapheme>New York</grapheme><phoneme>njuː jɔɹk</phoneme></lexeme>
            <lexeme><grapheme>York</grapheme><phoneme>ˈjɔɹk</phoneme></lexeme></lexicon>
            """
        let root = try copyFixture(
            body: "<p><span ssml:ph=\"ˈnjuː\">New</span> York.</p>", lexicon: pls)
        defer { try? FileManager.default.removeItem(at: root) }
        let blocks = try parseEPUBBlocks(audiobookID: "proof", epubURL: root).blocks
        let plan = try NarrationRenderPlanner.make(blocks: blocks, overrides: .init(entries: [:]))
        #expect(plan.blocks.last?.pronunciationDecisions.map(\.sourceWord) == ["New", "York"])
        #expect(
            plan.blocks.last?.pronunciationDecisions.map(\.source) == [.epubInline, .epubLexicon])
    }

    @Test func ambiguousPLSVariantsAreRejected() throws {
        let pls = """
            <lexicon xmlns="http://www.w3.org/2005/01/pronunciation-lexicon" alphabet="ipa" version="1.0" xml:lang="en-US">
            <lexeme><grapheme>bass</grapheme><phoneme>bæs</phoneme><phoneme>beɪs</phoneme></lexeme></lexicon>
            """
        #expect(throws: EPUBPronunciationError.self) { try EPUBPLSParser.parse(Data(pls.utf8)) }
    }

    private actor PlanRecorder {
        var plans: [PlannedSynthesisChunk] = []
        var voices: [VoiceID] = []
        func record(_ plan: PlannedSynthesisChunk, voice: VoiceID) {
            plans.append(plan)
            voices.append(voice)
        }
    }

    private final class RecordingEngine: TTSEngine {
        let recorder: PlanRecorder
        init(recorder: PlanRecorder) { self.recorder = recorder }
        func prepare() async throws {}
        func synthesize(_ text: String, voice: VoiceID) async throws -> TTSChunk {
            throw EPUBPronunciationError(detail: "Test expected planned synthesis, not raw text.")
        }
        func synthesize(_ plan: PlannedSynthesisChunk, voice: VoiceID) async throws -> TTSChunk {
            await recorder.record(plan, voice: voice)
            return TTSChunk(
                samples: [Float](repeating: 0.1, count: 4800), sampleRate: 24_000, duration: 0.2)
        }
    }

    @Test func headlessImportDispatchesAnnotatedPhonemesToEngineAndExportsOriginalWords()
        async throws
    {
        let root = try copyFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let out = root.appendingPathComponent("proof.m4b")
        let sidecar = root.appendingPathComponent("proof.alignment.json")
        let config = NarrationRunConfig(
            epubURL: root, outM4BURL: out, sidecarURL: sidecar,
            workDir: root.appendingPathComponent("work"), voice: VoiceID("am_michael"),
            title: "Pronunciation Proof", author: "Echo", maxNewChaptersPerRun: nil)
        let recorder = PlanRecorder()
        let result = try await HeadlessNarrationRunner().run(
            config, tts: RecordingEngine(recorder: recorder))
        #expect(result.complete)
        let manifestURL = root.appendingPathComponent("proof.pronunciation-audit.json")
        let manifest = try JSONDecoder().decode(
            PronunciationAuditManifest.self, from: Data(contentsOf: manifestURL))
        #expect(
            manifest.decisions.filter { $0.source == .epubInline || $0.source == .epubLexicon }
                .count == 5)
        let plans = await recorder.plans
        #expect(plans.contains { $0.g2pInputText.contains("[New York](/ˌnjuː ˈjɔɹk/)") })
        #expect(plans.contains { $0.phonemes.contains("bæs") && $0.phonemes.contains("bAs") })
        #expect(plans.allSatisfy { $0.pronunciationEvidenceValidation == .matched })
        let anchors = try AlignmentSidecar.decode(Data(contentsOf: sidecar))
        #expect(!anchors.isEmpty)
        let expected = try parseEPUBBlocks(audiobookID: "proof", epubURL: root).blocks
            .compactMap(\.text).flatMap { WordTokenizer.words(in: $0).map(String.init) }
        #expect(anchors.flatMap { $0.words ?? [] }.map(\.word) == expected)
        let json = try String(contentsOf: sidecar, encoding: .utf8)
        #expect(!json.contains("ssml:ph"))
        #expect(!json.contains("ˈpɔɹʃə"))
    }

    @Test func nonUTF8PLSAndEntityDeclarationsAreRejected() {
        let xml = """
            <!DOCTYPE lexicon [<!ENTITY name "Portia">]>
            <lexicon xmlns="http://www.w3.org/2005/01/pronunciation-lexicon" alphabet="ipa" version="1.0" xml:lang="en-US">
            <lexeme><grapheme>&name;</grapheme><phoneme>ˈpɔɹʃə</phoneme></lexeme></lexicon>
            """
        for encoding in [String.Encoding.utf8, .utf16] {
            #expect(throws: EPUBPronunciationError.self) {
                try EPUBPLSParser.parse(xml.data(using: encoding)!)
            }
        }
    }

    /// Opt-in real ONNX proof; ordinary unit tests use RecordingEngine and never
    /// download a waveform model. The output directory must be fresh.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ECHO_EPUB_LISTENING_OUTPUT"] != nil))
    func michaelListeningProof() async throws {
        let outputPath = try #require(
            ProcessInfo.processInfo.environment["ECHO_EPUB_LISTENING_OUTPUT"])
        let output = URL(fileURLWithPath: outputPath)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        struct Receipt: Codable {
            let voice: String
            let displayText: String
            let g2pInputText: String
            let phonemes: String
            let phonemeIDs: [Int32]
        }
        for name in ["baseline", "annotated"] {
            let recorder = PlanRecorder()
            let destination = output.appendingPathComponent(name)
            #expect(!FileManager.default.fileExists(atPath: destination.path))
            guard !FileManager.default.fileExists(atPath: destination.path) else {
                throw EPUBPronunciationError(detail: "Listening proof output must be fresh.")
            }
            try FileManager.default.createDirectory(
                at: destination, withIntermediateDirectories: true)
            let source = fixture().deletingLastPathComponent().appendingPathComponent(
                "pronunciation-\(name).epub")
            let config = NarrationRunConfig(
                epubURL: source, outM4BURL: destination.appendingPathComponent("\(name).m4b"),
                sidecarURL: destination.appendingPathComponent("\(name).alignment.json"),
                workDir: destination.appendingPathComponent("work"), voice: VoiceID("am_michael"),
                title: "Pronunciation Proof — \(name)", author: "Echo", maxNewChaptersPerRun: nil)
            let result = try await HeadlessNarrationRunner().run(
                config, tts: RecordingRealEngine(recorder: recorder))
            #expect(result.complete)
            let plans = await recorder.plans
            let voices = await recorder.voices
            #expect(voices.allSatisfy { $0 == VoiceID("am_michael") })
            let receipts = zip(plans, voices).map { plan, voice in
                Receipt(
                    voice: voice.rawValue,
                    displayText: plan.displayText, g2pInputText: plan.g2pInputText,
                    phonemes: plan.phonemes, phonemeIDs: plan.phonemeIDs)
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(receipts).write(
                to: destination.appendingPathComponent("dispatched-phonemes.json"))
            #expect(plans.allSatisfy { $0.pronunciationEvidenceValidation == .matched })
        }
    }

    private final class RecordingRealEngine: TTSEngine {
        let recorder: PlanRecorder
        let engine = OnnxKokoroEngine()
        init(recorder: PlanRecorder) { self.recorder = recorder }
        func prepare() async throws { try await engine.prepare() }
        func synthesize(_ text: String, voice: VoiceID) async throws -> TTSChunk {
            throw EPUBPronunciationError(detail: "Listening proof requires planned synthesis.")
        }
        func synthesize(_ plan: PlannedSynthesisChunk, voice: VoiceID) async throws -> TTSChunk {
            let result = try await engine.synthesize(plan, voice: voice)
            await recorder.record(plan, voice: voice)
            return result
        }
        func unload() async { await engine.unload() }
    }

}
