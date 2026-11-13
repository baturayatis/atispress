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

## Build a double-clickable macOS app

Requires macOS 14+ and Xcode command-line tools (`xcode-select --install` if
needed). From the repository:

```sh
cd /Users/baturayatis/Developer/AtisPressCore
./scripts/build_app.sh
open "dist/AtışPress.app"
```

The script performs a release build without debug symbols, generates a multi-resolution navy imposition
icon, creates **dist/AtışPress.app**, then runs
`codesign --force --deep --sign -` and verifies the signature. Generated bundles
are ignored by Git. The bundle identifier is **com.atisajans.atispress**, minimum
macOS is **14.0**, and Retina rendering is enabled. Edit
**packaging/Info.plist** to change the marketing version (currently **0.1.0**) or
build number (**1**); these are independent of the `.atispress` JSON schema version.

To install, drag **AtışPress.app** from `dist` into **Applications** in Finder.
Alternatively, copy it with these exact commands, then launch the installed copy:

```sh
ditto "dist/AtışPress.app" "/Applications/AtışPress.app"
open "/Applications/AtışPress.app"
```

The bundle declares `.atispress` as an editable **AtışPress Projesi** document
using the existing exported UTI **com.atispress.project**, conforming to JSON.
The build script registers the bundle with LaunchServices when available;
installing and launching it also lets Finder discover the document type.
Double-click a saved `.atispress` project to open it. If another app was previously
chosen, use Finder **Get Info → Open with → AtışPress → Change All**. To open a
specific project explicitly:

```sh
open -a "/Applications/AtışPress.app" "/absolute/path/example.atispress"
```

The existing URL-open handler restores the saved project, including the Turkish
source-PDF relink dialog if needed. Source PDFs remain linked, not embedded.

**App icon:** replace **packaging/AppIcon.icns** with your final icon and
rerun the script. If that file is absent, **scripts/generate_app_icon.swift** draws
the navy/white/teal glyph into all standard 16–1024-pixel icon representations using AppKit
and writes a PNG-backed ICNS container directly to
**Contents/Resources/AppIcon.icns**. It needs no external image tools or services.
Editing an already signed bundle invalidates its signature, so rebuild after
replacing the icon or changing metadata.

**Gatekeeper:** this local bundle is ad-hoc signed, without Developer ID or Apple
notarization. On macOS 14, if a trusted copy is blocked, right-click (or
Control-click) **AtışPress.app → Open**, then confirm **Open**. On newer macOS
versions where that shortcut does not offer an override, attempt to launch once,
then use **System Settings → Privacy & Security → Open Anyway** and confirm.
See [Apple's current Gatekeeper instructions](https://support.apple.com/en-gb/102445).
The script does not change Gatekeeper settings or remove quarantine attributes.

The default release targets the build Mac's architecture. For a universal binary,
with the full Xcode toolchain installed, pass SwiftPM architecture flags:

```sh
./scripts/build_app.sh --arch arm64 --arch x86_64
```

Packaging does not provide an installer, updater or notarized distribution.
Verification: all 114 existing tests pass unchanged; release packaging, strict
ad-hoc signature validation, bundle metadata/UTI consistency, all ten icon sizes,
and a native bundle launch were checked. This restricted shell cannot register
with LaunchServices, so Finder project double-click dispatch was not exercised;
use the installed app on the desktop to verify that integration.

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
Errors disable export; warnings do not. Unsupported bindings return explicit errors. Legacy projects without `BookSettings`
retain the included-cover path; the measured book workflow below enables independent covers. Mixed trim sizes are rejected rather than
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
- Gutter is the explicit trim-to-trim gap for flat/gang jobs. Booklet fold
  neighbors are always contiguous (0 mm); saved flat gutters cannot open folds.
  Outer space reserves the
  larger of bleed and crop offset + length. Crop segments that would cross another
  trim rectangle are omitted. The plan clips artwork and bleed guides at the
  midpoint of shared gutters/folds, so neighboring artwork cannot overlap.
  Safe area is a configurable inset.
- Measured book settings implement the existing creep/spine protocols using only
  explicit paper inputs. Legacy files retain zero correction until book settings
  are enabled. See **Kitap modu** below for formulas and approximation limits.

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
    SerialNumbering.swift
    SmartAutoLayout.swift
    FitDiagnostics.swift
  PDFEngine/
    PDFSource.swift
    PDFArtwork.swift
    PDFPlanRenderer.swift
    SerialTextOverlay.swift
    PDFExporter.swift
    PDFEdgeSamples.swift
    PDFColorProbe.swift
    GeneratedBleedOverlay.swift
  AtisPressApp/
    AtisPressApp.swift
    Workspace.swift
    WorkspaceView.swift
    InspectorView.swift
    SerialInspectorView.swift
    PreviewCanvas.swift
    ProjectDocument.swift
    ProjectWindowControl.swift
Tests/ImpositionCoreTests/PlannerTests.swift
Tests/ImpositionCoreTests/StepAndRepeatTests.swift
Tests/ImpositionCoreTests/SerialNumberingTests.swift
Tests/ImpositionCoreTests/SmartAutoLayoutTests.swift
Tests/ImpositionCoreTests/ArtworkClipTests.swift
Tests/ImpositionCoreTests/GeneratedBleedPlanTests.swift
Tests/PDFEngineTests/PDFSourceTests.swift
Tests/PDFEngineTests/PDFExportTests.swift
Tests/PDFEngineTests/GeneratedBleedTests.swift
Tests/AtisPressAppTests/WorkspaceTests.swift
Tests/AtisPressAppTests/ProjectDocumentTests.swift
Tests/AtisPressAppTests/AutoLayoutWorkspaceTests.swift
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

Open with **Dosya → Aç… / ⌘O**, the toolbar, or drop a PDF anywhere in the workspace.
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
| Ara boşluk | Flat/gang panel separation and packing capacity. Booklets show a fixed 0 mm at folds. |
| Taşma | Red bleed guides and per-slot insufficient/unknown bleed warnings. |
| Kesim uzunluğu / uzaklığı | Crop geometry and reserved outer space. Offset is hidden when mark length is zero. |
| Güvenli alan | Green inset guides. |
| Katmanlar | Show/hide only the corresponding plan marks or the sheet border; never alter layout. |

Changing mark geometry automatically enables its overlay so the change is visible.
Page labels stay readable at low zoom; purple badges identify rotation/mirroring,
and gray crossed slots identify blanks. Validation issues with slot references
outline those slots in red; clicking a referenced issue jumps to its sheet/face.
Margins/gripper have their own visibility toggle. Fit failures retain a separate
diagnostic preview with the source item, a red overflow outline and exact required
and available dimensions. Diagnostic geometry cannot be exported.

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

`swift test --disable-sandbox`: **194 XCTest tests, zero failures** (83 core,
52 PDF reading/drawing/export, 59 workspace/project persistence regression tests). GUI smoke checks
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
  signature size and unsupported bindings. Legacy included-cover geometry is preserved
  until the measured book workflow below is enabled.
- Standard PDF export and versioned project save/open are implemented; printing and installer distribution are not.

## Step & repeat — Tekrarlı yerleşim

Run with the same commands above (`swift run AtisPressApp`, or open `Package.swift`
and run the AtisPressApp scheme on My Mac). Select **Tekrarlı (kartvizit/düz iş)**
in **Yerleşim Yöntemi**. The existing booklet mode and its original tests remain.

- In **Çift yüz**, consecutive **selected-order** page pairs are independent jobs: 1/2, 3/4, etc.
  Each job gets its own sheet layout in **Tekrarlı İşler**. Different jobs may have
  different trim sizes; a job's front/back must match. An odd final page has an
  unprinted reverse when duplex is explicitly selected. New projects automatically
  choose Tek yüz for odd counts or unequal page sizes; each page then becomes
  its own front-only job. Source pages are never padded; `addedBlankPages` stays zero,
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
- Flat jobs start with **0 mm** and retain their own gutter across mode switches;
  gang retains its own independent value. Booklet modes always use **0 mm** at
  fold neighbors. Old saved booklet-gutter caches are ignored by mode switching;
  the core also ignores positive gutters when planning a folded publication.

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

Manual dimensions are limited to 1–200 per axis and rendered capacity to 20,000
items per sheet. Quantity has no artificial upper limit; checked native 64-bit
integer capacity applies. Larger grid dimensions report errors.
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
  `repeatCount` in flat work. Empty reverses follow the content policy below.
- **Her tabaka — ayrı PDF:** choose a parent folder. A new unique AtisPress folder
  receives one PDF per physical sheet, with front then back when included. Files are
  numbered continuously across jobs and repetitions.
- Export requires a source, a nonempty plan and `plan.canExport == true`. It is also
  disabled during import, recalculation and another export. Warnings still permit
  export. The engine independently enforces the same error gate.
- The current plan, source and export mark settings are frozen when the destination is
  accepted. Export runs off the main actor while preview/settings remain usable.
  **İptal** cancels rendering between slots/pages. Completion reports files/pages
  and offers **Finder’da Göster**. The completion banner describes the last output.
- **Çıktı İşaretleri** in both destination dialogs is independent of preview.
  Crop marks default ON; fold, bleed, safe area, slot labels, sheet info and full
  cut lines default OFF. Choices belong to `Project.exportMarks` and survive
  repeated exports and mode changes within that project. New workspaces start in
  **Tekrarlı (kartvizit/düz iş)** with zero gutter; assigning an existing project
  preserves its binding and export choices.
- Production strokes are solid, default **0.25 pt**, in DeviceCMYK black
  (0/0/0/100) or registration (100/100/100/100). Preview colors, dashes, sheet
  boundary, margins and gripper guides never print. Original source colors remain.
- Mark segments are clipped against every planned artwork/bleed rectangle with
  half-stroke clearance and against the sheet boundary. Existing crop offsets and
  anchors are retained. Warnings in the dialog explain removed portions.
- Artwork protection takes precedence over internal guides and full-length cuts:
  safe-area lines within artwork and full-cut portions crossing artwork are omitted.
  Slot labels are clipped to free space and can be partially hidden
  when margins/gutters are too small. Full cuts therefore do not print over artwork.
- Project-owned choices, mode and sheet values are saved in `.atispress` files
  and restored across launches (see Project save/open below).

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

`PDFPlanRenderer` handles shared artwork and preview guides.
`PDFExportMarkRenderer` handles protected production geometry and CMYK marks.
On-screen minimum text/stroke sizes keep preview guides legible at low zoom. Export writes drawing
operators through a Quartz PDF context. Vector paths/text remain vector, and
existing bitmap assets inside source PDFs remain images; no page-sized raster
flattening or bitmap-to-vector conversion is performed.

### PDFEngine API and extensibility

```swift
let result = try PDFExporter.export(
    plan: plan,
    source: source, // PDFSource opened by the reader
    destination: .singlePDF(outputURL),
    marks: ExportMarks.none
)
// Alternative: .perSheet(directory: folderURL, baseName: "book")
// result.files, result.pageCount, result.sheetCount
```

Call the synchronous engine API on a worker task. `PDFRenderOptions` belongs to
preview; production uses `ExportMarks`. The legacy `options:` overload maps flags
to production settings without exporting preview styles or press guides. The source file is protected from overwrite; whole-job
replacement is staged and atomically published. Per-sheet destinations reject
existing filenames. Rendering/overlay failures and cancellation remove staged
files instead of publishing partial PDFs. The app creates a unique per-sheet
folder, so a normal export does not collide with earlier outputs.

For additional variable text beyond the built-in serial fields, implement
`PDFSlotOverlay` and supply an array to `PDFExporter.export(overlays:)` or the shared
renderer's preview draw call. Hooks run **underArtwork** or **overArtwork**, in
slot-local trim mm with isolated graphics state and the plan's bleed clip. The
context provides trim/artwork rectangles, source page, slot/copy identity,
sheet/face/slot reference and physical repetition index. This requires no new
fields in `ImpositionPlan` or a separate layout path. Tests demonstrate vector
serial text with those hooks; generated bleed uses the same hooks in production.
The built-in serial UI and compact numbering recipe use this same vector overlay hook.

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

- Export has no artificial page-count cap. Output is streamed by sheet/repetition;
  numeric overflow is rejected. Actual export time and disk space grow with output.
- Standard PDF output only: no PDF/X certification, output intents, separation or
  overprint preflight, CMYK/spot-color conversion, trapping or press color proof.
- Source annotations, forms, links, bookmarks and document structure are not copied;
  the rendered PDF page content is imposed. Unlock encrypted input externally.
- A press sheet contains multiple finished trims, so only the sheet MediaBox is
  emitted as page metadata; individual trim/bleed extents remain plan geometry.
- At that stage, core packing/binding limits were unchanged. The measured book
  workflow below now adds independent covers, spine and creep.

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

## Preview/export separation verification

`swift test --disable-sandbox` covers production-only flags, empty output with all
marks off (including PDF stroke-operator inspection), solid CMYK black/registration
operators, crop stroke clearance against every slot's bleed clip at 0/1/10 mm
gutters, sheet-boundary/gutter warnings, default repeat mode, project mode/settings
retention, and export settings changing without replanning or changing preview.
The existing artwork, generated bleed, vector export, ordering, cancellation and
workspace regression tests remain in the suite. The native dialog layout has not
received an interactive GUI smoke check for this change.

## Project save/open — .atispress

Launch with `swift run --disable-sandbox AtisPressApp` (or open `Package.swift`
in Xcode and run **AtisPressApp / My Mac**). Launch and **Dosya → Yeni Proje / ⌘N**
start in **Tekrarlı (kartvizit/düz iş)** with **33×48 cm (330×480 mm)** stock.
Opening an existing project preserves its own mode, preset and custom dimensions.

- **Dosya → Aç… / ⌘O** accepts PDF and `.atispress` files. The toolbar and file
  drop also accept either type; a command-line argument can be either file type.
- **Kaydet / ⌘S** saves the current project; **Farklı Kaydet… / ⇧⌘S** writes a new
  project and switches subsequent saves to it. Source PDFs cannot be overwritten.
  Project writes are atomic. Empty projects can also be saved.
- Version 11 is readable JSON with top-level `version: 11` and `state`; version 1–10
  projects remain readable. Missing serial fields default to empty; old projects
  retain their saved layout values when opened. `state.project`
  contains ordered selected source-page metadata, binding/layout mode, blank-page
  and cover policies, sheet size/orientation/margins/gripper/gutter, every imposition
  setting, generated bleed settings/color, repeat grid/rotation/quantity, export
  mark choices, per-job serial fields, and automatic-layout state (production type,
  per-field automatic/manual flags, comfort level, clipping policy and summary). Other state fields retain all-page order, included pages, preview
  overlays, sheet preset, selected sheet/face, and the separately remembered booklet
  and repeat gutters. No calculated plan is persisted: the same planner regenerates it.
- `state.source` contains the absolute PDF path, base64 security-scoped read-only
  bookmark, filename and byte size. Bookmarks can follow moved PDFs; the original
  path is a fallback. Missing/inaccessible files or a changed byte size trigger
  **Kaynak PDF’yi Yeniden Bağla**. Relinking checks page count and selected-page
  trim/bleed metadata before applying the project, and marks it modified for saving.
- Unknown schema versions and inconsistent page selections are rejected. A failed
  or canceled open leaves the current project intact. Preview overlay switches are
  restored exactly; loading inspector values does not auto-enable guide layers.
- Setting, selection, order, source and overlay edits set the native window's modified
  indicator. Closing/quitting, New and opening another file prompt **Kaydet / Kaydetme /
  İptal**. Canceling or failing to save blocks the pending action. Sheet/face navigation
  alone does not count as an edit, but is included when saving.

Verification: `swift build --disable-sandbox` and `swift test --disable-sandbox`.
The suite includes JSON roundtrips/version rejection, defaults, exact restored plan
and overlay equality, identical rendered PDF exports before/after reopening, missing/changed PDF references, canceled and successful relink,
Save As, failed-write protection and save/discard/cancel decision coverage.
The restricted XCTest host cannot use ScopedBookmarksAgent, so persistence tests
inject native ordinary bookmark creation; production always requests security-scoped
bookmarks. A desktop smoke test of the built executable verified real security-scoped
bookmark saving, Save As, New defaults, saved-preset restoration, the Turkish relink
dialog and restored preview, and the native close/cancel prompt.

Limits: one active project/source PDF; PDFs are linked rather than embedded. The
identity check uses filename/size and selected page geometry, not a content hash.
Zoom/pan and transient row highlights reset on open; saved artwork placement,
preview layers and sheet/face are restored. There is no autosave, crash recovery,
project-version migration beyond v1–7 → v8, or an installer. The app bundle declares Finder file association as described above.
Use the app's Open command or a command-line path with the Swift package build.

## Serial numbering — Seri Numara

Run `swift run --disable-sandbox AtisPressApp` (optionally followed by a PDF or
`.atispress` path), or run the **AtisPressApp / My Mac** scheme in Xcode.
In **Tekrarlı (kartvizit/düz iş)** mode, select a job and choose **Seri Numara →
Alan Ekle**. Multiple independent fields belong to each page-pair job; numbering
restarts for each job. Existing projects start with no fields.

The inspector edits start, signed increment, zero-padding width, prefix/suffix,
installed font name, size in **points**, RGB/CMYK channels, clockwise rotation,
front/back/both item faces, and X/Y in **mm from the local bottom-left trim corner**.
X/Y identify the **left end of the text baseline**, before item rotation/reflection.
Select a field by its sample number, or click a number on the preview. Drag it to
move every occurrence of that field, snapping to 1 mm; dragging elsewhere still
pans. **Çoğalt** assigns a fresh field ID and offsets its position by 3 mm.
Serial edits update the existing plan immediately without repacking the artwork.

Set total finished quantity `Q` in **Seri Numara → Adet** or enable
**Tekrarlı Yerleşim → Adet hesapla**; both edit the same quantity.
Without a quantity, one full sheet is numbered. Let `C` be grid capacity, `S =
ceil(Q/C)` the physical sheet count, `r` the zero-based physical sheet index, and
`c` the zero-based copy/grid index (columns left to right, rows bottom to top as
viewed from the front). Back copies retain the same physical copy identity.

- **Sıralı:** ordinal `r*C+c`. Each sheet gets the next group of numbers.
- **İstif (kes ve istifle):** ordinal `c*S+r`. Cut each grid position into a pile
  with physical sheet 1 at the top, then concatenate piles in grid order.
- The printed value is `start + ordinal*step`. Ordinals `>= Q` receive no number;
  their existing artwork remains printed. Both modes therefore use exactly `Q`
  numbers per field on each selected item face, without numbering overproduction.

For a 2×2 grid, quantity 10, start 1 and step 1:

| Physical sheet | Sıralı (grid/copy order) | İstif (grid/copy order) |
| --- | --- | --- |
| 1 | 1, 2, 3, 4 | 1, 4, 7, 10 |
| 2 | 5, 6, 7, 8 | 2, 5, 8, — |
| 3 | 9, 10, —, — | 3, 6, 9, — |

The sheet list shows first/last formatted numbers for every field on each physical
sheet. Click a physical-sheet row or use **Baskı tabakası** to preview its real
numbers. Large lists show 100 sheets at a time with previous/next controls.

`Project.serialFields` is saved in `.atispress` files with stable UUIDs
and zero-based job indices. `Sheet.serialPlan` holds a compact pure-core numbering
recipe, evaluated for each slot and physical repetition; it does not allocate a
quantity-sized array. Preview and PDF export use this same recipe and the same
`SerialTextOverlay`. Serials are **vector artwork**, independent of preview guide
switches and export-mark checkboxes. They are clipped to each item's trim to
protect neighboring items. An unprinted reverse may contain a serial if Back/Both
is selected. Colors and font metrics are shared by preview and export.

Validation blocks invalid fields and Int64 number overflow. Up to 100 fields,
32 padding digits and 1–500 pt fonts are supported. Unknown font names use the
system fallback; the inspector reports an unavailable selected font. Cut-and-stack
assumes the pile order above, with no automatic reversal for a particular cutter
or sheet-delivery direction. Same-plate work styles require **distinct numbered
front/back plates**; a warning explains that the numbered output cannot be run as
one unchanged shared plate. Serial fields are retained but inactive in booklet
modes. Long/rotated text extending outside trim is clipped rather than auto-fitted.

Verification adds small-grid sequential/stack and partial-quantity examples,
front/back/copy identity (including repeated PDF pages and blank reverses), per-job
fields, formatting/overflow, immediate edits/duplication, rotated drag hit testing
and mm snapping, v1 compatibility and numbered project roundtrips. PDF tests
inspect real exported text, its planned positions, vector resources, rotated and
reflected glyph footprints, and matching preview/export pixels across repetitions.
A native launch showed the new inspector. Further interactive serial smoke checks
were blocked by an unresponsive macOS file picker and subsequent ScreenCaptureKit
errors in the desktop automation service; automated AppKit drag tests passed.

## Smart auto layout — Otomatik düzen

Run `swift run --disable-sandbox AtisPressApp`, optionally followed by a PDF or
project path, or use Xcode's **AtisPressApp / My Mac** scheme. New workspaces still
start with Tekrarlı and **Otomatik (ürüne göre)** sheet selection, backed by
SRA3 for Dijital or 33×48 for Ofset before a source is known. **Importing a PDF now runs
Otomatik düzen for its actual trim dimensions.** The inspector and toolbar also
provide **Otomatik düzenle**. Opening a saved `.atispress` restores it exactly and
does not rearrange it.

Select **Üretim → Dijital / Ofset** (default Dijital). Changing production reruns
layout while retaining manual fields. The solver uses these decisions:

1. A5, A4, A3, SRA3, 33×48, 35×50, 50×70 and 70×100 are recognized within ±1 mm,
   including swapped orientation. A matching flat item uses the same paper one-up,
   without marks/bleed/margins. Slight excess trim is clipped without scaling.
2. **Tabaka seçimi → Otomatik** (default) retains the production default stock
   for a nonstandard item whenever at least one copy fits at any comfort level.
   Otherwise it chooses the smallest fitting preset, then a custom sheet if none
   fits. **En verimli** explicitly opts into maximum-copy stock selection.
   **Sabit** retains the chosen stock. Selecting a concrete size pins it; beside
   its **Manuel** label, **Otomatik'e dön** releases only the sheet-size override.
   Saved projects retain their selection and size. Legacy automatic projects
   without a selection policy retain their previous maximum-copy behavior.
3. On each candidate stock, the first fitting comfort level wins:

| Level | Margins | Gripper | Marks / bleed |
| --- | --- | --- | --- |
| L1 full | 10 mm | Dijital 0; Ofset 10 mm | 5 mm crop ticks, offset = bleed + 0.5 mm; bleed 3 mm |
| L2 reduced | 5 mm | Production minimum | Same crop marks and bleed |
| L3 clipped | Dijital 3; Ofset 5 mm | Production minimum | Crop marks off; bleed clipped to stock |
| L4 full sheet | 0 | Dijital 0; Ofset 10 mm | Marks and bleed off |

Ofset's 10 mm gripper remains reserved even at L4. If that prevents a matching
paper from fitting, automatic stock selection tries a larger sheet; pinned stock
keeps the fit error. The full-sheet digital L4 explicitly allows zero margins.
Source bleed that is missing/unknown/insufficient enables generated bleed, unless
that setting was manually chosen. A full-sheet job with zero bleed does not need
it. Flat work defaults to **Bitişik**, with automatic gutter **0**;
**Aralıklı** sets automatic gutter to **2 × bleed**, independently of crop marks.
The existing gutter contract remains: positive gutter is the clear distance
between bleed boxes, with trim pitch = trim + 2×bleed + gutter.

Auto-chosen controls are labeled **Otomatik**. Editing a control (even selecting
its current value) labels it **Manuel** and locks it against future imports and
production changes. Other fields can still adapt to the new source. **Otomatik
düzenle explicitly clears these locks** and chooses afresh, while preserving job
mode, turn method, quantity, page selection and serial fields. Preview-layer
switches remain independent of export marks. A short Turkish summary is shown
in the inspector and below the preview after each automatic arrangement; manual
edits clear a stale summary.

`SmartAutoLayout.arrange(project, resetOverrides:)` is a pure-core API returning
the chosen project, preset name, summary and the real imposition plan. Import and
button calculations run off the main actor; duplicate page-pair dimensions are
probed once. Visible generated-bleed samples are prepared before publishing the
new import. Serial numbering and PDF export consume the resulting plan normally.

`Project.autoLayout` is saved in schema v8 (including sheet-selection policy) with each field's ownership, production,
level, summary, sheet-clipping policy and standard-paper tolerance. v1/v2 projects
without this metadata are restored as saved, and their existing settings are
preserved on PDF replacement until the explicit Auto button is used. The version
regression test still checks the version field, now against the active schema.

A fit failure leaves `plan.sheets` non-exportable and supplies `diagnosticSheets`
separately. The canvas expands to show the red required extent beyond the actual
paper; diagnostics state source trim, grid, 0° required size, stock size and usable
area in mm. Referenced issues select that diagnostic sheet. Empty page selection
and invalid PDF input still show their own validation state.

Tests cover A4/A5 full-sheet matches, swapped orientations and ±1 mm clipping
without scaling, L1 cards on pinned 33×48, L2/L3 fallback, Ofset gripper minimums,
maximum-copy stock selection, large/custom fallback, sticky edits across imports,
explicit reset, saved production/flags, old-schema compatibility, diagnostic
source retention and actual red pixels outside the paper, clean L1 crop geometry,
and exported PDF MediaBox equality with the chosen sheet. All earlier serial,
preview, bleed, export and persistence tests remain in the suite.

Current limits: regular grids and one shared stock policy per project; no printer
capability discovery or cost/stock-waste optimization. Manual settings take
precedence and can still cause a fit error. Full-sheet tolerance trims up to 1 mm
rather than rescaling artwork. Native interactive UI smoke testing has not been
rerun for this change; the AppKit diagnostic rendering test runs automatically.

## Serial range controls and grouped warnings

**Seri Numara** shows the shared **Adet**, every field's formatted first/last
number and sheet count, plus **Fazla N kopya numarasız** for overproduction.
Enable **Bitiş no göster** to edit an inclusive end number: a valid end derives
`Adet = (end − start) / step + 1`; quantity edits update the displayed end.
Wrong direction, zero step, incomplete increments and overflow produce Turkish
inline errors without changing quantity. Quantity still applies to every job.

Padding grows automatically when the range needs more digits, with
**Basamak 5'e çıkarıldı** feedback. Editing padding fixes it manually; an
insufficient fixed width gives a warning and preserves the complete number.
These controls and ownership flags survive project save/open. Numbers support
signed 64-bit values and positive native 64-bit quantities, including 9,999,999
and larger; arbitrary-precision integers are not implemented.

Preview calculates only visible slots and the current 100-row sheet-list window.
Stack ranges use constant-time arithmetic rather than expanding the quantity.
Tests check first/last ranges for 100,000 copies in a 2×2 grid and huge export
iteration reaching its first sheet without allocating repetition arrays.

Generated bleed suppresses missing-bleed warnings when enabled and needed.
Displayed identical warnings are grouped with counts and compressed source-page
ranges, e.g. **12 sayfada taşma payı eksik: 1-12**; detailed slot references remain
available internally. Existing preview/export alignment and project roundtrip
regressions remain active. Run `swift test --disable-sandbox` for all 194 tests.
Native interactive smoke testing has not been rerun for these controls.

## Empty reverse export and repeat arrangement

When the entire plan has no back artwork, both export destinations omit empty
reverses and show **Arka yüz boş: çıktıya eklenmedi.** A 10-copy serial form in a
2×2 grid exports three front pages, with unchanged serial text and placement.
In mixed jobs, **Boş arka yüzleri çıktıya ekle** defaults ON to preserve duplex
alignment; switching it OFF omits just the empty reverses. The choice is saved
per project and does not trigger geometry recalculation. Marks/guides alone do
not count as artwork. Serial-only backs and same-plate fronts printed on the
reverse do count as content and remain in the PDF. An empty **Arka** preview
shows **Arka yüz yok**. Physical sheet counts and per-sheet filenames stay stable.

**Tekrarlı Yerleşim → Dizilim** offers **Bitişik (ara boşluk 0)** and
**Aralıklı (ara boşluk = 2 × taşma)**, with an **Otomatik** label for calculated
gutters. Bitişik is the new-project and explicit automatic-reset default:
common trim cuts, generated/source bleed clipped to the block perimeter, and
the existing shared-cut warning. Aralıklı tracks changes to bleed. Editing
**Ara boşluk**, including re-entering its value, selects **Özel / Manuel**;
imports preserve that manual gutter until automatic layout is explicitly reset.
The existing positive-gutter geometry and insufficient-gutter warnings remain.
Version 5 saves the arrangement; old files without it keep their saved gutter.

Verification adds front-only serial text/position tests, mixed duplex output with
the checkbox ON/OFF in both destinations, serial-only/same-plate reverse retention,
default perimeter clips, spaced/custom behavior, and exact saved-plan restoration.
All previous tests remain, with the former spacing-specific tests explicitly
choosing Aralıklı and the front-only extension test expecting the new page count.
Run `swift run --disable-sandbox AtisPressApp`; verify with
`swift test --disable-sandbox`. Native interactive UI smoke testing has not been
rerun for that change. Single-source jobs now support the page-layout options below.

## Home screen and recent files

The empty home screen shows **PDF Seç…** below
**PDF dosyasını buraya sürükle veya ⌘O ile yükle**. It opens the standard macOS
file picker restricted to PDF files. **Proje Aç…** opens the same picker restricted
to `.atispress` projects. **Dosya → Aç / ⌘O** continues to accept both types.
Every picker selection, recent-file click, Finder open and drag-drop converges on
`Workspace.open`; PDF reading, automatic layout, preview, save prompts and the
project relink flow remain shared.

**Son kullanılanlar** retains the five most recently opened PDFs/projects or
saved projects, newest first. Reopening a file moves it to the top without a
duplicate. History persists in app preferences, independently of project JSON,
with security-scoped bookmarks when available and a path fallback. A canceled
picker or failed import does not add an entry. Missing/inaccessible files stay in
the list, greyed out and disabled with **Bulunamadı**; availability refreshes on
showing the home screen, returning to the app, and before opening a recent item.
Successful bookmark resolution can follow moved files.

Five new regression tests exercise the actual button and menu actions through an
injected file-picker result (no native dialog during XCTest), comparing imported
projects and plans with drag-drop and recent-file opening. They also cover typed
picker filters, cancellation, project restoration, persistent ordering/deduplication,
missing-file availability and failed-import history. All 114 earlier tests remain
unchanged; that addition brought the suite to 119 tests. Production features below extend it to 134. Native interactive picker/UI smoke
testing has not been rerun for this change.

Run `swift run --disable-sandbox AtisPressApp` or rebuild the signed bundle with
`./scripts/build_app.sh` and open `dist/AtışPress.app`.

## Fire payı, sayfa düzeni, ön kontrol ve bilgi şeridi

**Adet** in the repeat and serial inspectors remains the requested customer
quantity. Beside it, **Fire** selects **Yüzde (%)** (default 0) or **Sabit adet**.
Percent fire rounds upward to a whole copy. The planner uses `Adet + fire` to
calculate physical sheets and shows, for example,
**Adet 1000 + fire 50 = 1050 üretim, 12 tabaka** for a 90-copy grid. Grid rounding
can produce additional copies; the existing actual production count remains
visible. **Fire kopyalar → Numarasız** is the default. **Numaralı** extends each
field's range through the production quantity; the end-number input still determines
the customer quantity. Capacity rounding beyond that
quantity is always unnumbered. Sequential and cut-and-stack use the same lazy
recipe and total physical-sheet count; no quantity-sized arrays are created.
Fire/quantity apply per flat-work job, as before; booklet modes do not have an
independent run-quantity control. Invalid or overflowing counts report errors.

For multi-page imports, **Sayfa düzeni → Otomatik** chooses **Çift yüz** only for
an even selected-page count with equal dimensions (within 0.001 mm); otherwise
it chooses **Tek yüz**. The resolved choice is labeled **Otomatik**. A manual
choice persists across imports. **İş yüzü** in the job list overrides the rule
at that source front page: splitting a duplex job preserves both pages as
separate fronts; a duplex override consumes the next selected page. Each selected
page is used exactly once. Serial fields follow their source faces when jobs
are regrouped, duplicating a both-sides field if its faces become separate jobs.
Explicit simplex jobs suppress serial-only backs. Existing mixed-job blank-back
export controls remain in force; same-plate turn/tumble still requires both press
faces when each contains artwork.

Schema **6** saves `stepAndRepeat.waste`, `stepAndRepeat.pageLayout` (global mode
and source-front-page overrides), and `project.sheetInfo` (name and field flags).
Versions 1–5 still open. Missing production settings mean zero fire, unnumbered
fire and legacy consecutive duplex pairing; opening never rearranges an old
project. The Swift core API also treats a nil `pageLayout` as legacy intent;
set `PageLayoutSettings()` to request the new automatic policy. New app projects
set this automatically. Preflight results are derived from the linked source,
not persisted as potentially stale inspection results.

**Ön Kontrol** inspects the source during import, off the main actor, using only
Apple CoreGraphics/PDFKit/Foundation. It reports grouped Turkish findings with
severity, affected page ranges and counts: RGB image/color use, effective image
resolution below 250 dpi, used unembedded fonts, Separation/DeviceN spot spaces,
transparency/soft masks/blend modes, page-size differences, missing bleed, and
vector CMYK colors above 300% total ink. Image DPI uses placed content-stream
transforms, including nested Form XObjects; imposition preserves scale. RGB is
informational for Dijital and a warning for Ofset. Generated bleed suppresses
missing-bleed findings when applicable. No preflight finding disables export;
existing invalid-plan and mismatched duplex-size errors still apply.

This is **best effort**, not PDF/X certification or a full RIP: unsupported inline
images, patterns/shadings, complex/resource-limited streams, ICC conversion and
pixel-level total-ink coverage are explicitly **kontrol edilemedi**. Font checks
inspect used PDF font descriptors/program streams; Type 3 programs count as
embedded. Finding no issue is never shown as an overall OK. Inspection bounds
nested forms and tracked operators, avoids image decompression, and does not
alter the PDF or convert colors.

In the export dialog, **Tabaka bilgi şeridi** now has checkboxes for **İş adı**,
**Tarih**, **Tabaka no / toplam**, **Ön/Arka**, **Tabaka boyutu** and
**Ofset/Dijital**. The editable name defaults to the PDF filename. An example
updates immediately with the chosen fields. Export draws vector Helvetica text
at **6 pt**, using the selected black/registration CMYK mark color. Date is
captured once per export. A measured placement must fit an outer free margin,
clear of every trim/bleed box, production stroke and slot label. When the full
line cannot fit, it is skipped and **Tabaka bilgi şeridi için boş kenar alanı yok;
şerit çıktıya eklenmedi.** appears in the dialog/export notes. It is never partially
printed over artwork. Both combined and per-sheet PDFs use the same settings.

All 119 earlier tests remain unchanged. Fifteen additional tests cover fire
arithmetic/rounding/overflow, lazy numbered and unnumbered fire in both modes,
automatic/manual/per-job side selection, serial face migration, known RGB/low-DPI/
unembedded-font/spot/transparency/rich-black PDF fixtures and inherited Form
resources, strip geometry/no-room behavior/vector 6 pt text, grouped preflight,
and complete schema-6 roundtrips with version-5 compatibility. Current total:
**134 tests, zero failures** at that stage; color-control coverage below brings the total to 142. Native interactive UI smoke testing has not been
rerun for this change.

```sh
swift run --disable-sandbox AtisPressApp
swift test --disable-sandbox
./scripts/build_app.sh
open "dist/AtışPress.app"
```

## Renk skalası ve diz işaretleri

The export dialog now has independent **Renk skalası** and **Diz işaretleri**
checkboxes. Both default OFF for Dijital and ON for Ofset. Automatic layout and
the production selector apply these defaults unless the individual export choice
was edited manually. A separate pair under **Önizleme Katmanları** controls only
preview visibility; manually chosen preview visibility survives production
changes independently. Neither preview switch can enable export content.

**Diz boyutu (mm)** defaults to a 5 mm circle/crosshair, drawn with solid strokes
in registration **CMYK 100/100/100/100**, regardless of the ordinary mark-color
selector. Each target stays on the midpoint axis of its sheet edge and moves
inward only within that outer margin. A target that cannot fit is skipped with a
Turkish warning; other fitting edges remain available.

**Yama boyutu (mm, kare)** defaults to 5×5 mm. **Skala konumu** selects
**Maşa tarafı** or **Maşanın karşısı**; horizontal edges get a horizontal bar and
vertical edges a vertical bar. The twelve adjacent vector patches have these
exact CMYK values (fractions of 100%):

| Patch | C | M | Y | K |
| --- | --- | --- | --- | --- |
| C100 | 1 | 0 | 0 | 0 |
| M100 | 0 | 1 | 0 | 0 |
| Y100 | 0 | 0 | 1 | 0 |
| K100 | 0 | 0 | 0 | 1 |
| C50 | 0.5 | 0 | 0 | 0 |
| M50 | 0 | 0.5 | 0 | 0 |
| Y50 | 0 | 0 | 0.5 | 0 |
| K50 | 0 | 0 | 0 | 0.5 |
| B (C+M) | 1 | 1 | 0 | 0 |
| R (M+Y) | 0 | 1 | 1 | 0 |
| G (C+Y) | 1 | 0 | 1 | 0 |
| CMY gri | 0.5 | 0.4 | 0.4 | 0 |

Combined-ink patches are explicit CMYK fills, with no RGB conversion or raster
image. The gray recipe is fixed, not a calibrated/profile-dependent neutral proof.

Placement uses the artwork/bleed and crop geometry of **both** faces in a common
physical sheet frame. The back output is reflected using the planner's existing
turn/tumble viewing convention, so the bar and each colored patch align through
the sheet relative to the gripper. No extra artwork flip is introduced. Controls
stay in outer margins, never in item gutters. Stroke width is included in
clearance. Planned crop ticks and potential target positions remain reserved even
when hidden, keeping the bar stable as visibility switches change. When needed,
the bar shifts along the selected edge. If there is insufficient room, a warning
appears in preview/export settings and export notes, and the affected control is
omitted. Controls take placement priority over the job info strip, which then
finds another clear margin or reports its existing no-room warning.

Sizes and bar side are shared between preview and export and saved in
`project.exportMarks.colorControls`; visibility flags stay independent. Schema
**7** saves these plus the preview switches and their manual/default ownership.
Versions 1–6 remain readable; absent controls and preview flags restore as OFF,
including old Ofset projects, without changing their output on open. An explicit
production selection adopts defaults for the newly introduced controls.

Eight new tests check both faces' bleed/crop clearance on all gripper edges,
exact patch values in actual PDF operators, registration target color, printed
front/back alignment, target/patch sizes, no-room warnings and partial placement,
info-strip clearance, independent preview/export output, a real AppKit preview
pixel change, production defaults/manual overrides, and version-7 roundtrip with
version-6 compatibility. All prior tests remain; the active-schema assertion now
uses `ProjectDocument.currentVersion`. That feature set passed 142 tests; the current suite has 194. Interactive desktop
smoke testing has not been rerun; preview drawing is exercised in XCTest.

```sh
swift run --disable-sandbox AtisPressApp
swift test --disable-sandbox
./scripts/build_app.sh
open "dist/AtışPress.app"
```

## QR / Code 128 serial fields

In **Seri Numara → Tür**, choose **Metin**, **QR kod** or **Barkod (Code 128)**.
Existing projects/fields remain Metin. **İçerik şablonu** defaults to `{no}`;
all occurrences are replaced with the complete formatted number, including
prefix, zero padding, sign and suffix. Example: start 7, five digits, prefix `K-`
and suffix `-X` expands `https://site.com/k/{no}` to
`https://site.com/k/K-00007-X`. A template without `{no}` is static: the same
payload is printed throughout the field's normal quantity/fire copy range.
Static codes do not depend on counter arithmetic or overflow. Sıralı and
**Yığın (kes ve istifle)** retain the existing lazy ordinal plan.

Code settings are millimetres: QR defaults to a 25 mm square; a newly selected
Code 128 defaults to 50 mm width and 15 mm bar height. Width includes the quiet
zone. QR correction offers **L / M / Q / H**, default **M**. **Sessiz alan** defaults
to **4 modules on all four QR edges** and **10 modules on the left/right of Code
128** (editable range 0–1024 modules). The position is the lower-left corner of this outer quiet-zone box;
text fields retain their baseline anchor. Rotation, item rotation, face choices,
1 mm drag snapping and field duplication use the existing placement path.

**Altına okunabilir metin yaz** adds the expanded payload below the code, using
the field's selected font and its separate point-size setting (default 8 pt).
The code and text rotate together. Codes use CMYK, default K100; selecting a code
type from an RGB text field initializes its color to K100. An opaque CMYK-white
knockout background protects the quiet zone and readable-text area from underlying
artwork. Everything remains clipped to the item's trim.

Only Apple CoreImage's **CIQRCodeGenerator** and **CICode128BarcodeGenerator**
encode payloads. The generator bitmap is read at native module resolution,
normalized to a top-row-first matrix, and stripped of its built-in padding.
Explicit quiet-zone geometry is then applied in mm. Preview and PDF share
**filled vector rectangles** for contiguous dark module runs; neither embeds the
generator image. Optional readable text uses CoreText. Source PDF images remain
source images, as before.

A cache is configured for 256 results with a 16 MiB cost budget. Codes are
generated for visible/exported copies; the sheet list still calculates number
ranges without generating matrices. Validation probes field endpoints rather
than expanding a run. A 100,000-copy job retains just its grid and numbering
recipe. Duplicate/static payloads reuse their matrices. For variable-width manual
number formats, endpoint warnings are a useful check rather than certification
of every intermediate symbol.

Turkish warnings appear below the preview and in export notes for **QR modules
below 0.33 mm**, **Code 128 narrow bars below 0.25 mm**, content requiring a wider
code, insufficient quiet zones, generation/capacity failures, and rotated code or
readable text extending beyond trim. Too-long/unencodable codes are omitted with
a warning; artwork and valid serial fields still export. Code 128 accepts ASCII
without lossy conversion; use QR (UTF-8 bytes) for other characters. QR and Code
128 remain subject to Apple's encoder capacities (requests above 4096 QR bytes
or 1024 Code 128 bytes are rejected before generation). Actual scan performance
also depends on contrast, stock, print process and reader; hardware scanning has
not been verified. The restricted test host cannot run Apple's Vision decode
backend, so no successful decoder check is claimed.

Schema **8** saves the optional `SerialField.code` object: kind, template, width,
height, QR correction, quiet-zone override, readable-text flag and text size.
Existing font/color/position/rotation/mode/sides remain shared serial settings.
Versions 1–7 still open with missing code settings interpreted as text.

Nine new tests cover known matrices against the Apple generators and QR finder
orientation, full `{no}` substitution/static content, correction/quiet-zone and
size/trim warnings, 100,000-copy sequential/stack sampling, exact dark/white module
cells in rendered PDFs, readable payload text, no image XObjects in vector-fixture
exports, rotated click/drag snapping, live edits/duplication without repacking,
and complete schema-8 roundtrip with version-7 compatibility. **151 tests pass**;
all earlier tests remain, with the active-schema assertion updated to the current
version. Interactive desktop UI and physical scanner smoke testing were not rerun.

```sh
swift run --disable-sandbox AtisPressApp
swift test --disable-sandbox
./scripts/build_app.sh
open "dist/AtışPress.app"
```


## Karışık iş (gang run) — schema 9

Choose **Karışık iş (gang)** in **Yerleşim Yöntemi**. The current PDF becomes
one job per front/back pair (using the existing automatic tek/çift yüz rules).
**PDF ekle…**, PDF drag/drop, and PDF Open add more linked PDFs in this mode.
Multiple PDFs may be selected together. Choose **İşi çoğalt** to create another
job from the same PDF, then choose its **Ön sayfa** / **Arka sayfa**. **Yok — tek
yüz** leaves that job's reverse blank. Each job owns its name, Adet, fire,
rotation permission, trim size from the PDF, bleed/generated bleed settings,
and all existing text/QR/Code 128 fields. Select a job in the sidebar before
editing its inspector sections.

**Otomatik düzenle** searches a guillotine slicing tree of rectangular job-grid
blocks on the selected stock. Both item rotations and sheet orientations are
considered. Every job receives copies per sheet; the common production count is
`max(ceil((Adet + fire) / copiesPerSheet))`. The sidebar reports each job's
copies/sheet, surplus, and current serial range; its bounded physical-sheet list
and stepper remain lazy for large quantities. Fire numbering follows each job's
own **Numaralı / Numarasız** choice. Artwork-only edits reuse the cutting solution.

**Elle yerleştir** freezes the current automatic blocks. Drag a block on either
face (1 mm snap), or edit X/Y, columns, rows and rotation. Blocks can be duplicated
or deleted. Margin, gripper, bleed/gutter, overlap, missing-job and non-guillotine
errors retain the requested coordinates, highlight artwork red, and block unsafe
export. Zero gutter uses common trim edges with bleed clipped at neighboring
artwork; positive gutter must be at least twice the largest job bleed. The planner
never silently increases a manually entered gutter or moves an invalid block.
A bent, L-shaped knife path is rejected. An L-shaped *arrangement* that can be
separated using successive straight cuts is correctly accepted.

Job tints and names drawn over the preview are proof overlays only. Serial text
and codes use the same per-job lazy recipes in preview and vector PDF output.
Sheetwise, work-and-turn and tumble use the existing gripper-relative reflection
convention; front-only pieces remain blank on their reverse. Existing front-only
and mixed-duplex export rules still apply. Crop ticks follow the rectangular
leaf cuts; full cut guides use the slicing regions and are clipped out of every
job's artwork/bleed. Information strips list all job names (plus an optional
project title) when enabled and are skipped with a warning if they cannot fit.
Preflight inspects the original PDFs and is grouped separately by job, using original PDF page numbers and each job’s own bleed policy.

Schema 9 adds optional `project.gang`, `state.gangSources`, and the remembered
`state.gangGutter` for mode switches. The latter stores
each original PDF's path, read-only security-scoped bookmark, name, size and page
count. Original PDFs are never embedded. A temporary PDFKit document copies their
page objects without rasterizing them and is rebuilt on open; its temporary path
is never saved. All linked originals are protected against output overwrite.
Missing/changed links use the existing Turkish relink dialog, one PDF at a time.
A failed or canceled relink leaves the active project intact. Versions 1–8 still
open, with no gang settings, and keep their saved mode and stock.

Run and validate:

```sh
cd /Users/baturayatis/Developer/AtisPressCore
swift run --disable-sandbox AtisPressApp
swift test --disable-sandbox
# Optional double-clickable release bundle:
./scripts/build_app.sh
open "dist/AtışPress.app"
```

Known limits:

- Up to 8 gang jobs, 200 rows/columns per block and 20,000 physical slots per
  sheet. Automatic layout uses one regular rectangular block per job. For 1–4
  jobs it minimizes sheets within this slicing/grid model; it is not a global
  optimum over arbitrary split-block or polygon nesting. For 5–8 jobs the Pareto
  frontier is sampled to bound search cost; a Turkish warning explicitly says
  that the minimum sheet count is not proven. Manual layouts may use multiple
  blocks per job.
- A gang project uses one repeated sheet pattern and the selected stock; it does
  not schedule separate finishing sheets or automatically change stock size.
  Reducing surplus using a different final-sheet pattern is not implemented.
- Removing a job retains its linked PDF in the source catalog for reuse; that
  source must still be available or relinked when the project opens.
- PDFKit preserves vector artwork but may normalize PDF structure. Original
  forms/actions, interactive annotations, encryption and signatures are not
  production-output guarantees. Existing best-effort preflight limits apply.

Regression coverage includes unlike-size packing, the common sheet-count/fire
formula, a non-slicing windmill and bent-cut rejection, manual overlap/margin
preservation, all turn/gripper combinations with mixed backs, lazy 100,000-copy
numbering, bounded eight-job search, mark clearance, vector multi-source serial
and QR export, preview tint/drag behavior, linked-source overwrite protection,
missing-link recovery, schema-9 roundtrips, and the existing legacy project tests.


## Kitap modu — bağımsız kapak, sırt ve creep (schema 10)

Run the app, import the body PDF, choose **Tel dikiş** or **Tutkallı cilt**, then
click **Kitap ayarlarını aç**. This explicit opt-in preserves the exact layout of
existing projects. No stock caliper or binding factor is guessed. The new book
workflow uses the selected press stock; the stock preset and orientation remain
editable, and **Otomatik düzenle** recalculates the book without replacing paper
measurements or automatically selecting another stock.

**Kapak modu**:

- **İç sayfalara dahil** initially selects the first two and last two PDF pages as
  front / inside front / inside back / back. These roles can be overridden. Those
  four selected cover faces are removed from the interior block and imposed as
  an independent cover, in accordance with the independent-cover workflow.
- **Hariç — ayrı bas** requires explicit role selection from the body PDF. Each
  inside face can be **Boş**. Only selected cover pages are removed from the body;
  other selected PDF pages remain interior pages. The **İlk / son kapak yüzlerini
  seç** action fills all four roles explicitly.
- **Ayrı PDF** loads a linked cover PDF. The original body PDF remains entirely
  interior content. Choose **Tek tek kapak yüzleri** for four individual panels,
  or **Hazır açılım (dış / iç)** for an outer spread plus an optional inner spread.
  The page menus identify the original PDF filename and page number. **Kapak
  önizle** / **İç sayfalar** navigate the independently labeled sheet sections.
  The existing **Her tabaka — ayrı PDF** export also writes the cover sheet to
  its own file.

The project stores caliper either as **µm**, or **g/m² × cilt katsayısı (cm³/g)**.
For the latter, the product is micrometres; divide by 1000 to obtain millimetres.
Both inputs must be supplied; there is no default factor. The inspector and
preview show the entered units and the resulting mm value. Inactive input-mode
values are retained but are not used. Missing thickness is labeled **hesaplanamadı**.

For perfect binding, `MeasuredSpineCalculator: SpineThicknessCalculating` uses:

```
spine_mm = (interior_pages / 2) × interior_caliper_mm
           + cover_allowance_mm + adhesive_allowance_mm
```

The interior page count includes the blank pages actually required by the chosen
folding signature, and excludes separately selected cover faces. Both allowances
are user inputs, **default 0 mm**, explicitly labeled in the UI. Cover-paper
caliper is displayed independently and is never silently added as an allowance.
For example, 100 interior pages at 120 µm plus 0.4 mm cover allowance and 0.6 mm
adhesive allowance produce **7.0 mm**. Missing interior caliper blocks export.

The cover trim spread is **left flap + back + spine + front + right flap**;
height equals the body trim height. Existing job bleed is added around its outer
perimeter. The preview gives spine width, trim spread size, bleed-inclusive size,
individual flap widths, paper inputs and allowances. Inner panels are reversed
appropriately behind the outer cover. Optional flaps default to 0 mm. Individual
panel mode leaves spine and flaps unprinted; use a supplied full-spread PDF for
printed spine/flap artwork. Panel trim mismatches block export. A supplied spread
that differs by more than 0.1 mm generates a warning with the exact actual and
computed sizes; it stays at its **native scale** and is clipped to the computed
spread. Its artwork is never silently stretched to fit.

For saddle stitch, enable **Creep açık** after entering both interior and cover
caliper. `LinearCreepCalculator: CreepCalculating` is a deliberately simple,
additive nested-leaf approximation. The independently imposed outer cover stays
at zero compensation. For zero-based interior leaf `i`, outer to inner:

```
shift_mm(i) = cover_caliper_mm + i × interior_caliper_mm
maximum_mm = cover_caliper_mm + (interior_leaf_count − 1) × interior_caliper_mm
```

Each page's artwork shifts toward the fold: +local X on the left panel, −local X
on the right panel. Rotation and same-plate reflection transform those vectors
with the existing slot transform. Compensation is indexed by **logical nested
leaf**, not press-sheet index, because multiple distinct leaves may share a press
sheet. Trim boxes, fold/crop marks, sheet size and neighboring clipping bounds
stay fixed. Vector artwork and generated bleed follow the same displacement in
preview and PDF export. Missing caliper, creep enabled on perfect binding,
nonpositive measurements, invalid selections, mismatched panel sizes or a shift
reaching half the page width block export; invalid data is never written back as
a guessed value. Fit failures retain diagnostic outlines and section-aware links.

**This is a simple approximation, not a calibrated bindery model. Verify it with
a physical folded, trimmed test before production.** It does not account for
paper compression, nesting pressure, grain, moisture, ink loading, fold swelling,
adhesive chemistry or machine-specific compensation. There is no automatic
measurement or spine artwork editor in part 1. Saddle-stitch flaps are not part
of this workflow. Both cover modes sourced from the body PDF use independent
cover sheets; turn off the new book workflow by opening an unchanged legacy
project if the original included-cover signature behavior is required.

`Project.book` saves every paper input, cover role, cover artwork mode, allowance,
flap, creep toggle, cover source ID and PDF-page domain. Schema 10 adds optional
`state.linkedSources` for body/cover PDF bookmarks, names, sizes and page counts;
the schema-9 gang source catalog remains readable. Original PDFs stay linked,
with a temporary vector-preserving combined document rebuilt on open. Source
PDFs cannot be overwritten by project or export output. Relinking a missing
cover uses the Turkish source dialog; a failed/canceled relink leaves the active
project intact. Loading a different cover retains earlier source links in the
catalog for recovery, but their pages remain excluded from the interior block.
Versions **1–9** still open with unchanged saved layout and no caliper assumptions.

```sh
cd /Users/baturayatis/Developer/AtisPressCore
swift run --disable-sandbox AtisPressApp
swift test --disable-sandbox
./scripts/build_app.sh
open "dist/AtışPress.app"
```

The new tests cover the measured spine formula, gram-to-caliper conversion,
monotonic creep across logical leaves (including multiple leaves per press
sheet), fixed trim/clip geometry, all turn styles, cover selection and independent
ordering, spread/flap sizes, native-scale mismatch warnings, diagnostic section
links, vector text export positions and image-XObject absence, live preview pixel
changes, schema-10 roundtrips, separate-cover relinking/overwrite protection, and
schema-9 compatibility. The complete suite has **194 tests**.


### A5 / 106-page / separate-cover / A4 zero-gutter regression

Reproduced first with a failing test: 106 A5 interior pages, a separate four-face
A5 cover, manually selected landscape A4, every margin/gripper/gutter at 0,
all output marks off, and the normal 3 mm bleed retained. The original diagnostic
was **gereken 302.00×216.00 mm** although the trim spread is **296×210 mm**.

There were two distinct paths to the extra 6 mm:

- `Planner.bestLayout` uses `2 × trimWidth + sheet.gutter + 2 × reserve`.
  With gutter already 0, its `reserve = max(bleed, cropOffset + cropLength)`
  still added **two 3 mm outer bleed reserves**, producing 302×216. This was
  exterior fit padding, not a 6 mm gap between the fold neighbors. Diagnostics
  repeated the same reserve. Inactive preview crop dimensions could also reserve
  space even after output marks were switched off.
- `Workspace.setMode` independently used `bookletGutter ?? 6` on first entry
  into a booklet mode, overwriting an explicitly entered zero. A second failing
  test reproduced that real-gutter path. It now honors the inspector's manual
  gutter flag on first entry; an already remembered booklet gutter still takes
  precedence, preserving independent per-mode values. **This historical behavior
  is superseded by the fold-neighbor fix below: booklets now always use 0 mm.**

Zero outer margins, zero gripper and all output marks off select an
edge-to-edge booklet fit: the fold now always uses zero gutter, no exterior
mark/bleed reserve inflates the trim spread, and artwork/bleed is clipped to the
physical sheet. The independent cover uses the same rule; its assembled panels
also intersect the template's clipped artwork bounds. The preview and a Turkish
warning identify clipped bleed. Production-mark changes replan only when they
change this booklet fit policy; preview overlay switches remain independent.
The source bleed setting remains 3 mm rather than being silently changed to zero.

Native PDF point serialization can put a nominal 210 mm edge a few millionths
of a millimetre above 210. Full-sheet fit allows **0.0001 mm** numerical slack;
artwork is still clipped to the exact sheet. This is not a 1 mm trim allowance.
The old explicitly requested **6 mm fold-gap** behavior is superseded by the
fold-neighbor fix below; folded paper is now always contiguous.

The real-PDF workspace regression covers import, separate-cover loading, manual
A4/zero settings, output-mark toggling with stale preview crop lengths, save/open,
and export: **27 interior sheets (106 pages + 2 blanks) + 1 cover sheet = 28 A4
sheets / 56 PDF sides**, with zero fold gap. No stored setting was added, so the
schema remains 10.

```sh
swift test --disable-sandbox --filter testA5Booklet106
swift test --disable-sandbox --filter testExplicitZeroGutter
```


## Four-page forms, sewn binding and blank placement — schema 11

### Zero-length crop-mark reserve regression

A failing test first reproduced the exact report: A5 × 106 pages on manual A4
landscape, every margin/gripper/gutter/bleed at zero, crop length zero, saved crop
offset 3.5 mm, export crop enabled (**Açık · Otomatik**). The diagnostic was
**gereken 303.00×217.00; kullanılabilir 290.00×203.00; tabaka 297×210**.

The booklet reserve used `max(bleed, cropOffset + cropLength)` even when length
was zero or export crop was disabled. Thus a nonexistent mark reserved 3.5 mm on
each edge. The fitter compared that padded size against the sheet once; the
*diagnostic* then added the same padding to the required size and subtracted it
from usable space, presenting incompatible dimensions. Crop reserve is now zero
unless export crop is enabled **and** crop length is positive. Required dimensions
include exterior reserve once; usable dimensions exclude only margins/gripper.
Bleed is still accounted for independently, or clipped at the explicit full-sheet
boundary. Inactive crop settings do not require disabling the **Açık** checkbox.
Zero-reserve booklet fits retain 0.0001 mm numerical slack for native PDF point serialization.

Allowing true zero reserve also exposed native bleed crossing between adjacent
signature units on a larger press sheet. Per-unit clips now stop at shared cuts /
gutter midpoints, including shared-plate halves. The existing pixel-level export
corner tests remain active and pass with this protection.

### Four pages / one fold

Choose **Tutkallı cilt** (amerikan cilt) or **Dikişli cilt**, then **Forma → 4 sayfa
(tek kat)**. Existing 8/16/32 options remain. **Otomatik** now also considers 4;
its existing priority remains fewest press sheets, least padding, then the larger
signature. As a result, an old *automatic* choice may improve its blank count
(e.g. 106 pages can need 2 instead of 6 blanks); explicit saved 8/16/32 choices
retain their fold schemes.

A four-page signature starting at reading position `a` has:

```
front: [a+3 | a]
back:  [a+1 | a+2]
```

These independent bifolia are **stacked in signature order**, rather than nested
as saddle-stitch leaves. On an A4 sheet, two A5 panels per face produce four pages
per folded form. On larger stock the existing grid can impose several distinct
forms per press sheet. The sheet list identifies their **Forma 1, 2, …** numbers;
an independently imposed cover is labeled **Kapak**. Preview/export share exactly
the same slots. Sewn binding uses these same 4/8/16/32 folded/gathered forms;
thread-, compression- and sewn-spine calibration is not modeled. The measured
perfect-bound spine formula remains specific to **Tutkallı cilt**.

For 106 interior pages plus a separate four-face cover on fitting A4 stock:
**108 padded interior positions → 2 blanks → 27 four-page forms → 27 interior
sheets + 1 cover sheet → 56 PDF sides**. These counts and blank positions appear
in the summary and sheet list. A measured perfect-bound spine/flaps can make the
cover wider than A4; that still produces a genuine fit error and blocks export.
The program never shrinks a spine or switches stock silently to force a fit.

### Boş sayfalar nereye

The **Boş sayfalar** inspector applies to saddle stitch, perfect binding and sewn
binding:

- **Sona** is the default, including when older project files omit the setting.
- **Başa** places all padding before the first selected interior PDF page.
- **Elle seç** shows a checkbox list of the final padded **İç okuma sırası** in
  the source sidebar. Select the required number of blank positions. Positions
  are one-based final interior reading positions, after cover extraction; they
  are not original PDF page numbers. The rows show both the reading position and
  source PDF/page. Manual choices are remembered when switching placement modes.

Required padding still comes from the signature size; this setting moves those
blanks, not arbitrary extra pages. Duplicate, out-of-range or incomplete manual
selections block export. A provisional preview keeps every source page and puts
unassigned blanks at the end, labeled **Boş (geçici)** in the chooser. The project
intent is never silently rewritten. **Seçimi temizle** lets a stale selection be
replaced after a signature/page-count change. The existing reject-blank policy
remains effective; the inspector offers an explicit action to permit padding.

Only generated blank slots are introduced; linked source PDFs and their page
metadata/order are not modified. `Project.blankPlacement` persists placement mode
and manual positions in schema **11**. Schemas **1–10** remain readable, defaulting
to end padding. Four-page signature and sewn mode values also roundtrip. Derived
logical page indices, blank locations, form counts and PDF-side counts are rebuilt
by the planner, including after source relinking.

Tests include the original failing mark-offset case, the positive-mark reserve
comparison, exact four-page face order, an independent physical fold-and-stack
simulation for both bindings, **every pair** of manual blank positions in a
12-position book, start/end placement, invalid-position validation, automatic-4
selection, 106-page separate-cover vector PDF export in all three blank modes,
active UI-model changes, schema-11 roundtrips, and schema-10 defaults. Existing
8/16/32 fold, pixel/rotation, bleed, export, serial/QR, gang and save/open tests
remain. The old unsupported-binding assertion now covers spiral/wire-O; sewn is
covered by positive folding/export tests. The complete suite has **194 tests**.

```sh
cd /Users/baturayatis/Developer/AtisPressCore
swift run --disable-sandbox AtisPressApp
swift test --disable-sandbox
swift test --disable-sandbox --filter SignatureFourTests
./scripts/build_app.sh
open "dist/AtışPress.app"
```

## Hizalama ve tüm düzen ayarlarını sıfırlama (schema 12)

Yeni uygulama oturumu ve **Yeni Proje**, **Hizalama → Ortala** ile başlar.
Ürünler, ara boşluklar ve simetrik dış kesim işareti rezervinden oluşan blok,
kenar boşlukları ve maşa payı çıkarılmış kullanılabilir alanın iki ekseninde
ortalanır. Maşa payı yalnız bir kez çıkarılır. Örneğin 480×330 mm tabakada,
10 mm kenarlar, alt maşa 0, sıfır ara boşluk ve 86,7×54 mm ürünün 5×5 düzeninde
kesim bloğu **x=23,25, y=30 mm** konumundadır; kullanılabilir alanda sağ/sol
13,25 mm ve üst/alt 20 mm boşluk kalır.

**Maşa kenarına yasla**, önceki yerleşim algoritmasını aynen korur. Hizalama
alanı bulunmayan eski `.atispress` dosyaları bu davranışla açılır; mevcut
otomatik ayar metadatasında hizalama manuel işaretlenir. Dosyayı açmak yeniden
otomatik yerleşim başlatmaz. Şema **12**, hizalamayı ve otomatik/manuel sahipliğini
kaydeder; **1–11** sürümleri okunur. Çekirdek API'nin eski `Project` kurucusu da
hizalama belirtilmezse eski davranışı korur; yeni uygulama projeleri açıkça
`center` seçer.

Ön/arka yerleşimler aynı fiziksel kesim konumlarını paylaşır. Work-and-turn ve
work-and-tumble için aynı kalıbın iki yüzü, çevrilen eksendeki kullanılabilir
alanların simetrik kesişiminde ortalanır; bu baskı hizalaması için gereklidir.
Seri/QR konumları kesim köşesine bağlıdır; kesim işaretleri, bilgi şeridi ve renk
kontrolleri yeni blok konumunu izler. Yer bulamayan bilgi/renk kontrolleri mevcut
uyarılarla atlanır. Karışık işte otomatik blok bütünü ortalanır; elle sürüklenen
blokların açık koordinatları korunur. Yeniden otomatik yerleştirme bu blokları
çözücüye geri verir.

**Otomatik düzenle**, sabit/en-verimli tabaka politikasını da **Otomatik** yapar;
tabaka, yön, dört kenar, maşa, ara boşluk/dizilim, taşma üretimi, çıktı işaretleri,
döndürme, satır/sütun sınırları ve hizalamayı tekrar hesaplar. Manuel ayar varsa
**“Elle yapılan ayarlar sıfırlanacak.”** onayı gösterilir. İptal projeyi değiştirmez.
Adet/fire, kaynaklar, sayfa/kapak seçimi, ölçülmüş kâğıt kalınlıkları ve seri
alanları korunur. **Manuel** etiketli alanların yanındaki **Otomatik'e dön** yalnız
ilgili alanın manuel sahipliğini kaldırır; diğer manuel değerleri korur.

SRA3 yatayda 86,7×54 mm kart dönüş regresyonu önce başarısız testle üretildi:
L1'de 5 mm kesim çizgisi + 3,5 mm uzaklık iki kenarda toplam 17 mm ayırıyordu;
450−17=433 mm, dik 5 sütunun 433,5 mm enini dışarıda bırakıyordu. Böylece yalnız
90° 8×3=24 seçiliyordu. Otomatik çözücü artık rahat uzaklığın yanında taşmanın
dışında en az 0,1 mm (ve çizgi yarı kalınlığından fazla) güvenli mesafeyi de
karşılaştırır; bu örnekte 3,1 mm uzaklıkla 5×5=25 dik sığar. Eşit kapasitede dik,
eşit yön/kapasitede rahat işaret mesafesi tercih edilir. Manuel kesim uzaklığı
asla azaltılmaz; gerçekten sığmayan 25'li düzen zorlanmaz.

Doğrulama: **206 test**; iki eksende 0,01 mm merkezleme, maşa payının tek sayımı,
eski konum/şema göçü, tüm çevirme/maşa kombinasyonları, döndürülmüş kitap
arkası, karışık blok merkezleme, reset onay/iptali ve tek-alan reseti kapsanır.
Vektör seri çıktı testi her iki hizalamada PDF metni/konumu ve önizleme piksellerini
karşılaştırır; renk kontrol/bilgi şeridi testi blokla taşınmayı ve arka hizasını
denetler. Fiziksel baskı kaydı yine prova ile doğrulanmalıdır.

```sh
cd /Users/baturayatis/Developer/AtisPressCore
swift run --disable-sandbox AtisPressApp
swift test --disable-sandbox
swift test --disable-sandbox --filter Alignment
./scripts/build_app.sh
open "dist/AtışPress.app"
```


## Yeni proje / A5 106 sayfa / A4: kat komşuları daima bitişik

Önce başarısız bir gerçek-PDF akış testi eklendi: yeni Tekrarlı proje → 106 A5
sayfa içe aktar → Tel dikiş veya Tutkallı cilt → manuel yatay A4, kenarlar/maşa/
taşma 0 ve işaretler kapalı. Ara boşluk elle düzenlenmedi. Test ilk durumda
**Ara boşluk = 6 · Manuel** ve **gereken 302×210; kullanılabilir 297×210**
hatasını yeniden üretti.

Kök neden üç parçalıydı: `Workspace.setMode` ilk kitapçık geçişinde
`bookletGutter ?? 6` atıyordu; proje değişiklik izleyicisi bu programatik
atamayı manuel ara boşluk düzenlemesi sayıyordu; çekirdek aynı değeri katın iki
komşu sayfası arasına koyarak **148 + 6 + 148 = 302 mm** hesaplıyordu.
`SmartAutoLayout` da kitapçıklarda `2 × bleed` ile 6 mm'yi tekrar üretebiliyordu.

Artık kitapçık planının tüm kat komşuları **0 mm** aralıklıdır: yerleşim, kat
çizgileri, taşma kırpma ve sığma hata ölçüleri aynı bitişik geometriyi kullanır.
Eski dosyadaki pozitif ara boşluk da katı açamaz. Denetçi kitapçıkta düzenlenebilir
ara boşluk yerine **“Kat komşuları: 0 mm (sabit)”** gösterir. Moda geçiş manuel
ayar olarak kaydedilmez. Tekrarlı ve gang değerleri ayrı ayrı hatırlanır; kitapçık
hiçbirine ara boşluk kopyalamaz ve onlardan kat aralığı devralmaz. Eski
`bookletGutter` JSON alanı okunabilirlik için tutulur ama yerleşimde kullanılmaz;
yeni bir ayar/şema eklenmedi (şema 12).

Doğrulama: **211 test geçti**. Yeni akış her iki ciltlemede **27 A4 tabaka / 54 PDF yüzü**, 2 boş
sayfa ve 296×210 mm bitişik açılım üretir. 4/8/16/32/otomatik forma ve bütün
çevirme yöntemlerinde eski pozitif gutter planı, sıfır gutter planıyla aynıdır.
Düz/gang değerlerinin kitapçık geçişleri ve kaydet/aç sonrasında ayrı kalması da
test edilir. Önceki testler kaldırılmadı; 6 mm kat boşluğunu bekleyen üç eski
beklenti yeni bitişik kat kuralına güncellendi.

```sh
swift test --disable-sandbox
swift test --disable-sandbox --filter FoldGutter
swift test --disable-sandbox --filter testNewProjectImport106A5ThenBookletOnManualA4HasNoFoldGutter
```

## Spiral / Wire-O — katlamasız yaprak düzeni (şema 13)

**Yerleşim Yöntemi → Spiral / Wire-O**, forma yerine ardışık ön/arka yapraklar
oluşturur: 1/2, 3/4, … . Tek sayıda sayfa varsa yalnız **1 boş arka sayfa** eklenir;
boş ekleme yasaksa çıktı engellenir. Forma, creep, kâğıt kalınlığı ve sırt hesabı
bu modlarda uygulanmaz; saklanan kitap ayarları değişmeden kalır.

Aynı düz iş ızgarası, 0°/90° dönüş, taşma, ara boşluk, kenarlar, maşa, hizalama
ve vektör çıktı kullanılır. Yapraklar aynı kesim konumundaki tabakaları bir yığın
olarak alıp, yığınları ızgara/kopya sırasıyla üst üste koyduğunuzda 1…N okunacak
şekilde dağıtılır: `yaprak = yuvaSırası × tabakaSayısı + tabakaSırası`.
Kapasiteyi aşan son yuvalar boş bırakılır; bunlar yayına eklenmiş boş sayfa
sayılmaz. Yan çevirme/takla aynı kalıpta iki aynı takım üretir; özet fiziksel
yaprak kapasitesini ve takım sayısını gösterir. Kesim/istif yönünü fiziksel
prova ile doğrulayın. Bu modda bir seçili PDF bir yayın takımıdır; düz işin Adet/
fire/seri alanları bu yayına uygulanmaz ve bu modda düzenlenemez.

**Yaprak cilt: katlama yok** bölümünde:

- **Cilt kenarı: Sol / Üst / Sağ**. Arka yüzde kenar, seçilen çevirme ve ürün
  dönüşü sonrası önle aynı fiziksel kenardır; sıradan bir PDF-sol etiketi değildir.
- **Cilt payı (mm)** kullanıcı girdisidir. Girilmemiş değer 0 gösterilir ve uyarır.
  PDF kesim ölçüsü ve artwork doğal ölçeğinde korunur; güvenli alan cilt kenarında
  bu miktar kadar daha içeri alınır. Turuncu cilt sınırı ve güvenli alan önizlemede
  değişir. Kaynak tasarımın bu alanı boş bırakması gerekir; uygulama artwork'ü
  silmez, beyaza boyamaz veya sayfayı büyütmez. Pay sayfayı tüketirse çıktı engellenir.
- **Delik işaretlerini çıktıya ekle** başlangıçta kapalıdır. Delik aralığı, çapı
  ve kenardan uzaklık için varsayılan/pitch standardı tahmin edilmez. Üçünü de mm
  olarak girin. Delik merkezleri girilen aralıkla kenar boyunca ortalanır; uzaklık
  kesim kenarından **dışarıya** doğrudur. Bunlar boş baskı kenarındaki delme
  kılavuzlarıdır; kaynak artwork, üretilmiş taşma veya komşu ürün üzerine basılmaz.
  Sığmayanlar uyarıyla atlanır. Bir kenarda 1000, bir yüzde 50.000 kılavuz sınırı
  vardır. Çaplar gerçek mm'dir; daireler 0,25 pt vektör çizgidir, raster görüntü
  oluşturulmaz. Önizlemenin **Delik kılavuzları** anahtarı çıktıyı etkilemez.
- **Kapak modu**: Dahil bütün seçili sayfaları yayında tutar; **Hariç — ayrı bas**
  seçilen ön/arka kapak sayfalarını iç bloktan çıkarır. **Ayrı PDF** mevcut güvenli
  dosya/bookmark ve yeniden bağlama akışını kullanır. Ön ve arka kapaklar kendi
  yaprakları olarak, boş iç yüzleri ve aynı cilt kenarı kuralıyla bağımsız basılır.
  Kapakların ölçüleri kendi ızgaralarında ele alınır; yayının iç sayfaları eşit
  ölçüde olmalıdır. Özet/listede yaprak, tabaka, kapasite ve eklenen boşlar görünür.

Şema **13**, `project.leafBinding` içinde kenar, girilmiş/girilmemiş cilt payı,
delik görünürlüğü, aralık, çap ve uzaklığı saklar; kapak seçimi ve PDF bağlantıları
mevcut kitap alanlarıyla saklanır. Şema **1–12** açılır; yeni alan yoksa hiçbir
pay veya delik ölçüsü uydurulmaz. Eski düz/kitap/gang projelerinin planı korunur.
Yaprak modu gerekli boş arka yüzleri korur; mevcut düz iş boş-arka kuralları değişmez.

Doğrulama: **222 test geçti** (98 çekirdek, 55 PDF, 69 uygulama).
Testler: iki bağlama ve üç çevirme yönteminde bağımsız kes–istifle simülasyonu,
tek boşla çift sayfaya tamamlama, cilt kenarı/maşa yansıması, değişen güvenli alan,
tam aralık/çap/uzaklık, sığmayan deliklerin atlanması, ayrı kapak, şema 13 ve eski
şema açma, önizleme/PDF delik piksel eşleşmesi, vektörlük ve her PDF yüzündeki
sayfa metninin planla eşleşmesi. Önceki testler kaldırılmadı; Spiral/Wire-O'nun
artık desteklenmediğini varsayan eski beklenti olumlu yaprak doğrulamasına çevrildi.

## Yeni ikon ve Finder proje ilişkilendirmesi

Varsayılan ikon artık programatik çizilmiş koyu lacivert yuvarlatılmış kare,
beyaz katlanmış sayfa/forma ızgarası ve küçük turkuaz vurgudur. Kaynak
`scripts/generate_app_icon.swift`, on adet 16–1024 piksel temsilli `.icns` üretir.
`./scripts/build_app.sh` bunu **dist/AtışPress.app/Contents/Resources/AppIcon.icns**
konumuna yazar. Kendi ikonunuz için **packaging/AppIcon.icns** koyup yeniden
paketleyin; bu dosya varsa üretecin yerine kullanılır.

Info.plist, aynı `com.atispress.project` UTI'sini `public.json` alt türü,
`.atispress` uzantısı, belge ikonu ve MIME türüyle dışa aktarır. Belge rolü
**Editor**, sırası **Owner**'dır. Native `application(_:open:)` ile SwiftUI
`onOpenURL` aynı kuyruğa bağlanır: açılışta pencere hazır olmadan gelen dosyalar
saklanır; çalışan uygulamaya gelenler mevcut Kaydet/Aç onay akışından geçer.
Aynı native olayın çift teslimi tekilleştirilir. Plist ve iki URL teslim yolu
test edilir. Paketleme, mevcutsa `lsregister -f` çalıştırır.

Bu ortam LaunchServices kaydını engelleyebilir (`-10822`). Finder entegrasyonunun
elle kontrolü:

```sh
./scripts/build_app.sh
ditto "dist/AtışPress.app" "/Applications/AtışPress.app"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "/Applications/AtışPress.app"
open "/Applications/AtışPress.app"
```

Finder'da kayıtlı bir `.atispress` dosyasına uygulama kapalıyken çift tıklayın;
kaydedilen ayarların ve önizlemenin geldiğini kontrol edin. Uygulamayı açık
bırakıp başka bir projeye çift tıklayın; aynı çalışan uygulamada açıldığını,
değişiklik varsa Kaydet/İptal akışını kontrol edin. İlişkilendirme önceden başka
uygulamaya verilmişse **Bilgi Ver → Birlikte Aç → AtışPress → Tümünü Değiştir**
seçin. Ad-hoc imzalı paket notarize değildir; gerekirse sağ tık → Aç yöntemini
kullanın. Bu iş fiziksel delme kalıbı/CAD çıktısı veya makineye özel delik standardı
üretmez; kılavuzlar mutlaka üretim provasında doğrulanmalıdır.

```sh
cd /Users/baturayatis/Developer/AtisPressCore
swift run --disable-sandbox AtisPressApp
swift test --disable-sandbox
swift test --disable-sandbox --filter Leaf
./scripts/build_app.sh
open "dist/AtışPress.app"
```

## Cilt payı davranışı — Koru / Küçült / Kaydır (şema 14)

Spiral/Wire-O'nun **Yaprak cilt** bölümünde **Cilt payı davranışı** seçilir.
Ayrı kapaklar da aynı davranışı kullanır. Dönüşüm çekirdekte cilt kenarı/payını
bildiren sayfa yuvasına uygulanır; katlama/creep/sırt hesaplarıyla karıştırılmaz.
Şu anda bağımsız cilt payı sunan modlar Spiral ve Wire-O'dur.

- **Koru** varsayılandır. Artwork doğal ölçeğinde ve konumunda kalır; önceki
  projelerin görünümü korunur. Güvenli alan/turuncu cilt kılavuzu değişmez.
- **Küçült**, bütün sayfayı mevcut güvenli alana **tek bir ölçek katsayısıyla**
  sığdırır. Katsayı `min(1, güvenliEn / sayfaEn, güvenliBoy / sayfaBoy)` olur.
  Sayfa cilt kenarının karşı kenarına yaslanır, diğer eksende ortalanır.
  Örneğin A4 (210×297), sol cilt payı 12 mm ve diğer güvenli alan payı 0 için
  `198 / 210 = 0,942857…` yani **%94,29 ölçek**; sayfa 198×280,029 mm olur.
  Genel güvenli alan payı 5 mm ise kullanılabilir en 188 mm ve ölçek **%89,52**
  olur. Genel güvenli alan da hesaba katılır; hiçbir durumda sayfa büyütülmez.
- **Kaydır**, sayfayı ölçeklemeden cilt kenarından uzaklaşan yönde tam cilt payı
  kadar taşır. Yeni konumda artwork eski kesim kutusuna veya güvenli alana
  kırpılmaz. Kesim/katlama/delik kılavuzları sabit kalır. Komşu ürünle çakışma
  veya tabaka sınırı aşımı uyarılır; düzen kendiliğinden düzeltilmez. Tabaka dışı
  içerik fiziksel boyutu sabit PDF sayfasına sığamaz ve çıktı sayfa sınırında
  kesilir; bunun için daha büyük tabaka/kenar payı gerekir. Bu uyarı tek başına
  çıktıyı engellemez.

Özet ve tabaka listesi ölçeği veya mm kaydırmayı gösterir. Ön/arka çevirme,
ürün dönüşü ve cilt kenarı, **fiziksel tabaka koordinatlarında** birlikte
hesaplanır. Kaydırma/ölçek arka yüzde de aynı fiziksel taraftadır. Kaynak PDF
sayfasının konum dönüşümü uygulanır: yüksek yakınlaştırma, düşük yakınlaştırma
önizleme raster önbelleği ve vektör PDF aynı planı kullanır. Sayfa rastere
çevrilerek dışa aktarılmaz; kaynak metin vektör metin olarak kalır. Mevcut taşma
üretimi de sayfa ile birlikte taşınır/ölçeklenir; kesim ve güvenli alan kılavuzları
hareket etmez. Renk/işaret/şerit koruma geometrisi yeni artwork alanını kullanır.

**Koru şerit kontrolü:** sıfırdan büyük cilt payında ilgili kaynak sayfanın cilt
şeridi arka planda beyaz üzerine render edilerek beyaz olmayan içerik aranır.
Ön/arka yerel kenarlar ve PDF'nin dönüşü hesaba katılır. Aynı şerit tekrar
hesaplanmaz; sonuç kaynak başına sınırlı önbellekte tutulur. Bulunan sayfalar tek
uyarıda listelenir; okunamayan şerit **kontrol edilemedi** olarak bildirilir.
Aynı denetim doğrudan PDF dışa aktarımında da çalışır ve sonuç çıktı notlarına
eklenir. Kontrol uyarıdır, çıktı engeli değildir.

Bu kontrol en fazla **1024×128 piksel** örnekler; beyaza çok yakın veya çok ince
ayrıntıları kaçırabilir. Transparan içerik beyaz üzerinde değerlendirilir; bu bir
matbaa sertifikasyonu, içerik silme veya boş alan garantisi değildir. Fiziksel
prova gerekir. Kaydır'da komşu artwork üzerindeki çakışmalar otomatik kırpılmaz;
uyarıyı gidererek üretime geçin.

`.atispress` şeması **14**: davranış `leafBinding.placementBehavior` olarak
saklanır. Alanı olmayan **1–13** sürümleri **Koru** ile açılır. Sayfa dönüşümleri,
şerit denetimi ve yerleşim özetleri kaynak/ayarlar üzerinden tekrar üretilir;
kaynak dosyalar değiştirilmez.

Doğrulama: **230 test** geçti. A4 + 12 mm ölçeği ve güvenli alan payı, bütün cilt
kenarları/çevirme/maşa kombinasyonlarında arka yüz eşleşmesi, kırpılmadan kayma ve
taşma uyarısı, dolu/boş şerit ayrımı ve bilinmeyen sonuç, vektör metin konumu ve
font ölçeği, düşük/yüksek yakınlaştırma ile PDF eşleşmesi, canlı uyarılar ve her
üç davranışın kaydet/aç turu kapsanır. Mevcut testler korunmuştur.

```sh
cd /Users/baturayatis/Developer/AtisPressCore
swift run --disable-sandbox AtisPressApp
swift test --disable-sandbox
swift test --disable-sandbox --filter Binding
./scripts/build_app.sh
open "dist/AtışPress.app"
```

## Otomatik kurtarma, Geri Al/Yinele ve Hazır ayarlar — şema 15

### Otomatik kayıt ve çökme kurtarması

Gerçek uygulama açılışında kurtarma servisi etkinleşir. Değişmiş proje **30
saniyede bir**, ayrıca ayar değişikliklerinden **900 ms** sonra otomatik kaydedilir.
Kaydedilmemiş yeni proje de buna dahildir; kaynak PDF'nin yolu, bookmark'u ve
varsa çoklu PDF/kapak kataloğu kayda girer. Kayıt PDF'yi gömmez veya değiştirmez.
Kullanıcının `.atispress` dosyası yalnız açık **Kaydet/Farklı Kaydet** işlemiyle
yazılır; otomatik kayıt bu dosyanın üstüne hiçbir zaman yazmaz.

Kurtarma dosyaları atomik JSON olarak aşağıda tutulur:

```
~/Library/Application Support/AtisPress/Recovery/<proje UUID>.recovery.json
```

Proje kimliği normal kaydet/aç boyunca korunur. Yeni proje/PDF değişimi yeni bir
kimlik başlatır; kullanıcı eski değişiklikleri saklama/silme kararını mevcut
onay akışında verir. Normal kaydetme ve onaylanmış pencere kapatma/çıkış, aktif
projenin kurtarma dosyasını temizler ve bekleyen yazmayı iptal eder. Save panelinin
iptali veya uygulamanın çıkış onayının iptali kurtarma kaydını silmez.

Çökme/force quit sonrası dosya kalır. Bir sonraki açılışta **“Kurtarılan proje
bulundu”**, **Geri yükle / Sil** gösterilir. Geri yükleme kaynakları mevcut
Aç/yeniden bağlama doğrulamasıyla okur ve projeyi değiştirilmiş olarak açar.
Kayıtlı projeyse normal Kaydet özgün proje dosyasına gider; hiç kaydedilmemişse
Kaydet ad ister. Birden çok eski kayıt varsa en yenisi önce sunulur; geri
yüklenmeyen diğer kayıtlar kendiliğinden silinmez. Bozuk/desteklenmeyen kayıtta
hata gösterilir, dosya otomatik silinmez.

Sınırlar: son 900 ms'lik henüz kayda geçmemiş düzenleme çökmede kaybolabilir.
Kaynak PDF dosyaları hâlâ gereklidir; kayıp/değişmiş dosyalar yeniden bağlanır.
Kurtarma bir sürüm arşivi veya çok pencereli belge sistemi değildir; uygulamanın
mevcut tek çalışma alanını korur.

### Düzenle → Geri Al / Yinele

**⌘Z / ⇧⌘Z**, proje ayarları, kaynak sayfa dahil etme/sıralama, iş düzenlemeleri,
seri/QR alanları, hazır ayar uygulama ve manuel blok hareketlerini geri alır /
yineler. İşlem öncesi proje durumu, PDF kaynak kataloğu ve ayar sahiplikleri
birlikte saklanır; plan tek planlayıcıyla yeniden üretilir. Önizleme aynı
planı kullanır. Geri alma kaydedilmiş dosyayı yazmaz; gerektiğinde projeyi yeniden
“değişmiş” yapar.

Ana penceredeki metin/sayı alanları native düzenleme başlangıcı/bitişiyle tek
adımda birleşir; yazarken türeyen basamak/adet düzeltmeleri de aynı adımdadır.
Odak bildirimi olmayan programatik girişler **650 ms** duraklamaya kadar birleşir. Farklı alan, checkbox, yöntem değişimi veya sayfa seçimi ayrı
adımdır. Seri/QR ya da blok sürüklemesi açık fare-bas/fare-bırak sınırlarıyla,
süresi ne olursa olsun **tek adım** olur. Düzenleme geri alınmadan önce etkin
metin alanı tamamlanır. Yalnız görünümde tabaka/ön-arka gezinmesi geçmişe girmez.
Yeni Proje, yeni ana PDF ve Proje Aç bir geçmiş sınırıdır; mevcut işlere eklenen
PDF'ler ve kapak değişimleri proje düzenlemesi olarak geri alınabilir.

Geçmiş oturum içindir, `.atispress` içine yazılmaz; son **100 tamamlanmış adım**
tutulur. Hazır ayar kitaplığının adlandırma/silme işlemleri proje geçmişinden
ayrıdır; hazır ayarın projeye uygulanması ise tek geri alma adımıdır.

### Hazır ayarlar

Denetçideki **Hazır ayarlar** bölümü ve aynı adlı menü: **Hazır ayar uygula**,
**Yeni hazır ayar kaydet**, yeniden adlandırma, çoğaltma, silme ve paket
ithalat/ihracatı sunar. Kitaplık JSON sürümü 1'dir:

```
~/Library/Application Support/AtisPress/Presets/library.json
```

İlk kullanımda dört örnek eklenir; kullanıcı bunları silebilir ve silinenler
sonraki açılışta yeniden eklenmez:

- Kartvizit 33x48 ofset
- A4 form dijital
- A4 spiral form
- Amerikan cilt A5 forma 4

Hazır ayar alanları açık bir izin listesiyle saklanır: yöntem/ciltleme, forma ve
çevirme, tabaka/yön/hizalama, marj/maşa/ara boşluk, satır/sütun/döndürme tercihleri,
taşma ve üretimi, kılavuzlar/çıktı işaretleri, renk skalası/dizler, iş bilgi şeridi,
Dijital/Ofset ve cilt payı/davranışı. Taşma kırpma ve sayısal sığma toleransı da
aynı görünümü korur. **Kaynak PDF/bookmark, sayfa seçimi/sırası, adet/fire, seri/QR
alanları ve işlerin PDF kimlikleri kaydedilmez veya uygulanırken değiştirilmez.**
Kapak PDF rol seçimi ve ölçülmüş kitap kâğıdı girdileri de hedef projede kalır.
Gang'a uygulamada mevcut işler korunur; ortak taşma/taşma üretimi/dönüş tercihleri
uygulanır ve bloklar otomatik planlanır.

Uygulanan değerler **Hazır ayar** etiketlidir, **Manuel** değildir. Sonraki PDF
ithalatı bu değerleri sabit kabul eder; alanı elle değiştirmek o alanı Manuel
hale getirir. **Otomatik düzenle**, önceki davranış gibi işin yöntemini/kâğıt
ölçümlerini/adet/seri içeriğini koruyarak bütün yerleşim alanlarının sahipliğini
sıfırlar ve yeniden hesaplar; hazır ayar bayrakları da temizlenir.

Taşınabilir **.atispresetpack** dosyası sürümlü JSON'dur. Paket içe aktarma mevcut
kitaplığı değiştirmeden yeni kimliklerle kopyalar ekler; geçersiz veya gelecek
sürüm paketi mevcut kitaplığı değiştirmez. Bunlar üretim başlangıç örnekleridir;
makinenizin maşa, cilt payı ve kâğıt gereksinimlerini kontrol edin. Örneğin spiral
hazır ayarı ölçülmemiş cilt payı için değer uydurmaz; girilene kadar 0 ve uyarı
kalır.

`.atispress` şeması **15**, isteğe bağlı proje kimliğini ve hazır ayar alan
sahipliğini saklar. **1–14** projeleri açılır; kaynaklar, mevcut yerleşim ve
ayarlar korunur. Eski dosyaya ilk açılışta kimlik atanması tek başına projeyi
“değişmiş” yapmaz.

Doğrulama: **239 test**. Kurtarma dosyası ve kaynaklarının geri yüklenmesi,
kullanıcı dosyasının değişmemesi, debounced ve periyodik kayıt, temiz kapanıştan
sonra dosyanın kalmaması, gang katalog/seri/blok kurtarması; ayar/sayfa/seri/iş
undo-redo plan eşitliği, uzun sürüklemenin tek adımı, yazı gruplama ve checkbox
ayrımı; hazır ayar uygulama/geri alma/kaydetme, CRUD/paket turu, kaynak/adet/fire/
seri korunması, dört örneğin adlandırdığı ürüne sığması ve eski şema doğrulanır.
Mevcut testler korunmuştur; sürüm sabiti kullanan beklentiler şema 15'i izler.

```sh
cd /Users/baturayatis/Developer/AtisPressCore
swift run --disable-sandbox AtisPressApp
swift test --disable-sandbox
swift test --disable-sandbox --filter EditingServicesTests
./scripts/build_app.sh
open "dist/AtışPress.app"
```

## Fiyatlar, iş maliyeti ve teklif — şema 16

Çalıştırma: `swift run --disable-sandbox AtisPressApp`. Araç çubuğunda veya
**Fiyatlar** menüsünde **Fiyatlar** ve **İş maliyeti** pencerelerini açın.
Fiyat kitaplığı ilk kullanımda **boştur**; parasal değer veya vergi/kâr oranı
üretilmez. Boş fiyatlar **girilmedi** gösterir ve toplam/satış/teklif sonucunu
engeller. Ücretsiz bir kalem için açıkça **0** girin.

**Fiyatlar** penceresinde kâğıt adı, gramaj, mm tabaka ölçüsü, tabaka/1000 tabaka
fiyatı ve KDV dahil/hariç seçilir. Dijital ön ve arka fiyatları ayrıdır. Ofset
fiyatı kalıp başına, hazırlık/ayar **kalıp takımı başına**, baskı ise **1000 tabaka
geçişi başına** girilir; renk sayısı kullanıcı girdisidir. Baskı/işçilik fiyatları
KDV hariçtir. Kesim, katlama, tutkal, spiral, tel, seri numara ve ambalaj
kalemlerini adet/tabaka/iş birimiyle ekleyin. **Kâr marjı** burada maliyet üzerine
eklenen yüzdedir (`maliyet × yüzde / 100`); satıştan geriye hesaplanan brüt marj değildir.

Kitaplık sürümlü (v1), atomik JSON olarak saklanır:

```
~/Library/Application Support/AtisPress/Prices/library.json
```

**Tablo dışa aktar / içe aktar**, tam kitaplığı ve oranları taşır. İçe aktarma
kitaplığı değiştirir; bozuk/gelecek sürüm mevcut kitaplığı bozmaz. Önce dışa
aktarıp yedek alabilirsiniz. Kitaplık değişince açık maliyet penceresi güncellenir.

**İş maliyeti** bu `.atispress` projesinin teklifidir. Kâğıt, Dijital/Ofset ve ek
işlemler seçilir. **bu işe özel**, seçilen satırın proje içinde bağımsız kopyasını
oluşturur; düzenlemek fiyat tablosunu değiştirmez. Anahtar kapatılırsa tekrar
kitaplık fiyatı kullanılır. İşe özel kâr/KDV boşsa kitaplık oranı kullanılır;
ikisi de boşsa sonuç engellenir. Normal bağlantılı fiyatlar kitaplıktan canlı
okunur; taşınabilir sabit teklif için ilgili fiyatları işe özel yapın.

Hesap gerçek planın `repeatCount` toplamını kullanır; mevcut adet/fire hesabına
ikinci kez fire eklemez. **Ek fire tabakası** ayrıca girilebilir. Dijital baskı
sadece üretimde bulunan ön/arka yüz geçişlerini ücretlendirir. Ofset kalıp sayısı
renk × bağımsız kalıp yüzüdür; yan çevirme/taklada aynı takım ikinci kez sayılmaz.
Hazırlık her bağımsız takım için, baskı iki yüz geçişlerinin toplamına uygulanır.
Adet işçiliği istenen adet + plandaki fire kopyalarına, tabaka işçiliği toplam
fiziksel tabakaya, iş birimi bir kez uygulanır. Kitap/yaprak modlarının mevcut
planı tek yayındır: maliyet için **Yayın adedi** ayrıca girilir; önizleme ve üretim
PDF'si mevcut tek yayın planı olarak kalır. Karışık işte ortak kâğıt/baskı bir kez,
adet işçiliği işlerin toplam üretim adedine uygulanır. Aynı proje içindeki gang
alt işlerine ayrı kâğıt/press tarifesi veya maliyet paylaştırması yapılmaz;
ayrı teklif tarifeleri için ayrı proje kullanın.

Her kalem kuruşa yuvarlanır; maliyet kalemlerin toplamıdır. Kâr, ardından net
satışın KDV'si iki ondalığa yuvarlanır. Adet fiyatı KDV dahil satış / müşteri
adedidir. KDV dahil kâğıt fiyatı girilen KDV oranıyla netleştirilir. Kalemlerdeki
net birim fiyat hesap içinde hassasiyetini korur, ekranda iki ondalık gösterilir.

**Tabaka karşılaştır**, A3, SRA3, 33×48, 35×50, 50×70 ve 70×100 için mevcut
manuel kısıtları koruyarak aynı otomatik L1–L4 düzenleyiciyi çalıştırır. Seçili
kâğıdın **aynı ad/gramajdaki** tablo satırları değerlendirilir. Fiyat bulunmayan
ölçüler **fiyat yok** olarak listelenir; geçersiz plan/eksik baskı fiyatı da
kazanan olamaz. En düşük KDV dahil toplam işaretlenir. **Uygula**, karşılaştırılan
proje geometrisini ve kâğıt seçimini birlikte uygular. Sonraki değişiklik eski
karşılaştırmayı temizler. Bu mevcut düzenli ızgara/gang planlayıcısının aramasıdır;
keyfi nesting veya makine kapasitesi optimizasyonu değildir.

**Teklif PDF’i** tek A4 sayfada vektör metin içerir: isteğe bağlı firma/logo,
iş adı, tarih, ürün ölçüsü, adet, kâğıt, baskı/cilt, KDV dahil adet/toplam fiyatı,
KDV, kullanıcı tarafından girilen geçerlilik ve not. **Ayrıntılı maliyet dökümünü
ekle** varsayılan kapalıdır; açılmadıkça maliyet ve kâr PDF'ye yazılmaz. Logo
PNG/JPEG/PDF olabilir; bitmap logo kendi doğasında bitmap kalır. Uzun içerik 8 pt
altına küçültülmez; tek sayfaya sığmıyorsa hata verir, sessizce kesmez. Geçerlilik
ve tam maliyet girilmeden teklif yazılamaz. Kaynak PDF/proje üzerine yazılmaz.

Şema **16**, `project.costing` altında fiyat bağlantıları, işe özel kopyalar,
oranlar, yayın adedi/ek fire ve bütün teklif ayarlarını (logo verisi dahil)
saklar. **1–15** projeleri aynı planla açılır; maliyet alanları girilmemiştir.
Mevcut undo/redo, kurtarma ve kaydet/aç akışları bu proje alanını da kapsar.

Doğrulama:

```sh
swift build --disable-sandbox
swift test --disable-sandbox
swift test --disable-sandbox --filter CostingTests
swift test --disable-sandbox --filter PricingPersistenceTests
swift test --disable-sandbox --filter QuotePDFTests
```

Yeni testler bilinen fiyatlarla tabaka/fire, ön/arka, kalıp/ayar, adet işçiliği,
kâr/KDV/kuruş, eksik fiyat engeli ve açık sıfır, bağımsız override, en ucuz tabaka,
kitaplık disk/ithalat/ihracat, proje kaydet/aç/eski şema ve PDF'de varsayılan gizli
maliyetleri kapsar. Teklif PDF'si render edilerek Türkçe karakterler ve tek sayfa
akışı kontrol edildi. Yeni pencerelerin tam masaüstü etkileşim turu yapılmadı.

Son doğrulama: **249 XCTest testi, sıfır hata** (109 çekirdek, 59 PDF, 81 uygulama).
Mevcut testler korunmuştur; kurtarma testindeki sabit şema 15 beklentisi güncel
şema sabitine bağlanmıştır. Derleme ve `git diff --check` temizdir.

## Kapak sırası, sürekli önizleme, hedef ebat ve seri aralıkları — şema 17

12 sayfalık A4 tel dikiş işindeki kapak hatasının nedeni, `BookPlanner`ın
kapak yüzlerini iç bloktan ayırdıktan sonra bağımsız kapak tabakasını **sona**
eklemesiydi. İç bifoliaların kendi sırası doğruydu. Üretim tabakaları artık
kapak/dış tabaka önce gelecek biçimde sıralanır; doğrulama referansları da aynı
sıralamaya taşınır. Tanı tabakalarının indeks alanı korunur. Dahil, Hariç ve Ayrı
PDF panel kapaklarında iki A4/yüz için sonuç:

| Tabaka | Ön | Arka |
| --- | --- | --- |
| 1 | 12 · 1 | 2 · 11 |
| 2 | 10 · 3 | 4 · 9 |
| 3 | 8 · 5 | 6 · 7 |

Katlama testi bu tabakaları iç içe yerleştirip 1–12 okur. On sayfalık ek test,
tamamlama boşlarının kapak yüzlerine taşınmadığını da kontrol eder. Eski
`book == nil` projelerin sayfa/kapak modeli korunur.

**Görünüm → Tüm tabakalar**, kitapçıklarda varsayılandır. Ön ve arka yüzler
aynı satırda, bütün tabakalar sürekli kaydırmada gösterilir. Soldaki tabakaya
veya tekrarlı işin baskı tabakasına tıklamak ilgili yere gider; kaydırma seçimi
ve tekrar numarasını günceller. Page Up/Down ve oklar fiziksel tabakalar arasında
ilerler. Yakınlaştırma bütün kaydırma alanına uygulanır. **Tek tabaka** mevcut
etkileşimli görünümü korur. Ekran dışında PDF tuvalleri oluşturulmaz; tekrarlar
ayrıca diziye genişletilmez. Son tabaka yakınlaştırma düşükken de üst kenara
hizalanabilir. Görünür yüzlerin taşma örnekleri arka planda hazırlanır.

**Ölçeklendir**, her düz iş/karışık alt iş için hedef ebat ve modu saklar.
Kitap iç sayfaları birlikte, ayrı kapak PDF’si/açılımı ayrı ayarlanır; açılımın
hedefi açılımın tamamıdır. Kartvizit 90×50, 85×55, A6, A5, A4, DL (99×210) ve
Özel (mm) kullanılabilir. Seçilmiş hedef kaynak ölçüden farklıysa veya ürün
belirgin büyükse ithalatta ve **Otomatik düzenle** sırasında Türkçe soru açılır.
Öneri eşiği, yaklaşık 100–150 × 60–100 mm kartları ve uzun kenarı 300 mm’yi
geçen ürünleri kapsar; diğer ölçüler her zaman elle ayarlanabilir.

- **Oranı koru / sığdır:** küçük oran, ortalı yerleşim; kalan alan mevcut kenar
  rengi/kenar şeridi yöntemiyle tamamlanır.
- **Oranı koru / doldur (kırp):** büyük oran, ortalı kırpma.
- **Esnet:** bağımsız x/y oranları; oran değişimi %2’yi geçerse uyarı.

100×60 → 90×50 için sığdır %83,33, doldur %90, esnet x=%90/y=%83,33’tür.
Kesim her modda 90×50 olur. Kaynak PDF ve ölçü kataloğu değiştirilmez; plan
hedef kesimi ve affine artwork dönüşümünü taşır. Otomatik yerleşim hedef ölçüyü
kullanır ve özgün tek/çift yüz eşlemesini korur. Aynı kaynağın karışık iş
kopyaları ve yinelenmiş düz iş sayfaları bağımsız hedefler alabilir. Kaynak
artwork vektör kalır. Taşma hedefin ölçeklenmiş/kırpılmış kenarlarından üretilir;
mevcut daha büyük artwork/taşma planın taşma klibinde kesilir. Değişken kenarda
önceki yöntemdeki bir piksel genişliğinde şeritler kullanılabilir; bütün sayfa
rasterleştirilmez. Önizleme ve PDF aynı çizim yolunu kullanır.

**Seri Numara → Aralık dağıtımı**:

- **Kopya bazlı:** önceki toplam adet davranışı.
- **Blok bazlı:** düz işte her ızgara kopya konumu, gang’da her `GangBlock`
  bağımsız bloktur. Adet blok başınadır. İki blok ve 100 adet: 1–100 / 101–200.
  Gang ızgarasında birden çok ürün varsa blok içinde Sıralı veya Yığın düzeni
  uygulanır. Aynı başlangıç/artış/önek/sonek ve arka yüz kuralını kullanan
  blok sayaçları işler arasında da devam eder. Ortak baskı daha uzunsa bitmiş
  bloklarda numara üretilmez.
- **İş bazlı:** her işin kendi başlangıcı/artışı/bitişi; aynı önek/sonekle
  çakışan iş aralıkları çıktıyı engeller.

**Arka yüz numarası → Ön ile aynı** varsayılandır. **Ardışık**, fiziksel ön/arka
ürün için 1/2, sonraki ürün için 3/4 kullanır. Tek yüz iş arada numara atlamaz.
Blok aralıkları soldaki listede ve önizleme başlığında gösterilir. Sıfır artışlı
blok çakışması, sayısal taşma ve yeni blok/iş modlarında sabit basamak taşması
çıktıyı engeller. Adet/fire ve maliyet özeti blokların toplam üretimini sayar.
Aralık çakışması sayısal alt/üst sınırla denetlenir; seyrek artış dizilerinde
kesişmeyen tek tek değerleri ayrıca ayırmaz.

`.atispress` şeması **17**; görünüm tercihi, iş hedefleri/modları ve seri
aralık/arka yüz tercihlerini saklar. **1–16** açılır; eksik alanlar önceki kopya
bazlı/aynı arka yüz davranışını ve ölçeklenmemiş kaynakları korur. Undo/redo,
kurtarma ve normal kaydet/aç aynı proje alanlarını taşır.

Çalıştırma ve doğrulama (ağ gerekmez):

```sh
cd /Users/baturayatis/Developer/AtisPressCore
swift run --disable-sandbox AtisPressApp
swift test --disable-sandbox
swift test --disable-sandbox --filter 'SaddleCoverOrderTests|Rescal|SerialDistributionTests|NewProductionSettingsTests'
./scripts/build_app.sh
open "dist/AtışPress.app"
```

Yeni doğrulamalar: üç kapak modu, katlama ve iç boşlar; 1200 sayfalık gerçek
önizleme görünümünde seçme/kaydırma ve görünür görünüm sayısı; 100.000 tekrarlı
kaydırma geometrisi; üç ölçek modu, iş bağımsızlığı ve çift yüz eşlemesi;
vektör PDF kaynaklarının korunması ve taşma dahil önizleme/PDF piksel eşitliği;
blok/iş aralıkları, arka numaralar, taşmalar ve gerçek kaynakla kaydet/aç/eski
şema. Masaüstünde kapak yüzleri, kaydırma ve Türkçe kontroller ayrıca incelendi.
Donanıma bağlı FPS ölçümü ve fiziksel baskı/katlama provası yapılmadı.

Son doğrulama: **266 XCTest testi, sıfır hata** (121 çekirdek, 60 PDF, 85 uygulama).
Derleme ve `git diff --check` temizdir. Yerel uygulama paketi oluşturuldu ve ad-hoc
imzası doğrulandı. Sandbox LaunchServices kaydına izin vermediği için Finder
çift tıklama yönlendirmesi ayrıca denenmedi; uygulama paketinden açılış doğrulandı.
