//
//  GallerySearchView.swift
//  RPhoto
//

import SwiftUI
import PhotosUI
import Photos
import SwiftData
import Translation
import NaturalLanguage

private struct TranslationSearchRequest: Equatable {
    let id: UUID
    let rawText: String
    let detectedLanguage: Locale.Language?
    let detectedLanguageCode: String?
}

private enum TranslationDecision: String, Equatable {
    case passthroughEnglish
    case translatedToEnglish
    case blockedNeedsLanguagePack
    case blockedUnsupported

    var displayLabel: String {
        switch self {
        case .passthroughEnglish:
            return "passthroughEnglish"
        case .translatedToEnglish:
            return "translatedToEnglish"
        case .blockedNeedsLanguagePack:
            return "blockedNeedsLanguagePack"
        case .blockedUnsupported:
            return "blockedUnsupported"
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
    let detectedLanguageCode: String?
    let decision: TranslationDecision
    let statusMessage: String
}

struct GallerySearchView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var manager = GalleryManager()
    @State private var searchText = ""
    @State private var showDebugView = false
    @State private var waitingPermissionRefresh = false

    @State private var translationConfiguration: TranslationSession.Configuration?
    @State private var pendingTranslationRequest: TranslationSearchRequest?
    @State private var activeRequestId: UUID?
    @State private var effectiveSearchText = ""
    @State private var translationDiagnostics: TranslationDiagnostics?
    @State private var isTranslating = false
    @State private var translationStatusText = ""

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
            .translationTask(translationConfiguration) { session in
                await handleTranslation(using: session)
            }
        }
    }
}

private extension GallerySearchView {
    var shouldShowTranslationPanel: Bool {
        isTranslating || translationDiagnostics != nil
    }

    var translationStageLabel: String {
        if isTranslating {
            return translationStatusText
        }

        guard let diagnostics = translationDiagnostics else {
            return "Idle"
        }

        if diagnostics.decision.isBlocked {
            return "Blocked"
        }

        return "Ready"
    }

    var translationStageIcon: String {
        if isTranslating {
            return "globe.badge.chevron.backward"
        }

        guard let diagnostics = translationDiagnostics else {
            return "globe"
        }

        return diagnostics.decision.isBlocked ? "exclamationmark.triangle.fill" : "checkmark.circle.fill"
    }

    var translationStageColor: Color {
        if isTranslating {
            return .secondary
        }

        guard let diagnostics = translationDiagnostics else {
            return .secondary
        }

        return diagnostics.decision.isBlocked ? .red : .green
    }

    var translationDiagnosticsPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: translationStageIcon)
                    .foregroundStyle(translationStageColor)
                Text("Multilingual Query Pipeline")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                Spacer()
                Text(translationStageLabel)
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(translationStageColor)
            }

            if isTranslating {
                if let pendingTranslationRequest {
                    Text("Input: \(pendingTranslationRequest.rawText)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(translationStatusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let diagnostics = translationDiagnostics {
                Text("Decision: \(diagnostics.decision.displayLabel)")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text("Input: \(diagnostics.rawText)")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let detectedLanguageCode = diagnostics.detectedLanguageCode {
                    Text("Detected language: \(detectedLanguageCode)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let effectiveEnglishText = diagnostics.effectiveEnglishText {
                    Text("English query: \(effectiveEnglishText)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Text(diagnostics.statusMessage)
                    .font(.caption)
                    .foregroundStyle(diagnostics.decision.isBlocked ? .red : .secondary)
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

        let detectedLanguage = detectLanguage(for: normalizedText)
        let detectedLanguageCode = detectedLanguage?.languageCode?.identifier
        let isEnglishInput =
            detectedLanguageCode == "en" ||
            (detectedLanguage == nil && isLikelyEnglishText(normalizedText))

        if isEnglishInput {
            let effectiveLanguageCode = detectedLanguageCode ?? "en"
            runPassthroughSearch(
                rawText: normalizedText,
                detectedLanguageCode: effectiveLanguageCode,
                statusMessage: "Input appears to be English. Search ran without translation."
            )
            return
        }

        let request = TranslationSearchRequest(
            id: UUID(),
            rawText: normalizedText,
            detectedLanguage: detectedLanguage,
            detectedLanguageCode: detectedLanguageCode
        )
        pendingTranslationRequest = request
        activeRequestId = request.id
        effectiveSearchText = ""
        translationDiagnostics = nil
        isTranslating = true
        translationStatusText = "Checking language"

        let targetEnglish = Locale.Language(identifier: "en")
        if translationConfiguration == nil {
            translationConfiguration = TranslationSession.Configuration(
                source: request.detectedLanguage,
                target: targetEnglish
            )
        } else {
            var config = translationConfiguration!
            config.source = request.detectedLanguage
            config.target = targetEnglish
            config.invalidate()
            translationConfiguration = config
        }
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
        let detectedLanguage = request.detectedLanguage
        let detectedLanguageCode = request.detectedLanguageCode

        do {
            translationStatusText = "Checking language"
            if let detectedLanguage {
                let statusToEnglish = await availability.status(from: detectedLanguage, to: targetEnglish)
                guard isRequestActive(requestId) else {
                    return
                }

                switch statusToEnglish {
                case .installed:
                    translationStatusText = "Translating"
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
                            detectedLanguageCode: detectedLanguageCode,
                            statusMessage: "Translation returned an empty result. Open Apple's Translate app to verify language packs, then try again."
                        )
                        return
                    }

                    await completeTranslation(
                        requestId: requestId,
                        rawText: rawText,
                        effectiveEnglishText: translatedText,
                        detectedLanguageCode: response.sourceLanguage.languageCode?.identifier ?? detectedLanguageCode,
                        decision: .translatedToEnglish,
                        statusMessage: "Translated to English and executed semantic search."
                    )

                case .supported:
                    await blockTranslation(
                        requestId: requestId,
                        rawText: rawText,
                        decision: .blockedNeedsLanguagePack,
                        detectedLanguageCode: detectedLanguageCode,
                        statusMessage: "Translation resources are not installed for this language pair. Open Apple's Translate app and download the required language pack, then try again."
                    )

                case .unsupported:
                    await blockTranslation(
                        requestId: requestId,
                        rawText: rawText,
                        decision: .blockedUnsupported,
                        detectedLanguageCode: detectedLanguageCode,
                        statusMessage: "The detected language is not supported for translation to English. Open Apple's Translate app to verify available language packs."
                    )
                }
            } else {
                let statusToEnglish = try await availability.status(for: rawText, to: targetEnglish)
                guard isRequestActive(requestId) else {
                    return
                }

                switch statusToEnglish {
                case .installed:
                    translationStatusText = "Translating"
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
                            detectedLanguageCode: nil,
                            statusMessage: "Translation returned an empty result. Open Apple's Translate app to verify language packs, then try again."
                        )
                        return
                    }

                    await completeTranslation(
                        requestId: requestId,
                        rawText: rawText,
                        effectiveEnglishText: translatedText,
                        detectedLanguageCode: response.sourceLanguage.languageCode?.identifier,
                        decision: .translatedToEnglish,
                        statusMessage: "Translated to English and executed semantic search."
                    )

                case .supported:
                    await blockTranslation(
                        requestId: requestId,
                        rawText: rawText,
                        decision: .blockedNeedsLanguagePack,
                        detectedLanguageCode: nil,
                        statusMessage: "Translation resources are not installed for this language pair. Open Apple's Translate app and download the required language pack, then try again."
                    )

                case .unsupported:
                    let statusToAny = try await availability.status(for: rawText, to: nil)
                    guard isRequestActive(requestId) else {
                        return
                    }

                    if statusToAny == .installed || statusToAny == .supported {
                        await completeTranslation(
                            requestId: requestId,
                            rawText: rawText,
                            effectiveEnglishText: rawText,
                            detectedLanguageCode: "en",
                            decision: .passthroughEnglish,
                            statusMessage: "Input appears to be English. Search ran without translation."
                        )
                    } else {
                        await blockTranslation(
                            requestId: requestId,
                            rawText: rawText,
                            decision: .blockedUnsupported,
                            detectedLanguageCode: nil,
                            statusMessage: "Unable to identify a supported source language for English translation. Open Apple's Translate app to verify language packs, then try again."
                        )
                    }
                }
            }
        } catch {
            guard isRequestActive(requestId) else {
                return
            }

            if TranslationError.unableToIdentifyLanguage ~= error, isLikelyEnglishText(rawText) {
                await completeTranslation(
                    requestId: requestId,
                    rawText: rawText,
                    effectiveEnglishText: rawText,
                    detectedLanguageCode: "en",
                    decision: .passthroughEnglish,
                    statusMessage: "Input appears to be English. Search ran without translation."
                )
                return
            }

            let statusMessage: String
            if TranslationError.unableToIdentifyLanguage ~= error {
                statusMessage = "Could not identify the query language. Open Apple's Translate app to verify/download language packs, then try again."
            } else {
                statusMessage = "Translation failed. Open Apple's Translate app to verify/download language packs, then try again."
            }

            await blockTranslation(
                requestId: requestId,
                rawText: rawText,
                decision: .blockedUnsupported,
                detectedLanguageCode: nil,
                statusMessage: statusMessage
            )
        }
    }

    func completeTranslation(
        requestId: UUID,
        rawText: String,
        effectiveEnglishText: String,
        detectedLanguageCode: String?,
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
            detectedLanguageCode: detectedLanguageCode,
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
        detectedLanguageCode: String?,
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
            detectedLanguageCode: detectedLanguageCode,
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

    func runPassthroughSearch(rawText: String, detectedLanguageCode: String?, statusMessage: String) {
        activeRequestId = nil
        pendingTranslationRequest = nil
        translationConfiguration = nil
        isTranslating = false
        translationStatusText = ""

        effectiveSearchText = rawText
        translationDiagnostics = TranslationDiagnostics(
            rawText: rawText,
            effectiveEnglishText: rawText,
            detectedLanguageCode: detectedLanguageCode,
            decision: .passthroughEnglish,
            statusMessage: statusMessage
        )

        Task {
            await manager.search(text: rawText, context: modelContext)
        }
    }

    func detectLanguage(for text: String) -> Locale.Language? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)

        guard let language = recognizer.dominantLanguage else {
            return nil
        }

        return Locale.Language(identifier: language.rawValue)
    }

    func isLikelyEnglishText(_ text: String) -> Bool {
        let hasLatinLetters = text.range(of: "[A-Za-z]", options: .regularExpression) != nil
        let asciiLikePattern = "^[A-Za-z0-9\\s\\p{P}]+$"
        let isAsciiLike = text.range(of: asciiLikePattern, options: .regularExpression) != nil
        return hasLatinLetters && isAsciiLike
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
