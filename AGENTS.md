# Cotabby Agent Instructions

## What It Is
macOS menu bar app: on-device inline autocomplete via AX focus tracking + global input monitoring → Apple Intelligence or llama.cpp → ghost text near caret → Tab accepts.
Privacy/local-first. No hosted API deps unless user asks.

## Core Loop
1. Track focused field via Accessibility
2. Monitor global keys (no focus steal)
3. Check field/permissions/settings eligibility
4. Build request from text + optional visual context
5. Generate via Apple Intelligence | llama.cpp
6. Normalize output → short continuation
7. Render ghost text near caret
8. Tab → insert chunk, keep remaining tail alive

## Repo Map
- `Cotabby/App/` — entrypoint, composition root, lifecycle, coordinators
- `Cotabby/UI/` — SwiftUI/AppKit: settings, onboarding, menu views, overlays
- `Cotabby/Services/` — side-effectful: AX, input monitoring, text insertion, screenshots/OCR, visual context, llama runtime, permissions, downloads, updates, launch services
- `Cotabby/Models/` — value types, settings snapshots, states, domain models, protocol contracts
- `Cotabby/Support/` — pure helpers, prompt rendering, availability rules, normalization, reconciliation, geometry, low-level bridging
- `CotabbyTests/` — unit + microbench tests; prefer testing `Support/` + `Models/`
- `LlamaRuntime/` — llama.swift / llama.cpp artifacts

## App Ownership (lifecycle entry)
1. `Cotabby/App/Core/CotabbyApp.swift`
2. `Cotabby/App/Core/AppDelegate.swift`
3. `Cotabby/App/Core/CotabbyAppEnvironment.swift`

`CotabbyAppEnvironment` builds long-lived dep graph once. `AppDelegate` starts/stops/wires subscriptions. SwiftUI views observe this graph — never create services directly. Rule prevents: duplicate AX observers, duplicate input monitors, runtime reload races, mismatched settings state.

## Suggestion Pipeline (read in order)
1. `SuggestionCoordinator.swift`
2. `SuggestionCoordinator+Lifecycle.swift`
3. `SuggestionCoordinator+Input.swift`
4. `SuggestionCoordinator+Prediction.swift`
5. `SuggestionCoordinator+Acceptance.swift`

Coordinator = orchestration + user-facing state only. Pure rules live elsewhere:
- `SuggestionRequestFactory` — request construction
- `SuggestionAvailabilityEvaluator` — gating decisions
- `SuggestionSessionReconciler` — acceptance + tail reconciliation
- `SuggestionTextNormalizer` — backend-agnostic output cleanup
- `SuggestionWorkController` — task identity/cancellation
- `SuggestionInteractionState` — active suggestion session storage

## Focus + Accessibility
- `FocusTracker` — observes focus/value/selection → publishes snapshots
- `FocusSnapshotResolver` — raw AX elements → Cotabby focus snapshots
- `AXTextGeometryResolver` — caret + input geometry
- `AXHelper` — low-level AX/CF helper calls
- `FocusModels` — pure focus values, identities, capabilities, debug data

AX data is eventually consistent + app-specific (browser/Electron/AppKit/secure fields differ). Preserve stale-result guards, `focusChangeSequence`, capability checks unless explicitly replacing them.

## Visual Context + OCR
- `VisualContextCoordinator` — field-scoped session lifecycle
- `ScreenshotContextGenerator` — screenshot → OCR → optional summary → bounded excerpt
- `WindowScreenshotService` — captures window/region
- `ScreenTextExtractor` — Vision OCR
- `LlamaVisualContextSummarizer` — optional local summary via selected llama runtime
- `VisualContextModels` — config, status, excerpt values

Don't put raw screenshots, unbounded OCR dumps, or noisy AX tree text into prompts. Normalize + bound + mark unavailable explicitly. Screen Recording permission is separate from AX + Input Monitoring.

## Runtime + Prompting
- `SuggestionEngineRouter` — selects Apple Intelligence vs Open Source
- `FoundationModelSuggestionEngine` — Apple on-device path
- `LlamaSuggestionEngine` — request→prompt, result handling, cache reset handoff
- `LlamaRuntimeManager` — UI-facing state, model selection, warmup, lifecycle
- `LlamaRuntimeCore` — serialized actor: llama.cpp pointers, tokenization, KV-cache reuse, sampling, shutdown
- `LlamaPromptRenderer` — prompt construction

Keep llama.cpp pointer work serialized inside `LlamaRuntimeCore`. Manager publishes state; core owns native correctness.

## UI + Overlays
- `OverlayController` — ghost-text panel lifecycle + positioning
- `SuggestionOverlayPresenter` — show/hide decisions
- `ActivationIndicatorController` — caret/field-edge indicator
- `FocusDebugOverlayController` — dev-only, gate behind debug options not user settings
- Settings panes (`Cotabby/UI/Settings/Panes/`) + onboarding = presentation only; push behavior into services/models/support

## Swift + Concurrency Rules
- `@MainActor`: UI, AppKit, SwiftUI state, most AX access, published models
- Actors/explicit serialization: mutable native/runtime state
- Never block main actor with OCR, screenshots, model loading, generation
- Make cancellation + stale-result checks explicit — user can type/switch apps/accept while work runs
- Use narrow protocols from `SuggestionSubsystemContracts.swift` when coordinator needs behavior not concrete service
- CF + AX bridging = unsafe boundary; comment ownership, casting, failure handling

## Change Order (reduces regression risk)
1. Pure rules → `Support/`
2. Domain models + contracts → `Models/`
3. Service boundary behavior → `Services/`
4. Coordinator orchestration → `App/`
5. Presentation → `UI/`

## Comments
- Explain why, not what — which invariant/pitfall/macOS quirk
- File-level + type-level `///` for new important files/types
- Inline for: lifecycle, `@MainActor`, `Task`, cancellation, AX/CF bridging, unsafe pointers, llama.cpp state
- Don't restate the next line
- Annotate unfamiliar Swift briefly on first use in concept-heavy areas (`@Published`, `@MainActor`, `AXUIElement`, `CFTypeRef`, `unsafeBitCast`, etc.)

## Working in This Repo
- Read relevant subsystem before editing — app is stateful, permission-heavy, AX-tied
- Diagnose before coding: bugs often = stale snapshots, AX timing, permission state, runtime lifecycle, cancellation
- Keep changes narrow; prefer `Support/` helpers before touching coordinators/services/UI
- Production app w/ real users — treat every change as shipping

## Contributing
- PRs against `main`; Greptile reviews automatically
- `Cotabby.xcodeproj` generated from `project.yml` by XcodeGen (committed). `project.yml` = source of truth. New files need no project edit (auto-discovered). Structural changes (targets, build settings, deps, scheme) → edit `project.yml` + run `xcodegen generate`
- SwiftLint before push: `swiftlint lint --quiet` (config: `.swiftlint.yml`, line 140/200, no trailing commas)
- Wiki: https://github.com/FuJacob/Cotabby/wiki

## GitHub Automation
- No `Co-Authored-By` trailers in commits
- PRs: use `.github/PULL_REQUEST_TEMPLATE.md` — fill Summary, Validation, Linked issues, Risk/rollout
- Issues: use `.github/ISSUE_TEMPLATE/bug_report.md` or `feature_request.md` — fill every field

## Debugging + Logs
Launch with `-cotabby-debug` to enable JSONL sinks (always-on: Console.app stream).

Log files (only with `-cotabby-debug`):
- `~/Library/Logs/Cotabby/cotabby.jsonl` — main event stream, one JSON/line, all metadata flattened for `jq`
- `~/Library/Logs/Cotabby/llm-io.jsonl` — full LLM prompts + completions, one record/generation; shares `request_id` with main log
- `~/Desktop/cotabby-ax-dump.txt` — latest Chrome AX tree snapshot (overwritten per Chrome focus change, debounced)
- `*.jsonl.1` — rotated log (>10 MB)

Correlation: every prediction gets `request_id` (e.g. `req_a3f9k2lq`) on every log line.
```bash
jq 'select(.request_id == "req_a3f9k2lq")' ~/Library/Logs/Cotabby/cotabby.jsonl
jq 'select(.request_id == "req_a3f9k2lq")' ~/Library/Logs/Cotabby/llm-io.jsonl
```

Useful jq recipes:
```bash
jq 'select(.level == "error")' ~/Library/Logs/Cotabby/cotabby.jsonl
jq 'select(.engine == "llama" and .latency_ms > 500)' ~/Library/Logs/Cotabby/llm-io.jsonl
jq 'select(.category == "suggestion" and .stage != null)' ~/Library/Logs/Cotabby/cotabby.jsonl
jq 'select(.category == "runtime")' ~/Library/Logs/Cotabby/cotabby.jsonl
```

Symptom → category:
- Ghost text missing → `suggestion` + `focus`
- Wrong text inserted → `llm-io.jsonl` request lookup → `suggestion` acceptance
- Model won't load/decode → `runtime` + `models`
- Permission dialog loop → `app`
- Chrome weirdness → `~/Desktop/cotabby-ax-dump.txt` → `focus`
- Wrong backend → `suggestion` router log (`engine`, `fallback_engine`)

Console.app fallback (no `-cotabby-debug`):
```bash
log show --predicate 'subsystem == "com.cotabby.app"' --last 10m
log stream --predicate 'subsystem == "com.cotabby.app"' --level debug
```

On bug report: jq logs first using symptom→category map. Don't ask user to re-explain before checking logs. If no JSONL files → use `log show` fallback; only ask for relaunch w/ flag if OSLog stream insufficient.

## Validation
```bash
xcodebuild -project Cotabby.xcodeproj -scheme Cotabby -destination 'platform=macOS' build \
  -derivedDataPath build/DerivedData
xcodebuild -project Cotabby.xcodeproj -scheme Cotabby -destination 'platform=macOS' build-for-testing \
  -derivedDataPath build/DerivedData
```
Always use `-derivedDataPath build/DerivedData` (gitignored) — avoids multi-GB cache under `~/Library/Developer/Xcode/DerivedData/Cotabby-*`. When done: `rm -rf build/DerivedData`.

Run targeted tests for changed pure logic. If `xcodebuild test` fails (signing/Team ID), report exact failure + still provide build/build-for-testing result.

## Git Safety
- Inspect `git status -sb` + relevant files before editing
- Never revert unrelated changes; keep commits scoped
- No `git reset --hard` or `git checkout --` unless user explicitly asks
