// SPDX-License-Identifier: GPL-3.0-or-later
#if os(iOS) || os(macOS)
    import Foundation
    import OnnxRuntimeBindings  // SPM module of the "onnxruntime" product
    import os.log

    /// Kokoro narration via **ONNX Runtime (CPU)** — the default on-device engine
    /// (it replaced the fixed-shape CoreML pipeline).
    ///
    /// Why this exists: the CoreML path AOT-compiles its model graphs on-device on
    /// first run (~20 min on an A14 — the LSTM duration predictor is O(n²) to
    /// compile). ONNX Runtime *interprets* the graph: ~1 s session-load, no
    /// Espresso compile. ORT's CoreML EP can't run Kokoro's dynamic shapes, so this
    /// runs on the **CPU EP by construction** — which also means it never touches
    /// the ANE, so it can't hit the A14 BNNS vocoder trap either.
    ///
    /// Planned synthesis consumes the exact BOS/EOS-wrapped phoneme ids already
    /// approved upstream and asks `KokoroVoicePack` only for its 256-dim style row.
    /// The legacy string overload builds one plan before delegating. The single ONNX
    /// graph (`model_fp16.onnx`, 163 MB) contains duration, F0/N, decoder-pre, hn-NSF,
    /// and the generator internally.
    ///
    /// Model I/O contract (verified against onnx-community/Kokoro-82M-v1.0-ONNX):
    ///   inputs : input_ids INT64 [1, n] · style FLOAT [1, 256] · speed FLOAT [1]
    ///   output : waveform  FLOAT [1, num_samples]  (24 kHz mono)
    ///
    /// Logs session-load time and per-synthesis RTF (used to clear the A14 gate on
    /// device: ~0.7 s load, RTF ≈ 0.5). Compiles on iOS + macOS — both link ORT and
    /// run the CPU EP; no UIKit/AppKit dependency.
    actor OnnxKokoroEngine: TTSEngine {
        private let logger = Logger(category: "OnnxKokoro")
        private var env: ORTEnv?
        private var session: ORTSession?
        /// Optional second session: the extracted duration head (encoder +
        /// duration predictor). Loaded best-effort from the app bundle in
        /// `prepare()`; when nil, synthesis emits no word timings and callers fall
        /// back to interpolation. Same inputs as the waveform model.
        private var durationSession: ORTSession?
        private var initializationTask: Task<Void, Error>?
        private var progressFanOut: ProgressFanOut?
        private var didLogFirstSynthesis = false
        /// Run options shared by every session.run: asks ORT to shrink the CPU
        /// memory arena back after each run, so the arena no longer ratchets up to
        /// the largest chunk's activation peak for the session's lifetime (§7.1).
        private var runOptions: ORTRunOptions?
        /// Bumped by `unload()`. A `prepare()` in flight captures the generation
        /// current at its start and only commits its freshly created sessions if
        /// that generation is still current — otherwise an `unload()` racing the
        /// in-flight `modelProvider`/session-create work would be silently undone
        /// by the stale task's completion writing `session`/`env` back in.
        private var lifecycleGeneration = 0

        /// Actor-confined Kokoro compatibility front end and per-voice style cache.
        /// Planned synthesis only asks it for a style row; its legacy G2P/vocab path
        /// remains available to compatibility callers. See `KokoroFrontEnd`.
        private let frontEnd = KokoroFrontEnd()

        /// Resolves the local model URL (downloading once if absent). Injected so a
        /// test can exercise the failure path of `prepare()` without a network or
        /// the 163 MB model; defaults to the real `ensureModel`.
        private let modelProvider:
            @Sendable (@Sendable (NarrationPrepareProgress) -> Void) async throws -> URL

        /// Intra-op thread count for the CPU EP. The A14 has 2 performance cores;
        /// pinning intra-op parallelism to them is the throughput lever measured on
        /// device. Injectable so the on-device spike can compare 1/2/4.
        private let intraOpThreads: Int32
        private let generateWordTimings: Bool

        /// Test seam: surface the configured thread count without exposing internals.
        var intraOpThreadsForTesting: Int32 { intraOpThreads }

        init(intraOpThreads: Int32 = 2, generateWordTimings: Bool = true) {
            self.modelProvider = { progress in try await Self.ensureModel(progress: progress) }
            self.intraOpThreads = intraOpThreads
            self.generateWordTimings = generateWordTimings
        }

        /// Test seam: inject a custom model provider (e.g. one that throws) to drive
        /// the no-cache-on-failure retry path.
        init(
            modelProvider:
                @escaping @Sendable (
                    @Sendable (NarrationPrepareProgress) -> Void
                ) async throws -> URL,
            intraOpThreads: Int32 = 2,
            generateWordTimings: Bool = true
        ) {
            self.modelProvider = modelProvider
            self.intraOpThreads = intraOpThreads
            self.generateWordTimings = generateWordTimings
        }

        // MARK: - Model location

        /// ONNX model-asset subdir under the shared narration cache, parallel to
        /// the legacy CoreML `kokoro-fixed-v5` set. The suffix is historical: the
        /// audio cache render version can advance independently of the model file.
        private nonisolated static let modelSubdir = "Models/kokoro-onnx-v6"
        private nonisolated static let modelFileName = "model_fp16.onnx"
        /// Immutable commit pin for onnx-community/Kokoro-82M-v1.0-ONNX. Pinning a
        /// revision (not the moving `main` ref) means a future upstream re-upload can't
        /// silently change the pinned ONNX narration model. Validated at pin time:
        /// 163_234_740 B · sha256 ba4527a8…35c334a (onnx/model_fp16.onnx).
        ///
        /// GOVERNED TRIPWIRE — two-file blast radius: the versioned renderer installer
        /// parses this exact `modelRevision` declaration line and the
        /// `expectedModelBytes` line below (Scripts/echo_renderer/model_policy.py), and
        /// Scripts/echo_renderer/tests/test_model_policy.py pins both current values
        /// against this file. Bumping either value (or reformatting either declaration)
        /// must update that test suite in the same change.
        private nonisolated static let modelRevision = "1939ad2a8e416c0acfeecc08a694d14ef25f2231"
        private nonisolated static let hfModelURL = URL(
            string:
                "https://huggingface.co/onnx-community/Kokoro-82M-v1.0-ONNX/resolve/\(modelRevision)/onnx/model_fp16.onnx"
        )!

        nonisolated static func modelDirectory() -> URL {
            NarrationCache.directory().appendingPathComponent(modelSubdir, isDirectory: true)
        }
        nonisolated static func modelURL() -> URL {
            modelDirectory().appendingPathComponent(modelFileName)
        }

        /// Exact LFS byte length of `model_fp16.onnx` at the pinned revision. A pinned,
        /// content-addressed download is either exactly this size or corrupt/truncated,
        /// so an exact-size match is a cheap, sufficient integrity check.
        nonisolated static let expectedModelBytes = 163_234_740

        /// Bundled duration-head resource name and its sole output tensor.
        private nonisolated static let durationHeadResource = "kokoro_dur_head"
        private nonisolated static let durationOutputName =
            "/encoder/predictor/ReduceSum_output_0"

        /// Test seam: the immutable remote model URL, so a unit test can assert it is
        /// pinned to a commit revision rather than the moving `main` branch ref.
        nonisolated static var remoteModelURLForTesting: URL { hfModelURL }

        /// True iff a file exists at `url` whose byte length is exactly `expectedBytes`.
        /// A pinned, content-addressed download is either exactly this size or corrupt/
        /// truncated, so an exact-size match is a cheap, sufficient integrity check that
        /// also self-heals an interrupted prior download (wrong size ⇒ re-fetch). Cheap:
        /// a single stat, no hashing.
        nonisolated static func fileHasExpectedSize(at url: URL, expectedBytes: Int) -> Bool {
            guard
                let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
                let size = values.fileSize
            else { return false }
            return size == expectedBytes
        }

        // MARK: - TTSEngine

        func prepare() async throws { try await prepare(progress: { _ in }) }

        func prepare(progress: @escaping @Sendable (NarrationPrepareProgress) -> Void) async throws
        {
            if session != nil {
                progress(.ready)
                return
            }
            if let task = initializationTask {
                progressFanOut?.add(progress)
                try await task.value
                return
            }
            let fan = ProgressFanOut()
            fan.add(progress)
            progressFanOut = fan
            let generation = lifecycleGeneration
            let task = Task<Void, Error> {
                [logger, modelProvider, intraOpThreads, generation, generateWordTimings] in
                defer { fan.clear() }
                let modelURL = try await modelProvider { fan.emit($0) }
                // A concurrent unload() during the await above bumped
                // lifecycleGeneration and cancelled this task; bail before doing
                // any more work (including the possibly multi-second session
                // creation below) rather than resurrecting released state.
                try Task.checkCancellation()
                // No Espresso/AOT compile — session-create is the whole cost, and
                // it's seconds. Time it so the A14 spike has the load number.
                let loadStart = Date()
                let env = try ORTEnv(loggingLevel: ORTLoggingLevel.warning)
                let options = try ORTSessionOptions()
                // Tuning (behavior-preserving): op fusion + pin intra-op parallelism to the
                // A14 performance cores. CPU EP only — no ANE (the A14 trap path).
                try options.setGraphOptimizationLevel(.all)
                try options.setIntraOpNumThreads(intraOpThreads)
                fan.emit(.loadingModel)
                let session = try ORTSession(
                    env: env, modelPath: modelURL.path, sessionOptions: options)
                let loadMs = Int(Date().timeIntervalSince(loadStart) * 1000)
                logger.notice(
                    "ONNX session created in \(loadMs, privacy: .public) ms (no AOT compile), intraOp=\(intraOpThreads, privacy: .public)."
                )
                // Best-effort: load the bundled duration head so synthesis can emit
                // exact word timings. Its absence or a load error is non-fatal — it
                // only disables timing (callers fall back to interpolation).
                var durationSession: ORTSession?
                if generateWordTimings,
                    let headURL = NarrationResources.url(
                        forResource: Self.durationHeadResource, withExtension: "onnx")
                {
                    do {
                        let headOptions = try ORTSessionOptions()
                        try headOptions.setGraphOptimizationLevel(.all)
                        try headOptions.setIntraOpNumThreads(intraOpThreads)
                        durationSession = try ORTSession(
                            env: env, modelPath: headURL.path, sessionOptions: headOptions)
                    } catch {
                        logger.warning(
                            "Duration head load failed (word timing disabled): \(error.localizedDescription, privacy: .public)"
                        )
                    }
                } else if generateWordTimings {
                    logger.warning("Duration head resource not bundled (word timing disabled).")
                }
                self.store(
                    env: env, session: session, durationSession: durationSession,
                    ifGeneration: generation)
                fan.emit(.ready)
            }
            initializationTask = task
            do {
                try await task.value
            } catch {
                // §5.11: a failed initialization must not stay cached, or every
                // later prepare() re-awaits the same failure forever (a transient
                // network/disk error would brick narration until app relaunch).
                // Joiners only ever re-await this task — they never replace it — so
                // clearing here cannot drop a newer attempt.
                initializationTask = nil
                throw error
            }
        }

        /// Speeds tried, in order, when a fragment comes back silent — the
        /// prosody-neutral first recovery step. Leads with `1.0` (the real playback
        /// speed → no extra synthesis for the ~90% of chunks that aren't silent); the
        /// ±3% nudges are inaudible but change the duration predictor's output enough
        /// to (hopefully) dodge an input-specific all-zero before the guard resorts to
        /// splitting the text. Tunable; efficacy is a model property, confirmed on
        /// device. See `NarrationSilenceGuard.synthesizeWithSpeedNudge`.
        nonisolated static let silenceRecoverySpeeds: [Float] = [1.0, 1.03, 0.97]

        func synthesize(_ text: String, voice: VoiceID) async throws -> TTSChunk {
            let planned = try PronunciationPlanner().planResolved(text)
            return try await synthesize(planned, voice: voice)
        }

        func synthesize(_ planned: PlannedSynthesisChunk, voice: VoiceID) async throws -> TTSChunk {
            try await prepare()
            guard session != nil else { throw NarrationError.engineUnavailable }
            let inputs = try Self.plannedInputs(
                for: planned, voice: voice, frontEnd: frontEnd)

            // The ONNX model occasionally returns a full-length but all-zero
            // waveform (digital silence) for a non-empty input. Every speed retry
            // reuses the immutable planned ids; text splitting and re-planning belong
            // to NarrationService so approved pronunciation choices stay intact.
            let waveformStart = ContinuousClock.now
            let samples = try await NarrationSilenceGuard.synthesizeWithSpeedNudge(
                speeds: Self.silenceRecoverySpeeds
            ) { speed in
                try await self.runModel(
                    ids32: inputs.waveformIDs, refS: inputs.refS, speed: speed)
            }
            let audioS = Double(samples.count) / 24_000
            let waveformTime = waveformStart.duration(to: .now)
            let timingStart = ContinuousClock.now

            // Word timings from the duration head use the exact same planned ids.
            // The plan's display-text word count, rather than pronunciation markup,
            // drives token-to-word mapping. Soft-fails to nil → interpolation.
            var wordTimings: [ChunkWordTiming]?
            if let (ids, frames) = tokenDurations(
                ids32: inputs.durationIDs, refS: inputs.refS)
            {
                wordTimings = KokoroWordTimer.wordTimings(
                    ids: ids, perTokenFrames: frames, wordCount: inputs.wordCount,
                    wordGroupCounts: inputs.wordGroupCounts,
                    sampleCount: samples.count, sampleRate: 24_000)
            }
            let timingTime = timingStart.duration(to: .now)
            logger.debug(
                "Synthesis stages: waveform=\(String(describing: waveformTime), privacy: .public), wordTiming=\(String(describing: timingTime), privacy: .public), phonemes=\(planned.phonemeIDs.count, privacy: .public)"
            )
            return TTSChunk(
                samples: samples,
                sampleRate: 24_000,
                duration: audioS,
                wordTimings: wordTimings,
                pronunciationFallbackHits: planned.pronunciationFallbackHits)
        }

        /// Pure seam for proving that both production model calls consume the ids
        /// approved by `PronunciationPlanner`. The style lookup is the only front-end
        /// work on this path; it does not initialize or invoke G2P.
        nonisolated static func plannedInputs(
            for planned: PlannedSynthesisChunk,
            voice: VoiceID,
            frontEnd: KokoroFrontEnd
        ) throws -> (
            waveformIDs: [Int32], durationIDs: [Int32], refS: [Float], wordCount: Int,
            wordGroupCounts: [Int]?
        ) {
            let refS = try frontEnd.referenceStyle(
                voice: voice, phonemeCount: planned.phonemes.count)
            return (
                waveformIDs: planned.phonemeIDs,
                durationIDs: planned.phonemeIDs,
                refS: refS,
                wordCount: planned.wordCount,
                wordGroupCounts: planned.authoredWordGroupCounts
            )
        }

        /// One ONNX waveform run for the supplied planned ids and style row at a
        /// given `speed`. Speed retries receive these same values unchanged.
        private func runModel(ids32: [Int32], refS: [Float], speed: Float) async throws -> [Float] {
            guard let session else { throw NarrationError.engineUnavailable }

            // Boundary-only ids ([BOS, EOS]) mean every phoneme was dropped — there
            // is nothing to say. Treat it as empty (a legit zero-length fragment the
            // guard won't retry) rather than feeding it to the model, which would
            // return unrecoverable digital silence.
            guard ids32.contains(where: { $0 != KokoroPhonemeVocab.boundaryTokenId }) else {
                return []
            }

            // Widen ids to Int64 for the ONNX `input_ids` tensor.
            let ids64 = ids32.map { Int64($0) }
            let speedInput: [Float] = [speed]

            let inputIds = try ORTValue(
                tensorData: Self.tensorData(ids64),
                elementType: .int64,
                shape: [NSNumber(value: 1), NSNumber(value: ids64.count)])
            let styleValue = try ORTValue(
                tensorData: Self.tensorData(refS),
                elementType: .float,
                shape: [NSNumber(value: 1), NSNumber(value: refS.count)])
            let speedValue = try ORTValue(
                tensorData: Self.tensorData(speedInput),
                elementType: .float,
                shape: [NSNumber(value: 1)])

            let runStart = Date()
            let outputs = try session.run(
                withInputs: ["input_ids": inputIds, "style": styleValue, "speed": speedValue],
                outputNames: ["waveform"],
                runOptions: runOptions)
            let computeS = Date().timeIntervalSince(runStart)

            guard let waveform = outputs["waveform"] else { throw NarrationError.engineUnavailable }
            // ObjC tensorDataWithError: bridges to throwing tensorData().
            let data = try waveform.tensorData()
            let samples = data.toFloatArray()
            let audioS = Double(samples.count) / 24_000

            // The make-or-break number: RTF (compute/audio; <1 = faster than realtime).
            let rtf = audioS > 0 ? computeS / audioS : 0
            let tag = didLogFirstSynthesis ? "synth" : "FIRST synth (cold)"
            didLogFirstSynthesis = true
            logger.notice(
                "\(tag, privacy: .public): \(ids32.count, privacy: .public) tokens → \(String(format: "%.2f", audioS), privacy: .public)s audio in \(String(format: "%.2f", computeS), privacy: .public)s compute (RTF \(String(format: "%.2f", rtf), privacy: .public))"
            )

            // The model sometimes returns a full-length all-zero waveform; flag it
            // so the guard's retry/re-split is visible and the rate is monitorable.
            if NarrationSilenceGuard.isEffectivelySilent(samples) {
                logger.warning(
                    "Silent (all-zero) waveform for \(ids32.count, privacy: .public) tokens — retrying/splitting."
                )
            }

            return samples
        }

        /// Runs the duration head with the supplied planned ids and style row,
        /// returning those same ids alongside their per-token frame durations.
        /// `nil` when the head isn't loaded or anything fails — always a soft
        /// failure, never throwing into the synthesis path. `speed` is fixed at
        /// 1.0: it only globally scales durations, which per-word normalization to
        /// the real sample count absorbs.
        private func tokenDurations(ids32: [Int32], refS: [Float])
            -> (ids: [Int32], frames: [Float])?
        {
            guard let durationSession else { return nil }
            do {
                guard ids32.contains(where: { $0 != KokoroPhonemeVocab.boundaryTokenId }) else {
                    return nil
                }
                let ids64 = ids32.map { Int64($0) }
                let inputIds = try ORTValue(
                    tensorData: Self.tensorData(ids64), elementType: .int64,
                    shape: [NSNumber(value: 1), NSNumber(value: ids64.count)])
                let styleValue = try ORTValue(
                    tensorData: Self.tensorData(refS), elementType: .float,
                    shape: [NSNumber(value: 1), NSNumber(value: refS.count)])
                let speedValue = try ORTValue(
                    tensorData: Self.tensorData([Float(1.0)]), elementType: .float,
                    shape: [NSNumber(value: 1)])
                let outputs = try durationSession.run(
                    withInputs: ["input_ids": inputIds, "style": styleValue, "speed": speedValue],
                    outputNames: [Self.durationOutputName], runOptions: runOptions)
                guard let durValue = outputs[Self.durationOutputName] else { return nil }
                let frames = try durValue.tensorData().toFloatArray()
                guard frames.count == ids32.count else { return nil }
                return (ids32, frames)
            } catch {
                logger.warning(
                    "Duration head run failed: \(error.localizedDescription, privacy: .public)")
                return nil
            }
        }

        /// Test seam (see `remoteModelURLForTesting` for the pattern): creates a
        /// one-off session for the duration head at `url`, runs it with dummy
        /// in-vocab ids, and returns the decoded per-token frame durations.
        /// Exists so the default test suite can guard the bundled artifact's
        /// output element type — the ORT ObjC binding cannot read fp16
        /// (`tensorData()` throws "unsupported tensor element type…"), which
        /// silently disables synthesis word timing on every platform. Avoids
        /// `prepare()` (no 163 MB model download) and the G2P front end (no
        /// lexicon/voice load), so the probe is cheap enough for `make test`.
        nonisolated static func probeDurationHead(at url: URL) throws -> [Float] {
            let env = try ORTEnv(loggingLevel: ORTLoggingLevel.warning)
            let session = try ORTSession(
                env: env, modelPath: url.path, sessionOptions: ORTSessionOptions())
            // BOS + two arbitrary in-vocab phoneme ids + EOS; the values only
            // need to be valid embedding indices — the probe checks dtype
            // plumbing, not prosody.
            let ids: [Int64] = [0, 50, 60, 0]
            let style = [Float](repeating: 0, count: 256)
            let inputIds = try ORTValue(
                tensorData: tensorData(ids), elementType: .int64,
                shape: [NSNumber(value: 1), NSNumber(value: ids.count)])
            let styleValue = try ORTValue(
                tensorData: tensorData(style), elementType: .float,
                shape: [NSNumber(value: 1), NSNumber(value: style.count)])
            let speedValue = try ORTValue(
                tensorData: tensorData([Float(1.0)]), elementType: .float,
                shape: [NSNumber(value: 1)])
            let outputs = try session.run(
                withInputs: ["input_ids": inputIds, "style": styleValue, "speed": speedValue],
                outputNames: [durationOutputName], runOptions: nil)
            guard let durValue = outputs[durationOutputName] else { return [] }
            return try durValue.tensorData().toFloatArray()
        }

        // MARK: - Private

        /// Commits a freshly created env/session/durationSession — but only if
        /// `ifGeneration` still matches the current `lifecycleGeneration`. A
        /// mismatch means `unload()` ran while this session was being built;
        /// discard it silently (the caller's locals simply deallocate) rather
        /// than resurrecting state `unload()` already released.
        private func store(
            env: ORTEnv, session: ORTSession, durationSession: ORTSession?, ifGeneration: Int
        ) {
            guard lifecycleGeneration == ifGeneration else { return }
            self.env = env
            self.session = session
            self.durationSession = durationSession
            self.runOptions = try? Self.makeRunOptions()
        }

        /// Releases both ONNX sessions, the env, and the arena they own. prepare()
        /// lazily re-creates everything on the next synthesis, so callers may
        /// unload aggressively at render-completion boundaries.
        ///
        /// Declared `async` (though the body never suspends) to exactly match the
        /// `TTSEngine.unload() async` requirement's signature — a sync witness for
        /// an async requirement otherwise loses overload resolution to the
        /// protocol extension's default no-op when called on the concrete type,
        /// silently turning every call here into a no-op.
        ///
        /// Bumps `lifecycleGeneration` so an in-flight `prepare()` — cancelled
        /// below but not guaranteed to observe that cancellation before it
        /// finishes building a session — cannot silently repopulate the state
        /// this just cleared; see `store(env:session:durationSession:ifGeneration:)`.
        func unload() async {
            lifecycleGeneration += 1
            initializationTask?.cancel()
            initializationTask = nil
            session = nil
            durationSession = nil
            env = nil
            runOptions = nil
        }

        /// Test seam: whether the waveform session is currently resident.
        var isPreparedForTesting: Bool {
            session != nil
        }

        var isWordTimingPreparedForTesting: Bool { durationSession != nil }

        /// Builds the shared run options. "cpu:0" names the CPU EP's default
        /// device arena — ORT shrinks it at the end of each Run() carrying this key.
        private nonisolated static func makeRunOptions() throws -> ORTRunOptions {
            let options = try ORTRunOptions()
            try options.addConfigEntry(
                withKey: "memory.enable_memory_arena_shrinkage", value: "cpu:0")
            return options
        }

        /// Copies a numeric array's raw bytes into `NSMutableData` for an ORTValue
        /// tensor — via `withUnsafeBufferPointer` so there's no array-to-pointer
        /// lifetime ambiguity. `NSMutableData(bytes:length:)` copies the bytes.
        private nonisolated static func tensorData<T>(_ array: [T]) -> NSMutableData {
            array.withUnsafeBufferPointer { buf in
                NSMutableData(bytes: buf.baseAddress, length: buf.count * MemoryLayout<T>.stride)
            }
        }

        /// Returns the local model URL, downloading the single `.onnx` once if absent.
        /// An on-disk file (including a USB-sideloaded one) short-circuits the download
        /// only when its byte length matches the pinned model exactly — a truncated,
        /// partial, or stale file is discarded and re-fetched. A fresh download streams
        /// to a temp file with byte-level progress, and is size-validated before its
        /// path is handed to ORT (which would otherwise fail later with an opaque
        /// session-create error).
        private nonisolated static func ensureModel(
            progress: @Sendable (NarrationPrepareProgress) -> Void
        )
            async throws -> URL
        {
            let dest = modelURL()
            let fm = FileManager.default
            progress(.checkingModel(expectedBytes: Int64(expectedModelBytes)))
            if fm.fileExists(atPath: dest.path) {
                if fileHasExpectedSize(at: dest, expectedBytes: expectedModelBytes) {
                    progress(.modelCacheHit(byteCount: Int64(expectedModelBytes)))
                    return dest
                }
                try? fm.removeItem(at: dest)  // corrupt / partial / stale — re-fetch
            }
            try? fm.createDirectory(at: modelDirectory(), withIntermediateDirectories: true)
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForResource = 3_600
            let (byteStream, response) = try await URLSession(configuration: config).bytes(
                from: hfModelURL)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw NarrationError.modelDownloadFailed(name: modelFileName, underlying: nil)
            }

            let tempURL = modelDirectory().appendingPathComponent("\(modelFileName).download")
            do {
                try await writeModelBytes(
                    byteStream, to: tempURL, expectedBytes: expectedModelBytes,
                    progress: progress)
            } catch {
                try? fm.removeItem(at: tempURL)
                throw NarrationError.modelDownloadFailed(name: modelFileName, underlying: error)
            }

            try? fm.removeItem(at: dest)  // clear any stale file before the atomic move
            try fm.moveItem(at: tempURL, to: dest)
            return dest
        }

        /// Streams model bytes to disk without retaining the model in memory. Progress
        /// reports exact byte counts after every 64 KB write and the final partial
        /// write, then reports validation only after the expected size is confirmed.
        nonisolated static func writeModelBytes<S: AsyncSequence>(
            _ byteStream: S,
            to destination: URL,
            expectedBytes: Int,
            progress: @Sendable (NarrationPrepareProgress) -> Void
        ) async throws where S.Element == UInt8 {
            let fm = FileManager.default
            try? fm.removeItem(at: destination)
            fm.createFile(atPath: destination.path, contents: nil)
            let handle = try FileHandle(forWritingTo: destination)
            var received = 0
            var chunk = [UInt8]()
            chunk.reserveCapacity(1 << 16)
            progress(
                .downloadingModel(
                    receivedBytes: 0, totalBytes: Int64(expectedBytes)))
            do {
                for try await byte in byteStream {
                    chunk.append(byte)
                    if chunk.count == (1 << 16) {
                        try handle.write(contentsOf: Data(chunk))
                        received += chunk.count
                        chunk.removeAll(keepingCapacity: true)
                        progress(
                            .downloadingModel(
                                receivedBytes: Int64(received),
                                totalBytes: Int64(expectedBytes)))
                    }
                }
                if !chunk.isEmpty {
                    try handle.write(contentsOf: Data(chunk))
                    received += chunk.count
                    progress(
                        .downloadingModel(
                            receivedBytes: Int64(received),
                            totalBytes: Int64(expectedBytes)))
                }
                try handle.close()
            } catch {
                try? handle.close()
                try? fm.removeItem(at: destination)
                throw error
            }

            guard fileHasExpectedSize(at: destination, expectedBytes: expectedBytes) else {
                try? fm.removeItem(at: destination)
                throw NarrationError.modelDownloadFailed(name: modelFileName, underlying: nil)
            }
            progress(.validatingModel(byteCount: Int64(received)))
        }
    }

    extension NSData {
        /// Reinterprets raw tensor bytes as a Float32 array (the ONNX `waveform`
        /// output is fp32 even though the model's weights are fp16).
        nonisolated fileprivate func toFloatArray() -> [Float] {
            let count = length / MemoryLayout<Float>.stride
            guard count > 0 else { return [] }
            var out = [Float](repeating: 0, count: count)
            // NSData lacks Data's closure `withUnsafeBytes`; copy from its raw
            // `bytes` pointer into the Float buffer directly.
            out.withUnsafeMutableBytes { dst in
                dst.copyMemory(from: UnsafeRawBufferPointer(start: bytes, count: dst.count))
            }
            return out
        }
    }
#endif
