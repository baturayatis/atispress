# AtışPress — sayfa-bol durumu

15 Kasım 2026 · Dal: `sayfa-bol` · Proje şeması: **19**.

## Çalışanlar

- **Sayfayı böl**: tek kaynaklı, tek sayfalı düz/karışık işlerde boyut katlarından
  veya tekrarlanan dikdörtgen çerçevelerden ızgara önerisi. Öneri banner’ı ve
  kart 1’de manuel giriş. Olduğu gibi kullan üretimi değiştirmez; tercih kaydolur.
- Tek pencerede sayfa, sürüklenebilir yatay/dikey kesimler, yazılabilir
  Sütun/Satır alanları, hücre başına Ürün/Ön/Arka/Boş seçimi ve üç eşleme hazırı.
  Kayıtlı özel/kolon eşlemesi doğru adla açılır. Yalnız **Uygula** kaynak hazırlar.
- **Hücrede taşma** ile inset kesim veya elle girilmiş ortalanan kesim ebadı.
  Elle ebat seçiliyken gerçek en küçük hücre taşması hesaplanıp gösterilir;
  etkisiz bir taşma alanı sunulmaz. Ön/arka ebat eşitliği ve hücre geçerliliği
  onaydan önce denetlenir. Dolgu/görüntü/kesim kesişimi ihtiyatlı uyarıdır.
- Her ürün bir gang işi: kendi Ön/Arka sayfası, adedi, taşma ve seri/QR alanları.
  Ürünler tabakayı paylaşır. Arka konumunu mevcut sheetwise/turn/tumble motoru
  hesaplar. Yerleşim/paginasyon/katlama matematiği değiştirilmedi.
- Hücreler **vektör PDF kırpmasıdır**: orijinal sayfa yerleştirme dönüşümü ve
  clip ile çizilir; sayfa görüntüye çevrilmez. PDF içindeki eski bitmapler bitmap
  kalır. Her hücrenin gerçek TrimBox/BleedBox’ı ve bağımsız kenar örneklemesi vardır.
  Yeni hücre metadata’sı PDF ondalık kutu yazımındaki ulp farklarının eşit Ön/Arka
  ebatlarını bozmasını önlemek için 0,0001 mm hassasiyette kanonikleştirilir;
  bu bir ölçekleme değildir ve eski PDF okumasını değiştirmez.
- **Kılavuz çizgileri**: ≤0,5 pt stroke-only doğru parçaları/dikdörtgenler;
  magenta, pembe, cyan/açık mavi renkler; guide/kılavuz/bleed/trim/safe adlı OCG
  katmanları. RGB/CMYK ve 1/3/4 bileşenli ICC renklerde rol tahmini. Gruplama
  renk, kalınlık ve katman adına göredir. Sayı, swatch, rol ve katman listelenir.
- İç içe Form XObject’ler sekiz düzeye kadar **salt okunur** taranır. Dönüşümleri,
  BBox ve dikdörtgen clip’ler hesaba katılır. Bunlar ölçü öğrenebilir ve seçilebilir.
- Bir satır seçimi ilgili çizgileri turuncu vurgular. Sayfa üstünde **Çizgi seç**
  tıklaması grubu seçer; ⇧ ekler. Sayfa seçimi çok sayfalı tek kaynakta da vardır.
- Uygun kök içerik gruplarında işaretli kutu = gizli; **Gizle/Göster** çalışır.
  Seçilen `S/s` paint operatörü `n` yapılır. Diğer operatörler, nesneler,
  kaynaklar, görüntüler ve renk profilleri orijinal dosyada korunur; PDF artımlı
  güncellenir. Göster, değişmemiş özgün kaynaktan yeniden kurar.
- Her gizlemede seçili çizgi bantları dışındaki **tüm pikseller** 4 ve 8 piksel/mm
  render’da birebir karşılaştırılır. Dikdörtgenin içi maske değildir: iç baskının
  bozulması da reddedilir. Başarısızlıkta yeni kaynak uygulanmaz ve şu metin çıkar:
  “Bu çizgiler güvenli şekilde gizlenemedi. Çizgileri tasarım programında kılavuza
  çevirip PDF'i yeniden kaydedin.” Bu, her olası PDF renderer’ı için matematiksel
  renk/prova sertifikası değildir; çözünürlük ve destek kapsamı aşağıdadır.
- İç pembe dikdörtgen + dış magenta dikdörtgenden kesim ve boşluk önerisi:
  testte **90×50 mm ve 3 mm**. Öneri önce gösterilir; tıklamayla bölme taslağına
  taşınır, üretim için ayrıca Uygula gerekir. Dış sayfa boşlukları olduğunda
  öğrenilen çerçeve merkezleri korunur; istenirse kesimler hücrelerde ortalanır.
- Raster görüntüde kılavuz benzeri ince renkli çerçeveler için uyarı.
  Raster çizgileri silen bir kontrol yoktur.
- Gizlenen çizgi sayısı çıktı özetinde; bütün etkin üretim tercihleri ve
  önizleme taşma katmanı `.atispress` içinde. Şema 1–18 açılır; yeniden kayıt 19.
  Özgün PDF/bookmark saklanır; geçici hazırlanmış dosyalara bağımlı kayıt yoktur.
- Gizle/Göster ve bölme birer undo adımı. Gizleme adet, ürün kimliği, QR ve
  mevcut hedef ebat ayarlarını, sayfa seçimini/sırasını ve seçili ürünü sıfırlamaz. Önizleme ve export aynı hazırlanmış
  vektör kaynağı ve planı kullanır. Ürün bazında ölçekli kenar önbelleği de ısıtılır.
- Taşma altında ürün başına üretim/perimetre/beyaz kenar/başarısızlık satırı.
  Gerçek kaynak taşması ayrıca doğru biçimde “kaynakta … mm” olarak açıklanır.
  Beyaz uyarısı kenar örneğine dayanır; yalnız miktar girildi diye dolgu var denmez.
- **Üretilen taşma** yalnız önizlemede, üretilebilen ve örneği hazır alanları tint’ler.
  Baskı kesim çizgileri önizlemede tam siyah ve en az 1,5 cihaz pikselidir;
  PDF’nin fiziksel çizgi kalınlığı değişmez. Durum satırı çizilen kesim segmenti
  sayısını veya kenar payı yetersizliğini gösterir.

## Eksik / güvenle sunulmayanlar

- **İç içe Form XObject çizgilerini gizleme** yoktur. Paylaşılan formlarda yalnız
  seçilen kullanımı yeniden yazıp bütün grafik durumu/clip/şeffaflığı korumak bu
  sürümde doğrulanmadı. Bu gruplar listede salt okunurdur; gizleme kutuları yoktur.
- Xref/object-stream PDF’ler, şifreli/imzalı dosyalar, genel ExtGState (`gs`),
  transparency group, shading ve inline image içeren karmaşık içerikte gizleme
  sunulmaz. Opaque bir ExtGState de ihtiyatla salt okunur kabul edilir. Kaynak
  tasarım programında gerçek kılavuz katmanı kullanmak gerekir. Güvenli kapsam
  dışındaki gruplar için çalışmayan bir gizleme düğmesi bırakılmaz.
- Genel Bézier/eğri kılavuzlar, spot/pattern renklerin kesin renk dönüşümü,
  karmaşık şekil clip’lerinin tam geometrik analizi ve tüm OCG yapı türleri yoktur.
  Listedeki rol bir tahmindir; tasarımın ne olduğuna otomatik karar verilmez.
- Raster çerçeve uyarısı renk/şekil sezgisidir; görüntüde kesin kılavuz ayrıştırması
  veya raster içinden çizgi silme yoktur. Aynı sayfadaki vektör+raster karışımında
  raster çerçeve bulgusu eksik kalabilir; görüntü alanı hiçbir zaman gizlenmez.
- Bölme oluşturma/düzenleme **tek sayfalı tek kaynak** içindir. Çok kaynaklı veya
  kitap/yaprak işinde bu giriş sunulmaz. Hazırlanmış işlere ek PDF/ayrı kapak PDF
  ekleme UI’si sunulmaz. Mevcut gang sınırı **8 ürün**; daha çok ürün bir defada
  uygulanamaz (hücreler Boş seçilebilir). Keyfi polygon/nesting eklenmedi.
- Hücre başına otomatik içerik/ürün adı tanıma, OCR ve garantili kesim-içerik
  çarpışma analizi yoktur. Dolgu/görüntü kesişimi uyarısı boş arka planlarda da
  çıkabilir. Kesim yerini kullanıcı doğrular. Beyaz kaynak taşması, verilen
  hücre geometrisinden anlaşılmaz; bölme doldurulmuş taşma garantisi değildir.
- Bir sayfanın kaynak içerik taraması 4 MB; en fazla 2.000 sayfa ve sekiz Form
  düzeyi. Yeniden yazma klasik xref ve 64 MB altı dosya içindir. Güvenlik render’ı
  sayfa başına en fazla 4.000×4.000 / 8 milyon piksel; bu kapsamı aşan sayfalarda
  gizleme UI’si yoktur. Doğrulama seçili değiştirilmiş sayfalarda 4/8 px/mm’dir;
  başka çözünürlük/renderer ve fiziksel baskının formal ispatı değildir.
- PDF/X, spot ayrımı, overprint/prova sertifikası, annotation/form baskısı ve
  fiziksel makine kalibrasyonu mevcut kapsamın dışındadır.

## Otomatik doğrulama

Son tam koşu: **368 test geçti, 0 hata** (PDFEngine 70, ImpositionCore 124,
AtisPressApp 174). Yeni pencerelerin açık/koyu ekran görüntüleri ve önizleme
bitmap’inin hücre koordinatlarını doldurduğu da denetlendi.

`SourcePreparationTests`: üç çerçeveli 2×2 PDF; 12 stroke, renk/layer grupları,
90×50/3 öğrenme, hit-test; iki Ön/Arka ürün, üç çevirme yönteminde fiziksel arka
konumu; hücrede doğru kaynak içeriği, vektör çıktı; dış piksellerin korunması,
çerçevenin içindeki baskı hasarının bile reddi; raster/şeffaflık reddi; gerçek
Form içinde okuma/ölçü öğrenme; dış sayfa boşluğunda kesim merkezleri, kaynak
dosyanın üzerine yazmayı reddetme; grid alanı ve Gizle/Böl sırası dönüş snapshot’ları.

`PageSplitWorkflowTests`: açık onay, banner, bağımsız ürünler/adet/QR/ölçek,
kaynak dosyaya bağlantılı gerçek kaydet/aç, şema 19 ve şema 18 göçü, gizle/göster
undo/redo, ölçeklemesiz plan/PDF piksel snapshot’ı, yeni editör erişimi, taşma
satırları/tint durumu ve minimum ekran kesim genişliği. Önceki reachability ve
round-trip takımı da çalıştırılır. PDF snapshot’ı raster piksel karşılaştırmasıdır;
tarih/nesne sırası gibi PDF baytları eşitliği değildir.

```sh
cd /Users/baturayatis/Developer/AtisPressCore
swift run --disable-sandbox AtisPressApp
swift test --disable-sandbox
swift test --disable-sandbox --filter 'SourcePreparationTests|PageSplitWorkflowTests'
```

## Elle sınanması gerekenler

- Kullanıcının gerçek Illustrator dosyası bu oturuma eklenmedi. O dosyada
  grupların doğru saptandığı, destek dışı yapıların salt okunur kaldığı; gerçek
  dış magenta/iç pembe çerçevenin ölçüsünün doğru önerildiği kontrol edilmeli.
- Gerçek fareyle kesim çizgisi sürükleme, hücre menüleri, çizgiye tıklama ve
  ⇧ çoklu seçim; Retina/harici ekranda tüm zoomlarda siyah kesim çizgisi.
- VoiceOver, klavye odağı, uzun katman adları ve çok hücreli dar pencere.
- Ön/Arka fiziksel prova: yazıcının gerçek turn/tumble yönü, kesim ve ürün
  adedine göre harman; beyaz kenar ve kalın renkli çerçeveler ayrıca kontrol edilmeli.
- Aktarılan PDF’de Illustrator/Acrobat ile vektör, font, gömülü resim, renk ve
  şeffaflık kontrolü. Görsel otomatik doğrulama baskı onayı yerine geçmez.
- Universal uygulama/DMG bu turda yeniden paketlenmedi. Ağ kullanılmadı;
  push yapılmadı.

## Otomatik güncelleme dalı

`otomatik-guncelleme`: imzalı metadata/ZIP, SHA-256, bundle/codesign doğrulaması,
ilerlemeli indirme, geri yüklemeli kurulum yardımcısı ve varsayılan kapalı günlük
denetim eklendi. Plan/PDF ve proje şeması değişmedi. Ayrıntılar ve yerel iki sürüm
senaryosu [UPDATER.md](UPDATER.md) içinde.

Üretim anahtarı geliştirici Mac’inde `make_update_key.sh` ile kurulmalı; depoda
başlangıçta açık anahtar boş bırakıldı. Anahtarsız build kurulum düğmesi sunmaz.
Keychain yedekleme/geri yükleme, GitHub canlı indirmesi, Gatekeeper ve gerçek
quit/relaunch elle doğrulanmalıdır. Ağ/push kullanılmadı.

Son güncelleyici doğrulaması: **378 test geçti, 0 hata** (124 çekirdek, 70 PDF,
184 uygulama); son başlangıç değişikliğinden sonra 22 hedefli güncelleyici/erişim
testi de geçti. Universal arm64/x86_64 uygulama yeniden derlendi, strict ad-hoc
imza doğrulandı. Release paketinde debug açık anahtar override’ı yoktur. Açık/koyu
güncelleyici pencereleri incelendi. LaunchServices kaydı sandbox’ta engellendi;
uygulama paketi hazır. Üretim Keychain kurulumu, DMG/yayın ve gerçek
quit/relaunch bu oturumda yapılmadı.
