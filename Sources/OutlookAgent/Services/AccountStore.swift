import Foundation
import SwiftUI
import Observation
import AppKit

/// Çoklu hesap yönetimi store'u. Outlook'tan keşfedilen hesaplar ile kullanıcı
/// tercihlerinin (display name, color, enabled flag, default) merge'lenmiş
/// hâlini tutar. Diskteki dosya: ~/Library/Application Support/OutlookAgent/accounts.json.
///
/// `refreshFromOutlook(_:)` çağrısı OutlookService.listAccounts() ile
/// discovery yapılır; mevcut entry'ler `lastSeenAt` ile güncellenir, yeni hesaplar
/// default isEnabled=true ile eklenir, eski olanlar silinmez (kullanıcı manuel
/// silmedikçe).
@MainActor
@Observable
final class AccountStore {
    private(set) var accounts: [MailAccount] = []

    private let fileURL: URL = {
        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let dir = appSupport.appendingPathComponent("OutlookAgent", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("accounts.json")
    }()

    init() {
        loadFromDisk()
    }

    // MARK: - Queries

    var enabledAccounts: [MailAccount] {
        accounts.filter { $0.isEnabled }
    }

    var defaultAccount: MailAccount? {
        if let d = accounts.first(where: { $0.isDefault && $0.isEnabled }) {
            return d
        }
        return enabledAccounts.first
    }

    func account(id: String) -> MailAccount? {
        accounts.first { $0.id == id }
    }

    func account(matchingEmail email: String) -> MailAccount? {
        let target = email.lowercased()
        return accounts.first { $0.emailAddress.lowercased() == target }
    }

    // MARK: - CRUD

    func update(_ account: MailAccount) {
        guard let idx = accounts.firstIndex(where: { $0.id == account.id }) else { return }
        accounts[idx] = account
        normalizeDefault()
        persist()
    }

    func setEnabled(_ id: String, _ enabled: Bool) {
        guard let idx = accounts.firstIndex(where: { $0.id == id }) else { return }
        accounts[idx].isEnabled = enabled
        // If we disabled the default, promote another enabled account.
        if !enabled && accounts[idx].isDefault {
            accounts[idx].isDefault = false
            if let nextIdx = accounts.firstIndex(where: { $0.isEnabled }) {
                accounts[nextIdx].isDefault = true
            }
        }
        persist()
    }

    func setDefault(_ id: String) {
        for i in accounts.indices {
            accounts[i].isDefault = (accounts[i].id == id)
        }
        // Default account zorunlu olarak enabled olmalı.
        if let idx = accounts.firstIndex(where: { $0.id == id }) {
            accounts[idx].isEnabled = true
        }
        persist()
    }

    func setDisplayName(_ id: String, _ name: String) {
        guard let idx = accounts.firstIndex(where: { $0.id == id }) else { return }
        accounts[idx].displayName = name
        persist()
    }

    func setColor(_ id: String, hex: String?) {
        guard let idx = accounts.firstIndex(where: { $0.id == id }) else { return }
        accounts[idx].colorHex = hex
        persist()
    }

    /// Stale olmuş bir hesabı listeden tamamen kaldır (Outlook'tan silinmişse).
    func remove(_ id: String) {
        accounts.removeAll { $0.id == id }
        normalizeDefault()
        persist()
    }

    // MARK: - Discovery merge

    /// Outlook'tan gelen taze listeyi mevcut store'a uygula. Yeni hesaplar default
    /// preferences ile eklenir; mevcutlar email/type/outlookName fields güncellenir
    /// ve lastSeenAt=now olur. Kullanıcı override'ları (displayName, colorHex,
    /// isEnabled, isDefault) korunur.
    func mergeDiscovered(_ discovered: [MailAccount]) {
        let now = Date()
        var seen = Set<String>()
        for var fresh in discovered {
            seen.insert(fresh.id)
            fresh.lastSeenAt = now
            if let idx = accounts.firstIndex(where: { $0.id == fresh.id }) {
                // Preserve user prefs
                let existing = accounts[idx]
                fresh.displayName = existing.displayName.isEmpty ? fresh.displayName : existing.displayName
                fresh.colorHex = existing.colorHex
                fresh.isEnabled = existing.isEnabled
                fresh.isDefault = existing.isDefault
                accounts[idx] = fresh
            } else {
                // New account — default to enabled
                if fresh.displayName.isEmpty {
                    fresh.displayName = fresh.outlookAccountName.isEmpty ? fresh.emailAddress : fresh.outlookAccountName
                }
                fresh.isEnabled = true
                accounts.append(fresh)
            }
        }
        // Eski (görünmeyen) hesaplar listede kalır; sadece lastSeenAt güncellenmez.
        normalizeDefault()
        persist()
    }

    /// Default seçilmemişse ilk enabled hesabı default yap.
    private func normalizeDefault() {
        let defaults = accounts.filter { $0.isDefault && $0.isEnabled }
        if defaults.count > 1 {
            // Birden fazla default varsa ilki kalsın
            var foundFirst = false
            for i in accounts.indices where accounts[i].isDefault && accounts[i].isEnabled {
                if foundFirst { accounts[i].isDefault = false } else { foundFirst = true }
            }
        } else if defaults.isEmpty, let firstEnabled = accounts.firstIndex(where: { $0.isEnabled }) {
            accounts[firstEnabled].isDefault = true
        }
    }

    // MARK: - Persistence

    private func loadFromDisk() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        if let list = try? dec.decode([MailAccount].self, from: data) {
            self.accounts = list
        }
    }

    private func persist() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        if let data = try? enc.encode(accounts) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    // MARK: - Helpers

    /// Outlook uygulamasını ön plana getir — kullanıcı Tools → Accounts menüsünden
    /// hesap ekleyebilsin diye. AppleScript hesap eklemeyi doğrudan desteklemediği
    /// için bu en pragmatik yol.
    static func openOutlookForAccountManagement() {
        let script = """
        tell application "Microsoft Outlook"
            activate
        end tell
        """
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-e", script]
        try? task.run()
        // UI scripting Tools menüsüne tıklayamayabilir (Accessibility permission gerekir);
        // sadece Outlook'u öne getir, kullanıcı kalan adımı yapar.
    }
}
