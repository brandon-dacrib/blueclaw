import Foundation

/// Matches sensitive content found in user messages.
struct SensitiveMatch: Identifiable {
    let id = UUID()
    let category: String
    let matched: String
}

/// On-device content scanner that detects API keys and PII in outgoing messages
/// before they reach the gateway. All scanning runs locally — no data leaves the device.
enum ContentScanner {

    private static let enabledKey = "blueclaw.contentScannerEnabled"

    static var isEnabled: Bool {
        get {
            // Default to enabled if never set
            if UserDefaults.standard.object(forKey: enabledKey) == nil { return true }
            return UserDefaults.standard.bool(forKey: enabledKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: enabledKey)
        }
    }

    // MARK: - Patterns

    private struct Pattern {
        let category: String
        let regex: NSRegularExpression
        let redact: (String) -> String
    }

    private static let patterns: [Pattern] = {
        func re(_ pattern: String, options: NSRegularExpression.Options = []) -> NSRegularExpression {
            try! NSRegularExpression(pattern: pattern, options: options)
        }

        let keyRedact: (String) -> String = { match in
            if match.count > 8 {
                let prefix = String(match.prefix(4))
                let suffix = String(match.suffix(4))
                return "\(prefix)...\(suffix)"
            }
            return "****"
        }

        return [
            Pattern(category: "AWS Key",
                    regex: re(#"AKIA[0-9A-Z]{16}"#),
                    redact: keyRedact),
            Pattern(category: "OpenAI Key",
                    regex: re(#"sk-[a-zA-Z0-9_\-]{20,}"#),
                    redact: keyRedact),
            Pattern(category: "GitHub PAT",
                    regex: re(#"gh[pousr]_[a-zA-Z0-9]{36,}"#),
                    redact: keyRedact),
            Pattern(category: "Stripe Key",
                    regex: re(#"[sr]k_live_[a-zA-Z0-9]{24,}"#),
                    redact: keyRedact),
            Pattern(category: "Generic Secret",
                    regex: re(#"(api[_\-]?key|secret[_\-]?key|access[_\-]?token)\s*[:=]\s*["']?[^\s"']{16,}"#, options: .caseInsensitive),
                    redact: keyRedact),
            Pattern(category: "SSN",
                    regex: re(#"\b\d{3}-\d{2}-\d{4}\b"#),
                    redact: { _ in "***-**-****" }),
            Pattern(category: "Credit Card",
                    regex: re(#"\b\d{4}[\s-]?\d{4}[\s-]?\d{4}[\s-]?\d{4}\b"#),
                    redact: { _ in "****...****" }),
            Pattern(category: "Email Address",
                    regex: re(#"\b[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}\b"#),
                    redact: keyRedact),
        ]
    }()

    // MARK: - Scan

    /// Scans text for sensitive content. Returns empty array if nothing found or scanning is disabled.
    static func scan(_ text: String) -> [SensitiveMatch] {
        guard isEnabled else { return [] }

        var matches: [SensitiveMatch] = []
        let range = NSRange(text.startIndex..., in: text)

        for pattern in patterns {
            let results = pattern.regex.matches(in: text, range: range)
            for result in results {
                if let matchRange = Range(result.range, in: text) {
                    let matched = String(text[matchRange])
                    matches.append(SensitiveMatch(
                        category: pattern.category,
                        matched: pattern.redact(matched)
                    ))
                }
            }
        }

        return matches
    }
}
