# AtışPress 0.7.2 · build 12

- JPG/JPEG, PNG, TIFF, WebP ve HEIC dosyalarını PDF’lerle aynı işe ekleyebilirsiniz. HEIC ve WebP desteği macOS ImageIO’nun biçimi okuyabilmesine bağlıdır.
- Görsellerin baskı ölçüsünü milimetre ve DPI olarak düzenleyebilirsiniz. Gömülü DPI bulunmazsa 300 DPI kullanılır. AtışPress, etkin çözünürlük 150 DPI’ın altına düştüğünde uyarır.
- JPG ve PNG’nin aynı işte önizlenmesi ve iki sayfalı PDF’ye aktarılması kurulu Apple Silicon paketinde doğrulandı. Otomatik testler EXIF yönünü, PNG saydamlığını ve CMYK TIFF renk profilini kapsar. HEIC içe aktarma ve PDF çıktısı geçerli bir HEIC dosyasıyla ayrıca doğrulandı.
- Çalışma alanı ve sayfa listesi sürükle-bırak yolları aynı dosya konumu denetimini kullanır. JPG ve PNG için iki hedef de otomatik test edildi. Canlı Finder sürükle-bırak denemesi doğrulanamadı.
- Görsel yükleme hataları dosyaya erişim, biçim tanıma, piksel verisini açma ve çalışma PDF’si doğrulama aşamalarını ayrı bildirir.
