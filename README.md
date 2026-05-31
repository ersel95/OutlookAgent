# OutlookAgent

macOS native SwiftUI uygulaması — **Microsoft Outlook for Mac (Classic)** ile AppleScript köprüsü üstünden konuşur, AI özellikleri (inbox triage, taslak yanıt, takvim önerileri, prospect discovery) için seçtiğiniz **AI sağlayıcısı**nı kullanır.

- Hedef kullanıcı: B2B SaaS satış / region manager iş akışı
- Min macOS: 14.0
- Sparkle ile otomatik güncelleme

## Kurulum

### Hızlı yol (binary)

[Latest release](https://github.com/ersel95/OutlookAgent/releases/latest)'ten `OutlookAgent-X.Y.Z.dmg` indir → mount et → `OutlookAgent.app`'i `/Applications`'a sürükle → aç. Notarized + stapled olduğu için Gatekeeper engellemez.

İlk açılışta:
1. Outlook'a AppleScript erişimi izni ver (System Settings → Privacy & Security → Automation)
2. **AI Sağlayıcı seçimi** modal'ı çıkar — aşağıdaki sağlayıcılardan birini seç

### Kaynaktan derleme

```bash
git clone https://github.com/ersel95/OutlookAgent.git
cd OutlookAgent
./build.sh                     # release build, /Applications/OutlookAgent.app'e in-place install
open /Applications/OutlookAgent.app
```

Geliştirme için:
```bash
swift build -c debug
swift run OutlookAgent
```

## AI Sağlayıcıları

OutlookAgent dört AI sağlayıcısını destekler. Settings (`⌘,`) menüsünden istediğin zaman değiştirebilirsin. API key'ler macOS Keychain'de saklanır; `config.json` sadece sağlayıcı seçimi + model + non-secret ayarları içerir.

### 1. Claude CLI (önerilen — ücretsiz, Claude Max abonesiyle sınırsız)

[`claude` CLI](https://docs.claude.com/en/docs/claude-code/overview)'i Anthropic'ın resmî command-line aracıdır. Subprocess olarak çağrılır, API key gerektirmez (kullanıcı kendi hesabıyla auth'ludur).

```bash
brew install --cask claude-code
claude login                   # browser açılır, Claude hesabınla giriş yap
```

Settings'te **"Claude CLI (lokal subprocess)"** seç. Binary path bırakırsan `/opt/homebrew/bin/claude`, `/usr/local/bin/claude`, `/usr/bin/claude` sırasıyla taranır.

### 2. Anthropic API

Direkt Anthropic REST API. API key'in [console.anthropic.com](https://console.anthropic.com) → Settings → API Keys'ten oluştur.

Settings'te:
- **API key**: `sk-ant-...`
- **Model**: `claude-opus-4-7` (en yetenekli) veya `claude-sonnet-4-6` (hızlı, ucuz)

### 3. OpenAI (ve OpenAI-uyumlu servisler)

OpenAI Chat Completions API'sini kullanır. `response_format: json_object` ile yapısal çıktı garanti edilir.

Settings'te:
- **API key**: `sk-...` ([platform.openai.com](https://platform.openai.com) → API Keys)
- **Model**: `gpt-4o` veya `gpt-5`
- **Base URL**: `https://api.openai.com/v1` (Azure OpenAI, Groq, OpenRouter gibi OpenAI-uyumlu servisler için değiştirilebilir)

### 4. Ollama (tamamen lokal, ücretsiz)

[Ollama](https://ollama.com) lokal LLM runner. Tek başına çalışır, internet/API key gerektirmez.

```bash
brew install ollama
ollama serve                   # arkaplan'da server başlat
ollama pull llama3.1           # veya qwen2.5, mistral
```

Settings'te:
- **Model**: `llama3.1` (veya pull ettiğin diğer model)
- **Base URL**: `http://localhost:11434`

## Özellikler

- **Inbox triage**: AI'ya mailler verilir → kategori (prospect/poc/contract/renewal/...), öncelik, kısa Türkçe özet, müşteri sağlığı sinyali
- **Taslak yanıt**: Tek tıkla bağlama uygun yanıt taslağı; Outlook drafts'a otomatik yazılır
- **Takvim**: Heatmap, slot finder, davet sheet, AI ile pipeline aşaması tagging
- **Multi-timezone**: Müşteri domain'inden TZ türetimi (TLD + override haritası)
- **Prospect discovery**: Mail içeriğinden potansiyel hesap çıkarımı

## Sert kısıtlar

- **Classic Outlook for Mac zorunlu** (yeni Outlook AppleScript inbox traversal'ını desteklemiyor — Help → Revert to Legacy Outlook)
- **macOS 14+**

## Otomatik güncelleme

App Sparkle 2.x ile `appcast.xml`'i poll eder (launch + günlük). Yeni sürüm bulunca kullanıcı onayıyla install eder. Yeni sürüm tag push (`v*`) ile CI tarafından otomatik build + sign + notarize + DMG + release create olur — `.github/workflows/release.yml`.

## Lisans

MIT. Detay: [CLAUDE.md](CLAUDE.md) (mimari + release pipeline detayları).
