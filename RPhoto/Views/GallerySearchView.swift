//
//  GallerySearchView.swift
//  RPhoto
//

import SwiftUI
import PhotosUI
import Photos
import SwiftData

private enum AppLegalLinks {
    static let privacyPolicyURL = URL(
        string: "https://gist.github.com/scottham/43b16e9e73acb809e5c68263203201e6/raw/privacy_policy_rphoto.md"
    )!
}

private struct PrivacyPolicyView: View {
    @Environment(\.dismiss) private var dismiss

    let onlinePolicyURL: URL

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Last updated: November 16, 2026")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    policySection(
                        title: "Overview",
                        body: "RPhoto provides semantic photo search on your device. Photo indexing, embedding generation, and retrieval are designed to run locally inside the app sandbox."
                    )

                    policySection(
                        title: "Data Processed On Device",
                        body: """
                        The app may process:
                        - Selected photo local identifiers and image pixels available on-device.
                        - Generated image embeddings used for semantic search.
                        - Search query text.
                        """
                    )

                    policySection(
                        title: "How Data Is Used",
                        body: """
                        Processed data is used only for app features such as:
                        - Building and updating the local search index.
                        - Running local semantic search. Queries in any language are encoded directly by the on-device model; no translation service is used.
                        """
                    )

                    policySection(
                        title: "Network Usage",
                        body: """
                        - The app does not use the network. Photo indexing, search, and all models run entirely on your device.
                        - No photos, search queries, or usage data are sent off the device.
                        - Photo loading is configured to avoid triggering iCloud original downloads. If only iCloud originals exist, the app uses local available representations (for example, thumbnails) when possible.
                        """
                    )

                    policySection(
                        title: "Third-Party Technology",
                        body: """
                        Semantic search uses Google's SigLIP 2 model (Apache License 2.0), converted to run on-device with Core ML.
                        """
                    )

                    policySection(
                        title: "Permissions",
                        body: """
                        The app requests photo library access to search selected photos. You can change this anytime in iOS Settings.
                        """
                    )

                    policySection(
                        title: "Data Retention and Deletion",
                        body: """
                        Search cache data (including embeddings) is stored locally in the app sandbox. You can remove it by clearing app cache in-app or deleting the app from your device.
                        """
                    )

                    policySection(
                        title: "Contact",
                        body: "For privacy questions, use the developer contact channel listed on the app's distribution page."
                    )

                    Link("Open Online Privacy Policy", destination: onlinePolicyURL)
                        .font(.subheadline)
                        .padding(.top, 4)
                }
                .padding()
            }
            .navigationTitle("Privacy Policy")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func policySection(title: String, body: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.headline)
            Text(body)
                .font(.subheadline)
                .foregroundStyle(.primary)
        }
    }
}

struct GallerySearchView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var manager = GalleryManager()
    @State private var searchText = ""
    @State private var showDebugView = false
    @State private var waitingPermissionRefresh = false
    // Last submitted query, re-run after model or permission changes.
    @State private var effectiveSearchText = ""
    @State private var isShowingPrivacyPolicy = false

    @Query private var selectedAssets: [SelectedAsset]

    var body: some View {
        NavigationStack {
            VStack {
                if manager.isProcessing || manager.isSearching {
                    VStack(spacing: 8) {
                        if manager.isProcessing {
                            ProgressView(manager.processingStatusText, value: manager.processingProgress, total: 1.0)
                                .padding(.horizontal)
                            Text("\(Int(manager.processingProgress * 100))%")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        if manager.isSearching {
                            ProgressView(manager.searchStatusText, value: manager.searchProgress, total: 1.0)
                                .padding(.horizontal)
                            Text("\(Int(manager.searchProgress * 100))%")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.top, 8)
                }

                searchControlsPanel

                // Content
                if manager.displayedImages.isEmpty && !manager.isProcessing && !manager.isSearching {
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
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
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
                                Text("Semantic Search")
                                    .font(.headline)
                                    .foregroundStyle(.primary)
                                Image(systemName: "chevron.down")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }

                            if let ss = manager.searchStats {
                                Text(searchStatsSummaryText(ss))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.75)
                                    .allowsTightening(true)
                            } else if let es = manager.encodingStats {
                                Text(encodingStatsSummaryText(es, imageCount: manager.newlyEncodedCount))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.75)
                                    .allowsTightening(true)
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
                        Section("Photos") {
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
                        }

                        Section("Legal") {
                            Button("Privacy Policy") {
                                isShowingPrivacyPolicy = true
                            }
                        }
                    } label: {
                        Image(systemName: "gearshape")
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
            .sheet(isPresented: $isShowingPrivacyPolicy) {
                PrivacyPolicyView(onlinePolicyURL: AppLegalLinks.privacyPolicyURL)
            }
            .onChange(of: manager.selectedModel) { _, _ in
                Task {
                    await rerunWithEffectiveQuery()
                }
            }
            .onChange(of: scenePhase) { _, newValue in
                guard newValue == .active, waitingPermissionRefresh else {
                    return
                }
                waitingPermissionRefresh = false
                Task {
                    await manager.refreshAfterPermissionPotentiallyChanged(context: modelContext)
                    await rerunWithEffectiveQuery()
                }
            }
            .task {
                await manager.bootstrapPhotoAccess(context: modelContext)
            }
        }
    }
}

private extension GallerySearchView {
    var searchControlsPanel: some View {
        GlassEffectContainer(spacing: 12) {
            VStack(spacing: 10) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)

                    TextField("Search your photos (e.g. 'cat', 'sunset')...", text: $searchText)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onSubmit {
                            submitSearchPipeline()
                        }
                        .submitLabel(.search)

                    if !searchText.isEmpty {
                        Button(action: {
                            searchText = ""
                            clearSearchPipeline()
                        }) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .glassEffect(.regular.tint(Color.white.opacity(0.05)), in: .rect(cornerRadius: 20))
            }
        }
        .padding(.horizontal)
    }

    var permissionControlsPanel: some View {
        VStack(spacing: 10) {
            glassActionButton(
                "Sync Accessible Photos",
                systemImage: "arrow.triangle.2.circlepath",
                tint: Color.accentColor.opacity(0.16),
                action: syncAccessiblePhotos
            )

            if manager.isLimitedAuthorization {
                glassActionButton(
                    "Manage Limited Selection",
                    systemImage: "person.crop.circle.badge.questionmark",
                    action: openLimitedSelectionManager
                )
            }

            glassActionButton(
                "Open Settings (Limited/Full)",
                systemImage: "gearshape",
                action: openPhotoSettings
            )
        }
        .padding(14)
        .glassEffect(.regular.tint(Color.white.opacity(0.04)), in: .rect(cornerRadius: 22))
        .padding(.horizontal)
        .padding(.bottom, 10)
    }

    func glassActionButton(
        _ title: String,
        systemImage: String,
        tint: Color = Color.white.opacity(0.06),
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 14)
                .padding(.vertical, 14)
        }
        .foregroundStyle(.primary)
        .glassEffect(.regular.tint(tint).interactive(), in: .rect(cornerRadius: 18))
    }

    func submitSearchPipeline() {
        let normalizedText = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedText.isEmpty else {
            clearSearchPipeline()
            return
        }

        // SigLIP2 is multilingual, so queries in any language are encoded directly on-device.
        effectiveSearchText = normalizedText
        Task {
            await manager.search(text: normalizedText, context: modelContext)
        }
    }

    func clearSearchPipeline() {
        effectiveSearchText = ""
        Task {
            await manager.search(text: "", context: modelContext)
        }
    }

    func rerunWithEffectiveQuery() async {
        let query = effectiveSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return
        }

        await manager.search(text: query, context: modelContext)
    }

    func searchStatsSummaryText(_ stats: (tokenization: Double, textEncoding: Double, similarity: Double, total: Double)) -> String {
        String(
            format: "Search · Tot %.0fms",
            stats.total * 1000
        )
    }

    func encodingStatsSummaryText(_ stats: (total: Double, average: Double), imageCount: Int) -> String {
        // Average is per-image encoding time and should be shown in milliseconds.
        String(
            format: "%d img · Avg %.0fms · Tot %.1fs",
            imageCount,
            stats.average * 1000,
            stats.total
        )
    }

    func syncAccessiblePhotos() {
        Task {
            await manager.requestOrSyncPhotoAccess(context: modelContext)
            await rerunWithEffectiveQuery()
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
