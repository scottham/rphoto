//
//  GallerySearchView.swift
//  RPhoto
//

import SwiftUI
import PhotosUI
import Photos
import SwiftData
import Translation

private struct TranslationSearchRequest: Equatable {
    let id: UUID
    let rawText: String
    let sourceLanguage: Locale.Language
    let sourceLanguageCode: String
}

private enum TranslationDecision: String, Equatable {
    case passthroughEnglish
    case translatedToEnglish
    case blockedNeedsLanguagePack
    case blockedUnsupported

    var displayLabel: String {
        switch self {
        case .passthroughEnglish:
            return "English (no translation needed)"
        case .translatedToEnglish:
            return "Translated to English"
        case .blockedNeedsLanguagePack:
            return "Language pack not installed"
        case .blockedUnsupported:
            return "Language not supported"
        }
    }

    var isBlocked: Bool {
        switch self {
        case .blockedNeedsLanguagePack, .blockedUnsupported:
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
    let language: Locale.Language
    let displayName: String
}

struct GallerySearchView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var manager = GalleryManager()
    @State private var searchText = ""
    @State private var showDebugView = false
    @State private var waitingPermissionRefresh = false
    @AppStorage("search_input_language_identifier") private var selectedInputLanguageIdentifier = "en"

    @State private var translationConfiguration: TranslationSession.Configuration?
    @State private var pendingTranslationRequest: TranslationSearchRequest?
    @State private var activeRequestId: UUID?
    @State private var effectiveSearchText = ""
    @State private var translationDiagnostics: TranslationDiagnostics?
    @State private var isTranslating = false
    @State private var translationStatusText = ""
    @State private var supportedInputLanguages: [InputLanguageOption] = [
        InputLanguageOption(id: "en", language: Locale.Language(identifier: "en"), displayName: "English")
    ]
    @State private var isLoadingSupportedLanguages = false
    @State private var selectedInputLanguageDisplayName = "English"

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
                            ProgressView(translationStatusText)
                                .padding(.horizontal)
                        }
                    }
                    .padding(.top, 8)
                }

                // Search Bar
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.gray)
                    TextField("Search your photos (e.g. 'cat', 'sunset')...", text: $searchText)
                        .onSubmit {
                            submitSearchPipeline()
                        }
                        .submitLabel(.search)

                    #if !targetEnvironment(macCatalyst)
                    if !ProcessInfo.processInfo.isiOSAppOnMac {
                        Menu {
                            if isLoadingSupportedLanguages {
                                Text("Loading languages...")
                            }

                            Picker("Input Language", selection: $selectedInputLanguageIdentifier) {
                                ForEach(supportedInputLanguages) { languageOption in
                                    Text(languageOption.displayName).tag(languageOption.id)
                                }
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Text(selectedInputLanguageShortCode)
                                    .font(.caption)
                                    .fontWeight(.semibold)
                                Image(systemName: "chevron.up.chevron.down")
                                    .font(.caption2)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                            .background(Color(.systemGray5))
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        }
                        .accessibilityLabel("Input language")
                        .accessibilityValue(selectedInputLanguageDisplayName)
                    }
                    #endif

                    if !searchText.isEmpty {
                        Button(action: {
                            searchText = ""
                            clearSearchPipeline()
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

                if shouldShowTranslationPanel {
                    translationDiagnosticsPanel
                        .padding(.horizontal)
                        .padding(.top, 8)
                }

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
                                Text("Semantic Search")
                                    .font(.headline)
                                    .foregroundStyle(.primary)
                                Image(systemName: "chevron.down")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }

                            if let ss = manager.searchStats {
                                Text(String(format: "Tok: %.0fms | Enc: %.0fms | Sim: %.0fms | Total: %.0fms",
                                            ss.tokenization * 1000,
                                            ss.textEncoding * 1000,
                                            ss.similarity * 1000,
                                            ss.total * 1000))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            } else if let es = manager.encodingStats {
                                Text(String(format: "Img: %.2fs total | %.2fs avg (%d)",
                                            es.total, es.average, manager.newlyEncodedCount))
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
                    await loadSupportedInputLanguages()
                    await rerunWithEffectiveQuery()
                }
            }
            .task {
                await manager.bootstrapPhotoAccess(context: modelContext)
                await loadSupportedInputLanguages()
            }
            .translationTask(translationConfiguration) { session in
                await handleTranslation(using: session)
            }
        }
    }
}

private extension GallerySearchView {
    var isRunningOnMac: Bool {
        ProcessInfo.processInfo.isiOSAppOnMac
    }

    var shouldShowTranslationPanel: Bool {
        guard !isRunningOnMac else { return false }
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

    var translationDiagnosticsPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
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
            }

            if let diagnostics = translationDiagnostics {
                Text(diagnostics.statusMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(10)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

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

    func submitSearchPipeline() {
        let normalizedText = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedText.isEmpty else {
            clearSearchPipeline()
            return
        }

        // On Mac, Translation framework is unavailable — always search directly
        if isRunningOnMac {
            runPassthroughSearch(
                rawText: normalizedText,
                sourceLanguageCode: "en",
                statusMessage: "Searching in English."
            )
            return
        }

        let selectedSourceLanguage = resolvedSelectedInputLanguage()
        let selectedSourceLanguageCode = inputLanguageIdentifier(for: selectedSourceLanguage)

        if isEnglish(language: selectedSourceLanguage) {
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
            sourceLanguage: selectedSourceLanguage,
            sourceLanguageCode: selectedSourceLanguageCode
        )
        pendingTranslationRequest = request
        activeRequestId = request.id
        effectiveSearchText = ""
        translationDiagnostics = nil
        isTranslating = true
            translationStatusText = "Checking language availability..."

        let targetEnglish = Locale.Language(identifier: "en")
        var config = TranslationSession.Configuration(
            source: request.sourceLanguage,
            target: targetEnglish
        )
        config.invalidate()
        translationConfiguration = config
    }

    func clearSearchPipeline() {
        activeRequestId = nil
        pendingTranslationRequest = nil
        effectiveSearchText = ""
        translationDiagnostics = nil
        isTranslating = false
        translationStatusText = ""
        translationConfiguration = nil

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

    func handleTranslation(using session: TranslationSession) async {
        guard
            let request = pendingTranslationRequest,
            activeRequestId == request.id
        else {
            return
        }

        let requestId = request.id
        let rawText = request.rawText
        let targetEnglish = Locale.Language(identifier: "en")
        let availability = LanguageAvailability()
        let sourceLanguage = request.sourceLanguage
        let sourceLanguageCode = request.sourceLanguageCode

        do {
        translationStatusText = "Checking language availability..."
            let statusToEnglish = await availability.status(from: sourceLanguage, to: targetEnglish)
            guard isRequestActive(requestId) else {
                return
            }

            switch statusToEnglish {
            case .installed:
                translationStatusText = "Translating..."
                let response = try await session.translate(rawText)
                guard isRequestActive(requestId) else {
                    return
                }

                let translatedText = response.targetText.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !translatedText.isEmpty else {
                    await blockTranslation(
                        requestId: requestId,
                        rawText: rawText,
                        decision: .blockedUnsupported,
                        sourceLanguageCode: sourceLanguageCode,
                        statusMessage: "Translation returned empty. Please check your language packs in the Translate app."
                    )
                    return
                }

                await completeTranslation(
                    requestId: requestId,
                    rawText: rawText,
                    effectiveEnglishText: translatedText,
                    sourceLanguageCode: inputLanguageIdentifier(for: response.sourceLanguage),
                    decision: .translatedToEnglish,
                    statusMessage: "Translated and searching."
                )

            case .supported:
                let langName = displayName(for: sourceLanguageCode)
                await blockTranslation(
                    requestId: requestId,
                    rawText: rawText,
                    decision: .blockedNeedsLanguagePack,
                    sourceLanguageCode: sourceLanguageCode,
                    statusMessage: "Please install the \"\(langName) → English\" language pack in the Translate app, then try again."
                )

            case .unsupported:
                await blockTranslation(
                    requestId: requestId,
                    rawText: rawText,
                    decision: .blockedUnsupported,
                    sourceLanguageCode: sourceLanguageCode,
                    statusMessage: "This language is not supported for translation."
                )
            @unknown default:
                await blockTranslation(
                    requestId: requestId,
                    rawText: rawText,
                    decision: .blockedUnsupported,
                    sourceLanguageCode: sourceLanguageCode,
                    statusMessage: "Unable to check language availability. Please verify language packs in the Translate app."
                )
            }
        } catch {
            guard isRequestActive(requestId) else {
                return
            }

            let statusMessage: String
            if TranslationError.unsupportedSourceLanguage ~= error ||
                TranslationError.unsupportedTargetLanguage ~= error ||
                TranslationError.unsupportedLanguagePairing ~= error {
                statusMessage = "This language cannot be translated on this device. Check language packs in the Translate app."
            } else {
                statusMessage = "Translation failed. Check language packs in the Translate app and try again."
            }

            await blockTranslation(
                requestId: requestId,
                rawText: rawText,
                decision: .blockedUnsupported,
                sourceLanguageCode: sourceLanguageCode,
                statusMessage: statusMessage
            )
        }
    }

    func completeTranslation(
        requestId: UUID,
        rawText: String,
        effectiveEnglishText: String,
        sourceLanguageCode: String,
        decision: TranslationDecision,
        statusMessage: String
    ) async {
        guard isRequestActive(requestId) else {
            return
        }

        isTranslating = false
        translationStatusText = ""
        effectiveSearchText = effectiveEnglishText
        translationDiagnostics = TranslationDiagnostics(
            rawText: rawText,
            effectiveEnglishText: effectiveEnglishText,
            sourceLanguageCode: sourceLanguageCode,
            decision: decision,
            statusMessage: statusMessage
        )
        pendingTranslationRequest = nil
        activeRequestId = nil

        await manager.search(text: effectiveEnglishText, context: modelContext)
    }

    func blockTranslation(
        requestId: UUID,
        rawText: String,
        decision: TranslationDecision,
        sourceLanguageCode: String,
        statusMessage: String
    ) async {
        guard isRequestActive(requestId) else {
            return
        }

        isTranslating = false
        translationStatusText = "Blocked"
        effectiveSearchText = ""
        translationDiagnostics = TranslationDiagnostics(
            rawText: rawText,
            effectiveEnglishText: nil,
            sourceLanguageCode: sourceLanguageCode,
            decision: decision,
            statusMessage: statusMessage
        )
        pendingTranslationRequest = nil
        activeRequestId = nil

        await manager.search(text: "", context: modelContext)
    }

    func isRequestActive(_ requestId: UUID) -> Bool {
        activeRequestId == requestId
    }

    func runPassthroughSearch(rawText: String, sourceLanguageCode: String, statusMessage: String) {
        activeRequestId = nil
        pendingTranslationRequest = nil
        translationConfiguration = nil
        isTranslating = false
        translationStatusText = ""

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

    func loadSupportedInputLanguages() async {
        guard !isRunningOnMac else { return }

        isLoadingSupportedLanguages = true
        defer {
            isLoadingSupportedLanguages = false
        }

        let availability = LanguageAvailability()
        var supported = await availability.supportedLanguages
        supported.append(Locale.Language(identifier: "en"))

        var dedupedByIdentifier: [String: Locale.Language] = [:]
        for language in supported {
            let identifier = inputLanguageIdentifier(for: language)
            // Collapse all English variants (en-US, en-GB, en-AU, ...) into plain "en"
            let key = isEnglish(language: language) ? "en" : identifier
            if dedupedByIdentifier[key] == nil {
                dedupedByIdentifier[key] = isEnglish(language: language)
                    ? Locale.Language(identifier: "en")
                    : language
            }
        }

        var dedupedByDisplayName: [String: InputLanguageOption] = [:]
        for (identifier, language) in dedupedByIdentifier {
            let option = InputLanguageOption(
                id: identifier,
                language: language,
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
            selectedInputLanguageIdentifier = supportedInputLanguages.first(where: { $0.id == "en" })?.id
                ?? supportedInputLanguages.first?.id
                ?? "en"
        }

        selectedInputLanguageDisplayName = resolvedSelectedInputLanguageDisplayName()
    }

    func isSupportedInputLanguageIdentifier(_ identifier: String) -> Bool {
        supportedInputLanguages.contains { languageOption in
            languageOption.id == identifier
        }
    }

    func resolvedSelectedInputLanguage() -> Locale.Language {
        if let matchedLanguage = supportedInputLanguages.first(where: { $0.id == selectedInputLanguageIdentifier }) {
            return matchedLanguage.language
        }

        return Locale.Language(identifier: selectedInputLanguageIdentifier)
    }

    func inputLanguageIdentifier(for language: Locale.Language) -> String {
        guard let languageCode = language.languageCode?.identifier else {
            return language.minimalIdentifier
        }

        var parts: [String] = [languageCode]
        if let script = language.script?.identifier, script != "Latn" {
            parts.append(script)
        }
        if let region = language.region?.identifier {
            parts.append(region)
        }

        return parts.joined(separator: "-")
    }

    func displayName(for identifier: String) -> String {
        if let localized = Locale.current.localizedString(forIdentifier: identifier) {
            return localized
        }

        let languageCode = identifier.split(separator: "-").first.map(String.init)
        if let languageCode, let localizedLanguage = Locale.current.localizedString(forLanguageCode: languageCode) {
            return localizedLanguage
        }

        return identifier
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

    func isEnglish(language: Locale.Language) -> Bool {
        language.languageCode?.identifier == "en"
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
