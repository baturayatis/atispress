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
ditto -c -k --norsrc --noextattr --noacl --noqtn --keepParent "$update_test_dir/AtışPress.app" "$update_test_dir/AtisPress-0.3.0.zip"
xcrun swiftc Sources/AtisPressApp/UpdateManifest.swift Sources/AtisPressApp/UpdateArchive.swift Sources/AtisPressApp/UpdateInstaller.swift scripts/ReleaseTool/main.swift -o "$update_test_dir/release-tool"
"$update_test_dir/release-tool" sign-local "$update_test_dir/release" 0.3.0 "$update_test_dir/AtisPress-0.3.0.zip" "$update_test_dir/update.json"
"$update_test_dir/release-tool" verify "$update_test_dir/AtisPress-0.3.0.zip" "$update_test_dir/update.json" "$update_test_dir/release/packaging/Info.plist"
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

## Unicode ZIP düzeltmesi ve güvenli arşiv biçimi

Kök neden ZIP içeriği değil, eski `zipinfo -1` çıktısının dosya listesi olarak
kullanılmasıydı. Oturumun UTF-8 locale’inde NFC `ş` baytları `C5 9F` → `C5 3F` bozuluyordu;
çıktı geçersiz UTF-8 olunca liste boş sayılıyor ve genel yol hatası veriliyordu.
NFD (`s` + U+0327) bu UTF-8 ortamında aynı bozulmayı üretmedi. `LC_ALL=C` ile
ise NFC ad `At????Press.app/`, NFD ad `At??s??Press.app/` olarak listelendi ve
ikisi de beklenen kök önekiyle eşleşmedi. Eski testlerin locale/ad biçimi bu
farkı örtüyordu. Gerçek universal uygulamadan üretilen ZIP’in reddedilen NFC
uygulama girdileri (beklenen ham UTF-8 adlar):

- `AtışPress.app/`
- `AtışPress.app/Contents/`
- `AtışPress.app/Contents/Info.plist`
- `AtışPress.app/Contents/MacOS/`
- `AtışPress.app/Contents/MacOS/AtisPressApp`
- `AtışPress.app/Contents/Resources/`
- `AtışPress.app/Contents/Resources/AppIcon.icns`
- `AtışPress.app/Contents/Resources/LICENSE.txt`
- `AtışPress.app/Contents/PkgInfo`
- `AtışPress.app/Contents/_CodeSignature/`
- `AtışPress.app/Contents/_CodeSignature/CodeResources`

UTF-8 locale’de ilk girdinin `zipinfo` bayt çıktısı `41 74 C4 B1 C5 3F 50 72 65 73 73 2E 61 70 70 2F`;
gerçek merkez dizin adı `41 74 C4 B1 C5 9F 50 72 65 73 73 2E 61 70 70 2F`.
C locale’de aynı çıktı `41 74 3F 3F 3F 3F 50 72 65 73 73 2E 61 70 70 2F` olur.
Bu `?` karakterleri gerçek dosya adının parçası değildir. Doğrulayıcı artık dış komutun
locale’e bağlı görüntü metnini kullanmaz; ZIP’in merkez/yerel kayıtlarındaki ham
UTF-8 adlarını okur, NFC’ye çevirip karşılaştırır. `ditto` UTF-8 bayrağını koymasa
da geçerli ham UTF-8 kabul edilir; geçersiz kodlama reddedilir.

`--sequesterRsrc` ayrıca `__MACOSX/`, `__MACOSX/AtışPress.app/`,
`__MACOSX/AtışPress.app/Contents/`,
`__MACOSX/AtışPress.app/Contents/._Info.plist` ve
`__MACOSX/AtışPress.app/._Contents` üretti. Bunlar eski önek kontrolünün reddettiği
girdiler değildi; buna rağmen eski akış bunları açıyordu. Yeni okuyucu
`__MACOSX/` ve AppleDouble `._*` kayıtlarını **asla açmaz**. Sayı/boyut/yol/tür
kontrolleri bu atlanan kayıtlar için de geçerlidir.

Güncel yerel komut ve `make_release.sh` aynı `--norsrc --noextattr --noacl --noqtn`
biçimini kullanır; yeni ZIP’lerde AppleDouble üretilmez. Uygulama eski sequestered
ZIP’leri de güvenle kabul eder. İmzalar ZIP baytlarını kapsadığı için ZIP’i yeniden
oluşturduğunuzda manifesti de yeniden imzalayın.

Doğrulayıcı Foundation + Apple Compression ile yalnız store/deflate, tek diskli,
ZIP64 olmayan arşivleri açar. Sınırlar: **20.000 kayıt, toplam 512 MiB açılmış veri,
tek kayıtta 256 MiB**, indirilen ZIP’te mevcut 1,5 GB sınırı. Başlıktaki beyanlar ve
fiilî açılan boyut/CRC kontrol edilir; açıcı beyan edilen boyuttan fazla bellek
ayıramaz. Merkez ve yerel ad/yöntem/boyut/CRC uyuşmazlığı, üst üste binen veya
sahipsiz ZIP verisi reddedilir. Yeni/alışılmadık ZIP yöntemleri sessizce denenmez.

Mutlak/boş yollar, `..`, `.`, boş bileşenler, ters eğik çizgi/kontrol karakterleri,
tek `AtışPress.app` dışındaki girdiler, NFC/harf biçimi çakışmaları, aygıt/FIFO/socket
ve setuid/setgid türleri reddedilir. Bağlantılar yazılmadan önce bütün zincirleri
(çevrimsiz ve harf biçimi farkları dahil) denetlenir; hedef uygulama dışına çıkamaz.
Bir bağlantının altına arşiv girdisi yazılamaz. Normal dosyalar önce, yalnız güvenli
bağlantılar en son oluşturulur. AppleDouble, karantina, ACL ve kaynak çatalı
aktarılmaz; codesign doğrulaması bundan sonra zorunlu olarak çalışır.

Hata ilk sorunlu yolu, 160 karaktere kısaltılmış ve kontrol karakterleri kaçırılmış
olarak gösterir. Aynı mesaj 0600 izinli `install.log` içine yazılır; başarısız
indirmenin temp klasörü yalnız günlük için korunur, ZIP/yarım uygulama temizlenir.
Pencerede günlük konumu gösterilir. Hash, Ed25519, metadata, codesign, bundle ID,
sürüm/build ve kurulum konumu kontrolleri korunur.

`make_release.sh`, imzalamadan sonra aynı kodu kullanan `release-tool verify` ile
kendi ZIP/manifestini yeniden doğrular, açar ve codesign/bundle kontrollerini
çalıştırır. Bu adım başarısızsa `set -e` nedeniyle **gh komutu basılmaz**. Verify
komutu özel anahtar veya ağ kullanmaz; yalnız plist’teki açık anahtarı okur.
CLI doğrulama hatası da ZIP’in yanındaki `install.log` dosyasına yazılır.

```sh
swift test --disable-sandbox --filter 'UpdaterTests|UpdateArchiveTests'
swift test --disable-sandbox
```

Regresyon matrisi her iki üretici/komut için hem NFC hem NFD’yi, eski AppleDouble
ve yeni metadata’sız biçimi kapsar. Negatif testler bütün yol/tür/bağlantı/sınır
retlerini, beyan edilenden fazla açılmayı, günlük mesajını ve release doğrulama
kapısını sınar. Gerçek Keychain/DMG/GitHub yayını için önceki elle kontrol listesi
geçerlidir; bu düzeltme yayın yapmaz veya güven kökünü değiştirmez.

Gerçek universal paket üzerinde tüm 27 eski-biçim girdi ve NFC/NFD karşılığı
`.build/WorkflowQA/update-zip-entries.txt` tanı çıktısına kaydedildi. Yukarıdaki
11 uygulama girdisine ek olarak aşağıdaki 16 metadata girdisi gözlendi; bunlar
çıktıya alınmaz (NFD’de yalnız uygulama adındaki `ş`, `s` + U+0327 olur):

```text
__MACOSX/
__MACOSX/AtışPress.app/
__MACOSX/AtışPress.app/Contents/
__MACOSX/AtışPress.app/Contents/_CodeSignature/
__MACOSX/AtışPress.app/Contents/_CodeSignature/._CodeResources
__MACOSX/AtışPress.app/Contents/.__CodeSignature
__MACOSX/AtışPress.app/Contents/MacOS/
__MACOSX/AtışPress.app/Contents/MacOS/._AtisPressApp
__MACOSX/AtışPress.app/Contents/._MacOS
__MACOSX/AtışPress.app/Contents/Resources/
__MACOSX/AtışPress.app/Contents/Resources/._AppIcon.icns
__MACOSX/AtışPress.app/Contents/Resources/._LICENSE.txt
__MACOSX/AtışPress.app/Contents/._Resources
__MACOSX/AtışPress.app/Contents/._Info.plist
__MACOSX/AtışPress.app/Contents/._PkgInfo
__MACOSX/AtışPress.app/._Contents
```

Otomatik fixture’de çalıştırılabilir dosyanın adı `TestApp`’tir; aynı hata bu
adla da ilk kök girdisinde yeniden üretildi. Üretimdeki tam giriş listesi yukarıda
ayrıca gerçek `AtisPressApp` yürütülebiliriyle kontrol edildi.

Gerçek universal uygulama ZIP’i ayrıca dört birleşimde (NFC/NFD × eski/yeni
biçim) geçici CryptoKit anahtarıyla imzalanıp metadata, SHA-256, ZIP yapısı ve
codesign kontrollerinden geçirildi; dördü de geçti. Bu denemede bulunan büyük
DEFLATE akışının son çıktı tamponu durumu için de regresyon eklendi: Apple
Compression `OK` döndüğünde ilerleme varsa aynı sınırlı tamponla devam edilir;
yalnız `END`, tamamen tüketilmiş giriş, birebir boyut ve doğru CRC kabul edilir.
İlerlemesiz açıcı, artan çıktı veya sonda fazladan sıkıştırılmış veri reddedilir.

Son doğrulama: **387 test, 0 hata** (124 çekirdek, 70 PDF, 193 uygulama).
Son dosya sistemi bağlantı korumasından sonra 19 hedefli test de geçti.
Universal arm64/x86_64 uygulama yeniden derlendi; strict ad-hoc imza doğrulandı.
İlk regresyon eski kodda hata verdi; NFC/NFD ve eski/yeni biçimler düzeltilmiş
kodda geçti. LaunchServices kaydı sandbox’ta engellendi; paket oluşturuldu.
Ağ, Keychain anahtar üretimi, DMG oluşturma ve yayın/push yapılmadı.
