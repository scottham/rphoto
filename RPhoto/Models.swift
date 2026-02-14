//
// For licensing see accompanying LICENSE file.
// Copyright (C) 2024 Apple Inc. All Rights Reserved.
// Modified by individual developer.
//

import CoreML
import Foundation

protocol TextTokenizer {
    var contextLength: Int { get }
    func encode_full(text: String, padTokenId: Int) -> [Int]
}

protocol CLIPEncoder {

    var targetImageSize: CGSize { get }

    func load() async

    func encode(image: CVPixelBuffer) async throws -> MLMultiArray

    func encode(text: MLMultiArray) async throws -> MLMultiArray

}

public struct ModelConfiguration: Identifiable, Hashable {
    public let name: String
    let factory: () -> CLIPEncoder
    public let padTokenId: Int
    let tokenizerFactory: () -> any TextTokenizer
    public var id: String { name }

    init(name: String, padTokenId: Int = 0, factory: @escaping () -> CLIPEncoder, tokenizerFactory: @escaping () -> any TextTokenizer) {
        self.name = name
        self.padTokenId = padTokenId
        self.factory = factory
        self.tokenizerFactory = tokenizerFactory
    }

    public static func == (lhs: ModelConfiguration, rhs: ModelConfiguration) -> Bool {
        lhs.name == rhs.name
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(name)
    }
}

public let models: [ModelConfiguration] = [
    .init(name: "MobileCLIP-S2",
          factory: { S2Model() },
          tokenizerFactory: { CLIPTokenizer(vocabFileName: "clip-vocab", mergesFileName: "clip-merges") }),
    .init(name: "SigLIP2",
          factory: { SigLIP2Model() },
          tokenizerFactory: { SigLIP2Tokenizer() }),
    .init(name: "TinyCLIP",
          padTokenId: 1,
          factory: { TinyCLIPModel() },
          tokenizerFactory: { CLIPTokenizer(vocabFileName: "tinyclip-vocab", mergesFileName: "tinyclip-merges") }),
]

public let defaultModel = ModelConfiguration(
    name: "MobileCLIP-S2",
    factory: { S2Model() },
    tokenizerFactory: { CLIPTokenizer(vocabFileName: "clip-vocab", mergesFileName: "clip-merges") }
)

public struct S2Model: CLIPEncoder {

    let imageEncoder = AsyncFactory {
        do {
            return try mobileclip_s2_image()
        } catch {
            fatalError("Failed to initialize ML model: \(error)")
        }
    }

    let textEncoder = AsyncFactory {
        do {
            return try mobileclip_s2_text()
        } catch {
            fatalError("Failed to initialize ML model: \(error)")
        }
    }

    func load() async {
        async let t = textEncoder.get()
        async let i = imageEncoder.get()
        _ = await (t, i)
    }

    let targetImageSize = CGSize(width: 256, height: 256)

    func encode(image: CVPixelBuffer) async throws -> MLMultiArray {
        try await imageEncoder.get().prediction(image: image).final_emb_1
    }

    func encode(text: MLMultiArray) async throws -> MLMultiArray {
        try await textEncoder.get().prediction(text: text).final_emb_1
    }
}

public struct TinyCLIPModel: CLIPEncoder {

    let imageEncoder = AsyncFactory {
        do {
            return try TinyCLIP_Vision()
        } catch {
            fatalError("Failed to initialize ML model: \(error)")
        }
    }

    let textEncoder = AsyncFactory {
        do {
            return try TinyCLIP_Text()
        } catch {
            fatalError("Failed to initialize ML model: \(error)")
        }
    }

    func load() async {
        async let t = textEncoder.get()
        async let i = imageEncoder.get()
        _ = await (t, i)
    }
    
    let targetImageSize = CGSize(width: 224, height: 224)

    func encode(image: CVPixelBuffer) async throws -> MLMultiArray {
        // TinyCLIP_Vision expects input "image" and returns "embedding"
        // CoreML generated class usually has a prediction method taking the named inputs
        try await imageEncoder.get().prediction(image: image).embedding
    }

    func encode(text: MLMultiArray) async throws -> MLMultiArray {
        // TinyCLIP_Text expects input "input_ids" and returns "embedding"
        try await textEncoder.get().prediction(input_ids: text).embedding
    }
}

public struct SigLIP2Model: CLIPEncoder {

    let imageEncoder = AsyncFactory {
        do {
            return try SigLIP2_Vision()
        } catch {
            fatalError("Failed to initialize ML model: \(error)")
        }
    }

    let textEncoder = AsyncFactory {
        do {
            return try SigLIP2_Text()
        } catch {
            fatalError("Failed to initialize ML model: \(error)")
        }
    }

    func load() async {
        async let t = textEncoder.get()
        async let i = imageEncoder.get()
        _ = await (t, i)
    }

    let targetImageSize = CGSize(width: 224, height: 224)

    func encode(image: CVPixelBuffer) async throws -> MLMultiArray {
        try await imageEncoder.get().prediction(image: image).embedding
    }

    func encode(text: MLMultiArray) async throws -> MLMultiArray {
        let encoder = try await textEncoder.get()
        let result = try encoder.prediction(input_ids: text)
        return result.embedding
    }
}
