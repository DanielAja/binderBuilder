//
//  FoilTier.swift
//  binderBuilder
//
//  Rarity -> foil-effect normalization. TCGdex's `rarity` string is free text
//  and era-dependent (classic "Rare" is only a holo if `variants.holo` is set;
//  SwSh says "Secret Rare" where SV says "Hyper rare"; JP-sourced sets surface
//  literal diamond/star translations). A naive switch-on-string silently
//  misses those, so every raw string goes through the lookup table below into
//  a small internal tier the shader can branch on, with unknown/future strings
//  falling back to the physical variant and then to `.none`.
//
//  The tier's raw value IS the shader's tier code — CardSurface.metal branches
//  on `int(floor(custom.value.x))`, so these cases are ordered/renumbered only
//  together with the `BB_TIER_*` constants in that file.
//
//  Uniform packing (CustomMaterial exposes exactly one float4 + one texture):
//
//      custom.value.x = Float(tier.rawValue) + holoStrength   (strength < 1)
//      custom.value.y = Float(artBoxEra) * 2  + grayscaleAmount
//      custom.value.zw = light phase, owned by MotionUpdateSystem
//
//  Both x and y are integer-part/fraction pairs, which is what let the tier and
//  the frame-era selector in without stealing the two phase slots the motion
//  system writes every frame.
//

import Foundation

/// What kind of foil treatment a printing gets. One case per shader branch.
nonisolated enum FoilTier: Int, CaseIterable, Sendable, Hashable {
    /// Flat print — a whisper of sheen only.
    case none = 0
    /// Classic holo: cosmos/starburst dot-field inside the art window.
    case holoArt = 1
    /// Reverse holo: fine sparkle everywhere EXCEPT the art window.
    case reverseInverse = 2
    /// Full-art ultra rare: etched relief highlight + soft fresnel.
    case fullArtEtched = 3
    /// Illustration rare: restrained foil, essentially a sheen border.
    case illustrationRare = 4
    /// Special illustration rare: dense full-face glitter + fresnel.
    case specialIllustrationRare = 5
    /// Rainbow/secret rare: broad angular rainbow bands over the full face.
    case secretRainbow = 6
    /// Hyper rare / gold: bands collapsed to gold + strong fresnel.
    case goldHyper = 7
    /// Mega Hyper Rare: monochrome gold, densest sparkle. The top tier.
    case megaHyperGold = 8

    /// Foil amplitude for this tier, fed to the shader as `holoStrength`.
    /// Kept strictly below 1 so the packed uniform's integer part stays the
    /// tier code (see the packing note above); the shader caps the *result*
    /// at `bb_holo_cap` regardless, so this only shapes relative loudness.
    var intensity: Float {
        switch self {
        case .none: return 0.10
        case .holoArt: return 0.85
        case .reverseInverse: return 0.55
        case .fullArtEtched: return 0.80
        case .illustrationRare: return 0.55
        case .specialIllustrationRare: return 0.90
        case .secretRainbow: return 0.95
        case .goldHyper: return 0.99
        case .megaHyperGold: return 0.99
        }
    }

    /// True when the effect is confined to (or excluded from) the art window,
    /// i.e. when the art-box mask era actually matters.
    var usesArtBoxMask: Bool {
        self == .holoArt || self == .reverseInverse
    }

    // MARK: Normalization

    /// Rarity strings that name a foil treatment outright. Keys are lowercased
    /// and whitespace-trimmed. Strings NOT in here (Common, Uncommon, the JP
    /// diamond marks, "Rare", "None", "Promo", and anything a future set adds)
    /// deliberately fall through to the variant in `resolve`.
    private static let table: [String: FoilTier] = [
        // Classic / mid-era holo rares + the JP star marks.
        "rare holo": .holoArt,
        "holo rare": .holoArt,
        "one star": .holoArt,
        "two star": .holoArt,
        "three star": .holoArt,
        "radiant rare": .holoArt,

        // Full-art ultra rares (etched relief).
        "ultra rare": .fullArtEtched,
        "double rare": .fullArtEtched,
        "amazing rare": .fullArtEtched,
        "holo rare v": .fullArtEtched,
        "holo rare vmax": .fullArtEtched,
        "holo rare vstar": .fullArtEtched,

        // Restrained full-face foils.
        "illustration rare": .illustrationRare,
        "full art trainer": .illustrationRare,
        // ACE SPEC's treatment is the silver/black frame, not a dense foil —
        // the restrained rim reads closest.
        "ace spec rare": .illustrationRare,

        "special illustration rare": .specialIllustrationRare,

        // Rainbow-band family: secret rares, shinies, and the legacy
        // one-off tiers that all shipped a full-spectrum sweep.
        "secret rare": .secretRainbow,
        "shiny rare": .secretRainbow,
        "shiny rare v": .secretRainbow,
        "shiny rare vmax": .secretRainbow,
        "shiny ultra rare": .secretRainbow,
        "one shiny": .secretRainbow,
        "two shiny": .secretRainbow,
        "rare holo lv.x": .secretRainbow,
        "rare prime": .secretRainbow,
        "black white rare": .secretRainbow,
        "classic collection": .secretRainbow,
        "legend": .secretRainbow,

        // Gold.
        "hyper rare": .goldHyper,
        "crown": .goldHyper,
        "mega hyper rare": .megaHyperGold
    ]

    /// Normalizes a raw TCGdex rarity string + the physical printing into a
    /// tier. Pure and nonisolated so it can run on any actor (and be tested).
    ///
    /// Precedence: an explicit foil rarity always wins; otherwise the physical
    /// variant decides, which is what rescues the classic era (base-set
    /// Charizard is `rarity: "Rare"`, holo only by `variants.holo`) and every
    /// reverse-holo printing of an otherwise ordinary Common.
    static func resolve(rarity: String?, variant: CardVariant) -> FoilTier {
        let key = (rarity ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if let named = table[key] { return named }
        switch variant {
        case .holo: return .holoArt
        case .reverse: return .reverseInverse
        case .normal, .firstEdition: return .none
        }
    }

    /// Which art-window rectangle the shader masks with. 0 = the classic
    /// vertical frame (base set through Sword & Shield), 1 = the slightly
    /// higher/smaller Scarlet & Violet-era window. Keyed off the set prefix of
    /// a TCGdex card id (`"sv01-220"`, `"me02-130"`), which is the only era
    /// signal that reaches the render layer.
    ///
    /// Both rectangles are approximations — see the calibration note on
    /// `bb_art_box` in CardSurface.metal.
    static func artBoxEra(cardID: String) -> Int {
        let set = cardID.split(separator: "-").first.map(String.init) ?? cardID
        let lower = set.lowercased()
        // "sv01", "sv08.5", "me01", "me02.5" — but not "swsh*" or "smp".
        for prefix in ["sv", "me"] where lower.hasPrefix(prefix) {
            let rest = lower.dropFirst(prefix.count)
            if rest.first?.isNumber == true { return 1 }
        }
        return 0
    }
}

/// Packing helpers for the single `CustomMaterial.custom.value` float4 the
/// card surface shader gets. Pure, so CardSurface.metal's decode has a
/// testable Swift twin.
nonisolated enum FoilUniforms {
    /// Largest strength that still leaves `floor(x)` equal to the tier code.
    static let maxStrength: Float = 0.995

    /// `custom.value.x` — tier code in the integer part, foil amplitude in the
    /// fraction.
    static func packTier(_ tier: FoilTier, strength: Float) -> Float {
        Float(tier.rawValue) + min(max(strength, 0), maxStrength)
    }

    /// `custom.value.y` — art-box era in the integer part (x2, so the era bit
    /// never collides with a fractional grayscale blend), grayscale in the
    /// remainder.
    static func packEra(_ era: Int, grayscale: Float) -> Float {
        Float(max(era, 0)) * 2 + min(max(grayscale, 0), 1)
    }

    static func unpackTier(_ x: Float) -> FoilTier {
        FoilTier(rawValue: Int(x.rounded(.down))) ?? .none
    }

    static func unpackStrength(_ x: Float) -> Float {
        x - x.rounded(.down)
    }

    static func unpackEra(_ y: Float) -> Int {
        Int((y * 0.5).rounded(.down))
    }

    static func unpackGrayscale(_ y: Float) -> Float {
        min(max(y - Float(unpackEra(y)) * 2, 0), 1)
    }

    /// Rewrites only the grayscale part of a packed `y`, leaving the era alone.
    static func withGrayscale(_ y: Float, _ grayscale: Float) -> Float {
        packEra(unpackEra(y), grayscale: grayscale)
    }
}
