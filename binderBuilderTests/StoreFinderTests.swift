//
//  StoreFinderTests.swift
//  binderBuilderTests
//
//  Pure-helper coverage for StoreFinder: name classification, dedupe, and the
//  radius boundary. No network calls (MKLocalSearch itself isn't exercised).
//

import CoreLocation
import Testing
@testable import binderBuilder

struct StoreFinderTests {

    private func store(
        name: String, lat: Double = 40.0, lon: Double = -75.0,
        kind: StoreKind = .other, distance: Double = 1.0
    ) -> NearbyStore {
        NearbyStore(
            id: "\(lat),\(lon)|\(name.lowercased())", name: name, address: nil,
            latitude: lat, longitude: lon, kind: kind, distanceMiles: distance)
    }

    // MARK: - kind(forName:)

    @Test func classifiesBigBoxBrands() {
        #expect(StoreFinder.kind(forName: "Target Supercenter") == .bigbox)
        #expect(StoreFinder.kind(forName: "Walmart Supercenter") == .bigbox)
        #expect(StoreFinder.kind(forName: "GameStop") == .bigbox)
        #expect(StoreFinder.kind(forName: "Best Buy") == .bigbox)
    }

    @Test func classifiesLocalGameShops() {
        #expect(StoreFinder.kind(forName: "Bob's Cards & Comics") == .lgs)
        #expect(StoreFinder.kind(forName: "Downtown Hobby Shop") == .lgs)
        #expect(StoreFinder.kind(forName: "Midtown Comics") == .lgs)
    }

    @Test func classifiesOther() {
        #expect(StoreFinder.kind(forName: "Joe's Diner") == .other)
        #expect(StoreFinder.kind(forName: "First National Bank") == .other)
    }

    // MARK: - dedupe(_:)

    @Test func dedupeCollapsesSameCoordAndName() {
        let a = store(name: "Bob's Cards", lat: 40.00001, lon: -75.00001)
        let sameSpot = store(name: "Bob's Cards", lat: 40.00002, lon: -75.00002) // rounds to same 4dp
        let deduped = StoreFinder.dedupe([a, sameSpot])
        #expect(deduped.count == 1)
    }

    @Test func dedupeKeepsDistinctPlaces() {
        let a = store(name: "Bob's Cards", lat: 40.0, lon: -75.0)
        let differentName = store(name: "Target", lat: 40.0, lon: -75.0)
        let differentSpot = store(name: "Bob's Cards", lat: 41.0, lon: -76.0)
        let deduped = StoreFinder.dedupe([a, differentName, differentSpot])
        #expect(deduped.count == 3)
    }

    // MARK: - withinRadius(_:radiusMiles:)

    @Test func radiusBoundaryIsInclusive() {
        let atBoundary = store(name: "Edge Cards", distance: 25.0)
        let within = StoreFinder.withinRadius([atBoundary], radiusMiles: 25.0)
        #expect(within.count == 1)
    }

    @Test func radiusExcludesBeyondBoundary() {
        let justBeyond = store(name: "Far Cards", distance: 25.01)
        let within = StoreFinder.withinRadius([justBeyond], radiusMiles: 25.0)
        #expect(within.isEmpty)
    }

    @Test func radiusIncludesEverythingCloser() {
        let close = store(name: "Close Cards", distance: 1.0)
        let within = StoreFinder.withinRadius([close], radiusMiles: 25.0)
        #expect(within.count == 1)
    }

    // MARK: - distanceMiles(from:to:)

    @Test func distanceIsZeroForSameCoordinate() {
        let coordinate = CLLocationCoordinate2D(latitude: 40.0, longitude: -75.0)
        #expect(StoreFinder.distanceMiles(from: coordinate, to: coordinate) == 0)
    }

    @Test func distanceIsPositiveForDifferentCoordinates() {
        let origin = CLLocationCoordinate2D(latitude: 40.0, longitude: -75.0)
        let point = CLLocationCoordinate2D(latitude: 41.0, longitude: -75.0)
        #expect(StoreFinder.distanceMiles(from: origin, to: point) > 0)
    }
}
