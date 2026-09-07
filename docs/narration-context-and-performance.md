# Narration context and performance

The September 2026 update keeps Kokoro's pinned waveform model and improves the
text preparation and execution around it. Audio cache render version 25
invalidates older speech after the contextual `content` and normalization fixes.

## Production behavior

- Personal subjects select the verb in “We record sales” before compound-noun
  handling can override it.
- Linking verbs with degree/negation modifiers resolve satisfied `content`
  before the quantity-noun rule: “She was more content with her life.”
  Existential auxiliary chains keep the noun: “There will be more content.”
- Ordinary rendering records contextual model evaluation as `notRequested`.
  It no longer waits for a model whose choices are only shadow evidence.
- Optional Foundation Models text normalization only accepts exact token-addressed
  space insertions into identifiers. Every original character must remain in
  order; source mismatches, duplicate addresses, authored pronunciation markup,
  and prose rewrites reject the complete response. Plain prose without candidate
  identifiers does not call the model. Normalization signature is version 2.
- Chapter pronunciation planning runs off the UI actor, with cancellation checks
  between blocks.
- A render-unit cache reuses complete G2P results between split sizing and final
  planning. Keys include input and display text; storage is bounded to 64 entries
  with an 8 KiB combined input/display limit per entry. Long probes are not cached.
- Mac parallel engines may use one intra-op thread each when dividing available
  performance cores. The single-engine floor and iOS default remain two.
- `echo-cli narrate --no-word-timings` skips duration-head loading and inference
  for newly synthesized audio and omits sidecar word timings. Normal playback
  retains the timing model. Resuming existing captures can reuse earlier timing
  data; this flag is not a command to regenerate or erase it.
- ONNX debug logs separate waveform time (including silence retries) from word
  timing time, with phoneme counts and no source text.

## Contextual model qualification

`echo-cli narrate --contextual-pronunciation-audit` explicitly enables shadow
model evaluation. Use a fresh run and a separate work directory; combining this
flag with `--resume` is rejected because completed captures would otherwise skip
inference. The output remains the deterministic narration plus model evidence.

Prompt schema `context-shadow-v2` marks the precise target occurrence, including
when a word appears with two meanings in one sentence. Discovery adds the nearest
sentence across an adjacent visible paragraph, bounded to 600 characters from
the neighbor. It does not cross chapter/spine, hidden-block, or code boundaries.
Occurrence addresses stay local to their original display block. Context is
local-only; no cloud service or new model dependency is introduced.

All contextual families remain shadow. The existing qualification report still
requires human labels and listening verification. This update does not declare
those gates passed or enable unqualified model choices to override speech.
Automatic family promotion should use held-out per-sense cases, track model
regressions as well as corrections, preserve user overrides, and retain abstention
and deterministic fallback on unsupported devices. Fixing target identity must
precede that qualification.

## Reproducible listening and benchmark fixture

Generate the synthetic three-chapter EPUB and its listening checklist without a
model, build, or external service:

```sh
python3 Tools/Pronunciation/narration_benchmark.py --output /tmp/echo-listening
```

The cases cover repeated heteronyms, paragraph context, dialogue, names,
identifiers/negation, and a long sentence for chunk-seam listening. The checklist
contains intended senses and listening focus; it is not a claim of human grading.
Render the EPUB through the normal CLI for review and optionally enable the
contextual audit flag. Keep generated audio and reports outside the repository.

After building a Release CLI through the prescribed Apple build wrapper, compare
worker/thread combinations with fresh capture directories:

```sh
python3 Tools/Pronunciation/narration_benchmark.py \
  --cli .build/cli/Build/Products/Release/echo-cli \
  --output /tmp/echo-benchmark --jobs 1,2 --threads 1,2,4 --runs 3
```

The macOS benchmark uses the existing `ffprobe` executable and records CLI/fixture
hashes, platform, elapsed time, audio duration, end-to-end real-time factor,
exit status, and peak process RSS. It retains trial logs, fails on an unsuccessful
render, and never overwrites an output directory. Compare separate baseline and
candidate CLI binaries; the first trial can include model preparation, so compare
cold-start separately from subsequent warm-model trials. Audio captures are fresh
for every trial. Repeat with `--no-word-timings` to measure its effect.

## Remaining measurements

No throughput percentage or on-device listening improvement is claimed by static
review or unit tests. Measure sustained latency, memory, thermals, and playback
buffering on representative devices. Evaluate pauses/emphasis separately from
phoneme correctness, especially at the existing 420-phoneme chunk budget.

The pinned main graph exposes only waveform output. Eliminating the second
inference while retaining word timing would require exporting and qualifying a
new graph that also exposes its duration tensor. This update skips that second
model only when timing is explicitly disabled; it does not replace the model or
weaken normal read-along timing. Changing the chunk budget also remains a
listening/benchmark decision, not an assumed performance win.
