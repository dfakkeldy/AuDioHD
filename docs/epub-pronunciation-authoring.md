# EPUB pronunciation authoring contract

Echo accepts pronunciation instructions in EPUB XHTML and bundled PLS files.
They change speech, not the spelling in the reader, search index, or alignment
sidecar. This is an English/Kokoro contract (version `epub.*.ipa-v1`), not a claim
of complete SSML, PLS, or multilingual IPA support.

The format follows [EPUB Text-to-Speech Enhancements](https://www.w3.org/TR/epub-tts-10/)
and [PLS 1.0](https://www.w3.org/TR/pronunciation-lexicon/). The restrictions below
are Echo's supported subset. Do not put Misaki Markdown links in EPUB visible
text. Do not replace “Portia” with phonetic spelling.

## Inline occurrence instructions

Use the namespace URI `http://www.w3.org/2001/10/synthesis`, as in the EPUB
examples. Echo also accepts `https://www.w3.org/2001/10/synthesis`, which appears
in the current EPUB TTS attribute tables. The prefix can be `ssml` or another correctly bound prefix. `ssml:alphabet="ipa"`
may be inherited from an ancestor; `ssml:ph` applies only to its own element.

```xml
<?xml version="1.0" encoding="UTF-8"?>
<html xmlns="http://www.w3.org/1999/xhtml"
      xmlns:ssml="http://www.w3.org/2001/10/synthesis"
      xml:lang="en-US" ssml:alphabet="ipa">
  <head><title>Pronunciation Proof</title></head>
  <body>
    <h1>Pronunciation Proof</h1>
    <p><span ssml:ph="ˈpɔɹʃə">Portia</span> smiled.</p>
    <p>They met at <span ssml:ph="ˌnjuː ˈjɔɹk">New York</span>.</p>
    <p>The <span ssml:ph="bæs">bass</span> swam while the
       <span ssml:ph="beɪs">bass</span> played.</p>
  </body>
</html>
```

Keep each annotation within one imported paragraph or heading. Inline formatting
inside it is supported, including `Por<em>ti</em>a`. Use whole words or phrases;
mid-word instructions are not an authoring surface. Avoid wrapping punctuation
outside the spoken phrase. Whitespace and XML character references are collapsed
by the same parser used for display text, so offsets remain attached to the
original occurrence. A phrase is one indivisible pronunciation unit for chunking.

Nested pronunciation instructions, annotations spanning block boundaries, empty
annotations, and instructions on code, images, head content, or captions are
unsupported. Annotated text cannot contain the reserved characters `[]()/`.

## Recurring names through a bundled PLS lexicon

Write `EPUB/names.pls` as UTF-8:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<lexicon xmlns="http://www.w3.org/2005/01/pronunciation-lexicon"
         version="1.0" alphabet="ipa" xml:lang="en-US">
  <lexeme>
    <grapheme>Portia</grapheme>
    <grapheme>PORTIA</grapheme>
    <phoneme>ˈpɔɹʃə</phoneme>
  </lexeme>
  <lexeme>
    <grapheme>New York</grapheme>
    <phoneme>ˌnjuː ˈjɔɹk</phoneme>
  </lexeme>
</lexicon>
```

Declare it in the OPF manifest, alongside the content document:

```xml
<manifest xmlns="http://www.idpf.org/2007/opf">
  <item id="chapter" href="chapter.xhtml" media-type="application/xhtml+xml"/>
  <item id="names" href="names.pls" media-type="application/pls+xml"/>
</manifest>
```

Link it in the **head of every XHTML document that should use it**:

```xml
<link xmlns="http://www.w3.org/1999/xhtml"
      rel="pronunciation" type="application/pls+xml"
      hreflang="en-US" href="names.pls"/>
```

The OPF href is relative to the OPF directory; the XHTML link href is relative to
that XHTML document. Subdirectories and percent-encoded local paths are allowed.
Files must remain inside the EPUB container and be declared with media type
`application/pls+xml`. Remote URLs, absolute paths, query strings, fragments, and
paths or symlinks escaping the container are rejected. Echo does not fetch a
network lexicon. Standard EPUB `mimetype`, `META-INF/container.xml`, OPF metadata,
spine, and navigation requirements still apply; the fixture includes them.

Lexicons apply only to their linked document, not the whole book. Grapheme
matching is **case-sensitive, whole-word, leftmost-longest**. Supply multiple
`grapheme` elements for casing or spelling variants. Apostrophes, letters, digits,
and underscores are word constituents; “Portia” does not match “Portia's”. Spaces
in a phrase match the canonical collapsed spaces in the imported text.

Each lexeme needs one or more graphemes and **exactly one** phoneme. Identical
repeated entries are accepted. Conflicting pronunciations for the same grapheme
within or across linked lexicons reject import; use inline instructions for
ambiguous words. Aliases, roles, `prefer`, per-phoneme alphabets, foreign-namespace
extensions, DTDs, entity declarations, and non-English lexicons are unsupported.
PLS files are limited to 1 MiB, links to 32 per content document, and graphemes to
200 characters. Use `xml:lang="en"` or an `en-…` language tag. `hreflang` documents
the link; the PLS root controls the accepted language.

## Supported IPA

Use standard IPA without surrounding slashes or brackets. Primary and secondary
stress (`ˈ`, `ˌ`), vowel length (`ː`), and spaces between spoken words are supported.
Each instruction must contain speech symbols and at most 300 characters.
Whitespace is normalized to single spaces and Unicode is normalized to NFC.

Directly supported symbols:

```text
a b d e f h i j k l m n o p r s t u v w z
æ ɑ ɒ ɔ ə ɚ ɛ ɜ ɡ ɪ ŋ θ ð ɹ ʃ ʊ ʌ ʒ ʧ ʤ
ˈ ˌ ː
```

Echo explicitly maps these standard sequences to Kokoro's internal representation:

| Authored IPA | Kokoro representation |
| --- | --- |
| `tʃ`, `t͡ʃ`, `t͜ʃ` | `ʧ` |
| `dʒ`, `d͡ʒ`, `d͜ʒ` | `ʤ` |
| `aɪ`, `aʊ`, `eɪ`, `oʊ`, `ɔɪ` | `I`, `W`, `A`, `O`, `Y` respectively |
| ASCII `g` | IPA `ɡ` |
| `ɝ` | `ɜɹ` |
| `ɾ` | `T` (the renderer's flap token) |
| `ʔ` | `t` (the renderer's existing glottal-stop approximation) |

Author the left-hand column, not internal capital-letter shorthand. English
approximations for unsupported foreign names must use this subset. Other
combining marks, syllabification dots, syllabic consonant diacritics, tone marks,
phonetic brackets, and unsupported letters produce an error. Vocabulary support
alone does not establish the acoustic quality of a particular pronunciation.

## Precedence and preservation

1. Explicit user occurrence corrections, then per-book corrections, then global
   user corrections (existing user precedence is preserved).
2. Inline EPUB pronunciation instructions.
3. Linked PLS pronunciations.
4. Built-in defaults, automatic lexicon/context rules, and ordinary G2P fallback.

A user correction overlapping any part of an EPUB phrase suppresses the entire
EPUB phrase instruction; remaining words use normal handling. Inline instructions
similarly suppress overlapping lexicon matches. No automatic contextual model
may overwrite an explicit EPUB instruction.

Import persists pronunciation spans separately from `text` and `narration_text`.
For a block containing an instruction, deterministic text rewriting and optional
Foundation Models text normalization are bypassed for the **whole block**. Thus
abbreviations and identifiers elsewhere in that block retain their source form;
put a pronunciation instruction on them too if their spoken form matters.
Existing automatic pronunciation selection still runs on unannotated words.

Chunk display text and word indices continue to use original words. Phrase
phonemes are emitted once, without adding phonetic words to search or sidecars.
Word timing uses the existing duration/alignment machinery; where a phrase does
not provide a provable per-word boundary, timing must use the existing fallback
rather than claiming precise acoustic boundaries. Listen separately for pacing.

Pronunciation metadata participates in the content signature of each affected
render unit. Changing only IPA changes that unit's cache identity. Removing or
adding annotations also changes identity; unaffected units retain theirs.
Reimport the changed EPUB to update persisted instructions. An older already
exported M4B remains an immutable audio file and must be rendered again.

## Failure behavior and verification

Invalid inline data, invalid PLS, missing or undeclared links, conflicting entries,
and unsupported IPA reject the annotated import with an `EPUB pronunciation:`
error. There is no partial “success” with silently dropped phonemes. Correct the
source and reimport. Existing books without these instructions retain their
normal import behavior.

At render time, stored spans must still match their original words, their phonemes
must encode in the bundled vocabulary, and each EPUB decision must bind to the
actual final phoneme/token-ID slice. A failure stops rendering with an explicit
error; it does not claim that instruction worked. Audio already rendered before
an error is not acceptance of the failed instruction.

The same persisted blocks and render planner serve the app and headless CLI.
The pronunciation audit identifies `epubInline` and `epubLexicon` decisions,
original word spans, selected final IPA, and Kokoro IDs. Inspect those receipts
alongside the actual audio. Automated tests establish data flow and consistency;
human listening acceptance is separate.

## Reusable proof fixture

Expanded source: `Tools/Pronunciation/fixtures/epub-pronunciation/`.
Packaged files: `Tools/Pronunciation/fixtures/pronunciation-annotated.epub` and
`pronunciation-baseline.epub`. Both have identical visible text. The baseline
omits the inline phonemes and pronunciation link.

Regenerate reproducibly:

```sh
python3 Tools/Pronunciation/epub_pronunciation_fixture.py \
  --output /tmp/echo-epub-pronunciation
```

Render both with the same verified CLI, fresh work directories, `am_michael`, and
word timings enabled. Use `echo-cli narrate --help` for the current renderer
arguments. Compare the Portia, New York, and bass decisions in each output's
pronunciation audit. Do not compare against a resumed capture from a different
input. No audiobook skill changes are part of this implementation.

The opt-in `EPUBPronunciationTests/michaelListeningProof` test runs both archived
EPUBs through the headless importer and the real ONNX engine. It records every
successfully synthesized plan in `dispatched-phonemes.json` beside the M4B, sidecar,
and pronunciation audit. This gives complete baseline phonemes even for ordinary
words omitted from the selective pronunciation audit.

After building tests through the repository wrapper, run it with a fresh host
output directory (the simulator receives environment variables prefixed with
`SIMCTL_CHILD_`):

```sh
SIMCTL_CHILD_ECHO_EPUB_LISTENING_OUTPUT=/tmp/echo-epub-michael-proof \
  /Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- \
  make test-only FILTER=EchoTests/EPUBPronunciationTests/michaelListeningProof
```

Use the build wrapper's allowed window or a user-authorized off-hours override;
never bypass its memory checks. Without the environment variable, the acoustic
proof is skipped and ordinary import-to-engine tests use a recording test double.

CI explicitly enables the real-engine proof and uploads `EPUBPronunciationProof`
artifacts (14-day retention), containing only this public fixture. Local unit
tests leave it disabled unless the environment variable is supplied. CI's result
is an acoustic pipeline check, not human listening acceptance.
