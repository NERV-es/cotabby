# Tree Decode — Multi-Candidate Inference Plan

## Goal
Generate N candidates simultaneously using shared KV cache prefix (DTSM pattern from Cotypist RE), allowing users to cycle between alternatives.

## Architecture

```
SuggestionCoordinator
  → SuggestionEngineRouter
    → LlamaSuggestionEngine.generateCandidates(for:count:)
      → LlamaRuntimeCore.generateTree(prompt:options:candidateCount:)
        → engine.createSequence() × N (shared KV prefix via fork)
        → decode loop: sample N sequences in parallel
        → return ranked candidates
  → SuggestionResult gains `alternatives: [String]`
  → ActiveSuggestionSession tracks current alternative index
  → User cycles with configurable key (↑/↓ or Option+N)
```

## Implementation Phases

### Phase 1: Core — Multi-sequence generation in LlamaRuntimeCore
- Add `generateTree(prompt:options:candidateCount:)` method
- Fork the shared prefix sequence into N children
- Sample each child independently, collect results
- Rank by cumulative log probability (or length-normalized)

### Phase 2: Data model — Alternatives in SuggestionResult
- Extend `SuggestionResult` with `alternatives: [String]`
- Extend `ActiveSuggestionSession` with `currentAlternativeIndex`
- Add cycling method to session

### Phase 3: UI — Cycle trigger and overlay indicator
- Add keyboard shortcut for cycling (Option+] / Option+[)
- Show "1/3" indicator in suggestion overlay when alternatives exist
- Persist preferred alternative for context learning

### Phase 4: Settings
- `candidateCount` setting (1-5, default 3)
- Toggle for tree decode on/off (fallback to single-candidate)
- Latency budget — abort extra candidates if primary is fast enough

## Key Technical Details

### KV Cache Forking
The CotabbyInferenceEngine already supports:
- `createSequence(config)` → new sequence with fresh KV
- `decodePrompt(seqID, tokens, count, offset)` → fill KV
- `trimKV(seqID, tokenCount)` → truncate KV

For tree decode we need to verify if the engine supports **sequence forking** 
(copy existing KV into a new sequence). If not, we decode the shared prefix once 
then decode it N times (still cheaper than N full prompts due to batch parallelism).

### Sampling Diversity
To get meaningfully different candidates:
- Use different temperatures per branch (e.g., 0.3, 0.6, 0.9)
- Or: sample top-K first tokens, then greedily extend each
- Or: use nucleus sampling with different seeds per branch

### Latency Budget
Tree decode adds ~2-3x latency for 3 candidates (shared prefix amortizes prompt).
Only trigger when:
- User has been idle > 500ms (not mid-typing burst)
- Model is small enough (< 4B params) for multi-sequence
- Previous single-candidate latency was < 200ms
