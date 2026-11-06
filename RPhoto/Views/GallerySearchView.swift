//
//  GallerySearchView.swift
//  RPhoto
//

import SwiftUI
import PhotosUI
import Photos
import SwiftData

private let isTranslationFlowDebugEnabled = false

private struct TranslationSearchRequest: Equatable {
    let id: UUID
    let rawText: String
    let sourceLanguageCode: String
}

private struct TranslationDownloadPrompt: Identifiable, Equatable {
    let id: UUID
    let request: TranslationSearchRequest
    let sourceLanguageDisplayName: String
    let approxModelSizeMB: Int
}

private enum TranslationDecision: String, Equatable {
    case passthroughEnglish
    case translatedToEnglish
    case blockedNeedsModelDownload
    case blockedUnsupported

    var displayLabel: String {
        switch self {
        case .passthroughEnglish:
            return "English (no translation needed)"
        case .translatedToEnglish:
            return "Translated to English"
        case .blockedNeedsModelDownload:
            return "Model download required"
        case .blockedUnsupported:
            return "Language not supported"
        }
    }

    var isBlocked: Bool {
        switch self {
        case .blockedNeedsModelDownload, .blockedUnsupported:
            return true
        case .passthroughEnglish, .translatedToEnglish:
            return false
        }
    }
}

private struct TranslationDiagnostics: Equatable {
    let rawText: String
    let effectiveEnglishText: String?
    let sourceLanguageCode: String
    let decision: TranslationDecision
    let statusMessage: String
}

private struct InputLanguageOption: Identifiable, Equatable {
    let id: String
    let displayName: String
}

private struct TranslationModelLanguageOption: Identifiable, Equatable {
    let id: String
    let displayName: String
}

private struct ManualModelDownloadPrompt: Identifiable, Equatable {
    let id = UUID()
    let languageCode: String
    let languageDisplayName: String
}

private enum TranslationModelFilter: String, CaseIterable, Identifiable {
    case all
    case downloaded
    case notDownloaded

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all:
            return "All"
        case .downloaded:
            return "Downloaded"
        case .notDownloaded:
            return "Not Downloaded"
        }
    }
}

private enum TranslationAttribution {
    static let providerLine = "Powered by Google Translate"
    static let detailLine = "On-device translation uses Google ML Kit language models."
    static let disclaimerLine = "Machine translation may be inaccurate."
    static let requirementsURL = URL(string: "https://cloud.google.com/translate/attribution")!
}

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
                    Text("Last updated: February 17, 2026")
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
                        - Translation model download state.
                        """
                    )

                    policySection(
                        title: "How Data Is Used",
                        body: """
                        Processed data is used only for app features such as:
                        - Building and updating the local search index.
                        - Running local semantic search.
                        - Translating non-English queries to English for retrieval.
                        """
                    )

                    policySection(
                        title: "Network Usage",
                        body: """
                        - Photo search and embedding generation run locally.
                        - On first use of a non-English language, the app may download a Google ML Kit translation model after user confirmation.
                        - Translation model download may use Wi-Fi or cellular network.
                        - After a model is downloaded, translation can run offline.
                        - Photo loading is configured to avoid triggering iCloud original downloads. If only iCloud originals exist, the app uses local available representations (for example, thumbnails) when possible.
                        """
                    )

                    policySection(
                        title: "Third-Party Technology",
                        body: """
                        The app uses Google ML Kit Translation for on-device translation models.
                        - Attribution: Powered by Google Translate.
                        - Translation attribution requirements: https://cloud.google.com/translate/attribution
                        - Google Privacy Policy: https://policies.google.com/privacy
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

private struct TranslationModelSettingsView: View {
    @Environment(\.dismiss) private var dismiss

    let translationProvider: any TranslationProvider
    let targetLanguageCode: String
    let approxModelSizeMB: Int

    @State private var languageOptions: [TranslationModelLanguageOption] = []
    @State private var downloadedLanguageCodes: Set<String> = []
    @State private var downloadProgressByLanguageCode: [String: Double] = [:]
    @State private var downloadTasksByLanguageCode: [String: Task<Void, Never>] = [:]
    @State private var isLoading = false
    @State private var statusMessage: String?
    @State private var pendingDownloadPrompt: ManualModelDownloadPrompt?
    @State private var isShowingDownloadPrompt = false
    @State private var searchText = ""
    @State private var activeFilter: TranslationModelFilter = .all

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        Text("Downloaded")
                        Spacer()
                        Text("\(downloadedCount) / \(languageOptions.count)")
                            .foregroundStyle(.secondary)
                    }

                    if let statusMessage {
                        Text(statusMessage)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }

                if !languageOptions.isEmpty {
                    Section {
                        Picker("Filter", selection: $activeFilter) {
                            ForEach(TranslationModelFilter.allCases) { filter in
                                Text(filter.title).tag(filter)
                            }
                        }
                        .pickerStyle(.segmented)
                    }
                }

                Section("Attribution") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(TranslationAttribution.providerLine)
                            .font(.subheadline)
                            .fontWeight(.medium)
                        Text(TranslationAttribution.detailLine)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(TranslationAttribution.disclaimerLine)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Link("Attribution requirements", destination: TranslationAttribution.requirementsURL)
                            .font(.caption)
                    }
                    .padding(.vertical, 2)
                }

                Section("Language Models") {
                    if filteredLanguageOptions.isEmpty {
                        Text("No languages match the current filter.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(filteredLanguageOptions) { languageOption in
                            languageRow(for: languageOption)
                        }
                    }
                }
            }
            .navigationTitle("Translation Models")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .searchable(text: $searchText, prompt: "Search languages")
            .refreshable {
                await refreshDownloadedLanguages()
            }
            .overlay {
                if isLoading && languageOptions.isEmpty {
                    ProgressView("Loading translation models...")
                }
            }
            .task {
                await loadLanguagesAndDownloadStates()
            }
            .alert(
                "Download Translation Model?",
                isPresented: $isShowingDownloadPrompt,
                presenting: pendingDownloadPrompt
            ) { prompt in
                Button("Cancel", role: .cancel) {
                    pendingDownloadPrompt = nil
                }
                Button("Download") {
                    pendingDownloadPrompt = nil
                    startManualDownload(languageCode: prompt.languageCode)
                }
            } message: { prompt in
                Text(
                    "\"\(prompt.languageDisplayName) → \(displayName(for: targetLanguageCode))\" model is about \(approxModelSizeMB) MB. Download now?"
                )
            }
            .onDisappear {
                for (_, task) in downloadTasksByLanguageCode {
                    task.cancel()
                }
                downloadTasksByLanguageCode.removeAll()
            }
        }
    }
}

private extension TranslationModelSettingsView {
    var downloadedCount: Int {
        languageOptions.filter { option in
            isLanguageDownloaded(option.id)
        }.count
    }

    var filteredLanguageOptions: [TranslationModelLanguageOption] {
        let normalizedSearch = searchText.trimmingCharacters(in: .whitespacesAndNewlines)

        return languageOptions.filter { option in
            let passesFilter: Bool
            switch activeFilter {
            case .all:
                passesFilter = true
            case .downloaded:
                passesFilter = isLanguageDownloaded(option.id)
            case .notDownloaded:
                passesFilter = !isLanguageDownloaded(option.id)
            }

            guard passesFilter else {
                return false
            }

            guard !normalizedSearch.isEmpty else {
                return true
            }

            return option.displayName.localizedCaseInsensitiveContains(normalizedSearch)
                || option.id.localizedCaseInsensitiveContains(normalizedSearch)
        }
    }

    @ViewBuilder
    func languageRow(for languageOption: TranslationModelLanguageOption) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(languageOption.displayName)
                    .font(.body)
                Text(languageOption.id)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)

            if let progress = downloadProgressByLanguageCode[languageOption.id] {
                VStack(alignment: .trailing, spacing: 4) {
                    ProgressView(value: progress, total: 1.0)
                        .frame(width: 120)
                    Text("\(Int(progress * 100))%")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            } else if isLanguageDownloaded(languageOption.id) {
                Label("Downloaded", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            } else {
                Button("Download") {
                    pendingDownloadPrompt = ManualModelDownloadPrompt(
                        languageCode: languageOption.id,
                        languageDisplayName: languageOption.displayName
                    )
                    isShowingDownloadPrompt = true
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .padding(.vertical, 2)
    }

    func loadLanguagesAndDownloadStates() async {
        isLoading = true
        defer {
            isLoading = false
        }

        let supportedLanguageCodes = translationProvider
            .supportedLanguages()
            .filter { !isEnglishLanguageCode($0) }

        languageOptions = supportedLanguageCodes
            .map { languageCode in
                TranslationModelLanguageOption(
                    id: languageCode,
                    displayName: displayName(for: languageCode)
                )
            }
            .sorted { lhs, rhs in
                lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
            }

        await refreshDownloadedLanguages()
    }

    func refreshDownloadedLanguages() async {
        downloadedLanguageCodes = Set(
            translationProvider.downloadedLanguageCodes().map(normalizedLanguageCode)
        )
    }

    func startManualDownload(languageCode: String) {
        guard downloadTasksByLanguageCode[languageCode] == nil else {
            return
        }

        statusMessage = nil
        downloadProgressByLanguageCode[languageCode] = 0

        downloadTasksByLanguageCode[languageCode] = Task { @MainActor in
            do {
                try await translationProvider.downloadModel(
                    sourceLanguageCode: languageCode,
                    targetLanguageCode: targetLanguageCode,
                    allowsCellularAccess: true,
                    progressHandler: { progress in
                        Task { @MainActor in
                            guard downloadTasksByLanguageCode[languageCode] != nil else {
                                return
                            }
                            downloadProgressByLanguageCode[languageCode] = min(max(progress, 0), 1)
                        }
                    }
                )

                downloadedLanguageCodes.insert(normalizedLanguageCode(languageCode))
                downloadProgressByLanguageCode[languageCode] = 1
                try? await Task.sleep(nanoseconds: 250_000_000)
                downloadProgressByLanguageCode.removeValue(forKey: languageCode)
                downloadTasksByLanguageCode.removeValue(forKey: languageCode)
            } catch is CancellationError {
                downloadProgressByLanguageCode.removeValue(forKey: languageCode)
                downloadTasksByLanguageCode.removeValue(forKey: languageCode)
            } catch {
                downloadProgressByLanguageCode.removeValue(forKey: languageCode)
                downloadTasksByLanguageCode.removeValue(forKey: languageCode)
                statusMessage = "Failed to download model for \(displayName(for: languageCode)). \(error.localizedDescription)"
            }
        }
    }

    func isLanguageDownloaded(_ languageCode: String) -> Bool {
        downloadedLanguageCodes.contains(normalizedLanguageCode(languageCode))
    }

    func normalizedLanguageCode(_ languageCode: String) -> String {
        languageCode.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    func isEnglishLanguageCode(_ languageCode: String) -> Bool {
        languageCode
            .split(separator: "-")
            .first?
            .localizedCaseInsensitiveCompare("en") == .orderedSame
    }

    func displayName(for identifier: String) -> String {
        if identifier.localizedCaseInsensitiveCompare("zh-TW") == .orderedSame {
            return "Chinese (Traditional)"
        }
        if identifier.localizedCaseInsensitiveCompare("zh") == .orderedSame {
            return "Chinese (Simplified)"
        }

        let language = Locale.Language(identifier: identifier)
        if let languageCode = language.languageCode?.identifier,
           let localizedLanguage = Locale.current.localizedString(forLanguageCode: languageCode) {
            if let scriptCode = language.script?.identifier,
               scriptCode.localizedCaseInsensitiveCompare("Latn") != .orderedSame,
               let localizedScript = Locale.current.localizedString(forScriptCode: scriptCode) {
                return "\(localizedLanguage) (\(localizedScript))"
            }
            return localizedLanguage
        }

        return identifier
    }
}

struct GallerySearchView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var manager = GalleryManager()
    @State private var searchText = ""
    @State private var showDebugView = false
    @State private var waitingPermissionRefresh = false
    @AppStorage("search_input_language_identifier") private var selectedInputLanguageIdentifier = "en"

    @State private var pendingTranslationRequest: TranslationSearchRequest?
    @State private var activeRequestId: UUID?
    @State private var translationTask: Task<Void, Never>?
    @State private var effectiveSearchText = ""
    @State private var translationDiagnostics: TranslationDiagnostics?
    @State private var isTranslating = false
    @State private var translationStatusText = ""
    @State private var supportedInputLanguages: [InputLanguageOption] = [
        InputLanguageOption(id: "en", displayName: "English")
    ]
    @State private var isLoadingSupportedLanguages = false
    @State private var hasLoadedSupportedLanguages = false
    @State private var selectedInputLanguageDisplayName = "English"
    @State private var pendingDownloadPrompt: TranslationDownloadPrompt?
    @State private var isShowingDownloadPrompt = false
    @State private var translationDownloadProgress: Double?
    @State private var isShowingTranslationModels = false
    @State private var isShowingPrivacyPolicy = false

    private var translationProvider: any TranslationProvider { MLKitTranslationService.shared }
    private let targetLanguageCode = "en"
    private let approxTranslationModelSizeMB = 30

    @Query private var selectedAssets: [SelectedAsset]

    var body: some View {
        NavigationStack {
            VStack {
                if manager.isProcessing || manager.isSearching || isTranslating {
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

                        if isTranslating {
                            if let downloadProgress = translationDownloadProgress {
                                ProgressView(translationStatusText, value: downloadProgress, total: 1.0)
                                    .padding(.horizontal)
                                Text("\(Int(downloadProgress * 100))%")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            } else {
                                ProgressView(translationStatusText)
                                    .padding(.horizontal)
                            }
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
                                NavigationLink(destination: ImageDetailView(galleryImage: item)) {
                                    // Square cell sized by the grid column width; the image is drawn as an
                                    // overlay so its intrinsic size can never collapse or distort the cell.
                                    Color.secondary.opacity(0.12)
                                        .aspectRatio(1, contentMode: .fit)
                                        .overlay {
                                            if let image = item.image {
                                                Image(uiImage: image)
                                                    .resizable()
                                                    .scaledToFill()
                                            } else {
                                                Image(systemName: "photo")
                                                    .font(.title2)
                                                    .foregroundStyle(.secondary)
                                            }
                                        }
                                        .clipped()
                                        .contentShape(Rectangle())
                                        .overlay(alignment: .bottomTrailing) {
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
                                .buttonStyle(.plain)
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
                        Section("Translation") {
                            Button("Translation Models") {
                                isShowingTranslationModels = true
                            }
                        }

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
            .sheet(isPresented: $isShowingTranslationModels) {
                TranslationModelSettingsView(
                    translationProvider: translationProvider,
                    targetLanguageCode: targetLanguageCode,
                    approxModelSizeMB: approxTranslationModelSizeMB
                )
            }
            .sheet(isPresented: $isShowingPrivacyPolicy) {
                PrivacyPolicyView(onlinePolicyURL: AppLegalLinks.privacyPolicyURL)
            }
            .onChange(of: manager.selectedModel) { _, _ in
                Task {
                    await rerunWithEffectiveQuery()
                }
            }
            .onChange(of: selectedInputLanguageIdentifier) { _, _ in
                selectedInputLanguageDisplayName = resolvedSelectedInputLanguageDisplayName()
                if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    submitSearchPipeline()
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
                selectedInputLanguageDisplayName = resolvedSelectedInputLanguageDisplayName()
            }
            .alert(
                "Download Translation Model?",
                isPresented: $isShowingDownloadPrompt,
                presenting: pendingDownloadPrompt
            ) { prompt in
                Button("Cancel", role: .cancel) {
                    handleModelDownloadDecision(accepted: false, prompt: prompt)
                }
                Button("Download") {
                    handleModelDownloadDecision(accepted: true, prompt: prompt)
                }
            } message: { prompt in
                Text(
                    "\"\(prompt.sourceLanguageDisplayName) → English\" model is not on this device. Download now (about \(prompt.approxModelSizeMB) MB)?"
                )
            }
            .onDisappear {
                cancelTranslationWorkIfNeeded(reason: "view_disappear")
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

                    inputLanguageMenu

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

                if shouldShowTranslationPanel {
                    translationDiagnosticsPanel
                }
            }
        }
        .padding(.horizontal)
    }

    var shouldShowTranslationPanel: Bool {
        if isTranslating { return true }
        guard let diagnostics = translationDiagnostics else { return false }
        return diagnostics.decision.isBlocked
    }

    var selectedInputLanguageShortCode: String {
        selectedInputLanguageIdentifier
            .split(separator: "-")
            .first
            .map { String($0).uppercased() } ?? "EN"
    }

    var inputLanguageMenu: some View {
        Menu {
            if !hasLoadedSupportedLanguages || isLoadingSupportedLanguages {
                Text("Loading languages...")
                    .task {
                        await ensureSupportedInputLanguagesLoaded()
                    }
            }

            Picker("Input Language", selection: $selectedInputLanguageIdentifier) {
                ForEach(supportedInputLanguages) { languageOption in
                    Text(languageOption.displayName).tag(languageOption.id)
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(selectedInputLanguageShortCode)
                    .font(.caption.weight(.semibold))
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2)
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .glassEffect(.regular.tint(Color.white.opacity(0.05)).interactive(), in: .capsule)
        }
        .accessibilityLabel("Input language")
        .accessibilityValue(selectedInputLanguageDisplayName)
    }

    var translationDiagnosticsPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: isTranslating ? "globe.badge.chevron.backward" : "exclamationmark.triangle.fill")
                    .foregroundStyle(isTranslating ? Color.secondary : Color.red)
                Text("Translation")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                Spacer()
            }

            if isTranslating {
                Text(translationStatusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text(TranslationAttribution.providerLine)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if let diagnostics = translationDiagnostics {
                Text(diagnostics.statusMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(12)
        .glassEffect(
            .regular.tint(isTranslating ? Color.blue.opacity(0.08) : Color.red.opacity(0.08)),
            in: .rect(cornerRadius: 18)
        )
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

        cancelTranslationWorkIfNeeded(reason: "submit_pipeline")
        let selectedSourceLanguageCode = resolvedSelectedInputLanguageIdentifier()
        if isEnglishLanguageCode(selectedSourceLanguageCode) {
            runPassthroughSearch(
                rawText: normalizedText,
                sourceLanguageCode: selectedSourceLanguageCode,
                statusMessage: "Searching in English."
            )
            return
        }

        let request = TranslationSearchRequest(
            id: UUID(),
            rawText: normalizedText,
            sourceLanguageCode: selectedSourceLanguageCode
        )
        pendingTranslationRequest = request
        activeRequestId = request.id
        effectiveSearchText = ""
        translationDiagnostics = nil
        isTranslating = true
        translationStatusText = "Checking translation model..."
        translationDownloadProgress = nil
        translationDebug(
            "submit request id=\(request.id.uuidString) src=\(request.sourceLanguageCode) len=\(request.rawText.count)"
        )

        startTranslationPipeline(for: request, allowModelDownload: false)
    }

    func clearSearchPipeline() {
        cancelTranslationWorkIfNeeded(reason: "clear_pipeline")
        translationDebug("clear pipeline")
        activeRequestId = nil
        pendingTranslationRequest = nil
        effectiveSearchText = ""
        translationDiagnostics = nil
        isTranslating = false
        translationStatusText = ""

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

    func startTranslationPipeline(for request: TranslationSearchRequest, allowModelDownload: Bool) {
        translationTask?.cancel()
        translationTask = Task { @MainActor in
            await runTranslationPipeline(
                request: request,
                allowModelDownload: allowModelDownload
            )
        }
    }

    @MainActor
    func runTranslationPipeline(
        request: TranslationSearchRequest,
        allowModelDownload: Bool
    ) async {
        guard isRequestActive(request.id), pendingTranslationRequest?.id == request.id else {
            translationDebug("skip translation pipeline: inactive request id=\(request.id.uuidString)")
            return
        }

        do {
            translationStatusText = "Checking translation model..."
            translationDownloadProgress = nil
            translationDebug("checking model request id=\(request.id.uuidString) src=\(request.sourceLanguageCode)")
            let modelReady = try await translationProvider.isModelReady(
                sourceLanguageCode: request.sourceLanguageCode,
                targetLanguageCode: targetLanguageCode
            )

            guard isRequestActive(request.id) else {
                return
            }

            if !modelReady {
                if !allowModelDownload {
                    presentModelDownloadPrompt(for: request)
                    return
                }

                translationStatusText = "Downloading translation model..."
                translationDownloadProgress = 0
                translationDebug(
                    "downloading model request id=\(request.id.uuidString) src=\(request.sourceLanguageCode) allowsCellular=true"
                )
                try await translationProvider.downloadModel(
                    sourceLanguageCode: request.sourceLanguageCode,
                    targetLanguageCode: targetLanguageCode,
                    allowsCellularAccess: true,
                    progressHandler: { progress in
                        Task { @MainActor in
                            guard isRequestActive(request.id) else {
                                return
                            }
                            translationDownloadProgress = progress
                        }
                    }
                )
                translationDebug("model download finished request id=\(request.id.uuidString)")

                guard isRequestActive(request.id) else {
                    return
                }
            }

            translationStatusText = "Translating..."
            translationDownloadProgress = nil
            let startedAt = Date()
            let translatedText = try await translationProvider.translate(
                text: request.rawText,
                sourceLanguageCode: request.sourceLanguageCode,
                targetLanguageCode: targetLanguageCode
            )
            let latencyMS = Date().timeIntervalSince(startedAt) * 1000

            guard isRequestActive(request.id) else {
                return
            }

            await completeTranslation(
                requestId: request.id,
                rawText: request.rawText,
                effectiveEnglishText: translatedText,
                sourceLanguageCode: request.sourceLanguageCode,
                decision: .translatedToEnglish,
                statusMessage: "Translated and searching."
            )
            translationDebug(
                "translation succeeded request id=\(request.id.uuidString) latency_ms=\(Int(latencyMS.rounded()))"
            )
        } catch is CancellationError {
            translationDebug("translation cancelled request id=\(request.id.uuidString)")
        } catch let error as TranslationRuntimeError {
            guard isRequestActive(request.id) else {
                return
            }
            let statusMessage = translationFailureMessage(
                for: error,
                sourceLanguageCode: request.sourceLanguageCode
            )
            let decision: TranslationDecision
            switch error {
            case .modelNotDownloaded, .modelDownloadFailed:
                decision = .blockedNeedsModelDownload
            default:
                decision = .blockedUnsupported
            }
            await blockTranslation(
                requestId: request.id,
                rawText: request.rawText,
                decision: decision,
                sourceLanguageCode: request.sourceLanguageCode,
                statusMessage: statusMessage
            )
            translationDebug(
                "translation failed request id=\(request.id.uuidString) error=\(statusMessage)"
            )
        } catch {
            guard isRequestActive(request.id) else {
                return
            }
            let statusMessage = "Translation failed. Please try again."
            await blockTranslation(
                requestId: request.id,
                rawText: request.rawText,
                decision: .blockedUnsupported,
                sourceLanguageCode: request.sourceLanguageCode,
                statusMessage: statusMessage
            )
            translationDebug(
                "translation failed request id=\(request.id.uuidString) error=\(String(describing: error))"
            )
        }
    }

    @MainActor
    func presentModelDownloadPrompt(for request: TranslationSearchRequest) {
        guard isRequestActive(request.id) else {
            return
        }

        translationTask = nil
        isTranslating = false
        translationStatusText = ""
        translationDownloadProgress = nil
        let prompt = TranslationDownloadPrompt(
            id: request.id,
            request: request,
            sourceLanguageDisplayName: displayName(for: request.sourceLanguageCode),
            approxModelSizeMB: approxTranslationModelSizeMB
        )
        pendingDownloadPrompt = prompt
        isShowingDownloadPrompt = true
        translationDiagnostics = TranslationDiagnostics(
            rawText: request.rawText,
            effectiveEnglishText: nil,
            sourceLanguageCode: request.sourceLanguageCode,
            decision: .blockedNeedsModelDownload,
            statusMessage: "A translation model is required for this language."
        )
        translationDebug("model missing; prompting download request id=\(request.id.uuidString)")
    }

    @MainActor
    func handleModelDownloadDecision(accepted: Bool, prompt: TranslationDownloadPrompt) {
        isShowingDownloadPrompt = false
        pendingDownloadPrompt = nil

        guard isRequestActive(prompt.request.id), pendingTranslationRequest?.id == prompt.request.id else {
            translationDebug("model download decision ignored for stale request id=\(prompt.request.id.uuidString)")
            return
        }

        if !accepted {
            Task {
                await blockTranslation(
                    requestId: prompt.request.id,
                    rawText: prompt.request.rawText,
                    decision: .blockedNeedsModelDownload,
                    sourceLanguageCode: prompt.request.sourceLanguageCode,
                    statusMessage: "Model download was canceled. Use English or download the model to continue."
                )
            }
            return
        }

        translationDebug("model download accepted request id=\(prompt.request.id.uuidString)")
        translationDiagnostics = nil
        isTranslating = true
        translationStatusText = "Downloading translation model..."
        translationDownloadProgress = 0
        startTranslationPipeline(for: prompt.request, allowModelDownload: true)
    }

    func cancelTranslationWorkIfNeeded(reason: String = "unspecified") {
        let hadTask = translationTask != nil
        let hadPrompt = isShowingDownloadPrompt || pendingDownloadPrompt != nil
        if hadTask || hadPrompt || activeRequestId != nil {
            translationDebug(
                "cancel translation work reason=\(reason) hadTask=\(hadTask) hadPrompt=\(hadPrompt) \(translationRequestSummary())"
            )
        }

        translationTask?.cancel()
        translationTask = nil
        isShowingDownloadPrompt = false
        pendingDownloadPrompt = nil
        isTranslating = false
        translationStatusText = ""
        translationDownloadProgress = nil
    }

    func translationFailureMessage(
        for error: TranslationRuntimeError,
        sourceLanguageCode: String
    ) -> String {
        switch error {
        case .invalidLanguageCode:
            return "Selected input language is invalid."
        case .unsupportedLanguage:
            return "This language is not supported by ML Kit translation."
        case .modelNotDownloaded:
            let langName = displayName(for: sourceLanguageCode)
            return "\"\(langName) → English\" model is not downloaded."
        case .timeout(let stage):
            switch stage {
            case .modelCheck:
                return "Model availability check timed out. Please retry."
            case .modelDownload:
                return "Model download timed out. Please retry."
            case .translate:
                return "Translation timed out. Please retry."
            }
        case .modelDownloadFailed(let details):
            if details.isEmpty {
                return "Failed to download translation model. Check network and try again."
            }
            return "Failed to download translation model: \(details)"
        case .translationFailed(let details):
            if details.isEmpty {
                return "Translation failed. Please try again."
            }
            return "Translation failed: \(details)"
        case .emptyTranslation:
            return "Translation returned empty text. Please try again."
        }
    }

    func finishTranslationState(
        requestId: UUID,
        rawText: String,
        effectiveEnglishText: String?,
        sourceLanguageCode: String,
        decision: TranslationDecision,
        statusMessage: String
    ) async {
        guard isRequestActive(requestId) else {
            translationDebug("finish skipped: inactive request id=\(requestId.uuidString)")
            return
        }

        translationDebug(
            "finish request id=\(requestId.uuidString) decision=\(decision.rawValue) translated=\(effectiveEnglishText != nil)"
        )
        isTranslating = false
        translationStatusText = effectiveEnglishText == nil ? "Blocked" : ""
        translationDownloadProgress = nil
        effectiveSearchText = effectiveEnglishText ?? ""
        translationDiagnostics = TranslationDiagnostics(
            rawText: rawText,
            effectiveEnglishText: effectiveEnglishText,
            sourceLanguageCode: sourceLanguageCode,
            decision: decision,
            statusMessage: statusMessage
        )
        pendingTranslationRequest = nil
        activeRequestId = nil
        translationTask = nil
        pendingDownloadPrompt = nil
        isShowingDownloadPrompt = false

        await manager.search(text: effectiveEnglishText ?? "", context: modelContext)
    }

    func completeTranslation(
        requestId: UUID,
        rawText: String,
        effectiveEnglishText: String,
        sourceLanguageCode: String,
        decision: TranslationDecision,
        statusMessage: String
    ) async {
        await finishTranslationState(
            requestId: requestId,
            rawText: rawText,
            effectiveEnglishText: effectiveEnglishText,
            sourceLanguageCode: sourceLanguageCode,
            decision: decision,
            statusMessage: statusMessage
        )
    }

    func blockTranslation(
        requestId: UUID,
        rawText: String,
        decision: TranslationDecision,
        sourceLanguageCode: String,
        statusMessage: String
    ) async {
        await finishTranslationState(
            requestId: requestId,
            rawText: rawText,
            effectiveEnglishText: nil,
            sourceLanguageCode: sourceLanguageCode,
            decision: decision,
            statusMessage: statusMessage
        )
    }

    func isRequestActive(_ requestId: UUID) -> Bool {
        activeRequestId == requestId
    }

    func runPassthroughSearch(rawText: String, sourceLanguageCode: String, statusMessage: String) {
        cancelTranslationWorkIfNeeded(reason: "passthrough_search")
        translationDebug("run passthrough source=\(sourceLanguageCode) len=\(rawText.count)")
        activeRequestId = nil
        pendingTranslationRequest = nil
        translationTask = nil
        pendingDownloadPrompt = nil
        isShowingDownloadPrompt = false
        isTranslating = false
        translationStatusText = ""
        translationDownloadProgress = nil

        effectiveSearchText = rawText
        translationDiagnostics = TranslationDiagnostics(
            rawText: rawText,
            effectiveEnglishText: rawText,
            sourceLanguageCode: sourceLanguageCode,
            decision: .passthroughEnglish,
            statusMessage: statusMessage
        )

        Task {
            await manager.search(text: rawText, context: modelContext)
        }
    }

    func translationDebug(_ message: String) {
#if DEBUG
        guard isTranslationFlowDebugEnabled else { return }
        print("[TranslationFlow] \(message)")
#else
        _ = message
#endif
    }

    func translationRequestSummary() -> String {
        let active = activeRequestId?.uuidString ?? "nil"
        if let pending = pendingTranslationRequest {
            return "active=\(active) pending=\(pending.id.uuidString) src=\(pending.sourceLanguageCode) len=\(pending.rawText.count)"
        }
        return "active=\(active) pending=nil"
    }

    func ensureSupportedInputLanguagesLoaded() async {
        guard !hasLoadedSupportedLanguages, !isLoadingSupportedLanguages else {
            return
        }
        await loadSupportedInputLanguages()
    }

    func loadSupportedInputLanguages() async {
        isLoadingSupportedLanguages = true
        defer {
            isLoadingSupportedLanguages = false
        }

        var supportedIdentifiers = Set(translationProvider.supportedLanguages())
        supportedIdentifiers.insert(targetLanguageCode)

        selectedInputLanguageIdentifier = canonicalInputLanguageIdentifier(
            selectedInputLanguageIdentifier,
            supportedIdentifiers: supportedIdentifiers
        )

        var dedupedByDisplayName: [String: InputLanguageOption] = [:]
        for identifier in supportedIdentifiers {
            let option = InputLanguageOption(
                id: identifier,
                displayName: displayName(for: identifier)
            )
            let normalizedName = normalizedLanguageDisplayName(option.displayName)

            if let existingOption = dedupedByDisplayName[normalizedName] {
                dedupedByDisplayName[normalizedName] = preferredLanguageOption(
                    existing: existingOption,
                    candidate: option,
                    selectedIdentifier: selectedInputLanguageIdentifier
                )
            } else {
                dedupedByDisplayName[normalizedName] = option
            }
        }

        supportedInputLanguages = dedupedByDisplayName
            .values
            .sorted { lhs, rhs in
                lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
            }

        if !isSupportedInputLanguageIdentifier(selectedInputLanguageIdentifier) {
            selectedInputLanguageIdentifier = supportedInputLanguages.first(where: { $0.id == targetLanguageCode })?.id
                ?? supportedInputLanguages.first?.id
                ?? targetLanguageCode
        }

        selectedInputLanguageDisplayName = resolvedSelectedInputLanguageDisplayName()
        hasLoadedSupportedLanguages = true
    }

    func isSupportedInputLanguageIdentifier(_ identifier: String) -> Bool {
        supportedInputLanguages.contains { languageOption in
            languageOption.id == identifier
        }
    }

    func resolvedSelectedInputLanguageIdentifier() -> String {
        let supportedIdentifiers = Set(supportedInputLanguages.map(\.id))
        let canonicalIdentifier = canonicalInputLanguageIdentifier(
            selectedInputLanguageIdentifier,
            supportedIdentifiers: supportedIdentifiers
        )
        if canonicalIdentifier != selectedInputLanguageIdentifier {
            selectedInputLanguageIdentifier = canonicalIdentifier
        }
        return canonicalIdentifier
    }

    func canonicalInputLanguageIdentifier(
        _ identifier: String,
        supportedIdentifiers: Set<String>
    ) -> String {
        let trimmed = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return targetLanguageCode
        }

        if let matched = exactSupportedMatch(for: trimmed, in: supportedIdentifiers) {
            return matched
        }

        let lowered = trimmed.lowercased()
        if lowered.hasPrefix("en") {
            return targetLanguageCode
        }

        if lowered.hasPrefix("zh") {
            if lowered.contains("hant") || lowered.hasSuffix("-tw") || lowered.hasSuffix("-hk") || lowered.hasSuffix("-mo") {
                if let traditional = exactSupportedMatch(for: "zh-TW", in: supportedIdentifiers) {
                    return traditional
                }
            }
            if let simplified = exactSupportedMatch(for: "zh", in: supportedIdentifiers) {
                return simplified
            }
        }

        let baseIdentifier = lowered
            .split(separator: "-")
            .first
            .map(String.init) ?? lowered

        if let baseMatch = exactSupportedMatch(for: baseIdentifier, in: supportedIdentifiers) {
            return baseMatch
        }

        return targetLanguageCode
    }

    func exactSupportedMatch(
        for identifier: String,
        in supportedIdentifiers: Set<String>
    ) -> String? {
        supportedIdentifiers.first { candidate in
            candidate.localizedCaseInsensitiveCompare(identifier) == .orderedSame
        }
    }

    func displayName(for identifier: String) -> String {
        if identifier.localizedCaseInsensitiveCompare("zh-TW") == .orderedSame {
            return "Chinese (Traditional)"
        }
        if identifier.localizedCaseInsensitiveCompare("zh") == .orderedSame {
            return "Chinese (Simplified)"
        }

        let language = Locale.Language(identifier: identifier)
        if let languageCode = language.languageCode?.identifier,
           let localizedLanguage = Locale.current.localizedString(forLanguageCode: languageCode) {
            // Keep language (and script when needed), while dropping region suffixes.
            if let scriptCode = language.script?.identifier,
               scriptCode.localizedCaseInsensitiveCompare("Latn") != .orderedSame,
               let localizedScript = Locale.current.localizedString(forScriptCode: scriptCode) {
                return "\(localizedLanguage) (\(localizedScript))"
            }
            return localizedLanguage
        }

        return identifier
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

    func resolvedSelectedInputLanguageDisplayName() -> String {
        if let selectedOption = supportedInputLanguages.first(where: { $0.id == selectedInputLanguageIdentifier }) {
            return selectedOption.displayName
        }

        return displayName(for: selectedInputLanguageIdentifier)
    }

    func normalizedLanguageDisplayName(_ displayName: String) -> String {
        displayName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
    }

    func preferredLanguageOption(existing: InputLanguageOption, candidate: InputLanguageOption, selectedIdentifier: String) -> InputLanguageOption {
        if existing.id == selectedIdentifier {
            return existing
        }
        if candidate.id == selectedIdentifier {
            return candidate
        }
        if candidate.id.count < existing.id.count {
            return candidate
        }
        if candidate.id.count == existing.id.count,
           candidate.id.localizedCaseInsensitiveCompare(existing.id) == .orderedAscending {
            return candidate
        }

        return existing
    }

    func isEnglishLanguageCode(_ identifier: String) -> Bool {
        identifier
            .split(separator: "-")
            .first?
            .localizedCaseInsensitiveCompare("en") == .orderedSame
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
