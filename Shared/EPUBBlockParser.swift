// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Result of the shared EPUB block parse — the canonical block set (with stable,
/// iOS-format IDs) plus the context the iOS importer needs to finish (TOC
/// resolution, image localization).
///
/// The macOS aligner consumes only `blocks`; both the iOS importer and the
/// macOS alignment pipeline call the one `parseEPUBBlocks` driver, so the two
/// can never emit divergent block sets or IDs (CODE_AUDIT.md §5.1 / Phase A1).
nonisolated struct EPUBBlockParse {
    /// Flat, reading-order block records carrying final
    /// `epub-<audiobookID>-s<i>-b<j>` IDs.
    let blocks: [EPubBlockRecord]
    /// The descriptor each block was built from, aligned 1:1 with `blocks`
    /// (carries `anchorIDs` for TOC fragment resolution).
    let descriptors: [TextBlockDescriptor]
    /// Spine items in reading order.
    let spine: [SpineItemDescriptor]
    /// Publisher TOC tree (NCX navPoint / EPUB 3 nav `ol` nesting).
    let tocEntryTree: [TOCEntryNode]
    /// Directory containing the OPF — base for resolving relative hrefs.
    let opfDir: URL
    /// Per-spine XHTML file URL, keyed by spine index — for image resolution.
    let spineXHTMLURLByIndex: [Int: URL]
}

/// Parses an expanded EPUB directory into the canonical ordered block set with
/// stable IDs (`epub-<audiobookID>-s<i>-b<j>`).
///
/// This is the single source of truth for EPUB block identity, shared by
/// `EPUBImportService` (iOS) and the macOS alignment pipeline so that
/// Mac-produced alignment anchors resolve against the iOS database
/// (CODE_AUDIT.md §5.1 / `docs/MACOS_UNIFICATION_PLAN.md` Phase A1).
///
/// It produces exactly the blocks the importer persists: it runs the heuristic
/// engine, classifies front matter, and performs the synthetic-heading
/// insertion — the only block-*set*-changing step — before assigning IDs.
/// Downstream iOS steps (TOC promotion, chapter-index assignment, image
/// copying) mutate individual block fields but never the block set, so the IDs
/// stay stable.
///
/// - Parameters:
///   - audiobookID: The audiobook identifier embedded in every block ID
///     (typically `folderURL.absoluteString`). Both sides of a handoff must
///     use the same value for the resulting IDs to match.
///   - epubURL: An expanded EPUB directory (callers extract `.epub` archives
///     first, mirroring the iOS import path).
nonisolated func parseEPUBBlocks(
    audiobookID: String,
    epubURL: URL,
    generatedIdentity: GeneratedAnthologyImportIdentity? = nil
) throws -> EPUBBlockParse {
    // 1. Locate container.xml and find the OPF path.
    let containerURL = epubURL.appendingPathComponent("META-INF/container.xml")
    guard FileManager.default.fileExists(atPath: containerURL.path) else {
        throw EPUBImportError.notAnEPUB(url: epubURL)
    }
    let containerData = try Data(contentsOf: containerURL)
    guard let opfRelativePath = parseContainerXML(from: containerData) else {
        throw EPUBImportError.missingOPF
    }
    let opfURL = epubURL.appendingPathComponent(opfRelativePath)
    let opfDir = opfURL.deletingLastPathComponent()

    // 2. Parse OPF for spine order.
    let opfData = try Data(contentsOf: opfURL)
    let opfResult = parseOPF(from: opfData)
    try generatedIdentity?.validatePackage(
        identifier: opfResult.packageIdentifier,
        manifestSHA256: opfResult.echoManifestSHA256)
    let lexiconManifest = OPFParserDelegate()
    lexiconManifest.parse(opfData)
    let declaredLexicons = try Set(
        lexiconManifest.pronunciationLexiconHrefs.map {
            try EPUBPronunciationImport.localURL($0, relativeTo: opfDir, root: epubURL)
        })
    let spine = opfResult.spine
    guard !spine.isEmpty else {
        throw EPUBImportError.spineEmpty
    }

    // 2.5 Parse TOC (and EPUB 3 landmarks) if available.
    var tocMap: [String: String] = [:]
    var tocEntryTree: [TOCEntryNode] = []
    var landmarks: [GuideReference] = []
    if let tocHref = opfResult.tocHref {
        let tocURL: URL
        if tocHref.hasPrefix("/") || tocHref.contains("://") {
            tocURL = epubURL.appendingPathComponent(tocHref)
        } else {
            tocURL = opfDir.appendingPathComponent(tocHref)
        }
        if let tocData = try? Data(contentsOf: tocURL) {
            let tocParser = TOCParserDelegate()
            tocParser.parse(tocData)
            tocMap = tocParser.tocMap
            tocEntryTree = tocParser.tocEntries
            landmarks = tocParser.landmarks
        }
    }

    // 2.6 Locate where body matter starts so front matter (cover, praise
    // pages, printed TOC, …) is never promoted to chapters.
    let bodyStartSpineIndex = EPUBStructure.bodyMatterStartIndex(
        spine: spine,
        guideReferences: opfResult.guideReferences,
        landmarks: landmarks
    )

    // 3. Parse XHTML spine items into blocks.
    var parsedSpines: [(blocks: [TextBlockDescriptor], title: String?)] = []
    var spineXHTMLURLByIndex: [Int: URL] = [:]
    var generatedChapterBySpineIndex: [Int: GeneratedChapterIdentity] = [:]
    var seenGeneratedHrefs = Set<String>()

    for (i, item) in spine.enumerated() {
        let href = item.href
        let generatedChapter = generatedIdentity?.chapter(for: href)
        if let generatedChapter {
            guard seenGeneratedHrefs.insert(generatedChapter.href).inserted else {
                throw GeneratedAnthologyImportError.unexpectedChapter
            }
            generatedChapterBySpineIndex[i] = generatedChapter
        }
        let xhtmlURL: URL
        if href.hasPrefix("/") || href.contains("://") {
            xhtmlURL = epubURL.appendingPathComponent(href)
        } else {
            xhtmlURL = opfDir.appendingPathComponent(href)
        }
        spineXHTMLURLByIndex[i] = xhtmlURL

        guard FileManager.default.fileExists(atPath: xhtmlURL.path) else {
            parsedSpines.append((blocks: [], title: nil))
            continue
        }

        let xhtmlData = try Data(contentsOf: xhtmlURL)
        let parser = XHTMLBlockDelegate(captureEchoMetadata: generatedChapter != nil)
        parser.parse(xhtmlData)
        if let error = parser.pronunciation.error {
            throw EPUBPronunciationError(detail: "\(href): \(error.detail)")
        }
        var textBlocks = parser.textBlocks
        try EPUBPronunciationImport.applyLexicons(
            parser.pronunciation.links, to: &textBlocks,
            xhtmlURL: xhtmlURL, root: epubURL, declaredURLs: declaredLexicons)
        parsedSpines.append((blocks: textBlocks, title: parser.documentTitle))
    }
    if let generatedIdentity,
        seenGeneratedHrefs != Set(generatedIdentity.chaptersByHref.keys)
    {
        throw GeneratedAnthologyImportError.unexpectedChapter
    }

    // 4. Apply Heuristic Engine.
    var engine = EPUBHeuristicEngine(
        tocLabels: Array(tocMap.values), spineItemCount: spine.count)
    let allExtractedBlocks = parsedSpines.flatMap { $0.blocks }
    engine.buildCSSFingerprint(from: allExtractedBlocks)

    var blocks: [EPubBlockRecord] = []
    var descriptors: [TextBlockDescriptor] = []
    var sequenceIndex = 0
    var hasSeenContentHeading = false
    // One timestamp for the whole parse — block `created_at` is not part of the
    // ID and no consumer depends on per-block variance.
    let createdAt = ISO8601DateFormatter().string(from: Date())

    for i in 0..<parsedSpines.count {
        var textBlocks = parsedSpines[i].blocks
        let spineHref = spine[i].href

        // Score pass. Manifest-backed generated chapters already carry an
        // authenticated kind for every stable block. Reclassifying them with
        // generic publisher heuristics would invalidate that identity.
        if generatedChapterBySpineIndex[i] == nil {
            for j in 0..<textBlocks.count {
                let spans = textBlocks[j].pronunciationSpans
                let newKind = engine.score(block: textBlocks[j])
                // Create a new struct to update the kind
                textBlocks[j] = TextBlockDescriptor(
                    kind: newKind,
                    text: textBlocks[j].text,
                    imagePath: textBlocks[j].imagePath,
                    htmlContent: textBlocks[j].htmlContent,
                    markers: textBlocks[j].markers,
                    textFormats: textBlocks[j].textFormats,
                    rawClasses: textBlocks[j].rawClasses,
                    rawTags: textBlocks[j].rawTags,
                    anchorIDs: textBlocks[j].anchorIDs,
                    narrationCue: textBlocks[j].narrationCue,
                    codeLanguage: textBlocks[j].codeLanguage,
                    echoMetadataPresent: textBlocks[j].echoMetadataPresent,
                    echoStableSlot: textBlocks[j].echoStableSlot,
                    echoBlockIndex: textBlocks[j].echoBlockIndex,
                    echoNarration: textBlocks[j].echoNarration,
                    echoLinkNarrationValues: textBlocks[j].echoLinkNarrationValues
                )
                textBlocks[j].pronunciationSpans = spans
            }
        }
        let stableBlockIndices: [Int]?
        if let chapter = generatedChapterBySpineIndex[i], let generatedIdentity {
            stableBlockIndices = try generatedIdentity.validate(
                descriptors: textBlocks,
                chapter: chapter)
        } else {
            stableBlockIndices = nil
        }

        // Apply TOC Map or Document Title fallback if no *content* heading.
        let hasContentHeading = textBlocks.contains(where: { block in
            guard block.kind == .heading,
                let text = block.text,
                !text.trimmingCharacters(in: .whitespaces).isEmpty
            else { return false }
            return !HeadingClassifier.isJunk(text)
        })

        let decodedHref = spineHref.removingPercentEncoding ?? spineHref
        let hrefWithoutFragment = String(decodedHref.components(separatedBy: "#")[0])
        let fallbackTitle =
            tocMap[hrefWithoutFragment]
            ?? parsedSpines[i].title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let titleIsNonContent = fallbackTitle.map(HeadingClassifier.isNonContent) ?? false

        // Front matter by structure (linear="no", or before the guide /
        // landmarks body start), or — when the EPUB provides no structural
        // info — by a non-content title on a heading-less spine before any
        // real content has appeared.
        let structuralFrontMatter =
            !spine[i].linear
            || (bodyStartSpineIndex.map { i < $0 } ?? false)
        let canUseTitleHeuristic = bodyStartSpineIndex == nil && !hasSeenContentHeading
        let titleMatchesFrontMatterKeyword =
            canUseTitleHeuristic
            && (EPUBStructure.matchesFrontMatterTitleKeyword(fallbackTitle)
                || EPUBStructure.hrefMatchesFrontMatterTitleKeyword(spineHref))
        let isFrontMatterSpine =
            structuralFrontMatter
            || (canUseTitleHeuristic && !hasContentHeading && titleIsNonContent)
            || titleMatchesFrontMatterKeyword

        if hasContentHeading && !isFrontMatterSpine {
            hasSeenContentHeading = true
        } else if generatedChapterBySpineIndex[i] == nil,
            !isFrontMatterSpine, !titleIsNonContent,
            let title = fallbackTitle, !title.isEmpty,
            title.lowercased() != "untitled", title.lowercased() != "unknown"
        {
            let headingBlock = TextBlockDescriptor(
                kind: .heading,
                text: title,
                imagePath: nil,
                htmlContent: "<h2>\(title)</h2>",
                markers: [SyncMarker(type: .chapterStart, payload: "1", epubCharOffset: 0)],
                textFormats: []
            )
            textBlocks.insert(headingBlock, at: 0)
        }

        for (blockIdx, textBlock) in textBlocks.enumerated() {
            let stableBlockIndex = stableBlockIndices?[blockIdx]
            let generatedChapter = generatedChapterBySpineIndex[i]
            let wordCount =
                textBlock.text?.split(whereSeparator: { $0.isWhitespace }).count ?? 0
            let block = EPubBlockRecord(
                id: stableBlockIndex.map {
                    "epub-\(audiobookID)-s\(generatedChapter!.stableSlot)-b\($0)"
                }
                    ?? (generatedIdentity == nil
                        ? "epub-\(audiobookID)-s\(i)-b\(blockIdx)"
                        : "epub-\(audiobookID)-generic-s\(i)-b\(blockIdx)"),
                audiobookID: audiobookID,
                spineHref: spineHref,
                spineIndex: i,
                blockIndex: stableBlockIndex ?? blockIdx,
                sequenceIndex: sequenceIndex,
                blockKind: textBlock.kind.rawValue,
                text: textBlock.text,
                htmlContent: textBlock.htmlContent,
                cardColor: nil,
                imagePath: textBlock.imagePath,
                chapterIndex: nil,
                isHidden: false,
                hiddenReason: nil,
                isFrontMatter: isFrontMatterSpine,
                wordCount: max(1, wordCount),
                markers: EPubBlockRecord.encodeMarkers(textBlock.markers),
                textFormats: EPubBlockRecord.encodeFormats(textBlock.textFormats),
                narrationText: textBlock.narrationCue,
                codeLanguage: textBlock.codeLanguage,
                sourceChapterKey: generatedChapter?.sourceChapterKey,
                pronunciationAnnotations: try EPUBPronunciationStorage.encode(
                    textBlock.pronunciationSpans),
                createdAt: createdAt,
                modifiedAt: nil
            )
            blocks.append(block)
            descriptors.append(textBlock)
            sequenceIndex += 1
        }
    }

    return EPUBBlockParse(
        blocks: blocks,
        descriptors: descriptors,
        spine: spine,
        tocEntryTree: tocEntryTree,
        opfDir: opfDir,
        spineXHTMLURLByIndex: spineXHTMLURLByIndex
    )
}

// MARK: - Spine structural classification

/// Pure helpers for classifying EPUB spine structure. Shared so the one block
/// driver (and the iOS importer's TOC resolution) agree on href normalization
/// and body-matter detection.
nonisolated enum EPUBStructure {

    /// Spine/heading titles that are front matter even when the file carries a
    /// real heading. Deliberately excludes foreword, preface, and introduction:
    /// those are listenable content and keep their own chapters.
    private static let frontMatterTitleKeywords: Set<String> = [
        "title page", "titlepage", "copyright", "copyright page", "colophon",
        "dedication", "epigraph", "table of contents", "contents", "half title",
        "halftitle", "frontispiece", "about the author", "also by",
        "acknowledgments", "acknowledgements",
    ]

    static func matchesFrontMatterTitleKeyword(_ title: String?) -> Bool {
        guard let title else { return false }
        let normalized =
            title
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !normalized.isEmpty else { return false }

        if frontMatterTitleKeywords.contains(normalized) {
            return true
        }
        let compact = normalized.replacing(" ", with: "")
        if frontMatterTitleKeywords.contains(compact) {
            return true
        }
        return frontMatterTitleKeywords.contains { keyword in
            normalized.hasPrefix("\(keyword) ")
        }
    }

    static func hrefMatchesFrontMatterTitleKeyword(_ href: String) -> Bool {
        let normalized = normalizeHref(href)
        let stem = URL(fileURLWithPath: normalized)
            .deletingPathExtension()
            .lastPathComponent
        return matchesFrontMatterTitleKeyword(stem)
    }

    /// Spine index where body matter starts, from EPUB 3 landmarks
    /// (`epub:type="bodymatter"`) or the EPUB 2 guide (`type="text"`).
    /// Returns nil when the EPUB provides neither signal.
    static func bodyMatterStartIndex(
        spine: [SpineItemDescriptor],
        guideReferences: [GuideReference],
        landmarks: [GuideReference]
    ) -> Int? {
        let candidates =
            landmarks.filter { $0.type.split(separator: " ").contains("bodymatter") }
            + guideReferences.filter { $0.type == "text" }
        for candidate in candidates {
            if let index = spineIndex(of: candidate.href, in: spine) {
                return index
            }
        }
        return nil
    }

    static func spineIndex(of href: String, in spine: [SpineItemDescriptor]) -> Int? {
        let target = normalizeHref(href)
        if let exact = spine.firstIndex(where: { normalizeHref($0.href) == target }) {
            return exact
        }
        // Guide/landmark hrefs can be relative to a different directory than
        // spine hrefs (nav doc vs OPF); fall back to filename equality.
        let targetName = URL(fileURLWithPath: target).lastPathComponent
        return spine.firstIndex(where: {
            URL(fileURLWithPath: normalizeHref($0.href)).lastPathComponent == targetName
        })
    }

    /// Percent-decodes an href and strips its fragment.
    static func normalizeHref(_ href: String) -> String {
        let decoded = href.removingPercentEncoding ?? href
        return String(decoded.components(separatedBy: "#")[0])
    }
}

// MARK: - Errors

nonisolated enum EPUBImportError: LocalizedError, Equatable {
    case notAnEPUB(url: URL)
    case missingOPF
    case spineEmpty
    case databaseNotAvailable

    var errorDescription: String? {
        switch self {
        case .notAnEPUB(let url):
            return "Not a valid EPUB: \(url.lastPathComponent)"
        case .missingOPF:
            return "container.xml does not reference a content.opf"
        case .spineEmpty:
            return "EPUB spine is empty — no content to import"
        case .databaseNotAvailable:
            return "Database service not available for EPUB import"
        }
    }
}
