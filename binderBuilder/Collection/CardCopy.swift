//
//  CardCopy.swift
//  binderBuilder
//
//  A single physical copy the user owns: a printing (CardRef) plus its
//  condition, optional professional grade, optional acquisition price/date,
//  and notes. The collection is a set of copies; quantity = number of copies,
//  ownership = at least one copy. Raw (ungraded) copies value at market;
//  graded copies value at the user-entered acquisition/manual value.
//

import Foundation

/// Raw-card condition (TCG standard ladder).
nonisolated enum CardCondition: String, Codable, CaseIterable, Sendable, Hashable {
    case nm = "NM"   // Near Mint
    case lp = "LP"   // Lightly Played
    case mp = "MP"   // Moderately Played
    case hp = "HP"   // Heavily Played
    case dmg = "DMG" // Damaged

    var displayName: String {
        switch self {
        case .nm: return "Near Mint"
        case .lp: return "Lightly Played"
        case .mp: return "Moderately Played"
        case .hp: return "Heavily Played"
        case .dmg: return "Damaged"
        }
    }
}

/// Professional grading company.
nonisolated enum GradeCompany: String, Codable, CaseIterable, Sendable, Hashable {
    case psa = "PSA"
    case cgc = "CGC"
    case bgs = "BGS"
    case sgc = "SGC"
    case ace = "ACE"
    case other = "Other"
}

/// A professional grade on a slabbed copy (e.g. PSA 10).
nonisolated struct CardGrade: Codable, Hashable, Sendable {
    var company: GradeCompany
    var value: Double

    /// "PSA 10", "BGS 9.5".
    var label: String {
        let v = value == value.rounded() ? String(Int(value)) : String(value)
        return "\(company.rawValue) \(v)"
    }
}

/// One owned physical copy.
nonisolated struct CardCopy: Identifiable, Hashable, Sendable {
    var id: String
    var ref: CardRef
    var condition: CardCondition
    var grade: CardGrade?
    /// What the user paid (optional), used for cost-basis and graded value.
    var acquiredPrice: Double?
    var acquiredAt: Date
    var notes: String?

    var isGraded: Bool { grade != nil }

    init(
        id: String = UUID().uuidString,
        ref: CardRef,
        condition: CardCondition = .nm,
        grade: CardGrade? = nil,
        acquiredPrice: Double? = nil,
        acquiredAt: Date = Date(),
        notes: String? = nil
    ) {
        self.id = id
        self.ref = ref
        self.condition = condition
        self.grade = grade
        self.acquiredPrice = acquiredPrice
        self.acquiredAt = acquiredAt
        self.notes = notes
    }
}
