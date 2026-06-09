//
//  SetInfo.swift
//  binderBuilder
//
//  One TCG set, backed by the `set_info` table in catalog.sqlite.
//

import Foundation

nonisolated struct SetInfo: Identifiable, Hashable, Sendable {
    /// TCGdex set id, e.g. "base1".
    let id: String
    let name: String
    let seriesID: String?
    let seriesName: String?
    /// Count of cards in the official numbering (e.g. 102 for Base Set).
    let cardCountOfficial: Int?
    /// Total printed cards including secrets/trainer gallery.
    let cardCountTotal: Int?
    /// ISO date string "YYYY-MM-DD" (kept as TEXT, sorts lexicographically).
    let releaseDate: String?
    let symbolURL: String?
    let logoURL: String?
}
