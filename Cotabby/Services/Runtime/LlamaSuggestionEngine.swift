import CoreGraphics
import Foundation
import Logging

/// File overview:
/// Wraps the raw llama runtime with prompt/result normalization that is specific to inline
/// completion. This is where raw generated text becomes a short suggestion Cotabby can safely show.
///
/// Keeps prompt normalization separate from the raw llama runtime.
/// That separation matters because prompt strategy changes far more often than model lifecycle code.
@MainActor
final class LlamaSuggestionEngine {
    private let runtimeManager: LlamaRuntimeManager
    private let suggestionSettings: SuggestionSettingsModel
    private var promptCacheHintTracker = LlamaPromptCacheHintTracker()

    init(runtimeManager: LlamaRuntimeManager, suggestionSettings: SuggestionSettingsModel) {
        self.runtimeManager = runtimeManager
        self.suggestionSettings = suggestionSettings
    }

    /// Executes one generation request and packages the raw and normalized result for the coordinator.
    /// When tree decode is enabled, generates multiple candidates and returns alternatives.
    func generateSuggestion(for request: SuggestionRequest) async throws -> SuggestionResult {
        let baseMetadata: Logger.Metadata = [
            "request_id": .string(request.requestID),
            "engine": .string("llama")
        ]
        do {
            let startTime = Date()
            let cachedPrefixBytes = promptCacheHintTracker.cachedPrefixBytes(for: request)
            let hintDesc = cachedPrefixBytes.map(String.init) ?? "none"
            CotabbyLogger.suggestion.debug(
                "Llama generating",
                metadata: baseMetadata.merging([
                    "prompt_bytes": .stringConvertible(request.prompt.count),
                    "cache_hint_bytes": .string(hintDesc),
                    "max_tokens": .stringConvertible(request.maxPredictionTokens)
                ]) { _, new in new }
            )

            let options = LlamaGenerationOptions(
                maxPredictionTokens: request.maxPredictionTokens,
                temperature: request.temperature,
                topK: request.topK,
                topP: request.topP,
                minP: request.minP,
                repetitionPenalty: request.repetitionPenalty,
                seed: request.randomSeed
            )

            // Use tree decode when enabled (candidateCount > 1)
            let treeConfig = treeDecodeConfiguration
            let treeResult = try await runtimeManager.generateTree(
                prompt: request.prompt,
                cachedPrefixBytes: cachedPrefixBytes,
                options: options,
                config: treeConfig
            )
            try Task.checkCancellation()

            promptCacheHintTracker.recordSuccessfulRequest(request)

            guard let primary = treeResult.primary else {
                throw SuggestionClientError.generationFailed("Tree decode returned no candidates.")
            }

            let normalizedPrimary = SuggestionTextNormalizer.normalize(primary.text, for: request)
            let normalizedAlternatives = treeResult.alternatives.map {
                SuggestionTextNormalizer.normalize($0.text, for: request)
            }.filter { !$0.isEmpty && $0 != normalizedPrimary }

            let latency = Date().timeIntervalSince(startTime)
            let latencyMs = Int(latency * 1000)
            let altCount = normalizedAlternatives.count
            CotabbyLogger.suggestion.debug(
                "Llama tree decode",
                metadata: [
                    "primary_chars": .stringConvertible(normalizedPrimary.count),
                    "alternatives": .stringConvertible(altCount),
                    "latency_ms": .stringConvertible(latencyMs)
                ]
            )
            return SuggestionResult(
                generation: request.generation,
                rawText: primary.text,
                text: normalizedPrimary,
                latency: latency,
                alternatives: normalizedAlternatives
            )
        } catch is CancellationError {
            CotabbyLogger.suggestion.debug("Llama generation cancelled", metadata: baseMetadata)
            throw SuggestionClientError.cancelled
        } catch let error as LlamaRuntimeError {
            CotabbyLogger.suggestion.error(
                "Llama runtime error, resetting cache: \(error.localizedDescription)",
                metadata: baseMetadata
            )
            await resetCachedGenerationContext()
            throw SuggestionClientError.unavailable(error.localizedDescription)
        } catch let error as SuggestionClientError {
            CotabbyLogger.suggestion.error(
                "Suggestion client error, resetting cache: \(error.localizedDescription)",
                metadata: baseMetadata
            )
            await resetCachedGenerationContext()
            throw error
        } catch {
            CotabbyLogger.suggestion.error(
                "Unexpected generation error, resetting cache: \(error.localizedDescription)",
                metadata: baseMetadata
            )
            await resetCachedGenerationContext()
            throw SuggestionClientError.generationFailed(error.localizedDescription)
        }
    }

    /// Tree decode configuration derived from user settings.
    var treeDecodeConfiguration: TreeDecodeConfiguration {
        let count = suggestionSettings.treeCandidateCount
        return count <= 1 ? .disabled : TreeDecodeConfiguration(candidateCount: count)
    }

    /// Clears both the Swift-side hint tracker and the native llama KV cache.
    /// The tracker reset is synchronous because it protects the next request from advertising
    /// stale reuse; awaiting the runtime reset keeps native KV invalidation ordered before the next
    /// generation request that crosses this engine boundary.
    func resetCachedGenerationContext() async {
        promptCacheHintTracker.reset()
        runtimeManager.resetPromptCache()
    }
}

extension LlamaSuggestionEngine: SuggestionGenerating {}

/// Tracks the last successful llama prompt so the engine can pass a conservative byte-prefix hint
/// into `LlamaRuntimeManager.generate`. This type deliberately does not own correctness: native KV
/// state is still validated by `LlamaRuntimeCore` after tokenization.
struct LlamaPromptCacheHintTracker: Equatable {
    private var lastRequest: CachedRequest?

    mutating func cachedPrefixBytes(for request: SuggestionRequest) -> Int? {
        let nextRequest = CachedRequest(request: request)
        guard let lastRequest else {
            return nil
        }

        guard lastRequest.focusKey == nextRequest.focusKey,
              lastRequest.samplingFingerprint == nextRequest.samplingFingerprint
        else {
            self.lastRequest = nil
            return nil
        }

        return Self.commonPrefixByteCount(lastRequest.promptBytes, nextRequest.promptBytes)
    }

    mutating func recordSuccessfulRequest(_ request: SuggestionRequest) {
        lastRequest = CachedRequest(request: request)
    }

    mutating func reset() {
        lastRequest = nil
    }

    private static func commonPrefixByteCount(_ lhs: [UInt8], _ rhs: [UInt8]) -> Int {
        var index = 0
        let limit = min(lhs.count, rhs.count)

        while index < limit, lhs[index] == rhs[index] {
            index += 1
        }

        return index
    }
}

private extension LlamaPromptCacheHintTracker {
    struct CachedRequest: Equatable {
        let focusKey: FocusKey
        let samplingFingerprint: SamplingFingerprint
        let promptBytes: [UInt8]

        init(request: SuggestionRequest) {
            focusKey = FocusKey(context: request.context)
            samplingFingerprint = SamplingFingerprint(request: request)
            promptBytes = Array(request.prompt.utf8)
        }
    }

    struct FocusKey: Equatable {
        let bundleIdentifier: String
        let processIdentifier: Int32
        let role: String
        let subrole: String?
        let fieldAnchor: FieldAnchor

        init(context: FocusedInputContext) {
            bundleIdentifier = context.bundleIdentifier
            processIdentifier = context.processIdentifier
            role = context.role
            subrole = context.subrole
            fieldAnchor = FieldAnchor(
                inputFrame: context.inputFrameRect,
                fallbackElementIdentifier: context.elementIdentifier
            )
        }
    }

    struct FieldAnchor: Equatable {
        let roundedInputFrame: RoundedRect?
        let fallbackElementIdentifier: String?

        nonisolated init(inputFrame: CGRect?, fallbackElementIdentifier: String) {
            roundedInputFrame = inputFrame.map(RoundedRect.init(rect:))
            self.fallbackElementIdentifier = roundedInputFrame == nil ? fallbackElementIdentifier : nil
        }
    }

    struct RoundedRect: Equatable {
        let minX: Int
        let minY: Int
        let width: Int
        let height: Int

        nonisolated init(rect: CGRect) {
            minX = Int(rect.minX.rounded())
            minY = Int(rect.minY.rounded())
            width = Int(rect.width.rounded())
            height = Int(rect.height.rounded())
        }
    }

    struct SamplingFingerprint: Equatable {
        let maxPredictionTokens: Int
        let temperature: Double
        let topK: Int
        let topP: Double
        let minP: Double
        let repetitionPenalty: Double
        let randomSeed: UInt32?

        init(request: SuggestionRequest) {
            maxPredictionTokens = request.maxPredictionTokens
            temperature = request.temperature
            topK = request.topK
            topP = request.topP
            minP = request.minP
            repetitionPenalty = request.repetitionPenalty
            randomSeed = request.randomSeed
        }
    }
}
