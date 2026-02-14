//
//  SwiftDataModels.swift
//  RPhoto
//

import Foundation
import SwiftData
import CoreML

@Model
class CachedEmbedding {
    @Attribute(.unique) var id: String // Composite: "imageId|modelName"
    var imageId: String
    var modelName: String
    var embeddingData: Data
    var lastAccessed: Date
    
    init(imageId: String, modelName: String, embeddingData: Data, lastAccessed: Date = Date()) {
        self.imageId = imageId
        self.modelName = modelName
        self.id = "\(imageId)|\(modelName)"
        self.embeddingData = embeddingData
        self.lastAccessed = lastAccessed
    }
}

extension CachedEmbedding {
    func getEmbeddingVector() -> [Float]? {
        let stride = MemoryLayout<Float>.size
        guard embeddingData.count % stride == 0 else {
            return nil
        }

        let count = embeddingData.count / stride
        var values = Array(repeating: Float.zero, count: count)
        _ = values.withUnsafeMutableBytes { destination in
            embeddingData.copyBytes(to: destination)
        }
        return values
    }

    func getEmbedding() throws -> MLMultiArray? {
        guard let values = getEmbeddingVector() else {
            return nil
        }

        let count = values.count
        let embedding = try MLMultiArray(shape: [1, NSNumber(value: count)], dataType: .float32)

        let destination = embedding.dataPointer.bindMemory(to: Float.self, capacity: count)
        for index in 0..<count {
            destination[index] = values[index]
        }

        return embedding
    }

    static func from(vector: [Float], imageId: String, modelName: String) -> CachedEmbedding {
        let data = vector.withUnsafeBufferPointer { buffer in
            Data(buffer: buffer)
        }
        return CachedEmbedding(imageId: imageId, modelName: modelName, embeddingData: data)
    }

    static func from(embedding: MLMultiArray, imageId: String, modelName: String) -> CachedEmbedding? {
        let values: [Float]
        switch embedding.dataType {
        case .float16:
            values = embedding.withUnsafeBufferPointer(ofType: Float16.self) { buffer in
                buffer.map { Float($0) }
            }
        case .float32:
            values = embedding.withUnsafeBufferPointer(ofType: Float.self) { Array($0) }
        case .double:
            values = embedding.withUnsafeBufferPointer(ofType: Double.self) { buffer in
                buffer.map { Float($0) }
            }
        default:
            return nil
        }

        return CachedEmbedding.from(vector: values, imageId: imageId, modelName: modelName)
    }
}
