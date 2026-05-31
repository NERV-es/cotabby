import Foundation
import CotabbyInference

/// Extension on LlamaRuntimeCore that adds multi-candidate tree decoding.
/// Uses ephemeral sequences (separate from the persistent autocomplete sequence)
/// to generate diverse alternatives in parallel-ish fashion.
extension LlamaRuntimeCore {

    /// Generates multiple candidates from the same prompt using different sampling parameters.
    /// The primary candidate uses the original options; alternatives use modified temperatures.
    ///
    /// Thread safety: acquires `autocompleteLock` for the primary sequence, uses ephemeral
    /// sequences for alternatives. All sequences share the same underlying llama_context batch.
    func generateTree(
        prompt: String,
        cachedPrefixBytes: Int? = nil,
        options: LlamaGenerationOptions,
        config: TreeDecodeConfiguration
    ) throws -> TreeDecodeResult {
        guard config.candidateCount > 1 else {
            // Fast path: single candidate, use normal generate
            let start = Date()
            let text = try generate(prompt: prompt, cachedPrefixBytes: cachedPrefixBytes, options: options)
            let latency = Date().timeIntervalSince(start)
            return TreeDecodeResult(
                candidates: [TreeDecodeCandidate(text: text, tokenCount: 0, latency: latency, branchIndex: 0)],
                totalLatency: latency
            )
        }

        guard preparedRuntime != nil else {
            throw LlamaRuntimeError.unavailable("The llama model is not loaded.")
        }

        lifecycleCondition.lock()
        guard !isShuttingDown else {
            lifecycleCondition.unlock()
            throw LlamaRuntimeError.unavailable("The runtime is shutting down.")
        }
        activeOperationCount += 1
        lifecycleCondition.unlock()

        defer {
            lifecycleCondition.lock()
            activeOperationCount -= 1
            lifecycleCondition.broadcast()
            lifecycleCondition.unlock()
        }

        let totalStart = Date()
        let promptTokens = preparePromptTokens(prompt: prompt, options: options)
        guard !promptTokens.isEmpty else {
            throw LlamaRuntimeError.generationFailed("Tokenization returned no prompt tokens.")
        }

        // Generate primary candidate (uses KV cache reuse path)
        let primaryStart = Date()
        let primaryText = try generatePrimaryCandidate(
            prompt: prompt,
            promptTokens: promptTokens,
            cachedPrefixBytes: cachedPrefixBytes,
            options: options
        )
        let primaryLatency = Date().timeIntervalSince(primaryStart)

        var candidates = [TreeDecodeCandidate(
            text: primaryText,
            tokenCount: estimateTokenCount(primaryText),
            latency: primaryLatency,
            branchIndex: 0
        )]

        // Generate alternatives using ephemeral sequences
        let alternativeCount = min(config.candidateCount - 1, 3) // max 3 alternatives (engine limit: 4 total)
        let altMaxTokens = config.alternativeMaxTokens ?? options.maxPredictionTokens

        for i in 0 ..< alternativeCount {
            if Task.isCancelled { break }

            // Apply diversity: scale temperature for each branch
            let factor = i < config.diversityFactors.count ? config.diversityFactors[i] : Double(i + 2)
            let altOptions = LlamaGenerationOptions(
                maxPredictionTokens: altMaxTokens,
                temperature: min(options.temperature * factor, 2.0), // cap at 2.0
                topK: options.topK,
                topP: options.topP,
                minP: max(options.minP * 0.5, 0.01), // relax minP for diversity
                repetitionPenalty: options.repetitionPenalty,
                seed: options.seed.map { $0 + UInt32(i + 1) } // different seed per branch
            )

            let altStart = Date()
            do {
                let altText = try generateEphemeralCandidate(
                    promptTokens: promptTokens,
                    options: altOptions
                )
                let altLatency = Date().timeIntervalSince(altStart)

                // Skip duplicates or empty results
                if !altText.isEmpty && altText != primaryText {
                    candidates.append(TreeDecodeCandidate(
                        text: altText,
                        tokenCount: estimateTokenCount(altText),
                        latency: altLatency,
                        branchIndex: i + 1
                    ))
                }
            } catch {
                // Alternative generation failure is non-fatal; we still have the primary
                continue
            }
        }

        let totalLatency = Date().timeIntervalSince(totalStart)
        return TreeDecodeResult(candidates: candidates, totalLatency: totalLatency)
    }

    // MARK: - Private tree decode helpers

    private func preparePromptTokens(prompt: String, options: LlamaGenerationOptions) -> [Int32] {
        let allTokens = tokenize(prompt)
        guard let preparedRuntime else { return [] }
        let maxPromptTokens = max(1, preparedRuntime.contextWindowTokens - options.maxPredictionTokens)
        if allTokens.count > maxPromptTokens {
            return Array(allTokens.suffix(maxPromptTokens))
        }
        return allTokens
    }

    private func generatePrimaryCandidate(
        prompt: String,
        promptTokens: [Int32],
        cachedPrefixBytes: Int?,
        options: LlamaGenerationOptions
    ) throws -> String {
        let promptBytes = Array(prompt.utf8)
        let fingerprint = SamplingFingerprint(options: options)

        autocompleteLock.lock()
        defer { autocompleteLock.unlock() }

        let sequenceID = try obtainAutocompleteSequence(
            promptTokens: promptTokens,
            promptBytes: promptBytes,
            fingerprint: fingerprint,
            cachedPrefixBytes: cachedPrefixBytes,
            options: options
        )

        defer {
            _ = engine.trimKV(sequenceID, Int32(promptTokens.count))
            autocompletePromptBytes = promptBytes
            autocompletePromptTokens = promptTokens
            autocompleteSamplingFingerprint = fingerprint
        }

        var generatedText = ""
        for _ in 0 ..< options.maxPredictionTokens {
            if Task.isCancelled { break }
            let result = engine.sampleNext(sequenceID)
            if result.was_cancelled || result.is_eos { break }
            generatedText += Self.extractPiece(result)
        }
        return generatedText
    }

    /// Generates a candidate on an ephemeral sequence (no KV cache reuse, destroyed after).
    private func generateEphemeralCandidate(
        promptTokens: [Int32],
        options: LlamaGenerationOptions
    ) throws -> String {
        let config = Self.samplingConfig(from: options)
        let seqID = engine.createSequence(config)
        guard seqID >= 0 else {
            throw LlamaRuntimeError.generationFailed("Unable to create tree decode sequence.")
        }
        defer { engine.destroySequence(seqID) }

        var tokens = promptTokens
        let status = engine.decodePrompt(seqID, &tokens, Int32(tokens.count), 0)
        guard status == .ok else {
            throw LlamaRuntimeError.generationFailed("Tree decode prompt decoding failed.")
        }

        var generatedText = ""
        for _ in 0 ..< options.maxPredictionTokens {
            if Task.isCancelled { break }
            let result = engine.sampleNext(seqID)
            if result.is_eos || result.was_cancelled { break }
            generatedText += Self.extractPiece(result)
        }
        return generatedText
    }

    private func estimateTokenCount(_ text: String) -> Int {
        // Rough estimate: ~4 chars per token for English code
        max(1, text.utf8.count / 4)
    }
}
