//
//  DailyRateLimiter.swift
//  binderBuilder
//
//  Self-imposed daily budget for eBay Browse calls (the free tier allows
//  5,000/day; we stop at 4,500 to leave headroom). The count resets at UTC
//  midnight and is persisted in UserDefaults so it survives relaunches.
//

import Foundation

actor DailyRateLimiter {
    static let defaultDailyLimit = 4500

    private let limit: Int
    private let defaults: UserDefaults
    private let countKey: String
    private let dayKey: String
    private let now: @Sendable () -> Date

    init(
        limit: Int = DailyRateLimiter.defaultDailyLimit,
        defaults: UserDefaults = .standard,
        keyPrefix: String = "ebayDailyLimit",
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.limit = limit
        self.defaults = defaults
        self.countKey = "\(keyPrefix).count"
        self.dayKey = "\(keyPrefix).day"
        self.now = now
    }

    /// Consumes one request slot. Returns false (without consuming) when
    /// today's budget is already exhausted.
    func consume() -> Bool {
        let today = Self.utcDayString(for: now())
        let count = defaults.string(forKey: dayKey) == today
            ? defaults.integer(forKey: countKey)
            : 0  // a new UTC day resets the budget
        guard count < limit else { return false }
        defaults.set(today, forKey: dayKey)
        defaults.set(count + 1, forKey: countKey)
        return true
    }

    /// Slots left today (for the Settings screen).
    func remainingToday() -> Int {
        let today = Self.utcDayString(for: now())
        let count = defaults.string(forKey: dayKey) == today
            ? defaults.integer(forKey: countKey)
            : 0
        return max(0, limit - count)
    }

    static func utcDayString(for date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}
