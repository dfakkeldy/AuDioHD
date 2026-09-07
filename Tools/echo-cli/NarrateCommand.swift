// SPDX-License-Identifier: GPL-3.0-or-later
import ArgumentParser
import Foundation

/// `echo-cli narrate` — turn an EPUB into a chaptered .m4b + read-along sidecar.
struct NarrateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "narrate",
        abstract: "Narrate an EPUB or PDF into a chaptered .m4b + alignment sidecar.",
        discussion: """
            Exit codes: 0 = book complete (m4b + sidecar written); 2 = partial \
            batch (re-run with --resume to continue); 1 = any other failure.

            Performance: build with `make echo-cli` (Release). A plain \
            `xcodebuild build -scheme echo-cli` produces a slower Debug (-Onone) \
            binary. The big lever is --jobs: render chapters in parallel — each \
            worker holds its own engine (several hundred MB), so 2–4 is the \
            practical ceiling on a 16 GB machine.
            """)

    @Option(
        help: "EPUB/PDF source file or directory; EPUB folder/entry wins when both are present.")
    var epub: String
    @Option(help: "Output .m4b path.") var out: String
    @Option(help: "Sidecar .alignment.json path (optional).") var sidecar: String?
    @Option(help: "Kokoro voice id. Defaults to af_heart unless --voice-plan supplies the default.")
    var voice: String?
    @Option(name: .customLong("voice-plan"), help: "Source-bound block voice-plan JSON file.")
    var voicePlan: String?
    @Option(
        name: .customLong("chapter-voice"),
        help:
            "Override one 1-based narrated chapter, as N=voice_id. Repeat for additional chapters.")
    var chapterVoice: [String] = []
    @Option(help: "Book title (m4b metadata).") var title: String
    @Option(help: "Book author (m4b metadata).") var author: String
    @Option(help: "Square artwork image to embed instead of the EPUB/PDF cover.")
    var cover: String?
    @Option(name: .customLong("work-dir"), help: "Intermediates dir (default: next to --out).")
    var workDir: String?
    @Option(name: .customLong("max-chapters"), help: "Chapters per process (default: whole book).")
    var maxChapters: Int?
    @Option(name: .customLong("db"), help: "Persistent SQLite database path (default: in-memory).")
    var db: String?
    @Option(help: "Concurrent chapter renders (default 1; 2-4 recommended on 16 GB).")
    var jobs: Int = 1
    @Option(help: "ONNX intra-op threads per engine (default: auto for this machine and --jobs).")
    var threads: Int?
    @Flag(help: "Continue from existing .anchors markers.") var resume = false
    @Flag(
        name: .customLong("no-word-timings"),
        help: "Skip duration-model inference and write block-level sidecar anchors only.")
    var noWordTimings = false
    @Flag(
        name: .customLong("no-pronunciation-review"),
        help: "Do not write the pronunciation audit JSON or listening reel.")
    var noPronunciationReview = false
    @Flag(
        name: .customLong("contextual-pronunciation-audit"),
        help:
            "Evaluate contextual pronunciation choices for qualification (slower; does not change audio)."
    )
    var contextualPronunciationAudit = false

    func validate() throws {
        guard jobs > 0, threads.map({ $0 > 0 && $0 <= Int(Int32.max) }) ?? true else {
            throw ValidationError(
                "--jobs and --threads must be positive; threads must fit a 32-bit integer.")
        }
        guard !(resume && contextualPronunciationAudit) else {
            throw ValidationError(
                "--contextual-pronunciation-audit requires a fresh run; omit --resume and use a new --work-dir to preserve previous audio."
            )
        }
    }

    @MainActor func run() async throws {
        EchoCLI.configureResources()
        let outURL = URL(fileURLWithPath: out)
        let coverArtData = try cover.map {
            try NarrationCoverOverride.load(from: URL(fileURLWithPath: $0))
        }
        let chapterVoiceAssignments = try ChapterVoiceAssignments(arguments: chapterVoice)
        let work =
            workDir.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? outURL.deletingLastPathComponent()
            .appendingPathComponent("work-\(outURL.deletingPathExtension().lastPathComponent)")

        let config = NarrationRunConfig(
            epubURL: URL(fileURLWithPath: epub),
            outM4BURL: outURL,
            sidecarURL: sidecar.map { URL(fileURLWithPath: $0) },
            workDir: work,
            voice: voice.map { VoiceID(rawValue: $0) },
            voicePlanURL: voicePlan.map { URL(fileURLWithPath: $0) },
            chapterVoicesByDisplayNumber: chapterVoiceAssignments.byDisplayNumber,
            title: title,
            author: author,
            coverArtData: coverArtData,
            maxNewChaptersPerRun: maxChapters,
            databaseURL: db.map { URL(fileURLWithPath: $0) },
            enableContextualPronunciationAudit: contextualPronunciationAudit,
            includeWordTimings: !noWordTimings,
            jobs: max(1, jobs),
            intraOpThreads: threads.map(Int32.init),
            generatePronunciationReview: !noPronunciationReview,
            clearExistingCapturesBeforeRun: !resume)

        // Overnight renders must survive the Mac idling: without this, the
        // system can sleep mid-book and the wall clock silently balloons.
        let activity = ProcessInfo.processInfo.beginActivity(
            options: [.idleSystemSleepDisabled, .userInitiated],
            reason: "echo-cli narrate render")
        defer { ProcessInfo.processInfo.endActivity(activity) }

        let start = Date()
        var lastMessage = ""
        // `progress:` is labeled explicitly — an unlabeled trailing closure
        // would forward-scan-match the runner's `ttsFactory:` parameter.
        let result = try await HeadlessNarrationRunner().run(
            config,
            progress: { progress in
                // Dedupe on the timestamp-free message so unchanged fractions
                // don't spam the log, while real advances keep their elapsed stamp.
                let message = NarrationRunProgressFormatter.message(for: progress)
                guard message != lastMessage else { return }
                lastMessage = message
                let elapsed = Date().timeIntervalSince(start)
                let stamp = NarrationRunProgressFormatter.timestamp(elapsed)
                FileHandle.standardError.write(Data("[\(stamp)] \(message)\n".utf8))
            })

        let wall = Date().timeIntervalSince(start)
        if result.complete {
            let summary = NarrationRunProgressFormatter.summary(
                audioSeconds: result.durationSeconds, wallSeconds: wall)
            print(
                "DONE \(result.outM4BURL.path) — \(result.chapters) chapters, \(summary)")
            switch result.pronunciationReview {
            case .generated(let auditURL, let reelURL):
                print(
                    "Pronunciation review: \(auditURL.path) and \(reelURL.path)")
            case .auditOnly(let auditURL):
                print("Pronunciation review: \(auditURL.path); no reel was needed.")
            case .disabled:
                print("Pronunciation review generation was disabled by --no-pronunciation-review.")
            case .pending:
                break
            }
        } else {
            print(
                "PARTIAL - \(result.capturedThisRun) captured this run out of \(result.chapters) total chapters in \(Int(wall.rounded()))s; re-run with --resume to continue"
            )
            throw ExitCode(2)
        }
    }
}
