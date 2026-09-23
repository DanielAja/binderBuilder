//
//  DecimalInput.swift
//  binderBuilder
//
//  Parses what people type into a decimal-pad field. `Double(String)` only
//  understands "12.50", but the decimal pad in a German, French or Brazilian
//  locale types "12,50" — which silently failed to parse (the price was
//  dropped, the alert couldn't be saved). Either separator is accepted
//  whatever the device locale, so a pasted "12.50" works everywhere too.
//

import Foundation

nonisolated enum DecimalInput {
    /// The number in `text`, or nil when it isn't one. Accepts "12.50",
    /// "12,50", "1,234.50", "1.234,50", a leading currency symbol and spaces.
    /// A separator that appears once is the decimal point; one that repeats
    /// ("1.234.567") is grouping. With both present, the last one wins.
    static func parse(_ text: String) -> Double? {
        var s = text.filter { !$0.isWhitespace && $0 != "\u{00A0}" && $0 != "\u{202F}" }
        s = String(s.drop(while: { "$€£¥".contains($0) }))
        guard !s.isEmpty else { return nil }

        let lastDot = s.lastIndex(of: "."), lastComma = s.lastIndex(of: ",")
        let decimal: Character?
        switch (lastDot, lastComma) {
        case let (dot?, comma?): decimal = dot > comma ? "." : ","
        case (_?, nil): decimal = s.filter { $0 == "." }.count == 1 ? "." : nil
        case (nil, _?): decimal = s.filter { $0 == "," }.count == 1 ? "," : nil
        case (nil, nil): decimal = nil
        }

        var normalized = ""
        for ch in s {
            if ch == "." || ch == "," {
                if ch == decimal { normalized.append(".") }   // else: grouping, dropped
            } else {
                normalized.append(ch)
            }
        }
        guard let value = Double(normalized), value.isFinite else { return nil }
        return value
    }

    /// A stored value as the user's locale writes it ("12,5" in de_DE), for
    /// pre-filling an edit field that `parse` will read back.
    static func string(_ value: Double, locale: Locale = .current) -> String {
        value.formatted(.number.grouping(.never).precision(.fractionLength(0...2)).locale(locale))
    }
}
