# AtışPress güncelleyici

Yalnız Apple Foundation/AppKit/Security/CryptoKit ve macOS araçları kullanılır.
Planlayıcı, PDF çizimi ve `.atispress` şeması değişmez. Tercih uygulama düzeyinde
UserDefaults içindedir; projeye ağ/kurulum tercihi yazılmaz.

## İlk anahtar kurulumu — geliştiricinin Mac’inde bir kez

```sh
./scripts/make_update_key.sh
```

Betik CryptoKit `Curve25519.Signing` (Ed25519) anahtarı üretir. Özel anahtar
hiçbir dosyaya, komut satırı argümanına, stdout’a veya depoya yazılmaz. Base64
olarak macOS Keychain generic password kaydında saklanır:

- service: `com.atisajans.atispress.update-signing`
- account: `ed25519-v1`
- erişim: `WhenUnlockedThisDeviceOnly`; iCloud ile eşitlenmez.

Yalnız açık anahtar ekrana ve `packaging/Info.plist` içindeki
`AtisPressUpdatePublicKey` alanına yazılır. Bu plist değişikliğini commit edin,
uygulamayı yeniden derleyin. Var olan Keychain kaydı veya açık anahtarın üzerine
betik yazmaz. Keychain erişimi için macOS izin penceresi çıkabilir.

**ÖZEL ANAHTARI YEDEKLEYİN.** Keychain Access’te bu kaydı bulun, “Parolayı göster”
ile base64 değeri yalnız güvenilir çevrimdışı şifreli parola kasasına alın.
Terminale yapıştırmayın, düz dosya veya repo oluşturmayın. Panoya aldıysanız
panoyu temizleyin. Mac/Keychain kaybında bu anahtar olmadan mevcut kurulumlara
geçerli güncelleme imzalanamaz. Yeni Mac’te Keychain Access ile aynı service/account
ve base64 parola kaydını güvenli kasadan geri kurun; aynı açık anahtarla eşleştiğini
release betiği kontrol eder. Yedeğin erişilebilirliğini yayınlamadan önce sınayın.
Anahtar rotasyonu eski güven anahtarını kendiliğinden değiştirmez; mevcut anahtarla
imzalı geçiş sürümü veya elle yeniden kurulum gerekir.

Depodaki açık anahtar başlangıçta **boştur**: bu oturumda üretim sırrı oluşturulmaz.
Kurulum yapılana kadar uygulama Türkçe açıklama ve GitHub bağlantısı gösterir,
indirme/kurma düğmesi sunmaz. Test anahtarları üretim anahtarı olarak gömülmez.

## Sürüm yayınlama

1. `packaging/Info.plist` sürüm/build değerlerini ve `AppHelp` paket dışı
   sürüm/build yedeğini yükseltin. İlgili sürüm testini güncelleyin. Aynı sürümde
   daha yüksek build desteklenir; eski sürüm daha yüksek build ile kurulamaz.
2. `RELEASE_NOTES.md` içine o sürümün notlarını yazın. Bu dosya yoksa
   `CHANGELOG.md` kullanılır. Notlar boş olamaz; UTF-8 metin olarak gösterilir.
3. Testleri çalıştırın; ardından örneğin:

```sh
swift test --disable-sandbox
./scripts/make_release.sh 0.2.1
```

Betik önce Keychain/açık anahtar eşleşmesini denetler; universal uygulama ve DMG
oluşturur, `ditto` ile `dist/AtisPress-0.2.1.zip` üretir. ZIP baytlarının SHA-256
özeti ve Ed25519 imzası `dist/update.json` içindedir. JSON’un bütün anlamlı alanları
ayrıca `metadataSignature` ile imzalanır. Alanlar: `version`, sayısal `build`,
`minimumOS`, `url`, `sha256`, base64 `signature`, `notes`, ISO8601 `publishedAt`,
base64 `metadataSignature`. Metadata kanonik biçimi, bu son alan hariç sıralı
anahtarlı JSON’dur (`withoutEscapingSlashes`). İmzalayan araç ve uygulama aynı
`UpdateManifest.swift` kaynağını kullanır. JSON’u imzadan sonra değiştirmeyin.

Betik **hiçbir şey yüklemez/push etmez**; ağ/noter kimliklerini DMG alt işleminden
çıkarır. Ekrana çalıştırılabilir tam komutu yazar:

```sh
gh release create 'v0.2.1' 'dist/AtisPress-0.2.1.dmg' 'dist/AtisPress-0.2.1.zip' 'dist/update.json' --title 'AtışPress 0.2.1' --notes-file 'RELEASE_NOTES.md'
```

Bunu yalnız hazır olduğunuzda ağ erişimli Terminal’de kendiniz çalıştırın.
GitHub etiketi `v<version>` olmalı ve release “latest” olmalıdır. ZIP adı ve URL
sürümle birebir eşleşir. Yanlış build içeren eski uygulama paketlenmez. DMG
oluşturma sandbox’ta engellenebilir; bu durumda betik başarısız çıkar, yayın
komutu basmaz. Normal geliştirici Terminal’inde yeniden çalıştırın. Üretilen
paket mevcut build betiği gibi ad-hoc imzalıdır; Developer ID/noter onayı bu
çevrimdışı akışın parçası değildir.

## Kullanıcı akışı ve güvenlik

Yardım → **Güncellemeleri denetle…** yalnız
`https://github.com/baturayatis/atispress/releases/latest/download/update.json`
GET isteğini yapar. Metadata imzası doğrulanır, sürüm/build ve minimum macOS
kontrol edilir. **Şimdi güncelle** tıklanmadan ZIP indirilmez. Açılışta denetleme
varsayılan kapalıdır; açılırsa başarısız denemeler dahil en fazla 24 saatte bir.
Proje, dosya adı, tanı veya kullanıcı verisi gönderilmez. HTTP oturumu ephemeral;
çerez, kimlik bilgisi ve kalıcı cache yoktur. HTTPS yönlendirmeleri yalnız GitHub
ve GitHub release asset sunucularına izin verir. GitHub standart bağlantı/IP
bilgisini ağ isteği nedeniyle görür. Uygulama başka API/analitik isteği yapmaz.

İndirme ilerlemesi gösterilir. ZIP hash’i ve imzası doğrulandıktan sonra yolları
kontrol edilerek açılır; codesign strict/deep, bundle ID, sürüm/build ve minimumOS
manifest ile eşleştirilir. Metadata en fazla 512 KB, ZIP 1,5 GB kabul edilir.
Minimum sistem macOS 14’tür. Yalnız kararlı üç parçalı sürümler desteklenir.

DMG/App Translocation/salt okunur veya yazılamayan hedefte kurulum sunulmaz:
“Önce uygulamayı Uygulamalar klasörüne taşıyın”. Yetki yükseltme/sudo yoktur.
Doğrulama bitince mevcut kaydet/iptal penceresi çalışır. Yardımcı betik yalnız
uygulama kapandıktan sonra (en fazla 300 saniye bekleyerek) kopyalar. Önce aynı
hedef diskte yeni paket hazırlanıp codesign doğrulanır, temp klasöre yedek alınır,
eski paket atomik olarak kenara taşınır. Yeni paket yerleştirilir; karantinası
kaldırılır, imzası yeniden doğrulanır ve `open -n` ile açılır. Hata halinde eski
paket geri taşınır. Yedek ve `install.log`/`result.txt` temp güncelleme klasöründe
kalır; sonraki açılışta sonuç gösterilir. Başarılı kurulumdan sonra yedeği elle
kaldırabilirsiniz; macOS temp dosyaları zamanla silebilir.

`open` başarılı döndükten sonraki uygulama çökmesini otomatik saptama/geri alma
bu sürümde yoktur. Elektrik kesintisi/kill -9 sırasında shell trap çalışmaz;
yedekten elle geri yükleme gerekebilir. Gerçek sistem izinleri ve Gatekeeper
sonucu ayrıca sınanmalıdır. Şeffaf otomatik yetki yükseltme yapılmaz.

## Yerel file:// testi — gerçek kurulumunuza dokunmadan iki sürüm

Ağ gerekmez. Önce kendi geliştirici anahtarınızı oluşturup açık anahtarı gömmüş
olun. Release derlemesi yerel dosya modunda da **yalnız gömülü anahtarı** kabul
eder; doğrulamalar kapatılmaz. Debug testlerinde ayrı geçici anahtar enjekte
edilebilir, bu override release derlemesine girmez.

Aşağıdaki komutları repo kökünde çalıştırın. Geçici dizinde eski 0.2.1/build 3 ve
yeni 0.3.0/build 4 kopyası oluşturur. Sürümünüz farklıysa sayıları buna göre seçin.
Bu yalnız updater testi için kopyanın plist’ini değiştirir; gerçek release’i böyle
hazırlamayın. Kurulum hedefi `/Applications` yerine geçici Applications dizinidir.

```sh
./scripts/build_app.sh
update_test_dir="$(mktemp -d /tmp/atispress-local-update.XXXXXX)"
mkdir -p "$update_test_dir/Applications" "$update_test_dir/release/packaging"
ditto 'dist/AtışPress.app' "$update_test_dir/Applications/AtışPress.app"
ditto 'dist/AtışPress.app' "$update_test_dir/AtışPress.app"
/usr/libexec/PlistBuddy -c 'Set :CFBundleShortVersionString 0.3.0' "$update_test_dir/AtışPress.app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleVersion 4' "$update_test_dir/AtışPress.app/Contents/Info.plist"
codesign --force --deep --sign - "$update_test_dir/AtışPress.app"
cp "$update_test_dir/AtışPress.app/Contents/Info.plist" "$update_test_dir/release/packaging/Info.plist"
printf 'Yerel güncelleme denemesi\n' > "$update_test_dir/release/RELEASE_NOTES.md"
ditto -c -k --sequesterRsrc --keepParent "$update_test_dir/AtışPress.app" "$update_test_dir/AtisPress-0.3.0.zip"
xcrun swiftc Sources/AtisPressApp/UpdateManifest.swift scripts/ReleaseTool/main.swift -o "$update_test_dir/release-tool"
"$update_test_dir/release-tool" sign-local "$update_test_dir/release" 0.3.0 "$update_test_dir/AtisPress-0.3.0.zip" "$update_test_dir/update.json"
ATISPRESS_LOCAL_UPDATE="file://$update_test_dir/update.json" "$update_test_dir/Applications/AtışPress.app/Contents/MacOS/AtisPressApp"
```

Diğer AtışPress pencerelerini kapatın; test uygulamasında Yardım → denetle →
Şimdi güncelle. Yeni sürüm aynı geçici hedefe gelmeli; yedek/log yolu sonuçta
bulunur. Kaydedilmemiş projede İptal kurulum yapmamalı; Kaydet kaydetmelidir.
İmzalı ZIP’i değiştirmek SHA-256 hatası, JSON notunu değiştirmek metadata imza
hatası vermelidir. Eski sürüm/eşit build kurulmaz. Aynı sürüm/daha yüksek build
ayrıca denenebilir. DMG’den/Translocation’dan açınca yalnız taşıma mesajı ve
GitHub bağlantısı kalmalıdır. Helper’ın hata enjeksiyon testleri gerçek
Applications’a dokunmaz:

```sh
swift test --disable-sandbox --filter UpdaterTests
swift test --disable-sandbox
```

Otomatik testler ağ/Keychain kullanmaz: geçici CryptoKit anahtarları, sahte fetch,
file:// akışı, hash/imza/metadata bozulması, bundle/codesign kontrolleri,
yazılamayan hedef, iki noktada zorlanmış geri alma ve günlük denetim kapısı.
Fiziksel Keychain izin penceresi/yedek geri yükleme, GitHub yönlendirmeleri,
Gatekeeper/noter onayı ve gerçek quit/relaunch elle doğrulanmalıdır.

Son güncelleyici doğrulaması: **378 test geçti, 0 hata** (124 çekirdek, 70 PDF,
184 uygulama); son başlangıç değişikliğinden sonra 22 hedefli güncelleyici/erişim
testi de geçti. Universal arm64/x86_64 uygulama yeniden derlendi, strict ad-hoc
imza doğrulandı. Release paketinde debug açık anahtar override’ı yoktur. Açık/koyu
güncelleyici pencereleri incelendi. LaunchServices kaydı sandbox’ta engellendi;
uygulama paketi hazır. Üretim Keychain kurulumu, DMG/yayın ve gerçek
quit/relaunch bu oturumda yapılmadı.
