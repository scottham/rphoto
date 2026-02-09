//
//  GallerySearchView.swift
//  RPhoto
//

import SwiftUI
import PhotosUI
import Photos
import SwiftData

struct GallerySearchView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var manager = GalleryManager()
    @State private var searchText = ""
    @State private var showDebugView = false
    @State private var waitingPermissionRefresh = false
    @Query private var selectedAssets: [SelectedAsset]
    
    var body: some View {
        NavigationStack {
            VStack {
                if manager.isProcessing {
                    VStack {
                        ProgressView(manager.processingStatusText, value: manager.processingProgress, total: 1.0)
                            .padding()
                        Text("\(Int(manager.processingProgress * 100))%")
                    }
                }
                
                // Search Bar
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.gray)
                    TextField("Search your photos (e.g. 'cat', 'sunset')...", text: $searchText)
                        .onSubmit {
                            Task {
                                await manager.search(text: searchText, context: modelContext)
                            }
                        }
                        .submitLabel(.search)
                    
                    if !searchText.isEmpty {
                        Button(action: {
                            searchText = ""
                            Task { await manager.search(text: "", context: modelContext) }
                        }) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.gray)
                        }
                    }
                }
                .padding()
                .background(Color(.systemGray6))
                .cornerRadius(10)
                .padding(.horizontal)
                
                // Content
                if manager.displayedImages.isEmpty && !manager.isProcessing {
                    let availableCount = max(manager.totalEncodedCount, selectedAssets.count)
                    VStack(spacing: 16) {
                        if manager.photoAuthorizationStatus == .denied || manager.photoAuthorizationStatus == .restricted {
                            ContentUnavailableView(
                                "Photo Access Required",
                                systemImage: "lock.slash",
                                description: Text("Grant photo access to analyze and search your photo library.")
                            )
                        } else if availableCount > 0 {
                            ContentUnavailableView(
                                "Ready to Search",
                                systemImage: "magnifyingglass",
                                description: Text("\(manager.newlyEncodedCount) newly encoded, \(manager.newlyLoadedFromCacheCount) loaded from cache. \(availableCount) selected photos available for search.")
                            )
                        } else {
                            ContentUnavailableView(
                                "No Photos Available Yet",
                                systemImage: "photo.on.rectangle",
                                description: Text("Use the access controls below to grant photo access and sync analysis.")
                            )
                        }

                        Spacer(minLength: 0)
                        permissionControlsPanel
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                } else {
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 2)], spacing: 2) {
                            ForEach(manager.displayedImages) { item in
                                if let image = item.image {
                                    NavigationLink(destination: ImageDetailView(galleryImage: item)) {
                                        ZStack(alignment: .bottomTrailing) {
                                            Image(uiImage: image)
                                                .resizable()
                                            .aspectRatio(contentMode: .fill)
                                            .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                                            .clipped()
                                            .aspectRatio(1, contentMode: .fit)
                                        
                                        if !searchText.isEmpty {
                                            Text(String(format: "%.2f", item.similarityScore))
                                                .font(.caption2)
                                                .padding(2)
                                                .background(.black.opacity(0.6))
                                                .foregroundStyle(.white)
                                                .cornerRadius(4)
                                                .padding(4)
                                        }
                                    }
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Picker("Top K", selection: $manager.topK) {
                            Text("Top 5").tag(5)
                            Text("Top 10").tag(10)
                            Text("Top 20").tag(20)
                            Text("Top 50").tag(50)
                            Text("Top 100").tag(100)
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "slider.horizontal.3")
                            Text("Top \(manager.topK)")
                                .font(.caption)
                                .fontWeight(.bold)
                        }
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color(.systemGray6))
                        .cornerRadius(8)
                    }
                }
                
                ToolbarItem(placement: .principal) {
                    Menu {
                        Section("Switch Model") {
                            ForEach(models) { modelConfig in
                                Button {
                                    Task {
                                        await manager.setModel(modelConfig)
                                    }
                                } label: {
                                    HStack {
                                        Text(modelConfig.name)
                                        if manager.selectedModel == modelConfig {
                                            Image(systemName: "checkmark")
                                        }
                                    }
                                }
                            }
                        }
                    } label: {
                        VStack(spacing: 0) {
                            HStack(spacing: 4) {
                                Text("MobileCLIP Search")
                                    .font(.headline)
                                    .foregroundStyle(.primary)
                                Image(systemName: "chevron.down")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            
                            if let stats = manager.encodingStats {
                                Text(String(format: "Total: %.2fs | Avg: %.2fs", stats.total, stats.average))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            } else {
                                Text(manager.selectedModel.name)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Sync Accessible Photos") {
                            syncAccessiblePhotos()
                        }

                        if manager.isLimitedAuthorization {
                            Button("Manage Limited Selection") {
                                openLimitedSelectionManager()
                            }
                        }

                        Button("Open Settings (Limited/Full)") {
                            openPhotoSettings()
                        }
                    } label: {
                        Image(systemName: "photo.on.rectangle.angled")
                    }
                }
                
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showDebugView = true
                    } label: {
                        Image(systemName: "cylinder.split.1x2")
                    }
                }
            }
            .sheet(isPresented: $showDebugView) {
                CacheDebugView()
            }
            .onChange(of: manager.selectedModel) { _, _ in
                Task {
                    if !searchText.isEmpty {
                        await manager.search(text: searchText, context: modelContext)
                    }
                }
            }
            .onChange(of: scenePhase) { _, newValue in
                guard newValue == .active, waitingPermissionRefresh else {
                    return
                }
                waitingPermissionRefresh = false
                Task {
                    await manager.refreshAfterPermissionPotentiallyChanged(context: modelContext)
                    if !searchText.isEmpty {
                        await manager.search(text: searchText, context: modelContext)
                    }
                }
            }
            .task {
                await manager.bootstrapPhotoAccess(context: modelContext)
            }
        }
    }
}

private extension GallerySearchView {
    var permissionControlsPanel: some View {
        VStack(spacing: 10) {
            Button(action: syncAccessiblePhotos) {
                Label("Sync Accessible Photos", systemImage: "arrow.triangle.2.circlepath")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)

            if manager.isLimitedAuthorization {
                Button(action: openLimitedSelectionManager) {
                    Label("Manage Limited Selection", systemImage: "person.crop.circle.badge.questionmark")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }

            Button(action: openPhotoSettings) {
                Label("Open Settings (Limited/Full)", systemImage: "gearshape")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
        .padding(12)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.horizontal)
        .padding(.bottom, 10)
    }

    func syncAccessiblePhotos() {
        Task {
            await manager.requestOrSyncPhotoAccess(context: modelContext)
            if !searchText.isEmpty {
                await manager.search(text: searchText, context: modelContext)
            }
        }
    }

    func openLimitedSelectionManager() {
        if manager.presentLimitedLibraryPicker() {
            waitingPermissionRefresh = true
        }
    }

    func openPhotoSettings() {
        waitingPermissionRefresh = true
        manager.openPhotoSettings()
    }
}

#Preview {
    GallerySearchView()
}
