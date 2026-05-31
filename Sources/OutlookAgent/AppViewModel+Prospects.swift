import Foundation
import SwiftUI

// MARK: - Prospects pipeline orchestration

extension AppViewModel {

    // MARK: - Computed (filter + sort)

    var visibleProspects: [Prospect] {
        var out = prospectStore.prospects
        if !prospectShowDeleted {
            out = out.filter { !$0.isDeleted }
        }
        if let s = prospectStatusFilter {
            out = out.filter { $0.status == s }
        }
        if let q = prospectQueueFilter {
            out = out.filter { $0.queue == q }
        }
        let qStr = prospectSearchQuery.trimmingCharacters(in: .whitespaces).lowercased()
        if !qStr.isEmpty {
            out = out.filter { p in
                p.companyName.lowercased().contains(qStr)
                || p.domain.lowercased().contains(qStr)
                || p.contact.fullName.lowercased().contains(qStr)
                || p.contact.email.lowercased().contains(qStr)
                || (p.industry?.lowercased().contains(qStr) ?? false)
            }
        }
        // Türkiye-first, sonra status öncelik, sonra skor.
        out.sort { (a, b) in
            if a.isTurkey != b.isTurkey { return a.isTurkey && !b.isTurkey }
            if a.status.sortOrder != b.status.sortOrder {
                return a.status.sortOrder < b.status.sortOrder
            }
            let sa = a.score?.combined ?? 0
            let sb = b.score?.combined ?? 0
            if sa != sb { return sa > sb }
            return a.updatedAt > b.updatedAt
        }
        return out
    }

    var selectedProspect: Prospect? {
        guard let id = selectedProspectId else { return nil }
        return prospectStore.prospect(id: id)
    }

    // MARK: - Import (paste-and-parse)

    func importProspectFromText() async {
        let text = prospectImportText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        isImportingProspect = true
        prospectImportError = nil
        defer { isImportingProspect = false }
        do {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withFullDate]
            let tag = "paste-\(f.string(from: Date()))"
            let parsed = try await ClaudeService.shared.parseProspectFromText(text, sourceTag: tag)
            // Dedup: aynı domain'de mevcut varsa hata göster.
            if let dup = prospectStore.byDomain(parsed.domain) {
                prospectImportError = "\(parsed.companyName) zaten kuyrukta (\(dup.status.label))."
                return
            }
            prospectStore.add(parsed)
            selectedProspectId = parsed.id
            prospectImportText = ""
            prospectShowImport = false
        } catch {
            prospectImportError = error.localizedDescription
        }
    }

    // MARK: - Auto-discovery (Claude WebSearch)

    /// Vertical + ülke verince Claude WebSearch ile gerçek şirketleri keşfeder.
    /// Sonuç toplu prospect — domain bazında dedup, mevcut olanlar atlanır.
    func runAutoDiscovery() async {
        let vertical = discoveryVertical.trimmingCharacters(in: .whitespaces)
        let country  = discoveryCountry.trimmingCharacters(in: .whitespaces)
        guard !vertical.isEmpty, !country.isEmpty else {
            prospectImportError = "Vertical ve ülke boş bırakılamaz."
            return
        }
        isImportingProspect = true
        aiHighPriorityBusy = true
        prospectImportError = nil
        let startTime = Date()
        AppLogger.shared.info(.prospectPipeline, "auto-discovery başlatıldı", metadata: [
            "vertical": .string(vertical),
            "country":  .string(country),
            "count":    .int(discoveryCount)
        ])
        defer {
            isImportingProspect = false
            aiHighPriorityBusy = false
        }
        do {
            let discovered = try await ClaudeService.shared.discoverProspects(
                vertical: vertical, country: country, count: discoveryCount
            )

            // Aliveness check — AI eski/kapanmış startup'ları döndürebilir
            // (vidyodan.com / clickmelive.com vakası). Her domain için DNS + HTTPS HEAD.
            prospectBusyLabel = "Domain kontrolü"
            var alive: [Prospect] = []
            var deadDomains: [String] = []
            for p in discovered {
                let health = await EmailVerifierService.shared.checkDomainHealth(p.domain)
                AppLogger.shared.debug(.prospectPipeline, "domain health", metadata: [
                    "domain": .string(p.domain),
                    "health": .string(health.rawValue)
                ])
                if health == .alive || health == .unknown {
                    alive.append(p)
                } else {
                    deadDomains.append("\(p.companyName) (\(p.domain))")
                }
            }

            let result = prospectStore.ingest(alive)
            let parts = [
                "\(result.added) yeni prospect eklendi",
                result.dupActive > 0 ? "\(result.dupActive) zaten kuyrukta" : nil,
                result.dupDeleted > 0 ? "\(result.dupDeleted) önceden silinmiş (atlandı)" : nil,
                deadDomains.count > 0 ? "\(deadDomains.count) kapalı domain atlandı" : nil
            ].compactMap { $0 }
            lastImportSummary = parts.joined(separator: ", ") + "."
            prospectShowImport = false
            AppLogger.shared.info(.prospectPipeline, "auto-discovery başarılı", metadata: [
                "elapsedMs":     .int(Int(Date().timeIntervalSince(startTime) * 1000)),
                "returned":      .int(discovered.count),
                "alive":         .int(alive.count),
                "added":         .int(result.added),
                "dupActive":     .int(result.dupActive),
                "dupDeleted":    .int(result.dupDeleted),
                "skippedDead":   .int(deadDomains.count),
                "deadDomains":   .string(deadDomains.joined(separator: " · ")),
                "firstName":     .string(alive.first?.companyName ?? "—")
            ])
            // İlk eklenen prospect'i seç ki kullanıcı detayı görsün.
            if let first = discovered.first(where: { p in
                prospectStore.prospects.contains(where: { $0.id == p.id })
            }) {
                selectedProspectId = first.id
            }
            // Auto-status badge timer.
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                self.lastImportSummary = nil
            }
        } catch {
            prospectImportError = error.localizedDescription
            AppLogger.shared.error(.prospectPipeline, "auto-discovery hata", metadata: [
                "vertical":  .string(vertical),
                "country":   .string(country),
                "elapsedMs": .int(Int(Date().timeIntervalSince(startTime) * 1000)),
                "error":     .string(error.localizedDescription)
            ])
        }
    }

    /// Apple iTunes Lookup API ile App Store'dan TR (ya da seçilen ülke) market
    /// app discovery. Apptopia-lite — SDK detect yok ama mobile-first şirketleri
    /// bedava + hızlı bulmak için yeterli.
    func runAppStoreDiscovery() async {
        let query = appStoreQuery.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else {
            prospectImportError = "Arama sorgusu boş bırakılamaz."
            return
        }
        isImportingProspect = true
        prospectImportError = nil
        defer { isImportingProspect = false }
        do {
            let discovered = try await AppStoreDiscoveryService.shared.search(
                query: query, country: appStoreCountry, limit: appStoreLimit
            )
            let result = prospectStore.ingest(discovered)
            let parts = [
                "\(result.added) yeni app developer eklendi",
                result.dupActive > 0 ? "\(result.dupActive) zaten kuyrukta" : nil,
                result.dupDeleted > 0 ? "\(result.dupDeleted) önceden silinmiş (atlandı)" : nil
            ].compactMap { $0 }
            lastImportSummary = parts.joined(separator: ", ") + "."
            prospectShowImport = false
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                self.lastImportSummary = nil
            }
        } catch {
            prospectImportError = error.localizedDescription
        }
    }

    /// Tek bir prospect'i WebSearch + WebFetch ile zenginleştirir. Boş alanları
    /// doldurur, doluları korur. Halihazırda discovered/matched/excluded'da
    /// faydalı (henüz score/draft yapılmamış olanlar).
    func runWebEnrichment(prospectId: UUID) async {
        guard let p = prospectStore.prospect(id: prospectId) else { return }
        prospectBusyId = prospectId
        prospectBusyLabel = "Webden zenginleştirme"
        aiHighPriorityBusy = true
        defer {
            prospectBusyId = nil
            prospectBusyLabel = nil
            aiHighPriorityBusy = false
        }
        do {
            let merged = try await ClaudeService.shared.enrichProspectFromWeb(p)
            prospectStore.update(merged)
        } catch {
            errorMessage = "Web zenginleştirme hatası: \(error.localizedDescription)"
        }
    }

    // MARK: - Pipeline steps

    /// Salesforce dedup query'sini çalıştırır + result'a göre statüyü günceller.
    func runDedup(prospectId: UUID) async {
        guard let p = prospectStore.prospect(id: prospectId) else { return }
        prospectBusyId = prospectId
        prospectBusyLabel = "Salesforce dedup"
        defer {
            prospectBusyId = nil
            prospectBusyLabel = nil
        }
        do {
            let result = try await SalesforceService.shared.dedupCheck(
                domain: p.domain, email: p.contact.email
            )
            prospectStore.setDedup(prospectId, result)
        } catch {
            errorMessage = "Dedup hatası: \(error.localizedDescription)"
        }
    }

    /// Claude ile ICP + revenue skoru hesapla. Salesforce'taki Crunchbase /
    /// Agora-spesifik field'ları otomatik çekip prompt'a inject eder.
    func runScoring(prospectId: UUID) async {
        guard let p = prospectStore.prospect(id: prospectId) else { return }
        prospectBusyId = prospectId
        prospectBusyLabel = "AI skorlama"
        aiHighPriorityBusy = true
        defer {
            prospectBusyId = nil
            prospectBusyLabel = nil
            aiHighPriorityBusy = false
        }
        do {
            // Crunchbase/SF enrichment'ı önce çek (en kötü ihtimalle nil — fail soft).
            let enrichment = try? await SalesforceService.shared.enrichAccount(domain: p.domain)
            let score = try await ClaudeService.shared.scoreProspect(
                p, dedup: p.dedup, enrichment: enrichment
            )
            prospectStore.setScore(prospectId, score)
        } catch {
            errorMessage = "Skor hatası: \(error.localizedDescription)"
        }
    }

    /// Claude ile sequence draft'ları üret.
    /// Calendar slot'ları ilk email step'inin CTA'sına otomatik enjekte edilir.
    func runSequenceDraft(prospectId: UUID) async {
        guard let p = prospectStore.prospect(id: prospectId) else { return }
        prospectBusyId = prospectId
        prospectBusyLabel = "Sequence draft"
        aiHighPriorityBusy = true
        defer {
            prospectBusyId = nil
            prospectBusyLabel = nil
            aiHighPriorityBusy = false
        }

        // Mevcut CalendarStore + freeSlots reuse — önümüzdeki 5 iş günündeki müsait slot'lar.
        let cal = Calendar.current
        let now = Date()
        let from = cal.date(byAdding: .day, value: 1, to: now) ?? now
        let to = cal.date(byAdding: .day, value: 7, to: now) ?? now
        let slots = calendarStore.freeSlots(
            from: from, to: to,
            workingHourStart: 10, workingHourEnd: 17, minMinutes: 30
        )
        let custTz = TimezoneStrategy.timezoneId(for: p.domain)
        let enrichment = try? await SalesforceService.shared.enrichAccount(domain: p.domain)

        do {
            let steps = try await ClaudeService.shared.draftProspectSequence(
                p, dedup: p.dedup, score: p.score, queue: p.queue,
                availableSlots: Array(slots.prefix(6)),
                customerTimezone: custTz,
                enrichment: enrichment
            )
            prospectStore.setSequence(prospectId, steps)
        } catch {
            errorMessage = "Sequence draft hatası: \(error.localizedDescription)"
        }
    }

    /// "Hepsini onayla" — drafted step'leri approved'a alır.
    func approveAllSteps(prospectId: UUID) {
        prospectStore.approveAll(prospectId: prospectId)
    }

    /// Tek bir step'i atla.
    func skipStep(prospectId: UUID, stepId: UUID) {
        prospectStore.updateStep(prospectId: prospectId, stepId: stepId) { step in
            step.status = .skipped
        }
    }

    /// Bir sonraki gönderilebilir step'i çalıştırır.
    /// - Email: Outlook auto-send (email yoksa AI pattern guess + DNS MX kontrolü).
    /// - LinkedIn: clipboard'a kopya + Sales Nav URL açma (kullanıcı manuel atar).
    func sendNextStep(prospectId: UUID) async {
        guard let p0 = prospectStore.prospect(id: prospectId),
              let step = p0.nextStep else { return }

        // Safety: bugünkü hard bounce eşiği aşıldıysa global pause'da; send'i tamamen blokla.
        if globalSendingPaused {
            errorMessage = "Sending pause — bugün \(dailyBounceCount) bounce var. " +
                "Inbox'taki postmaster'ları gözden geçir, sequence'leri manuel düzelt, " +
                "sonra 'Pause'u Kaldır' butonuna bas."
            return
        }

        prospectBusyId = prospectId
        prospectBusyLabel = "Gönderiliyor (\(step.channel.label))"
        defer {
            prospectBusyId = nil
            prospectBusyLabel = nil
        }

        // Step approved değilse otomatik onay (kullanıcı bilinçli "Şimdi Gönder" dedi).
        if step.status == .drafted {
            prospectStore.updateStep(prospectId: prospectId, stepId: step.id) { s in
                s.status = .approved
            }
        }

        switch step.channel {
        case .email:
            // Email yoksa: önce DNS MX kontrolü, sonra pattern guess.
            var current = prospectStore.prospect(id: prospectId) ?? p0
            if current.contact.email.isEmpty {
                if !(await ensureEmailForProspect(prospectId: prospectId)) {
                    errorMessage = "Email tahmini yapılamadı — manuel ekle ya da prospect'i atla."
                    return
                }
                // ensureEmail prospect'i güncelledi, fresh oku.
                current = prospectStore.prospect(id: prospectId) ?? current
            }
            await sendEmailStep(prospect: current, step: step)
        case .linkedinConnect, .linkedinMessage, .linkedinInMail:
            await prepareLinkedInStep(prospect: p0, step: step)
        }
    }

    /// Send öncesi email yoksa DNS MX → cache → AI pattern guess pipeline'ı.
    /// Başarılı → prospect.contact.email güncellenir, ilgili pattern cache'e
    /// `.guessed` confidence ile yazılır. Başarısız → false.
    @discardableResult
    func ensureEmailForProspect(prospectId: UUID) async -> Bool {
        guard let p = prospectStore.prospect(id: prospectId) else { return false }
        if !p.contact.email.isEmpty { return true }

        prospectBusyLabel = "Email tahmini"

        // 1. DNS MX sanity — domain mail kabul ediyor mu?
        do {
            let hasMX = try await EmailVerifierService.shared.hasMXRecord(p.domain)
            if !hasMX {
                errorMessage = "\(p.domain) için MX kaydı yok — domain mail kabul etmiyor."
                return false
            }
        } catch {
            // dig hatası fatal değil — MX yokmuş gibi davranma, sadece logla.
        }

        // 2. Cache + AI pattern guess
        do {
            let candidate = try await EmailVerifierService.shared.emailCandidate(
                for: p, cache: emailPatternCache
            )
            // Cache'e guessed olarak yaz (henüz denemedik).
            emailPatternCache.recordGuess(
                domain: p.domain, template: candidate.template, sample: candidate.email
            )
            // Prospect'e ata.
            var updated = p
            updated.contact.email = candidate.email
            // Hangi pattern kullanıldığını notes'a ekle (debug + kullanıcı için).
            let note = "\nEmail pattern: \(candidate.template) (\(candidate.source))"
            if !updated.notes.contains(note) {
                updated.notes += note
            }
            prospectStore.update(updated)
            return true
        } catch {
            errorMessage = "Email tahmin hatası: \(error.localizedDescription)"
            return false
        }
    }

    // MARK: - Bounce detection (V2 — sender reputation safety)

    /// Outlook inbox'ında postmaster mail'lerini tespit eder.
    /// Hard bounce → ilgili prospect'in en son sent step'ini `.failed` yapar,
    /// pattern cache'i `.failed` işaretler, prospect'i `.paused`'a çeker.
    /// Günlük bounce sayacı eşiği aştığında `globalSendingPaused = true`.
    func detectBouncesInInbox() async {
        guard !emails.isEmpty else { return }
        rolloverDailyBounceIfNeeded()

        // Sender / subject heuristic — postmaster maili mi?
        let bounceSenders = [
            "mailer-daemon", "postmaster", "noreply.protection.outlook",
            "no-reply", "delivery", "sysadmin"
        ]
        let bounceSubjectKeywords = [
            "undeliverable", "delivery has failed", "delivery status notification",
            "returned mail", "mail delivery failed", "failure notice",
            "delivery report", "could not be delivered"
        ]

        for mail in emails {
            let fromLc = mail.fromAddress.lowercased()
            let subjLc = mail.subject.lowercased()
            let isBounceSender  = bounceSenders.contains  { fromLc.contains($0) }
            let isBounceSubject = bounceSubjectKeywords.contains { subjLc.contains($0) }
            guard isBounceSender || isBounceSubject else { continue }

            // Bu maili daha önce işledik mi? (Step.outlookMessageId üzerinden basit dedup.)
            let alreadyProcessed = prospectStore.prospects.contains { p in
                p.sequenceSteps.contains { $0.failureReason?.contains("msgId:\(mail.id)") == true }
            }
            if alreadyProcessed { continue }

            // Bounce body'sinden orijinal alıcı çıkar.
            let bouncedAddr: String?
            do {
                let full = try await OutlookService.shared.readEmail(id: mail.id)
                bouncedAddr = Self.extractBouncedAddress(from: full.body)
            } catch {
                continue
            }
            guard let addr = bouncedAddr?.lowercased(), !addr.isEmpty else { continue }

            // İlgili prospect'i bul.
            guard let prospect = prospectStore.prospects.first(where: {
                $0.contact.email.lowercased() == addr
            }) else { continue }

            // En son sent edilmiş step'i fail işaretle.
            guard let lastSent = prospect.sequenceSteps.last(where: { $0.status == .sent }) else { continue }
            prospectStore.updateStep(prospectId: prospect.id, stepId: lastSent.id) { s in
                s.status = .failed
                s.failureReason = "Bounce: \(addr) — msgId:\(mail.id)"
            }
            prospectStore.setStatus(prospect.id, .paused)

            // Pattern cache: bu pattern başarısız → bir sonraki prospect'te dışla.
            // Pattern'i prospect.notes'tan çıkar (ensureEmail "Email pattern: X" yazıyor).
            if let template = Self.extractTemplateFromNotes(prospect.notes) {
                emailPatternCache.recordFailure(
                    domain: prospect.domain, template: template, sample: addr
                )
            }

            // Daily counter + safety guard.
            dailyBounceCount += 1
            if dailyBounceCount >= dailyBounceLimit {
                globalSendingPaused = true
                errorMessage = "Sender reputation koruması: bugün \(dailyBounceCount) bounce — " +
                    "tüm sending otomatik pause edildi."
            }
        }
    }

    /// Yeni gün → sayaç sıfırla.
    private func rolloverDailyBounceIfNeeded() {
        let today = Calendar.current.startOfDay(for: Date())
        if dailyBounceCountDate != today {
            dailyBounceCount = 0
            dailyBounceCountDate = today
        }
    }

    /// Pause'u manuel kaldır — kullanıcı inbox'taki postmaster mail'lerini gözden
    /// geçirip sequence'leri düzeltince tekrar send'e izin verilir.
    func resumeSendingAfterBounceReview() {
        globalSendingPaused = false
        errorMessage = nil
    }

    /// Bounce mail body'sinden orijinal alıcı email adresini çıkarır.
    /// Standart NDR formatları: `Final-Recipient: rfc822; addr@dom`,
    /// `Original-Recipient: ...`, ya da gövdede `<addr@dom>` ifadesi.
    private nonisolated static func extractBouncedAddress(from body: String) -> String? {
        // 1. RFC 3464 DSN: "Final-Recipient: rfc822; foo@bar.com"
        if let r = body.range(of: #"(?i)final-recipient[^;]*;\s*[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+"#,
                              options: .regularExpression) {
            let chunk = String(body[r])
            if let mr = chunk.range(of: #"[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+"#,
                                    options: .regularExpression) {
                return String(chunk[mr])
            }
        }
        // 2. Microsoft Exchange: "couldn't be delivered to <foo@bar.com>"
        if let r = body.range(of: #"<([A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+)>"#,
                              options: .regularExpression) {
            return String(body[r])
                .replacingOccurrences(of: "<", with: "")
                .replacingOccurrences(of: ">", with: "")
        }
        // 3. Generic: postmaster body'de geçen ilk email
        if let r = body.range(of: #"[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}"#,
                              options: .regularExpression) {
            return String(body[r])
        }
        return nil
    }

    /// Prospect.notes içine yazılmış "Email pattern: {template} (...)" satırından
    /// template'i çıkarır. Pattern cache fail kaydı için.
    private nonisolated static func extractTemplateFromNotes(_ notes: String) -> String? {
        guard let r = notes.range(of: #"Email pattern:\s*(\{[^}\s]+(\}\.\{[^}\s]+)*\}|\{[^}\s]+\})"#,
                                  options: .regularExpression) else { return nil }
        let chunk = String(notes[r])
        // "Email pattern: {first}.{last} (cache (verified))"
        if let templateR = chunk.range(of: #"\{[^)]+?\}(\.\{[^)]+?\})*"#,
                                       options: .regularExpression) {
            return String(chunk[templateR]).trimmingCharacters(in: .whitespaces)
        }
        // Daha basit fallback — "{first}.{last}" tek match
        return chunk.replacingOccurrences(of: "Email pattern:", with: "")
                    .components(separatedBy: " ").first?
                    .trimmingCharacters(in: .whitespaces)
    }

    private func sendEmailStep(prospect p: Prospect, step: SequenceStep) async {
        let subject = step.subject ?? "(no subject)"
        let body = step.body
        guard !body.isEmpty else {
            errorMessage = "Step body boş — gönderilmedi."
            return
        }
        do {
            let msgId = try await OutlookService.shared.sendEmail(
                subject: subject,
                body: body,
                to: [p.contact.email],
                fromAccountId: accountStore.defaultAccount?.id
            )
            prospectStore.updateStep(prospectId: p.id, stepId: step.id) { s in
                s.status = .sent
                s.sentAt = Date()
                s.outlookMessageId = msgId.isEmpty ? nil : msgId
            }
        } catch {
            prospectStore.updateStep(prospectId: p.id, stepId: step.id) { s in
                s.status = .failed
                s.failureReason = error.localizedDescription
            }
            errorMessage = "Email gönderim hatası: \(error.localizedDescription)"
        }
    }

    private func prepareLinkedInStep(prospect p: Prospect, step: SequenceStep) async {
        // ToS gereği auto-send yok. Tool metni clipboard'a koyar + Sales Nav URL'i açar.
        let pb = NSPasteboard.general
        pb.clearContents()
        var clipboard = step.body
        if let subj = step.subject, step.channel == .linkedinInMail, !subj.isEmpty {
            clipboard = "Subject: \(subj)\n\n" + step.body
        }
        pb.setString(clipboard, forType: .string)

        // LinkedIn URL'ini aç (Sales Nav profile ya da fallback olarak public URL).
        let urlStr: String? = p.contact.linkedinUrl ?? Self.fallbackLinkedInSearchURL(for: p)
        if let s = urlStr, let url = URL(string: s) {
            NSWorkspace.shared.open(url)
        }

        // Step'i "sent" olarak işaretle — Ersel manuel atmış kabul.
        // (kullanıcı atmadıysa bile UI bu durumu açıkça gösteriyor: pasif "sent" tag.)
        prospectStore.updateStep(prospectId: p.id, stepId: step.id) { s in
            s.status = .sent
            s.sentAt = Date()
        }
        lastInviteAttemptStatus = "\(step.channel.label) metni panoya kopyalandı + LinkedIn açıldı."
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if self.lastInviteAttemptStatus?.contains("metni panoya") == true {
                self.lastInviteAttemptStatus = nil
            }
        }
    }

    private static func fallbackLinkedInSearchURL(for p: Prospect) -> String? {
        let name = p.contact.fullName.replacingOccurrences(of: " ", with: "%20")
        if name.isEmpty { return nil }
        let comp = p.companyName.replacingOccurrences(of: " ", with: "%20")
        return "https://www.linkedin.com/search/results/people/?keywords=\(name)%20\(comp)"
    }

    /// Salesforce'a Lead + ilk Activity Task'ı INSERT eder.
    func pushToSalesforce(prospectId: UUID) async {
        guard let p = prospectStore.prospect(id: prospectId) else { return }
        prospectBusyId = prospectId
        prospectBusyLabel = "Salesforce'a yazılıyor"
        defer {
            prospectBusyId = nil
            prospectBusyLabel = nil
        }
        do {
            let (id, url) = try await SalesforceService.shared.createLead(p)
            prospectStore.setSalesforceLead(prospectId: prospectId, leadId: id, url: url)

            // Atılan ilk step'i Activity Task olarak SF'ye logla (varsa).
            if let firstSent = p.sequenceSteps.first(where: { $0.status == .sent }) {
                let desc = (firstSent.subject.map { "Subject: \($0)\n\n" } ?? "") + firstSent.body
                let taskId = try await SalesforceService.shared.logTask(
                    prospectLeadId: id,
                    subject: firstSent.subject ?? firstSent.channel.label,
                    description: desc,
                    channel: firstSent.channel
                )
                prospectStore.appendSalesforceTask(prospectId: prospectId, taskId: taskId)
            }
            lastInviteAttemptStatus = "Salesforce Lead oluşturuldu — \(id)"
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                if self.lastInviteAttemptStatus?.contains("Lead oluşturuldu") == true {
                    self.lastInviteAttemptStatus = nil
                }
            }
        } catch {
            errorMessage = "Salesforce push hatası: \(error.localizedDescription)"
        }
    }

    // MARK: - Manual edit

    /// Tek bir step'in subject/body'sini elle düzenle.
    func editStep(prospectId: UUID, stepId: UUID, subject: String?, body: String) {
        prospectStore.updateStep(prospectId: prospectId, stepId: stepId) { step in
            step.subject = subject
            step.body = body
            // Düzenlendiyse onayı sıfırla — tekrar approve edilmesi gerek.
            if step.status == .approved || step.status == .drafted {
                step.status = .drafted
            }
        }
    }

    /// Soft delete — kayıt durur, AI yeniden keşfetse de eklenmez. Default action.
    func softDeleteProspect(_ id: UUID, reason: String = "kullanıcı manuel sildi") {
        guard let p = prospectStore.prospect(id: id) else { return }
        prospectStore.softDelete(id, reason: reason)
        AppLogger.shared.info(.prospectPipeline, "prospect soft-deleted", metadata: [
            "domain":  .string(p.domain),
            "company": .string(p.companyName),
            "reason":  .string(reason)
        ])
        if selectedProspectId == id { selectedProspectId = nil }
    }

    func restoreProspect(_ id: UUID) {
        guard let p = prospectStore.prospect(id: id) else { return }
        prospectStore.restore(id)
        AppLogger.shared.info(.prospectPipeline, "prospect restored", metadata: [
            "domain":  .string(p.domain),
            "company": .string(p.companyName)
        ])
    }

    /// Kalıcı sil — geri dönüş yok. Onay sonrası kullanılmalı.
    func hardDeleteProspect(_ id: UUID) {
        guard let p = prospectStore.prospect(id: id) else { return }
        AppLogger.shared.warn(.prospectPipeline, "prospect HARD deleted", metadata: [
            "domain":  .string(p.domain),
            "company": .string(p.companyName)
        ])
        prospectStore.hardDelete(id)
        if selectedProspectId == id { selectedProspectId = nil }
    }

    /// Sequence'i duraklat (gönderim durur, manuel devam ettirilir).
    func pauseProspect(_ id: UUID) {
        guard let p = prospectStore.prospect(id: id) else { return }
        prospectStore.setStatus(id, .paused)
        AppLogger.shared.info(.prospectPipeline, "prospect paused", metadata: [
            "domain": .string(p.domain)
        ])
    }

    /// Pause'tan kalkar. Skoru/sequence'i varsa devam ettirir; yoksa matched'a düşer.
    func resumeProspect(_ id: UUID) {
        guard let p = prospectStore.prospect(id: id) else { return }
        let newStatus: ProspectStatus
        if !p.sequenceSteps.isEmpty {
            let anySent = p.sequenceSteps.contains { $0.status == .sent }
            newStatus = anySent ? .sending : .drafted
        } else if p.score != nil {
            newStatus = .scored
        } else if p.dedup != nil {
            newStatus = .matched
        } else {
            newStatus = .discovered
        }
        prospectStore.setStatus(id, newStatus)
        AppLogger.shared.info(.prospectPipeline, "prospect resumed", metadata: [
            "domain":    .string(p.domain),
            "newStatus": .string(newStatus.rawValue)
        ])
    }

    // Eski API uyumluluk — varsayılan soft delete'e yönlendir.
    func deleteProspect(_ id: UUID) {
        softDeleteProspect(id)
    }

    // MARK: - Reply detection (V1)

    /// Mevcut inbox state'i prospect kontak adresleriyle eşleştirip reply'leri
    /// otomatik tespit eder. `refreshInbox()` sonrasında background task olarak
    /// çağrılır.
    func linkInboxRepliesToProspects() async {
        guard !prospectStore.prospects.isEmpty, !emails.isEmpty else { return }
        for p in prospectStore.prospects {
            // Replied/completed olanları yeniden işaretleme.
            if p.status == .completed || p.status == .replied { continue }
            let contactLc = p.contact.email.lowercased()
            guard !contactLc.isEmpty else { continue }
            // emails listesi tarih-desc; ilk match en son.
            guard let mostRecent = emails.first(where: {
                $0.fromAddress.lowercased() == contactLc
            }) else { continue }

            let lastSentAt = p.sequenceSteps.compactMap { $0.sentAt }.max() ?? .distantPast
            let mailDate = DateUtil.parse(mostRecent.date) ?? Date()
            if mailDate <= lastSentAt { continue }

            // Hangi step'e reply geldi: en son sent edilen step.
            guard let lastSent = p.sequenceSteps.last(where: { $0.status == .sent }) else { continue }
            prospectStore.updateStep(prospectId: p.id, stepId: lastSent.id) { s in
                s.status = .repliedTo
                s.replyDetectedAt = Date()
                s.replySummary = String(mostRecent.preview.prefix(220))
            }
        }
    }

    /// Replied prospect için inbox'a geç + ilgili mail'i seç. Mevcut draft akışı
    /// (RightPanelView "Yanıt Taslağı" butonu) zaten Türkçe taslak üretiyor.
    func openProspectReplyInInbox(prospectId: UUID) async {
        guard let p = prospectStore.prospect(id: prospectId) else { return }
        let contactLc = p.contact.email.lowercased()
        guard !contactLc.isEmpty else {
            errorMessage = "Kontak email yok."
            return
        }
        // Önce mevcut inbox'ta arıyoruz; yoksa yenile + tekrar dene.
        if let mail = emails.first(where: { $0.fromAddress.lowercased() == contactLc }) {
            currentFeature = .inbox
            await selectEmail(mail.id)
            return
        }
        // Inbox stale olabilir — yenile.
        await refreshInbox()
        if let mail = emails.first(where: { $0.fromAddress.lowercased() == contactLc }) {
            currentFeature = .inbox
            await selectEmail(mail.id)
        } else {
            errorMessage = "Reply mail bulunamadı — inbox limiti içinde değil olabilir."
        }
    }
}
