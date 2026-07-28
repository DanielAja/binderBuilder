//
//  StoreFinder.swift
//  binderBuilder
//
//  Finds nearby card shops and big-box retailers (for drop-radius alerts and
//  the favorite-store picker) via MKLocalSearch. Pure Sendable value types +
//  free functions so the classification/dedupe/radius logic is unit-testable
//  without touching the network.
//

import CoreLocation
import Foundation
import MapKit

/// Coarse classification of a search result, matching favorite_store.kind.
nonisolated enum StoreKind: String, Codable, CaseIterable, Sendable {
    case lgs      // local game/card/hobby shop
    case bigbox   // Target, Walmart, GameStop, Best Buy, ...
    case other
}

/// A place found near the user, already distance-filtered.
nonisolated struct NearbyStore: Identifiable, Sendable {
    var id: String
    var name: String
    var address: String?
    var latitude: Double
    var longitude: Double
    var kind: StoreKind
    var distanceMiles: Double

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

nonisolated enum StoreFinder {
    private static let metersPerMile = 1609.344

    /// Search terms fanned out in parallel to cover both dedicated card shops
    /// and the big-box retailers that stock sealed product.
    static let searchTerms = [
        "trading cards", "card shop", "game store", "hobby shop",
        "comic book store", "Target", "Walmart", "GameStop", "Best Buy",
    ]

    /// Searches every term near `coordinate`, merges + dedupes + radius-filters
    /// the results, and returns them sorted nearest-first. Individual query
    /// failures are swallowed (a bad term shouldn't blank the whole list).
    static func search(near coordinate: CLLocationCoordinate2D, radiusMiles: Double) async -> [NearbyStore] {
        let region = MKCoordinateRegion(
            center: coordinate,
            latitudinalMeters: radiusMiles * metersPerMile * 2,
            longitudinalMeters: radiusMiles * metersPerMile * 2)

        let batches: [[NearbyStore]] = await withTaskGroup(of: [NearbyStore].self) { group in
            for term in searchTerms {
                group.addTask {
                    let request = MKLocalSearch.Request()
                    request.naturalLanguageQuery = term
                    request.region = region
                    request.resultTypes = .pointOfInterest
                    guard let response = try? await MKLocalSearch(request: request).start() else { return [] }
                    return response.mapItems.compactMap { item -> NearbyStore? in
                        guard let name = item.name else { return nil }
                        let itemCoordinate = item.placemark.coordinate
                        let distance = distanceMiles(from: coordinate, to: itemCoordinate)
                        return NearbyStore(
                            id: makeID(latitude: itemCoordinate.latitude, longitude: itemCoordinate.longitude, name: name),
                            name: name,
                            address: item.placemark.title,
                            latitude: itemCoordinate.latitude,
                            longitude: itemCoordinate.longitude,
                            kind: kind(forName: name),
                            distanceMiles: distance)
                    }
                }
            }
            var collected: [[NearbyStore]] = []
            for await batch in group { collected.append(batch) }
            return collected
        }

        let merged = withinRadius(dedupe(batches.flatMap { $0 }), radiusMiles: radiusMiles)
        return merged.sorted { $0.distanceMiles < $1.distanceMiles }
    }

    // MARK: - Pure helpers (unit-tested)

    /// Straight-line distance in miles between two coordinates.
    static func distanceMiles(from origin: CLLocationCoordinate2D, to point: CLLocationCoordinate2D) -> Double {
        let a = CLLocation(latitude: origin.latitude, longitude: origin.longitude)
        let b = CLLocation(latitude: point.latitude, longitude: point.longitude)
        return a.distance(from: b) / metersPerMile
    }

    /// Classifies a place name into lgs (local game/card shop), bigbox, or
    /// other. Checked in this order so brand names never fall through to the
    /// generic "game"/"card" keyword bucket (e.g. GameStop is bigbox, not lgs).
    static func kind(forName name: String) -> StoreKind {
        let lowered = name.lowercased()
        let bigBoxBrands = ["target", "walmart", "gamestop", "best buy"]
        if bigBoxBrands.contains(where: { lowered.contains($0) }) { return .bigbox }
        let lgsKeywords = ["card", "comic", "hobby", "game", "collectible"]
        if lgsKeywords.contains(where: { lowered.contains($0) }) { return .lgs }
        return .other
    }

    /// Collapses results the fanned-out queries return more than once
    /// (identical coordinate to 4dp + name); distinct places are kept.
    static func dedupe(_ stores: [NearbyStore]) -> [NearbyStore] {
        var seen = Set<String>()
        return stores.filter {
            seen.insert(makeID(latitude: $0.latitude, longitude: $0.longitude, name: $0.name)).inserted
        }
    }

    /// Radius filter, inclusive of the boundary (a store exactly at the
    /// configured radius still counts as "nearby").
    static func withinRadius(_ stores: [NearbyStore], radiusMiles: Double) -> [NearbyStore] {
        stores.filter { $0.distanceMiles <= radiusMiles }
    }

    private static func makeID(latitude: Double, longitude: Double, name: String) -> String {
        "\(round4(latitude)),\(round4(longitude))|\(name.lowercased())"
    }

    private static func round4(_ value: Double) -> Double {
        (value * 10_000).rounded() / 10_000
    }
}
