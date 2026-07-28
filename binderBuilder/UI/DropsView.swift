//
//  DropsView.swift
//  binderBuilder
//
//  Release calendar + "stores near you": upcoming set countdowns with a
//  per-release reminder bell (DropStore), and a saved/nearby card-shop list
//  fed by MapKit search (StoreFinder) once the user grants When-In-Use
//  location (LocationAuthority). Pushed from Settings -> "Release calendar &
//  stores"; also reachable via -showDrops for debug/screenshot verification.
//
//  Owns its own DropStore/FavoriteStoreStore/LocationAuthority off
//  env.userDatabase — the same "own store" pattern CardPickerView uses for
//  its CatalogStore — so this view never needs AppEnvironment to carry
//  drop-specific state.
//
//  These are release-date reminders, never live stock alerts: no free app can
//  see what's actually on a store's shelf, so the copy here never implies it.
//

import CoreLocation
import SwiftUI

struct DropsView: View {
    let env: AppEnvironment

    @State private var drops: DropStore
    @State private var favorites: FavoriteStoreStore
    @State private var location = LocationAuthority()

    @State private var nearby: [NearbyStore] = []
    @State private var searching = false
    @State private var searchErrorMessage: String?

    init(env: AppEnvironment) {
        self.env = env
        _drops = State(initialValue: DropStore(database: env.userDatabase))
        _favorites = State(initialValue: FavoriteStoreStore(database: env.userDatabase))
    }

    private var today: Date { Calendar.current.startOfDay(for: Date()) }

    /// The bundled calendar, ascending, with anything already behind us
    /// trimmed from view (still present in `drops.releases` for scheduling).
    private var comingUp: [UpcomingRelease] {
        drops.releases.filter { $0.expectedDate >= today }
    }

    /// Nearby search results not already saved, so favorites aren't shown twice.
    private var unsavedNearby: [NearbyStore] {
        nearby.filter { !favorites.isFavorite($0.id) }
    }

    var body: some View {
        List {
            comingUpSection
            storesSection
            Section {
            } footer: {
                Text("Drops are release-date reminders, not live stock alerts — no free app can see what is actually on a store's shelf. We remind you what is coming and where you saved stores to look.")
            }
        }
        .navigationTitle("Drops")
        .task { await drops.load(); await favorites.load() }
        .task(id: location.authorizationStatus) {
            guard location.authorizationStatus == .authorizedWhenInUse
                || location.authorizationStatus == .authorizedAlways
            else { return }
            await search()
        }
        .onChange(of: env.settings.dropRadiusMiles) { _, _ in Task { await search() } }
    }

    // MARK: - Coming up

    @ViewBuilder private var comingUpSection: some View {
        Section("Coming up") {
            if !drops.isLoaded {
                HStack { Spacer(); ProgressView(); Spacer() }
            } else if comingUp.isEmpty {
                Text("No upcoming releases yet — check back soon.")
                    .font(.footnote).foregroundStyle(.secondary)
            } else {
                ForEach(comingUp) { release in
                    CountdownCard(
                        release: release,
                        isSubscribed: drops.isSubscribed(release.id),
                        onToggleSubscribed: {
                            drops.setSubscribed(!drops.isSubscribed(release.id), for: release.id)
                        }
                    )
                }
            }
        }
    }

    // MARK: - Stores near you

    @ViewBuilder private var storesSection: some View {
        Section("Stores near you") {
            switch location.authorizationStatus {
            case .authorizedWhenInUse, .authorizedAlways:
                radiusPicker
                if searching {
                    HStack { Spacer(); ProgressView(); Spacer() }
                } else if let searchErrorMessage {
                    Text(searchErrorMessage).font(.footnote).foregroundStyle(.secondary)
                }
                ForEach(favorites.stores) { store in
                    storeRow(name: store.name, address: store.address, kind: store.kind, isSaved: true) {
                        favorites.remove(id: store.id)
                    }
                }
                ForEach(unsavedNearby) { store in
                    storeRow(name: store.name, address: store.address, kind: store.kind, isSaved: false) {
                        favorites.add(store)
                    }
                }
            case .denied, .restricted:
                Text("Location access is off, so we can't look for stores near you. Turn it on in Settings to see nearby shops here.")
                    .font(.footnote).foregroundStyle(.secondary)
            default:
                Button {
                    location.requestWhenInUse()
                } label: {
                    Label("Find stores near you", systemImage: "location")
                }
            }
        }
    }

    private var radiusPicker: some View {
        @Bindable var settings = env.settings
        return Picker("Search radius", selection: $settings.dropRadiusMiles) {
            Text("10 mi").tag(10.0)
            Text("25 mi").tag(25.0)
            Text("50 mi").tag(50.0)
            Text("100 mi").tag(100.0)
        }
        .pickerStyle(.segmented)
    }

    private func storeRow(
        name: String, address: String?, kind: StoreKind, isSaved: Bool, action: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.subheadline.weight(.medium))
                Text(kindLabel(kind)).font(.caption).foregroundStyle(.secondary)
                if let address {
                    Text(address).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button {
                Haptics.selection()
                action()
            } label: {
                Image(systemName: isSaved ? "star.fill" : "star")
                    .foregroundStyle(isSaved ? .yellow : .secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isSaved ? "Remove \(name) from saved stores" : "Save \(name)")
        }
        .padding(.vertical, 2)
    }

    private func kindLabel(_ kind: StoreKind) -> String {
        switch kind {
        case .lgs: "Local game store"
        case .bigbox: "Big box retailer"
        case .other: "Store"
        }
    }

    private func search() async {
        searching = true
        searchErrorMessage = nil
        defer { searching = false }
        do {
            let coordinate = try await location.currentLocation()
            nearby = await StoreFinder.search(near: coordinate, radiusMiles: env.settings.dropRadiusMiles)
        } catch {
            searchErrorMessage = "Couldn't get your location."
        }
    }
}
