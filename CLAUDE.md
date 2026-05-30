# OutlookAgent

macOS native SwiftUI uygulaması — Microsoft Outlook for Mac (**Classic** sürüm) ile AppleScript köprüsü üstünden konuşur, AI özellikleri için yerel `claude` CLI'yi subprocess olarak çağırır. Hedef kullanıcı: Agora.io Region Manager iş akışı (inbox triage, görev yönetimi, takvim, çoklu timezone, pipeline farkındalığı).

## Çalıştırma

```bash
./build.sh             # release derler, /Applications/OutlookAgent.app'i in-place günceller
swift build -c debug   # geliştirme sırasında hızlı derleme
swift run OutlookAgent # bundle dışında doğrudan çalıştır (TCC izinleri sıfırdan istenir)
```

`./build.sh` `/Applications/OutlookAgent.app` mevcutsa onu in-place yeniler — bu, macOS TCC izinlerinin (Apple Events, Automation) bundle ID üstünden hatırlanmasını sağlar. Yeni bir konuma kurulum: `INSTALL_DIR=/path ./build.sh`.

İlk çalıştırmada Outlook'a Apple Events erişim izni vermek gerekiyor (Sistem Ayarları → Gizlilik & Güvenlik → Otomasyon).

## Sert kısıtlar

- **Classic Outlook for Mac zorunlu.** Yeni Outlook AppleScript inbox traversal'ını desteklemiyor; `OutlookError.newOutlookUnsupported` ile yakalanıyor (Help → Revert to Legacy Outlook).
- **`claude` CLI gerekir** (`/opt/homebrew/bin/claude`). Anthropic API key kullanılmıyor; AI çağrıları `Process` ile `claude -p "<prompt>" --output-format json` şeklinde yapılır, sonuç JSON'un `result` alanından parse edilir.
- **macOS 14+** (`Package.swift` içinde `.macOS(.v14)` pinli).

## Mimari

```
App.swift                       SwiftUI @main, ⌘1/2/3 feature shortcut'ları
AppViewModel                    @Observable @MainActor, top-level state
RootView                        feature sidebar + içerik
Views/
  InboxView, ThreadView         3-pane mail görünümü, chat-style thread bubble'ları
  TasksFeatureView              filtreli görev yönetimi
  CalendarFeatureView           sidebar / agenda / detail; heatmap, slot finder, invite sheet
  RightPanelView                inbox sağ panel: taslak yanıt + mailden görev çıkar
Services/                       hepsi `actor`, paralel-güvenli
  OutlookService                AppleScript runner (osascript subprocess)
  ClaudeService                 `claude -p` runner; JSON-tolerans extract
  TaskStore, TriageStore,       JSON-backed persistence (~/Library/App Support/OutlookAgent)
  CalendarStore
  TimezoneStrategy              domain → IANA TZ haritası (TLD + override)
  AgoraContext                  system prompt + Agora-specific sözlükler
  EmailBodyParser, BodyFormatter mail gövdesi/quote ayrıştırma
Models/                         Email, EmailFull, EmailThread, ThreadMessage,
                                CalendarEvent, TaskItem, TriageResult, AppFeature
Scripts/                        AppleScript dosyaları, `Bundle.module` ile yüklenir
  list_inbox, read_email, list_thread, mark_read, delete_email,
  create_draft, list_calendar, create_calendar_event
```

### Veri akışı

1. **Outlook → Swift**: AppleScript stdout'u base64-encoded payload üretir; alan ayracı `0x1F` (US), kayıt ayracı `0x1E` (RS). `OutlookService.parseInboxPayload` / `parseCalendarPayload` decode eder.
2. **Swift → Claude**: `ClaudeService.runClaude(prompt:)` → subprocess → JSON `result` field'ı → `extractJSON` (kod-fence toleransı). Calendar/triage prompt builder'ları `AgoraContext.systemPrompt` ile prefix'lenir.
3. **Persistance**: `~/Library/Application Support/OutlookAgent/` → `tasks.json`, `triage.json`, `calendar.json`, `calendar_enrichment.json`, `calendar_focus.json`. Görsel ekler `~/Library/Caches/OutlookAgent/attachments/<msgId>/`.

## AppleScript pitfall — reserved keyword'ler

Outlook for Mac dictionary ile AppleScript core arasında bazı çakışan terimler var. Bunlar `tell application "Microsoft Outlook"` blokunun içinde bile parser'ı kırıyor:

| Token              | Sorun                                                | Geçici çözüm                                  |
|--------------------|------------------------------------------------------|-----------------------------------------------|
| `st`               | Identifier olarak parse edilemez                     | `evST`, `evStartTime` gibi 3+ harf kullan     |
| `response status`  | calendar event / attendee property — parse hatası    | Atla; cevap durumunu Swift'te attendee listesinden türet |
| `reminder set`     | Property + `set` keyword çakışması                   | Atla; `hasReminder` default `false`           |
| `recurring`        | Bazı bağlamlarda parse hatası                        | Atla; `isRecurring` default `false`           |

`list_calendar.applescript` bu tuzakları `responseString` handler'ı koruyarak ama property erişimini kısıtlayarak çözüyor; gelecekte yeni bir Outlook script'i eklerken aynı kalıbı uygula.

## Pipeline & TZ haritalama

- **Triage kategorileri** (`AgoraContext.allowedCategories`): prospect, poc, contract, renewal, churnRisk, technical, partner, internalNote, calendar, marketing, spam, other.
- **Pipeline aşamaları** (`CalendarEvent.PipelineStage`): yukarıdakine paralel + `qbr`, `focus`. Claude `classifyMeetings` ile tag'lenir, `enrichment` cache'ine yazılır.
- **TZ override'ları** (`TimezoneStrategy.customerOverrides`): rakip & büyük partner domain'leri pin'li. Geri kalanı ccTLD haritasından (`.com.tr`, `.co.uk`, `.com.cn` vb.). Bilinmeyen domain → `nil` (zorla tahmin yapma).

## Test

Otomatik test yok. Akış:

```bash
./build.sh                                     # /Applications/OutlookAgent.app güncellenir
osacompile -o /tmp/check.scpt Sources/OutlookAgent/Scripts/list_calendar.applescript
                                               # AppleScript syntax sanity
open /Applications/OutlookAgent.app            # gerçek Outlook ile manuel doğrulama
```

UI/davranış doğrulaması elle yapılır — değişiklik sonrası ⌘1/2/3 ile her feature'ı dolaş, "Yenile" → liste güncel, mail/görev/etkinlik seçimi → detay paneli akıyor mu kontrol et.

## Release & otomatik güncelleme (Sparkle)

`v1.2.3` formunda tag push → `.github/workflows/release.yml` tetiklenir → DMG build + Developer ID sign + Apple notarization + EdDSA imza + `appcast.xml`'e item insert + GitHub Release. App çalışırken `SUFeedURL` (raw `appcast.xml`) launch'ta ve günlük (`SUScheduledCheckInterval=86400`) poll eder, yeni sürüm bulursa kullanıcıya sorar (`SUAutomaticallyUpdate=false`).

### İlk kurulum (tek seferlik)

1. **EdDSA key pair üret** (Sparkle 2.9.2):
   ```bash
   curl -fsSL https://github.com/sparkle-project/Sparkle/releases/download/2.9.2/Sparkle-2.9.2.tar.xz | tar -xJ -C /tmp
   /tmp/bin/generate_keys
   ```
   Public key → GitHub secret `SU_PUBLIC_ED_KEY`, private key → GitHub secret `SPARKLE_ED_PRIVATE_KEY`. (Private key'i lokal Keychain'de de saklar — kaybedersen yeni public key ile tüm kullanıcılar update almaz.)

2. **GitHub Secrets** (Settings → Secrets and variables → Actions):
   - `DEVELOPER_ID_CERT_P12_BASE64` — Keychain Access'tan "Developer ID Application" sertifikası export .p12 → `base64 -i cert.p12`
   - `DEVELOPER_ID_CERT_PASSWORD` — yukarıdaki .p12'nin parolası
   - `SIGNING_IDENTITY` — tam string: `Developer ID Application: Adın Soyadın (TEAMID)`
   - `ASC_KEY_P8_BASE64` — App Store Connect API key (.p8) base64
   - `ASC_KEY_ID` — ASC API Key ID (10 char)
   - `ASC_ISSUER_ID` — ASC Issuer ID (UUID)
   - `SU_PUBLIC_ED_KEY` — yukarıda üretilen Sparkle public key (base64)
   - `SPARKLE_ED_PRIVATE_KEY` — yukarıda üretilen Sparkle private key

### Release süreci

```bash
git tag v1.0.1 && git push origin v1.0.1
# CI: build → sign → notarize → DMG → notarize DMG → sign_update (EdDSA)
#     → appcast.xml'e item push (main) → gh release create
```

CI bittiğinde `https://github.com/ersel95/OutlookAgent/releases/download/v1.0.1/OutlookAgent-1.0.1.dmg` indirilebilir, ve eski kurulumlar Sparkle ile otomatik upgrade'i görür.

### Lokal dev

`./build.sh` ad-hoc imza (`-`) ile çalışır; Sparkle.framework `.build/`'den `Contents/Frameworks/`'e kopyalanır ve iç bileşenler ad-hoc imzalanır. Auto-update lokal dev'de `SUFeedURL` raw GitHub'a baktığı için yine de çalışır (ama yeni release'leri lokal değişiklikler aşmaz — `VERSION` env ile override edilebilir: `VERSION=0.0.0 ./build.sh`).

## Stil

- Türkçe yazışıyoruz; teknik terimler / identifier'lar İngilizce kalır.
- AI çıktıları default Türkçe (mail dili İngilizce ise ona uy).
- Asistan kendini "AI" olarak sunmaz — `AgoraContext.systemPrompt` doğal yardımcı tonu enjekte eder.
- Yorum: yalnızca *neden* açıklığa kavuşturulması gerektiğinde — ne yaptığını isim açıklasın.
