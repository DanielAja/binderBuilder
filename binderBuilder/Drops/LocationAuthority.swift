//
//  LocationAuthority.swift
//  binderBuilder
//
//  Thin CLLocationManager wrapper for the drop-radius feature: When-In-Use
//  authorization only, and a single one-shot location fix (no continuous
//  updates, no region monitoring, no Always).
//

import CoreLocation
import Observation
import os

@MainActor
@Observable
final class LocationAuthority: NSObject {
    enum LocationError: Error {
        case denied
        case timeout
    }

    @ObservationIgnored private let manager = CLLocationManager()
    /// Every caller waiting on the one in-flight fix. A second request while
    /// one is pending joins it instead of overwriting (and leaking) the first
    /// caller's continuation and firing a second requestLocation().
    @ObservationIgnored private var waiters: [CheckedContinuation<CLLocationCoordinate2D, Error>] = []
    @ObservationIgnored private var timeoutTask: Task<Void, Never>?

    @ObservationIgnored
    nonisolated private static let logger = Logger(subsystem: "com.aja.binderBuilder", category: "LocationAuthority")

    private(set) var authorizationStatus: CLAuthorizationStatus

    override init() {
        authorizationStatus = manager.authorizationStatus
        super.init()
        manager.delegate = self
    }

    func requestWhenInUse() {
        manager.requestWhenInUseAuthorization()
    }

    /// One-shot current location; throws rather than hanging if the OS never
    /// delivers a fix (or the user hasn't authorized When-In-Use).
    func currentLocation() async throws -> CLLocationCoordinate2D {
        guard authorizationStatus == .authorizedWhenInUse || authorizationStatus == .authorizedAlways else {
            throw LocationError.denied
        }
        return try await withCheckedThrowingContinuation { continuation in
            let alreadyInFlight = !waiters.isEmpty
            waiters.append(continuation)
            guard !alreadyInFlight else { return }
            timeoutTask?.cancel()
            timeoutTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(10))
                // `try?` swallows the cancellation, so without this check a
                // timer cancelled by a delivered fix would still fire and fail
                // the NEXT request the moment it started waiting.
                guard !Task.isCancelled else { return }
                self?.fail(LocationError.timeout)
            }
            manager.requestLocation()
        }
    }

    private func resolve(with coordinate: CLLocationCoordinate2D) {
        timeoutTask?.cancel()
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume(returning: coordinate) }
    }

    private func fail(_ error: Error) {
        timeoutTask?.cancel()
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume(throwing: error) }
    }
}

extension LocationAuthority: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in self.authorizationStatus = status }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let coordinate = locations.last?.coordinate else { return }
        Task { @MainActor in self.resolve(with: coordinate) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Self.logger.error("location request failed: \(String(describing: error))")
        Task { @MainActor in self.fail(error) }
    }
}
