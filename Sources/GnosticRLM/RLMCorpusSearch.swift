// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

/// One ranked lexical match over a committed corpus snapshot.
public struct RLMSearchHit: Sendable, Equatable {
    public let chunkID: String
    public let path: String
    public let startLine: Int
    public let endLine: Int
    public let preview: String
    public let score: Int

    public init(
        chunkID: String,
        path: String,
        startLine: Int,
        endLine: Int,
        preview: String,
        score: Int
    ) {
        self.chunkID = chunkID
        self.path = path
        self.startLine = startLine
        self.endLine = endLine
        self.preview = preview
        self.score = score
    }
}

/// Deterministic lexical search over the chunks of a committed snapshot.
public enum RLMCorpusSearch {
    /// Returns up to `limit` hits, ranked by match count, then path, then start line.
    public static func search(
        snapshot: RLMCorpusSnapshot,
        query: String,
        limit: Int
    ) -> [RLMSearchHit] {
        guard limit > 0 else { return [] }
        let tokens = query.lowercased().split { character in
            !character.isLetter && !character.isNumber && character != "_"
        }.map(String.init)
        guard !tokens.isEmpty else { return [] }

        var ranked: [(score: Int, hit: RLMSearchHit)] = []
        for chunk in snapshot.chunks {
            let lowered = chunk.content.lowercased()
            var score = 0
            var previewLine: String?
            for token in tokens {
                score += occurrences(of: token, in: lowered)
                if previewLine == nil {
                    previewLine = firstLine(containing: token, in: chunk.content)
                }
            }
            guard score > 0 else { continue }
            let previewSource = previewLine ?? firstLine(of: chunk.content) ?? ""
            let hit = RLMSearchHit(
                chunkID: chunk.id,
                path: chunk.path,
                startLine: chunk.startLine,
                endLine: chunk.endLine,
                preview: String(previewSource.prefix(160)),
                score: score
            )
            ranked.append((score, hit))
        }

        ranked.sort { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            if lhs.hit.path != rhs.hit.path { return lhs.hit.path < rhs.hit.path }
            return lhs.hit.startLine < rhs.hit.startLine
        }
        return ranked.prefix(limit).map(\.hit)
    }

    private static func occurrences(of needle: String, in haystack: String) -> Int {
        let needleCharacters = Array(needle)
        guard !needleCharacters.isEmpty else { return 0 }
        let haystackCharacters = Array(haystack)
        guard haystackCharacters.count >= needleCharacters.count else { return 0 }

        var count = 0
        var index = 0
        while index <= haystackCharacters.count - needleCharacters.count {
            var matched = true
            for offset in 0..<needleCharacters.count where haystackCharacters[index + offset] != needleCharacters[offset] {
                matched = false
                break
            }
            if matched {
                count += 1
                index += needleCharacters.count
            } else {
                index += 1
            }
        }
        return count
    }

    private static func firstLine(containing needle: String, in content: String) -> String? {
        for line in content.split(separator: "\n", omittingEmptySubsequences: false)
        where occurrences(of: needle, in: line.lowercased()) > 0 {
            return String(line)
        }
        return nil
    }

    private static func firstLine(of content: String) -> String? {
        content.split(separator: "\n", omittingEmptySubsequences: false).first.map(String.init)
    }
}
