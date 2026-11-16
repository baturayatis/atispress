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

## Tekil paneller ve okunabilir bağlam satırı — ikon-panel

### Panel içerikleri

| Panel | İçerik / alt gruplar |
| --- | --- |
| İş | Ürün tipi, ebat/değiştir, adet, fire; yöntem, ürünlerin ön/arka eşlemesi, ayrıntılı fire, hazır yerleşim ayarları |
| Tabaka | Ölçü chip'leri, özel ölçü, yön, üretim, ön/arka çevirme; yerleşim, dönüş izni ve satır/sütun |
| Kenarlar | Dört kenar payı, maşa kenarı/payı, ara boşluk, hizalama |
| Taşma | Üretim anahtarı, miktar, kaynak/sonuç satırları; yöntem, tolerans ve renk |
| İşaretler | Baskı işaretleri, kesim/güvenli alan ölçüleri, renk/diz ölçüleri, bilgi şeridi, önizleme katmanları |
| Seri No | Alanlar, içerik/kod, aralık, görünüm, konum; aynı seri/QR alanları |
| Ölçek/Böl | Ebat penceresi, sayfa bölme, kaynak kılavuzları ve boyut önerileri |
| Cilt | Kitap işinde yöntem, kapak, kâğıt, sırt/creep, boş sayfalar; yaprak işinde Cilt ve Kapak grupları |
| Fiyat | Maliyet, işçilik, sonuç/tabaka karşılaştırması, teklif, fiyat kitaplığı |
| Çıktı | Çıktı hazır seçimleri, boş arka seçenekleri, PDF hazırlama, ön kontrol |

### Davranış

- Simge bir tek panel seçer. Uzun denetçi, bölümler arası kaydırma/takip,
  Tümünü aç/daralt ve accordion kaldırıldı. Seçim UserDefaults'ta hatırlanır.
  Eski görünüm tercihleri üretim veya proje ayarlarını değiştirmez.
- Sütun 350 pt, simge çubuğu 72 pt, minimum içerik boyutu 1180×800 pt'dir.
  Başlığa çift tıklama sütunu daraltır; simge aynı paneli flyout'ta açar.
  ⌘1–⌘9 ilk dokuz paneli seçer. Onuncu Çıktı simgeden/menüden açılır;
  mevcut ⌘0 Sığdır, ⌘E ve ⌘O korunur.
- 56 pt üst satırda inline 13 pt etiketler ve büyük kontroller kullanılır.
  Sayı alanları tam Girilmedi ve birim için yer ayırır. Sığmayanlar sabit
  öncelikle … altına taşınır. Panel ve bar aynı bağlarla çalışır.
- Hücre/kılavuz seçimi modal pencerede olduğundan ilgili Ata/Böl/Gizle-Göster
  kontrolleri aynı pencerenin bağlam satırındadır. Kılavuz rollerinin otomatik
  saptaması ve güvenli gizleme mekanizması kullanılır.
- Boş projede planlama çağrısı başlatılmaz. Üst/durum satırı PDF seçin gösterir.
  Boş plan dışa aktarılamaz. Dolu planların yerleşim hesapları korunur.

### Doğrulama

```sh
cd /Users/baturayatis/Developer/AtisPressCore
swift test --disable-sandbox
./scripts/build_app.sh
open "dist/AtışPress.app"
```

Son tam koşuda **399 test geçti, 0 hata** (70 PDFEngine, 124 ImpositionCore,
205 AtisPressApp). Son panel/envanter doğrulamasında ayrıca 22 hedefli test geçti.

`IconPanelTests` envanterin tekil panel sahipliğini, seçim/kalıcılık/flyout,
boş projenin hatasız durumunu, 12 pt alt sınırını, bağlam/overflow ve iki yönlü
bağ/undo davranışını sınar. Dört iş türünde bütün görünür panel alt grupları
350×743 pt panel alanında yerel kaydırmaya gerek kalmadan oluşturulur.
Açık/koyu 1180×800 ve dar bağlam satırı görselleri `.build/WorkflowQA` altındadır.
Dört modda plan, dışa aktarılan PDF piksel snapshot'ı ve proje kaydet/aç sonucu
karşılaştırılır. Önceki reachability, round-trip ve güncelleyici testleri de koşulur.

Paketlenmiş uygulamada erişilebilirlik ağacı üzerinden tek panel seçimi,
⌘1–⌘9 (Cilt kitap işinde), simgeden Çıktı, çift tıklamayla daraltma ve flyout
kontrol edildi. Boş durumda iki yerde PDF seçin ve hatasız görünüm görüldü.
Oluşturulan 12 sayfalı test PDF'inde Adet üst satırdan 123, panelden 456 yapıldı;
ikisi eşzamanlı değişti ve tek undo 123'e döndürdü. Kitap bağlam satırı da görüldü.
Test projesi kaydedilmeden kapatıldı. Açık/koyu minimum boyut görselleri incelendi.
Universal arm64/x86_64 uygulama ve strict codesign doğrulaması üretildi.
LaunchServices kaydı sandbox'ta engellendi; paket masaüstü aracıyla açıldı.

### Sınırlar ve elle denenecekler

- Çok sayıda seri alanı/ürün, fiyat kitaplığı satırı, uzun kullanıcı metni veya
  ek uyarı içerikleri sığmazsa yalnız seçili alt grubun içinde yerel kaydırma
  kullanılır. Bölümler arasında kaydırma bulunmaz.
- Hücre/kılavuz bağlamları gerçek Illustrator PDF'iyle ayrıca denenmeli.
  Kılavuz grubuna yeni rol atayan editör sunulmaz.
- VoiceOver sesli okuması ve tüm karmaşık menü/panel odak geçişleri fiziksel
  kullanımda ayrıca kontrol edilmeli.

## Sayfa listesi işlemleri — sayfa-listesi

- Her satırda … ve sağ tık menüsü; üstte + Boş sayfa, Çoğalt, Sil bulunur.
  ⌘D ve liste odaktayken ⌫ aynı komutları çalıştırır. Native List çoklu seçimi
  ve .onMove yeniden sıralaması kullanılır. Menü, sağ tıklanan satır seçiliyse
  bütün seçime; başka bir satırsa o satıra uygulanır.
- Çiftin tek yüzü seçildiğinde çoğaltma penceresinde bütün Ön/Arka çiftini
  yeni ürün yapma varsayılandır. Yalnız seçili yüz ve 1–99 kopya seçenekleri
  vardır. Tam çift seçiliyse normal Çoğalt doğrudan çalışır.
- Sil, tek bağımsız sayfada doğrudan çalışır. Çoklu seçimde onay; çiftin tek
  yüzünde çift/yalnız seçili yüz seçimi vardır. Baskıya dahil ayrı geçici
  seçimdir. Ön/Arka bilgisi ve çift kimliği sıralamadan bağımsızdır. Tek yüz
  silme diğer yüzün rolünü değiştirmez.
- Boşlar komşu ölçüsündedir, kesik çerçeveli küçük görselle gösterilir ve forma
  içeriğinde yer tutar. Tamamen boş bir arka yüz de kasıtlı eklenmişse çıktıya
  alınır. Kitap sayfa sayısı, listedeki boşlar ve otomatik eklenecek boşlar
  gösterilir; forma için boş eklemek gerektiğinde satır uyarı rengindedir.
- PageListItem kimlikleri fiziksel PDF sayfa numaralarından ayrıdır. Planner
  aynı geometri/paginasyon hesabını kullanır; son ortak planda çizim referansı
  özgün sayfaya, boşlar nil'e çözülür. PDF kopyalanmaz veya rasterleştirilmez.
  .atispress yalnız küçük referans/ölçü kayıtlarıyla büyür; kaynak PDF korunur.
- Sıra değişiminde seri alanları ve işe özel ölçekler ürün sırasına taşınır;
  çift çoğaltırken alan kimlikleri yenilenir. Kılavuz hazırlama, sonradan PDF
  ekleme ve ayrı kapak bağlama da liste kimliklerini korur.
- Şema **21**; şema 1–20 açılır. Açılışta kimlikler, sıra/baskı seçimi,
  kaynak sayfa sınırları ve kaynak ölçüleri denetlenir. Undo/redo aynı
  ProjectState ve kaynak erişimini saklar. Güncelleyici değiştirilmedi.

### Test ve çalıştırma

```sh
cd /Users/baturayatis/Developer/AtisPressCore
swift test --disable-sandbox
swift run --disable-sandbox AtisPressApp
```

Önceki sayfa listesi koşusu **409 test, 0 hata** (70 PDFEngine, 124 ImpositionCore,
215 AtisPressApp). Yeni PageListActionTests çoğaltma/99 kopya, çift kaynakları,
tek yüz, silme/dahil etme ayrımı, çoklu seçim, boş/sıra, kitap forma sayısı,
undo/redo, şema 19 göçü ve 20 kaydet/aç, seri/ölçek taşıma, ek PDF/kapak,
bozuk referans reddi, kimlik taşması/yeniden kullanmama ve PDF vektör/piksel karşılaştırmasını kapsar. Önceki
reachability, round-trip, snapshot ve güncelleyici testleri de geçer.

Masaüstü uygulamasında …/sağ tık menüsünün yedi işlemi ve Baskıya dahil
kutusunun erişilebilirlik adları incelendi. Açılışta bulunan kurtarma oturumu
geri yüklendi ve açık bırakıldı. İşlem ve çıktı denemeleri üretilen test PDF'leriyle
çalıştırılır. Universal uygulama dist/AtışPress.app altında derlenir; LaunchServices
kaydı sandbox'ta engellenebilir.

### Sınırlar ve elle doğrulama

- Bu işlemler klasik Sayfalar listesi içindir. Karışık işin mevcut ürün
  listesi kendi ürün işlemlerini kullanır.
- Kitapta elle belirlenmiş otomatik boş konumları yeni sayıya uymuyorsa
  mevcut ön kontrol uyarısını gidermek gerekir.
- Uzun gerçek belgelerde sürükleyerek çoklu sıralama ve VoiceOver sesli
  gezinme ayrıca denenmelidir.

## Sayfalara başka PDF ekleme — sayfa-listesi, şema 21

### Çalışanlar

- Sayfalar araçlarında **PDF ekle…**, satırın …/sağ tık menüsünde
  **Buraya PDF ekle…** ve listeye/satıra birden fazla PDF bırakma bulunur.
  Seçim penceresinde küçük görseller, kutular, Tümü/Hiçbiri, `1-4, 7`
  aralıkları, dosya sırası ve üstüne/altına/başa/sona konumu vardır.
  Arka plandaki ekleme çizgisi konumu gösterir. Ekle onayı öncesi proje değişmez.
- Ön/Arka/Tek yüz ve çift UUID’si her satırda saklanır. İlk liste düzenlemesi
  eski projenin mevcut eşlemesini sabitler. İki sayfalık kartın Ön/Arka rolleri
  boş ekleme, çoğaltma, silme, dahil etme ve sıralama sırasında korunur.
  Ön silinip Arka tutulursa boş Ön eklenir. Arka silinirse Ön olarak kalır.
- Çiftin ortasına ekleme, iç içe sıralanmış çiftler dahil, çift sınırına taşınır
  ve seçim penceresi bunu açıklar. Çift yüzlü işte çift sayıda yeni sayfanın
  çift olarak eklenmesi varsayılandır. Tek sayıda sayfada boş arkalı önler,
  sıralı çiftler (son arka boş), ayrı tek yüzlü ürünler ve Vazgeç seçenekleri vardır.
  Sayfa eklemek işin genel yüz modunu değiştirmez. Kullanıcı İş panelinde
  veya satırın Yüz menüsünde yüz tercihini değiştirebilir.
- Gerçek arka yüzü bulunan iş artık arka yüz içermiyorsa önizlemede Geri al /
  Çift yüz yap uyarısı; durum ve çıktı özetinde **Arka yüz yok** görünür.
  Çıktı açık onay ister. Kitap sayısı ve otomatik forma boşları yeniden hesaplanır.
- Satırlar yerel kaynak sayfa numarasını ve kısaltılmış dosya adını gösterir.
  Kaynaklar dosya adı, sayısı ve yolu ile Değiştir…/Kaldır sunar. Kaldırma
  sayfalarıyla silme veya sayfaları tutup yeniden bağlama sorar. Son kaynak
  kaldırılırken boşların da temizleneceği açıklanır. Eksik kaynak açılışta
  yeniden bağlanır. Şifreli PDF için parola istenir ve projeye yazılmaz.
- Kaynaklar tek referansla paylaşılır. Geçici birleşik PDF, PDFKit sayfa
  kopyalarıyla vektör olarak oluşturulur. Ortak plan hem global çizim numarasını
  hem kaynak UUID’sini/yerel sayfasını taşır. Önizleme, seri alanları ve çıktı
  aynı çözümlemeyi kullanır. Kaynak dosyaların içeriği değiştirilmez.
- Farklı ebatta PDF için karışık işe dönüştürme veya mevcut Ebadı değiştir
  penceresi sunulur. Kitapta ölçekleme/Vazgeç vardır. Ölçek penceresi yalnız
  yeni sayfaları kapsar; Vazgeç tüm eklemeyi geri alır. Ekleme, ölçekleme,
  kaynak değiştirme ve kaldırma birer geri alma adımıdır.
- Şema 21 kaynak UUID/yerel sayfa, açık yüz/çift ve arka yüz geçmişini saklar.
  Şema 1–20 açılır. Açılışta kaynak kimliği, yerel/global sayfa tutarlılığı,
  sayfa ölçüleri ve kaynak sınırları denetlenir.

### Testler ve çalıştırma

```sh
cd /Users/baturayatis/Developer/AtisPressCore
swift test --disable-sandbox
./scripts/build_app.sh
open dist/AtışPress.app
```

Son tam koşu **421 test, 0 hata** (70 PDFEngine, 124 ImpositionCore,
227 AtisPressApp). Universal arm64/x86_64 release paketi ve strict ad-hoc
imzası doğrulandı. LaunchServices kaydı sandbox nedeniyle engellendi;
paket `dist/AtışPress.app` altında hazırdır.

PDFInsertionTests konumları, çift sınırlarını, tek/çift sayıları ve iptali,
çoklu kaynak sırasını, eski kartın yüzlerini, arka kaybı uyarı modelini,
undo/redo, farklı ebat seçeneklerini, ölçekleme iptalini, kitap boşlarını,
kaynak paylaşımını, kaynak kaldırma/yeniden bağlama, taşınmış kaynak açılışını,
yanlış/doğru parola ve iptalini, şifrenin kaydedilmemesini, çok kaynaklı
kaydet/aç ve karışık ebatlı karışık işin çıktısını kapsar. Tek kaynaklı plan
ve çıktı pikselleri geri alma sonrasında eşit karşılaştırılır; test çıktısında
raster görsel nesnesi oluşmadığı denetlenir. Mevcut reachability, round-trip,
snapshot ve güncelleyici testleri tam koşuya dahildir.

### Bilinen sınırlar ve elle kontrol

- Yeni seçim penceresi klasik Sayfalar listesindedir. Karışık işe geçildikten
  sonra mevcut ürün/kaynak araçları kullanılır.
- Kaynak değiştirirken kullanılan sayfaların kesim ölçüleri aynı olmalıdır.
  Farklı ölçüyle yeniden bağlama açık hata verir. Farklı ebatta içerik eklemek
  için PDF ekle… içindeki ölçekleme/karışık iş seçimi kullanılır.
- Kaynak kılavuzlarını seçerek gizleme ve Sayfayı böl araçları mevcut tek
  kaynak sınırını korur. Çok kaynak eklendikten sonra bunları dosya başına
  düzenleyen yeni bir arayüz eklenmedi.
- Parolası açılan PDF’nin geçici vektör kopyası oturum boyunca tutulur ve
  kaynak nesnesi bırakılınca silinir. Yeniden açılışta parola tekrar sorulur.
- Gerçek Finder çoklu PDF bırakma, ekleme çizgisinin görünürlüğü, parola/
  yeniden bağlama pencerelerinin odak sırası ve VoiceOver sesli kullanımı
  masaüstünde ayrıca doğrulanmalıdır. Bu değişiklikte fiziksel UI denemesi
  yapılmadı.
