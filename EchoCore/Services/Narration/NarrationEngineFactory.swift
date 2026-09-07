// SPDX-License-Identifier: GPL-3.0-or-later
#if os(iOS) || os(macOS)
    import Foundation

    /// Supplies the concrete on-device `TTSEngine` for real narration synthesis.
    /// Gated to iOS + macOS because `OnnxKokoroEngine` (and ONNX Runtime /
    /// MisakiSwift) only link there, and those are the only targets that compile
    /// `EchoCore` *and* synthesize narration (watchOS and the Widget sync neither
    /// `EchoCore` nor the narration deps). Tests inject `MockTTSEngine` straight
    /// into `NarrationService`, so they bypass this factory entirely.
    enum NarrationEngineFactory {
        /// The on-device synthesis engine for both iOS and macOS:
        /// **`OnnxKokoroEngine`** (ONNX Runtime, CPU) — instant load (no AOT
        /// compile), RTF ≈ 0.5 on A14, and it never touches the ANE so the BNNS
        /// vocoder trap can't occur. (The former FluidAudio + fixed-shape CoreML
        /// engines were removed once this was device-verified.)
        ///
        /// - Parameter intraOpThreads: ONNX intra-op thread count; `nil` uses the
        ///   platform default from `defaultIntraOpThreads(jobs:)`.
        static func make(intraOpThreads: Int32? = nil, generateWordTimings: Bool = true)
            -> TTSEngine
        {
            OnnxKokoroEngine(
                intraOpThreads: intraOpThreads ?? defaultIntraOpThreads(),
                generateWordTimings: generateWordTimings)
        }

        /// Pure thread-count policy, unit-tested without sysctl: divide the
        /// performance cores across `jobs` concurrent engines. Preserve the
        /// single-engine A14 baseline of 2, but allow one thread per parallel
        /// worker rather than oversubscribing cores. Never exceed 4 — Kokoro-82M's
        /// intra-op scaling saturates quickly, and threads beyond ~4 only add
        /// scheduling overhead while starving parallel workers.
        static func resolvedIntraOpThreads(performanceCores: Int, jobs: Int) -> Int32 {
            Int32(min(4, max(jobs > 1 ? 1 : 2, performanceCores / max(jobs, 1))))
        }

        /// Platform default for the CPU EP's intra-op parallelism. iOS keeps the
        /// measured A14 tuning (2 performance cores). macOS resolves from the
        /// machine's actual performance-core count so an M-series Mac no longer
        /// runs inference throttled to an iPhone's core budget.
        static func defaultIntraOpThreads(jobs: Int = 1) -> Int32 {
            #if os(macOS)
                return resolvedIntraOpThreads(
                    performanceCores: performanceCoreCount(), jobs: jobs)
            #else
                return 2
            #endif
        }

        #if os(macOS)
            /// The machine's performance-core count via
            /// `hw.perflevel0.physicalcpu`; falls back to half the active
            /// processors (M-series ship roughly half P-cores) when the sysctl
            /// is unavailable.
            static func performanceCoreCount() -> Int {
                var cores: Int32 = 0
                var size = MemoryLayout<Int32>.size
                if sysctlbyname("hw.perflevel0.physicalcpu", &cores, &size, nil, 0) == 0,
                    cores > 0
                {
                    return Int(cores)
                }
                return max(2, ProcessInfo.processInfo.activeProcessorCount / 2)
            }
        #endif
    }
#endif
