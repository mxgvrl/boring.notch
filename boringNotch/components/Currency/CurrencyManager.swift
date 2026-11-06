//
//  CurrencyManager.swift
//  boringNotch
//
//  Currency tab state: EUR / USD / PLN amounts, ECB rates via Frankfurter (cached in Defaults).
//

import AppKit
import Defaults
import Foundation

enum CurrencyCode: String, CaseIterable, Identifiable {
    case eur = "EUR"
    case usd = "USD"
    case pln = "PLN"

    var id: String { rawValue }
    var code: String { rawValue }
    var symbol: String {
        switch self {
        case .eur: return "€"
        case .usd: return "$"
        case .pln: return "zł"
        }
    }
    var label: String { "\(symbol) \(code)" }
}

struct CurrencyRates: Codable, Equatable {
    var usd: Double
    var pln: Double
    var rateDate: String  // yyyy-MM-dd
    var fetchedAt: Date
}

private struct FrankfurterResponse: Decodable {
    let date: String
    let rates: [String: Double]
}

@MainActor
final class CurrencyManager: ObservableObject {
    static let shared = CurrencyManager()

    @Published private(set) var texts: [CurrencyCode: String] = [:]
    @Published private(set) var source: CurrencyCode = .eur
    @Published private(set) var isValid = true
    @Published private(set) var isFetching = false
    @Published private(set) var rates: CurrencyRates?
    @Published var focusedField: CurrencyCode?
    /// One-shot request (target NSWindow.windowNumber) to focus the source field (tab hotkey dwell).
    @Published var pendingFocusWindow: Int?

    var keepsNotchOpen: Bool { focusedField != nil }

    private static let url = URL(string: "https://api.frankfurter.dev/v1/latest?base=EUR&symbols=USD,PLN")!
    private static let staleAfter: TimeInterval = 3600
    private static let rateDateStaleAfter: TimeInterval = 3 * 24 * 3600

    private init() {
        if let usd = Defaults[.currencyRateUSD], let pln = Defaults[.currencyRatePLN],
           let date = Defaults[.currencyRateDate], let fetched = Defaults[.currencyFetchedAt] {
            rates = CurrencyRates(usd: usd, pln: pln, rateDate: date, fetchedAt: fetched)
        }
        source = CurrencyCode(rawValue: Defaults[.currencyLastSource]) ?? .eur
        texts[source] = Defaults[.currencyLastAmount]
        recompute()
    }

    // MARK: Input

    func setText(_ text: String, for code: CurrencyCode) {
        guard texts[code] != text || source != code else { return }
        source = code
        texts[code] = text
        Defaults[.currencyLastAmount] = text
        Defaults[.currencyLastSource] = code.rawValue
        recompute()
    }

    private func recompute() {
        let text = texts[source] ?? ""
        let others = CurrencyCode.allCases.filter { $0 != source }
        let value = Self.parse(text)
        isValid = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || value != nil
        for other in others {
            if let value, let r = rate(from: source, to: other) {
                texts[other] = Self.format(value * r)
            } else {
                texts[other] = ""
            }
        }
    }

    /// `,` and `.` are both decimal separators; whitespace (incl. NBSP) is ignored; negatives are invalid.
    nonisolated static func parse(_ text: String) -> Double? {
        let stripped = text.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) && $0 != "\u{00A0}" }
        var s = String(String.UnicodeScalarView(stripped))
        guard !s.isEmpty else { return nil }
        s = s.replacingOccurrences(of: ",", with: ".")
        guard s.filter({ $0 == "." }).count <= 1,
              s.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == ".") }),
              s.contains(where: { $0.isNumber }),
              let v = Double(s), v.isFinite, v >= 0 else { return nil }
        return v
    }

    nonisolated static func format(_ value: Double) -> String {
        let f = NumberFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.numberStyle = .decimal
        f.groupingSeparator = " "
        f.decimalSeparator = "."
        f.usesGroupingSeparator = true
        f.groupingSize = 3
        let digits = (value > 0 && value < 0.01) ? 4 : 2
        f.minimumFractionDigits = digits
        f.maximumFractionDigits = digits
        return f.string(from: NSNumber(value: value)) ?? String(value)
    }

    // MARK: Rates

    /// Units of `to` per one unit of `from`, via EUR.
    func rate(from: CurrencyCode, to: CurrencyCode) -> Double? {
        guard let rates else { return nil }
        func perEUR(_ c: CurrencyCode) -> Double {
            switch c {
            case .eur: return 1
            case .usd: return rates.usd
            case .pln: return rates.pln
            }
        }
        guard perEUR(from) > 0 else { return nil }
        return perEUR(to) / perEUR(from)
    }

    private static let dateParser: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static let dateShown: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "MMM d"
        return f
    }()

    var rateDateText: String? {
        guard let rates, let d = Self.dateParser.date(from: rates.rateDate) else { return nil }
        return Self.dateShown.string(from: d)
    }

    var isRateDateStale: Bool {
        guard let rates, let d = Self.dateParser.date(from: rates.rateDate) else { return false }
        return Date().timeIntervalSince(d) > Self.rateDateStaleAfter
    }

    func refreshIfStale() {
        if let fetched = rates?.fetchedAt, Date().timeIntervalSince(fetched) <= Self.staleAfter { return }
        refresh()
    }

    func refresh() {
        guard !isFetching else { return }
        isFetching = true
        Task { [weak self] in
            defer { self?.isFetching = false }
            var request = URLRequest(url: Self.url)
            request.timeoutInterval = 10
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let decoded = try? JSONDecoder().decode(FrankfurterResponse.self, from: data),
                  let usd = decoded.rates["USD"], let pln = decoded.rates["PLN"], usd > 0, pln > 0,
                  let self else { return }
            let now = Date()
            Defaults[.currencyRateUSD] = usd
            Defaults[.currencyRatePLN] = pln
            Defaults[.currencyRateDate] = decoded.date
            Defaults[.currencyFetchedAt] = now
            self.rates = CurrencyRates(usd: usd, pln: pln, rateDate: decoded.date, fetchedAt: now)
            self.recompute()
        }
    }

    // MARK: Copy

    @discardableResult
    func copyValue(for code: CurrencyCode) -> Bool {
        let value = (texts[code] ?? "").filter { !$0.isWhitespace && $0 != "\u{00A0}" }
        guard !value.isEmpty else { return false }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(value, forType: .string)
        ClipboardWatcher.shared.markOwnWrite()
        return true
    }
}
