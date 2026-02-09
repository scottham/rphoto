//
// For licensing see accompanying LICENSE file.
// Copyright (C) 2024 Apple Inc. All Rights Reserved.
// Modified by individual developer.
//

import CoreML
import Foundation

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
    public let vocabName: String
    public let mergesName: String
    public var id: String { name }
    
    init(name: String, padTokenId: Int = 0, vocabName: String = "clip-vocab", mergesName: String = "clip-merges", factory: @escaping () -> CLIPEncoder) {
        self.name = name
        self.padTokenId = padTokenId
        self.vocabName = vocabName
        self.mergesName = mergesName
        self.factory = factory
    }

    public static func == (lhs: ModelConfiguration, rhs: ModelConfiguration) -> Bool {
        lhs.name == rhs.name
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(name)
    }
}

public let models: [ModelConfiguration] = [
    .init(name: "MobileCLIP-S2", factory: { S2Model() }),
    .init(name: "MobileCLIP-BLT", factory: { BLTModel() }),
    .init(name: "TinyCLIP", padTokenId: 1, vocabName: "tinyclip-vocab", mergesName: "tinyclip-merges", factory: { TinyCLIPModel() }),
]

public let defaultModel = ModelConfiguration(name: "MobileCLIP-S2", factory: { S2Model() })

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

public struct BLTModel: CLIPEncoder {

    let imageEncoder = AsyncFactory {
        do {
            return try mobileclip_blt_image()
        } catch {
            fatalError("Failed to initialize ML model: \(error)")
        }
    }

    let textEncoder = AsyncFactory {
        do {
            return try mobileclip_blt_text()
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
