# AtışPress — live preview and vector PDF export

Swift 5.9 package; macOS 14+, no external dependencies. `ImpositionCore` imports
neither UI nor PDF frameworks. `PDFEngine` reads PDF metadata, draws bleed-aware
preview artwork and writes vector-preserving imposed PDFs. `AtisPressApp` is a
native SwiftUI executable. Preview and export consume the same `ImpositionPlan`.

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
// plan.canExport gates export; plan.issues contains Turkish messages.
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
  safe-area and fold marks are plan geometry selected by `PDFRenderOptions`.
  Labels are anchors plus text, not font metrics. `Slot.artworkClip` is the planned
  sheet-space extent including bleed and shared-cut clipping.
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
  trim rectangle are omitted. The plan clips artwork and bleed guides at the
  midpoint of shared gutters/folds, so neighboring artwork cannot overlap.
  Safe area is a configurable inset.
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
    StepAndRepeat.swift
  PDFEngine/
    PDFSource.swift
    PDFArtwork.swift
    PDFPlanRenderer.swift
    PDFExporter.swift
    PDFEdgeSamples.swift
    PDFColorProbe.swift
    GeneratedBleedOverlay.swift
  AtisPressApp/
    AtisPressApp.swift
    Workspace.swift
    WorkspaceView.swift
    InspectorView.swift
    PreviewCanvas.swift
Tests/ImpositionCoreTests/PlannerTests.swift
Tests/ImpositionCoreTests/StepAndRepeatTests.swift
Tests/ImpositionCoreTests/ArtworkClipTests.swift
Tests/ImpositionCoreTests/GeneratedBleedPlanTests.swift
Tests/PDFEngineTests/PDFSourceTests.swift
Tests/PDFEngineTests/PDFExportTests.swift
Tests/PDFEngineTests/GeneratedBleedTests.swift
Tests/AtisPressAppTests/WorkspaceTests.swift
```

## Run the live preview

```sh
cd /Users/baturayatis/Developer/AtisPressCore
swift run AtisPressApp
# Optional file argument (quote paths containing spaces):
swift run AtisPressApp "/path/to/book.pdf"
```

For Xcode, open `Package.swift`, choose the **AtisPressApp** scheme and **My Mac**,
then Run (⌘R). No generated Xcode project or signing team is needed for local use.
The app sets `NSApplication` activation policy to `.regular` and activates on launch.
In this agent's restricted shell, use `--disable-sandbox` for SwiftPM; the shell also
blocks LaunchServices connections, so interactive GUI checks used an ad hoc local
bundle containing the exact same executable, launched through the desktop tools.
On a normal Mac terminal, use the `swift run` command above.

Open with **PDF Aç… / ⌘O**, the toolbar, or drop a PDF anywhere in the workspace.
A new PDF replaces the previous source. Checkboxes control inclusion; select rows
with ⌘/⇧ and move with ↑/↓ toolbar buttons or native List drag reordering. Source
numbers retain their original PDF identity after a move. Select a sheet in the
lower sidebar to jump to it; **Ön / Arka** selects its face. Pinch to zoom, scroll
with the trackpad/wheel, drag the canvas to pan, or use **− / Sığdır / +**.

| Control | Visible effect |
| --- | --- |
| Ciltleme | Nested saddle leaves versus folded perfect-bound signatures; page ordering, blank count and sheet count change. |
| Forma (perfect binding only) | 8/16/32 or automatic folding scheme and padding. Hidden for saddle stitch, where it would have no effect. |
| Çevirme | Separate front/back versus paired same-plate halves; mirrored/rotated slots and copy count convention. |
| Boyut / Özel / Yön | Press sheet boundary, packing capacity, orientation or a no-fit validation error. Units are mm; preset names 33×48 etc. are cm. |
| Sol / Sağ / Üst / Alt | Orange margin guides plus the plan's usable area/placement. Even an unchanged packing count has visibly different guides. |
| Maşa kenarı / Maşa payı | Orange labeled gripper boundary and reserved edge. |
| Ara boşluk | Panel separation and fold lines, sometimes packing capacity. |
| Taşma | Red bleed guides and per-slot insufficient/unknown bleed warnings. |
| Kesim uzunluğu / uzaklığı | Crop geometry and reserved outer space. Offset is hidden when mark length is zero. |
| Güvenli alan | Green inset guides. |
| Katmanlar | Show/hide only the corresponding plan marks or the sheet border; never alter layout. |

Changing mark geometry automatically enables its overlay so the change is visible.
Page labels stay readable at low zoom; purple badges identify rotation/mirroring,
and gray crossed slots identify blanks. Validation issues with slot references
outline those slots in red; clicking a referenced issue jumps to its sheet/face.
Margins/gripper have their own visibility toggle. Errors with no viable layout show an empty
preview and a validation explanation rather than retaining an unrelated old plan.

### Responsiveness and rendering

`Workspace` snapshots `Project`, debounces changes by 140 ms, calculates via
`ImpositionPlanner` in a detached task, and publishes only the latest revision on
the main actor. No imposition math exists in the app or PDF reader. Overlay/zoom
changes redraw immediately and do not need a new imposition calculation.

PDF box scanning runs off the main thread. Actual TrimBox (with CropBox/MediaBox
fallback), MediaBox intersection and inherited `/Rotate` determine displayed trim
size. Available bleed is the minimum of the four BleedBox-to-TrimBox distances,
clipped to MediaBox; an absent explicit BleedBox stays unknown rather than being
invented from MediaBox. Missing bleed warnings are supplied by the core plan,
including slot references. Dimensions enter the core in mm.

PDFKit thumbnails are requested by visible List rows; offscreen rows release their
image state and cancelled queued requests are skipped. A 64 MiB `NSCache` holds
128-pixel thumbnails and adaptive 128/256/512-pixel low-zoom preview rasters. Only the visible slots
are drawn. At magnification ≥0.85, a separate main-thread `CGPDFDocument` draws
real PDF vectors with `CGPDFPage.getDrawingTransform`; PDF objects are never shared
concurrently between the vector view and the serial PDFKit raster queue.

The transform helper follows Apple's
[PDF drawing and transformation documentation](https://developer.apple.com/library/archive/documentation/GraphicsImaging/Conceptual/drawingwithquartz2d/dq_pdf/dq_pdf.html).
Native pinch zoom uses [NSScrollView magnification](https://developer.apple.com/documentation/appkit/nsscrollview/allowsmagnification).

### Verification and current limits

`swift test --disable-sandbox`: **54 XCTest tests, zero failures** (26 core,
21 PDF reading/drawing/export, 7 workspace/drop/export/initial-fit regression tests). GUI smoke checks
used vector fixtures with 12 and 1,004 pages: import, scrolling thumbnails, sheet
navigation, page selection/reordering/exclusion, binding change, front/back,
shared-plate mirroring, bleed warnings/red slot highlighting, zoom and fit.

- Single imported PDF per workspace; replacement rather than multi-document merging.
- Locked PDFs require unlocking externally. Booklets require uniform trim sizes; flat jobs require matching sizes within each front/back pair.
- PDF annotations/forms are omitted consistently from thumbnails and vector preview.
- Artwork uses BleedBox (MediaBox/TrimBox fallback), anchored at TrimBox and clipped to plan bleed bounds.
- No PDF/X, separation, overprint or color-managed press-proof simulation.
- Native file-dialog chrome and standard system commands follow the macOS language.
- Existing core limits remain: regular-grid packing, one explicit fold sequence per
  signature size, included covers only, no creep/spine correction, unsupported bindings.
- Standard PDF export is implemented; printing, persistence and installer distribution are not.

## Step & repeat — Tekrarlı yerleşim

Run with the same commands above (`swift run AtisPressApp`, or open `Package.swift`
and run the AtisPressApp scheme on My Mac). Select **Tekrarlı (kartvizit/düz iş)**
in **Yerleşim Yöntemi**. The existing booklet mode and its original tests remain.

- Consecutive **selected-order** page pairs are independent jobs: 1/2, 3/4, etc.
  Each job gets its own sheet layout in **Tekrarlı İşler**. Different jobs may have
  different trim sizes; a job's front/back must match. An odd final page has an
  unprinted reverse. Source pages are never padded; `addedBlankPages` stays zero,
  even with the reject-padding policy.
- **90° döndürmeye izin ver** allows a uniform item rotation if it increases
  capacity. Stock portrait/landscape and item 0°/90° candidates are compared.
  Equal capacities prefer unrotated items, then portrait stock. Packing is optimal
  among those regular-grid candidates; mixed-rotation nesting is not implemented.
- **Sütun / Satır sayısını belirle** overrides either dimension independently;
  the other remains automatic. Overrides that do not fit produce validation errors.
- **Adet hesapla** applies the requested finished quantity to **every job**. Each
  press sheet is fully populated, including the final sheet. Sheet count is
  `quantity / copiesPerSheet`, rounded up; produced quantity can exceed the request.
  Nil quantity means one full press sheet per job. The inspector and preview HUD
  show the grid, copies per sheet, required sheets and all-job total. The inspector
  also shows produced quantity.
- The UI remembers the booklet gutter separately and starts flat jobs with **0 mm**.
  Switching back restores the booklet gutter. The core always reads `SheetSpec.gutter`.

### Grid, bleed and crop geometry

For a positive gutter `g`, spacing between trim rectangles is `2 × bleed + g`:
neighboring bleed boxes have the requested clear gap. Outer reserved space is the
larger of bleed and crop offset + crop length (crop reservation is zero if crop
length is zero). Margins and gripper reservation reduce usable stock first.
For each axis, automatic count is `floor((usable + spacing)/(trim + spacing))`.
The rotated candidate swaps trim width/height.

**Zero gutter explicitly means shared trim cuts:** pitch equals trim size,
outer bleed is still reserved, and internal bleed guides stop at the common cut.
A warning explains that internal bleed is clipped and neighboring edge designs
must be checked. This provides common cuts without silently overlapping artwork.
Choose a positive gutter for independent bleed on every item edge.

Crop ticks identify every row/column trim coordinate around the grid. Positive
spacing also receives individual corner ticks where they fit, clipped before the
next item's trim. Shared-cut ticks are deduplicated; marks never cross neighboring
trim artwork. Bleed, safe-area and page-label marks are generated by the core.
There are no folds in flat work, so its fold overlay toggle is hidden.
The existing canvas renders these plan marks without additional layout logic.

### Back registration and same-plate work styles

Grid positions are zero-based with rows counted from the bottom **as viewed from
each face**. `Slot.copyIndex` identifies the same physical cut piece on both faces.
For a bottom/top gripper:

| Work style | Back index for front `(column, row)` | Plate content |
| --- | --- | --- |
| Sheetwise | `(columns - 1 - column, row)` | Separate front/back plates |
| Work-and-turn | `(columns - 1 - column, row)` | Front on left half, back on right; even columns |
| Work-and-tumble | `(column, rows - 1 - row)` | Front on bottom half, back on top; even rows |

For a left/right gripper the turn axis is exchanged (turn keeps the gripper;
tumble switches it). The corresponding grid axis must be even in same-plate styles.
The grid is centered along its reflection axis, and both passes' margin/gripper
clearances are reserved. Tumble also displays the opposite gripper guide.

These are **position reflections**, not reversed printed lettering: flat-work
slots have `mirrored == false`. An x reflection reverses item rotation `θ` to
`-θ`; a y reflection changes it to `180° - θ`. For same-plate styles, the plan
contains front/back pages in opposite halves on each face; their geometry/content
by grid position is identical on both plate views. Their arrays remain in
physical-copy order, so mapped indices identify the corresponding reverse page.
After both passes, finished copies per physical sheet equal the full grid count,
including pieces from both halves. Both faces of a one-page job consist of
complementary printed/blank halves in same-plate styles; every finished piece
still has one printed face and one unprinted face.

Same-plate halves and gripper handling follow Kodak's
[work-style documentation](https://workflowhelp.kodak.com/spaces/flyingpdf/pdfpageexport.action?pageId=263717741).
The explicit index/rotation convention above is implemented and tested in the core.

### API additions and limits

```swift
project.binding = .stepAndRepeat
project.sheet.gutter = 0
project.stepAndRepeat = StepAndRepeatSettings(
    columns: nil, rows: nil, allowRotation: true, quantity: 1000
)
let plan = ImpositionPlanner.plan(project)
for sheet in plan.sheets {
    if let layout = sheet.repeatLayout {
        // layout.columns, layout.rows, layout.copiesPerSheet, layout.jobIndex,
        // layout.frontPageNumber, layout.backPageNumber, layout.requestedQuantity
        print(layout.copiesPerSheet, sheet.repeatCount)
    }
}
print(plan.totalPressSheets)
```

Geometry is stored once per job, with `Sheet.repeatCount` recording identical
physical sheets; large quantities do not allocate duplicate slots. The existing
booklet sheets default to `repeatCount == 1` and `repeatLayout == nil`.

Manual dimensions are limited to 1–200 per axis, quantity to 1–1,000,000,000 per
job, and rendered capacity to 20,000 items per sheet. Larger values report errors.
There is no gang mixing of different jobs on one sheet, per-job quantity override,
partial final sheet, registration calibration, mixed-rotation packing or printing.
Existing omitted-annotation and color-proofing limitations still apply.

Ten new pure-core tests cover pairing/no padding, exact row/column back mapping,
all gripper edges, readable rotation, same-plate identity, grid optimization,
bleed/gutter/margins, manual overrides, quantities and crop geometry. A workspace
regression verifies debounced grid/quantity changes and restoring booklet settings.
GUI checks used a three-page 85×55 mm card fixture, including two jobs, an unprinted
reverse, manual grid changes, sheet counts and same-plate halves.

## Step 4 — PDF export

Run `swift run AtisPressApp` from the package folder, or open `Package.swift` in
Xcode, choose **AtisPressApp / My Mac**, and Run. Import the source and select
**PDF Dışa Aktar** in the toolbar or **Dosya → PDF Dışa Aktar…** (⇧⌘E).

- **Bütün iş — tek PDF:** a Save panel selects the output file. Pages are ordered
  sheet 1 front, sheet 1 back, sheet 2 front, sheet 2 back, including every physical
  `repeatCount` in flat work. Blank reverse faces are retained.
- **Her tabaka — ayrı PDF:** choose a parent folder. A new unique AtisPress folder
  receives one two-page PDF per physical sheet, with front then back. Files are
  numbered continuously across jobs and repetitions.
- Export requires a source, a nonempty plan and `plan.canExport == true`. It is also
  disabled during import, recalculation and another export. Warnings still permit
  export. The engine independently enforces the same error gate.
- The current plan, source and overlay options are frozen when the destination is
  accepted. Export runs off the main actor while preview/settings remain usable.
  **İptal** cancels rendering between slots/pages. Completion reports files/pages
  and offers **Finder’da Göster**. The completion banner describes the last output.
- Open overlay layers are printed: crop, fold, bleed, safe area, page numbers,
  sheet boundary and margin/gripper guides. Turn off proof guides or numbers before
  exporting if they are not wanted on the print sheet. Gray blank crosses, rotation
  badges, trim-selection outlines and validation highlights remain editor decorations.

### Bleed-aware drawing

Artwork selection is explicit BleedBox first, then MediaBox, then TrimBox. BleedBox
is intersected with a valid MediaBox. Quartz's **TrimBox** transform still anchors
and scales the trim to the plan slot; fitting the whole bleed box into that slot
would incorrectly shrink/move the trim. Nonzero box origins, `/Rotate`, plan rotation
and local mirroring are all honored. No source-TrimBox clipping remains in the draw
path. Both raster and vector preview retain artwork outside the trim.

The core now records a sheet-space `artworkClip` per slot. Booklets clip at the
midpoint of internal gutters/folds; flat jobs use the already planned bleed bounds,
including common-cut clipping. Export and preview apply that rectangle directly;
the PDF layer performs no fitting, pairing, grid optimization or pagination.

The low-zoom cache stores a bleed-aware Quartz raster of each PDFKit page reference,
plus its extent normalized to the displayed trim. High zoom and export draw the
original `CGPDFPage` through the same `PDFPreviewDrawing` transform. The raster cache
is never consulted during export. Output MediaBox is each plan sheet's exact mm
size converted to PDF points (`72/25.4`), with no content scaling to another stock.

`PDFPlanRenderer` handles artwork and CoreText/vector marks for both consumers.
On-screen minimum text/stroke sizes keep guides legible at low zoom; exported
marks use physical mm sizes and the same plan anchors. Export writes drawing
operators through a Quartz PDF context. Vector paths/text remain vector, and
existing bitmap assets inside source PDFs remain images; no page-sized raster
flattening or bitmap-to-vector conversion is performed.

### PDFEngine API and extensibility

```swift
let result = try PDFExporter.export(
    plan: plan,
    source: source, // PDFSource opened by the reader
    destination: .singlePDF(outputURL),
    options: PDFRenderOptions.artworkOnly
)
// Alternative: .perSheet(directory: folderURL, baseName: "book")
// result.files, result.pageCount, result.sheetCount
```

Call the synchronous engine API on a worker task. `PDFRenderOptions` is also the
app's preview overlay state. The source file is protected from overwrite; whole-job
replacement is staged and atomically published. Per-sheet destinations reject
existing filenames. Rendering/overlay failures and cancellation remove staged
files instead of publishing partial PDFs. The app creates a unique per-sheet
folder, so a normal export does not collide with earlier outputs.

For later variable text or serial numbers, implement
`PDFSlotOverlay` and supply an array to `PDFExporter.export(overlays:)` or the shared
renderer's preview draw call. Hooks run **underArtwork** or **overArtwork**, in
slot-local trim mm with isolated graphics state and the plan's bleed clip. The
context provides trim/artwork rectangles, source page, slot/copy identity,
sheet/face/slot reference and physical repetition index. This requires no new
fields in `ImpositionPlan` or a separate layout path. Tests demonstrate vector
serial text with those hooks; generated bleed uses the same hooks in production.
There is no variable-data UI yet.

### Export validation and remaining limits

The new tests reopen exported PDFs to verify page order/count, exact MediaBox sizes,
slot centers/corners, rotated/mirrored source content, BleedBox/MediaBox fallback,
nonzero TrimBox origins, inherited source rotation, overlay switches, repeated
physical sheets and per-sheet files. Vector-resource inspection confirms pure
vector fixtures contain no image XObjects after export, while source image assets
are retained. Additional checks cover overwrite protection, failed-export cleanup,
PDF replacement, extension hooks and UI export gating during recalculation.
Rendered PDFs were inspected using Apple Quartz, including both GUI save flows.
The existing booklet/fold/grid tests remain unchanged and pass.

- Up to **20,000 PDF pages (10,000 physical sheets)** per export operation. Larger
  quantity runs are rejected explicitly; their plan remains available for preview.
- Standard PDF output only: no PDF/X certification, output intents, separation or
  overprint preflight, CMYK/spot-color conversion, trapping or press color proof.
- Source annotations, forms, links, bookmarks and document structure are not copied;
  the rendered PDF page content is imposed. Unlock encrypted input externally.
- A press sheet contains multiple finished trims, so only the sheet MediaBox is
  emitted as page metadata; individual trim/bleed extents remain plan geometry.
- Existing core packing, binding, cover and creep/spine limits are unchanged.

## Generated bleed

Open a PDF, choose a layout and enable **Üretilmiş Taşma → Taşma üret** in the
inspector. Existing projects keep generated bleed off by default; the default
method when enabled is **Otomatik (zemin rengi)**. All generation settings are
snapshotted in `ImpositionPlan` and use one overlay implementation for preview and
export. Source artwork within TrimBox is unchanged.

- **Otomatik (zemin rengi)** samples a 0.5 mm strip just inside each trim edge at
  600 dpi. A channel range within the selected tolerance (default 2%) produces a
  vector solid fill. A varied strip stretches the nearest edge pixel line outward,
  preserving its changes along the edge; it never substitutes an average color.
  Corners use the nearest corner color.
- **Yansıt** reflects vector source artwork outside the trim; corners use sampled
  corner colors. **Renk** supplies a vector CMYK or RGB fill with editable channels.
- With zero gutter, the grid is one block: only its outer perimeter gets generated
  bleed. Interior boundaries are shared cut lines, controlled by the crop-mark
  toggle. The plan checks that outer bleed fits the sheet. With positive gutter,
  each item receives four-sided bleed within its own artwork clip. A warning is
  shown when gutter is less than twice the bleed. The existing gutter convention
  remains a clear gap between bleed boxes (`trim spacing = 2 × bleed + gutter`).

Samples are prepared off the main thread and cached per source page in a bounded
64 MiB cache. Only edge pixel lines, channel ranges and corner colors are retained;
changing tolerance reuses the samples. Export waits for preview sampling, and the
engine can also populate its cache when used independently.

DeviceCMYK sources that the conservative content scanner can identify are sampled
and filled in DeviceCMYK. Mixed RGB/CMYK, ICC/spot/pattern colors, shading,
transparency and color-space overrides fall back to sRGB; the inspector reports
RGB sampling. This is not full color preflight or ICC preservation. Varied automatic
edges are small raster strips; original PDF artwork and solid fills remain vector.
Mirror tiling has safety limits for extreme bleed-to-trim ratios.

Tests cover a 3×2 touching grid, independent spaced items, uniform/varied/depth
sampling, caching, clipping, rotated/mirrored slots, native CMYK and matching
preview/export rendering. Run `swift test` on your Mac; if the host blocks nested
SwiftPM sandboxing, use `swift test --disable-sandbox`.
