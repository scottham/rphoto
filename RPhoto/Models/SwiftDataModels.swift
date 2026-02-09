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
    func getEmbedding() throws -> MLMultiArray? {
        let stride = MemoryLayout<Float>.size
        guard embeddingData.count % stride == 0 else {
            print("CachedEmbedding: Invalid embedding byte length \(embeddingData.count)")
            return nil
        }

        let count = embeddingData.count / stride
        let embedding = try MLMultiArray(shape: [1, NSNumber(value: count)], dataType: .float32)

        embeddingData.withUnsafeBytes { rawBuffer in
            if let baseAddress = rawBuffer.baseAddress {
                let dest = embedding.dataPointer.bindMemory(to: Float.self, capacity: count)
                let src = baseAddress.bindMemory(to: Float.self, capacity: count)
                for i in 0..<count {
                    dest[i] = src[i]
                }
            }
        }
        
        return embedding
    }
    
    static func from(embedding: MLMultiArray, imageId: String, modelName: String) -> CachedEmbedding? {
        let count = embedding.count
        var data = Data(count: count * MemoryLayout<Float>.size)

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

        guard values.count == count else {
            return nil
        }

        data.withUnsafeMutableBytes { rawBuffer in
            if let dest = rawBuffer.baseAddress?.bindMemory(to: Float.self, capacity: count) {
                for i in 0..<count {
                    dest[i] = values[i]
                }
            }
        }
        
        return CachedEmbedding(imageId: imageId, modelName: modelName, embeddingData: data)
    }
}
