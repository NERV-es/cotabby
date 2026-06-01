import Foundation

/// File overview:
/// Pure rules for salvaging a completion that finished generating *after* the user kept typing.
///
/// Inline autocomplete has an unavoidable race. A request is built from the prefix at time `t0`, the
/// model decodes for some milliseconds, and a fast typist can append characters before the result
/// lands at `t1`. The naive response is to throw the now-stale result away (the generation guard in
/// `SuggestionCoordinator.apply`). This helper instead tries to recover it: it trims the characters
/// typed during the race off the front of the continuation, so a request built from
/// "thanks for meet" whose model returned "ing with me today" still renders " with me today" after
/// the user has typed "ing".
///
/// This type is intentionally pure (identical inputs always yield identical output), so the salvage
/// decision is unit-testable in isolation from Accessibility timing and runtime state. The
/// context-level guardrails (focus shift, selected text, a changed suffix) stay with the coordinator,
/// which owns that live data; this helper only reasons about the three strings involved.
enum StaleCompletionReconciler {
    /// How confident we are that the salvaged tail is correct.
    ///
    /// `exact` means the continuation literally began with the typed-ahead text, so the trim is
    /// unambiguous. `overlap` means we recovered the join by matching a suffix of the typed text
    /// against a prefix of the continuation, which is plausible but weaker, so callers can log or
    /// gate it separately.
    enum Confidence: String, Equatable, Sendable {
        case exact
        case overlap
    }

    /// A salvaged continuation plus the evidence behind it.
    struct Reconciled: Equatable, Sendable {
        /// The continuation with the race-window typing trimmed off the front.
        let text: String
        /// The characters the user typed between the request going out and the result landing.
        let typedSinceRequest: String
        let confidence: Confidence
    }

    /// Minimum suffix/prefix overlap, in characters, before the fuzzy join is trusted. One- and
    /// two-character overlaps fire constantly on spaces and single letters, so they would salvage
    /// garbage; three keeps the fallback meaningful without being reckless.
    static let defaultMinimumOverlap = 3

    /// Attempts to salvage `continuation` given the prefix it was generated against and the prefix
    /// now in the field. Returns `nil` when the result is unsalvageable: the user deleted past the
    /// request baseline, did not actually type ahead, typed something disjoint from the continuation,
    /// or the trimmed tail collapses to whitespace.
    static func reconcile(
        continuation: String,
        prefixAtRequest: String,
        currentPrefix: String,
        minimumOverlap: Int = defaultMinimumOverlap
    ) -> Reconciled? {
        // The user must only have *added* text since the request. If the current prefix no longer
        // begins with the request prefix they deleted past the baseline or the field diverged, and
        // any trim we computed would be guesswork.
        guard currentPrefix.hasPrefix(prefixAtRequest) else {
            return nil
        }

        let typed = String(currentPrefix.dropFirst(prefixAtRequest.count))

        // Salvage exists to recover from type-ahead specifically. With nothing typed there is no
        // overlap to remove, so this is a plain stale drop, not a rescue; let the caller handle it.
        guard !typed.isEmpty else {
            return nil
        }

        // Clean case: the user is typing straight along the predicted continuation, so it begins with
        // exactly what they typed. Drop that prefix and show the remainder.
        if continuation.hasPrefix(typed) {
            return finalize(
                String(continuation.dropFirst(typed.count)),
                typedSinceRequest: typed,
                confidence: .exact
            )
        }

        // Fuzzy case: the continuation and the typed-ahead text converge partway in. If a suffix of
        // what the user typed equals a prefix of the continuation (typed "see you ", model returned
        // "you soon"), drop the overlapping head so "you soon" becomes "soon".
        let overlap = longestSuffixPrefixOverlap(suffix: typed, prefix: continuation)
        if overlap >= minimumOverlap {
            return finalize(
                String(continuation.dropFirst(overlap)),
                typedSinceRequest: typed,
                confidence: .overlap
            )
        }

        return nil
    }

    /// Returns the largest `k` such that the last `k` characters of `suffix` equal the first `k`
    /// characters of `prefix`. Operates in `Character` units so multi-scalar graphemes (emoji,
    /// composed characters) are never split mid-cluster.
    static func longestSuffixPrefixOverlap(suffix: String, prefix: String) -> Int {
        let suffixCharacters = Array(suffix)
        let prefixCharacters = Array(prefix)
        let maxOverlap = min(suffixCharacters.count, prefixCharacters.count)
        guard maxOverlap > 0 else {
            return 0
        }

        var best = 0
        for candidate in 1...maxOverlap {
            let tail = suffixCharacters[(suffixCharacters.count - candidate)...]
            let head = prefixCharacters[..<candidate]
            if tail.elementsEqual(head) {
                best = candidate
            }
        }
        return best
    }

    /// Rejects salvaged tails that are empty or whitespace-only. Showing "ghost spaces" reads as a
    /// broken suggestion, matching `ActiveSuggestionSession.isExhausted`.
    private static func finalize(
        _ text: String,
        typedSinceRequest: String,
        confidence: Confidence
    ) -> Reconciled? {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return Reconciled(text: text, typedSinceRequest: typedSinceRequest, confidence: confidence)
    }
}
