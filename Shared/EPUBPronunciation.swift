// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Imported speech instructions address Unicode characters in the original,
/// whitespace-collapsed block, never a rewritten or phonetic display string.
nonisolated struct EPUBPronunciationSpan: Codable, Equatable, Hashable, Sendable {
    enum Source: String, Codable, Sendable { case inline, lexicon }
    let start: Int
    let end: Int
    let text: String
    let ipa: String
    let source: Source
}

nonisolated struct EPUBPronunciationError: LocalizedError, Equatable {
    let detail: String
    var errorDescription: String? { "EPUB pronunciation: \(detail)" }
}

/// Versioned, deliberately bounded English IPA contract. Reject unsupported
/// symbols rather than using the vocabulary's lossy encoder.
nonisolated enum EPUBPronunciationIPA {
    static func normalize(_ input: String) throws -> String {
        var value = input.precomposedStringWithCanonicalMapping
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !value.isEmpty, value.count <= 300 else {
            throw EPUBPronunciationError(detail: "IPA must contain 1–300 characters.")
        }
        for (standard, kokoro) in [
            ("t͡ʃ", "ʧ"), ("t͜ʃ", "ʧ"), ("d͡ʒ", "ʤ"), ("d͜ʒ", "ʤ"),
            ("tʃ", "ʧ"), ("dʒ", "ʤ"), ("aɪ", "I"), ("aʊ", "W"),
            ("eɪ", "A"), ("oʊ", "O"), ("ɔɪ", "Y"), ("g", "ɡ"), ("ɝ", "ɜɹ"),
            ("ɾ", "T"), ("ʔ", "t"),
        ] { value = value.replacingOccurrences(of: standard, with: kokoro) }
        let allowed = Set(" abdefhijklmnoprstuvwzæɑɒɔəɚɛɜɡɪŋθðɹʃʊʌʒʧʤˈˌːAIWOYT")
        // Internal shorthand is generated above, never accepted from authors.
        guard !input.contains(where: { "AIWOYT".contains($0) }),
            value.allSatisfy({ allowed.contains($0) }),
            value.contains(where: { $0.isLetter && !"ˈˌː".contains($0) })
        else {
            throw EPUBPronunciationError(
                detail: "Unsupported IPA notation or symbol in annotation: \(input)")
        }
        return value
    }
}

nonisolated enum EPUBPronunciationStorage {
    static func encode(_ spans: [EPUBPronunciationSpan]) throws -> String? {
        guard !spans.isEmpty else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(spans), as: UTF8.self)
    }

    static func decode(_ json: String?) throws -> [EPUBPronunciationSpan] {
        guard let json else { return [] }
        do {
            return try JSONDecoder().decode([EPUBPronunciationSpan].self, from: Data(json.utf8))
        } catch {
            throw EPUBPronunciationError(detail: "Corrupt persisted pronunciation annotations.")
        }
    }
}

/// Used by the canonical streaming XHTML parser so character/entity/whitespace
/// handling is identical for display text and annotation positions.
nonisolated final class EPUBInlinePronunciationTracker {
    private var namespaces: [[String: String]] = []
    private var alphabets: [String?] = []
    private var active: (depth: Int, start: Int, ipa: String)?
    private var spans: [EPUBPronunciationSpan] = []
    private(set) var links: [String] = []
    private(set) var error: EPUBPronunciationError?
    private(set) var hasInstructions = false
    private let ssml = "http://www.w3.org/2001/10/synthesis"

    func fail(_ detail: String) {
        if error == nil { error = EPUBPronunciationError(detail: detail) }
    }

    func pushNamespaces(_ attributes: [String: String]) {
        var bindings = namespaces.last ?? [:]
        for (key, value) in attributes where key.hasPrefix("xmlns:") {
            bindings[String(key.dropFirst(6))] = value
        }
        namespaces.append(bindings)
        alphabets.append(attribute("alphabet", in: attributes) ?? alphabets.last.flatMap { $0 })
    }

    func popNamespaces() {
        _ = namespaces.popLast()
        _ = alphabets.popLast()
    }

    private func attribute(_ name: String, in attributes: [String: String]) -> String? {
        attributes.first { key, _ in
            let parts = key.split(separator: ":", maxSplits: 1)
            return parts.count == 2 && parts[1] == name
                && namespaces.last?[String(parts[0])] == ssml
        }?.value
    }

    func start(
        element: String, attributes: [String: String], offset: Int, allowed: Bool, isBlock: Bool
    ) {
        if element == "link",
            attributes["rel"]?.split(separator: " ").contains("pronunciation") == true
        {
            hasInstructions = true
            guard attributes["type"] == "application/pls+xml", let href = attributes["href"],
                !href.isEmpty
            else {
                fail("Pronunciation links require type application/pls+xml and a local href.")
                return
            }
            links.append(href)
        }
        if attributes["ssml:ph"] != nil && namespaces.last?["ssml"] != ssml {
            hasInstructions = true
            fail("ssml:ph requires the SSML namespace http://www.w3.org/2001/10/synthesis.")
        }
        guard let ph = attribute("ph", in: attributes) else { return }
        hasInstructions = true
        guard allowed, element != "img", element != "br", element != "hr" else {
            fail("Pronunciation annotations require spoken text, outside head, code and captions.")
            return
        }
        guard active == nil else {
            fail("Nested pronunciation annotations are unsupported.")
            return
        }
        guard alphabets.last.flatMap({ $0 }) == "ipa" else {
            fail(
                "Pronunciation annotations require ssml:alphabet=ipa on the element or an ancestor."
            )
            return
        }
        do { active = (namespaces.count, offset, try EPUBPronunciationIPA.normalize(ph)) } catch {
            fail(error.localizedDescription)
        }
    }

    func end(element: String, text: String) {
        guard let current = active, current.depth == namespaces.count else { return }
        active = nil
        guard current.start <= text.count else {
            fail("Annotation crosses a block boundary.")
            return
        }
        let suffix = String(text.dropFirst(current.start))
        let display = suffix.trimmingCharacters(in: .whitespacesAndNewlines)
        let leading = suffix.prefix(while: \.isWhitespace).count
        guard !display.isEmpty, !display.contains(where: { "[]()/".contains($0) }) else {
            fail("Annotated text is empty or contains reserved pronunciation markup characters.")
            return
        }
        spans.append(
            .init(
                start: current.start + leading, end: current.start + leading + display.count,
                text: display, ipa: current.ipa, source: .inline))
    }

    func flush(text: String) -> [EPUBPronunciationSpan] {
        if active != nil {
            fail("A pronunciation annotation cannot cross imported block boundaries.")
        }
        let leading = text.prefix(while: \.isWhitespace).count
        let result = spans.map {
            EPUBPronunciationSpan(
                start: $0.start - leading, end: $0.end - leading,
                text: $0.text, ipa: $0.ipa, source: $0.source)
        }
        spans = []
        return result
    }
}

/// Strict supported PLS subset: one IPA phoneme and one or more graphemes per
/// lexeme. Reject ambiguous variants, aliases and roles instead of guessing.
nonisolated final class EPUBPLSParser: NSObject, XMLParserDelegate {
    private var stack: [String] = []
    private var graphemes: [String] = []
    private var phonemes: [String] = []
    private var buffer = ""
    private var entries: [String: String] = [:]
    private var failure: String?
    private var sawRoot = false

    static func parse(_ data: Data) throws -> [String: String] {
        guard data.count <= 1_048_576 else {
            throw EPUBPronunciationError(detail: "PLS exceeds 1 MiB.")
        }
        guard let xml = String(data: data, encoding: .utf8), !xml.contains("\0"),
            !xml.contains("<!DOCTYPE"), !xml.contains("<!ENTITY")
        else {
            throw EPUBPronunciationError(
                detail: "PLS must be UTF-8 without DTDs or entity declarations.")
        }
        let delegate = EPUBPLSParser()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        guard parser.parse(), delegate.failure == nil, delegate.sawRoot else {
            throw EPUBPronunciationError(detail: delegate.failure ?? "Malformed PLS XML.")
        }
        return delegate.entries
    }

    func parser(
        _ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
        qualifiedName: String?, attributes: [String: String]
    ) {
        guard namespaceURI == "http://www.w3.org/2005/01/pronunciation-lexicon" else {
            failure = "PLS elements require the pronunciation-lexicon namespace."
            parser.abortParsing()
            return
        }
        let parent = stack.last
        switch name {
        case "lexicon" where parent == nil && !sawRoot:
            sawRoot = true
            guard attributes["version"] == "1.0", attributes["alphabet"] == "ipa",
                let language = attributes["xml:lang"], language == "en" || language.hasPrefix("en-")
            else {
                failure = "PLS requires version 1.0, alphabet ipa, and English xml:lang."
                parser.abortParsing()
                return
            }
        case "lexeme" where parent == "lexicon":
            guard attributes.isEmpty else {
                failure = "PLS lexeme attributes (including role) are unsupported."
                parser.abortParsing()
                return
            }
            graphemes = []
            phonemes = []
        case "grapheme" where parent == "lexeme", "phoneme" where parent == "lexeme":
            guard attributes.isEmpty else {
                failure = "PLS grapheme/phoneme attributes are unsupported."
                parser.abortParsing()
                return
            }
            buffer = ""
        default:
            failure = "Unsupported PLS element or nesting: \(name)."
            parser.abortParsing()
            return
        }
        stack.append(name)
    }

    func parser(_ parser: XMLParser, foundCharacters text: String) { buffer += text }

    func parser(
        _ parser: XMLParser, didEndElement name: String, namespaceURI: String?,
        qualifiedName: String?
    ) {
        if name == "grapheme" {
            graphemes.append(buffer.split(whereSeparator: \.isWhitespace).joined(separator: " "))
        }
        if name == "phoneme" {
            phonemes.append(buffer.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        if name == "lexeme" {
            guard !graphemes.isEmpty, phonemes.count == 1 else {
                failure = "Each PLS lexeme requires grapheme(s) and exactly one phoneme."
                parser.abortParsing()
                return
            }
            do {
                let ipa = try EPUBPronunciationIPA.normalize(phonemes[0])
                for word in graphemes {
                    guard !word.isEmpty, word.count <= 200,
                        !word.contains(where: { "[]()/".contains($0) }),
                        entries[word] == nil || entries[word] == ipa
                    else {
                        throw EPUBPronunciationError(
                            detail: "Invalid or conflicting PLS grapheme: \(word)")
                    }
                    entries[word] = ipa
                }
            } catch {
                failure = error.localizedDescription
                parser.abortParsing()
            }
        }
        _ = stack.popLast()
        buffer = ""
    }
}

nonisolated enum EPUBPronunciationImport {
    static func localURL(_ href: String, relativeTo directory: URL, root: URL) throws -> URL {
        guard let components = URLComponents(string: href), components.scheme == nil,
            components.host == nil, components.query == nil, components.fragment == nil,
            let path = href.removingPercentEncoding, !path.hasPrefix("/"), !path.contains("\\")
        else {
            throw EPUBPronunciationError(
                detail: "PLS href must be a local relative path without query or fragment.")
        }
        let result = directory.appendingPathComponent(path).standardizedFileURL
            .resolvingSymlinksInPath()
        let safeRoot = root.standardizedFileURL.resolvingSymlinksInPath().path + "/"
        guard result.path.hasPrefix(safeRoot) else {
            throw EPUBPronunciationError(detail: "PLS href escapes the EPUB container.")
        }
        return result
    }

    static func applyLexicons(
        _ links: [String], to blocks: inout [TextBlockDescriptor],
        xhtmlURL: URL, root: URL, declaredURLs: Set<URL>
    ) throws {
        var entries: [String: String] = [:]
        guard links.count <= 32 else {
            throw EPUBPronunciationError(detail: "At most 32 PLS links per document are supported.")
        }
        for href in links {
            let url = try localURL(
                href, relativeTo: xhtmlURL.deletingLastPathComponent(), root: root)
            guard declaredURLs.contains(url) else {
                throw EPUBPronunciationError(
                    detail:
                        "PLS link \(href) must be declared in the OPF manifest as application/pls+xml."
                )
            }
            let data: Data
            do {
                let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size <= 1_048_576 else {
                    throw EPUBPronunciationError(detail: "PLS exceeds 1 MiB.")
                }
                let file = try FileHandle(forReadingFrom: url)
                defer { try? file.close() }
                data = try file.read(upToCount: 1_048_577) ?? Data()
            } catch { throw EPUBPronunciationError(detail: "Cannot read bundled PLS: \(href)") }
            for (word, ipa) in try EPUBPLSParser.parse(data) {
                guard entries[word] == nil || entries[word] == ipa else {
                    throw EPUBPronunciationError(
                        detail: "Conflicting linked PLS pronunciations for \(word).")
                }
                entries[word] = ipa
            }
        }
        let ordered = entries.keys.sorted { $0.count == $1.count ? $0 < $1 : $0.count > $1.count }
        guard !ordered.isEmpty else { return }
        let alternatives = ordered.map(NSRegularExpression.escapedPattern(for:)).joined(
            separator: "|")
        let pattern = "(?<![\\p{L}\\p{N}_’'])(?:" + alternatives + ")(?![\\p{L}\\p{N}_’'])"
        let regex = try NSRegularExpression(pattern: pattern)
        for index in blocks.indices {
            guard blocks[index].kind != .code, blocks[index].kind != .image,
                let text = blocks[index].text
            else { continue }
            var spans = blocks[index].pronunciationSpans
            for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                guard let range = Range(match.range, in: text) else { continue }
                let start = text.distance(from: text.startIndex, to: range.lowerBound)
                let end = text.distance(from: text.startIndex, to: range.upperBound)
                if spans.contains(where: { $0.start < end && start < $0.end }) { continue }
                let word = String(text[range])
                spans.append(
                    .init(start: start, end: end, text: word, ipa: entries[word]!, source: .lexicon)
                )
            }
            blocks[index].pronunciationSpans = spans.sorted { $0.start < $1.start }
        }
    }
}
