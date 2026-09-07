import Foundation

public enum Redactor {
    public static func redact(_ text: String) -> String {
        var output = text
        if output.localizedCaseInsensitiveContains("private key") {
            output = replace(
                pattern: "-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----[\\s\\S]*?-----END [A-Z0-9 ]*PRIVATE KEY-----",
                in: output,
                with: "[REDACTED_PRIVATE_KEY]"
            )
        }
        if output.range(of: "[A-Fa-f0-9]{32,}", options: .regularExpression) != nil {
            output = replace(pattern: "\\b[A-Fa-f0-9]{32,}\\b", in: output, with: "[REDACTED_HEX]")
        }
        if output.contains("-") {
            output = replace(
                pattern: "\\b[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\\b",
                in: output,
                with: "[REDACTED_UUID]"
            )
        }
        if output.contains("@") {
            output = replace(pattern: "[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}", in: output, with: "[REDACTED_EMAIL]")
        }
        let lower = output.lowercased()
        if ["password", "token", "secret", "private_key", "private key", "psk", "auth_blob", "auth blob"]
            .contains(where: lower.contains) {
            output = replace(
                pattern: "(?i)(password|token|secret|private[_ -]?key|psk|auth[_ -]?blob)\\s*[:=]\\s*\\S+",
                in: output,
                with: "$1=[REDACTED]"
            )
        }
        output = replace(
            pattern: "(?i)(authorization|cookie|set-cookie|x-apple-gs-token|x-apple-i-md(?:-m)?|session[-_ ]?id)\\s*[:=]\\s*[^\\s,;]+",
            in: output,
            with: "$1=[REDACTED]"
        )
        output = replace(
            pattern: "(?i)(verification|2fa|two-factor)[-_ ]?(code)?\\s*[:=]\\s*[0-9]{4,8}",
            in: output,
            with: "$1-code=[REDACTED]"
        )
        return output
    }

    private static func replace(pattern: String, in text: String, with replacement: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return text
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: replacement)
    }
}
