// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

// MARK: - Whitespace Normalization

nonisolated extension StringProtocol {
    /// Collapses every run of whitespace (spaces, newlines, tabs, NBSP) into a
    /// single space and trims the ends. Publisher XHTML is pretty-printed, so
    /// without this extracted titles and text keep source-file line breaks.
    nonisolated func collapsedWhitespace() -> String {
        split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

// MARK: - Models

/// Describes a spine item from the OPF manifest (reading-order metadata).
nonisolated struct SpineItemDescriptor: Sendable {
    let id: String
    let href: String
    let mediaType: String
    /// `false` when the spine itemref carries `linear="no"` — auxiliary
    /// content (cover pages, inserts) outside the main reading flow.
    let linear: Bool

    init(id: String, href: String, mediaType: String, linear: Bool = true) {
        self.id = id
        self.href = href
        self.mediaType = mediaType
        self.linear = linear
    }
}

/// A classified pointer from EPUB structural metadata: an EPUB 2
/// `<guide><reference>` or an EPUB 3 landmarks entry.
///
/// `type` values follow the specs: "cover", "toc", "copyright-page",
/// "text" (guide, EPUB 2) or "cover", "toc", "bodymatter" (landmarks, EPUB 3).
nonisolated struct GuideReference: Sendable {
    let type: String
    let href: String
}

/// A node in the publisher-declared TOC tree (NCX `navPoint` nesting or
/// EPUB 3 nav `ol` nesting). `href` is the spine-relative file (decoded, no
/// fragment); `fragment` is the anchor id within that file, when present.
nonisolated struct TOCEntryNode: Sendable, Equatable {
    var title: String
    var href: String
    var fragment: String?
    var children: [TOCEntryNode]

    init(title: String, href: String, fragment: String? = nil, children: [TOCEntryNode] = []) {
        self.title = title
        self.href = href
        self.fragment = fragment
        self.children = children
    }
}

/// Result of parsing an OPF package document.
nonisolated struct OPFParseResult: Sendable {
    let spine: [SpineItemDescriptor]
    let tocHref: String?
    let guideReferences: [GuideReference]
    let packageIdentifier: String?
    let echoManifestSHA256: String?
}

/// A parsed block from XHTML content — a paragraph, heading, image, or code.
nonisolated struct TextBlockDescriptor: Sendable {
    let kind: EPubBlockRecord.Kind
    var text: String?
    let imagePath: String?
    let htmlContent: String?
    let markers: [SyncMarker]
    let textFormats: [TextFormat]
    let rawClasses: [String]
    let rawTags: String
    /// Element `id` attributes seen within (or immediately wrapping) this
    /// block, in document order — used to resolve TOC fragment targets.
    let anchorIDs: [String]
    /// Spoken cue for `.code` blocks (figcaption or "Code listing."). Nil otherwise.
    var narrationCue: String?
    /// Language hint for `.code` blocks. Nil otherwise.
    let codeLanguage: String?
    let echoMetadataPresent: Bool
    let echoStableSlot: Int?
    let echoBlockIndex: Int?
    let echoNarration: String?
    let echoLinkNarrationValues: [String]
    var pronunciationSpans: [EPUBPronunciationSpan] = []

    init(
        kind: EPubBlockRecord.Kind, text: String?, imagePath: String?, htmlContent: String?,
        markers: [SyncMarker] = [], textFormats: [TextFormat] = [],
        rawClasses: [String] = [], rawTags: String = "", anchorIDs: [String] = [],
        narrationCue: String? = nil, codeLanguage: String? = nil,
        echoMetadataPresent: Bool = false, echoStableSlot: Int? = nil,
        echoBlockIndex: Int? = nil, echoNarration: String? = nil,
        echoLinkNarrationValues: [String] = []
    ) {
        self.kind = kind
        self.text = text
        self.imagePath = imagePath
        self.htmlContent = htmlContent
        self.markers = markers
        self.textFormats = textFormats
        self.rawClasses = rawClasses
        self.rawTags = rawTags
        self.anchorIDs = anchorIDs
        self.narrationCue = narrationCue
        self.codeLanguage = codeLanguage
        self.echoMetadataPresent = echoMetadataPresent
        self.echoStableSlot = echoStableSlot
        self.echoBlockIndex = echoBlockIndex
        self.echoNarration = echoNarration
        self.echoLinkNarrationValues = echoLinkNarrationValues
    }
}

// MARK: - Container XML Parser

/// Parses `META-INF/container.xml` to locate the OPF package document path.
nonisolated final class ContainerXMLParser: NSObject, XMLParserDelegate {
    var rootfilePath: String?

    func parse(_ data: Data) {
        let parser = XMLParser(data: data)
        // Trust boundary: parsing untrusted EPUB input.
        parser.shouldResolveExternalEntities = false
        parser.delegate = self
        parser.parse()
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        if elementName == "rootfile", let path = attributeDict["full-path"] {
            rootfilePath = path
        }
    }
}

// MARK: - OPF Parser

/// Parses an OPF (package document) into an ordered list of spine items.
///
/// Reads `<manifest>` items and cross-references them with `<spine>` itemref
/// elements to produce `SpineItemDescriptor` values in reading order.
nonisolated final class OPFParserDelegate: NSObject, XMLParserDelegate {
    var spineItems: [SpineItemDescriptor] = []
    var pronunciationLexiconHrefs: [String] = []
    /// Preferred TOC source: the EPUB 3 nav document when present (labels are
    /// usually cleaner), otherwise the legacy NCX.
    var tocHref: String? { navHref ?? ncxHref }
    var guideReferences: [GuideReference] = []
    private var navHref: String?
    private var ncxHref: String?
    private var manifestItems: [String: SpineItemDescriptor] = [:]
    private var spineRefs: [(idref: String, linear: Bool)] = []
    private var currentAttributes: [String: String] = [:]
    private var metadataText = ""
    private var metadataTarget: MetadataTarget?
    private(set) var packageIdentifier: String?
    private(set) var echoManifestSHA256: String?

    private enum MetadataTarget {
        case identifier
        case manifestSHA256
    }

    func parse(_ data: Data) {
        let parser = XMLParser(data: opfDataEscapingBareAmpersands(data))
        parser.delegate = self
        parser.shouldProcessNamespaces = true
        parser.parse()
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        if elementName == "item", attributeDict["media-type"] == "application/pls+xml",
            let href = attributeDict["href"]
        {
            pronunciationLexiconHrefs.append(href)
        }
        currentAttributes = attributeDict
        if elementName == "identifier" {
            metadataTarget = .identifier
            metadataText = ""
        } else if elementName == "meta",
            attributeDict["property"] == "echo:manifest-sha256"
        {
            metadataTarget = .manifestSHA256
            metadataText = ""
        }
        if elementName == "itemref", let idref = attributeDict["idref"] {
            spineRefs.append((idref: idref, linear: attributeDict["linear"]?.lowercased() != "no"))
        } else if elementName == "reference",
            let type = attributeDict["type"],
            let href = attributeDict["href"]
        {
            guideReferences.append(GuideReference(type: type, href: href))
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        if elementName == "identifier", metadataTarget == .identifier {
            packageIdentifier = metadataText.trimmingCharacters(in: .whitespacesAndNewlines)
            metadataTarget = nil
        } else if elementName == "meta", metadataTarget == .manifestSHA256 {
            echoManifestSHA256 = metadataText.trimmingCharacters(in: .whitespacesAndNewlines)
            metadataTarget = nil
        }
        if elementName == "item",
            let id = currentAttributes["id"],
            let href = currentAttributes["href"],
            let mediaType = currentAttributes["media-type"]
        {
            manifestItems[id] = SpineItemDescriptor(id: id, href: href, mediaType: mediaType)

            // `properties` is a space-separated list per spec (e.g. "nav scripted").
            let properties = (currentAttributes["properties"] ?? "").split(separator: " ")
            if properties.contains("nav") {
                navHref = href
            } else if id == "ncx" || mediaType == "application/x-dtbncx+xml" {
                ncxHref = href
            }
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if metadataTarget != nil { metadataText += string }
    }

    func parserDidEndDocument(_ parser: XMLParser) {
        spineItems = spineRefs.compactMap { ref in
            guard let item = manifestItems[ref.idref] else { return nil }
            return SpineItemDescriptor(
                id: item.id, href: item.href, mediaType: item.mediaType, linear: ref.linear)
        }
    }
}

/// Some publisher OPFs in real libraries contain unescaped ampersands in
/// metadata text (`Eating & Diet`). That is malformed XML, but the spine and
/// manifest are still usable, so repair bare ampersands before parsing package
/// metadata.
private nonisolated func opfDataEscapingBareAmpersands(_ data: Data) -> Data {
    guard let string = String(data: data, encoding: .utf8), string.contains("&") else {
        return data
    }

    var repaired = ""
    repaired.reserveCapacity(string.count)

    var index = string.startIndex
    while index < string.endIndex {
        guard string[index] == "&" else {
            repaired.append(string[index])
            index = string.index(after: index)
            continue
        }

        let next = string.index(after: index)
        if isXMLReference(in: string, startingAt: next) {
            repaired.append("&")
        } else {
            repaired.append("&amp;")
        }
        index = next
    }

    return Data(repaired.utf8)
}

private nonisolated func isXMLReference(in string: String, startingAt start: String.Index) -> Bool {
    guard start < string.endIndex else { return false }

    if string[start] == "#" {
        return isXMLCharacterReference(in: string, startingAt: string.index(after: start))
    }

    var index = start
    guard let first = string[index].unicodeScalars.first, isXMLNameStart(first) else {
        return false
    }
    index = string.index(after: index)

    while index < string.endIndex {
        if string[index] == ";" { return true }
        guard let scalar = string[index].unicodeScalars.first, isXMLNameCharacter(scalar) else {
            return false
        }
        index = string.index(after: index)
    }
    return false
}

private nonisolated func isXMLCharacterReference(in string: String, startingAt start: String.Index)
    -> Bool
{
    guard start < string.endIndex else { return false }

    var index = start
    if string[index] == "x" || string[index] == "X" {
        index = string.index(after: index)
        let digitStart = index
        while index < string.endIndex, isHexDigit(string[index]) {
            index = string.index(after: index)
        }
        return index > digitStart && index < string.endIndex && string[index] == ";"
    }

    let digitStart = index
    while index < string.endIndex, string[index].isNumber {
        index = string.index(after: index)
    }
    return index > digitStart && index < string.endIndex && string[index] == ";"
}

private nonisolated func isXMLNameStart(_ scalar: Unicode.Scalar) -> Bool {
    scalar == ":" || scalar == "_"
        || ("A"..."Z").contains(Character(scalar))
        || ("a"..."z").contains(Character(scalar))
}

private nonisolated func isXMLNameCharacter(_ scalar: Unicode.Scalar) -> Bool {
    isXMLNameStart(scalar)
        || ("0"..."9").contains(Character(scalar))
        || scalar == "-" || scalar == "."
}

private nonisolated func isHexDigit(_ character: Character) -> Bool {
    ("0"..."9").contains(character)
        || ("A"..."F").contains(character)
        || ("a"..."f").contains(character)
}

// MARK: - TOC Parser

/// Parses `toc.ncx` (EPUB 2) or `nav.xhtml` (EPUB 3) to extract a mapping from `href` to TOC title.
nonisolated final class TOCParserDelegate: NSObject, XMLParserDelegate {
    var tocMap: [String: String] = [:]
    /// Publisher-declared TOC tree (NCX navPoint / EPUB 3 nav ol nesting).
    var tocEntries: [TOCEntryNode] = []
    /// Entries from the EPUB 3 landmarks nav (`<nav epub:type="landmarks">`),
    /// e.g. type "bodymatter" pointing at the first body-content file.
    var landmarks: [GuideReference] = []
    private var isInsideNavLabelText = false
    private var currentText = ""
    private var currentSrc = ""
    /// `epub:type` values of currently open `<nav>` elements (innermost last).
    /// Only anchors inside the "toc" nav may contribute titles — otherwise
    /// landmarks/page-list labels pollute the map.
    private var navTypes: [String] = []
    /// Open NCX `navPoint` frames, outermost first; children attach on pop.
    private var ncxFrames: [TOCEntryNode] = []
    /// Open EPUB 3 nav `<ol>` levels, outermost first. Nodes collect per
    /// level; a closing `<ol>` attaches its nodes as children of the last
    /// node in the enclosing level.
    private var navLevelStack: [[TOCEntryNode]] = []

    /// Mirrors the anchor rule below: a nav with no `epub:type` is treated as
    /// the TOC (lenient toward malformed nav docs), named navs must say "toc".
    private var isInsideTOCNav: Bool {
        let words = (navTypes.last ?? "").split(separator: " ")
        return words.isEmpty || words.contains("toc")
    }

    /// Splits an `href`/`src` into a percent-decoded file path and fragment.
    private static func splitTarget(_ src: String) -> (href: String, fragment: String?) {
        let parts = src.components(separatedBy: "#")
        let file = parts[0].removingPercentEncoding ?? parts[0]
        guard parts.count > 1 else { return (file, nil) }
        let rawFragment = parts.dropFirst().joined(separator: "#")
        let fragment = rawFragment.removingPercentEncoding ?? rawFragment
        return (file, fragment.isEmpty ? nil : fragment)
    }

    func parse(_ data: Data) {
        let parser = XMLParser(data: data)
        // Trust boundary: parsing untrusted EPUB input.
        parser.shouldResolveExternalEntities = false
        parser.delegate = self
        parser.parse()
    }

    func parser(
        _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
        qualifiedName: String?, attributes attributeDict: [String: String] = [:]
    ) {
        if elementName == "nav" {  // NAV (EPUB3)
            navTypes.append(attributeDict["epub:type"] ?? "")
        } else if elementName == "navPoint" {  // NCX
            ncxFrames.append(TOCEntryNode(title: "", href: ""))
        } else if elementName == "ol" {  // NAV (EPUB3)
            if isInsideTOCNav { navLevelStack.append([]) }
        } else if elementName == "text" {  // NCX
            isInsideNavLabelText = true
            currentText = ""
        } else if elementName == "content" {  // NCX
            if let src = attributeDict["src"] {
                currentSrc = src
                let label = currentText.collapsedWhitespace()
                if !label.isEmpty {
                    let href = String(currentSrc.components(separatedBy: "#")[0])
                    let decodedHref = href.removingPercentEncoding ?? href
                    if tocMap[decodedHref] == nil {
                        tocMap[decodedHref] = label
                    }
                }
                // Fill the innermost open navPoint frame (its <content> comes
                // before any child navPoints, so innermost-empty is correct).
                if !ncxFrames.isEmpty, ncxFrames[ncxFrames.count - 1].href.isEmpty {
                    let target = Self.splitTarget(src)
                    if !target.href.isEmpty {
                        ncxFrames[ncxFrames.count - 1].href = target.href
                        ncxFrames[ncxFrames.count - 1].fragment = target.fragment
                        ncxFrames[ncxFrames.count - 1].title = label
                    }
                }
            }
        } else if elementName == "a" {  // NAV (EPUB3)
            if let href = attributeDict["href"] {
                let navWords = (navTypes.last ?? "").split(separator: " ")
                if navWords.contains("landmarks") {
                    let cleanHref = String(href.components(separatedBy: "#")[0])
                    let decoded = cleanHref.removingPercentEncoding ?? cleanHref
                    landmarks.append(
                        GuideReference(type: attributeDict["epub:type"] ?? "", href: decoded))
                } else if navWords.isEmpty || navWords.contains("toc") {
                    currentSrc = href
                    isInsideNavLabelText = true
                    currentText = ""
                }
                // Anchors in other navs (page-list, etc.) are ignored.
            }
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if isInsideNavLabelText {
            currentText += string
        }
    }

    func parser(
        _ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
        qualifiedName: String?
    ) {
        if elementName == "nav" {  // NAV (EPUB3)
            // Malformed docs may close the nav with <ol> levels still open;
            // flush them innermost-out so collected entries aren't lost.
            if isInsideTOCNav {
                while !navLevelStack.isEmpty {
                    attachClosedNavLevel(navLevelStack.removeLast())
                }
            }
            if !navTypes.isEmpty { navTypes.removeLast() }
        } else if elementName == "navPoint" {  // NCX
            guard !ncxFrames.isEmpty else { return }
            let frame = ncxFrames.removeLast()
            // An entry without a display title or target file can't be a TOC
            // row — keep its children by promoting them to this level.
            let finished = (frame.title.isEmpty || frame.href.isEmpty) ? frame.children : [frame]
            if ncxFrames.isEmpty {
                tocEntries.append(contentsOf: finished)
            } else {
                ncxFrames[ncxFrames.count - 1].children.append(contentsOf: finished)
            }
        } else if elementName == "ol" {  // NAV (EPUB3)
            guard isInsideTOCNav, !navLevelStack.isEmpty else { return }
            attachClosedNavLevel(navLevelStack.removeLast())
        } else if elementName == "text" {  // NCX end text
            isInsideNavLabelText = false
        } else if elementName == "a" {  // NAV end a
            guard isInsideNavLabelText else { return }  // anchor was in a non-TOC nav
            isInsideNavLabelText = false
            let href = String(currentSrc.components(separatedBy: "#")[0])
            let decodedHref = href.removingPercentEncoding ?? href
            let label = currentText.collapsedWhitespace()
            if tocMap[decodedHref] == nil && !label.isEmpty {
                tocMap[decodedHref] = label
            }
            let target = Self.splitTarget(currentSrc)
            if !label.isEmpty, !target.href.isEmpty {
                let node = TOCEntryNode(title: label, href: target.href, fragment: target.fragment)
                if navLevelStack.isEmpty {
                    tocEntries.append(node)
                } else {
                    navLevelStack[navLevelStack.count - 1].append(node)
                }
            }
        }
    }

    /// Attaches a closed `<ol>` level: nested levels become children of the
    /// last node in the enclosing level; the outermost level becomes roots.
    private func attachClosedNavLevel(_ level: [TOCEntryNode]) {
        guard !level.isEmpty else { return }
        if navLevelStack.isEmpty {
            tocEntries.append(contentsOf: level)
        } else if navLevelStack[navLevelStack.count - 1].isEmpty {
            // Malformed: a nested list with no preceding sibling anchor.
            navLevelStack[navLevelStack.count - 1].append(contentsOf: level)
        } else {
            let lastIndex = navLevelStack[navLevelStack.count - 1].count - 1
            navLevelStack[navLevelStack.count - 1][lastIndex].children.append(contentsOf: level)
        }
    }
}

// MARK: - XHTML Block Parser

/// Parses XHTML content into `TextBlockDescriptor` values, stripping markup and
/// preserving block structure (paragraphs, headings, images, code blocks).
///
/// This parser:
/// - Skips `script`, `style`, and non-title `head` content.
/// - Splits text on paragraph-level tags (`p`, `div`, `h1`–`h6`, `blockquote`, `li`, `section`).
/// - Captures heading content and inline HTML for rich display.
/// - Extracts image blocks from `<img src="...">` elements.
nonisolated final class XHTMLBlockDelegate: NSObject, XMLParserDelegate {
    var textBlocks: [TextBlockDescriptor] = []
    var documentTitle: String?
    let pronunciation = EPUBInlinePronunciationTracker()
    private var currentText = ""
    private var currentHTML = ""
    private var inlineDepth = 0
    private var isInBlock = false
    private var currentHeading = ""
    private var isInHeading = false
    private var skipDepth = 0
    private var isInsideHead = false
    private var isInsideTitle = false
    private var currentBlockClasses: [String] = []
    private var currentBlockTags: String = ""
    private var blockquoteDepth = 0
    private var currentBlockHasBlockquote = false
    // MARK: - Code block (<pre>) capture
    private var isInPre = false
    private var currentCodeText = ""
    private var currentCodeLanguage: String?
    // MARK: - Figure / figcaption (code-listing captions)
    private struct FigureContext {
        var captionText = ""
        var codeBlockIndices: [Int] = []
        var imageBlockIndices: [Int] = []
    }

    private var figureStack: [FigureContext] = []
    private var isInFigcaption = false
    private let skipTags: Set<String> = ["script", "style", "figcaption"]
    private let blockTags: Set<String> = [
        "p", "div", "h1", "h2", "h3", "h4", "h5", "h6", "blockquote", "li", "section",
    ]
    private let inlineTags: Set<String> = [
        "b", "i", "em", "strong", "span", "small", "sub", "sup", "a", "br", "u",
    ]

    /// Element `id`s seen since the last emitted block. Carried forward across
    /// empty flushes so an id on a wrapper (`<table id=…>` before any text)
    /// lands on the block that eventually emits.
    private var pendingAnchorIDs: [String] = []

    // MARK: - Marker & Format Tracking (ported from CLI XHTMLContentParser)
    private var currentCharOffset = 0
    private var pendingFormatStack: [(FormatType, Int)] = []
    private var blockMarkers: [SyncMarker] = []
    private var blockFormats: [TextFormat] = []
    private let captureEchoMetadata: Bool
    private var currentEchoMetadataPresent = false
    private var currentEchoStableSlot: Int?
    private var currentEchoBlockIndex: Int?
    private var currentEchoNarration: String?
    private var currentEchoLinkNarrationValues: [String] = []
    private var isGeneratedImagePlaceholder = false

    init(captureEchoMetadata: Bool = false) {
        self.captureEchoMetadata = captureEchoMetadata
    }

    func parse(_ data: Data) {
        let parser = XMLParser(data: data)
        // Trust boundary: parsing untrusted EPUB input.
        parser.shouldResolveExternalEntities = false
        parser.delegate = self
        currentHTML = ""
        currentText = ""
        if !parser.parse(), pronunciation.hasInstructions {
            pronunciation.fail("Malformed annotated XHTML.")
        }
        flushBlock()
        documentTitle = documentTitle?.collapsedWhitespace()
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        pronunciation.pushNamespaces(attributeDict)
        defer {
            pronunciation.start(
                element: elementName, attributes: attributeDict,
                offset: currentText.count,
                allowed: !isInsideHead && !isInPre && skipDepth == 0 && !isInFigcaption,
                isBlock: blockTags.contains(elementName))
        }
        if elementName == "figcaption", !figureStack.isEmpty, skipDepth == 0 {
            isInFigcaption = true
            return
        }
        if skipTags.contains(elementName) {
            skipDepth += 1
            return
        }
        guard skipDepth == 0 else { return }

        if isInFigcaption {
            insertSoftWordBreakInFigcaptionIfStructural(elementName)
            return
        }

        if elementName == "head" {
            isInsideHead = true
            return
        }
        if elementName == "title" {
            isInsideTitle = true
            return
        }

        if isInPre {
            // Inside <pre>, nested markup contributes characters only — no soft
            // word breaks, no block flushes. <br/> is a real line break; a nested
            // <code class="language-…"> may carry the language hint.
            if elementName == "br" { currentCodeText += "\n" }
            if elementName == "code", currentCodeLanguage == nil {
                currentCodeLanguage = Self.codeLanguage(
                    fromClassAttribute: attributeDict["class"])
            }
            return
        }
        if elementName == "figure" { figureStack.append(FigureContext()) }
        if elementName == "pre" {
            flushBlock()
            captureAnchorID(attributeDict["id"])
            captureEchoAttributes(attributeDict)
            isInPre = true
            currentCodeText = ""
            let classLanguage = Self.codeLanguage(
                fromClassAttribute: attributeDict["class"])
            currentCodeLanguage =
                captureEchoMetadata
                ? attributeDict["data-code-language"] ?? classLanguage
                : classLanguage
            return
        }

        insertSoftWordBreakIfStructural(elementName)

        // Capture the element id for TOC fragment resolution. Tags that flush
        // the current block (headings, images, block tags) capture *after*
        // flushing so the id lands on the block they open, not the one they
        // close; everything else (table, td, inline tags, …) captures now.
        let anchorID = attributeDict["id"]
        let flushesBlock = elementName == "img" || blockTags.contains(elementName)
        if !flushesBlock { captureAnchorID(anchorID) }

        if captureEchoMetadata, elementName == "hr", hasEchoAttributes(attributeDict) {
            flushBlock()
            captureAnchorID(anchorID)
            captureEchoAttributes(attributeDict)
            textBlocks.append(
                TextBlockDescriptor(
                    kind: .paragraph,
                    text: nil,
                    imagePath: nil,
                    htmlContent: nil,
                    rawTags: "hr",
                    anchorIDs: pendingAnchorIDs,
                    echoMetadataPresent: currentEchoMetadataPresent,
                    echoStableSlot: currentEchoStableSlot,
                    echoBlockIndex: currentEchoBlockIndex,
                    echoNarration: currentEchoNarration
                ))
            pendingAnchorIDs = []
            resetEchoAttributes()
            return
        }
        if captureEchoMetadata, elementName == "span", hasEchoAttributes(attributeDict) {
            flushBlock()
            captureAnchorID(anchorID)
            captureEchoAttributes(attributeDict)
            currentBlockTags = "span"
            currentBlockClasses = (attributeDict["class"] ?? "").split(separator: " ").map(
                String.init)
            isGeneratedImagePlaceholder = true
            return
        }

        if ["h1", "h2", "h3", "h4", "h5", "h6"].contains(elementName) {
            flushBlock()
            captureAnchorID(anchorID)
            captureEchoAttributes(attributeDict)
            isInHeading = true
            isInBlock = true
            currentHeading = ""
            currentHTML = ""
            currentBlockTags = elementName
            currentBlockClasses = (attributeDict["class"] ?? "").split(separator: " ").map(
                String.init)
        } else if elementName == "img", let src = attributeDict["src"] {
            flushBlock()
            captureAnchorID(anchorID)
            captureEchoAttributes(attributeDict)
            let marker = SyncMarker(type: .image, payload: src, epubCharOffset: currentCharOffset)
            textBlocks.append(
                TextBlockDescriptor(
                    kind: .image,
                    text: attributeDict["alt"].flatMap {
                        let value = $0.collapsedWhitespace()
                        return value.isEmpty ? nil : value
                    },
                    imagePath: src,
                    htmlContent: nil,
                    markers: [marker],
                    rawClasses: (attributeDict["class"] ?? "").split(separator: " ").map(
                        String.init),
                    rawTags: "img",
                    anchorIDs: pendingAnchorIDs,
                    echoMetadataPresent: currentEchoMetadataPresent,
                    echoStableSlot: currentEchoStableSlot,
                    echoBlockIndex: currentEchoBlockIndex,
                    echoNarration: currentEchoNarration
                ))
            pendingAnchorIDs = []
            resetEchoAttributes()
            if !figureStack.isEmpty {
                figureStack[figureStack.count - 1].imageBlockIndices.append(
                    textBlocks.count - 1)
            }
        } else if blockTags.contains(elementName) {
            flushBlock()
            captureAnchorID(anchorID)
            captureEchoAttributes(attributeDict)
            isInBlock = true
            currentHTML = ""
            currentBlockTags = elementName
            currentBlockClasses = (attributeDict["class"] ?? "").split(separator: " ").map(
                String.init)
            if elementName == "blockquote" {
                blockquoteDepth += 1
                currentBlockHasBlockquote = true
            }
        } else if elementName == "a", let href = attributeDict["href"] {
            let marker = SyncMarker(
                type: .hyperlink, payload: href, epubCharOffset: currentCharOffset)
            blockMarkers.append(marker)
            if captureEchoMetadata, currentEchoMetadataPresent,
                let narration = attributeDict["data-echo-narration"]
            {
                currentEchoLinkNarrationValues.append(narration)
            }
        } else if elementName == "hr" {
            let marker = SyncMarker(
                type: .horizontalRule, payload: "", epubCharOffset: currentCharOffset)
            blockMarkers.append(marker)
        } else if inlineTags.contains(elementName) {
            var tag = "<\(elementName)"
            for (key, value) in attributeDict {
                tag += " \(key)=\"\(value)\""
            }
            tag += ">"
            currentHTML += tag
            inlineDepth += 1
            // Track format start position for TextFormat emission
            let formatType: FormatType?
            switch elementName {
            case "b", "strong": formatType = .bold
            case "i", "em": formatType = .italic
            case "u": formatType = .underline
            default: formatType = nil
            }
            if let ft = formatType {
                pendingFormatStack.append((ft, currentCharOffset))
            }
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard skipDepth == 0 else { return }

        if isInsideTitle {
            let docTitle = documentTitle ?? ""
            documentTitle = docTitle + string
            return
        }
        if isInsideHead { return }  // ignore all other text in head

        if isInFigcaption {
            let figureIndex = figureStack.count - 1
            appendCollapsed(string, to: &figureStack[figureIndex].captionText)
            return
        }
        if isInPre {
            currentCodeText += string  // raw — indentation and newlines are content
            return
        }

        if isInHeading { appendCollapsed(string, to: &currentHeading) }
        currentCharOffset += appendCollapsed(string, to: &currentText)
        if isInBlock || inlineDepth > 0 {
            currentHTML += string
        }
    }

    /// Treats a structural element boundary as a word break.
    ///
    /// XMLParser splits one text node at every entity reference with NO
    /// element events in between, so plain chunk joins must stay
    /// separator-free (`it&#8217;s` → "it's"). But text arriving across an
    /// element boundary is a different case: `<td>Topic 3</td><td>Software
    /// Entropy</td>` or `<span>Chapter 1</span><br/><span>A Pragmatic
    /// Philosophy</span>` renders as separate words. Non-inline tags and
    /// explicit `<br>` inject a collapsible space; inline formatting tags
    /// must not, because mid-word markup (`<em>un</em>do`) is real.
    private func insertSoftWordBreakIfStructural(_ elementName: String) {
        guard elementName == "br" || !inlineTags.contains(elementName) else { return }
        guard !isInsideHead else { return }
        if isInHeading { appendCollapsed(" ", to: &currentHeading) }
        currentCharOffset += appendCollapsed(" ", to: &currentText)
    }

    private func insertSoftWordBreakInFigcaptionIfStructural(_ elementName: String) {
        guard elementName == "br" || !inlineTags.contains(elementName) else { return }
        let figureIndex = figureStack.count - 1
        appendCollapsed(" ", to: &figureStack[figureIndex].captionText)
    }

    /// Records an element `id` for fragment-target resolution.
    private func captureAnchorID(_ id: String?) {
        guard let id, !id.isEmpty else { return }
        pendingAnchorIDs.append(id)
    }

    /// Appends `chunk` to `target`, collapsing whitespace runs into single
    /// spaces and dropping leading whitespace while `target` is empty.
    ///
    /// XMLParser may deliver one text node as several chunks (it splits at
    /// every entity reference), so chunks must be joined with NO separator —
    /// only whitespace actually present in the source becomes a space.
    /// Returns the number of characters appended so marker/format offsets
    /// stay aligned with the accumulated text.
    @discardableResult
    private func appendCollapsed(_ chunk: String, to target: inout String) -> Int {
        var appended = 0
        for character in chunk {
            if character.isWhitespace {
                if !target.isEmpty && target.last != " " {
                    target.append(" ")
                    appended += 1
                }
            } else {
                target.append(character)
                appended += 1
            }
        }
        return appended
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName: String?
    ) {
        pronunciation.end(element: elementName, text: currentText)
        defer { pronunciation.popNamespaces() }
        if elementName == "figcaption", isInFigcaption {
            isInFigcaption = false
            return
        }
        if skipTags.contains(elementName) {
            skipDepth = max(0, skipDepth - 1)
            return
        }
        guard skipDepth == 0 else { return }

        if isInFigcaption {
            insertSoftWordBreakInFigcaptionIfStructural(elementName)
            return
        }

        if isInPre {
            if elementName == "pre" {
                isInPre = false
                emitCodeBlock()
            }
            return  // ignore inner closes (span/code) while in pre
        }
        if elementName == "figure" {
            attachFigcaptionToPendingCodeBlocks()
            // fall through: figure was always transparent; keep the soft word
            // break below by NOT returning here.
        }

        if elementName == "head" {
            isInsideHead = false
            return
        }
        if elementName == "title" {
            isInsideTitle = false
            return
        }

        insertSoftWordBreakIfStructural(elementName)

        if elementName == "span", isGeneratedImagePlaceholder {
            isGeneratedImagePlaceholder = false
            textBlocks.append(
                TextBlockDescriptor(
                    kind: .image,
                    text: nil,
                    imagePath: nil,
                    htmlContent: nil,
                    rawClasses: currentBlockClasses,
                    rawTags: currentBlockTags,
                    anchorIDs: pendingAnchorIDs,
                    echoMetadataPresent: currentEchoMetadataPresent,
                    echoStableSlot: currentEchoStableSlot,
                    echoBlockIndex: currentEchoBlockIndex,
                    echoNarration: currentEchoNarration,
                    echoLinkNarrationValues: currentEchoLinkNarrationValues
                ))
            pendingAnchorIDs = []
            currentBlockClasses = []
            currentBlockTags = ""
            resetEchoAttributes()
            return
        }

        // `<a>` is opened as a hyperlink marker only (no HTML, no inlineDepth),
        // so its close must be a no-op — otherwise it emits an orphan `</a>`
        // and desyncs inlineDepth.
        if elementName == "a" { return }

        if elementName == "blockquote" {
            blockquoteDepth = max(0, blockquoteDepth - 1)
            flushBlock()
            return
        }

        if inlineTags.contains(elementName) {
            currentHTML += "</\(elementName)>"
            inlineDepth = max(0, inlineDepth - 1)
            // Finalize any pending format span
            let formatType: FormatType?
            switch elementName {
            case "b", "strong": formatType = .bold
            case "i", "em": formatType = .italic
            case "u": formatType = .underline
            default: formatType = nil
            }
            if let ft = formatType,
                let idx = pendingFormatStack.lastIndex(where: { $0.0 == ft })
            {
                let (_, start) = pendingFormatStack.remove(at: idx)
                let end = max(start, currentCharOffset - 1)
                blockFormats.append(TextFormat(type: ft, range: start...end))
            }
            return
        }

        if ["h1", "h2", "h3", "h4", "h5", "h6"].contains(elementName) {
            isInHeading = false
            isInBlock = false
            let heading = currentHeading.trimmingCharacters(in: .whitespaces)
            let html = currentHTML.trimmingCharacters(in: .whitespaces)
            // Emit chapterStart marker at the heading's position within the block.
            // We store the heading level (e.g. "2" for "h2") in the payload.
            let level = String(elementName.dropFirst())
            let headingMarkers: [SyncMarker] =
                heading.isEmpty
                ? []
                : [
                    SyncMarker(
                        type: .chapterStart, payload: level,
                        epubCharOffset: max(0, currentCharOffset - heading.count - 1))
                ]
            let pronunciationSpans = pronunciation.flush(text: currentText)
            currentText = ""
            currentHTML = ""
            if !heading.isEmpty {
                textBlocks.append(
                    TextBlockDescriptor(
                        kind: .heading,
                        text: heading,
                        imagePath: nil,
                        htmlContent: html.isEmpty ? nil : html,
                        markers: headingMarkers,
                        textFormats: [],
                        rawClasses: currentBlockClasses,
                        rawTags: currentBlockTags,
                        anchorIDs: pendingAnchorIDs,
                        echoMetadataPresent: currentEchoMetadataPresent,
                        echoStableSlot: currentEchoStableSlot,
                        echoBlockIndex: currentEchoBlockIndex,
                        echoNarration: currentEchoNarration,
                        echoLinkNarrationValues: currentEchoLinkNarrationValues
                    ))
                if !heading.isEmpty, !textBlocks.isEmpty {
                    textBlocks[textBlocks.count - 1].pronunciationSpans = pronunciationSpans
                }
                pendingAnchorIDs = []
            }
            resetEchoAttributes()
        }
    }

    private func flushBlock() {
        let pronunciationSpans = pronunciation.flush(text: currentText)
        let text = currentText.trimmingCharacters(in: .whitespaces)
        let html = currentHTML.trimmingCharacters(in: .whitespaces)
        currentText = ""
        currentHTML = ""
        isInBlock = false
        guard !text.isEmpty else {
            // Even if no text, reset per-block accumulation state
            blockMarkers = []
            blockFormats = []
            currentCharOffset = 0
            if !currentEchoMetadataPresent {
                resetEchoAttributes()
            }
            return
        }
        let markers =
            blockMarkers
            + (currentBlockHasBlockquote
                ? [SyncMarker(type: .blockquote, payload: "", epubCharOffset: 0)]
                : [])
        let formats = blockFormats
        blockMarkers = []
        blockFormats = []
        currentCharOffset = 0
        if blockquoteDepth == 0 {
            currentBlockHasBlockquote = false
        }
        let classes = currentBlockClasses
        let tags = currentBlockTags
        currentBlockClasses = []
        currentBlockTags = ""
        textBlocks.append(
            TextBlockDescriptor(
                kind: .paragraph,
                text: text,
                imagePath: nil,
                htmlContent: html.isEmpty ? nil : html,
                markers: markers,
                textFormats: formats,
                rawClasses: classes,
                rawTags: tags,
                anchorIDs: pendingAnchorIDs,
                echoMetadataPresent: currentEchoMetadataPresent,
                echoStableSlot: currentEchoStableSlot,
                echoBlockIndex: currentEchoBlockIndex,
                echoNarration: currentEchoNarration,
                echoLinkNarrationValues: currentEchoLinkNarrationValues
            ))
        textBlocks[textBlocks.count - 1].pronunciationSpans = pronunciationSpans
        pendingAnchorIDs = []
        resetEchoAttributes()
    }

    /// Emits the accumulated <pre> content as a `.code` descriptor. Leading and
    /// trailing blank lines are dropped; internal indentation is preserved.
    private func emitCodeBlock() {
        let lines = currentCodeText.components(separatedBy: "\n")
        let isBlank: (String) -> Bool = {
            $0.trimmingCharacters(in: .whitespaces).isEmpty
        }
        let trimmed = Array(
            lines.drop(while: isBlank).reversed().drop(while: isBlank).reversed())
        let code = trimmed.joined(separator: "\n")
        currentCodeText = ""
        let language = currentCodeLanguage
        currentCodeLanguage = nil
        guard !code.isEmpty else { return }
        textBlocks.append(
            TextBlockDescriptor(
                kind: .code,
                text: code,
                imagePath: nil,
                htmlContent: nil,
                rawTags: "pre",
                anchorIDs: pendingAnchorIDs,
                narrationCue: "Code listing.",
                codeLanguage: language,
                echoMetadataPresent: currentEchoMetadataPresent,
                echoStableSlot: currentEchoStableSlot,
                echoBlockIndex: currentEchoBlockIndex,
                echoNarration: currentEchoNarration,
                echoLinkNarrationValues: currentEchoLinkNarrationValues
            ))
        pendingAnchorIDs = []
        resetEchoAttributes()
        if !figureStack.isEmpty {
            figureStack[figureStack.count - 1].codeBlockIndices.append(textBlocks.count - 1)
        }
    }

    /// At </figure>, a captured <figcaption> becomes the spoken cue for the
    /// figure's code blocks (handles caption-before-pre and caption-after-pre).
    private func attachFigcaptionToPendingCodeBlocks() {
        guard let figure = figureStack.popLast() else { return }
        let caption = figure.captionText.trimmingCharacters(in: .whitespaces)
        if !caption.isEmpty {
            for index in figure.codeBlockIndices {
                textBlocks[index].narrationCue = caption
            }
            for index in figure.imageBlockIndices {
                textBlocks[index].text = caption
            }
        }
    }

    /// "language-python" / "lang-rb" / "brush:swift" → "python"/"rb"/"swift".
    static func codeLanguage(fromClassAttribute classAttr: String?) -> String? {
        guard let classAttr else { return nil }
        let classes = classAttr.lowercased().split(whereSeparator: { $0.isWhitespace })

        func languageValue(_ rawValue: Substring) -> String? {
            let value = String(rawValue).trimmingCharacters(
                in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ";"))
            )
            return value.isEmpty ? nil : value
        }

        for (index, cls) in classes.enumerated() {
            for prefix in ["language-", "lang-"] where cls.hasPrefix(prefix) {
                if let value = languageValue(cls.dropFirst(prefix.count)) { return value }
            }
            if cls.hasPrefix("brush:") {
                if let value = languageValue(cls.dropFirst("brush:".count)) { return value }
                if index + 1 < classes.count, let value = languageValue(classes[index + 1]) {
                    return value
                }
            }
        }
        return nil
    }

    private func hasEchoAttributes(_ attributes: [String: String]) -> Bool {
        attributes["data-echo-stable-slot"] != nil
            || attributes["data-echo-block-index"] != nil
    }

    private func captureEchoAttributes(_ attributes: [String: String]) {
        guard captureEchoMetadata else { return }
        currentEchoMetadataPresent = hasEchoAttributes(attributes)
        currentEchoStableSlot = attributes["data-echo-stable-slot"].flatMap(Int.init)
        currentEchoBlockIndex = attributes["data-echo-block-index"].flatMap(Int.init)
        currentEchoNarration = attributes["data-echo-narration"]
        currentEchoLinkNarrationValues = []
    }

    private func resetEchoAttributes() {
        currentEchoMetadataPresent = false
        currentEchoStableSlot = nil
        currentEchoBlockIndex = nil
        currentEchoNarration = nil
        currentEchoLinkNarrationValues = []
    }
}

// MARK: - Convenience Helpers

/// Parse `META-INF/container.xml` data and return the OPF path, or `nil`.
nonisolated func parseContainerXML(from data: Data) -> String? {
    let parser = ContainerXMLParser()
    parser.parse(data)
    return parser.rootfilePath
}

/// Parse OPF data and return spine items in EPUB reading order, the optional
/// TOC href, and any `<guide>` references.
nonisolated func parseOPF(from data: Data) -> OPFParseResult {
    let parser = OPFParserDelegate()
    parser.parse(data)
    return OPFParseResult(
        spine: parser.spineItems,
        tocHref: parser.tocHref,
        guideReferences: parser.guideReferences,
        packageIdentifier: parser.packageIdentifier,
        echoManifestSHA256: parser.echoManifestSHA256
    )
}

/// Parse XHTML data into an array of text / image block descriptors and the document title if available.
nonisolated func parseXHTML(
    from data: Data,
    captureEchoMetadata: Bool = false
) -> (blocks: [TextBlockDescriptor], title: String?) {
    let parser = XHTMLBlockDelegate(captureEchoMetadata: captureEchoMetadata)
    parser.parse(data)
    return (parser.textBlocks, parser.documentTitle)
}

// MARK: - Streaming Helper

/// Concatenates blocks from a spine item into a single text stream,
/// adjusting marker character offsets to be relative to the concatenated
/// result. For CLI-style sliding-window alignment consumers.
///
/// - Parameter blocks: Ordered `TextBlockDescriptor` values from one spine item.
/// - Returns: A tuple of concatenated raw text, offset-adjusted markers,
///   and offset-adjusted text formats.
nonisolated func concatenateBlocks(
    _ blocks: [TextBlockDescriptor]
) -> (rawText: String, markers: [SyncMarker], formats: [TextFormat]) {
    var rawText = ""
    var allMarkers: [SyncMarker] = []
    var allFormats: [TextFormat] = []

    for block in blocks {
        guard let text = block.text, !text.isEmpty else { continue }
        let baseOffset = rawText.count

        // Append block text with a space separator
        if !rawText.isEmpty { rawText += " " }
        rawText += text

        // Rebase marker offsets
        for marker in block.markers {
            allMarkers.append(
                SyncMarker(
                    type: marker.type,
                    payload: marker.payload,
                    epubCharOffset: marker.epubCharOffset + baseOffset
                ))
        }

        // Rebase format ranges
        for format in block.textFormats {
            allFormats.append(
                TextFormat(
                    type: format.type,
                    range: (format.range.lowerBound + baseOffset)...(format.range.upperBound
                        + baseOffset)
                ))
        }
    }

    return (rawText, allMarkers, allFormats)
}
