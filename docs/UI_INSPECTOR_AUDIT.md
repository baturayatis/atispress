# Denetçi ayar denetimi — 15 Kasım 2026

Kapsam: düz/tekrarlı, karışık iş, kitapçık ve yaprak cilt; Dijital/Ofset.
Üretim anahtarları silinmedi; eski projelerdeki görünmeyen değerler korunur.
[257 bağ/key-path kaydının sabit erişim envanteri](UI_SETTING_REACHABILITY.md)
ve `WorkflowCardTests.testEveryPreRedesignSettingBindingAndEditorRemainsReachable`
önceki bütün editörlere karşı çalışır. Aşağıdaki tablo kullanıcıya sunulan
kontrolleri açıklar; aynı veri alanının çıktı penceresindeki ikinci erişimi de belirtilmiştir.

Sayı satırları etiket solda, alan/birim/adımlayıcı sağdadır. Ölçülerde ortak
`TRFormat` kullanılır. Boş kalabilen kâğıt kalınlığı ve fiyat alanları sıfırla
kendiliğinden doldurulmaz. Kısa seçimler parçalı, uzun/dinamik listeler açılır
menüdür. Çevirme seçiminin kısa düğmeleri altında seçili tam Türkçe/teknik ad
ve açıklama görünür. Kâğıt seçenekleri A5 dahil çiplerdir. Yardım açıklamaları
zorunlu olmayan yerlerde araç ipucuna taşınmıştır; `—` ek metin gerekmediğini gösterir.

| Ayar | Kart / bölüm | Etiket | Kontrol | Yardım metni / görünürlük |
|---|---|---|---|---|
| Ürün | 1 · Ne basıyoruz? | Ürün tipi | Açılır liste | Ölçüden algılanan ürün değiştirilebilir |
| İstenen miktar | 1 | Adet | Sayı + adet + adımlayıcı | Kitap/yaprakta yayın adedi maliyet içindir |
| Yüzde fire | 1 | Fire | Sayı + % + adımlayıcı | Ek üretim payı |
| Tabaka | 2 · Hangi kâğıda basılacak? | Otomatik, A5, A4, A3, SRA3, 33×48, 35×50, 50×70, 70×100, Özel | Çipler | Öneri ile seçili kapasite birlikte gösterilir |
| Özel en | 2 | Genişlik | Sayı + mm + adımlayıcı | Yalnız Özel |
| Özel boy | 2 | Yükseklik | Sayı + mm + adımlayıcı | Yalnız Özel |
| Yön | 2 | Yön | Parçalı seçim | Otomatik / Yatay / Dikey; gerçek ölçü özeti |
| Çevirme | 2 | Ön/arka çevirme | Parçalı seçim | Yalnız çift yüz; tam ad aşağıda |
| Ayrı kalıp | 2 · Çevirme | Ayrı kalıp (sheetwise) | Seçenek | Ön ve arka için ayrı baskı kalıbı |
| Yandan çevirme | 2 · Çevirme | Yandan çevir (work-and-turn) | Seçenek | Kâğıt yan kenarından çevrilir; aynı kalıp |
| Baştan çevirme | 2 · Çevirme | Baştan çevir (work-and-tumble) | Seçenek | Kâğıt baştan çevrilir; aynı kalıp |
| Üretim türü | 2 | Üretim | Parçalı seçim | Dijital / Ofset |
| Taşma üretimi ve miktarı | 3 · Kesim ve taşma | Taşma payı | Tek satır: anahtar + sayı + mm + adımlayıcı | Anahtar eksik taşmayı üretir; mm kesim dışı paydır |
| Kesim işareti | 3; Çıktı işaretleri; PDF hazırlama | Kesim işaretleri | Anahtar | Çıktıya basılır |
| Dizilim | 3; Ayrıntılar · Aralıklar | Dizilim | Parçalı seçim | Bitişik / Aralıklı / Özel; kitapta değiştirilemez |
| Cilt yöntemi | Cilt ve kapak; Ayrıntılar · Diğer | Yöntem | Açılır liste | Düz, karışık iş ve cilt türleri korunur |
| Forma büyüklüğü | Cilt ve kapak | Forma | Açılır liste | Yalnız tutkallı/dikişli cilt |
| Ölçülmüş kitap ayarları | Cilt ve kapak | Kitap ayarları | Anahtar | Eski proje ölçülmüş iş akışına açıkça geçirilir |
| Kapak dahil/ayrı/ayrı PDF | Cilt ve kapak | Kapak modu | Parçalı seçim | Kitap ve yaprak cilt |
| Kapak kaynağı | Cilt ve kapak | Kapak PDF yükle… | Dosya düğmesi | Ayrı PDF seçilince |
| Kapak sayfa biçimi | Cilt ve kapak | PDF biçimi | Parçalı seçim | Tek yüzler / hazır açılım |
| Dış açılım sayfası | Cilt ve kapak | Dış açılım | Açılır sayfa listesi | Hazır açılım |
| İç açılım sayfası | Cilt ve kapak | İç açılım | Açılır sayfa listesi | Hazır açılım; boş olabilir |
| Ön kapak sayfası | Cilt ve kapak | Ön kapak | Açılır sayfa listesi | Tek kapak yüzleri |
| İç ön kapak sayfası | Cilt ve kapak | İç ön | Açılır sayfa listesi | Kitap; boş olabilir |
| İç arka kapak sayfası | Cilt ve kapak | İç arka | Açılır sayfa listesi | Kitap; boş olabilir |
| Arka kapak sayfası | Cilt ve kapak | Arka kapak | Açılır sayfa listesi | Tek kapak yüzleri |
| İç kâğıt giriş biçimi | Cilt ve kapak | Kalınlık girişi | Parçalı seçim | Mikron / gramaj × katsayı |
| İç kâğıt kalınlığı | Cilt ve kapak | Mikron | İsteğe bağlı sayı + birim + adımlayıcı | Ölçülmüş değer; varsayılmaz |
| İç kâğıt gramajı | Cilt ve kapak | Gramaj | İsteğe bağlı sayı + birim + adımlayıcı | Gramaj girişinde |
| İç kâğıt katsayısı | Cilt ve kapak | Cilt katsayısı | İsteğe bağlı sayı + adımlayıcı | Gramaj girişinde; kullanıcı ölçer |
| Kapak kâğıt girişi/kalınlık/gramaj/katsayı | Cilt ve kapak | Kapak kâğıdı | Aynı dört kontrol | Kapak için bağımsız ölçü |
| Kapak payı | Cilt ve kapak | Kapak payı | Sayı + mm + adımlayıcı | Sırt hesabında; tutkallı cilt |
| Yapıştırıcı payı | Cilt ve kapak | Yapıştırıcı payı | Sayı + mm + adımlayıcı | Sırt hesabında; tutkallı cilt |
| Sol kulak | Cilt ve kapak | Sol kulak | Sayı + mm + adımlayıcı | Kapak açılımı |
| Sağ kulak | Cilt ve kapak | Sağ kulak | Sayı + mm + adımlayıcı | Kapak açılımı |
| Kat kalınlığı düzeltmesi | Cilt ve kapak | Kat kalınlığı kaydırması | Anahtar | Ölçülmüş iç/kapak kalınlığı gerekir |
| Boş sayfa yeri | Cilt ve kapak | Boş sayfalar nereye | Parçalı seçim | Sona / Başa / Elle seç |
| Boş konumlar | Sol panel · iç okuma sırası | Boş konum | İşaretleme listesi | Yalnız elle boş yerleşimi |
| Boşlara izin | Cilt ve kapak | Boş sayfa eklemeye izin ver | Eylem | Önceden reddet politikası kayıtlıysa |
| Cilt kenarı | Cilt ve kapak · yaprak | Cilt kenarı | Açılır liste | Dört kenar |
| Cilt payı | Cilt ve kapak · yaprak | Cilt payı | Sayı + mm + adımlayıcı | Yaprak cilt |
| Cilt payı davranışı | Cilt ve kapak · yaprak | Cilt payı davranışı | Parçalı seçim | Koru / Küçült / Kaydır |
| Yaprak dönüş izni | Cilt ve kapak · yaprak | 90° döndürme | Anahtar | Yaprak cilt |
| Delik kılavuzu | Cilt ve kapak · yaprak | Delik kılavuzları | Anahtar | Yaprak cilt |
| Delik aralığı | Cilt ve kapak · yaprak | Delik aralığı | Sayı + mm + adımlayıcı | Delikler açıkken |
| Delik çapı | Cilt ve kapak · yaprak | Delik çapı | Sayı + mm + adımlayıcı | Delikler açıkken |
| Delik uzaklığı | Cilt ve kapak · yaprak | Kenardan uzaklık | Sayı + mm + adımlayıcı | Delikler açıkken |
| Sol/sağ/üst/alt kenar payı | Ayrıntılar · Kenarlar | Sol / Sağ / Üst / Alt | Dört sayı + mm + adımlayıcı | Kâğıtta ayrılan boşluk |
| Maşa kenarı | Ayrıntılar · Maşa | Maşa kenarı | Açılır liste | Makinenin tuttuğu kenar |
| Maşa genişliği | Ayrıntılar · Maşa | Maşa payı | Sayı + mm + adımlayıcı | Makinenin tuttuğu kenarda ayrılan boşluk |
| Ara boşluk | Ayrıntılar · Aralıklar | Ara boşluk | Sayı + mm + adımlayıcı | Düz/karışık iş; kitap katı sabit 0 |
| Blok hizalama | Ayrıntılar · Kenarlar | Hizalama | Parçalı seçim | Ortala / Maşaya yasla |
| Tabaka seçim politikası | Ayrıntılar · Diğer | Tabaka seçimi | Parçalı seçim | Sabit / En verimli / Otomatik |
| Kesim işareti uzunluğu | Ayrıntılar · Kesim ve katlama işaretleri | Kesim uzunluğu | Sayı + mm + adımlayıcı | İşaret uzunluğu |
| Kesim işareti uzaklığı | Aynı | Kesim uzaklığı | Sayı + mm + adımlayıcı | Uzunluk 0'dan büyükse |
| Güvenli iç mesafe | Aynı | Güvenli alan | Sayı + mm + adımlayıcı | Yazı/logo için kesimin içindeki mesafe |
| Üretilmiş taşma yöntemi | Ayrıntılar · Taşma ayrıntıları | Yöntem | Parçalı seçim | Otomatik / Yansıt / Renk; üretim açıkken |
| Renk benzerliği toleransı | Aynı | Tolerans | Sayı + % + adımlayıcı | Otomatik yöntemde |
| Üretilmiş taşma renk uzayı | Aynı | Renk uzayı | Parçalı seçim | CMYK / RGB; Renk yönteminde |
| Taşma renk bileşenleri | Aynı | C/M/Y/K veya R/G/B | Sayı + % + adımlayıcı | Seçilen renk uzayına göre |
| Tek/çift yüz eşlemesi | Ayrıntılar · Aralıklar | Sayfa düzeni | Parçalı seçim | Otomatik / Çift yüz / Tek yüz |
| İşe özel yüz eşlemesi | Ayrıntılar · İşlere göre ön/arka | İş N yüzleri | Açılır seçim | Genel / Tek / Çift yüz |
| Ürün dönüş izni | Ayrıntılar · Aralıklar | 90° döndürmeye izin ver | Anahtar | Düz iş |
| Sütun/satır geçersiz kılma | Ayrıntılar · Aralıklar | Sütun / Satır sayısını belirle | Anahtar + adımlayıcı | Otomatik sayı korunabilir |
| Adet hesabı | Ayrıntılar · Aralıklar | Adet hesapla | Anahtar + sayı | Düz iş; ana kartla aynı miktar |
| Fire biçimi | Ayrıntılar; Seri | Fire türü | Parçalı seçim | Yüzde / sabit adet |
| Sabit fire | Aynı | Ek üretim payı | Sayı + adet + adımlayıcı | Sabit adette |
| Fire numaralama | Aynı | Fire kopyalar | Parçalı seçim | Numarasız / Numaralı |
| Karışık iş düzeni | Ayrıntılar · Karışık İş | Düzen | Parçalı seçim | Otomatik / Elle yerleştir |
| Karışık iş adı | Aynı | İş adı | Metin | Seçili iş |
| Karışık iş ön/arka sayfası | Aynı | Ön sayfa / Arka sayfa | Açılır sayfa listeleri | Arka Yok olabilir |
| Karışık iş dönüş izni | Aynı | 90° döndürmeye izin ver | Anahtar | Seçili iş |
| Karışık iş taşma miktarı | Kart 3 | Taşma payı | Ortak satır | Seçili işin taşması; ikinci taşma satırı kaldırıldı |
| Karışık iş rengi | Ayrıntılar · Karışık İş | Önizleme rengi | Kaydırıcı | Yalnız önizleme |
| Karışık iş miktarı | Sol iş listesi | Adet | Sayı / miktar listesi | İşe özel üretim sayısı |
| Elle blok seçimi | Ayrıntılar · Karışık İş | Blok | Açılır liste | Yalnız elle düzen |
| Elle blok X/Y | Aynı | X / Y | İki sayı + mm + adımlayıcı | Blok konumu |
| Elle blok satır/sütun | Aynı | Sütun / Satır | İki sayı + adımlayıcı | Blok ızgarası |
| Elle blok dönüşü | Aynı | Blok 90° | Anahtar | Yalnız elle düzen |
| İş/blok ekleme/silme/çoğaltma | Aynı | İşi/Bloku çoğalt, sil | Eylem düğmeleri | Mevcut sınırlar korunur |
| Seri editör görünümü | Eklemek istersen | Seri numara / QR kod | Anahtar | Düz ve karışık işte; kapatmak veriyi silmez |
| Seri miktarı | Seri | Adet | Sayı + adet | Üretim adediyle aynı veri |
| Seri alanı seçimi | Seri | Alan listesi | Seçim düğmesi | Önizlemede de seçilebilir |
| Seri ekle/çoğalt/sil | Seri | Alan Ekle / Çoğalt / Sil | Eylem düğmeleri | En çok 100 alan |
| Seri türü | Seri | Tür | Parçalı seçim | Metin / QR / Barkod |
| Seri dağıtımı | Seri | Aralık dağıtımı | Parçalı seçim | Kopya / Blok / İş |
| Arka yüz sayacı | Seri | Arka yüz numarası | Parçalı seçim | Ön ile aynı / Ardışık |
| Sayaç sırası | Seri | Mod | Parçalı seçim | Sıralı / Kes ve istifle |
| İlk değer | Seri | Başlangıç | Tam sayı + adımlayıcı | — |
| Artış | Seri | Artış | Tam sayı + adımlayıcı | — |
| Son değeri göster | Seri | Bitiş no göster | Anahtar | Sayısal seride |
| Son değer | Seri | Bitiş no | Düzenlenebilir sayı metni | Müşteri adedini belirler; geçici hatalı giriş korunur |
| Basamak sahipliği | Seri | Basamağı elle sabitle | Anahtar | — |
| Basamak sayısı | Seri | Basamak | Adımlayıcı | — |
| Önek/sonek | Seri | Önek / Sonek | İki metin alanı | — |
| Yazı tipi | Seri | Yazı tipi | Açılır liste + özel ad metni | Metin veya okunabilir kod metninde |
| Yazı boyutu | Seri | Boyut / Okunabilir metin | Sayı + pt + adımlayıcı | Metin / kod alt yazısı |
| Seri açısı | Seri | Dönüş | Sayı + ° + adımlayıcı | — |
| Seri basılacak yüzler | Seri | Yüzler | Parçalı seçim | Ön / Arka / Ön ve arka |
| Seri konumu | Seri | X / Y | İki sayı + mm + adımlayıcı | Sol alt kesim köşesine göre; sürüklenebilir |
| Seri hizalama | Seri | Ortala / Köşeye al | Düğme + dört köşe menüsü | Alanın gerçek sınırına göre |
| Seri renk uzayı | Seri | Renk uzayı | İki seçenek | Metinde; kodlar CMYK |
| Seri renk bileşenleri | Seri | C/M/Y/K veya R/G/B | Sayı + % + adımlayıcı | — |
| QR/barkod içeriği | Seri · kod | İçerik şablonu | Metin | {no} sayaçtır; yoksa sabit içerik |
| Kod eni/kare boyutu | Seri · kod | Boyut / Genişlik | Sayı + mm + adımlayıcı | Boş tarama alanını da içerir |
| Barkod yüksekliği | Seri · kod | Çubuk yüksekliği | Sayı + mm + adımlayıcı | Yalnız barkod |
| QR hata düzeltme | Seri · kod | Hata düzeltme | Açılır liste | Yalnız QR; dört seviye |
| Kod boş kenarı | Seri · kod | Tarama boşluğu | Tam sayı + adımlayıcı | Birim: kod modülü |
| Kod alt yazısı | Seri · kod | Altına okunabilir metin yaz | Anahtar | — |
| Baskı tekrarı | Seri; sol panel | Baskı tabakası | Adımlayıcı | Fiziksel tabaka sayısı |
| Ebat akışı | 1 · Ne basıyoruz? | Ebat / Ebadı değiştir… | Tek pencere düğmesi | Açmak üretimi değiştirmez |
| Ölçek hedefi | Ebat penceresi · 1 | Yeni ebat | Standart çipleri / Özel ölçü | Mevcut ebat Şu an ile işaretlenir |
| Ölçek özel en/boy | Ebat penceresi · 1 | Genişlik × Yükseklik | İki sayı + mm + adımlayıcı | Özel ölçü |
| Ölçek davranışı | Ebat penceresi · 2 | Nasıl sığsın? | Açıklamalı üç çizim kartı | Tamamı görünsün / Alan dolsun / Ebada esnet |
| İş ölçekleme istisnası | Ebat penceresi · 3 | Hangi işlere? | Tüm işler / Sadece seçili iş | Çok işte liste; Genel ayarı kullan ve Ölçeklemeyi kaldır |
| Renk skalası | Eklemek istersen; Çıktı işaretleri | Renk skalası | Anahtar | Baskı rengini kontrol eder |
| Diz işareti | Aynı | Diz işaretleri | Anahtar | Baskı kalıplarını hizalar |
| Diz ölçüsü | Renk kontrol | Diz boyutu | Sayı + mm + adımlayıcı | Çıktı/önizleme dizleri açıkken |
| Renk yaması | Renk kontrol | Renk yaması | Sayı + mm + adımlayıcı | Skala açıkken |
| Skala kenarı | Renk kontrol | Skala konumu | Parçalı seçim | Maşa / karşı kenar; skala açıkken |
| Boş arka yüzü basma | Çıktı işaretleri / PDF hazırla | Boş arka yüzleri çıktıya ekle | Anahtar | Boş arka ve dolu arka birlikte varsa |
| Katlama işareti | Çıktı işaretleri / PDF hazırla | Katlama işaretleri | Anahtar | Yalnız kitapçık |
| Taşma kılavuzunu basma | Aynı | Taşma çizgisi | Anahtar | Üretim taşmasından bağımsız işaret |
| Güvenli alanı basma | Aynı | Güvenli alan | Anahtar | — |
| Sayfa etiketini basma | Aynı | Sayfa numaraları / yuva etiketleri | Anahtar | — |
| Bilgi şeridi | Eklemek istersen; çıktı ayrıntıları | Bilgi şeridini çıktıya ekle | Anahtar | — |
| Bilgi şeridi özel adı | Bilgi şeridi | İş adı | Metin | Yalnız etkin şerit |
| Şerit parçaları | Bilgi şeridi | İş adı, Tarih, Tabaka no, Ön/Arka, Tabaka boyutu, Ofset/Dijital | Altı anahtar | Yalnız etkin şerit |
| Tam kesim çizgisi | Çıktı işaretleri | Ürün üzerinde tam kesim çizgisi | Anahtar | Ürünün üzerine de basılır |
| Çıktı çizgi rengi | Çıktı işaretleri | Çizgi rengi | Parçalı seçim | Siyah / Tüm kalıplar |
| Çıktı çizgi kalınlığı | Çıktı işaretleri | Çizgi kalınlığı | Sayı + pt + adımlayıcı | — |
| Önizleme kılavuzları | Katmanlar; Ayrıntılar | Kesim, Katlama, Taşma, Güvenli alan, Sayfa numaraları, Tabaka sınırı | Altı anahtar | Yalnız ekran; çıktı işaretlerinden bağımsız |
| Diğer önizleme işaretleri | Ayrıntılar · Renk kontrol | Maşa, Delik, Renk skalası, Diz | Anahtarlar | Delik yalnız yaprak ciltte |
| Hazır ayar | Ayrıntılar · Diğer | Hazır ayar | Açılır liste + eylemler | Uygula/kaydet/adlandır/çoğalt/sil/içe/dışa aktar |
| Ön kontrol | Ayrıntılar · Diğer | Ön Kontrol | Salt okunur bulgular | Gerçek kaynak bulguları korunur |
| Otomatik sahiplik | Her kart başlığı | N ayar manuel · Otomatiğe döndür | Tek eylem | Kartın alanları tek işlemde otomatiğe döner |
| Genel sıfırlama | Panel altı | Tüm ayarları otomatiğe döndür | Onay isteyen eylem | Miktar, seri içeriği ve ölçülmüş kâğıt korunur |
| Maliyet etkinliği | Eklemek istersen | Maliyet ve teklif | Görünürlük anahtarı | Değerleri silmez |
| Maliyet kâğıt/baskı/işçilik | Maliyet | Kâğıt, baskı, işçilik | Açılır fiyat kaydı + özel fiyat | Kullanıcı fiyat girer; varsayılmaz |
| Maliyet yayın adedi/ek fire | Maliyet | Yayın adedi / Ek fire | İsteğe bağlı sayılar | Yayın adedi yalnız kitap/yaprakta |
| Kâr ve vergi | Maliyet; fiyat kitaplığı | Kâr marjı / KDV | İsteğe bağlı ondalık + adımlayıcı | % |
| Fiyat kaydı adı/türü/birimi | Fiyat kitaplığı | Ad / tür / birim | Metin/açılır liste | Fiyat türüne bağlı alanlar |
| Kâğıt fiyat ölçüleri | Fiyat kitaplığı | Gramaj / En / Boy | İsteğe bağlı sayı; ölçü + mm + adımlayıcı | Yalnız kâğıt fiyatı |
| Fiyat KDV ve miktar tabanı | Fiyat kitaplığı | KDV dahil / 1000 tabaka fiyatı | Anahtarlar | Kâğıt fiyatı |
| Fiyat tutarları | Fiyat kitaplığı | Birim, ön/arka, kalıp, hazırlık | İsteğe bağlı ondalık + adımlayıcı | ₺; türe göre |
| Baskı renk sayısı | Fiyat kitaplığı | Renk sayısı | İsteğe bağlı tam sayı | Yalnız ofset |
| Teklif metinleri | Maliyet · Teklif | Firma, iş adı, geçerlilik, not | Metinler | Girilen bilgiler korunur |
| Teklif logosu | Aynı | Logo seç / kaldır | Dosya eylemi | İsteğe bağlı |
| Teklif maliyet dökümü | Aynı | Ayrıntılı maliyet dökümünü ekle | Anahtar | — |
| Teklif çıktı | Aynı | Teklif PDF’i dışa aktar | Eylem | Geçerlilik ve hesap gerekir |

Yerleştirilemeyen üretim ayarı: **yok**. Tam sayılardaki geçici hatalı girişler,
isteğe bağlı fiyat/kalınlık ve seri bitiş numarası özel editörlerini korur;
bunlar boş değerleri kaybetmemek için ortak mm alanına zorlanmadı.

15 Kasım güncellemesi: çıktı kontrolleri **(çıktıya basılır)**, Katmanlar **(çıktıya basılmaz)** olarak etiketlenir. Çizgiler açılımı bütün türleri ve güvenli alan ölçüsünü açıklar. [Dönüş denetimi](UI_ROUND_TRIP_AUDIT.md).
