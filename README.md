# S82 RTK

South S82 RTK GNSS alıcısı için saha uygulaması (Android + iPhone, tek Flutter kodu).

- Android: S82'ye doğrudan klasik Bluetooth; iPhone: ESP32 BLE köprüsü
- Harita (OSM / uydu altlık), NetCAD .ncz okuma (nokta, çizgi, parsel)

- Bağlantı: ESP32 köprü (Nordic UART Service), `esp32/S82_BLE_Kopru`
- TUSAGA-Aktif NTRIP istemcisi (GGA gönderir, RTCM'i alıcıya iletir)
- ITRF96 → TM 3° (GRS80) dönüşümü
- Nokta ölçme (epok ortalaması), .ncn paylaşma
- Aplikasyon (mesafe, Kuzey/Doğu farkı, semt, kazı/dolgu)

## iPhone'a kurulum
1. GitHub → Actions → son "iPhone IPA derle" çalışması → **S82RTK-ipa** dosyasını indir, zip'ten `S82RTK.ipa`'yı çıkar.
2. Windows'ta Sideloadly ile Apple ID'nle iPhone'a yükle (ücretsiz hesapta 7 günde bir yenile).
3. iPhone: Ayarlar → Genel → VPN ve Aygıt Yönetimi → geliştiriciye güven.

`android-native/` klasöründe S82'ye doğrudan Bluetooth ile bağlanan Android uygulaması var.

## Lisans
GPL-2.0-or-later. NCZ okuyucu (`lib/ncz.dart`), Yusuf Eminoğlu'nun [cad2geo](https://pypi.org/project/cad2geo/) projesinin (GPL-2.0-or-later) Dart'a uyarlanmış alt kümesidir.
