//
//  SigLIP2Tokenizer.swift
//  RPhoto
//
//  SentencePiece-style BPE tokenizer for SigLIP2 (Gemma tokenizer).
//  Loads vocabulary and merge rules extracted from the HuggingFace tokenizer.json.
//

import Foundation

class SigLIP2Tokenizer: TextTokenizer {

    let contextLength = 64

    /// EOS token appended after content tokens.
    private let eosTokenId = 1

    /// SentencePiece space marker (U+2581 LOWER ONE EIGHTH BLOCK).
    private static let spMarker: Character = "\u{2581}"
    private static let spMarkerStr: String = "\u{2581}"

    /// Token string -> integer ID.
    private let vocab: [String: Int]

    /// BPE merge pairs ranked by priority (lower index = higher priority).
    private let mergeRanks: [StringPair: Int]

    // MARK: - Initialization

    init(vocabFileName: String = "siglip2-vocab", mergesFileName: String = "siglip2-merges") {
        // Load vocabulary with pre-allocated capacity to avoid rehashing.
        guard let vocabUrl = Bundle.main.url(forResource: vocabFileName, withExtension: "json") else {
            fatalError("Failed to find vocab file: \(vocabFileName).json")
        }
        var loadedVocab: [String: Int] = [:]
        autoreleasepool {
            let vocabData = try! Data(contentsOf: vocabUrl)
            let decoded = try! JSONDecoder().decode([String: Int].self, from: vocabData)
            loadedVocab.reserveCapacity(decoded.count)
            loadedVocab = decoded
        }
        self.vocab = loadedVocab

        // Load merges by streaming line-by-line to avoid holding the entire
        // file string + split array + dictionary in memory simultaneously.
        guard let mergesUrl = Bundle.main.url(forResource: mergesFileName, withExtension: "txt") else {
            fatalError("Failed to find merges file: \(mergesFileName).txt")
        }
        var ranks: [StringPair: Int] = [:]
        ranks.reserveCapacity(580_000)

        autoreleasepool {
            let mergesData = try! Data(contentsOf: mergesUrl)
            mergesData.withUnsafeBytes { rawBuffer in
                guard let base = rawBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
                let count = rawBuffer.count
                var lineStart = 0
                var rankIndex = 0
                var isFirstLine = true  // Skip header "#version: 0.2"

                for i in 0...count {
                    let isEnd = (i == count)
                    let isNewline = !isEnd && base[i] == UInt8(ascii: "\n")

                    guard isEnd || isNewline else { continue }

                    let lineLen = i - lineStart
                    if isFirstLine {
                        isFirstLine = false
                        lineStart = i + 1
                        continue
                    }
                    guard lineLen > 2 else {
                        lineStart = i + 1
                        continue
                    }

                    // Find the space separator within the line.
                    var spacePos = -1
                    for j in lineStart..<i {
                        if base[j] == UInt8(ascii: " ") {
                            spacePos = j
                            break
                        }
                    }

                    if spacePos > lineStart && spacePos < i - 1 {
                        let a = String(bytes: UnsafeBufferPointer(start: base + lineStart, count: spacePos - lineStart), encoding: .utf8) ?? ""
                        let b = String(bytes: UnsafeBufferPointer(start: base + spacePos + 1, count: i - spacePos - 1), encoding: .utf8) ?? ""
                        if !a.isEmpty && !b.isEmpty {
                            ranks[StringPair(a, b)] = rankIndex
                        }
                    }
                    rankIndex += 1
                    lineStart = i + 1
                }
            }
        }
        self.mergeRanks = ranks
    }

    // MARK: - TextTokenizer conformance

    func encode_full(text: String, padTokenId: Int = 0) -> [Int] {
        let ids = encode(text: text)

        var result = Array(repeating: padTokenId, count: contextLength)
        guard contextLength >= 1 else { return result }

        // Reserve the last slot for <eos> if truncation is needed.
        let maxContentTokens = contextLength - 1
        let clipped = ids.prefix(maxContentTokens)

        for (i, id) in clipped.enumerated() {
            result[i] = id
        }
        // Append <eos> immediately after content tokens.
        result[clipped.count] = eosTokenId

        return result
    }

    // MARK: - Core tokenization

    /// Tokenize text and return token IDs (without <eos> or padding).
    private func encode(text: String) -> [Int] {
        let lowercased = text.lowercased()

        // Normalizer: replace space with SentencePiece marker ▁
        let normalized = lowercased.replacingOccurrences(of: " ", with: Self.spMarkerStr)

        guard !normalized.isEmpty else { return [] }

        // Apply BPE to the entire normalized string as a single piece.
        let bpeTokens = bpe(normalized)

        // Map tokens to IDs, with byte_fallback for unknown tokens.
        var ids: [Int] = []
        for token in bpeTokens {
            if let id = vocab[token] {
                ids.append(id)
            } else {
                // Byte fallback: encode each UTF-8 byte of the token as <0xHH>.
                let bytes = Array(token.utf8)
                for byte in bytes {
                    let fallbackToken = String(format: "<0x%02X>", byte)
                    if let id = vocab[fallbackToken] {
                        ids.append(id)
                    } else {
                        // If even the byte fallback token is missing, use <unk> (ID 3).
                        ids.append(vocab["<unk>"] ?? 3)
                    }
                }
            }
        }
        return ids
    }

    // MARK: - BPE algorithm

    /// Apply BPE merges to a string. Returns an array of token strings.
    private func bpe(_ text: String) -> [String] {
        // Start with individual characters (Unicode scalars as strings).
        var word = text.map { String($0) }

        guard word.count > 1 else {
            return word
        }

        while true {
            // Find the pair with the lowest (highest-priority) merge rank.
            var bestPair: StringPair?
            var bestRank = Int.max

            for i in 0 ..< word.count - 1 {
                let pair = StringPair(word[i], word[i + 1])
                if let rank = mergeRanks[pair], rank < bestRank {
                    bestRank = rank
                    bestPair = pair
                }
            }

            guard let pair = bestPair else {
                break  // No more merges possible.
            }

            // Merge all occurrences of this pair in the word.
            var newWord: [String] = []
            var i = 0
            while i < word.count {
                if i < word.count - 1 && word[i] == pair.a && word[i + 1] == pair.b {
                    newWord.append(pair.a + pair.b)
                    i += 2
                } else {
                    newWord.append(word[i])
                    i += 1
                }
            }
            word = newWord

            if word.count == 1 {
                break
            }
        }

        return word
    }
}

// MARK: - Helper type for merge pair lookup

/// A pair of strings used as a dictionary key for BPE merge lookups.
private struct StringPair: Hashable {
    let a: String
    let b: String

    init(_ a: String, _ b: String) {
        self.a = a
        self.b = b
    }
}
