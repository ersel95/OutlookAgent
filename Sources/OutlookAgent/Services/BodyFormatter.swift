import Foundation
import SwiftUI

/// Turns Outlook plain-text bodies into a styled AttributedString:
///   - <https://x>, <mailto:y>     → unwrap brackets
///   - cleans excessive whitespace and trailing spaces
///   - **bold**, __bold__          → bold
///   - *italic*, _italic_          → italic (only when delimited by spaces/punct)
///   - URLs and emails             → tappable links (accent color, underline)
enum BodyFormatter {

    /// Returns nil when the body is effectively empty after cleaning
    /// (e.g. only invisible Unicode chars, calendar invitations).
    static func format(_ raw: String) -> AttributedString? {
        let cleaned = clean(raw)
        guard !cleaned.isEmpty else { return nil }
        var attr = applyMarkdown(cleaned)
        attachLinks(&attr)
        return attr
    }

    // MARK: - Cleanup

    private static let bracketURL = try! NSRegularExpression(
        pattern: #"<((?:https?|mailto)://[^>\s]+|mailto:[^>\s]+)>"#,
        options: [.caseInsensitive])
    private static let multiBlank = try! NSRegularExpression(
        pattern: #"\n{3,}"#, options: [])
    private static let trailingSpaces = try! NSRegularExpression(
        pattern: #"[ \t]+(?=\n)"#, options: [])

    private static func clean(_ raw: String) -> String {
        var s = raw.replacingOccurrences(of: "\r\n", with: "\n")
        s = s.replacingOccurrences(of: "\u{00A0}", with: " ")        // NBSP
        s = s.replacingOccurrences(of: "\u{200B}", with: "")         // ZWSP
        s = s.replacingOccurrences(of: "\u{FEFF}", with: "")         // BOM

        // Unwrap "<https://...>" and "<mailto:...>" to bare URL/email
        s = bracketURL.stringByReplacingMatches(
            in: s,
            range: NSRange(s.startIndex..., in: s),
            withTemplate: "$1"
        )
        // Strip HTML/CSS residue from poorly-rendered HTML emails (Outlook's
        // plain-text rendering occasionally leaves angle-bracketed style
        // attributes or template placeholders behind).
        s = stripHTMLResidue(s)
        // Strip "mailto:" prefix from bare-text emails (we still detect them as links)
        s = s.replacingOccurrences(of: "mailto:", with: "", options: .caseInsensitive)

        // Trim trailing whitespace at line ends
        s = trailingSpaces.stringByReplacingMatches(
            in: s,
            range: NSRange(s.startIndex..., in: s),
            withTemplate: ""
        )
        // Collapse 3+ consecutive blank lines to a single blank
        s = multiBlank.stringByReplacingMatches(
            in: s,
            range: NSRange(s.startIndex..., in: s),
            withTemplate: "\n\n"
        )
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - HTML residue

    /// Outlook'un `plain text content` çıktısı, kötü yapılı HTML mail'lerde bazen
    /// `<font-size:14px; font-family:...; display:block>` veya `<blank>` gibi
    /// markup parçalarını strip etmeden bırakır. Buradaki regex'ler:
    ///   1) `<blank>`, `<empty>`, `<preheader>` placeholder token'larını siler
    ///   2) İçinde CSS keyword'leri (font-, color:, style=, display:, ...) geçen
    ///      `<...>` bloklarını siler — gerçek inline link `<https://...>` veya
    ///      `<email@x>` zaten daha önce `bracketURL` ile unwrap edilmiştir.
    static func stripHTMLResidue(_ raw: String) -> String {
        var s = raw

        // Placeholder tokens that surface from preheader / template stubs.
        let placeholderRegex = try! NSRegularExpression(
            pattern: #"<\s*(?:blank|empty|preheader|preview|spacer)\s*>"#,
            options: [.caseInsensitive])
        s = placeholderRegex.stringByReplacingMatches(
            in: s, range: NSRange(s.startIndex..., in: s), withTemplate: " ")

        // Angle-bracketed blob that looks like leaked inline-style or CSS — i.e.
        // a `<...>` chunk (no nested angle, max ~600 chars) whose interior
        // contains at least one CSS/style keyword. Conservative: requires the
        // CSS hint so we don't eat legitimate user content like `<3` or
        // `<not-a-tag>`. Multiline-aware (some bodies wrap mid-attribute).
        let cssBlobRegex = try! NSRegularExpression(
            pattern: #"<[^<>]{0,600}?(?:font-(?:size|family|weight|style)|color\s*:|background(?:-color)?\s*:|style\s*=|width\s*:|height\s*:|margin(?:-[a-z]+)?\s*:|padding(?:-[a-z]+)?\s*:|border(?:-[a-z]+)?\s*:|display\s*:|text-decoration|line-height|letter-spacing|vertical-align)[^<>]{0,600}?>"#,
            options: [.caseInsensitive, .dotMatchesLineSeparators])
        s = cssBlobRegex.stringByReplacingMatches(
            in: s, range: NSRange(s.startIndex..., in: s), withTemplate: " ")

        // After stripping, multiple spaces around the cut point can pile up.
        let multiSpace = try! NSRegularExpression(
            pattern: #"[ \t]{2,}"#, options: [])
        s = multiSpace.stringByReplacingMatches(
            in: s, range: NSRange(s.startIndex..., in: s), withTemplate: " ")

        return s
    }

    // MARK: - Markdown (bold + italic)

    private static let boldRegex = try! NSRegularExpression(
        pattern: #"(\*\*|__)(?=\S)(.+?)(?<=\S)\1"#, options: [])
    private static let italicRegex = try! NSRegularExpression(
        // Single * or _ around non-space content. Avoid matching ** which is bold.
        pattern: #"(?<![\*_\w])([*_])(?=\S)([^*_\n]+?)(?<=\S)\1(?![\*_\w])"#,
        options: [])

    private static func applyMarkdown(_ text: String) -> AttributedString {
        // Build by walking the text and emitting runs.
        var attr = AttributedString(text)

        // Apply bold
        applyRegex(boldRegex, on: text, into: &attr) { run in
            run.font = .body.bold()
        } captureRange: { match, source in
            // capture group 2 is the inner text
            return Range(match.range(at: 2), in: source)
        }

        // Apply italic (skip ranges already inside bold via simple second pass)
        applyRegex(italicRegex, on: text, into: &attr) { run in
            run.font = .body.italic()
        } captureRange: { match, source in
            return Range(match.range(at: 2), in: source)
        }

        // Strip the markdown delimiters themselves (* and _) by hiding them.
        // Easiest: on the original AttributedString, find those characters and remove.
        attr = stripMarkdownDelimiters(attr)
        return attr
    }

    private static func applyRegex(
        _ regex: NSRegularExpression,
        on source: String,
        into attr: inout AttributedString,
        styler: (inout AttributeContainer) -> Void,
        captureRange: (NSTextCheckingResult, String) -> Range<String.Index>?
    ) {
        let nsRange = NSRange(source.startIndex..., in: source)
        let matches = regex.matches(in: source, range: nsRange)
        for m in matches {
            guard let strRange = captureRange(m, source) else { continue }
            // Map String.Index range → AttributedString.Index range
            guard let attrRange = Range(strRange, in: attr) else { continue }
            var c = AttributeContainer()
            styler(&c)
            attr[attrRange].mergeAttributes(c)
        }
    }

    /// Removes leftover *, _, ** delimiters (the markers themselves) from the
    /// AttributedString while preserving styles already applied to the wrapped text.
    private static func stripMarkdownDelimiters(_ input: AttributedString) -> AttributedString {
        // Convert to NSAttributedString, scan and rebuild.
        let ns = NSAttributedString(input)
        let str = ns.string
        let mutable = NSMutableAttributedString()

        let chars = Array(str)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            // Recognize bold markers: ** or __ around content
            if (c == "*" || c == "_") && i + 1 < chars.count && chars[i+1] == c {
                // Bold delimiter — skip both
                i += 2
                continue
            }
            // Single * or _ as italic marker — skip
            if c == "*" || c == "_" {
                // But only if surrounded by non-word on the outer side; we keep it simple and skip.
                i += 1
                continue
            }
            // Append the character with its existing attributes
            let nsRange = NSRange(location: i, length: 1)
            mutable.append(ns.attributedSubstring(from: nsRange))
            i += 1
        }
        return AttributedString(mutable)
    }

    // MARK: - Links + emails

    private static func attachLinks(_ attr: inout AttributedString) {
        let plain = String(attr.characters)
        let nsRange = NSRange(plain.startIndex..., in: plain)
        let detector = try? NSDataDetector(
            types: NSTextCheckingResult.CheckingType.link.rawValue
        )
        let matches = detector?.matches(in: plain, range: nsRange) ?? []
        for m in matches {
            guard let strRange = Range(m.range, in: plain),
                  let attrRange = Range(strRange, in: attr) else { continue }
            let url: URL? = m.url ?? {
                let s = String(plain[strRange])
                if s.contains("@"), !s.contains("://") {
                    return URL(string: "mailto:\(s)")
                }
                return URL(string: s)
            }()
            if let url = url {
                attr[attrRange].link = url
                // Color comes from the surrounding `.tint(...)` so it adapts
                // to the bubble (white on outgoing, accent on incoming).
                attr[attrRange].underlineStyle = .single
            }
        }

        // Also catch bare email addresses NSDataDetector sometimes misses.
        let emailRegex = try! NSRegularExpression(
            pattern: #"(?<![\w.+-])([A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,})(?![\w])"#,
            options: [.caseInsensitive])
        let eMatches = emailRegex.matches(in: plain, range: nsRange)
        for m in eMatches {
            guard let strRange = Range(m.range, in: plain),
                  let attrRange = Range(strRange, in: attr) else { continue }
            // Skip if already linked
            if attr[attrRange].link != nil { continue }
            if let url = URL(string: "mailto:\(plain[strRange])") {
                attr[attrRange].link = url
                attr[attrRange].underlineStyle = .single
            }
        }
    }
}
