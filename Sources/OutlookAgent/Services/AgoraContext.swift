import Foundation

enum AgoraContext {
    static let userName = "Ersel Tarhan"
    static let userRole = "Region Manager @ Agora.io"
    static let userEmail = "ersel.tarhan@agora.io"

    static let systemPrompt = """
    Sen Ersel Tarhan'ın (Agora.io Region Manager, ersel.tarhan@agora.io) kişisel \
    e-posta asistanısın. Agora.io gerçek-zamanlı ses, video, sinyal ve konuşma yapay \
    zekâ SDK'ları sağlayan bir CPaaS sağlayıcısı. Müşterileri SDK'yı entegre eden \
    geliştiriciler ve B2B kurumlardır.

    Region Manager rolünün anahtar bağlamı:
    - Bölgesel pipeline yönetimi (prospect → POC → contract → renewal)
    - Müşteri sağlığı izleme (SDK kullanım düşüşü, churn sinyalleri)
    - Teknik soruları doğru ekibe yönlendirme (Solutions Engineer, DevRel, Support)
    - Partner / reseller / ISV ilişkileri
    - Veri yerleşimi & uyum (GDPR, Çin, Hindistan veri yönetmeliği)
    - Çoklu zaman dilimi koordinasyonu
    - QBR (Quarterly Business Review), executive briefing hazırlık

    Rakipler: Twilio, Daily.co, LiveKit, Vonage/Vonage Video, ZEGOCLOUD, \
    Tencent RTC, AWS IVS, Dolby.io, Stream.io, 100ms, Sinch.

    Önemli ürün isimleri: Agora RTC SDK, Agora RTM (signaling), Agora Chat, \
    Conversational AI Engine, Real-Time STT, Cloud Recording, Voice/Video Calling, \
    Interactive Live Streaming, Co-host token, App ID, App Certificate.

    Yanıtlarında:
    - Türkçe yaz (kullanıcının dili).
    - Profesyonel, kısa, net ol — pazarlama dili kullanma.
    - Yapay zekâ olduğunu belirtme; doğal yardımcı gibi davran.
    - Kararsızsan "?" ile işaretle, uydurma.
    """

    /// Common dictionaries used by the model when asked for structured output.
    static let allowedCategories: [String] = [
        "prospect","poc","contract","renewal","churnRisk","technical",
        "partner","internalNote","calendar","marketing","spam","other"
    ]
    static let allowedPriorities = ["urgent","high","normal","low"]
    static let knownCompetitors = [
        "Twilio","Daily","LiveKit","Vonage","ZEGOCLOUD","Tencent RTC",
        "AWS IVS","Dolby.io","Stream.io","100ms","Sinch"
    ]

    /// AI SDR (Prospects feature) için ek bağlam — Salesforce 24-aylık won/lost
    /// analizinden çıkmış ICP V1. Skor + sequence drafter prompt'larına eklenir.
    static let icpProfile = """
    AGORA ICP V1 (data-driven, 24-aylık won/lost analizinden):

    EN İYİ KAZANILAN VERTICAL'LAR (yüksek WR + volume):
    • Social audio/video community (WR %69, 189 won)
    • Future of Work / B2B collaboration (WR %67, 206 won)
    • Live-Commerce / E-Commerce Live Streaming (WR %61, 98 won)
    • Faith Tech (WR %88, küçük ama yüksek)

    ANTI-ICP (DÜŞÜK WR — farklı angle gerekir):
    • Telehealth (WR %33) — rakip switch + somut latency/scale avantajı angle'ı şart
    • Enterprise Collaboration / B2B Video Conferencing (WR %35-36)
    • Gaming RTC (WR %40)
    • Series B startups (0/8, anomalous — re-evaluation araştırma temalı)
    • France HQ (0/3)

    FUNDING SWEET SPOT:
    • Seed (WR %60), Series A (WR %48) — sweet spot
    • Series C+ (WR %50)
    • Series B → ATLA ya da farklı angle (re-evaluation)

    USE CASE WIN PATTERN:
    • Yüksek WR: Live stream (60%), E-Commerce Live Streaming (52%), Live Events/Broadcast (44%)
    • Anti: Telehealth, Enterprise Collaboration, B2B Video Platform

    KAZANILAN DEAL DOLAR BANDI:
    • Sweet spot: $50K–$200K yıllık ARR (Year_Projection_ARR_Rollup__c)

    BAĞIMSIZ KIRMIZI/YEŞİL SİNYAL:
    • YEŞİL: rakip RTC SDK kullanan ya da hiç RTC kullanmayan, ölçeklenmeye hazır
      (Apptopia'da Twilio/ZEGOCLOUD/Daily/LiveKit detect edilmiş app'ler birinci öncelik)
    • Already_using_Agora_SDK = false → AMER/EMEA wins'in 46/46'sında bu doğru
      (yani tüm wins rakip switch / cold adopter — mevcut müşteriden upsell değil)

    SCOPE & ÖNCELİK (2026-05-09):
    • Yetki: tüm Avrupa
    • V0/V1 öncelik: TÜRKİYE (Ersel'in yerel network + dil + kültürel okuma avantajı)
    • TR'de ICP V1 verisi WR %37 — anti-ICP eşiğine yakın; hyper-personalization'ın
      bu pazarda WR'yi yükseltebileceği hipotezini test ediyoruz.
    • TR'den sonra UK (WR %77 — yüksek), Sweden, Northern Europe, Almanya, vb.

    SEQUENCE STRATEJİSİ:
    • Email = otomatik (Outlook auto-send), LinkedIn = manuel (ToS gereği,
      tool draft eder + Sales Nav UI'da Ersel manuel atar).
    • Hyper-personalization şart: her step'te 1-2 spesifik referans
      (son funding, kullandıkları rakip SDK, kişinin LinkedIn rolü/geçmişi).
    • Anti-ICP'ye girerken jenerik "Agora is great" değil, "rakip switch + somut
      teknik avantaj (latency/scale/fiyat)" angle'ı.
    """
}
