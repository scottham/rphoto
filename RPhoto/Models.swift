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
    .init(name: "Siglip2",
          factory: { SigLIP2Model() },
          tokenizerFactory: { SigLIP2Tokenizer() }),
    // MobileCLIP2-S2 is intentionally disabled for now.
    // Keep implementation below for easier future re-enable.
    // .init(name: "MobileCLIP2-S2",
    //       factory: { MobileCLIP2S2Model() },
    //       tokenizerFactory: { MobileCLIP2Tokenizer() }),
]

public let defaultModel = ModelConfiguration(
    name: "Siglip2",
    factory: { SigLIP2Model() },
    tokenizerFactory: { SigLIP2Tokenizer() }
)

// NOTE:
// MobileCLIP2-S2 support is retained as source-only reference and excluded from
// compilation while its model bundles are removed from the project.
#if false
public struct MobileCLIP2S2Model: CLIPEncoder {

    let imageEncoder = AsyncFactory {
        do {
            return try MobileCLIP2_S2_Vision()
        } catch {
            fatalError("Failed to initialize ML model: \(error)")
        }
    }

    let textEncoder = AsyncFactory {
        do {
            return try MobileCLIP2_S2_Text()
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
        try await imageEncoder.get().prediction(image: image).embedding
    }

    func encode(text: MLMultiArray) async throws -> MLMultiArray {
        try await textEncoder.get().prediction(input_ids: text).embedding
    }
}
#endif

public struct SigLIP2Model: CLIPEncoder {

    private static func makeConfig() -> MLModelConfiguration {
        let config = MLModelConfiguration()
        config.computeUnits = .cpuAndNeuralEngine
        return config
    }

    let imageEncoder = AsyncFactory {
        do {
            return try SigLIP2_Vision(configuration: makeConfig())
        } catch {
            fatalError("Failed to initialize ML model: \(error)")
        }
    }

    let textEncoder = AsyncFactory {
        do {
            return try SigLIP2_Text(configuration: makeConfig())
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
        try await imageEncoder.get().prediction(image: image).embedding
    }

    func encode(text: MLMultiArray) async throws -> MLMultiArray {
        let encoder = try await textEncoder.get()
        let result = try encoder.prediction(input_ids: text)
        return result.embedding
    }
}
