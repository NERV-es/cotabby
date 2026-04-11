import Combine
import CoreGraphics
import Foundation

/// File overview:
/// Coordinates Tabby's end-to-end inline-completion pipeline. It listens to focus and input
/// changes, schedules debounced generation, rejects stale results, drives the ghost overlay,
/// and accepts suggestions with `Tab`.
///
/// This file is currently the app's largest state machine. The comments and section markers below
/// are here to help maintainers navigate its responsibilities until more logic is extracted into
/// smaller types.
@MainActor
final class SuggestionCoordinator: ObservableObject {
    /// `@Published private(set)` means SwiftUI can observe these values, but only the coordinator
    /// itself is allowed to mutate them.
    ///
    /// The first group is user-facing and debug-facing state surfaced in the menu UI.
    @Published private(set) var state: SuggestionDebugState = .idle
    @Published private(set) var overlayState: OverlayState = .hidden(reason: "Overlay idle.")
    @Published private(set) var latestSuggestionPreview: String?
    @Published private(set) var latestFullSuggestionPreview: String?
    @Published private(set) var latestRemainingSuggestionPreview: String?
    @Published private(set) var latestAcceptedCharacterCount: Int?
    @Published private(set) var latestRemainingCharacterCount: Int?
    @Published private(set) var latestAcceptanceAction: String?
    @Published private(set) var latestLatencyMilliseconds: Int?
    @Published private(set) var latestStageMessage = "Idle"
    @Published private(set) var latestOverlayMessage = "Overlay idle."
    @Published private(set) var latestPromptPreview: String?
    @Published private(set) var latestRawModelOutput: String?
    @Published private(set) var latestGenerationNumber: UInt64?
    @Published private(set) var visualContextStatus: VisualContextStatus = .idle
    @Published private(set) var latestInjectedContextSummary: String?
    @Published private(set) var totalTabAcceptedWordCount: Int = 0
    @Published private(set) var selectedWordCountPreset: SuggestionWordCountPreset = .threeToSeven
    @Published private(set) var selectedPromptMode: SuggestionPromptMode = .guided

    // Core collaborators. The coordinator depends on capability-shaped protocols here so its
    // orchestration logic stays separated from concrete service implementations.
    private let permissionManager: any SuggestionPermissionProviding
    private let focusModel: any SuggestionFocusProviding
    private let inputMonitor: any SuggestionInputMonitoring
    private let overlayController: OverlayController
    private let suggestionInserter: any SuggestionInserting
    private let suggestionEngine: any SuggestionGenerating
    private let visualContextCoordinator: any VisualContextCoordinating
    private let interactionState: SuggestionInteractionState
    private let workController: SuggestionWorkController
    private let configuration: SuggestionConfiguration
    private let userDefaults: UserDefaults
    private let overlayPresenter: SuggestionOverlayPresenter
    private let logger: SuggestionDebugLogger

    private static let selectedWordCountPresetDefaultsKey = "selectedSuggestionWordCountPreset"
    private static let selectedPromptModeDefaultsKey = "selectedSuggestionPromptMode"
    private static let totalTabAcceptedWordCountDefaultsKey = "totalTabAcceptedWordCount"

    // Combine subscriptions are the coordinator's remaining direct mutable bookkeeping.
    // Async work and active-session storage now live in dedicated collaborators below.
    private var cancellables = Set<AnyCancellable>()

    init(
        permissionManager: any SuggestionPermissionProviding,
        focusModel: any SuggestionFocusProviding,
        inputMonitor: any SuggestionInputMonitoring,
        overlayController: OverlayController,
        suggestionInserter: any SuggestionInserting,
        suggestionEngine: any SuggestionGenerating,
        visualContextCoordinator: any VisualContextCoordinating,
        interactionState: SuggestionInteractionState,
        workController: SuggestionWorkController,
        configuration: SuggestionConfiguration,
        userDefaults: UserDefaults = .standard
    ) {
        // Restore persisted user preferences before wiring the coordinator to the rest of the app.
        // This ensures first-render UI matches the settings the user last chose.
        let storedWordCountPreset = userDefaults
            .string(forKey: Self.selectedWordCountPresetDefaultsKey)
            .flatMap(SuggestionWordCountPreset.init(rawValue:))
        let resolvedWordCountPreset = storedWordCountPreset ?? configuration.defaultWordCountPreset
        let storedPromptMode = userDefaults
            .string(forKey: Self.selectedPromptModeDefaultsKey)
            .flatMap(SuggestionPromptMode.init(rawValue:))
        let resolvedPromptMode = storedPromptMode ?? configuration.defaultPromptMode
        let storedTotalTabAcceptedWordCount = userDefaults.integer(forKey: Self.totalTabAcceptedWordCountDefaultsKey)

        self.permissionManager = permissionManager
        self.focusModel = focusModel
        self.inputMonitor = inputMonitor
        self.overlayController = overlayController
        self.suggestionInserter = suggestionInserter
        self.suggestionEngine = suggestionEngine
        self.visualContextCoordinator = visualContextCoordinator
        self.interactionState = interactionState
        self.workController = workController
        self.configuration = configuration
        self.userDefaults = userDefaults
        // These collaborators isolate "how overlay/logging works" from "when the coordinator
        // wants to show state," which keeps the coordinator closer to orchestration code.
        overlayPresenter = SuggestionOverlayPresenter(overlayController: overlayController)
        logger = SuggestionDebugLogger()
        selectedWordCountPreset = resolvedWordCountPreset
        selectedPromptMode = resolvedPromptMode
        totalTabAcceptedWordCount = max(storedTotalTabAcceptedWordCount, 0)
        visualContextStatus = visualContextCoordinator.status
        latestInjectedContextSummary = visualContextCoordinator.latestSummary

        if storedWordCountPreset == nil {
            userDefaults.set(resolvedWordCountPreset.rawValue, forKey: Self.selectedWordCountPresetDefaultsKey)
        }

        if storedPromptMode == nil {
            userDefaults.set(resolvedPromptMode.rawValue, forKey: Self.selectedPromptModeDefaultsKey)
        }

        overlayState = overlayController.state
        latestOverlayMessage = overlayController.state.detail

        focusModel.snapshotPublisher
            .sink { [weak self] snapshot in
                self?.handleFocusSnapshotChange(snapshot)
            }
            .store(in: &cancellables)

        permissionManager.inputMonitoringGrantedPublisher
            .sink { [weak self] _ in
                self?.handlePermissionChange()
            }
            .store(in: &cancellables)

        permissionManager.screenRecordingGrantedPublisher
            .sink { [weak self] _ in
                self?.handlePermissionChange()
            }
            .store(in: &cancellables)

        // The monitor and overlay controller are callback-driven. The coordinator translates those
        // callbacks back into its state-machine methods.
        inputMonitor.onEvent = { [weak self] event in
            self?.handleInputEvent(event) ?? false
        }

        inputMonitor.onSuppressedSyntheticInput = { [weak self] in
            self?.handleSuppressedSyntheticInput()
        }

        overlayController.onStateChange = { [weak self] state in
            self?.overlayState = state
        }

        visualContextCoordinator.onStateChange = { [weak self] status, summary in
            self?.visualContextStatus = status
            self?.latestInjectedContextSummary = summary
        }

        visualContextCoordinator.onInjectedContextReady = { [weak self] elementIdentifier in
            self?.schedulePredictionForCurrentFocusIfPossible(matching: elementIdentifier)
        }
    }

    private var currentWorkID: UInt64 {
        workController.currentWorkID
    }

    // MARK: - Lifecycle

    /// Reconciles coordinator state with the current permission and focus environment.
    func start() {
        reconcileWithCurrentEnvironment()
    }

    /// Cancels any pending work and detaches long-lived callbacks during shutdown.
    func stop() {
        cancelPredictionWork()
        visualContextCoordinator.cancel(resetState: true)
        hideOverlay(reason: "Overlay hidden because Tabby stopped observing suggestions.")
        inputMonitor.onEvent = nil
        inputMonitor.onSuppressedSyntheticInput = nil
        overlayController.onStateChange = nil
        visualContextCoordinator.onStateChange = nil
        visualContextCoordinator.onInjectedContextReady = nil
    }

    /// Clears any active suggestion work before the runtime swaps to a different model.
    /// This prevents stale completions from the previous model from surviving the switch.
    func prepareForRuntimeModelSwitch() {
        cancelPredictionWork()
        interactionState.resetAll()
        visualContextCoordinator.cancel(resetState: true)
        clearSuggestion(clearDiagnostics: true)
        hideOverlay(reason: "Overlay hidden because the runtime model is switching.")
        state = .idle
        latestStageMessage = "Idle: runtime model switching reset active suggestion state."
    }

    // MARK: - User Preferences

    /// Updates the length target used in prompt instructions and persists the user preference.
    func selectWordCountPreset(_ preset: SuggestionWordCountPreset) {
        guard selectedWordCountPreset != preset else {
            return
        }

        selectedWordCountPreset = preset
        userDefaults.set(preset.rawValue, forKey: Self.selectedWordCountPresetDefaultsKey)

        cancelPredictionWork()
        clearSuggestion(clearDiagnostics: true)
        hideOverlay(reason: "Overlay hidden because suggestion length settings changed.")
        state = .idle
        latestStageMessage = "Updated suggestion length to \(preset.displayLabel)."

        if permissionManager.inputMonitoringGranted,
           case .supported = focusModel.snapshot.capability
        {
            schedulePrediction()
        }
    }

    /// Switches prompt strategy between guided and strict prefix-only generation.
    func selectPromptMode(_ mode: SuggestionPromptMode) {
        guard selectedPromptMode != mode else {
            return
        }

        selectedPromptMode = mode
        userDefaults.set(mode.rawValue, forKey: Self.selectedPromptModeDefaultsKey)

        cancelPredictionWork()
        clearSuggestion(clearDiagnostics: true)
        hideOverlay(reason: "Overlay hidden because prompt mode changed.")
        state = .idle
        latestStageMessage = "Updated prompt mode to \(mode.displayLabel)."

        if mode.usesVisualContext {
            if case .supported = focusModel.snapshot.capability,
               let focusedContext = focusModel.snapshot.context
            {
                visualContextCoordinator.startSessionIfNeeded(for: focusedContext)
            }
        } else {
            visualContextCoordinator.cancel(resetState: true)
        }

        if permissionManager.inputMonitoringGranted,
           case .supported = focusModel.snapshot.capability
        {
            schedulePrediction()
        }
    }

    // MARK: - Environment and Input Handling

    private func handlePermissionChange() {
        if !permissionManager.screenRecordingGranted {
            visualContextCoordinator.cancel(resetState: true)
        }

        reconcileWithCurrentEnvironment()

        if SuggestionAvailabilityEvaluator.shouldSchedulePrediction(
            inputMonitoringGranted: permissionManager.inputMonitoringGranted,
            focusSnapshot: focusModel.snapshot
        ) {
            handleSupportedSnapshot(focusModel.snapshot)
        }
    }

    private func handleFocusSnapshotChange(_ snapshot: FocusSnapshot) {
        if let disabledReason = SuggestionAvailabilityEvaluator.disabledReason(
            inputMonitoringGranted: permissionManager.inputMonitoringGranted,
            focusSnapshot: snapshot
        ) {
            disablePredictions(reason: disabledReason)
        } else {
            handleSupportedSnapshot(snapshot)
        }
    }

    private func handleSupportedSnapshot(_ snapshot: FocusSnapshot) {
        guard let focusedContext = snapshot.context else {
            disablePredictions(reason: "No focused text input.")
            return
        }

        if selectedPromptMode.usesVisualContext {
            visualContextCoordinator.startSessionIfNeeded(for: focusedContext)
        } else if visualContextStatus != .idle {
            visualContextCoordinator.cancel(resetState: true)
        }

        if case .disabled = state {
            state = .idle
        }

        if interactionState.activeSession != nil {
            reconcileActiveSession(with: snapshot)
            return
        }

        if interactionState.hasFocusedElementChanged(comparedTo: focusedContext) {
            cancelPredictionWork()
            clearSuggestion(clearDiagnostics: true)
            hideOverlay(reason: "Overlay hidden because the focused field changed.")
            state = .idle
        }

        if overlayState.isVisible {
            hideOverlay(reason: "Overlay hidden because no ready suggestion remains.")
        }
    }

    private func handleInputEvent(_ event: CapturedInputEvent) -> Bool {
        if let disabledReason = SuggestionAvailabilityEvaluator.disabledReason(
            inputMonitoringGranted: permissionManager.inputMonitoringGranted,
            focusSnapshot: focusModel.snapshot
        ) {
            disablePredictions(reason: disabledReason)
            return false
        }

        if event.kind == .tab {
            return acceptCurrentSuggestion()
        }

        if let activeSession = interactionState.activeSession {
            return handleInputEvent(event, with: activeSession)
        }

        if event.shouldClearSuggestion {
            cancelPredictionWork()
            clearSuggestion(clearDiagnostics: true)
            hideOverlay(reason: SuggestionSessionReconciler.overlayHideReason(for: event))
            if !event.shouldSchedulePrediction {
                state = .idle
            }
        }

        if event.shouldSchedulePrediction {
            schedulePrediction()
        }

        return false
    }

    private func handleSuppressedSyntheticInput() {
        logStage(
            "suppressed-synthetic-input",
            workID: currentWorkID,
            generation: latestGenerationNumber,
            message: "Ignored Tabby's own synthetic key event."
        )
    }

    /// While a suggestion tail is active, normal typing is interpreted relative to that tail first.
    /// This is the same idea as reconciling optimistic UI with the eventual live editor state:
    /// keep the existing session only when the user's new input is still consistent with it.
    private func handleInputEvent(_ event: CapturedInputEvent, with session: ActiveSuggestionSession) -> Bool {
        switch event.kind {
        case .textMutation:
            if advanceActiveSessionIfTypedCharactersMatch(event.characters, session: session) {
                return false
            }

            invalidateActiveSuggestion(
                reason: SuggestionSessionReconciler.overlayHideReason(for: event),
                clearDiagnostics: false
            )
            if event.shouldSchedulePrediction {
                schedulePrediction()
            }
            return false

        case .shortcutMutation:
            invalidateActiveSuggestion(
                reason: "Overlay hidden because a shortcut changed the text and invalidated the current suggestion.",
                clearDiagnostics: false
            )
            if event.shouldSchedulePrediction {
                schedulePrediction()
            }
            return false

        case .navigation, .dismissal:
            invalidateActiveSuggestion(
                reason: SuggestionSessionReconciler.overlayHideReason(for: event),
                clearDiagnostics: false
            )
            state = .idle
            return false

        case .other, .tab:
            return false
        }
    }

    // MARK: - Prediction Pipeline

    private func schedulePrediction() {
        if let disabledReason = SuggestionAvailabilityEvaluator.disabledReason(
            inputMonitoringGranted: permissionManager.inputMonitoringGranted,
            focusSnapshot: focusModel.snapshot
        ) {
            disablePredictions(reason: disabledReason)
            return
        }

        // Task cancellation in Swift is cooperative, so we also use an explicit work id.
        // That gives us strict "latest request wins" semantics even if an old task wakes up late.
        let workID = workController.replaceDebouncedWork(
            delayMilliseconds: configuration.debounceMilliseconds
        ) { [weak self] workID in
            await self?.generateFromCurrentFocus(workID: workID)
        }

        state = .debouncing
        logStage("debouncing", workID: workID, message: "Waiting \(configuration.debounceMilliseconds)ms before generating.")
    }

    /// Refreshes focus after debounce, materializes a stable context, and starts generation.
    private func generateFromCurrentFocus(workID: UInt64) async {
        guard workController.isCurrent(workID) else {
            return
        }

        // We intentionally re-read the latest focus snapshot here instead of trusting the earlier
        // key event, because the user may have switched apps or fields during the debounce window.
        focusModel.refreshNow()
        let snapshot = focusModel.snapshot

        if let disabledReason = SuggestionAvailabilityEvaluator.disabledReason(
            inputMonitoringGranted: permissionManager.inputMonitoringGranted,
            focusSnapshot: snapshot
        ) {
            disablePredictions(reason: disabledReason)
            return
        }

        guard let rawContext = snapshot.context else {
            disablePredictions(reason: snapshot.capability.summary)
            return
        }

        guard SuggestionRequestFactory.shouldGenerateSuggestion(for: rawContext.precedingText) else {
            clearSuggestion()
            hideOverlay(reason: "Overlay hidden because suggestions wait for a completed word boundary (space).")
            state = .idle
            return
        }

        let context = interactionState.materializeContext(from: rawContext)
        let injectedContextSummary = selectedPromptMode.usesVisualContext
            ? visualContextCoordinator.summary(for: context)
            : nil
        let requestBuildResult = SuggestionRequestFactory.buildRequest(
            context: context,
            promptMode: selectedPromptMode,
            wordCountPreset: selectedWordCountPreset,
            configuration: configuration,
            injectedContextSummary: injectedContextSummary
        )
        latestGenerationNumber = context.generation
        latestPromptPreview = requestBuildResult.promptPreview
        latestRawModelOutput = nil
        let request = requestBuildResult.request

        state = .generating
        logStage(
            "generating",
            workID: workID,
            generation: context.generation,
            message: "Requesting a completion for \(context.elementIdentifier).",
            prompt: requestBuildResult.promptPreview
        )

        workController.replaceGenerationWork(for: workID) { [weak self] in
            guard let self else {
                return
            }

            do {
                let result = try await suggestionEngine.generateSuggestion(for: request)
                guard !Task.isCancelled, self.workController.isCurrent(workID) else {
                    return
                }

                await apply(result: result, workID: workID)
            } catch SuggestionClientError.cancelled {
                return
            } catch {
                guard self.workController.isCurrent(workID) else {
                    return
                }

                await applyFailure(error.localizedDescription, workID: workID)
            }
        }
    }

    /// Promotes a generated result to `ready` only when it is still fresh for the current field.
    private func apply(result: SuggestionResult, workID: UInt64) async {
        guard workController.isCurrent(workID) else {
            return
        }

        focusModel.refreshNow()
        let snapshot = focusModel.snapshot

        if let disabledReason = SuggestionAvailabilityEvaluator.disabledReason(
            inputMonitoringGranted: permissionManager.inputMonitoringGranted,
            focusSnapshot: snapshot
        ) {
            disablePredictions(reason: disabledReason)
            return
        }

        guard let rawContext = snapshot.context else {
            disablePredictions(reason: snapshot.capability.summary)
            return
        }

        let liveContext = interactionState.materializeContext(from: rawContext)
        // Generation numbers are our stale-result guard. If the text changed while the model was
        // thinking, we drop the answer instead of showing a suggestion for old content.
        guard liveContext.generation == result.generation else {
            latestRawModelOutput = SuggestionDebugLogger.debugPreview(result.rawText)
            logStage(
                "stale-drop",
                workID: workID,
                generation: result.generation,
                message: "Dropped stale result because live generation is \(liveContext.generation).",
                rawOutput: result.rawText,
                normalizedOutput: result.text
            )
            hideOverlay(reason: "Overlay hidden because a stale result was dropped.")
            return
        }

        latestRawModelOutput = SuggestionDebugLogger.debugPreview(result.rawText)

        guard !result.text.isEmpty else {
            clearSuggestion()
            hideOverlay(reason: "Overlay hidden because the model returned an empty continuation.")
            state = .idle
            logStage(
                "empty-result",
                workID: workID,
                generation: result.generation,
                message: "Model returned an empty or whitespace-only continuation after normalization.",
                rawOutput: result.rawText,
                normalizedOutput: result.text
            )
            return
        }

        guard liveContext.selection.length == 0 else {
            clearSuggestion(clearDiagnostics: true)
            hideOverlay(reason: "Overlay hidden because text is selected.")
            state = .idle
            logStage(
                "selected-text",
                workID: workID,
                generation: result.generation,
                message: "Ignored the suggestion because the current field has selected text.",
                rawOutput: result.rawText,
                normalizedOutput: result.text
            )
            return
        }

        latestLatencyMilliseconds = Int(result.latency * 1000)
        latestGenerationNumber = liveContext.generation
        let session = interactionState.startSession(
            fullText: result.text,
            liveContext: liveContext,
            latency: result.latency
        )
        applySessionDiagnostics(session, acceptanceAction: "Generated new suggestion.")
        state = .ready(text: session.remainingText, latency: session.latency)
        presentOverlay(text: session.remainingText, at: liveContext.caretRect)
        logStage(
            "ready",
            workID: workID,
            generation: result.generation,
            message: "Accepted a non-empty normalized suggestion.",
            rawOutput: result.rawText,
            normalizedOutput: result.text
        )
    }

    /// Converts a runtime or engine failure into visible coordinator state and clears stale UI.
    private func applyFailure(_ message: String, workID: UInt64) async {
        guard workController.isCurrent(workID) else {
            return
        }

        clearSuggestion()
        hideOverlay(reason: "Overlay hidden because generation failed.")
        state = .failed(message)
        logStage("failed", workID: workID, generation: latestGenerationNumber, message: message)
    }

    // MARK: - Coordinator State Reset

    /// Recomputes whether prediction should be enabled based on current permissions and focus support.
    private func reconcileWithCurrentEnvironment() {
        let disabledReason = SuggestionAvailabilityEvaluator.disabledReason(
            inputMonitoringGranted: permissionManager.inputMonitoringGranted,
            focusSnapshot: focusModel.snapshot
        )

        if disabledReason == nil {
            if case .disabled = state {
                state = .idle
            }
        } else if let disabledReason {
            disablePredictions(reason: disabledReason)
        }
    }

    /// Reconciles the active suggestion session with the latest live AX context.
    /// This is the heart of partial acceptance: a text change is not automatically "stale" anymore.
    /// It may instead mean "the user consumed the next expected part of the suggestion."
    private func reconcileActiveSession(with snapshot: FocusSnapshot) {
        guard interactionState.activeSession != nil else {
            if overlayState.isVisible {
                hideOverlay(reason: "Overlay hidden because no ready suggestion remains.")
            }
            return
        }

        guard case .supported = snapshot.capability, let rawContext = snapshot.context else {
            invalidateActiveSuggestion(reason: snapshot.capability.summary)
            return
        }

        guard let reconciliation = interactionState.reconcileActiveSession(with: rawContext) else {
            invalidateActiveSuggestion(reason: "Overlay hidden because no ready suggestion remains.")
            return
        }

        switch reconciliation {
        case let .valid(liveContext, reconciledSession, advancement):
            latestGenerationNumber = liveContext.generation
            applySessionDiagnostics(reconciledSession, acceptanceAction: advancement?.actionSummary ?? latestAcceptanceAction)

            if reconciledSession.isExhausted {
                completeActiveSuggestion(
                    reason: "Overlay hidden because the active suggestion was fully consumed.",
                    scheduleNextPrediction: true,
                    stage: advancement?.exhaustionStage ?? "session-exhausted",
                    message: advancement?.exhaustionMessage ?? "The active suggestion was fully consumed.",
                    acceptanceAction: advancement?.actionSummary ?? "Suggestion tail was fully consumed."
                )
                return
            }

            state = .ready(text: reconciledSession.remainingText, latency: reconciledSession.latency)
            presentOverlay(text: reconciledSession.remainingText, at: liveContext.caretRect)
            if let advancement {
                logStage(
                    advancement.stage,
                    workID: currentWorkID,
                    generation: liveContext.generation,
                    message: advancement.message,
                    normalizedOutput: reconciledSession.remainingText
                )
            }

        case let .invalid(reason):
            invalidateActiveSuggestion(reason: reason)
        }
    }

    /// Fully disables prediction, clears cached context, and updates UI messaging with the cause.
    private func disablePredictions(reason: String) {
        cancelPredictionWork()
        visualContextCoordinator.cancel(resetState: true)
        interactionState.resetAll()
        clearSuggestion(clearDiagnostics: true)
        hideOverlay(reason: reason)
        state = .disabled(reason)
        latestStageMessage = "Disabled: \(reason)"
    }

    /// Clears the active suggestion and optionally preserves or drops diagnostic breadcrumbs.
    private func clearSuggestion(clearDiagnostics: Bool = false) {
        latestSuggestionPreview = nil
        latestFullSuggestionPreview = nil
        latestRemainingSuggestionPreview = nil
        latestAcceptedCharacterCount = nil
        latestRemainingCharacterCount = nil
        latestAcceptanceAction = nil
        latestLatencyMilliseconds = nil
        interactionState.clearSuggestion()

        if clearDiagnostics {
            latestPromptPreview = nil
            latestRawModelOutput = nil
            latestGenerationNumber = nil
        }
    }

    /// Cancels debounce/generation tasks and advances the work id so late completions are ignored.
    private func cancelPredictionWork() {
        workController.cancelAll()
    }

    // MARK: - Visual Context

    /// Once screenshot context becomes ready, regenerate only if the user is still in the same
    /// field and there is enough typed text for a real inline completion request.
    private func schedulePredictionForCurrentFocusIfPossible(matching elementIdentifier: String) {
        focusModel.refreshNow()
        let snapshot = focusModel.snapshot

        guard SuggestionAvailabilityEvaluator.shouldSchedulePredictionWhenVisualContextBecomesReady(
            focusSnapshot: snapshot,
            matching: elementIdentifier
        ) else {
            return
        }

        schedulePrediction()
    }

    // MARK: - Acceptance and Session Reconciliation

    /// Accepts the current suggestion only if the field, generation, and visible overlay still match.
    private func acceptCurrentSuggestion() -> Bool {
        let snapshot = focusModel.snapshot

        guard permissionManager.inputMonitoringGranted else {
            return passTabThrough(reason: "Input Monitoring permission is required before Tabby can accept Tab.")
        }

        guard case .supported = snapshot.capability, let rawContext = snapshot.context else {
            return passTabThrough(reason: snapshot.capability.summary)
        }

        guard case .ready = state else {
            return passTabThrough(reason: "Tab passed through because no valid suggestion was ready.")
        }

        let acceptancePreparation = interactionState.prepareAcceptance(
            from: rawContext,
            overlayState: overlayState
        )
        let liveContext: FocusedInputContext
        let sessionForAcceptance: ActiveSuggestionSession
        let acceptedChunk: String
        switch acceptancePreparation {
        case let .ready(preparedLiveContext, preparedSession, preparedAcceptedChunk):
            liveContext = preparedLiveContext
            sessionForAcceptance = preparedSession
            acceptedChunk = preparedAcceptedChunk

        case let .invalid(reason):
            return passTabThrough(reason: reason)
        }

        guard suggestionInserter.insert(acceptedChunk) else {
            let message = suggestionInserter.lastErrorMessage ?? "Suggestion insertion failed."
            cancelPredictionWork()
            clearSuggestion(clearDiagnostics: true)
            hideOverlay(reason: "Overlay hidden because suggestion insertion failed.")
            state = .idle
            logStage(
                "insert-failed",
                workID: currentWorkID,
                generation: liveContext.generation,
                message: message,
                normalizedOutput: acceptedChunk
            )
            return false
        }

        recordAcceptedWords(from: acceptedChunk)

        cancelPredictionWork()

        switch interactionState.commitAcceptedChunk(
            acceptedChunk,
            liveContext: liveContext,
            session: sessionForAcceptance
        ) {
        case .exhausted:
            latestGenerationNumber = liveContext.generation
            clearSuggestion(clearDiagnostics: false)
            hideOverlay(reason: "Overlay hidden because Tab accepted the final suggestion chunk.")
            latestAcceptanceAction = "Accepted final chunk with Tab."
            state = .idle
            logStage(
                "tab-accepted-final-chunk",
                workID: currentWorkID,
                generation: liveContext.generation,
                message: "Inserted the final suggestion chunk and queued a refresh.",
                normalizedOutput: acceptedChunk
            )
            schedulePrediction()
            return true

        case let .advanced(advancedSession, _):
            latestGenerationNumber = liveContext.generation
            applySessionDiagnostics(advancedSession, acceptanceAction: "Accepted next chunk with Tab.")
            state = .ready(text: advancedSession.remainingText, latency: advancedSession.latency)
            // Optimistic overlay: show the remaining suggestion text immediately at the last known
            // caret position instead of hiding and waiting for AX to report the new caret. The overlay
            // position will be slightly stale (by roughly the inserted chunk width) for one poll cycle,
            // then snap to the correct position when AX catches up. This eliminates the flash where
            // ghost text disappears and reappears between Tab presses.
            presentOverlay(text: advancedSession.remainingText, at: liveContext.caretRect)
            logStage(
                "tab-accepted-chunk",
                workID: currentWorkID,
                generation: liveContext.generation,
                message: "Inserted the next suggestion chunk and kept the remaining tail active.",
                normalizedOutput: acceptedChunk
            )
            return true
        }
    }

    /// Returns control of `Tab` to the host app and clears stale suggestion UI.
    private func passTabThrough(reason: String) -> Bool {
        let generation = latestGenerationNumber
        cancelPredictionWork()
        clearSuggestion(clearDiagnostics: true)
        hideOverlay(reason: reason)
        state = .idle
        logStage(
            "tab-passed-through",
            workID: currentWorkID,
            generation: generation,
            message: reason
        )
        return false
    }

    /// Advances the active session from the user's directly typed characters when they match the
    /// next expected tail exactly. This avoids a wasteful regeneration for text the user already
    /// committed to the field themselves.
    private func advanceActiveSessionIfTypedCharactersMatch(_ typedCharacters: String, session: ActiveSuggestionSession) -> Bool {
        guard let advancedSession = interactionState.advanceIfTypedCharactersMatch(
            typedCharacters,
            expectedSession: session
        ) else {
            return false
        }

        cancelPredictionWork()
        applySessionDiagnostics(advancedSession, acceptanceAction: "User typed the next expected characters.")

        if advancedSession.isExhausted {
            completeActiveSuggestion(
                reason: "Overlay hidden because the user typed through the rest of the suggestion.",
                scheduleNextPrediction: true,
                stage: "typed-match-exhausted",
                message: "The user typed the remaining suggestion characters exactly.",
                acceptanceAction: "User typed through the rest of the suggestion."
            )
            return true
        }

        state = .ready(text: advancedSession.remainingText, latency: advancedSession.latency)
        presentOverlay(text: advancedSession.remainingText, at: session.baseContext.caretRect)
        logStage(
            "typed-match-advanced",
            workID: currentWorkID,
            generation: latestGenerationNumber,
            message: "User typing matched the active suggestion tail exactly.",
            normalizedOutput: advancedSession.remainingText
        )
        return true
    }

    private func invalidateActiveSuggestion(
        reason: String,
        clearDiagnostics: Bool = true
    ) {
        cancelPredictionWork()
        clearSuggestion(clearDiagnostics: clearDiagnostics)
        hideOverlay(reason: reason)
        state = .idle
    }

    private func completeActiveSuggestion(
        reason: String,
        scheduleNextPrediction: Bool,
        stage: String,
        message: String,
        acceptanceAction: String
    ) {
        let generation = latestGenerationNumber
        clearSuggestion(clearDiagnostics: false)
        latestAcceptanceAction = acceptanceAction
        hideOverlay(reason: reason)
        state = .idle
        logStage(stage, workID: currentWorkID, generation: generation, message: message)

        if scheduleNextPrediction {
            schedulePrediction()
        }
    }

    private func applySessionDiagnostics(_ session: ActiveSuggestionSession, acceptanceAction: String?) {
        latestSuggestionPreview = session.remainingText
        latestFullSuggestionPreview = session.fullText
        latestRemainingSuggestionPreview = session.remainingText
        latestAcceptedCharacterCount = session.acceptedCount
        latestRemainingCharacterCount = session.remainingCount
        if let acceptanceAction {
            latestAcceptanceAction = acceptanceAction
        }
    }

    /// Updates the global productivity counter from text accepted via Tab.
    private func recordAcceptedWords(from acceptedChunk: String) {
        let acceptedWordCount = SuggestionSessionReconciler.acceptedWordCount(in: acceptedChunk)
        guard acceptedWordCount > 0 else {
            return
        }

        totalTabAcceptedWordCount += acceptedWordCount
        userDefaults.set(totalTabAcceptedWordCount, forKey: Self.totalTabAcceptedWordCountDefaultsKey)
    }

    // MARK: - Overlay and Logging

    private func presentOverlay(text: String, at caretRect: CGRect) {
        if let message = overlayPresenter.present(text: text, at: caretRect, previousState: overlayState) {
            latestOverlayMessage = message
        }
    }

    private func hideOverlay(reason: String) {
        latestOverlayMessage = overlayPresenter.hide(reason: reason)
    }

    private func logStage(
        _ stage: String,
        workID: UInt64,
        generation: UInt64? = nil,
        message: String,
        prompt: String? = nil,
        rawOutput: String? = nil,
        normalizedOutput: String? = nil
    ) {
        latestStageMessage = message
        logger.logStage(
            stage,
            workID: workID,
            generation: generation,
            message: message,
            prompt: prompt,
            rawOutput: rawOutput,
            normalizedOutput: normalizedOutput
        )
    }
}
