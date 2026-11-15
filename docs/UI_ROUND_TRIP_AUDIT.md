# Kontrol dönüş denetimi — 15 Kasım 2026

Erişim envanteri: `Tests/AtisPressAppTests/WorkflowSettingsBefore.swift`.
257 erişim kaydı korunur; taşınan hedef alanları yeni ebat penceresine, kılavuz
bağı Katmanlar’a, ortak ölçü bağı InspectorControls’a eşlenmiştir.

`SettingsRoundTripTests` bu envanterin adlarından somut Codable yaprakları
üretir. Düz, karışık, tel dikiş ve spiral örneklerinde her alan için başlangıç
planı/kılavuz geometrisi alınır, alternatif değer uygulanır, yalnız ilgili alan
eski değere alınır, plan/uyarı/önizleme eşitliği sınanır. Kimlikler, kaynak PDF
metaverisi ve salt okunur türetilmiş değerler düzenleyici değildir. Sayısal
alanlar bir adım, enumlar kendi çözücüsünün kabul ettiği başka bir durumla
sınanır. Para/fiyat kitaplığı üretim geometrisini etkilemez. Per-job ölçekleme,
boş override ve eski proje geçişleri ayrı ölçekleme/kayıt testlerindedir.

Aynı saklama grupları ve kartlar için bütün boolean çiftlerinde A değiştir,
B değiştir, A geri al, B geri al uygulanır. Kart 3’ün taşma/kesim, yaprak kartının
cilt/döndürme ve bilgi şeridinin içerik anahtarları çapraz saklama gruplarıyla da
sınanır. Katmanlar’ın on anahtarı için bütün çiftler ayrıca sınanır. Ham JSON’da
`nil` ve `false` olan eski opsiyonel katman alanları aynı çizim anlamındadır;
bu ayrım uyumluluk için korunur.

## Bulunan sorunlar ve düzeltmeler

| Kontrol / geçiş | Sorun | Düzeltme / test |
|---|---|---|
| Kesim işaretleri; diğer odaklanan çıktı kontrolleri | `.marks` odağı kapalı güvenli alanı turkuaz çiziyor ve odak kalıyordu; plan eski haline dönüyordu | Kalıcı odak çizimi kaldırıldı. `LineStateTests.testTwelveA4SaddleCropOffRestoresExactCanvas` düzeltme öncesi tek piksel eşitliği hatası verdi; sonrası geçer |
| Taşma, kesim uzunluğu/uzaklığı, güvenli iç mesafe | Ölçü değiştirmek ilgili Katmanlar anahtarını açıyordu | Ortak ölçü bağı yalnız üretim değerini değiştirir; gerçek bağ dönüş testleri |
| Yaprak cilt kenarı/davranışı; delik anahtarı; cilt payı, delik aralığı/çapı/uzaklığı | Kenar, güvenli alan ve delik katmanları kendiliğinden açılıyordu | Bağımsız yaprak bağları; gerçek bağ dönüş testleri |
| Ürün/cilt türü | Kitap türüne geçmek sayfa numarası katmanını açıyordu | Katman tercihi korunur |
| Dijital/Ofset | Renk skalası ve diz önizleme katmanları değişiyordu | Yalnız üretim varsayılanları değişir; bağımsızlık testi |
| Satır/sütun/adet etkinleştirme | Kapatıp açmak elle girilmiş sayıyı varsayılana çeviriyordu | Pencere içinde pasif sayı hatırlanır |
| Özel / Bitişik / Özel dizilim | Eski özel ara boşluk kayboluyordu | Özel aralık hatırlanır |
| Dahil / Ayrı PDF / Dahil kapak | Elle seçilmiş kapak yüzleri sıfırlanıyordu | Mod başına kapak seçimi hatırlanır |
| Çift / tek / çift yüz; iş bazında yüz istisnası | Seri alanı yeniden eşlemesi alanları çoğaltabiliyor veya kimlik/yüz seçimini değiştirebiliyordu | Değiştirilmemiş eşlemenin önceki tarifi geri getirilir; seri alanı elle düzenlenmişse eski hatıra kullanılmaz |
| Metin / QR veya Code 128 / Metin | Kodun CMYK zorunluluğu metnin rengini ve pasif kod ayarlarını değiştiriyordu | Tür başına kod/rengi hatırlanır; ortak numara/içerik alanları korunur |
| Basamağı elle sabitle | Otomatik artış elle girilmiş dar basamağı unutturuyordu | Manuel basamak hatırlanır; otomatik hesap aynı motoru kullanır |
| Sabit fire → yüzde düzenle → eski yüzde | Sabit fire modu geri gelmiyordu; alan ve adımlayıcı farklı davranıyordu | Ortak yüzde bağı önceki modu geri getirir |
| Taşma miktarı değiştir → eski miktar | Otomatik açılan üretim anahtarı geri gelmiyordu | Bağlı miktar dönüşü önceki durumu geri getirir; yeni değer üretimi açar, açık anahtar düzenlemesi bu bağlantıyı keser |
| Tüm yüzler: bilgi şeridi/taşma üretimi | Plan yüzleri aynı kaldığında önizleme önbelleği güncellenmeyebiliyordu | Önbellek üretim metnini, taşma miktarı/ayarını ve üretim türünü de izler; canlı tuval güncellemesi testi |

Temel veri alanlarının dönüş taramasında ek bir planlayıcı matematiği hatası
bulunmadı. Düzeltmeler UI bağları, önizleme ve pencere belleği ile sınırlıdır.
Eski projenin açıkça kaydedilmiş üretim ayarları yeniden yorumlanmaz. Pasif
kontrol hatırası proje verisinin parçası değildir; açık değerler aynı şemayla
kaydedilir/açılır.

## Ölçek penceresi

`ScaleWindowTests`: pencere varsayılanı, tek/çok iş kapsamı, çipler, gerçek oran
metni, %2 oran uyarısı, küçülen yazı ve ölçülmüş/ölçülmemiş dpi; tüm/seçili iş,
Genel ayarı kullan, kaldırma, kitapçık sayfa sayısı, karışık iş istisnası,
önerinin tıklama gerektirmesi ve eski ayarların yeni satırda görünmesi.
Fit/fill/stretch için eski `rescaleJobs` motoruyla yeni pencere sonucu aynı
plan ve PDF piksellerini üretir. Kaldırma ve ölçeklemesiz aç/vazgeç başlangıç
planı ve PDF piksellerine döner. Proje JSON turu ve mevcut gerçek dosya
kaydet/aç testleri korunur. Çizgi açıklamasında bütün çizgi türleri sınanır.

Açık/koyu pencere ve minimum ana ekran görselleri `.build/WorkflowQA` içinde
üretilir. Gerçek donanım/VoiceOver sınaması yapılmadı. Bir alternatifli dönüş
matrisi bütün olası değer kombinasyonlarını veya fiziksel baskı sonucunu
kanıtlamaz. PDF eşitliği raster snapshot’tır; PDF baytlarının eşitliği değildir.

Son sonuç: tam takım 353 XCTest (124 çekirdek, 60 PDF, 169 uygulama), sıfır hata.
Son denetçi/seri hatırası ve etiket değişikliklerinden sonra 38 hedefli test
sıfır hatayla geçti. Üretilen alan raporu her ailede 174, toplam 696 dönüş
satırıdır. Yüz düzeni hatırasının anahtarı sıralı JSON ile oluşturulur; nesne
anahtar sırası değişiminin rastgele hatıra kaçırmasına izin verilmez.
