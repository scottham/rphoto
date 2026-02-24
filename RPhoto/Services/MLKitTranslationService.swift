//
//  MLKitTranslationService.swift
//  RPhoto
//

import Foundation
import MLKitCommon
import MLKitTranslate

private let isMLKitTranslationDebugEnabled = false

private func mlKitTranslationDebug(_ message: String) {
#if DEBUG
    guard isMLKitTranslationDebugEnabled else { return }
    print("[MLKitTranslationService] \(message)")
#else
    _ = message
#endif
}

enum TranslationRuntimeError: LocalizedError {
    enum Stage: String {
        case modelCheck
        case modelDownload
        case translate
    }

    case invalidLanguageCode(String)
    case unsupportedLanguage(String)
    case modelNotDownloaded(String)
    case modelDownloadFailed(String)
    case translationFailed(String)
    case timeout(stage: Stage)
    case emptyTranslation

    var errorDescription: String? {
        switch self {
        case .invalidLanguageCode(let code):
            return "Invalid language code: \(code)"
        case .unsupportedLanguage(let code):
            return "Unsupported language: \(code)"
        case .modelNotDownloaded(let code):
            return "Translation model is not downloaded for: \(code)"
        case .modelDownloadFailed(let details):
            return details.isEmpty ? "Failed to download translation model." : details
        case .translationFailed(let details):
            return details.isEmpty ? "Translation failed." : details
        case .timeout(let stage):
            return "Timeout at stage: \(stage.rawValue)"
        case .emptyTranslation:
            return "Translation returned empty output."
        }
    }
}

protocol TranslationProvider {
    func supportedLanguages() -> [String]
    func downloadedLanguageCodes() -> Set<String>
    func isModelReady(
        sourceLanguageCode: String,
        targetLanguageCode: String
    ) async throws -> Bool
    func downloadModel(
        sourceLanguageCode: String,
        targetLanguageCode: String,
        allowsCellularAccess: Bool,
        progressHandler: (@Sendable (Double) -> Void)?
    ) async throws
    func translate(
        text: String,
        sourceLanguageCode: String,
        targetLanguageCode: String
    ) async throws -> String
}

extension TranslationProvider {
    func downloadModel(
        sourceLanguageCode: String,
        targetLanguageCode: String,
        allowsCellularAccess: Bool
    ) async throws {
        try await downloadModel(
            sourceLanguageCode: sourceLanguageCode,
            targetLanguageCode: targetLanguageCode,
            allowsCellularAccess: allowsCellularAccess,
            progressHandler: nil
        )
    }
}

final class MLKitTranslationService: TranslationProvider {
    static let shared = MLKitTranslationService()

    private static let sharedModelManager = ModelManager.modelManager()
    private var modelManager: ModelManager { Self.sharedModelManager }
    private let translatorCacheQueue = DispatchQueue(
        label: "com.rphoto.mlkit.translation.translator-cache",
        qos: .userInitiated
    )
    private var translatorCacheByLanguagePair: [String: Translator] = [:]
    private let modelCheckTimeoutSeconds: Double = 3
    private let modelDownloadTimeoutSeconds: Double = 120
    private let translateTimeoutSeconds: Double = 12

    private init() {}

    func supportedLanguages() -> [String] {
        TranslateLanguage.allLanguages().map(\.rawValue).sorted()
    }

    func downloadedLanguageCodes() -> Set<String> {
        Set(modelManager.downloadedTranslateModels.map { model in
            model.language.rawValue
        })
    }

    func isModelReady(
        sourceLanguageCode: String,
        targetLanguageCode: String
    ) async throws -> Bool {
        try await withTimeout(seconds: modelCheckTimeoutSeconds, stage: .modelCheck) {
            let sourceLanguage = try self.language(from: sourceLanguageCode)
            let targetLanguage = try self.language(from: targetLanguageCode)
            let requiredModels = self.requiredRemoteModels(
                sourceLanguage: sourceLanguage,
                targetLanguage: targetLanguage
            )
            guard !requiredModels.isEmpty else {
                return true
            }

            return requiredModels.allSatisfy { model in
                self.modelManager.isModelDownloaded(model)
            }
        }
    }

    func downloadModel(
        sourceLanguageCode: String,
        targetLanguageCode: String,
        allowsCellularAccess: Bool,
        progressHandler: (@Sendable (Double) -> Void)?
    ) async throws {
        let sourceLanguage = try language(from: sourceLanguageCode)
        let targetLanguage = try language(from: targetLanguageCode)
        let requiredModels = requiredRemoteModels(
            sourceLanguage: sourceLanguage,
            targetLanguage: targetLanguage
        )
        guard !requiredModels.isEmpty else {
            progressHandler?(1.0)
            return
        }

        let pendingModels = requiredModels.filter { model in
            !modelManager.isModelDownloaded(model)
        }
        guard !pendingModels.isEmpty else {
            progressHandler?(1.0)
            return
        }

        let conditions = ModelDownloadConditions(
            allowsCellularAccess: allowsCellularAccess,
            allowsBackgroundDownloading: true
        )
        let clampedProgress: @Sendable (Double) -> Void = { progress in
            progressHandler?(min(max(progress, 0), 1))
        }

        do {
            clampedProgress(0)
            let totalModelCount = Double(pendingModels.count)
            for (index, remoteModel) in pendingModels.enumerated() {
                let baseProgress = Double(index) / totalModelCount
                let progressSpan = 1.0 / totalModelCount
                try await downloadSingleModel(
                    remoteModel,
                    conditions: conditions,
                    baseProgress: baseProgress,
                    progressSpan: progressSpan,
                    progressHandler: clampedProgress
                )
            }
            clampedProgress(1)
        } catch let error as TranslationRuntimeError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw TranslationRuntimeError.modelDownloadFailed(error.localizedDescription)
        }
    }

    func translate(
        text: String,
        sourceLanguageCode: String,
        targetLanguageCode: String
    ) async throws -> String {
        let sourceLanguage = try language(from: sourceLanguageCode)
        let targetLanguage = try language(from: targetLanguageCode)

        let requiredModels = requiredRemoteModels(
            sourceLanguage: sourceLanguage,
            targetLanguage: targetLanguage
        )
        if !requiredModels.isEmpty {
            let ready = requiredModels.allSatisfy { modelManager.isModelDownloaded($0) }
            guard ready else {
                throw TranslationRuntimeError.modelNotDownloaded(sourceLanguageCode)
            }
        }

        let pairKey = translatorPairKey(
            sourceLanguage: sourceLanguage,
            targetLanguage: targetLanguage
        )
        let translator = cachedTranslator(
            sourceLanguage: sourceLanguage,
            targetLanguage: targetLanguage
        )

        do {
            let startedAt = Date()
            mlKitTranslationDebug("translate start pair=\(pairKey) chars=\(text.count)")
            let output = try await withTimeout(seconds: translateTimeoutSeconds, stage: .translate) {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
                    let callStartedAt = Date()
                    translator.translate(text) { translatedText, error in
                        let callbackLatencyMS = Int(
                            Date().timeIntervalSince(callStartedAt) * 1000
                        )
                        if let error {
                            mlKitTranslationDebug(
                                "translate callback error pair=\(pairKey) callback_latency_ms=\(callbackLatencyMS) error=\(error.localizedDescription)"
                            )
                            continuation.resume(throwing: error)
                            return
                        }
                        mlKitTranslationDebug(
                            "translate callback success pair=\(pairKey) callback_latency_ms=\(callbackLatencyMS) output_len=\(translatedText?.count ?? 0)"
                        )
                        continuation.resume(returning: translatedText ?? "")
                    }
                }
            }
            let totalLatencyMS = Int(Date().timeIntervalSince(startedAt) * 1000)
            mlKitTranslationDebug("translate complete pair=\(pairKey) total_latency_ms=\(totalLatencyMS)")

            let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                throw TranslationRuntimeError.emptyTranslation
            }
            return trimmed
        } catch let error as TranslationRuntimeError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw TranslationRuntimeError.translationFailed(error.localizedDescription)
        }
    }

    private func makeTranslator(
        sourceLanguageCode: String,
        targetLanguageCode: String
    ) throws -> Translator {
        let sourceLanguage = try language(from: sourceLanguageCode)
        let targetLanguage = try language(from: targetLanguageCode)
        return makeTranslator(sourceLanguage: sourceLanguage, targetLanguage: targetLanguage)
    }

    private func makeTranslator(
        sourceLanguage: TranslateLanguage,
        targetLanguage: TranslateLanguage
    ) -> Translator {
        let options = TranslatorOptions(
            sourceLanguage: sourceLanguage,
            targetLanguage: targetLanguage
        )
        return Translator.translator(options: options)
    }

    private func translatorPairKey(
        sourceLanguage: TranslateLanguage,
        targetLanguage: TranslateLanguage
    ) -> String {
        "\(sourceLanguage.rawValue.lowercased())->\(targetLanguage.rawValue.lowercased())"
    }

    private func cachedTranslator(
        sourceLanguage: TranslateLanguage,
        targetLanguage: TranslateLanguage
    ) -> Translator {
        let pairKey = translatorPairKey(
            sourceLanguage: sourceLanguage,
            targetLanguage: targetLanguage
        )
        return translatorCacheQueue.sync {
            if let cached = translatorCacheByLanguagePair[pairKey] {
                mlKitTranslationDebug("translator cache hit pair=\(pairKey)")
                return cached
            }

            let created = makeTranslator(
                sourceLanguage: sourceLanguage,
                targetLanguage: targetLanguage
            )
            translatorCacheByLanguagePair[pairKey] = created
            mlKitTranslationDebug("translator cache miss pair=\(pairKey); created new translator")
            return created
        }
    }

    private func language(from identifier: String) throws -> TranslateLanguage {
        let trimmed = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw TranslationRuntimeError.invalidLanguageCode(identifier)
        }

        let supportedLanguages = Set(TranslateLanguage.allLanguages())
        if let exactMatch = supportedLanguages.first(where: {
            $0.rawValue.localizedCaseInsensitiveCompare(trimmed) == .orderedSame
        }) {
            return exactMatch
        }

        let lowered = trimmed.lowercased()
        if let loweredMatch = supportedLanguages.first(where: {
            $0.rawValue.localizedCaseInsensitiveCompare(lowered) == .orderedSame
        }) {
            return loweredMatch
        }

        if lowered == "zh-tw" || lowered == "zh-hant" {
            if let traditionalChinese = supportedLanguages.first(where: {
                $0.rawValue.localizedCaseInsensitiveCompare("zh-TW") == .orderedSame
            }) {
                return traditionalChinese
            }
            if let chinese = supportedLanguages.first(where: {
                $0.rawValue.localizedCaseInsensitiveCompare("zh") == .orderedSame
            }) {
                return chinese
            }
        }

        let baseIdentifier = lowered
            .split(separator: "-")
            .first
            .map(String.init) ?? lowered
        if let baseMatch = supportedLanguages.first(where: {
            $0.rawValue.localizedCaseInsensitiveCompare(baseIdentifier) == .orderedSame
        }) {
            return baseMatch
        }

        throw TranslationRuntimeError.unsupportedLanguage(identifier)
    }

    private func requiredRemoteModels(
        sourceLanguage: TranslateLanguage,
        targetLanguage: TranslateLanguage
    ) -> [TranslateRemoteModel] {
        let source = sourceLanguage.rawValue.lowercased()
        let target = targetLanguage.rawValue.lowercased()

        if source == target {
            if source == "en" {
                return []
            }
            return [TranslateRemoteModel.translateRemoteModel(language: sourceLanguage)]
        }

        if source == "en" {
            return [TranslateRemoteModel.translateRemoteModel(language: targetLanguage)]
        }

        if target == "en" {
            return [TranslateRemoteModel.translateRemoteModel(language: sourceLanguage)]
        }

        return [
            TranslateRemoteModel.translateRemoteModel(language: sourceLanguage),
            TranslateRemoteModel.translateRemoteModel(language: targetLanguage)
        ]
    }

    private func downloadSingleModel(
        _ remoteModel: TranslateRemoteModel,
        conditions: ModelDownloadConditions,
        baseProgress: Double,
        progressSpan: Double,
        progressHandler: @escaping @Sendable (Double) -> Void
    ) async throws {
        progressHandler(baseProgress)
        let progress = modelManager.download(remoteModel, conditions: conditions)
        let pollTask = Task(priority: .userInitiated) {
            while !Task.isCancelled {
                let fractional = min(max(progress.fractionCompleted, 0), 1)
                progressHandler(baseProgress + progressSpan * fractional)
                if progress.isFinished {
                    break
                }
                try? await Task.sleep(nanoseconds: 120_000_000)
            }
        }
        defer {
            pollTask.cancel()
            progressHandler(baseProgress + progressSpan)
        }

        try await withTimeout(seconds: modelDownloadTimeoutSeconds, stage: .modelDownload) {
            try await self.awaitModelDownloadCompletion(for: remoteModel)
        }
    }

    private func awaitModelDownloadCompletion(for remoteModel: TranslateRemoteModel) async throws {
        if modelManager.isModelDownloaded(remoteModel) {
            return
        }

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                for await notification in NotificationCenter.default.notifications(
                    named: .mlkitModelDownloadDidSucceed
                ) {
                    if self.notification(notification, matches: remoteModel) {
                        return
                    }
                }
            }

            group.addTask {
                for await notification in NotificationCenter.default.notifications(
                    named: .mlkitModelDownloadDidFail
                ) {
                    guard self.notification(notification, matches: remoteModel) else {
                        continue
                    }

                    if let error = notification.userInfo?[ModelDownloadUserInfoKey.error] as? NSError {
                        throw TranslationRuntimeError.modelDownloadFailed(error.localizedDescription)
                    }
                    throw TranslationRuntimeError.modelDownloadFailed("Translation model download failed.")
                }
            }

            group.addTask {
                while !Task.isCancelled {
                    if self.modelManager.isModelDownloaded(remoteModel) {
                        return
                    }
                    try await Task.sleep(nanoseconds: 150_000_000)
                }
                throw CancellationError()
            }

            do {
                _ = try await group.next()
                group.cancelAll()
            } catch {
                group.cancelAll()
                throw error
            }
        }
    }

    private func notification(_ notification: Notification, matches remoteModel: TranslateRemoteModel) -> Bool {
        guard let downloadedModel = notification.userInfo?[ModelDownloadUserInfoKey.remoteModel] as? TranslateRemoteModel else {
            return false
        }

        return downloadedModel.language.rawValue.localizedCaseInsensitiveCompare(remoteModel.language.rawValue) == .orderedSame
    }

    private func withTimeout<T>(
        seconds: Double,
        stage: TranslationRuntimeError.Stage,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let timeoutNanoseconds = UInt64(max(seconds, 0) * 1_000_000_000)
        return try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                if timeoutNanoseconds > 0 {
                    try await Task.sleep(nanoseconds: timeoutNanoseconds)
                }
                throw TranslationRuntimeError.timeout(stage: stage)
            }
            defer { group.cancelAll() }
            guard let value = try await group.next() else {
                throw TranslationRuntimeError.timeout(stage: stage)
            }
            return value
        }
    }

}
