# Pixel-Perfect Caret Placement in macOS Accessibility

**How Tabby positions ghost text next to the cursor in every app — including the ones that fight back.**

---

## The Problem

Tabby is a macOS menu bar app that shows inline text completions as ghost text next to the user's cursor. To do this, it needs one thing: the exact screen coordinates of the text caret in whatever app the user is typing in.

macOS provides Accessibility APIs for this. In theory, you ask the system "where is the caret?" and it tells you. In practice, every app implements these APIs differently, some lie about coordinates, and the most popular email clients in the world don't implement the key API at all.

This document covers every failure mode we hit and how we solved each one.

---

## Background: How macOS Accessibility Coordinates Work

### The Coordinate Space Problem

macOS has two coordinate systems that matter:

1. **Cocoa (AppKit)**: Origin at **bottom-left** of the primary display. Y increases upward. This is what `NSWindow`, `NSScreen`, and overlay positioning use.

2. **Accessibility (AX)**: Origin at **top-left** of the primary display. Y increases downward. This is what `AXUIElementCopyAttributeValue` and `AXBoundsForRange` return.

Every AX rect must be Y-flipped before use:

```swift
// AX top-left origin → Cocoa bottom-left origin
let desktopBounds = NSScreen.screens.map(\.frame).reduce(.null) { $0.union($1) }
let cocoaY = desktopBounds.maxY - axRect.origin.y - axRect.height
```

This flip uses the union of all screen frames (not just the primary screen) so multi-monitor setups work correctly.

### The Three APIs That Return Caret Positions

| API | What it returns | Reliability |
|-----|----------------|-------------|
| `AXBoundsForRange` (parameterized) | Bounding rect for a text range | Best when it works. Fails entirely in Gmail/Outlook. |
| `AXSelectedTextMarkerRange` → `AXBoundsForTextMarkerRange` | Caret rect via WebKit/Chromium internal markers | Works in some Chromium apps (Discord, some Chrome pages). Absent in Gmail/Outlook compose. |
| `AXFrame` | Bounding rect of the entire UI element | Always works. Too coarse for caret placement on its own, but critical as a validation anchor. |

---

## Failure Mode 1: Chromium Returns Physical Pixels, Not Points

### The Bug

On a Retina display (2x scaling), Chromium-based apps (Chrome, Edge, Slack, Discord) return `AXBoundsForRange` values in **physical pixels** instead of **Cocoa points**. A caret at point (500, 300) comes back as (1000, 600).

Native macOS apps (TextEdit, Notes, Xcode) return points. There is no flag or attribute that tells you which coordinate space an app is using.

### Failed Approach: Bundle ID Lookup Table

Our first attempt was a hardcoded set of bundle identifiers known to need scaling:

```swift
// DON'T DO THIS — it's fragile, incomplete, and wrong for some code paths
static let requiresPixelToPointScalingBundles: Set<String> = [
    "com.google.Chrome",
    "com.microsoft.edgemac",
    "com.brave.Browser",
    "com.tinyspeck.slackmacgap",
    // ... dozens more
]
```

**Why it failed:**
- The list is never complete. New Electron apps ship constantly.
- Some apps (Outlook) weren't in the list, so their coordinates were wrong.
- The `AXTextMarkerRange` path also went through this scaling, but TextMarker results were already in points in some apps — so scaling them *halved* the coordinates and made placement worse.
- Maintaining a bundle ID list is a losing game.

### Working Approach: Anchor-Validated Conversion

**Key insight: `AXFrame` is always correct.** Every app needs its own element frames to be right for hit testing, focus rings, window management, etc. So `AXFrame` is universally reliable and always in Cocoa points.

We use the element's `AXFrame` (converted to Cocoa coordinates via simple Y-flip) as a ground-truth anchor. Then for any text-range rect:

1. **Try unscaled:** Y-flip the raw AX rect. Check if the result's center falls inside the anchor frame (with tolerance). If yes, the app returns points — use it.
2. **Try scaled:** Divide by the screen's `backingScaleFactor`, then Y-flip. Check again. If yes, the app returns pixels — use the scaled version.
3. **Fallback:** If neither fits, return the unscaled version as best-effort.

```swift
static func validatedCocoaTextRect(
    fromAccessibilityRect textRect: CGRect,
    anchorFrame cocoaAnchorFrame: CGRect?
) -> CGRect {
    let flipped = yFlip(textRect)

    guard let anchor = cocoaAnchorFrame, !anchor.isEmpty else {
        return flipped  // No anchor — plain Y-flip is safest
    }

    let tolerance: CGFloat = 80
    let expanded = anchor.insetBy(dx: -tolerance, dy: -tolerance)

    // Candidate A: already in points?
    if expanded.contains(CGPoint(x: flipped.midX, y: flipped.midY)) {
        return flipped
    }

    // Candidate B: physical pixels that need scaling?
    let scale = screenBackingScale(for: textRect)
    let scaledFlipped = yFlip(scaled(textRect, by: scale))

    if expanded.contains(CGPoint(x: scaledFlipped.midX, y: scaledFlipped.midY)) {
        return scaledFlipped
    }

    return flipped  // Neither fits — best effort
}
```

**Why 80pt tolerance?** Text fields have padding, the caret can be anywhere within the field vertically (multi-line), and scroll offsets can push content around. 80pt (~1cm on Retina) is generous enough to avoid false negatives while still distinguishing "in the right coordinate space" from "coordinates are 2x too large."

**Concrete example on a 1440×900pt Retina display:**
- Text field at Cocoa (100, 500), size 300×30
- Correct caret at Cocoa (150, 510)
- In AX points: (150, 370) → Y-flip → (150, 510) ✓ — inside anchor
- In AX pixels: (300, 740) → Y-flip → (300, 120) ✗ — way outside anchor
- Scaled: (150, 370) → Y-flip → (150, 510) ✓ — now inside anchor

The system self-corrects for every app without knowing its bundle ID.

---

## Failure Mode 2: BoundsForRange Fails Entirely

### The Bug

Gmail and Outlook compose areas (both Chromium-based) return **failure/empty** for every `AXBoundsForRange` call — zero-length ranges, single-character ranges, all of them. `AXTextMarkerRange` is also absent. The only caret resolution that works is `AXFrame`, which returns the entire compose area (568×360pt). That's useless for positioning ghost text.

### Discovery: AX Tree Dump

We added temporary debug logging directly into the focus polling loop (not a separate tool — that avoids the "no focused element" problem that happens when you switch apps):

```
AXTextArea
  frame: (1073, 631, 568×360)       ← entire compose area
  value: "hi my name is jacob and i hate the rain." (len=42)
  selection: loc=42 len=0
  BoundsForRange(loc,0): FAILED      ← completely broken

  [0] AXStaticText
    frame: (1073, 633, 183×15)       ← tight per-text-run frame!
    value: "hi my name is jacob and i hate " (32 chars)

  [1] AXStaticText
    frame: (1256, 633, 51×15)        ← tight per-text-run frame!
    value: " the rain." (10 chars)
```

**Key finding:** While BoundsForRange is broken, Chrome exposes **AXStaticText children** for each text run with **tight per-run AXFrames** (183×15, 51×15). These frames are precise because Chrome needs them for its own accessibility hit testing.

### Working Approach: Child Text-Run Proportional Estimation

Since we can't ask "where is character N?" (BoundsForRange), we instead ask "which text-run child contains character N, and where within that child's frame would it be?"

**Algorithm:**

1. Get the parent's selection location (e.g., 42) and its AXStaticText children
2. Walk children in order, accumulating text lengths:
   - Child 0: "hi my name is jacob and i hate " → 32 chars, cumulative 0–32
   - Child 1: " the rain." → 10 chars, cumulative 32–42
3. Parent selection (42) falls in child 1 at local offset 42 - 32 = 10
4. Proportion: 10/10 = 1.0 (end of child)
5. Caret X = child1.frame.minX + 1.0 × child1.frame.width = 1256 + 51 = 1307
6. Caret Y = child1.frame.minY, height = child1.frame.height

```swift
private func resolveCaretFromChildTextRuns(
    element: AXUIElement,
    parentSelection: NSRange,
    parentText: String
) -> CaretGeometryResult? {
    let children = AXHelper.childElements(of: element)
    guard !children.isEmpty else { return nil }

    // Collect AXStaticText children with text and frames
    var textRuns: [(text: String, frame: CGRect)] = []
    for child in children {
        let role = AXHelper.stringValue(for: kAXRoleAttribute as CFString, on: child)
        guard role == kAXStaticTextRole as String else { continue }
        guard let text = AXHelper.stringValue(for: kAXValueAttribute as CFString, on: child),
              !text.isEmpty,
              let frame = AXHelper.rectValue(for: "AXFrame" as CFString, on: child),
              !frame.isEmpty else { continue }
        textRuns.append((text, frame))
    }
    guard !textRuns.isEmpty else { return nil }

    // Match parent selection offset against cumulative child text lengths.
    // AX selections use UTF-16 offsets → use NSString.length, not String.count.
    let caretOffset = parentSelection.location
    var cumulative = 0
    for run in textRuns {
        let runLen = (run.text as NSString).length
        if caretOffset <= cumulative + runLen {
            let localOffset = caretOffset - cumulative
            let fraction = runLen > 0 ? CGFloat(localOffset) / CGFloat(runLen) : 1.0
            let cocoaFrame = AXHelper.cocoaRect(fromAccessibilityRect: run.frame)
            let caretX = cocoaFrame.minX + fraction * cocoaFrame.width
            return CaretGeometryResult(
                rect: CGRect(x: caretX, y: cocoaFrame.minY, width: 2, height: cocoaFrame.height),
                quality: .derived
            )
        }
        cumulative += runLen
    }

    // Caret past all children (e.g., trailing newline not in child text)
    let lastFrame = AXHelper.cocoaRect(fromAccessibilityRect: textRuns.last!.frame)
    return CaretGeometryResult(
        rect: CGRect(x: lastFrame.maxX, y: lastFrame.minY, width: 2, height: lastFrame.height),
        quality: .derived
    )
}
```

**Why proportional estimation instead of per-character BoundsForRange on the child?** Because BoundsForRange fails on the children too. Chrome fails it at every level of the AX tree. The proportional approach (`localOffset / textLength × frameWidth`) is approximate but good enough — text runs are typically short (one word to one line), so the error is at most a few pixels.

**Why this works for multiline:** Each line in a Gmail compose area gets its own AXStaticText children at different Y positions. The algorithm naturally finds the correct child on the correct line because it walks by text offset, not by spatial position.

---

## The Resolution Cascade

Tabby's caret resolution tries five approaches in priority order. Each app hits a different path:

| Branch | Method | Quality | Who hits it |
|--------|--------|---------|-------------|
| 1 | `BoundsForRange(selection, length: 0)` | exact | Native apps (TextEdit, Notes, Xcode, VS Code) |
| 1.5 | `AXTextMarkerRange` → `BoundsForTextMarkerRange` | exact | Some Chromium pages (Discord) |
| 2 | `BoundsForRange(selection - 1, length: 1)` → shift to trailing edge | derived | Native apps at position > 0 when branch 1 returns empty |
| **2.5** | **Child AXStaticText frame proportional estimation** | **derived** | **Gmail, Outlook, Chromium editors** |
| 3 | `AXFrame` fallback + character-count estimation | estimated | Last resort (element with no children, no BoundsForRange) |

Branch 2.5 is the key addition. Before it existed, Gmail/Outlook fell all the way to Branch 3, which used the entire compose area (568×360pt) as the caret anchor — the ghost text appeared at a random position in the field.

### Deep Geometry Search

Some Chromium apps focus a wrapper element (AXGroup) instead of the actual text area. The primary candidate may not even have text or a selection. To handle this, we run a BFS from the focused element looking for any descendant with precise caret data:

```
Focused: AXGroup (no text)
  └── AXGroup (no text)
      └── AXTextArea (has text + selection + AXStaticText children)
          ├── AXStaticText "hello "
          └── AXStaticText "world"
```

The BFS walks up to 10 levels deep and 200 nodes. When it finds a node with a zero-length selection, it runs the full resolution cascade on that node. If the result is `exact` or `derived`, it wins over the primary candidate's `estimated` result.

---

## Debugging Caret Placement

### Adding an AX Tree Dump

When caret placement breaks in a new app, the first step is always seeing the raw AX tree. We add logging directly into the focus polling loop — not a separate tool — because the polling loop already has the focused element:

```swift
// In FocusSnapshotResolver.resolveSnapshot():
if Self.dumpAXTree, Self.lastDumpedElementID != focusedElementIdentifier {
    Self.lastDumpedElementID = focusedElementIdentifier
    printAXTreeDump(focusedElement: focusedElement, ...)
}
```

**Why not a separate capture tool?** We tried building a standalone `AXTreeDumper` that captured after a 3-second delay. It failed because `AXUIElementCreateSystemWide()` + `kAXFocusedUIElementAttribute` returned nil — the menu bar interaction disrupted focus state. Dumping from inside the existing polling loop avoids this entirely because the element is already resolved.

The dump logs for each node:
- Role + subrole
- AXFrame (raw AX coordinates and Cocoa-converted)
- Text value (truncated)
- Selection range
- BoundsForRange probe result at the caret position
- TextMarkerCaret result if available
- Editable flag
- Child count

### What to Look For

| Symptom | Likely cause | Fix |
|---------|-------------|-----|
| Ghost text at top-left of field | BoundsForRange failing, falling to AXFrame | Check if children have usable frames (Branch 2.5) |
| Ghost text at 2x the correct position | App returns pixels, not points | Anchor validation should catch this — check if AXFrame is available |
| Ghost text on wrong line | Wrong child selected in text-run walk | Check cumulative text length math, look for newlines not in child text |
| No ghost text at all | Caret quality too low, filtered out | Check if `findDeepGeometrySource` is reaching the text node |
| Ghost text correct in Chrome but wrong in Gmail | Different AX tree structure | Dump both and compare — Gmail may have different nesting |

---

## Lessons Learned

### 1. Never Trust a Single API

`AXBoundsForRange` is the "right" API for caret placement. It works in 80% of apps. The other 20% — including the two most popular email clients — return garbage or nothing. You need a cascade of fallbacks, and each fallback needs to be validated against ground truth.

### 2. AXFrame is the One Rect That Never Lies

Every app gets its own element frames right because they need them for rendering. When you're lost in coordinate space ambiguity, `AXFrame` is your compass. Use it as a validation anchor, not as a caret position.

### 3. Bundle ID Heuristics Are Technical Debt

A lookup table of bundle IDs that need special treatment is a maintenance nightmare that's wrong the moment a new Electron app ships. Geometric validation (does this rect fall inside the element's frame?) is self-correcting and requires zero maintenance.

### 4. Children Know More Than Parents

When a parent element's text APIs are broken, its children often have precise per-run geometry. Chrome's AXStaticText children have 183×15pt frames — tight enough to position ghost text within a few pixels. The parent's 568×360pt AXFrame is useless for positioning but the children are goldmines.

### 5. Debug Where the Data Already Exists

Don't build elaborate capture tools with timers and file I/O. Log directly in the code path that already has the data you need. The focus polling loop runs every 100ms and already has the focused element, its attributes, and its children. Adding a `print()` there is simpler and more reliable than any external tool.

### 6. UTF-16 Offsets Matter

AX selection ranges are in UTF-16 code units, not Swift `Character` counts. For ASCII text this doesn't matter, but for emoji or CJK text, `String.count` and `NSString.length` diverge. Always use `(text as NSString).length` when comparing against AX selection offsets.

### 7. Proportional Estimation Beats No Estimation

When you can't get per-character positioning, proportional estimation within a known frame (`localOffset / textLength × frameWidth`) is good enough. Text runs are typically short (a few words), so even with variable-width fonts, the error is small — certainly better than using the entire text area's frame.

---

## Architecture Summary

```
FocusTracker (polling shell — timer + permission guards)
    │
    ▼
FocusSnapshotResolver (candidate search + snapshot assembly)
    │
    ├── candidateElements()     — focused element + ancestors + their children
    ├── candidateSnapshot()     — reads AX attributes, calls geometry resolver
    ├── findDeepGeometrySource() — BFS for precise caret data on descendants
    │
    ▼
AXTextGeometryResolver (caret + frame geometry)
    │
    ├── resolveCaretRect()
    │   ├── Branch 1:   BoundsForRange zero-length (exact)
    │   ├── Branch 1.5: TextMarkerRange (exact)
    │   ├── Branch 2:   BoundsForRange previous char (derived)
    │   ├── Branch 2.5: Child text-run proportional (derived)  ← the Gmail/Outlook fix
    │   └── Branch 3:   AXFrame fallback (estimated)
    │
    └── resolveInputFrameRect()  — element-level frame for activation indicator
    │
    ▼
AXHelper (raw AX API wrappers + coordinate conversion)
    │
    ├── cocoaRect()              — simple Y-flip for element frames
    ├── validatedCocoaTextRect() — anchor-validated conversion for text ranges
    └── childElements(), textMarkerCaretRect(), etc.
```

Each layer has a single responsibility:
- **FocusTracker** owns the timer. It doesn't know about AX attributes.
- **FocusSnapshotResolver** owns candidate search. It doesn't know about coordinate math.
- **AXTextGeometryResolver** owns caret heuristics. It doesn't know about suggestion state.
- **AXHelper** owns raw AX calls. It doesn't know about caret placement strategy.

When caret placement breaks in a new app, you debug in `AXTextGeometryResolver`. When the wrong element is selected, you debug in `FocusSnapshotResolver`. When coordinates are wrong, you debug in `AXHelper`. The separation makes compatibility bugs tractable.

---

## Regression Postmortem (April 2026): Stuck on `estimated primary-fallback`

### Symptom

In failing editors, the debug badge stayed on:

`estimated primary-fallback | AXTextArea`

even when the AX tree clearly contained deeper text-run nodes that should have produced `derived` geometry.

### Why This Regressed

This incident came from two independent assumptions failing at the same time:

1. **Neighborhood selection and deep-search root were mismatched**
    `FocusSnapshotResolver` selected candidates from a neighborhood (focused node, ancestors, and ancestor children), but deep geometry BFS was rooted only at the focused node.

    Result: the chosen editable candidate could be in a sibling branch that deep BFS could not reach.

2. **Branch 2.5 assumed text runs were immediate children**
    `resolveCaretFromChildTextRuns` initially scanned only one child level for `AXStaticText` runs.

    Result: editors with wrapper-heavy AX trees (`AXGroup` / container nodes) exposed real runs deeper in the tree, so Branch 2.5 never triggered and Branch 3 (`AXFrame` estimate) won.

### What Fixed It

1. **Deep search now starts from the resolved candidate first**
    - Added a routing helper that tries deep search from the resolved editable element.
    - Falls back to focused-element root only when needed.

2. **Candidate now stores concrete AX element identity**
    - `AXFocusCandidate` now carries the real `AXUIElement`, not just a string identifier.
    - This allows deep search to root at the exact resolved branch.

3. **Branch 2.5 now scans descendant text runs**
    - Added descendant traversal for `AXStaticText` runs with depth/node caps.
    - Preserves cumulative UTF-16 matching behavior while covering nested wrapper trees.

### Engineering Lessons

1. **Root-of-traversal bugs can mimic geometry bugs**
    If traversal starts from the wrong branch, perfect geometry logic still looks broken.

2. **AX trees are eventually consistent under polling**
    Focus, selection, and child structure can update on different ticks. Treat each poll as a snapshot with possible staleness, not a globally consistent transaction.

3. **Fallback quality labels are observability, not just UI**
    Seeing `estimated primary-fallback` repeatedly is a signal that traversal or branch eligibility failed, not necessarily that coordinate conversion failed.

4. **Depth assumptions are compatibility assumptions**
    "Immediate children" works in simple trees but silently fails in modern browser/editor accessibility trees.

### Challenges We Hit

1. **False confidence from partial fixes**
    Fixing deep-search root improved one topology but did not solve nested-run topologies.

2. **Tree-shape variance across host apps**
    Some apps put text runs under `AXTextArea` directly; others add multiple wrapper layers.

3. **Debugging under asynchronous UI updates**
    Timing differences between selection publication and child-tree publication can temporarily hide the path that exists a few milliseconds later.

### Recurrence Runbook

If this ever happens again, follow this order:

1. **Read the quality/source badge first**
    If you see `estimated primary-fallback`, treat it as branch-selection/traversal failure until proven otherwise.

2. **Dump focused + resolved branch topology**
    Confirm whether resolved candidate and focused node are on different branches of a shared ancestor.

3. **Verify deep-search root and reachability**
    Ensure deep traversal starts from resolved candidate before focused fallback.

4. **Count discovered text runs in Branch 2.5**
    If run count is zero in a field with visible text, traversal depth/source is still wrong.

5. **Validate selection-to-text invariants**
    Ensure `selection.location <= (parentText as NSString).length` and use UTF-16 everywhere for offsets.

6. **Only then tune heuristics/caps**
    Increase `maxDepth`/`maxNodes` only after proving root and traversal shape are correct.

### Suggested Guardrails

1. Keep a temporary debug counter for:
    - deep-search root used (`resolved` vs `focused`)
    - descendant text-run count
    - winning branch (`exact`, `derived`, `estimated`)

2. Keep a small manual smoke matrix for release checks:
    - native editor (TextEdit/Notes)
    - Chromium simple input
    - Chromium rich editor with wrapper-heavy tree

3. When refactoring candidate selection or deep traversal, treat them as a coupled system and review together.
