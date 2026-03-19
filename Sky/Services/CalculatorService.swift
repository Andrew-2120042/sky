import Foundation

/// Evaluates simple math expressions client-side without an API call.
/// Returns nil if the input doesn't look like a math expression.
final class CalculatorService: @unchecked Sendable {

    static let shared = CalculatorService()
    private init() {}

    /// Attempts to evaluate `input` as a math expression.
    /// Returns a formatted string like "2 + 3 = 5", or nil if the input is not math.
    func evaluate(_ input: String) -> String? {
        let cleaned = input
            .replacingOccurrences(of: "×", with: "*")
            .replacingOccurrences(of: "÷", with: "/")
            .trimmingCharacters(in: .whitespaces)

        // Only evaluate if it looks like a pure math expression (digits, operators, parens, decimals)
        let mathPattern = #"^[\d\s\+\-\*\/\.\(\)]+$"#
        guard cleaned.range(of: mathPattern, options: .regularExpression) != nil else { return nil }

        // Require at least one operator — don't evaluate bare numbers
        guard cleaned.contains("+") || cleaned.contains("-") ||
              cleaned.contains("*") || cleaned.contains("/") else { return nil }

        let expr = NSExpression(format: cleaned)
        guard let result = expr.expressionValue(with: nil, context: nil) as? NSNumber else { return nil }

        let d = result.doubleValue
        guard !d.isNaN && !d.isInfinite else { return nil }

        if d == d.rounded() && abs(d) < 1_000_000_000 {
            return "\(input) = \(Int(d))"
        }
        return "\(input) = \(String(format: "%.4g", d))"
    }
}
