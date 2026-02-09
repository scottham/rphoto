//
//  SelectedAsset.swift
//  RPhoto
//

import Foundation
import SwiftData

@Model
final class SelectedAsset {
    @Attribute(.unique) var id: String
    var createdAt: Date
    var lastValidatedAt: Date

    init(id: String, createdAt: Date = Date(), lastValidatedAt: Date = Date()) {
        self.id = id
        self.createdAt = createdAt
        self.lastValidatedAt = lastValidatedAt
    }
}
