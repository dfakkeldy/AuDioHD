# 🗣️ Echo: Audiobook Study Player

> For Every Mind — turn listening into learning

[![Build Status](https://img.shields.io/badge/build-passing-brightgreen.svg)](#)
[![TestFlight](https://img.shields.io/badge/TestFlight-Beta-blue.svg)](#)
[![Platform](https://img.shields.io/badge/iOS-18+-blue.svg)](#)
[![Platform](https://img.shields.io/badge/macOS-15+-blue.svg)](#)
[![Platform](https://img.shields.io/badge/watchOS-11+-blue.svg)](#)
[![License](https://img.shields.io/badge/License-GPLv3-blue.svg)](LICENSE)

**Echo** turns audiobooks into a serious study medium. It aligns the audiobook you already own to its EPUB/PDF for word-level read-along, **narrates ebooks that have no audiobook** on-device, and turns what you hear into flashcards you review with spaced repetition — all without leaving the audio.

Plenty of apps now read your ebook aloud, or sync an audiobook to the text. Echo is the one that turns that into a study *system* — and it still works when you own the ebook but not an audiobook (it narrates that for you too).

---

## Documentation & Website

Echo's **marketing home** is **[KinNoKi Labs](https://kinnokilabs.com/apps/echo)**. App Store marketing, privacy, and support URLs have pointed there since 2026-06-10 (`kinnokilabs.com/apps/echo`, `/echo-privacy`, `/echo-help`).

The public **GitHub Pages** documentation site remains live at [dfakkeldy.github.io/Echo](https://dfakkeldy.github.io/Echo/). It hosts the open glossary, guides, manual, and devlog for the open-source audience. It is the docs site, not the marketing home.

| Resource | What it covers |
|---|---|
| 🌐 [Marketing home — KinNoKi Labs](https://kinnokilabs.com/apps/echo) | Product story for App Store visitors |
| 📖 [Docs site (GitHub Pages)](https://dfakkeldy.github.io/Echo/) | Public documentation: glossary, guides, manual, devlog |
| 📚 [Glossary](https://dfakkeldy.github.io/Echo/glossary.html) | Plain-language definitions for every term below — hover any dotted-underlined word on the site |
| 🧠 [Getting the Most Out of Echo](https://dfakkeldy.github.io/Echo/learn.html) ([md](docs/guides/getting-the-most-out-of-echo.md)) | Every feature + the memory science behind it (context-dependent memory, spaced repetition, the testing effect, cognitive offloading…) |
| ♾️ [The Focus Field Guide](https://dfakkeldy.github.io/Echo/focus.html) ([md](docs/guides/focus-field-guide.md)) | ADHD/AuDHD strategies — task initiation, time blindness, organization, motivation, hyperfocus, distractibility — with sources |
| 📖 [User Manual](https://dfakkeldy.github.io/Echo/manual.html) ([md](docs/guides/user-manual.md)) | Complete reference: every feature on every platform, incl. library organization |
| 🛠 [Devlog](https://dfakkeldy.github.io/Echo/devlog.html) ([md](docs/guides/devlog.md)) | Week-by-week build history from the real commit log |
| 🔤 [EPUB pronunciation authoring](docs/epub-pronunciation-authoring.md) | How EPUB authors ship SSML IPA spans and PLS lexicons so Echo narrates names without respelling reader text (English/Kokoro subset) |
| 🏗 [ARCHITECTURE.md](ARCHITECTURE.md) · [ROADMAP.md](ROADMAP.md) · [CHANGELOG.md](CHANGELOG.md) | For contributors |

> **Status tags used below:** 🚧 = **Coming in 1.0** (in active development) · 🔭 = **Roadmap** (planned after 1.0). Everything unmarked ships in the current beta.

---

## Why I Built Echo

I spend my days delivering mail. I'm in and out of my car dozens of times a shift, relying on an aux cable and dealing with constant interruptions. I listen to non-fiction to learn, but trying to absorb complex information with intermittent attention using standard audiobook apps was an exercise in frustration.

I needed an app that could loop a single chapter until I understood it. I needed to leave voice memos on bookmarks so I wouldn't forget my thoughts while driving. I needed a watch complication large enough to actually hit without looking down. And when I finally got home, I needed the audio to align perfectly with the ePub so I could look at the diagrams I had just heard about.

I couldn't find an app that did any of this persistently. So, I built it myself.

Echo is the result of a massive, months-long AuDHD spin. It brings together Spaced Repetition (SRS), smart rewind, pitch-corrected speed playback, and a library system that actually makes sense. It was designed from the ground up to support neurodivergent learning styles, but it turns out that building an app for an ADHD brain creates a powerful, friction-free tool for **every** mind.

Echo bridges the gap between reading and listening: a synced EPUB or PDF sits alongside your audiobook so you can follow the text while you hear it, jump between the two, and never lose your place. If you've ever struggled to stay focused on audio alone — or found that reading is your anchor — this hybrid approach is for you. Built for students, professionals, commuters, and anyone who learns differently.

---

## The Study Workflow

Echo is built around a simple idea: **audiobooks should be as searchable and referenceable as textbooks.** Here's how that works:

```
Add audiobook + EPUB/PDF   →   Echo aligns text to audio
          ↓
Search for any phrase   →   Jump instantly to that moment in the narration
          ↓
Lock paragraphs to timestamps   →   Build a precise, verified map of the book
          ↓
Capture while you listen   →   Bookmarks, voice memos, marks, brain-dump notes
          ↓
Review with spaced repetition   →   Retain what you learned, on your schedule
          ↓
See honest insights & export your second brain   →   Own what you learned
```

### Auto Study Plans

For EPUB-backed books, Echo can create a Study Plan from Book Settings. A plan generates one listening-assignment card per included chapter, can include image cards for EPUB pictures, and releases new chapter work on a daily or weekly cadence. After the first grade, the existing FSRS review scheduler controls future due dates.

### Features Built for Focus

- **Intermittent Attention Support.** Smart rewind ensures you never lose context when you hit play after a pause. The longer you've been away, the further it rewinds — perfect for delivery drivers, commuters, and anyone with an interrupted day.
- **Local Library Shelf.** Point Echo at folders of audiobooks and it builds a browsable shelf without copying your files. The Library tab groups by recent additions, author, topic, folder, study status, and processing status; missing books can be hidden, relocated, or removed; and the Mac app gets the same shelf in its sidebar.
- **Chapter Looping.** Put a single chapter on repeat until the concepts are fully absorbed. Loop between bookmarks for targeted review sessions.
- **Voice Memo Bookmarks.** Instantly save your thoughts without fumbling with your phone. Perfect for driving, walking, or when your hands are full. Memos can play back inline when the narration reaches them.
- **Sessions history.** Review when and where you listened — GPS route and distance, minutes, the chapters you covered, and the bookmarks, cards, and notes you made — then tap any session to jump back into that exact slice of the book.
- **Photo Bookmarks.** Attach a photo (from camera or library) to any bookmark; the player artwork dynamically switches to your photo as playback passes that moment. Built on *context-dependent memory* — your brain encodes where you were alongside what you heard, and the photo becomes a retrieval cue. [The science →](https://dfakkeldy.github.io/Echo/learn.html)
- **Spaced Repetition (SRS).** Built-in flashcard system using the **FSRS** algorithm (the modern free-spaced-repetition scheduler) to help you memorize crucial facts, languages, or concepts permanently — with audio snippets on cards, Anki-style deck import, review stats, daily reminders, and resilient hands-free review on Apple Watch.
- **Mark Now, Card Later.** One tap (phone or watch) marks a passage without pausing playback; the **Card Inbox** turns marks into flashcards when you have the bandwidth. Retires mid-playback popups for good.
- **Decks, Tags & Real Anki Import.** 🚧 Organize cards into decks with tags, edit any card, review per deck — and import genuine `.apkg` Anki decks with scheduling history and referenced media preserved. Imported cards can be **anchored to the exact EPUB passage** they came from, so they appear inline at the right spot in the reader. JSON deck export round-trips losslessly.
- **AI-Generated Cards.** 🚧 Turn a book's text into question/answer and cloze flashcards with either **your own** Anthropic API key (stored in your Keychain; no Echo account or servers) or, when Apple's Foundation Models runtime is available, an on-device provider that keeps the book text private. It's opt-in and off by default, anchored to the source passage, and drops straight into the same FSRS review flow. The book's text is sent to Anthropic only when you choose the cloud provider.
- **Brain Dump / Book Notes.** 🚧 A frictionless mental inbox: park any thought — text or voice, even dictated from the watch — without pausing the book, then promote keepers to bookmarks or flashcards. Built for leaky working memory.
- **Context Memory (opt-in).** 🚧 Echo can tag new bookmarks with an approximate place name — context-dependent memory, automated. Off by default, reduced accuracy, and deletable in one tap; session and chapter-start tagging are the remaining 1.0 scope decision.
- **Insights.** A dedicated stats screen computed entirely on-device: listening time by day/week/month/year, streaks, playback-speed trends, time-of-day patterns, Study review charts with retention curves and grade distributions, a 30-day review forecast, plus per-chapter coverage ("Ch 7 — 86%, listened 3×") and session-length views.
- **Second-Brain Export.** Per-book Markdown `.zip` bundles from the iOS More menu, plus full-library study-notes export from Settings — bookmarks, notes, flashcards, chapters, voice memos, photos, and imported card media — that drop straight into Obsidian, Logseq, or Notion. Echo Pro can also auto-export a text-only Markdown mirror to a folder you pick (for example iCloud Drive), keeping one deterministic file per book updated for Mac-side tools. Plain files, relative links, no accounts, no lock-in.
- **iCloud Study Sync.** 🚧 Flashcards, decks, bookmarks, and playback position across iPhone, Mac, and Watch via your personal iCloud — Echo runs no servers.
- **On-Device EPUB Alignment (+ PDF companion).** Seamlessly scroll through the EPUB text and view diagrams exactly when the audio reaches that section. On-device auto-alignment ([WhisperKit](https://dfakkeldy.github.io/Echo/glossary.html#whisperkit) + [CoreML](https://dfakkeldy.github.io/Echo/glossary.html#coreml)) maps every paragraph of the **EPUB** to the narration — no cloud API calls, no privacy concerns. **PDF** companions get page-level alignment (pin a page to a timestamp) and per-page screenshot bookmarks — and, for PDFs parsed into text, a **read-along reading surface** you can flip between the original page and a reflowed text feed (iOS), with the narration auto-following the page and the current word highlighted.
- **Word-by-Word Read-Along (Karaoke).** As the narration plays, the current word lights up in the text — on iPhone *and* Mac. Built on the same on-device alignment, refined to the narrator's actual word timings wherever speech recognition is confident. (Existing books need a one-time re-align to light up.)
- **Audio-only transcription reader.** Imported audiobooks that have no EPUB/PDF can be transcribed on-device into searchable read-along text, with word timing, tap-to-seek, and clear provenance so ASR text never masquerades as the canonical book.
- **On-Device Narration for text-only books.** Got an EPUB with no audiobook? Echo can speak it in a natural voice (Kokoro, the same on-device model on iPhone and Mac, run via ONNX Runtime on the CPU) — no cloud, no account, no API keys. **Choose from 28 built-in voices** (American & British, female & male). On iPhone it narrates as you listen (every device — no Neural-Engine requirement); on Mac you can queue EPUBs to synthesize overnight, then play them back like any audiobook, with full read-along. The playlist shows the book's **full chapter outline** up front, and generated tracks/M4B markers use heading-derived names like `ch. 1: The Door Opens` when available, falling back to `Chapter N`. You can tap any chapter to **skip narrating it** — handy for cutting front matter, appendices, or chapters you don't need spoken. **Markdown (`.md`/`.markdown`) and plain text (`.txt`) files are also supported** — imported as standalone narratable books on both iOS and macOS, with the same narration, read-along, and chaptered playback as EPUBs. Markdown chapters follow the heading hierarchy; plain text uses heuristic chapter detection ("Chapter N", prominent ALL-CAPS titles) and falls back to a single chapter.
- On-device narrated books get exact word-by-word read-along highlighting, timed from the speech synthesizer itself (no transcription pass).
- **Transcript and narration QA.** Source-backed alignment can compare ASR against the real EPUB/PDF text, and generated narration can be listened back for reviewable divergences. Pronunciation fixes save overrides and regenerate the affected chapter so names and jargon stay correct.
- **Tap or hold a word (iOS).** In the reflowed reader and on the PDF page, tap a word to jump the audio there, or press-and-hold to **Look Up** its definition or **Save word** — saved words become spaced-repetition vocabulary cards that replay in their original sentence.
- **Teach the narrator how to say names.** Invented character names, brands, and niche jargon trip up any text-to-speech. A built-in **Pronunciation** dictionary (Settings) lets you spell a word out in IPA once, and the narrator says it your way everywhere it appears. EPUB authors can also embed pronunciation without respelling reader text — inline SSML IPA and document-linked PLS lexicons, English/Kokoro subset. See [EPUB pronunciation authoring](docs/epub-pronunciation-authoring.md).
- **Overnight Batch Processing (Mac).** Point the Mac app at a folder of audiobooks and it imports, transcribes, and aligns them one by one, unattended — and picks up where it left off if you quit and relaunch. The same queue can also **narrate text-only EPUBs** overnight (Batch ▸ “Narrate EPUB(s)…”).
- **Chaptered M4B Export.** Export any book — AI-narrated or already-imported — as a single `.m4b` with real chapter markers and embedded metadata, playable in any chapter-aware player. Works on both iPhone and Mac; one tap on iOS (player More menu → share sheet), File menu → Save on Mac.
- **Pristine Speed Control.** Listen at 1.25x (or faster) with zero pitch distortion. Speed suggestions adapt to your listening habits.
- **Apple Watch Remote.** A massive, user-configurable interface with up to 25 customizable buttons across 5 pages. Assign the Digital Crown to control volume or scrub through audio — leave your phone in your pocket.
- **Designed for Neurodiversity.** Lexend and OpenDyslexic fonts — both backed by reading-fluency research — are built in. The hybrid document+audio view means you're never forced to learn by listening alone. The app icon (an infinity symbol in silver and gold) is a nod to the AuDHD community. The name "Echo" reflects how many neurodivergent brains work: ideas echoing between different modes of thinking, with text and audio reinforcing each other.

---

## The Road to v1.0

Echo has a defined 1.0 — rebuilt 2026-06-19 around **six competitive wedges**, each turning a recurring competitor weakness into an Echo strength:

> **Echo 1.0 is a deep study _system_ on iPhone (full), Apple Watch (companion), and Mac (full peer): the audiobooks you already own turned into spaced-repetition study; rock-solid and obviously usable; free and verifiably private; with study-state and self-hosted-library sync that never loses your place. Launch is gate-driven — it ships when it's deep and solid, not on a date.**

| Wedge | Competitors fail at… | …so Echo ships |
|---|---|---|
| **1 · Study Moat** *(lead)* | nobody has it | FSRS + **Chapter Study Mode** (partial: chapter assignment grade policy + global daily cap wired; hands-free Again/re-listen/retire prompts remain) + narrator-voice flashcards + resilient watch review + align-*or*-narrate + deep on-device analytics |
| **2 · Rock-Solid** | crashes, freezes, lost progress | never crashes, never loses your place — MetricKit diagnostics capture and macOS relaunch resume are wired; App Store Connect crash-free data and broader no-lost-progress verification remain |
| **3 · Clarity** | confusing UI, poor onboarding | a genuine UI overhaul + <60s onboarding; first-launch workflow guide, action-led empty/recovery states, Reader search/filter recovery, Reader card VoiceOver actions, inline Reader speed presets, ABS browse/Card Inbox/study-review recovery, current help/manual/settings/architecture copy, EPUB/PDF companion import, visible Bookmark Loop unavailable states, non-drag phone/watch control customization, and 44pt reader/player utility targets are in place; full interactive tutorial/UI overhaul still pending |
| **4 · Trust** | ads, hidden fees, subscriptions | free core + a **one-time** Pro unlock (never a subscription), open-source, ad-free, **verifiably** private (you can read the code) |
| **5 · Sync Done Right** | losing progress across devices | full iCloud study-state sync, a BYO local Library shelf with managed folder roots, and a self-hosted Audiobookshelf library (connect/browse/download-to-local/two-way progress sync — **shipped**; macOS UI + multiple saved servers wired on nightly; live-sync device verification and full background download remain), no lost progress |
| **6 · Support** | slow, unhelpful support | responsive, open, in-app feedback via email, GitHub Issues, and the manual |

**macOS is a full peer in 1.0** — the study layer comes to Mac, and the batch transcribe/align/narrate pipeline is already there. Full plan and the launch-gate criteria: **[ROADMAP.md](ROADMAP.md)**.

**Deferred to 1.x:** photo-of-a-page → audio jump · CarPlay capture · Audiobookshelf **streaming** (connect/browse/download/sync is now built — download-based; streaming only is deferred) · AnkiConnect · focus soundscapes. See [ROADMAP.md](ROADMAP.md).

---

## Overview

> 💡 New to a term in this section or the next? Look it up in the [Glossary](https://dfakkeldy.github.io/Echo/glossary.html) — on the website, technical words carry hover-to-define popovers.

Echo is a full-featured audiobook study application organized as a single Xcode workspace with four distinct targets. It supports bookmarking with optional voice memos, chapter navigation, loop modes, a sleep timer, variable playback speed, and intelligent rewind logic that adapts to pause duration. The iOS and watchOS apps communicate bidirectionally via WatchConnectivity, while the watchOS widget displays current artwork and progress in circular watch-face and rectangular Smart Stack/complication families. iPhone Lock Screen controls come from the system Now Playing integration, not the watch-only widget extension.

When you add an EPUB or PDF file alongside your audiobook, Echo unlocks its study toolkit: a searchable, browsable reader with per-paragraph audio alignment. Long-press any paragraph or PDF page to lock it to the current playback position, color-code important passages, or create timestamped bookmarks. Use **Auto-Align Chapters** to let Echo automatically align every chapter — it first matches audiobook chapter titles (from M4B metadata) against EPUB headings instantly, with no ML required, then falls back to on-device speech recognition (WhisperKit + CoreML) for any remaining chapters, transcribing short clips and fuzzy-matching them against the EPUB text ([Levenshtein](https://dfakkeldy.github.io/Echo/glossary.html#levenshtein) + [Jaccard](https://dfakkeldy.github.io/Echo/glossary.html#jaccard)) to create precise alignment anchors. Drift detection finds misaligned chapters, and drift repair uses [TokenDTW (Dynamic Time Warping)](https://dfakkeldy.github.io/Echo/glossary.html#dtw) to insert correction anchors at word-level precision. Optional **Continuous Alignment** runs in the background during playback. For PDF documents, use the **Manual Alignment** sheet with the scrubber joystick for fine-tuned alignment.

---

## Architecture

The workspace is composed of four targets, each with its own entry point and view hierarchy:

| Target | Bundle Identifier / Entry Point | Purpose |
|---|---|---|
| **EchoCore** (`iOS/iPadOS`) | `EchoCoreApp.swift` → `RootTabView.swift` | Primary audiobook player. Uses a 3-tab layout (Now Playing, Read & Study with EPUB/PDF alignment and full-text search, Library). PlayerModel acts as a thin coordinator over 20+ single-responsibility services. Handles library roots, file/folder selection, bookmarks, voice memos, WatchConnectivity, and Now Playing integration. When an EPUB or PDF file is loaded alongside the audiobook, the Reader tab provides a searchable, browsable book with per-paragraph alignment (EPUB) or page-level alignment (PDF). |
| **Echo macOS** (`macOS`) | `Echo_macOSApp.swift` → `MacTriPaneView.swift` | Native macOS desktop companion. Uses `MacPlayerModel` (`@Observable`-based) with a tri-pane `NavigationSplitView` layout: a local Library shelf plus table-of-contents sidebar, a player pane with a `< Chapter Title >` chevron nav bar, a Playback Options popover (speed / loop / skip / boost), a More menu, and EPUB alignment via `MacAlignmentService` with streaming audio transcription support. A native Preferences scene (⌘,, `MacSettingsView`) binds the shared `SettingsManager`. |
| **Echo Watch App** (`watchOS`) | `EchoCoreWatchApp.swift` → `ContentView.swift` | Wearable remote for the iOS player. Communicates with the phone via `WCSession` to send play/pause, skip, scrub, volume, loop mode, sleep timer, section navigation, and bookmark commands. Features a customizable button layout with up to five pages of five action slots each (25 total), with configurable seek forward/backward durations (5–60s), all syncable from the phone. |
| **Echo Widget** (`watchOS`) | `Echo_WidgetBundle.swift` → `Echo_Widget.swift` | The watchOS widget extension exposes `.accessoryCircular` and `.accessoryRectangular` families through the Watch App's `AppGroupDefaults`. Circular rendering shows the current thumbnail inside a bold system-tinted progress ring. The rectangular Smart Stack/complication card adds title, playback state, percentage, and a bold gauge; it uses the cover-derived accent only in WidgetKit full-colour rendering and adopts the watch-face palette in accented or vibrant rendering. The source includes an iOS Control Widget implementation behind a platform gate, but the current extension target is watchOS-only. |

Shared models and utilities used across targets include:

- **`PlayerModel`** — Central iOS/iPadOS coordinator (`@Observable`), wires together 20+ focused services (PlaybackController, BookmarkStore, SleepTimerManager, ChapterLoadingCoordinator, PlaybackProgressPresenter, PlayerLoadingCoordinator, BookmarkArtworkCoordinator, PlayerTimelinePersistenceService, PlaylistManager, ChapterGroupingService, etc.) via closure injection in `init()`. Each service owns a single responsibility; PlayerModel provides thin pass-through computed properties for SwiftUI view binding. Supports section-level navigation within chapters (Libation-style sub-sections), a compact player layout mode, and haptic-scrubbing through section tick marks on the scrubber rail.
- **`MacPlayerModel`** — macOS-specific playback model wrapping AVPlayer with its own bookmark format (`MacBookmark`), security-scoped bookmarks, and UserDefaults persistence. Independent of the iOS `PlaybackController` (not compiled into the macOS target), it carries its own chapter axis (M4B markers via the shared `ChapterService`), a 3-way loop with end-of-chapter sleep, a configurable skip interval, above-unity volume boost (`MacAudioBoostTap`, an `MTAudioProcessingTap`), and `SettingsManager` consumption. Pure decision helpers (`MacChapterLoopDecision`, `MacVolumeBoost`) live in `EchoCore/Services/MacPlaybackLogic.swift`.
- **`Bookmark.swift`** — The `Bookmark` struct (Codable, Equatable, Hashable) representing a saved position, with optional text note and voice memo filename. Includes `VoiceMemoRecorder` and `EditBookmarkView` for recording/editing.
- **`AppIntent.swift`** — Shared `AppGroupDefaults` suite and `SessionDelegator` for WCSession activation, enabling the widget and app intents to toggle playback.
- **`LayoutPreset.swift`** — `WatchPreset` and `PhonePreset` data models (Codable, Identifiable) for customizable watch button layouts (up to 5 pages × 5 slots) and phone transport control layouts (5-slot tap actions + 5-slot long-press secondary actions). The action palette includes play/pause, skip, next/previous track, next/previous section, loop mode, speed, sleep timer, and bookmark. Presets sync bidirectionally via WatchConnectivity and persist in UserDefaults.
- **`WatchAction.swift`** — Enumeration of all available transport actions (`playPause`, `skipForward`, `skipBackward`, `nextTrack`, `previousTrack`, `nextSection`, `previousSection`, `loopMode`, `speed`, `sleepTimer`, `bookmark`, `empty`) with SF Symbol icon mappings and watch command routing strings.
- **`ChapterGroupingService.swift`** — Detects and collapses Libation-style sub-section chapter atoms (e.g. "Chapter 11. A" / "Chapter 11. B") into logical chapters, retaining sub-sections for scrubber tick marks and section-level navigation.
- **Shared Font Assets** — `Lexend.ttf` and `OpenDyslexic-Regular.otf` are bundled in both the iOS and macOS targets for accessibility-optimized typography.
	- **`ReaderFeedViewModel`** — View model for the EPUB reader feed. Loads blocks from `EPubBlockDAO`, supports full-text search, and tracks the active block via binary search for O(log N) playback sync.
	- **`ReaderCardItem`** — Enum for reader feed items (`.chapterHeader` and `.block(EPubBlockRecord)`), rendered as cards in a `UICollectionView`.
	- **`ReaderSettings`** — User-configurable reader settings: font size, line spacing, and card background tint color.
	- **`AlignmentService`** — Manual EPUB-to-audio alignment through locked anchors and word-count-weighted proportional interpolation with dynamic CPS projection.
	- **`AutoAlignmentService`** — On-device auto-alignment via a progressive 4-tier pipeline: metadata title matching (Tier 0, `ChapterTitleMatcher`, no ML), VAD chunking + TokenDTW (Tier 1, WhisperKit), drift detection (Tier 2), drift repair (Tier 3), and manual fine-tuning.
	- **`AutoAlignmentTextMatcher`** — Fuzzy text matching (Levenshtein + word-level Jaccard) for matching transcribed audio against EPUB paragraphs.
	- **`TokenDTW`** — Dynamic Time Warping aligner for word-level EPUB-to-audio token matching. Uses flat Int32/Int8 arrays for memory-efficient 3000×3000 token grid alignment with Levenshtein-like fuzzy matching. Replaces the earlier silence-mapping approach (Tier 0) for drift repair.
- **`SilenceDetectionService`** — AVAudioFile + Accelerate-based silence gap detection. Retained for potential future use; no longer part of the active alignment pipeline.
	- **`EPUBImportService`** — Parses EPUB files into `epub_block` records: extracts the OPF spine, parses XHTML, copies images to Application Support.
		- **`PDFImportCoordinator`** — Copies PDF files into the audiobook folder with security-scoped resource access. Same-folder imports are no-ops to prevent file corruption.
		- **`PDFViewState`** — Codable model capturing PDF page index, zoom scale, and scroll offset for persistent bookmark restoration across app restarts.
		- **`PDFDocumentView`** — SwiftUI view wrapping `PDFKit.PDFView` for in-app PDF reading with long-press context menus for alignment and bookmarking.
		- **`ManualAlignmentSheet`** — Modal alignment UI with play/pause, ±5s skip, a `ScrubberJoystick` for fine-grained scrubbing, and audio snippet preview during adjustment.
		- **`ScrubberJoystick`** — Horizontal drag-track control with spring-return and exponential mapping (small pulls = slow, big pulls = fast) for precise scrubbing.
	- **`EPUBXMLParsing`** — Shared EPUB XML parser delegates (`ContainerXMLParser`, `OPFParserDelegate`, `XHTMLBlockDelegate`) deduplicated across iOS and macOS — each platform previously carried ~190 lines of identical parsing code.
	- **`WhisperSession`** — Reference-counted, shared WhisperKit model manager. Prevents duplicate ~40 MB model loads when both `AutoAlignmentService` and `ContinuousAlignmentService` are active.
	- **`ContinuousAlignmentService`** — Background audio capture and transcription: samples 15-second audio windows during playback, transcribes via WhisperKit, and inserts alignment anchors on-the-fly.
	- **`FileLocations`** — Centralized directory access (`documentsDirectory`, `cachesDirectory`, `applicationSupportDirectory`, `epubUnpackedDirectory(safeID:)`) replacing ad-hoc `FileManager.default.urls(for:in:)` calls across the codebase.
	- **`KeychainStore`** — Thin Keychain wrapper for storing security-scoped bookmark data and other sensitive blobs that should not live in unencrypted `UserDefaults`.
	- **`Logger+Subsystem`** — Single `"com.echo.audiobooks"` subsystem constant used by every logger in the project — prevents log fragmentation from typos in repeated string literals.
	- **`Schema_V1`** — Fresh-install GRDB baseline schema. This is the post-reset source of truth for Echo's current database shape; future TestFlight changes should be additive migrations again.
		- **`AnimationDurations`** — Named animation timing constants (`.micro`, `.standard`, `.emphasized`, `.slow`) to replace magic-number literals scattered across view bodies.
	- **`AudioSnippetPlayer`** — Lightweight, single-use audio player for voice-memo previews and bookmark playback. Eliminates the ad-hoc `AVAudioEngine` setup duplicated across `BookmarkStore`, `Bookmarks`, and `SnippetPlayer`.

---

## Accessibility (A11y) First

Echo is built with accessibility as a core principle, not an afterthought.

### Neurodivergent-Friendly Design

Echo is built from the ground up for the AuDHD (Autism + ADHD) and broader neurodivergent community. The core premise — a **hybrid reading + listening** experience — was inspired by the realization that many neurodivergent people struggle to learn from audio alone and need text as an anchor to stay engaged.

### Dyslexia-Optimized Typography

The project bundles two specially-selected font families to support dyslexic and neurodivergent readers:

- **Lexend** ([`EchoCore/Fonts/Lexend.ttf`](EchoCore/Fonts/Lexend.ttf) and [`Echo macOS/Fonts/Lexend.ttf`](Echo%20macOS/Fonts/Lexend.ttf)) — A typeface designed with research-backed letter spacing and proportions to improve reading fluency and reduce visual crowding.
- **OpenDyslexic** ([`EchoCore/Fonts/OpenDyslexic-Regular.otf`](EchoCore/Fonts/OpenDyslexic-Regular.otf) and [`Echo macOS/Fonts/OpenDyslexic-Regular.otf`](Echo%20macOS/Fonts/OpenDyslexic-Regular.otf)) — An open-source font weighted at the bottom to combat letter reversal and rotation, widely adopted by the dyslexia community.

### App Icon & Colors: An AuDHD Shoutout

The Echo app icon features an **infinity symbol (∞) in silver and gold** — a deliberate nod to the AuDHD community:

- **Infinity symbol (∞)**: Widely adopted by the neurodivergent community to represent the infinite variations and possibilities of the human mind — the idea that there is no single "correct" way to think, learn, or process information.
- **Silver & gold**: The AuDHD community's colors, representing the dual nature of autism (Au) and ADHD (DHD), and the unique strengths that come from this combination.
- **"Echo"**: The name itself speaks to the way many AuDHD brains work — ideas echoing back and forth between different modes of thinking, with text and audio reinforcing each other.

### Developer Requirements

> **All developers contributing to this project MUST:**
> 1. Register both fonts in the target's `Info.plist` under `UIAppFonts` (iOS) / `ATSApplicationFontsPath` (macOS) when adding new text-rendering targets.
> 2. Apply `Lexend` as the default body font and `OpenDyslexic` as the dyslexia-friendly toggle option in all user-facing text views.
> 3. Never hardcode a system font (`SF Pro`, `Helvetica Neue`, etc.) as the sole typographic option — the app must always offer at least one of the bundled accessibility fonts.
> 4. Test all new UI with both fonts enabled to ensure no truncation, overlapping, or layout breakage.

### Additional A11y Practices

- AVPlayer is configured with `mode: .spokenAudio` for optimal speech reproduction and language-specific voiceover support.
- All interactive controls (play/pause, skip, seek) are surfaced via `UIAccessibility` and WatchOS `accessibility` modifiers.
- Both Watch complication families combine title, playback state, and percentage into one VoiceOver element so colour is never the only signal. The circular ring always joins WidgetKit's system accent group; the rectangular gauge uses the cover-derived accent only in full-colour rendering and otherwise follows the system palette.
- The Watch Pomodoro shows exactly two large digits in a rounded semantic font that adapts to Dynamic Type, changing from upward-rounded hours to minutes at 60 minutes and from minutes to seconds at 60 seconds. VoiceOver announces running/stopped/complete state plus the full unit and exposes a named **Set duration** action alongside the unchanged physical long press.

---

## Development & Testing

### Test Suites

| Target | Test File | Scope |
|---|---|---|
| **EchoTests** | `EchoTests.swift` | Unit tests for the iOS model layer (playback logic, bookmark persistence, timer logic). |
| **EchoUITests** | `EchoUITests.swift`, `EchoUITestsLaunchTests.swift` | UI integration tests for the iOS app using XCUITest. |
| **Echo Watch AppTests** | `Echo_Watch_AppTests.swift` | Unit tests for watchOS model and WCSession command parsing. |
| **Echo Watch AppUITests** | `Echo_Watch_AppUITests.swift` | UI tests for the watch app (launch validation, button interaction). |

Run all tests from Xcode with `⌘U` or via the terminal:

```bash
xcodebuild test \
  -project Echo.xcodeproj \
  -scheme "Echo" \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro'
```

CI build-gates the embedded watch app through the `Echo` scheme, but watchOS
unit tests are manual until a pinned watchOS simulator destination is reliable on
the runner. To run them locally, first choose a destination from:

```bash
xcodebuild -showdestinations \
  -project Echo.xcodeproj \
  -scheme "Echo Watch App"
```

Then run:

```bash
WATCH_DEST='platform=watchOS Simulator,name=Apple Watch Series 10 (46mm)'
xcodebuild test \
  -project Echo.xcodeproj \
  -scheme "Echo Watch App" \
  -destination "$WATCH_DEST" \
  -only-testing:"Echo Watch AppTests" \
  -parallel-testing-enabled NO \
  CODE_SIGNING_ALLOWED=NO
```

### MockMediaProvider

[`MockMediaProvider.swift`](EchoCore/Services/MockMediaProvider.swift) is a `#if DEBUG`-only utility that seeds screenshot/development media into the simulator's Documents directory on first launch. It prefers a local, rights-cleared sample audiobook (`EchoScreenshotSample.m4b`) when one is bundled, and otherwise falls back to the bundled Standard Ebooks copy of *The Great Gatsby*. Audio samples are intentionally git-ignored; use public-domain or otherwise rights-cleared media for screenshots and testing.

Development EPUB fixtures are also available for testing the reader pipeline:

```
EchoCore/Development Assets/standardebooks_great_gatsby/
└── f-scott-fitzgerald_the-great-gatsby.epub  ← F. Scott Fitzgerald (EPUB)
EchoCore/Development Assets/aliceinwonderland_1102_librivox/
└── Alice's Adventures in Wonderland.epub  ← Lewis Carroll (EPUB)
```

In `#if DEBUG` builds, `SettingsView` exposes a "Load Development Assets" button under a "Debug Menu" section. This invokes `PlayerModel.loadFolder()` with the main bundle URL, seeding bundled development media for immediate testing of the reader, alignment, and search features without requiring external file selection.

This allows developers to test the full playback, bookmarking, and chapter-navigation pipeline without any network dependency or real audiobook files.

### Branching & Release Trains

Echo uses a **promotion ladder** — three long-lived branches that are release
*stages*, with code flowing one direction only:

```
feature/* ──▶ nightly ──▶ weekly ──▶ main (stable)
            (integrate)  (promote)  (promote + tag → App Store)
```

- **`nightly`** — integration branch; feature PRs land here. Builds to TestFlight daily.
- **`weekly`** — the beta channel, promoted from `nightly` weekly. Builds to TestFlight on Mondays.
- **`main`** — stable; only ever promoted from a proven `weekly`. Tagging `vX.Y.Z` here cuts an App Store release.

Hotfixes branch from `main`, then merge back *down* into `weekly`/`nightly`.

CI (`.github/workflows/ci.yml`) gates pushes/PRs to all three branches with the
**`Build gate + tests`** check: the workflow compiles the shared Echo scheme,
runs `EchoTests` on a pinned iOS 26.4 simulator destination, and smoke-builds the
macOS target. Scheduled TestFlight builds live in
`.github/workflows/release-trains.yml` (it runs from `main` and checks out the
train branch; uploads via `fastlane beta` once the App Store Connect / match
secrets are configured, compile-only until then). See **Release Engineering —
Promotion Ladder** in [`ARCHITECTURE.md`](ARCHITECTURE.md) for branch-protection
settings and the full rhythm.

Nightly builds auto-draft their TestFlight "What to Test" copy from the commit
history (`make whats-new`); weekly/external builds keep the human-curated copy.
Weekly builds also submit the committed Beta App Review details and, after a
successful TestFlight upload, push reviewed App Store screenshots/metadata when
PNG/JPG assets exist.

---

## Agentic Workflows

Echo includes an autonomous agent workflow definition at [`.clinerules/workflows/release.md`](.clinerules/workflows/release.md). This file is consumed by Cline-compatible agents to automate the release process:

1. The agent asks the developer for the next semantic version number.
2. It updates `MARKETING_VERSION` and increments `CURRENT_PROJECT_VERSION` in the Xcode project settings.
3. It stages all changes and commits with `chore: bump version to [version]`.
4. It requests permission before pushing to the remote.

When extending or modifying the project with autonomous tooling, future agents MUST:
- Read `.clinerules/workflows/release.md` before executing any version-bump or release-related task.
- Respect the font accessibility constraints documented in the **Accessibility (A11y) First** section above.
- Ensure all four platform targets remain buildable and that platform-specific compilation guards (e.g., `#if os(iOS)`, `#if os(macOS)`, `#if os(watchOS)`) are correctly maintained.

### Credits

- **[Paul Hudson](https://github.com/twostraws) ([@twostraws](https://github.com/twostraws))** — This project's [`AGENTS.md`](AGENTS.md) is adapted from Paul's [AGENTS.md template](https://github.com/twostraws/AGENTS.md), which has become the standard for guiding AI-assisted Swift and SwiftUI development.

---

## License

Echo is licensed under the [GNU General Public License v3.0 or later](LICENSE) (`GPL-3.0-or-later`) — the source stays free and open, and any derivative app must stay open source too.

For distribution through Apple's App Store (and comparable platforms), the copyright holder grants an [**App Store Distribution Exception**](LICENSE-APP-STORE-EXCEPTION.md) — an additional permission under GPLv3 §7 that resolves the known GPL-vs-App-Store incompatibility, on the condition that the complete corresponding source remains available under the GPL through this repository.
