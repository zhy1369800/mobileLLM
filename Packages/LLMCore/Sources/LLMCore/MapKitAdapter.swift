// SPDX-License-Identifier: MIT

#if canImport(MapKit)
import Foundation
import MapKit
import CoreLocation

/// The real, on-device `MapKitProviding` backed by Apple MapKit and CoreLocation.
/// Not unit-tested directly (device only); LLMCore's tests exercise `MapKitTool` through a fake conforming to `MapKitProviding`.
public final class MapKitProvider: MapKitProviding, @unchecked Sendable {
    public init() {}

    private func resolveMapItem(
        address: String?,
        coord: (latitude: Double, longitude: Double)?
    ) async throws -> MKMapItem {
        if let c = coord {
            let clCoord = CLLocationCoordinate2D(latitude: c.latitude, longitude: c.longitude)
            return MKMapItem(placemark: MKPlacemark(coordinate: clCoord))
        } else if let addr = address?.trimmingCharacters(in: .whitespacesAndNewlines), !addr.isEmpty {
            let placemarks = try await CLGeocoder().geocodeAddressString(addr)
            guard let first = placemarks.first else {
                throw MapKitError.invalidParameters("Address not found: " + addr)
            }
            return MKMapItem(placemark: MKPlacemark(placemark: first))
        } else {
            throw MapKitError.invalidParameters("Must provide either an address or coordinates.")
        }
    }

    public func searchPlaces(
        query: String,
        center: (latitude: Double, longitude: Double)?,
        radiusMeters: Double,
        limit: Int
    ) async throws -> [MapPlaceItem] {
        let req = MKLocalSearch.Request()
        req.naturalLanguageQuery = query
        if let c = center {
            let clCoord = CLLocationCoordinate2D(latitude: c.latitude, longitude: c.longitude)
            req.region = MKCoordinateRegion(
                center: clCoord,
                latitudinalMeters: radiusMeters * 2,
                longitudinalMeters: radiusMeters * 2
            )
        }
        let search = MKLocalSearch(request: req)
        let response = try await search.start()
        let items = response.mapItems

        let userLoc: CLLocation? = center.map { CLLocation(latitude: $0.latitude, longitude: $0.longitude) }

        return Array(items.prefix(limit)).map { item in
            let coord = item.placemark.coordinate
            let distance: Int?
            if let userLoc {
                let d = userLoc.distance(from: CLLocation(latitude: coord.latitude, longitude: coord.longitude))
                distance = Int(d.rounded())
            } else {
                distance = nil
            }
            let addrParts = [
                item.placemark.subThoroughfare,
                item.placemark.thoroughfare,
                item.placemark.locality,
                item.placemark.administrativeArea,
                item.placemark.country
            ].compactMap { $0 }

            return MapPlaceItem(
                name: item.name ?? "Unknown Place",
                phoneNumber: item.phoneNumber,
                url: item.url?.absoluteString,
                latitude: coord.latitude,
                longitude: coord.longitude,
                address: addrParts.joined(separator: " "),
                distanceMeters: distance
            )
        }
    }

    public func calculateRoute(
        fromAddress: String?,
        fromCoord: (latitude: Double, longitude: Double)?,
        toAddress: String?,
        toCoord: (latitude: Double, longitude: Double)?,
        mode: String?
    ) async throws -> RouteInfo {
        let fromItem = try await resolveMapItem(address: fromAddress, coord: fromCoord)
        let toItem = try await resolveMapItem(address: toAddress, coord: toCoord)

        let req = MKDirections.Request()
        req.source = fromItem
        req.destination = toItem
        req.transportType = transportType(from: mode)
        req.requestsAlternateRoutes = false

        let directions = MKDirections(request: req)
        let response = try await directions.calculate()
        guard let route = response.routes.first else {
            throw MapKitError.routeFailed("No route found between the specified locations.")
        }

        let steps = route.steps
            .filter { !$0.instructions.isEmpty }
            .map { RouteStepInfo(instruction: $0.instructions, distanceMeters: Int($0.distance.rounded())) }

        return RouteInfo(
            distanceKilometers: (route.distance / 1000.0 * 10).rounded() / 10,
            durationMinutes: (route.expectedTravelTime / 60.0).rounded(),
            steps: steps
        )
    }

    public func calculateEta(
        fromAddress: String?,
        fromCoord: (latitude: Double, longitude: Double)?,
        toAddress: String?,
        toCoord: (latitude: Double, longitude: Double)?,
        mode: String?
    ) async throws -> EtaInfo {
        let fromItem = try await resolveMapItem(address: fromAddress, coord: fromCoord)
        let toItem = try await resolveMapItem(address: toAddress, coord: toCoord)

        let req = MKDirections.Request()
        req.source = fromItem
        req.destination = toItem
        req.transportType = transportType(from: mode)

        let directions = MKDirections(request: req)
        let eta = try await directions.calculateETA()

        return EtaInfo(
            distanceKilometers: (eta.distance / 1000.0 * 10).rounded() / 10,
            durationMinutes: (eta.expectedTravelTime / 60.0).rounded(),
            expectedArrival: eta.expectedArrivalDate
        )
    }

    private func transportType(from mode: String?) -> MKDirectionsTransportType {
        switch mode?.lowercased() {
        case "walking": return .walking
        case "transit": return .transit
        default: return .automobile
        }
    }
}
#endif
