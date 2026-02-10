//
//  GalleryManager.swift
//  RPhoto
//

import CoreML
import Foundation
import Photos
import SwiftData
import SwiftUI

struct GalleryImage: Identifiable {
    let id = UUID()
    let sourceId: String
    var image: UIImage?
    let embedding: [Float]
    var similarityScore: Float = 0
}

@MainActor
class GalleryManager: ObservableObject {
    @Published var displayedImages: [GalleryImage] = []
    @Published var isProcessing = false
    @Published var processingProgress: Double = 0
    @Published var processingStatusText = "Processing Images..."
    @Published var isSearching = false
    @Published var searchProgress: Double = 0
    @Published var searchStatusText = "Searching photos..."
    @Published var photoAuthorizationStatus: PHAuthorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    @Published var topK: Int = 20 {
        didSet {
            if !lastSearchText.isEmpty {
                Task {
                    await updateDisplayedImages()
                }
            }
        }
    }

    @Published var selectedModel: ModelConfiguration = defaultModel
    @Published var encodingStats: (total: Double, average: Double)?

    private var allImages: [GalleryImage] = []
    private var selectedAssetIds: [String] = []
    private var hasPreparedIndexForCurrentModel = false
    private var isPreparingIndex = false
    private var didRunBootstrap = false

    var totalEncodedCount: Int {
        allImages.count
    }

    @Published var newlyEncodedCount: Int = 0
    @Published var newlyLoadedFromCacheCount: Int = 0

    private var lastSearchText: String = ""
    private var model: CLIPEncoder
    private var tokenizer: AsyncFactory<CLIPTokenizer>
    private let photoLibraryService = PhotoLibraryService()
    private var cacheResetObserver: NSObjectProtocol?

    init() {
        self.model = defaultModel.factory()
        self.tokenizer = AsyncFactory {
            CLIPTokenizer(
                vocabFileName: defaultModel.vocabName,
                mergesFileName: defaultModel.mergesName
            )
        }
        self.cacheResetObserver = NotificationCenter.default.addObserver(
            forName: .galleryDataDidReset,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.resetInMemoryIndex()
            }
        }

        Task {
            await self.model.load()
        }
    }

    deinit {
        if let observer = cacheResetObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    var isLimitedAuthorization: Bool {
        photoAuthorizationStatus == .limited
    }

    func setModel(_ config: ModelConfiguration) async {
        guard config != selectedModel else { return }

        selectedModel = config
        model = config.factory()
        tokenizer = AsyncFactory {
            CLIPTokenizer(vocabFileName: config.vocabName, mergesFileName: config.mergesName)
        }

        resetInMemoryIndex()
        encodingStats = nil

        await model.load()
    }

    func bootstrapPhotoAccess(context: ModelContext) async {
        guard !didRunBootstrap else { return }
        didRunBootstrap = true
        let previousStatus = photoLibraryService.currentAuthorizationStatus()
        let status = await photoLibraryService.requestReadAuthorizationIfNeeded()
        photoAuthorizationStatus = status

        guard status == .authorized || status == .limited else {
            return
        }

        // Keep first-install behavior: if the very first permission grant happens with no persisted data,
        // perform one initial sync. Later permission updates are always manual via Sync button.
        if previousStatus == .notDetermined, !hasPersistedGalleryData(context: context) {
            await syncAccessibleAssetsForCurrentPermission(context: context)
            return
        }

        await restoreCachedIndexOnLaunch(context: context)
    }

    func requestOrSyncPhotoAccess(context: ModelContext) async {
        let status = await photoLibraryService.requestReadAuthorizationIfNeeded()
        photoAuthorizationStatus = status
        guard status == .authorized || status == .limited else {
            resetInMemoryIndex()
            return
        }
        await syncAccessibleAssetsForCurrentPermission(context: context)
    }

    func refreshAfterPermissionPotentiallyChanged(context _: ModelContext) async {
        photoAuthorizationStatus = photoLibraryService.currentAuthorizationStatus()
        guard photoAuthorizationStatus == .authorized || photoAuthorizationStatus == .limited else {
            resetInMemoryIndex()
            return
        }
    }

    func openPhotoSettings() {
        photoLibraryService.openPhotoSettings()
    }

    @discardableResult
    func presentLimitedLibraryPicker() -> Bool {
        photoLibraryService.presentLimitedLibraryPickerIfPossible()
    }

    func ensureIndexReady(context: ModelContext) async {
        guard !hasPreparedIndexForCurrentModel else { return }
        guard !isPreparingIndex else { return }

        isPreparingIndex = true
        isProcessing = true
        processingStatusText = "Restoring search index..."
        processingProgress = 0
        newlyEncodedCount = 0
        newlyLoadedFromCacheCount = 0

        defer {
            isPreparingIndex = false
            isProcessing = false
        }

        photoAuthorizationStatus = photoLibraryService.currentAuthorizationStatus()
        guard photoAuthorizationStatus == .authorized || photoAuthorizationStatus == .limited else {
            processingStatusText = "Photo access is required."
            resetInMemoryIndex()
            hasPreparedIndexForCurrentModel = true
            return
        }

        migrateSelectedAssetsFromLegacyCacheIfNeeded(context: context)
        processingStatusText = "Validating photo references..."
        await cleanupStaleAssets(context: context)
        processingStatusText = "Loading cached embeddings..."
        hydrateFromCache(context: context)
        processingProgress = selectedAssetIds.isEmpty ? 1.0 : 0.5
        processingStatusText = "Encoding missing embeddings..."
        await backfillMissingEmbeddings(
            context: context,
            progressStart: 0.5,
            progressSpan: 0.5
        )
        processingProgress = 1.0

        hasPreparedIndexForCurrentModel = true
    }

    func cleanupStaleAssets(context: ModelContext) async {
        if photoAuthorizationStatus == .limited {
            return
        }

        do {
            let selectedAssets = try context.fetch(FetchDescriptor<SelectedAsset>())
            let selectedIds = selectedAssets.map(\.id)
            let existingIds = photoLibraryService.existingAssetIdentifiers(localIdentifiers: selectedIds)
            var staleIds: [String] = []

            for asset in selectedAssets {
                if existingIds.contains(asset.id) {
                    asset.lastValidatedAt = Date()
                } else {
                    staleIds.append(asset.id)
                }
            }

            cleanupStaleAssets(ids: staleIds, context: context)
            try? context.save()
        } catch {
            print("Failed to cleanup stale assets: \(error)")
        }
    }

    func search(text: String, context: ModelContext) async {
        lastSearchText = text

        guard !text.isEmpty else {
            displayedImages = []
            trimImageCache(keeping: [])
            isSearching = false
            searchProgress = 0
            searchStatusText = "Searching photos..."
            return
        }

        isSearching = true
        searchProgress = 0
        searchStatusText = "Preparing search index..."
        defer {
            isSearching = false
        }

        await ensureIndexReady(context: context)
        guard !allImages.isEmpty else {
            displayedImages = []
            searchProgress = 1
            searchStatusText = "No indexed photos available."
            return
        }

        do {
            searchStatusText = "Encoding query..."
            let tokenIds = await tokenizer.get().encode_full(
                text: text,
                padTokenId: selectedModel.padTokenId
            )
            let inputBox = try MLMultiArray(shape: [1, 77], dataType: .int32)
            for (index, value) in tokenIds.enumerated() {
                inputBox[index] = NSNumber(value: value)
            }

            let textEmbedding = try await model.encode(text: inputBox)
            guard let normalizedQueryEmbedding = normalizedEmbedding(from: textEmbedding) else {
                displayedImages = []
                searchProgress = 0
                searchStatusText = "Search failed."
                return
            }

            searchProgress = 0.15
            searchStatusText = "Calculating similarities..."
            await scoreAllImages(
                using: normalizedQueryEmbedding,
                progressStart: 0.15,
                progressSpan: 0.65
            )

            searchStatusText = "Loading top results..."
            await updateDisplayedImages(
                searchProgressStart: 0.8,
                searchProgressSpan: 0.2
            )
            searchProgress = 1
            searchStatusText = "Search completed."
        } catch {
            print("Search failed: \(error)")
            searchProgress = 0
            searchStatusText = "Search failed."
        }
    }

    private func migrateSelectedAssetsFromLegacyCacheIfNeeded(context: ModelContext) {
        do {
            let selectedAssets = try context.fetch(FetchDescriptor<SelectedAsset>())
            guard selectedAssets.isEmpty else { return }

            let cachedEmbeddings = try context.fetch(FetchDescriptor<CachedEmbedding>())
            let legacyIds = Array(Set(cachedEmbeddings.map(\.imageId))).sorted()
            guard !legacyIds.isEmpty else { return }

            for id in legacyIds {
                context.insert(SelectedAsset(id: id))
            }

            try? context.save()
        } catch {
            print("Legacy migration failed: \(error)")
        }
    }

    private func hydrateFromCache(context: ModelContext) {
        do {
            let selectedAssets = try context.fetch(FetchDescriptor<SelectedAsset>())
            selectedAssetIds = selectedAssets.map(\.id).sorted()

            guard !selectedAssetIds.isEmpty else {
                allImages = []
                newlyLoadedFromCacheCount = 0
                return
            }

            let existingImagesById: [String: UIImage] = Dictionary(
                uniqueKeysWithValues: allImages.compactMap { galleryImage -> (String, UIImage)? in
                    guard let uiImage = galleryImage.image else { return nil }
                    return (galleryImage.sourceId, uiImage)
                }
            )

            let cacheMap = try fetchCachedEmbeddingsMap(
                imageIds: selectedAssetIds,
                modelName: selectedModel.name,
                context: context
            )

            allImages = []
            var cacheHitCount = 0

            for id in selectedAssetIds {
                guard
                    let cached = cacheMap[id],
                    let vector = cached.getEmbeddingVector(),
                    let normalizedVector = normalizedEmbedding(from: vector)
                else {
                    continue
                }

                cached.lastAccessed = Date()
                cacheHitCount += 1
                allImages.append(
                    GalleryImage(
                        sourceId: id,
                        image: existingImagesById[id],
                        embedding: normalizedVector
                    )
                )
            }

            newlyLoadedFromCacheCount = cacheHitCount
        } catch {
            print("Hydrate from cache failed: \(error)")
            selectedAssetIds = []
            allImages = []
            newlyLoadedFromCacheCount = 0
        }
    }

    private func backfillMissingEmbeddings(
        context: ModelContext,
        progressStart: Double,
        progressSpan: Double
    ) async {
        let existingIds = Set(allImages.map(\.sourceId))
        let missingIds = selectedAssetIds.filter { !existingIds.contains($0) }
        guard !missingIds.isEmpty else { return }

        var encodedCount = 0
        let total = Double(missingIds.count)

        for (offset, id) in missingIds.enumerated() {
            defer {
                let progress = progressStart + (Double(offset + 1) / total * progressSpan)
                processingProgress = min(max(progress, 0), 1)
            }

            guard photoLibraryService.assetExists(localIdentifier: id) else {
                cleanupStaleAssets(ids: [id], context: context)
                continue
            }

            guard
                let uiImage = await photoLibraryService.loadUIImageForEncoding(
                    localIdentifier: id,
                    targetSize: model.targetImageSize
                ),
                let pixelBuffer = uiImage.pixelBuffer(
                    width: Int(model.targetImageSize.width),
                    height: Int(model.targetImageSize.height)
                )
            else {
                continue
            }

            do {
                let embedding = try await model.encode(image: pixelBuffer)
                guard let normalizedVector = normalizedEmbedding(from: embedding) else {
                    continue
                }

                upsertInMemoryImage(sourceId: id, embedding: normalizedVector)
                encodedCount += 1

                let cachedObject = CachedEmbedding.from(
                    vector: normalizedVector,
                    imageId: id,
                    modelName: selectedModel.name
                )
                context.insert(cachedObject)
            } catch {
                print("Backfill failed for \(id): \(error)")
            }
        }

        try? context.save()
        newlyEncodedCount = encodedCount
    }

    private func scoreAllImages(
        using textEmbedding: [Float],
        progressStart: Double,
        progressSpan: Double
    ) async {
        let total = allImages.count
        guard total > 0 else { return }

        let updateStride = max(total / 30, 1)

        for index in 0..<total {
            allImages[index].similarityScore = cosineSimilarity(
                allImages[index].embedding,
                textEmbedding
            )

            if index % updateStride == 0 || index == total - 1 {
                let fraction = Double(index + 1) / Double(total)
                let progress = progressStart + fraction * progressSpan
                searchProgress = min(max(progress, 0), 1)
            }

            if index % 200 == 0 {
                await Task.yield()
            }
        }
    }

    private func updateDisplayedImages(
        searchProgressStart: Double? = nil,
        searchProgressSpan: Double = 0
    ) async {
        if lastSearchText.isEmpty {
            displayedImages = []
            trimImageCache(keeping: [])
            return
        }

        let sortedIndices = allImages.indices.sorted {
            allImages[$0].similarityScore > allImages[$1].similarityScore
        }
        let topIndices = sortedIndices.prefix(topK)
        let topCount = topIndices.count

        let thumbnailSize = CGSize(width: 600, height: 600)
        var resultImages: [GalleryImage] = []

        for (offset, index) in topIndices.enumerated() {
            var image = allImages[index]

            if image.image == nil {
                if let uiImage = await photoLibraryService.loadUIImage(
                    localIdentifier: image.sourceId,
                    targetSize: thumbnailSize
                ) {
                    image.image = uiImage
                    allImages[index].image = uiImage
                }
            }

            resultImages.append(image)

            if let searchProgressStart {
                let fraction = topCount == 0 ? 1 : Double(offset + 1) / Double(topCount)
                let progress = searchProgressStart + fraction * searchProgressSpan
                searchProgress = min(max(progress, 0), 1)
            }
        }

        displayedImages = resultImages.filter { $0.image != nil }
        trimImageCache(keeping: Set(displayedImages.map(\.sourceId)))
    }

    private func fetchCachedEmbeddingsMap(
        imageIds: [String],
        modelName: String,
        context: ModelContext
    ) throws -> [String: CachedEmbedding] {
        guard !imageIds.isEmpty else {
            return [:]
        }

        let compositeKeys = imageIds.map { "\($0)|\(modelName)" }
        let descriptor = FetchDescriptor<CachedEmbedding>(
            predicate: #Predicate { compositeKeys.contains($0.id) }
        )
        let results = try context.fetch(descriptor)

        var map: [String: CachedEmbedding] = [:]
        for cached in results {
            map[cached.imageId] = cached
        }
        return map
    }

    private func hasPersistedGalleryData(context: ModelContext) -> Bool {
        do {
            let selectedCount = try context.fetchCount(FetchDescriptor<SelectedAsset>())
            if selectedCount > 0 {
                return true
            }

            let cachedCount = try context.fetchCount(FetchDescriptor<CachedEmbedding>())
            return cachedCount > 0
        } catch {
            print("Failed to inspect persisted gallery data: \(error)")
            return false
        }
    }

    private func persistSelectedAssets(ids: [String], context: ModelContext) throws -> [String] {
        guard !ids.isEmpty else { return [] }

        let descriptor = FetchDescriptor<SelectedAsset>(
            predicate: #Predicate { ids.contains($0.id) }
        )
        let existing = try context.fetch(descriptor)
        let existingIds = Set(existing.map(\.id))

        for asset in existing {
            asset.lastValidatedAt = Date()
        }

        var newlyInsertedIds: [String] = []
        for id in ids where !existingIds.contains(id) {
            context.insert(SelectedAsset(id: id))
            newlyInsertedIds.append(id)
        }

        try context.save()
        return newlyInsertedIds
    }

    private func syncAccessibleAssetsForCurrentPermission(context: ModelContext) async {
        guard !isPreparingIndex else { return }
        isPreparingIndex = true
        isProcessing = true
        processingStatusText = "Scanning accessible photos..."
        processingProgress = 0
        newlyEncodedCount = 0
        newlyLoadedFromCacheCount = 0

        defer {
            isPreparingIndex = false
            isProcessing = false
        }

        let status = photoAuthorizationStatus
        guard status == .authorized || status == .limited else {
            resetInMemoryIndex()
            hasPreparedIndexForCurrentModel = true
            return
        }

        migrateSelectedAssetsFromLegacyCacheIfNeeded(context: context)

        let accessibleIds = Set(photoLibraryService.fetchAccessibleImageAssetIds())
        let sortedAccessibleIds = Array(accessibleIds).sorted()

        do {
            let existingSelected = try context.fetch(FetchDescriptor<SelectedAsset>())
            let existingIds = Set(existingSelected.map(\.id))
            let removedIds = Array(existingIds.subtracting(accessibleIds))

            _ = try persistSelectedAssets(ids: sortedAccessibleIds, context: context)
            removeSelectedAssets(ids: removedIds, context: context, removeCache: status == .authorized)
        } catch {
            print("Failed to sync selected assets: \(error)")
        }

        selectedAssetIds = sortedAccessibleIds
        processingStatusText = "Loading cached embeddings..."
        hydrateFromCache(context: context)
        processingProgress = selectedAssetIds.isEmpty ? 1.0 : 0
        processingStatusText = "Encoding new photos..."
        await backfillMissingEmbeddings(
            context: context,
            progressStart: 0,
            progressSpan: 1
        )
        processingProgress = 1.0
        hasPreparedIndexForCurrentModel = true
    }

    private func restoreCachedIndexOnLaunch(context: ModelContext) async {
        guard !isPreparingIndex else { return }
        isPreparingIndex = true
        isProcessing = true
        processingStatusText = "Loading cached index..."
        processingProgress = 0
        newlyEncodedCount = 0
        newlyLoadedFromCacheCount = 0

        defer {
            isPreparingIndex = false
            isProcessing = false
        }

        migrateSelectedAssetsFromLegacyCacheIfNeeded(context: context)
        processingProgress = 0.25
        processingStatusText = "Reading cached embeddings..."
        hydrateFromCache(context: context)
        processingProgress = 0.9
        processingStatusText = "Cache ready."
        processingProgress = 1.0

        // Mark as prepared only when cache exists for current model.
        // If cache is missing (e.g., model changed), search can still trigger backfill on demand.
        hasPreparedIndexForCurrentModel = !allImages.isEmpty

        // Run stale cleanup after cache restoration so app startup is not blocked.
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.cleanupStaleAssets(context: context)
        }
    }

    private func cleanupStaleAssets(ids: [String], context: ModelContext) {
        removeSelectedAssets(ids: ids, context: context, removeCache: true)
    }

    private func removeSelectedAssets(ids: [String], context: ModelContext, removeCache: Bool) {
        let idSet = Set(ids)
        guard !idSet.isEmpty else { return }

        let idList = Array(idSet)

        do {
            let selectedDescriptor = FetchDescriptor<SelectedAsset>(
                predicate: #Predicate { idList.contains($0.id) }
            )
            let selectedAssets = try context.fetch(selectedDescriptor)
            for asset in selectedAssets {
                context.delete(asset)
            }

            if removeCache {
                let cacheDescriptor = FetchDescriptor<CachedEmbedding>(
                    predicate: #Predicate { idList.contains($0.imageId) }
                )
                let cacheItems = try context.fetch(cacheDescriptor)
                for item in cacheItems {
                    context.delete(item)
                }
            }

            allImages.removeAll { idSet.contains($0.sourceId) }
            selectedAssetIds.removeAll { idSet.contains($0) }

            try context.save()
        } catch {
            print("Failed to remove selected assets: \(error)")
        }
    }

    private func upsertInMemoryImage(
        sourceId: String,
        embedding: [Float],
        preferredImage: UIImage? = nil
    ) {
        if let index = allImages.firstIndex(where: { $0.sourceId == sourceId }) {
            let existingImage = preferredImage ?? allImages[index].image
            allImages[index] = GalleryImage(
                sourceId: sourceId,
                image: existingImage,
                embedding: embedding,
                similarityScore: 0
            )
        } else {
            allImages.append(
                GalleryImage(
                    sourceId: sourceId,
                    image: preferredImage,
                    embedding: embedding
                )
            )
        }
    }

    private func resetInMemoryIndex() {
        allImages = []
        selectedAssetIds = []
        displayedImages = []
        newlyEncodedCount = 0
        newlyLoadedFromCacheCount = 0
        hasPreparedIndexForCurrentModel = false
        isSearching = false
        searchProgress = 0
        searchStatusText = "Searching photos..."
    }

    private func trimImageCache(keeping sourceIds: Set<String>) {
        for index in allImages.indices where !sourceIds.contains(allImages[index].sourceId) {
            allImages[index].image = nil
        }
    }

    private func normalizedEmbedding(from multiArray: MLMultiArray) -> [Float]? {
        let values: [Float]
        switch multiArray.dataType {
        case .float16:
            values = multiArray.withUnsafeBufferPointer(ofType: Float16.self) { buffer in
                buffer.map { Float($0) }
            }
        case .float32:
            values = multiArray.withUnsafeBufferPointer(ofType: Float.self) { Array($0) }
        case .double:
            values = multiArray.withUnsafeBufferPointer(ofType: Double.self) { buffer in
                buffer.map { Float($0) }
            }
        default:
            return nil
        }

        return normalizedEmbedding(from: values)
    }

    private func normalizedEmbedding(from values: [Float]) -> [Float]? {
        guard !values.isEmpty else {
            return nil
        }

        var sumSquares: Float = 0
        for value in values {
            sumSquares += value * value
        }

        let magnitude = sqrt(sumSquares)
        guard magnitude > 0 else {
            return nil
        }

        let inverseMagnitude = 1 / magnitude
        return values.map { $0 * inverseMagnitude }
    }

    private func cosineSimilarity(_ embedding1: [Float], _ embedding2: [Float]) -> Float {
        guard embedding1.count == embedding2.count, !embedding1.isEmpty else {
            return 0
        }

        var dotProduct: Float = 0
        for index in 0..<embedding1.count {
            dotProduct += embedding1[index] * embedding2[index]
        }
        return dotProduct
    }
}

extension UIImage {
    func pixelBuffer(width: Int, height: Int) -> CVPixelBuffer? {
        let attrs = [
            kCVPixelBufferCGImageCompatibilityKey: kCFBooleanTrue,
            kCVPixelBufferCGBitmapContextCompatibilityKey: kCFBooleanTrue
        ] as CFDictionary

        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32ARGB,
            attrs,
            &pixelBuffer
        )

        guard status == kCVReturnSuccess, let buffer = pixelBuffer else {
            return nil
        }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        let pixelData = CVPixelBufferGetBaseAddress(buffer)
        let rgbColorSpace = CGColorSpaceCreateDeviceRGB()

        guard
            let context = CGContext(
                data: pixelData,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                space: rgbColorSpace,
                bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
            )
        else {
            return nil
        }

        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1.0, y: -1.0)

        UIGraphicsPushContext(context)
        draw(in: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
        UIGraphicsPopContext()

        return buffer
    }
}
