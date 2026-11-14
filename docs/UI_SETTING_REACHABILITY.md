# Ayar erişim denetimi

Yeniden tasarımdan önceki editörlerin kaynakta kullanılan ayar/bağlantı anahtarları aşağıda sabitlendi. Yeni görünümde editörler aynı bağlarla yeniden kullanılır. Salt sunum olan eski mod ve arama kaldırılmıştır.

| Önceki editör | Yeni erişim yolu | Korunan anahtarlar |
| --- | --- | --- |
| InspectorView | Kartlar 1/2/3 ve son ayrıntı bölümü | `autoLayout`, `binding`, `blockAlignment`, `book`, `exportMarks.crop`, `gang`, `isBooklet`, `isLeafBinding`, `keyPath.bleed`, `keyPath.crop`, `keyPath.cropMarkLength`, `keyPath.cropMarkOffset`, `keyPath.offset`, `keyPath.safeArea`, `keyPath.safeAreaInset`, `model.editableGeneratedBleed.color`, `model.editableGeneratedBleed.color.components`, `model.editableGeneratedBleed.color.components.count`, `model.editableGeneratedBleed.enabled`, `model.editableGeneratedBleed.method`, `model.editableGeneratedBleed.tolerance`, `model.overlays`, `model.overlays.bleed`, `model.overlays.colorBar`, `model.overlays.crop`, `model.overlays.fold`, `model.overlays.pageNumbers`, `model.overlays.pressGuides`, `model.overlays.punch`, `model.overlays.registrationTargets`, `model.overlays.safeArea`, `model.overlays.sheetBoundary`, `model.pageLayoutMode`, `model.repeatArrangement`, `model.sheetPreset`, `pages.count`, `pages.isEmpty`, `settings`, `settings.bleed`, `settings.cropMarkLength`, `settings.signatureSize`, `settings.turnMethod`, `sheet.gripperEdge`, `sheet.gripperWidth`, `sheet.gutter`, `sheet.margins.bottom`, `sheet.margins.left`, `sheet.margins.right`, `sheet.margins.top`, `sheet.orientation`, `sheet.size`, `sheet.size.height`, `sheet.size.width`, `stepAndRepeat.allowRotation`, `stepAndRepeat.columns`, `stepAndRepeat.quantity`, `stepAndRepeat.rows` |
| BookInspectorView | Cilt ve kapak; Broşür için son ayrıntılar | `adhesiveAllowance`, `binding`, `book`, `bulk`, `coverAllowance`, `coverArtwork`, `coverMode`, `coverPaper`, `creepEnabled`, `description`, `grammage`, `input`, `interiorPaper`, `keyPath.back`, `keyPath.bookInfo`, `keyPath.front`, `keyPath.insideBack`, `keyPath.insideFront`, `leftFlap`, `microns`, `millimetres`, `model.bookSettings`, `model.bookSettings.adhesiveAllowance`, `model.bookSettings.coverAllowance`, `model.bookSettings.coverArtwork`, `model.bookSettings.coverPaper.millimetres`, `model.bookSettings.coverSourceID`, `model.bookSettings.creepEnabled`, `model.bookSettings.interiorPaper.millimetres`, `model.bookSettings.selection`, `resolvedCoverSelection`, `rightFlap` |
| LeafInspectorView | Cilt ve kapak | `allowance`, `book`, `coverMode`, `diameter`, `keyPath.back`, `keyPath.front`, `keyPath.leafInfo`, `keyPath.offset`, `leafSettings`, `leafSettings.allowance`, `leafSettings.behavior`, `leafSettings.edge`, `leafSettings.holes`, `model.bookSettings.selection`, `model.overlays.pressGuides`, `model.overlays.punch`, `model.overlays.safeArea`, `offset`, `pages`, `pitch`, `stepAndRepeat.allowRotation` |
| BlankPlacementView | Cilt ve kapak | `blankPagePolicy`, `keyPath.offset`, `model.blankSettings.mode`, `model.blankSettings.positions`, `model.blankSettings.positions.contains`, `model.blankSettings.positions.count` |
| SerialInspectorView | Eklemek istersen → Seri numara / QR kod | `backNumbering`, `binding`, `codeSettings.humanFontSize`, `codeSettings.humanReadable`, `color`, `color.components`, `color.components.count`, `content`, `digitNote`, `digits`, `digitsAreManual`, `distribution`, `font`, `id`, `jobIndex`, `keyPath.offset`, `kind`, `mode`, `model.editableSerialFields`, `model.editableSerialFields.count`, `model.editableSerialFields.filter`, `model.editableSerialFields.first`, `model.editableSerialFields.firstIndex`, `model.editableSerialFields.removeAll`, `position.x`, `position.y`, `prefix`, `rangeDescription`, `rotation`, `showsEndNumber`, `sides`, `size`, `start`, `step`, `stepAndRepeat.quantity`, `suffix`, `usesSerialNumber`, `value` |
| SerialCodeControlsView | Seri numara → Tür: QR / Code 128 | `codeSettings.correction`, `codeSettings.height`, `codeSettings.humanReadable`, `codeSettings.quietZone`, `codeSettings.template`, `codeSettings.width`, `content`, `kind` |
| RescaleInspectorView | Eklemek istersen → Hedef ebada ölçeklendir | `binding`, `book`, `gang`, `hasInvalidScaling`, `isBooklet`, `isValid`, `migrateScaling`, `mode`, `pages.filter`, `pages.first`, `repeatJobs.enumerated`, `scaling`, `scalingSettings`, `target`, `target.height`, `target.width` |
| ColorControlSizeView | Eklemek istersen → Renk skalası ve diz işaretleri | `exportMarks.barSide`, `exportMarks.patchSize`, `exportMarks.targetSize` |
| ExportMarksView | Son ayrıntılar → Çıktı işaretleri; PDF hazırlama penceresi | `exportMarks`, `exportMarks.bleed`, `exportMarks.color`, `exportMarks.colorBar`, `exportMarks.crop`, `exportMarks.fold`, `exportMarks.fullCut`, `exportMarks.lineWidth`, `exportMarks.pageNumbers`, `exportMarks.registrationTargets`, `exportMarks.safeArea`, `exportMarks.sheetInfo`, `includeBlankBacks`, `keyPath.date`, `keyPath.production`, `keyPath.sheetNumber`, `keyPath.sheetSize`, `keyPath.showJobName`, `keyPath.side`, `model.infoJobName` |
| PricingView | Eklemek istersen → Maliyet ve teklif → Fiyat kitaplığı | `backPrice`, `colors`, `copies`, `costing`, `extraWasteSheets`, `finishing`, `finishing.contains`, `finishing.indices`, `grammage`, `id`, `includesVAT`, `isBooklet`, `isLeafBinding`, `keyPath.offset`, `kind`, `margin`, `model.sheetPreset`, `name`, `override`, `paper`, `perThousand`, `platePrice`, `price`, `printing`, `quote.company`, `quote.jobName`, `quote.logo.wrappedValue`, `quote.note`, `quote.showCosts`, `quote.validity`, `quote.validity.isEmpty`, `quote.validity.trimmingCharacters`, `resolved`, `setupPrice`, `size.height`, `size.width`, `unit`, `vat`, `wrappedValue` |
| FireControlsView | Kart 1; tam fire seçenekleri son ayrıntılarda | `fixed`, `mode`, `numberCopies`, `percent`, `stepAndRepeat.waste` |
| GangInspectorView | Son ayrıntılar → Karışık iş | `gang`, `keyPath.allowRotation`, `keyPath.bleed`, `keyPath.element.id`, `keyPath.element.number`, `keyPath.job.id`, `keyPath.name`, `keyPath.saved.id`, `keyPath.tint`, `model.editableSerialFields.contains`, `quantities` |
| PresetInspectorView | Son ayrıntılar → Hazır ayarlar | `autoLayout` |

Toplam: 257 editör/anahtar kaydı. Aynı anahtar birden fazla editörde görünebilir. `WorkflowCardTests` kaynak bağlarını ve editör erişim grafiğini bu sabit envantere karşı denetler. Koşullu kapak, cilt, seri türü ve iş seçenekleri ilgili ürün/iş seçildikten sonra açılır.

Kaldırılan kalıcı arama/mod ortamı ve pencere açma eylemi üretim ayarı değildir; `inspectorSearchEnabled`, `inspectorSection`, `openWindow` bu üretim ayarı envanterine dahil edilmez.

## Yön ve önizleme gezinmesi

Üretim ayarlarının 257 kaydı korunur. `sheet.orientation` artık doğrudan
**Kart 2 → Yön** içindedir; ayrıntılarda ikinci bir Yön kontrolü yoktur.

| Anahtar / eylem | Önizleme araç çubuğu | Görünüm menüsü / klavye |
| --- | --- | --- |
| `project.allSheetsPreview` | Görünüm: Tüm yüzler / Tek yüz | Görünüm seçimi |
| `side` | Ön / Arka | Ön yüz / Arka yüz |
| `zoomAction`, `zoomFactor` | Uzaklaştır / Sığdır / Yakınlaştır | Aynı eylemler; ⌘− / ⌘0 / ⌘+ |
| `sheetIndex`, `repetition` | Tek yüzde ◀ / ▶ ve Tabaka N / M; soldaki tabaka listesi | Önceki / Sonraki tabaka; tek yüzde ← / → |
| Yüz konumu | Tüm yüzlerde dikey kaydırma | Önizleme odaktayken ↑ / ↓ ve PageUp / PageDown |

`SidePreviewTests` araç çubuğu ve menü erişimini, gerçek AppKit kaydırma
konumunu, Ön/Arka ve tabaka seçimi eşleşmesini, uyarıdan ilgili yüze gitmeyi,
1.200 yüzün yalnız görünür bloklarla çizilmesini ve 100.000 tekrarın kompakt
geometrisini denetler. Önceki envanter ve testler değiştirilmemiştir.

Önizleme araç çubuğundaki `zoomAutomatic` / `zoomScale` durum etiketi,
**Otomatik sığdır** veya **%N** gösterir. Düğmeler ve Görünüm menüsü aynı
`zoomAction` / `zoomFactor` eylemlerini kullanır; Sığdır / ⌘0 otomatik durumu
yeniden açar. Bu pencere durumu üretim ayarı veya proje şeması değildir.
