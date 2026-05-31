import Foundation

/// File overview:
/// Multi-candidate generation using tree decoding. Spawns N inference sequences from a shared
/// prompt prefix, samples each with different parameters to produce diverse alternatives.
/// This is the "DTSM" pattern — Decode Tree Sequence Manager.
///
/// Design constraints:
/// - CotabbyInferenceEngine supports up to 4 concurrent sequences
/// - Sequence 0 is reserved for the primary autocomplete (KV cache reuse)
/// - Tree decode uses ephemeral sequences (1-3) for alternatives
/// - Total latency budget: primary + 50% overhead for alternatives

/// Configuration for tree decode behavior.
struct TreeDecodeConfiguration: Sendable {
    /// Number of candidates to generate (1 = disabled, 2-4 supported).
    let candidateCount: Int

    /// Temperature multipliers applied to each branch beyond the primary.
    /// Branch 0 uses the request's original temperature.
    /// Branch 1 uses temperature * diversityFactors[0], etc.
    let diversityFactors: [Double]

    /// Maximum tokens to generate per alternative branch.
    /// Alternatives can be shorter than the primary to save latency.
    let alternativeMaxTokens: Int?

    /// If true, abort alternative generation when the primary completes
    /// and alternatives haven't started producing tokens yet.
    let earlyAbortOnSlowAlternatives: Bool

    static let `default` = TreeDecodeConfiguration(
        candidateCount: 3,
        diversityFactors: [1.5, 2.5],
        alternativeMaxTokens: nil,
        earlyAbortOnSlowAlternatives: true
    )

    static let disabled = TreeDecodeConfiguration(
        candidateCount: 1,
        diversityFactors: [],
        alternativeMaxTokens: nil,
        earlyAbortOnSlowAlternatives: false
    )
}

/// A single candidate from tree decode, with metadata for ranking.
struct TreeDecodeCandidate: Sendable {
    let text: String
    let tokenCount: Int
    let latency: TimeInterval
    /// Branch index (0 = primary with original params)
    let branchIndex: Int
}

/// Result of a tree decode operation.
struct TreeDecodeResult: Sendable {
    /// Candidates ordered by rank (primary first, then alternatives sorted by quality heuristic).
    let candidates: [TreeDecodeCandidate]

    /// Total wall-clock time for the entire tree decode (prompt + all branches).
    let totalLatency: TimeInterval

    var primary: TreeDecodeCandidate? { candidates.first }
    var alternatives: [TreeDecodeCandidate] { Array(candidates.dropFirst()) }
}
