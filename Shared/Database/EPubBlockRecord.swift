// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB
import os.log

/// A parsed EPUB block — heading, paragraph, sentence, image, or code — extracted
/// from XHTML spine items and stored in structural reading order.
nonisolated struct EPubBlockRecord: Identifiable, Equatable, Hashable, Sendable, Codable,
    FetchableRecord, MutablePersistableRecord
{
    var id: String
    var audiobookID: String
    var spineHref: String
    var spineIndex: Int
    var blockIndex: Int
    var sequenceIndex: Int
    var blockKind: String
    var text: String?
    var htmlContent: String?
    var cardColor: String?
    var chapterThemeColor: String?
    var imagePath: String?
    var chapterIndex: Int?
    var isHidden: Bool
    var hiddenReason: String?
    /// `true` for blocks in front-matter spine items (cover, praise pages,
    /// printed TOC, …) classified during import from EPUB structural metadata.
    var isFrontMatter: Bool = false
    var wordCount: Int?
    var markers: String?  // JSON-encoded [SyncMarker]
    var textFormats: String?  // JSON-encoded [TextFormat]
    /// FM-normalized text for TTS rendering. Null → use original `text`.
    var narrationText: String?
    /// Language hint for `.code` blocks ("python", "swift", …), sniffed from
    /// markup at import. Nil for non-code blocks or unhinted listings.
    var codeLanguage: String?
    /// Trusted source chapter identity for generated anthologies. Generic EPUB
    /// imports leave this nil and retain their order-based identity.
    var sourceChapterKey: String? = nil
    var pronunciationAnnotations: String? = nil
    var createdAt: String?
    var modifiedAt: String?

    static let databaseTableName = "epub_block"

    enum CodingKeys: String, CodingKey {
        case id
        case audiobookID = "audiobook_id"
        case spineHref = "spine_href"
        case spineIndex = "spine_index"
        case blockIndex = "block_index"
        case sequenceIndex = "sequence_index"
        case blockKind = "block_kind"
        case text
        case htmlContent = "html_content"
        case cardColor = "card_color"
        case chapterThemeColor = "chapter_theme_color"
        case imagePath = "image_path"
        case chapterIndex = "chapter_index"
        case isHidden = "is_hidden"
        case hiddenReason = "hidden_reason"
        case isFrontMatter = "is_front_matter"
        case wordCount = "word_count"
        case markers
        case textFormats = "text_formats"
        case narrationText = "narration_text"
        case codeLanguage = "code_language"
        case sourceChapterKey = "source_chapter_key"
        case pronunciationAnnotations = "pronunciation_annotations"
        case createdAt = "created_at"
        case modifiedAt = "modified_at"
    }
}

extension EPubBlockRecord {
    private static let logger = Logger(category: "EPubBlockRecord")

    struct JSONDecodingFailure: Error, CustomStringConvertible, LocalizedError, Sendable {
        let column: String
        let blockID: String
        let audiobookID: String
        let spineHref: String
        let blockIndex: Int
        let underlyingDescription: String

        var description: String {
            """
            Failed to decode \(column) JSON for EPUB block \(blockID) \
            in audiobook \(audiobookID), spine \(spineHref), block index \(blockIndex): \
            \(underlyingDescription)
            """
        }

        var errorDescription: String? { description }
    }

    /// Block kind constants used in the `block_kind` column.
    enum Kind: String {
        case heading
        case paragraph
        case sentence
        case image
        case code
    }

    /// Encode markers to JSON for database storage.
    /// Returns nil for empty arrays to keep storage clean.
    static func encodeMarkers(_ markers: [SyncMarker]) -> String? {
        guard !markers.isEmpty else { return nil }
        return encodeJSONColumn(markers, column: "markers")
    }

    /// Encode text formats to JSON for database storage.
    /// Returns nil for empty arrays to keep storage clean.
    static func encodeFormats(_ formats: [TextFormat]) -> String? {
        guard !formats.isEmpty else { return nil }
        return encodeJSONColumn(formats, column: "text_formats")
    }

    /// Decode markers from the JSON column. Returns empty only when the optional
    /// column is absent; malformed persisted JSON throws with row context.
    func decodeMarkers() throws -> [SyncMarker] {
        try decodeJSONColumn(markers, column: "markers", as: [SyncMarker].self, absentValue: [])
    }

    /// Decode text formats from the JSON column. Returns empty only when the
    /// optional column is absent; malformed persisted JSON throws with row context.
    func decodeFormats() throws -> [TextFormat] {
        try decodeJSONColumn(
            textFormats, column: "text_formats", as: [TextFormat].self, absentValue: [])
    }

    private func decodeJSONColumn<Value: Decodable>(
        _ json: String?,
        column: String,
        as type: Value.Type,
        absentValue: @autoclosure () -> Value
    ) throws -> Value {
        guard let json else { return absentValue() }

        do {
            return try JSONDecoder().decode(type, from: Data(json.utf8))
        } catch {
            let failure = JSONDecodingFailure(
                column: column,
                blockID: id,
                audiobookID: audiobookID,
                spineHref: spineHref,
                blockIndex: blockIndex,
                underlyingDescription: String(describing: error)
            )
            Self.logJSONDecodingFailure(failure)
            throw failure
        }
    }

    private static func encodeJSONColumn<Value: Encodable>(_ value: Value, column: String)
        -> String?
    {
        do {
            let data = try JSONEncoder().encode(value)
            guard let json = String(data: data, encoding: .utf8) else {
                logger.error(
                    "Failed to encode EPUB JSON column \(column, privacy: .public): encoded data was not valid UTF-8"
                )
                return nil
            }
            return json
        } catch {
            logger.error(
                "Failed to encode EPUB JSON column \(column, privacy: .public): \(String(describing: error), privacy: .private)"
            )
            return nil
        }
    }

    private static func logJSONDecodingFailure(_ failure: JSONDecodingFailure) {
        logger.error(
            """
            Failed to decode persisted EPUB JSON column \(failure.column, privacy: .public) \
            for block \(failure.blockID, privacy: .private) \
            audiobook \(failure.audiobookID, privacy: .private) \
            spine \(failure.spineHref, privacy: .private) \
            blockIndex \(failure.blockIndex, privacy: .public): \
            \(failure.underlyingDescription, privacy: .private)
            """
        )
    }
}
