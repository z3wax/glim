# Glim — iPhone kamerasi bilan Reels / Shorts recorder (Ubuntu)

Glim — **Flutter**da yozilgan bitta ilova, ikki rolda ishlaydi:

| Qurilma | Vazifasi |
|---|---|
| **iPhone** (`.ipa`) | Kamera + mikrofonni USB kabel orqali kompyuterga uzatadi (iPhone = USB veb-kamera) |
| **Ubuntu** (`.deb`) | iPhone tasvirini qabul qilib, **9:16 vertikal** (1080×1920) Instagram Reels / YouTube Shorts / TikTok formatida MP4 (H.264 + AAC) yozadi |

## Imkoniyatlar

### 🧑‍💻 Kod yozish reels: ekran + iPhone kamera

Kompyuter ekranini (kod muharriri) yozib, iPhone kamerasini yuzingiz uchun veb-kamera qilib, ikkalasini **bitta 9:16 videoga** birlashtiradi:

| Rejim | Ko'rinishi |
|---|---|
| **Kamera** | faqat iPhone kamerasi |
| **Split** | tepada ekran (kod), pastda yuzingiz — ulushini 40–75% oralig'ida sozlash, "Kamera tepada" variantini tanlash mumkin |
| **Doira** | ekran butun kadrda, yuzingiz oq hoshiyali dumaloq oynachada (4 burchakdan birida, hajmi sozlanadi) |

- Ekran hududi: butun monitor yoki **"Hududni belgilash"** (sichqoncha bilan to'rtburchak chizasiz, `slop`). Panel ideal nisbatni ko'rsatadi (masalan Split 58% → 1080×1114 ≈ 1:1). Shunga yaqin hudud tanlasangiz, kod kadrni to'liq egallaydi.
- **Sig'dirish** (hudud to'liq ko'rinadi) yoki **To'ldirish** (crop)
- Sichqoncha kursorini ko'rsatish/yashirish
- Kod matni tiniq chiqishi uchun ekranli rejimlarda sifat avtomatik oshiriladi
- **Muharrirdan chiqmasdan boshqarish:** `glim-toggle` buyrug'ini global klaviatura yorlig'iga biriktiring:
  *Sozlamalar → Klaviatura → Maxsus yorliqlar → +* → Buyruq: `glim-toggle`, Yorliq: `Ctrl+Alt+R`
- Yozish paytida iPhone bir lahzaga uzilib qolsa, yozuv to'xtamaydi (oxirgi kadr ushlab turiladi)

> ⚠️ Ekran yozish **X11 (Xorg)** sessiyasida ishlaydi. Ubuntu 22.04+ standart holatda Wayland'da bo'ladi: tizimdan chiqing, login ekranidagi ⚙ tugmasidan **"Ubuntu on Xorg"** ni tanlang.

**Maslahatlar:** muharrir shriftini kattalashtiring (16–20pt), Glim oynasini yozilayotgan hududdan tashqariga yoki ikkinchi monitorga qo'ying, 3 soniyalik taymerdan foydalaning.

### Umumiy

- 🔌 **USB kabel orqali** ulanish (usbmuxd / `iproxy`) — Wi-Fi kerak emas, kechikish kam. Wi-Fi rejimi ham bor.
- 📱 Kamera tanlash (orqa, ultra-wide, telefoto, old), zoom, chiroq — ham iPhone'dan, ham kompyuterdan boshqariladi
- 🎬 1080×1920 yoki 720×1280, 30/60 fps, sifat (CRF) tanlash
- ✂️ Kadrlash: **To'ldirish (crop)** — gorizontal/vertikal surish bilan, yoki **Sig'dirish (blur)** — gorizontal video uchun xira fon
- 🎙️ Ovoz: iPhone mikrofoni, kompyuter mikrofoni (PulseAudio/PipeWire) yoki ovozsiz
- ⏱️ Davomiylik chegarasi (15s / 30s / 60s / 90s / 3 daq) va boshlashdan oldin taymer (3/5/10 s)
- 🟥 Instagram / YouTube interfeysi qoplaydigan **xavfsiz zonalar** va 1/3 to'r
- 🪞 Ko'zgu (mirror)
- 📷 **Virtual veb-kamera** (v4l2loopback) — OBS, Zoom, Google Meet, Telegram uchun
- ⌨️ `Space` yoki `Ctrl+R` — yozishni boshlash/to'xtatish
- Videolar `~/Videos/Glim/glim_reel_YYYYMMDD_HHMMSS.mp4` ga saqlanadi

## O'rnatish

Tayyor fayllar **[Releases](../../releases)** bo'limida.

### Ubuntu (22.04 / 24.04)

```bash
sudo apt install ./glim_1.0.0_amd64.deb
```

`.deb` o'zi `ffmpeg`, `usbmuxd`, `libusbmuxd-tools` (`iproxy`) va `libimobiledevice-utils` ni o'rnatadi.
`.tar.gz` versiyasini ishlatsangiz, ularni qo'lda o'rnating:

```bash
sudo apt install ffmpeg usbmuxd libusbmuxd-tools libimobiledevice-utils x11-xserver-utils slop
```

### iPhone (.ipa)

Release'dagi `Glim-x.y.z.ipa` **imzolanmagan** (Apple Developer hisobisiz yasalgan). Uni o'zingizning Apple ID'ingiz bilan o'rnating:

- **Sideloadly** yoki **AltStore / SideStore** — bepul Apple ID bilan ishlaydi (7 kunda qayta imzolash kerak);
- **TrollStore** — mos iOS versiyalarida doimiy o'rnatiladi;
- yoki Mac'da Xcode orqali o'zingiz yig'ing (pastga qarang).

iOS 16+ da: *Sozlamalar → Maxfiylik va xavfsizlik → Developer Mode* ni yoqing, keyin *Sozlamalar → Umumiy → VPN va qurilma boshqaruvi* da sertifikatga ishonch bildiring.

## Foydalanish

1. iPhone'ni USB kabel bilan kompyuterga ulang, iPhone'da **"Bu kompyuterga ishonasizmi? → Ishonish"** ni bosing.
   Tekshirish: `idevice_id -l` UDID chiqarishi kerak.
2. iPhone'da **Glim** ni oching, kamera va mikrofonga ruxsat bering — u avtomatik uzatishni boshlaydi (port 8686).
   🌙 tugmasi ekranni qoraytiradi (batareya tejash, ikki marta bosib qaytasiz).
3. Ubuntu'da **Glim** ni oching → *Ulanish: USB kabel*. Bir necha soniyada tasvir chiqadi.
4. Kadrni sozlang va 🔴 tugmasini (yoki `Space`) bosing.

**Wi-Fi rejimi:** iPhone va kompyuter bitta tarmoqda bo'lsin. iPhone ekranida ko'rsatilgan IP manzilni kompyuterdagi *Wi-Fi* maydoniga kiriting.

### Virtual veb-kamera (ixtiyoriy)

```bash
sudo apt install v4l2loopback-dkms
sudo modprobe v4l2loopback devices=1 video_nr=10 card_label="Glim iPhone" exclusive_caps=1
```

So'ng Glim'da *Virtual veb-kamera* ni yoqing — boshqa dasturlarda "Glim iPhone" kamerasi paydo bo'ladi.

## Qanday ishlaydi

```
iPhone (AVCaptureSession) ──JPEG kadrlar + PCM ovoz──► TCP :8686
        │                                                 ▲
        └────────── USB kabel (usbmuxd) ── iproxy 18686:8686
                                                          │
Ubuntu: Glim ──► 9:16 preview ──► ffmpeg (libx264 + AAC) ──► ~/Videos/Glim/*.mp4
                                    ▲
               ekran (x11grab) ─────┘  split: vstack · doira: alphamerge + overlay
                              └─► ffmpeg ──► /dev/video10 (v4l2loopback)
```

- iOS qismi: `ios/Runner/AppDelegate.swift` (kamera, JPEG kodlash, Network.framework server, Flutter texture preview)
- Protokol: `lib/protocol.dart` — `[turi: u8][uzunlik: u32 BE][ma'lumot]`
- Kompozitsiya: `lib/receiver/composer.dart` — preview va ffmpeg filtri bitta geometriyadan hisoblanadi, shuning uchun preview'da ko'rgan narsangiz aynan videoga tushadi
- Ubuntu qismi: `lib/receiver/` — ulanish (`phone_link.dart`), yozish (`recorder.dart`), preview, sozlamalar (`~/.config/glim/settings.json`)

Video kadrlar ffmpeg'ga devor soati bo'yicha doimiy fps bilan yoziladi, shuning uchun telefon kadr tashlab yuborsa ham ovoz bilan sinxronlik buzilmaydi.

## Manba koddan yig'ish

```bash
# Ubuntu
sudo apt install clang cmake ninja-build pkg-config libgtk-3-dev ffmpeg
flutter pub get
flutter build linux --release
packaging/build_deb.sh            # dist/glim_<v>_amd64.deb + .tar.gz

# macOS (iPhone uchun)
packaging/build_ipa.sh            # dist/Glim-<v>.ipa (imzolanmagan)
# yoki Xcode'da ios/Runner.xcworkspace ni ochib, Team tanlab, iPhone'ga Run
```

iPhone'siz sinash uchun soxta telefon simulyatori:

```bash
dart run tool/fake_phone.dart     # so'ng Glim'da Wi-Fi → 127.0.0.1
```

## Release chiqarish

`v*` teg push qilinsa GitHub Actions `.deb`, `.tar.gz` va `.ipa` ni yig'ib, avtomatik Release yaratadi:

```bash
git tag v1.0.1
git push origin v1.0.1
```

Yoki GitHub'da: **Actions → Build & Release → Run workflow** → `release_tag` ga `v1.0.1` yozing.

## Muammolar

| Belgi | Yechim |
|---|---|
| "iPhone USB orqali topilmadi" | Kabelni qayta ulang, iPhone'da "Ishonish"ni bosing, `sudo systemctl restart usbmuxd` |
| "iproxy topilmadi" | `sudo apt install libusbmuxd-tools` |
| "Glim ilovasini oching…" | iPhone'da ilova ochiq va ekran yoqiq bo'lsin (fonda kamera ishlamaydi) |
| Ekran qora chiqadi | Wayland sessiyasi — "Ubuntu on Xorg" bilan kiring |
| "Hududni belgilash" ishlamaydi | `sudo apt install slop` |
| Kadrlar sekin | iPhone sozlamalarida 720p yoki JPEG sifatini pasaytiring |
