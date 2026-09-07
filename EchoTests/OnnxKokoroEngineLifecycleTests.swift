// SPDX-License-Identifier: GPL-3.0-or-later
#if os(iOS) || os(macOS)
    import Foundation
    import Testing

    @testable import Echo

    struct OnnxKokoroEngineLifecycleTests {
        @Test func waveformOnlyPreparationDoesNotLoadDurationSession() async throws {
            let url = try #require(
                NarrationResources.url(
                    forResource: "kokoro_dur_head", withExtension: "onnx"))
            for enabled in [false, true] {
                let engine = OnnxKokoroEngine(
                    modelProvider: { _ in url }, intraOpThreads: 1, generateWordTimings: enabled)
                try await engine.prepare()
                #expect(await engine.isPreparedForTesting)
                #expect(await engine.isWordTimingPreparedForTesting == enabled)
                await engine.unload()
            }
        }

        /// unload() releases the sessions; a later prepare() re-creates them.
        /// Uses the small bundled duration-head onnx as the "model" via the
        /// modelProvider seam so no 163 MB download is involved.
        @Test func unloadReleasesAndPrepareRestores() async throws {
            let headURL = try #require(
                NarrationResources.url(forResource: "kokoro_dur_head", withExtension: "onnx"))
            let engine = OnnxKokoroEngine(
                modelProvider: { _ in headURL }, intraOpThreads: 1)

            try await engine.prepare()
            #expect(await engine.isPreparedForTesting)

            await engine.unload()
            #expect(await engine.isPreparedForTesting == false)

            try await engine.prepare()
            #expect(await engine.isPreparedForTesting)
        }

        /// unload() racing an in-flight prepare() must not let that prepare()
        /// resurrect the state unload() just cleared. The injected modelProvider
        /// suspends on a signal so the test can deterministically land unload()
        /// while prepare()'s child task is still inside the modelProvider await —
        /// the exact window §7.1's fix (Task.checkCancellation() + a generation
        /// guard on store()) closes.
        @Test func unloadDuringInFlightPrepareDoesNotResurrectState() async throws {
            let headURL = try #require(
                NarrationResources.url(forResource: "kokoro_dur_head", withExtension: "onnx"))

            let (enteredStream, enteredContinuation) = AsyncStream<Void>.makeStream()
            let (releaseStream, releaseContinuation) = AsyncStream<Void>.makeStream()

            let engine = OnnxKokoroEngine(
                modelProvider: { _ in
                    enteredContinuation.yield(())
                    var releaseIterator = releaseStream.makeAsyncIterator()
                    _ = await releaseIterator.next()
                    return headURL
                },
                intraOpThreads: 1)

            let prepareTask = Task { try await engine.prepare() }

            // Wait until prepare()'s child task is inside modelProvider (i.e.
            // suspended on the release signal) before unloading.
            var enteredIterator = enteredStream.makeAsyncIterator()
            _ = await enteredIterator.next()

            await engine.unload()

            // Let the in-flight prepare() proceed now that it's been unloaded out
            // from under it.
            releaseContinuation.yield(())
            releaseContinuation.finish()

            // This implementation's Task.checkCancellation() (inserted right after
            // the modelProvider await returns) deterministically throws here,
            // since unload() already cancelled prepare()'s child task.
            await #expect(throws: CancellationError.self) {
                try await prepareTask.value
            }

            #expect(await engine.isPreparedForTesting == false)

            // A later, unraced prepare() must still succeed.
            try await engine.prepare()
            #expect(await engine.isPreparedForTesting)
        }
    }
#endif
