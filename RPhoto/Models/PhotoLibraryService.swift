//
//  PhotoLibraryService.swift
//  RPhoto
//

import Foundation
import CoreLocation
import Photos
import UIKit

struct PhotoAssetMetadata {
    let creationDate: Date?
    let locationName: String?
    let coordinateText: String?
    let pixelWidth: Int
    let pixelHeight: Int
}

struct PhotoLibraryService {
    private let imageManager = PHImageManager.default()
    private let imageRequestTimeout: TimeInterval = 8

    private enum DegradedImagePolicy {
        case fallbackIfNeeded
        case acceptFirst
        case requireNonDegraded
    }

    func currentAuthorizationStatus() -> PHAuthorizationStatus {
        PHPhotoLibrary.authorizationStatus(for: .readWrite)
    }

    func requestReadAuthorizationIfNeeded() async -> PHAuthorizationStatus {
        let current = currentAuthorizationStatus()
        if current != .notDetermined {
            return current
        }
        return await withCheckedContinuation { continuation in
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
                continuation.resume(returning: status)
            }
        }
    }

    func fetchAccessibleImageAssetIds() -> [String] {
        let result = PHAsset.fetchAssets(with: .image, options: nil)
        var ids: [String] = []
        ids.reserveCapacity(result.count)
        result.enumerateObjects { asset, _, _ in
            ids.append(asset.localIdentifier)
        }
        return ids
    }

    func openPhotoSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else {
            return
        }
        UIApplication.shared.open(url)
    }

    @discardableResult
    func presentLimitedLibraryPickerIfPossible() -> Bool {
        guard
            currentAuthorizationStatus() == .limited,
            let controller = topViewController()
        else {
            return false
        }

        PHPhotoLibrary.shared().presentLimitedLibraryPicker(from: controller)
        return true
    }

    func assetExists(localIdentifier: String) -> Bool {
        let result = PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil)
        return result.firstObject != nil
    }

    func existingAssetIdentifiers(localIdentifiers: [String]) -> Set<String> {
        guard !localIdentifiers.isEmpty else {
            return []
        }

        let chunkSize = 1000
        var existingIds = Set<String>()
        existingIds.reserveCapacity(localIdentifiers.count)

        var start = 0
        while start < localIdentifiers.count {
            let end = min(start + chunkSize, localIdentifiers.count)
            let chunk = Array(localIdentifiers[start..<end])
            let result = PHAsset.fetchAssets(withLocalIdentifiers: chunk, options: nil)
            result.enumerateObjects { asset, _, _ in
                existingIds.insert(asset.localIdentifier)
            }
            start = end
        }

        return existingIds
    }

    func loadUIImage(localIdentifier: String, targetSize: CGSize) async -> UIImage? {
        guard let asset = fetchAsset(localIdentifier: localIdentifier) else {
            return nil
        }

        let options = PHImageRequestOptions()
        options.isSynchronous = false
        // Never trigger iCloud download. Use only local photo data.
        options.isNetworkAccessAllowed = false
        options.deliveryMode = .opportunistic
        options.resizeMode = .fast

        return await requestImage(
            for: asset,
            targetSize: targetSize,
            contentMode: .aspectFill,
            options: options,
            degradedImagePolicy: .fallbackIfNeeded
        )
    }

    func loadUIImageForEncoding(localIdentifier: String, targetSize: CGSize) async -> UIImage? {
        guard let asset = fetchAsset(localIdentifier: localIdentifier) else {
            return nil
        }

        let options = PHImageRequestOptions()
        options.isSynchronous = false
        // Never trigger iCloud download. Prefer locally available high-quality image for encoding.
        options.isNetworkAccessAllowed = false
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .exact

        return await requestImage(
            for: asset,
            targetSize: targetSize,
            contentMode: .aspectFill,
            options: options,
            degradedImagePolicy: .requireNonDegraded
        )
    }

    func loadUIImageForPreview(localIdentifier: String, targetSize: CGSize) async -> UIImage? {
        guard let asset = fetchAsset(localIdentifier: localIdentifier) else {
            return nil
        }

        let options = PHImageRequestOptions()
        options.isSynchronous = false
        // Never trigger iCloud download. Show best local image available.
        options.isNetworkAccessAllowed = false
        options.deliveryMode = .opportunistic
        options.resizeMode = .exact

        return await requestImage(
            for: asset,
            targetSize: targetSize,
            contentMode: .aspectFit,
            options: options,
            degradedImagePolicy: .fallbackIfNeeded
        )
    }

    func loadMetadata(localIdentifier: String) async -> PhotoAssetMetadata? {
        guard let asset = fetchAsset(localIdentifier: localIdentifier) else {
            return nil
        }

        var locationName: String?
        var coordinateText: String?
        if let location = asset.location {
            coordinateText = String(
                format: "%.4f, %.4f",
                location.coordinate.latitude,
                location.coordinate.longitude
            )
            locationName = await reverseGeocodeLocationName(location)
        }

        return PhotoAssetMetadata(
            creationDate: asset.creationDate,
            locationName: locationName,
            coordinateText: coordinateText,
            pixelWidth: asset.pixelWidth,
            pixelHeight: asset.pixelHeight
        )
    }

    private func fetchAsset(localIdentifier: String) -> PHAsset? {
        let result = PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil)
        return result.firstObject
    }

    private func requestImage(
        for asset: PHAsset,
        targetSize: CGSize,
        contentMode: PHImageContentMode,
        options: PHImageRequestOptions,
        degradedImagePolicy: DegradedImagePolicy
    ) async -> UIImage? {
        await withCheckedContinuation { continuation in
            // Result handlers and the timeout may run on different threads; guard shared state with a lock.
            let lock = NSLock()
            var hasResumed = false
            var degradedCandidate: UIImage?
            var requestId: PHImageRequestID = PHInvalidImageRequestID

            func resumeOnce(_ image: UIImage?) {
                lock.lock()
                guard !hasResumed else {
                    lock.unlock()
                    return
                }
                hasResumed = true
                lock.unlock()
                continuation.resume(returning: image)
            }

            func fallbackImage() -> UIImage? {
                switch degradedImagePolicy {
                case .acceptFirst, .fallbackIfNeeded:
                    lock.lock()
                    defer { lock.unlock() }
                    return degradedCandidate
                case .requireNonDegraded:
                    return nil
                }
            }

            let id = imageManager.requestImage(
                for: asset,
                targetSize: targetSize,
                contentMode: contentMode,
                options: options
            ) { image, info in
                let isCancelled = info?[PHImageCancelledKey] as? Bool ?? false
                let hasError = info?[PHImageErrorKey] != nil
                let isDegraded = info?[PHImageResultIsDegradedKey] as? Bool ?? false
                let isInCloud = info?[PHImageResultIsInCloudKey] as? Bool ?? false

                // Cloud-only assets with network disabled often finish with an error or nil image;
                // fall back to the local degraded thumbnail delivered earlier instead of dropping the photo.
                if isCancelled || hasError {
                    resumeOnce(image ?? fallbackImage())
                    return
                }

                if isDegraded {
                    guard let image else {
                        return
                    }

                    switch degradedImagePolicy {
                    case .acceptFirst:
                        resumeOnce(image)
                    case .fallbackIfNeeded:
                        lock.lock()
                        degradedCandidate = image
                        lock.unlock()
                        if isInCloud && !options.isNetworkAccessAllowed {
                            // The full-quality image is only in iCloud; return local degraded image directly.
                            resumeOnce(image)
                        }
                    case .requireNonDegraded:
                        // Encoding path: do not use degraded images.
                        if isInCloud && !options.isNetworkAccessAllowed {
                            // Full-quality image is cloud-only and network is disabled.
                            resumeOnce(nil)
                        }
                    }
                    return
                }

                resumeOnce(image ?? fallbackImage())
            }

            lock.lock()
            requestId = id
            lock.unlock()

            // Never let a stuck PhotoKit request block the caller (e.g. search results loading forever).
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + imageRequestTimeout) {
                lock.lock()
                let pending = !hasResumed
                let pendingId = requestId
                lock.unlock()
                guard pending else { return }
                imageManager.cancelImageRequest(pendingId)
                resumeOnce(fallbackImage())
            }
        }
    }

    private func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .filter {
                $0.activationState == .foregroundActive || $0.activationState == .foregroundInactive
            }

        guard
            let window = scenes
                .flatMap(\.windows)
                .first(where: { $0.isKeyWindow }),
            var controller = window.rootViewController
        else {
            return nil
        }

        while let presented = controller.presentedViewController {
            controller = presented
        }
        return controller
    }

    private func reverseGeocodeLocationName(_ location: CLLocation) async -> String? {
        let geocoder = CLGeocoder()

        return await withCheckedContinuation { continuation in
            geocoder.reverseGeocodeLocation(location) { placemarks, _ in
                let components = [
                    placemarks?.first?.name,
                    placemarks?.first?.locality,
                    placemarks?.first?.administrativeArea,
                    placemarks?.first?.country
                ]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }

                let uniqueComponents = components.reduce(into: [String]()) { partialResult, value in
                    if !partialResult.contains(value) {
                        partialResult.append(value)
                    }
                }

                if uniqueComponents.isEmpty {
                    continuation.resume(returning: nil)
                } else {
                    continuation.resume(returning: uniqueComponents.joined(separator: ", "))
                }
            }
        }
    }
}
