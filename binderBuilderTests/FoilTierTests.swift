//
//  FoilTierTests.swift
//  binderBuilderTests
//
//  The rarity -> foil-effect normalization table and the CustomMaterial
//  uniform packing it feeds. Covers every rarity string TCGdex's /rarities
//  endpoint returns (the union across the whole database, including the
//  Japanese diamond/star translations that a naive switch would miss), plus
//  the era caveats: classic "Rare" is a holo only via `variants.holo`, and
//  unknown/future strings must degrade to a safe no-effect fallback.
//

import Testing
@testable import binderBuilder

struct FoilTierNormalizationTests {
    /// Verbatim from `GET /v2/en/rarities`.
    static let inventory = [
        "ACE SPEC Rare", "Amazing Rare", "Black White Rare", "Classic Collection", "Common",
        "Crown", "Double rare", "Four Diamond", "Full Art Trainer", "Holo Rare", "Holo Rare V",
        "Holo Rare VMAX", "Holo Rare VSTAR", "Hyper rare", "Illustration rare", "LEGEND",
        "Mega Hyper Rare", "None", "One Diamond", "One Shiny", "One Star", "Promo",
        "Radiant Rare", "Rare", "Rare Holo", "Rare Holo LV.X", "Rare PRIME", "Secret Rare",
        "Shiny Ultra Rare", "Shiny rare", "Shiny rare V", "Shiny rare VMAX",
        "Special illustration rare", "Three Diamond", "Three Star", "Two Diamond", "Two Shiny",
        "Two Star", "Ultra Rare", "Uncommon"
    ]

    /// Every string in the live inventory resolves without trapping, and the
    /// non-foil buckets stay flat for a plain printing.
    @Test func everyKnownRarityStringMapsSomewhereSane() {
        let flat: Set<String> = [
            "Common", "Uncommon", "None", "Promo", "Rare",
            "One Diamond", "Two Diamond", "Three Diamond", "Four Diamond"
        ]
        for rarity in Self.inventory {
            let tier = FoilTier.resolve(rarity: rarity, variant: .normal)
            if flat.contains(rarity) {
                #expect(tier == .none, "\(rarity) should be flat for a normal printing")
            } else {
                #expect(tier != .none, "\(rarity) names a foil and should not resolve to .none")
            }
        }
    }

    @Test func classicRareIsHoloOnlyViaTheVariant() {
        // base1-4 Charizard: rarity "Rare", disambiguated by variants.holo.
        #expect(FoilTier.resolve(rarity: "Rare", variant: .holo) == .holoArt)
        #expect(FoilTier.resolve(rarity: "Rare", variant: .normal) == .none)
        #expect(FoilTier.resolve(rarity: "Rare", variant: .firstEdition) == .none)
        #expect(FoilTier.resolve(rarity: "Rare", variant: .reverse) == .reverseInverse)
    }

    @Test func reverseVariantOfAnOrdinaryCardGetsTheInverseMask() {
        #expect(FoilTier.resolve(rarity: "Common", variant: .reverse) == .reverseInverse)
        #expect(FoilTier.resolve(rarity: "Uncommon", variant: .reverse) == .reverseInverse)
        // ...but a named foil rarity still wins over the physical variant.
        #expect(FoilTier.resolve(rarity: "Hyper rare", variant: .reverse) == .goldHyper)
    }

    @Test func eraSpecificStringsLandOnTheirTier() {
        // SwSh era.
        #expect(FoilTier.resolve(rarity: "Ultra Rare", variant: .holo) == .fullArtEtched)
        #expect(FoilTier.resolve(rarity: "Holo Rare VSTAR", variant: .holo) == .fullArtEtched)
        #expect(FoilTier.resolve(rarity: "Secret Rare", variant: .holo) == .secretRainbow)
        // SV era.
        #expect(FoilTier.resolve(rarity: "Illustration rare", variant: .normal) == .illustrationRare)
        #expect(FoilTier.resolve(rarity: "Special illustration rare", variant: .normal)
                == .specialIllustrationRare)
        #expect(FoilTier.resolve(rarity: "Hyper rare", variant: .normal) == .goldHyper)
        // Mega Evolution era.
        #expect(FoilTier.resolve(rarity: "Mega Hyper Rare", variant: .holo) == .megaHyperGold)
    }

    @Test func japaneseDiamondAndStarMarksFoldIntoTheRightBuckets() {
        for diamond in ["One Diamond", "Two Diamond", "Three Diamond", "Four Diamond"] {
            #expect(FoilTier.resolve(rarity: diamond, variant: .normal) == .none)
        }
        for star in ["One Star", "Two Star", "Three Star"] {
            #expect(FoilTier.resolve(rarity: star, variant: .normal) == .holoArt)
        }
        for shiny in ["One Shiny", "Two Shiny", "Shiny rare", "Shiny Ultra Rare"] {
            #expect(FoilTier.resolve(rarity: shiny, variant: .normal) == .secretRainbow)
        }
    }

    @Test func unknownAndFutureStringsFallBackSafely() {
        #expect(FoilTier.resolve(rarity: nil, variant: .normal) == .none)
        #expect(FoilTier.resolve(rarity: "", variant: .normal) == .none)
        #expect(FoilTier.resolve(rarity: "None", variant: .normal) == .none)
        #expect(FoilTier.resolve(rarity: "Ultra Mega Cosmic Rare 2031", variant: .normal) == .none)
        // An unknown string on a holo printing still gets the classic holo.
        #expect(FoilTier.resolve(rarity: "Ultra Mega Cosmic Rare 2031", variant: .holo) == .holoArt)
    }

    @Test func lookupIsCaseAndWhitespaceInsensitive() {
        #expect(FoilTier.resolve(rarity: "  hyper RARE ", variant: .normal) == .goldHyper)
        #expect(FoilTier.resolve(rarity: "SPECIAL ILLUSTRATION RARE", variant: .normal)
                == .specialIllustrationRare)
    }

    @Test func everyTierHasABoundedIntensity() {
        for tier in FoilTier.allCases {
            #expect(tier.intensity > 0)
            #expect(tier.intensity <= FoilUniforms.maxStrength)
        }
        // Only the masked tiers care which art-window rect the shader uses.
        #expect(FoilTier.holoArt.usesArtBoxMask)
        #expect(FoilTier.reverseInverse.usesArtBoxMask)
        #expect(!FoilTier.megaHyperGold.usesArtBoxMask)
    }
}

struct FoilArtBoxEraTests {
    @Test func modernFramesSelectTheHigherArtWindow() {
        #expect(FoilTier.artBoxEra(cardID: "sv01-220") == 1)
        #expect(FoilTier.artBoxEra(cardID: "sv08.5-161") == 1)
        #expect(FoilTier.artBoxEra(cardID: "me02-130") == 1)
    }

    @Test func classicFramesKeepTheStandardWindow() {
        #expect(FoilTier.artBoxEra(cardID: "base1-4") == 0)
        #expect(FoilTier.artBoxEra(cardID: "swsh9-153") == 0)   // "sw..." must not match "sv"
        #expect(FoilTier.artBoxEra(cardID: "smp-SM01") == 0)
        #expect(FoilTier.artBoxEra(cardID: "col1-SL7") == 0)
        #expect(FoilTier.artBoxEra(cardID: "garbage") == 0)
    }
}

/// The shader decodes these by hand (`floor(u.x)`, `u.x - floor(u.x)`,
/// `floor(u.y * 0.5)`, `u.y - floor(u.y*0.5)*2`), so the round trip has to
/// survive float32 exactly for every tier.
struct FoilUniformPackingTests {
    @Test func tierAndStrengthRoundTripForEveryTier() {
        for tier in FoilTier.allCases {
            for strength: Float in [0, 0.1, 0.5, 0.85, 0.99, 1.0, 2.0, -1.0] {
                let packed = FoilUniforms.packTier(tier, strength: strength)
                #expect(FoilUniforms.unpackTier(packed) == tier)
                let expected = min(max(strength, 0), FoilUniforms.maxStrength)
                #expect(abs(FoilUniforms.unpackStrength(packed) - expected) < 1e-4)
            }
        }
    }

    @Test func eraAndGrayscaleRoundTrip() {
        for era in [0, 1] {
            for gray: Float in [0, 0.5, 1] {
                let packed = FoilUniforms.packEra(era, grayscale: gray)
                #expect(FoilUniforms.unpackEra(packed) == era)
                #expect(abs(FoilUniforms.unpackGrayscale(packed) - gray) < 1e-5)
            }
        }
    }

    @Test func flippingGrayscalePreservesTheEra() {
        for era in [0, 1] {
            let owned = FoilUniforms.packEra(era, grayscale: 0)
            let unowned = FoilUniforms.withGrayscale(owned, 1)
            #expect(FoilUniforms.unpackEra(unowned) == era)
            #expect(FoilUniforms.unpackGrayscale(unowned) == 1)
            #expect(FoilUniforms.unpackGrayscale(FoilUniforms.withGrayscale(unowned, 0)) == 0)
        }
    }

    @Test func aFullStrengthFoilNeverBleedsIntoTheTierCode() {
        // The whole packing rests on strength staying strictly below 1.
        let packed = FoilUniforms.packTier(.megaHyperGold, strength: 1.0)
        #expect(packed < Float(FoilTier.megaHyperGold.rawValue + 1))
        #expect(FoilUniforms.unpackTier(packed) == .megaHyperGold)
    }
}

struct CardSlotRenderFoilTests {
    private func render(_ id: String, _ variant: CardVariant, _ rarity: String?) -> CardSlotRender {
        CardSlotRender(
            ref: CardRef(cardID: id, variant: variant), imageBase: nil, owned: true, rarity: rarity
        )
    }

    @Test func renderResolvesItsOwnTier() {
        #expect(render("base1-4", .holo, "Rare").foil == .holoArt)
        #expect(render("base1-46", .normal, "Common").foil == .none)
        #expect(render("me02-130", .holo, "Mega Hyper Rare").foil == .megaHyperGold)
        // No rarity plumbed (older snapshots / debug content) still degrades.
        #expect(CardSlotRender(ref: CardRef(cardID: "x-1", variant: .normal),
                               imageBase: nil, owned: true).foil == .none)
    }

    @Test func debugContentSourceCoversEveryTier() {
        let source = DebugCardContentSource()
        var seen: Set<FoilTier> = []
        for sheet in 0..<source.sheetCount {
            let snap = source.snapshot(sheet: sheet)
            for card in snap.front + snap.back { if let card { seen.insert(card.foil) } }
        }
        #expect(seen == Set(FoilTier.allCases))
    }
}

/// The demo binder's opening spread is the first thing a new install sees, and
/// it is supposed to be one card per foil treatment rather than eighteen
/// commons. Two things have to hold for that: the showcase list has to actually
/// name every tier, and the splice arithmetic has to drop it on the spread the
/// scene opens to.
@MainActor
struct DemoSeedShowcaseTests {
    @Test func showcaseNamesEveryFoilTierWorthShowing() {
        let claimed = Set(DemoSeed.showcase.map(\.tier))
        // `.none` is deliberately absent — it is what the surrounding base-set
        // commons already render, so a slot spent on it would be a wasted one.
        #expect(claimed == Set(FoilTier.allCases).subtracting([.none]))
        // Exactly one spread's worth, so the splice lands flush.
        #expect(DemoSeed.showcase.count == SpreadModel.slotsPerPage * 2)
        #expect(Set(DemoSeed.showcaseIDs).count == DemoSeed.showcase.count)
    }

    @Test func theShowcaseLandsExactlyOnTheSpreadTheSceneOpensTo() {
        // Base Set is 102 cards; the showcase adds 18.
        let plan = DemoSeed.ShowcasePlan(baseCount: 102, showcaseCount: DemoSeed.showcase.count)
        #expect(plan.pageCount == 7)
        #expect(plan.openingSpread == plan.pageCount / 2)
        let spliced = plan.spliceIndex..<(plan.spliceIndex + DemoSeed.showcase.count)
        #expect(spliced == plan.visibleRange)
    }

    /// Small/large catalogs must still splice inside the layout and inside the
    /// binder — a plan that points past either would seed an invisible showcase.
    @Test func theSpliceStaysInBoundsForAnyCatalogSize() {
        for baseCount in [0, 9, 18, 40, 102, 400] {
            let plan = DemoSeed.ShowcasePlan(baseCount: baseCount, showcaseCount: 18)
            #expect(plan.pageCount >= 2)
            #expect(plan.pageCount <= 8)
            #expect(plan.spliceIndex >= 0)
            #expect(plan.visibleRange.lowerBound == plan.spliceIndex)
            // The opening spread has to exist inside the binder.
            #expect(plan.openingSpread <= plan.pageCount)
            #expect(plan.visibleRange.upperBound <= plan.pageCount * SpreadModel.slotsPerPage * 2)
        }
    }
}
