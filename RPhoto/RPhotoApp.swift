//
// For licensing see accompanying LICENSE file.
// Copyright (C) 2024 Apple Inc. All Rights Reserved.
// Modified by individual developer.
//

import SwiftUI
import SwiftData

@main
struct RPhotoApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(for: [CachedEmbedding.self, SelectedAsset.self])
    }
}
