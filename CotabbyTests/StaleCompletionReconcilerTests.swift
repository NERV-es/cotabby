import XCTest
@testable import Cotabby

/// Tests for the pure rules that salvage a completion which finished generating after the user kept
/// typing. This logic decides whether a stale result can be rescued by trimming the type-ahead
/// overlap, so it is the heart of the new salvage path and worth covering exhaustively in isolation.
final class StaleCompletionReconcilerTests: XCTestCase {
    // MARK: - Exact trim

    func test_reconcile_trimsTypedAheadWhenContinuationStartsWithIt() {
        let reconciled = StaleCompletionReconciler.reconcile(
            continuation: "ing with me today",
            prefixAtRequest: "thanks for meet",
            currentPrefix: "thanks for meeting"
        )

        XCTAssertEqual(reconciled?.text, " with me today")
        XCTAssertEqual(reconciled?.typedSinceRequest, "ing")
        XCTAssertEqual(reconciled?.confidence, .exact)
    }

    func test_reconcile_preservesLeadingSpaceTheUserHasNotTypedYet() {
        // The user typed "see" but not the following space, so the salvaged tail must keep it.
        let reconciled = StaleCompletionReconciler.reconcile(
            continuation: "see you soon",
            prefixAtRequest: "I will ",
            currentPrefix: "I will see"
        )

        XCTAssertEqual(reconciled?.text, " you soon")
        XCTAssertEqual(reconciled?.confidence, .exact)
    }

    // MARK: - No-op cases

    func test_reconcile_returnsNilWhenNothingWasTyped() {
        // Salvage exists to recover from type-ahead. An unchanged prefix is a plain stale drop.
        let reconciled = StaleCompletionReconciler.reconcile(
            continuation: " with me today",
            prefixAtRequest: "thanks for meeting",
            currentPrefix: "thanks for meeting"
        )

        XCTAssertNil(reconciled)
    }

    func test_reconcile_returnsNilWhenUserDeletedPastTheRequestBaseline() {
        let reconciled = StaleCompletionReconciler.reconcile(
            continuation: "ing with me today",
            prefixAtRequest: "thanks for meet",
            currentPrefix: "thanks for me"
        )

        XCTAssertNil(reconciled)
    }

    func test_reconcile_returnsNilWhenTypedTextIsDisjointFromContinuation() {
        let reconciled = StaleCompletionReconciler.reconcile(
            continuation: "ing with me today",
            prefixAtRequest: "thanks for meet",
            currentPrefix: "thanks for meetXYZQR"
        )

        XCTAssertNil(reconciled)
    }

    // MARK: - Overlap fallback

    func test_reconcile_recoversJoinViaSuffixPrefixOverlap() {
        // The model continued from "I will " with "you soon" while the user typed "see you "; the
        // shared "you " lets us recover "soon".
        let reconciled = StaleCompletionReconciler.reconcile(
            continuation: "you soon",
            prefixAtRequest: "I will ",
            currentPrefix: "I will see you "
        )

        XCTAssertEqual(reconciled?.text, "soon")
        XCTAssertEqual(reconciled?.typedSinceRequest, "see you ")
        XCTAssertEqual(reconciled?.confidence, .overlap)
    }

    func test_reconcile_rejectsOverlapBelowMinimum() {
        // Only a 2-character ("de") overlap exists, under the default minimum of 3.
        let reconciled = StaleCompletionReconciler.reconcile(
            continuation: "defgh",
            prefixAtRequest: "z",
            currentPrefix: "zabde"
        )

        XCTAssertNil(reconciled)
    }

    func test_reconcile_honorsCustomMinimumOverlap() {
        let reconciled = StaleCompletionReconciler.reconcile(
            continuation: "defgh",
            prefixAtRequest: "z",
            currentPrefix: "zabde",
            minimumOverlap: 2
        )

        XCTAssertEqual(reconciled?.text, "fgh")
        XCTAssertEqual(reconciled?.confidence, .overlap)
    }

    // MARK: - Empty / whitespace guards

    func test_reconcile_returnsNilWhenTheUserTypedThroughTheWholeContinuation() {
        let reconciled = StaleCompletionReconciler.reconcile(
            continuation: "there",
            prefixAtRequest: "hi ",
            currentPrefix: "hi there"
        )

        XCTAssertNil(reconciled)
    }

    func test_reconcile_returnsNilWhenSalvagedTailIsWhitespaceOnly() {
        let reconciled = StaleCompletionReconciler.reconcile(
            continuation: "there ",
            prefixAtRequest: "hi ",
            currentPrefix: "hi there"
        )

        XCTAssertNil(reconciled)
    }

    // MARK: - Grapheme safety

    func test_reconcile_trimsByGraphemeForEmoji() {
        let reconciled = StaleCompletionReconciler.reconcile(
            continuation: "👍 thanks",
            prefixAtRequest: "hi ",
            currentPrefix: "hi 👍"
        )

        XCTAssertEqual(reconciled?.text, " thanks")
        XCTAssertEqual(reconciled?.typedSinceRequest, "👍")
        XCTAssertEqual(reconciled?.confidence, .exact)
    }

    // MARK: - Overlap primitive

    func test_longestSuffixPrefixOverlap_findsSharedJoin() {
        XCTAssertEqual(
            StaleCompletionReconciler.longestSuffixPrefixOverlap(suffix: "see you ", prefix: "you soon"),
            4
        )
    }

    func test_longestSuffixPrefixOverlap_isZeroWhenDisjoint() {
        XCTAssertEqual(
            StaleCompletionReconciler.longestSuffixPrefixOverlap(suffix: "abc", prefix: "xyz"),
            0
        )
    }

    func test_longestSuffixPrefixOverlap_isZeroForEmptyInput() {
        XCTAssertEqual(
            StaleCompletionReconciler.longestSuffixPrefixOverlap(suffix: "", prefix: "abc"),
            0
        )
    }
}
