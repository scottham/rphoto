//
//  CacheDebugView.swift
//  RPhoto
//

import SwiftUI
import SwiftData

struct CacheDebugView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    
    @Query(sort: \CachedEmbedding.lastAccessed, order: .reverse)
    private var cachedItems: [CachedEmbedding]
    @Query private var selectedAssets: [SelectedAsset]
    
    // Derived: Group by model name
    var groupedItems: [String: [CachedEmbedding]] {
        Dictionary(grouping: cachedItems, by: { $0.modelName })
    }
    
    var sortedModelNames: [String] {
        groupedItems.keys.sorted()
    }
    
    var body: some View {
        NavigationStack {
            List {
                Section("Summary") {
                    HStack {
                        Text("Total Cached Items")
                        Spacer()
                        Text("\(cachedItems.count)")
                            .foregroundStyle(.secondary)
                    }

                    HStack {
                        Text("Selected Assets")
                        Spacer()
                        Text("\(selectedAssets.count)")
                            .foregroundStyle(.secondary)
                    }
                    
                    Button(role: .destructive, action: { clearCache(for: nil) }) {
                        Text("Clear All Cache")
                    }
                }
                
                ForEach(sortedModelNames, id: \.self) { modelName in
                    DisclosureGroup {
                        Button(role: .destructive) {
                            clearCache(for: modelName)
                        } label: {
                            Label("Clear \(modelName) Cache", systemImage: "trash")
                                .foregroundStyle(.red)
                        }
                        
                        if let items = groupedItems[modelName] {
                            ForEach(items) { item in
                                VStack(alignment: .leading) {
                                    Text(item.imageId) // Show clean image ID
                                        .font(.caption)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    Text(item.lastAccessed, format: .dateTime)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    } label: {
                        HStack {
                            Text(modelName)
                                .fontWeight(.medium)
                                .foregroundStyle(.primary)
                            Spacer()
                            if let items = groupedItems[modelName] {
                                let size = items.reduce(0) { $0 + $1.embeddingData.count }
                                Text("\(items.count) items (Est. \(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)))")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                
                if cachedItems.isEmpty {
                    Section {
                         ContentUnavailableView("Cache Empty", systemImage: "cylinder.split.1x2", description: Text("No images encoded yet."))
                    }
                }
            }
            .navigationTitle("Cache Status")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
    
    private func clearCache(for modelName: String?) {
        do {
            if let modelName = modelName {
                // Delete specific model items
                // Note: SwiftData bulk delete with complex predicate can be tricky, 
                // but we can just fetch and delete for safety or use delete(where:) if supported.
                // delete(model:where:) is supported in iOS 18 / newer SwiftData, but standard context.delete(_ object) loop is safest across versions if count is small.
                // Let's try efficient approach first:
                try modelContext.delete(model: CachedEmbedding.self, where: #Predicate { $0.modelName == modelName })
            } else {
                // Delete all cache + selected assets
                try modelContext.delete(model: CachedEmbedding.self)
                try modelContext.delete(model: SelectedAsset.self)
                NotificationCenter.default.post(name: .galleryDataDidReset, object: nil)
            }
        } catch {
            print("Failed to clear cache: \(error)")
        }
    }
}

#Preview {
    CacheDebugView()
        .modelContainer(for: [CachedEmbedding.self, SelectedAsset.self], inMemory: true)
}
