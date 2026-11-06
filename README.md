# AtışPress — core, steps 1–2

Swift 5.9 package; macOS 14+, no external dependencies. `ImpositionCore` imports
neither UI nor PDF frameworks. The other two targets contain comments only; the
app target is deliberately not executable until the UI step.

## Build and test

```sh
cd /Users/baturayatis/Developer/AtisPressCore
swift build
swift test
```

In an environment that prevents nested `sandbox-exec` (including the current
agent environment), use `swift build --disable-sandbox` and
`swift test --disable-sandbox`. Xcode can also open `Package.swift` directly.

## API

```swift
import ImpositionCore

let project = Project(
    pages: (1...106).map {
        SourcePage(number: $0, trimSize: Size(148, 210), availableBleed: 3)
    },
    binding: .perfectBound,
    sheet: SheetSpec(preset: .cm70x100, margins: Insets(left: 10, right: 10,
                                                       top: 10, bottom: 10)),
    settings: ImpositionSettings(signatureSize: .sixteen)
)
let plan = ImpositionPlanner.plan(project)
// plan.canExport gates future export; plan.issues contains Turkish messages.
// Both preview and PDFEngine must consume plan.sheets, without recalculating it.
```

`Project` owns the ordered selection, blank-page policy, binding, cover, stock and
settings. Source identifiers are one-based; duplicates and reordered selections
are allowed. `nil` in a slot means a generated blank. `ImpositionPlan` contains
sheets, front/back slots, geometry marks, signature size, blank count and issues.
`Slot.signature` is zero-based. An optional `SlotReference` identifies the
zero-based sheet/slot and face for diagnostics. Current job-wide issues omit it.
Errors disable export; warnings do not. Unsupported bindings and non-included
cover modes return explicit errors. Mixed trim sizes are rejected rather than
silently scaled. Bleed that is absent, unknown or insufficient produces a warning.

## Geometry and production contract

- Distances are millimetres, origin bottom left, +x right, +y up. No implicit scale.
  Margins and gripper edges refer to the selected press orientation; gripper width
  adds to the specified edge's margin.
- Slot `size` is the axis-aligned footprint on the press sheet. Optionally reflect original
  source trim horizontally in local coordinates, rotate clockwise by `rotation`,
  then translate the resulting bounding box to `origin`. Bleed,
  safe-area and fold marks are guides; a future exporter must choose which mark
  kinds are printable. Labels are anchors plus text, not font metrics.
- Saddle stitch uses nested bifolia, outer to inner, padded to a multiple of four.
  The required `[last, first] / [second, penultimate]` face convention is used.
- Perfect binding uses full rectangular folding sheets: 8 pages = 2×2 panels,
  16 = 4×2, 32 = 4×4. Repeatedly fold the left half over the right half, then the
  bottom half over the top half. Open/cut closed edges after folding for gathering.
  Page assignment comes from reversing physical paper stacks and tracking face
  swaps and text rotations. This is one explicit fold scheme, not a claim to
  support all bindery schemes. The test simulator reads both faces of the folded
  stack, checking sequential pages and upright text.
- Sheetwise back faces are viewed from behind after a left/right sheet turn;
  no glyph reflection is applied. Work-and-turn uses an x reflection, tumble a y
  reflection (represented by horizontal reflection plus 180°). These styles
  contain a complete front/back pair in opposite halves on the same plate;
  consequently each press sheet yields **two copies** of every assigned unit.
  Blank count is the logical publication padding, not multiplied by copies.
  The back face is the transformed same plate. Consumers must honor `mirrored`
  and the stated face-coordinate convention; they must not add a second flip.
- Packing exhaustively compares portrait/landscape stock and 0°/90° rotations
  of a uniform rectangular unit grid, maximizing units per sheet. Ties prefer
  unrotated units, then portrait. This is optimal within regular-grid packing;
  arbitrary mixed-rotation polygon nesting is outside this version's scope.
  Multiple distinct signatures or saddle bifolia can share a press sheet and
  must be cut, gathered and collated using their signature/order metadata.
- Automatic signatures compare 8/16/32: fewest press sheets, then least padding,
  then largest signature. Fixed signatures pad the last signature to full size.
  A 106-page job needs 2 blanks for saddle stitch, 6 for 8/16-page perfect binding,
  or 22 for 32-page perfect binding. Automatic depends on sheet fit and packing.
- Gutter is the explicit trim-to-trim gap, also at folds. Outer space reserves the
  larger of bleed and crop offset + length. Crop segments that would cross another
  trim rectangle are omitted. Bleed guides may overlap at shared folds; they do
  not authorize overlapping artwork. Future PDFEngine must clip placed content
  at the midpoint of shared gutters/folds. Safe area is a configurable inset.
- Creep and spine thickness are intentionally only protocols, marked TODO, with
  no unverified stock/adhesive formula or correction applied.

Physical folding semantics were checked against Heidelberg's
[Folding Scheme Editor](https://onlinehelp.prinect-lounge.com/Prinect_Signa_Station/Version2021/en/Prinect/Editors/Editors-10.htm),
which documents stack direction for X/Y folds. The selected fold sequence above
is explicit rather than inferred from a signature's page count alone.

## Files

```
Package.swift
Sources/
  ImpositionCore/
    Models.swift
    Planner.swift
  PDFEngine/Placeholder.swift
  AtisPressApp/Placeholder.swift
Tests/ImpositionCoreTests/PlannerTests.swift
```
