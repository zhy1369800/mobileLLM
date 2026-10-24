// SPDX-License-Identifier: MIT

import Foundation

// MARK: - Location & Map Data Structures

/// Detailed reverse-geocoded address information.
public struct PlacemarkInfo: Sendable, Equatable {
    public var name: String?
    public var country: String?
    public var administrativeArea: String? // State / Province
    public var locality: String?           // City
    public var subLocality: String?        // District / Suburb
    public var thoroughfare: String?       // Street
    public var subThoroughfare: String?    // Street number
    public var postalCode: String?
    public var formattedAddress: String?

    public init(
        name: String? = nil,
        country: String? = nil,
        administrativeArea: String? = nil,
        locality: String? = nil,
        subLocality: String? = nil,
        thoroughfare: String? = nil,
        subThoroughfare: String? = nil,
        postalCode: String? = nil,
        formattedAddress: String? = nil
    ) {
        self.name = name
        self.country = country
        self.administrativeArea = administrativeArea
        self.locality = locality
        self.subLocality = subLocality
        self.thoroughfare = thoroughfare
        self.subThoroughfare = subThoroughfare
        self.postalCode = postalCode
        self.formattedAddress = formattedAddress
    }
}

/// A location fix with coordinates, precision and detailed address info.
public struct LocationFix: Sendable, Equatable {
    public var latitude: Double
    public var longitude: Double
    public var altitude: Double?
    public var accuracy: Double        // horizontal accuracy in meters
    public var speed: Double?
    public var heading: Double?
    public var locality: String?       // convenient place name / city
    public var placemark: PlacemarkInfo?

    public init(
        latitude: Double,
        longitude: Double,
        altitude: Double? = nil,
        accuracy: Double,
        speed: Double? = nil,
        heading: Double? = nil,
        locality: String? = nil,
        placemark: PlacemarkInfo? = nil
    ) {
        self.latitude = latitude
        self.longitude = longitude
        self.altitude = altitude
        self.accuracy = accuracy
        self.speed = speed
        self.heading = heading
        self.locality = locality ?? placemark?.locality
        self.placemark = placemark
    }
}

/// Forward-geocoded coordinates for a searched address string.
public struct GeocodedCoordinate: Sendable, Equatable {
    public var latitude: Double
    public var longitude: Double
    public var displayName: String?

    public init(latitude: Double, longitude: Double, displayName: String? = nil) {
        self.latitude = latitude
        self.longitude = longitude
        self.displayName = displayName
    }
}

/// A map point of interest (POI) item from MKLocalSearch.
public struct MapPlaceItem: Sendable, Equatable {
    public var name: String
    public var phoneNumber: String?
    public var url: String?
    public var latitude: Double
    public var longitude: Double
    public var address: String
    public var distanceMeters: Int?

    public init(
        name: String,
        phoneNumber: String? = nil,
        url: String? = nil,
        latitude: Double,
        longitude: Double,
        address: String,
        distanceMeters: Int? = nil
    ) {
        self.name = name
        self.phoneNumber = phoneNumber
        self.url = url
        self.latitude = latitude
        self.longitude = longitude
        self.address = address
        self.distanceMeters = distanceMeters
    }
}

/// A step in a route navigation plan.
public struct RouteStepInfo: Sendable, Equatable {
    public var instruction: String
    public var distanceMeters: Int

    public init(instruction: String, distanceMeters: Int) {
        self.instruction = instruction
        self.distanceMeters = distanceMeters
    }
}

/// Navigation route information.
public struct RouteInfo: Sendable, Equatable {
    public var distanceKilometers: Double
    public var durationMinutes: Double
    public var steps: [RouteStepInfo]

    public init(distanceKilometers: Double, durationMinutes: Double, steps: [RouteStepInfo] = []) {
        self.distanceKilometers = distanceKilometers
        self.durationMinutes = durationMinutes
        self.steps = steps
    }
}

/// Estimated travel time and arrival info.
public struct EtaInfo: Sendable, Equatable {
    public var distanceKilometers: Double
    public var durationMinutes: Double
    public var expectedArrival: Date

    public init(distanceKilometers: Double, durationMinutes: Double, expectedArrival: Date) {
        self.distanceKilometers = distanceKilometers
        self.durationMinutes = durationMinutes
        self.expectedArrival = expectedArrival
    }
}

/// Errors the location seam raises; the tool maps them to instructive strings.
public enum LocationError: Error, Sendable, Equatable {
    case denied
    case unavailable(String)
    case timeout
}

/// Errors raised by MapKit operations.
public enum MapKitError: Error, Sendable, Equatable {
    case searchFailed(String)
    case routeFailed(String)
    case etaFailed(String)
    case invalidParameters(String)
}

/// The authorization state of a privacy-gated tool's system permission.
public enum ToolPermission: Sendable, Equatable {
    case notDetermined
    case granted
    case denied
}

// MARK: - Seam Protocols

/// The CoreLocation seam. A real `CLLocationManager`-backed adapter conforms on-device; tests inject a fake.
public protocol LocationProviding: Sendable {
    func currentLocation() async throws -> LocationFix
    func geocode(address: String) async throws -> [GeocodedCoordinate]
    /// Current system authorization, without prompting.
    func permissionState() async -> ToolPermission
    /// Prompt the user if undetermined; resolves immediately when already decided.
    func requestPermission() async -> ToolPermission
}

public extension LocationProviding {
    func geocode(address: String) async throws -> [GeocodedCoordinate] { [] }
    func permissionState() async -> ToolPermission { .granted }
    func requestPermission() async -> ToolPermission { .granted }
}

/// The MapKit seam for POI search, directions and ETA calculations.
public protocol MapKitProviding: Sendable {
    func searchPlaces(
        query: String,
        center: (latitude: Double, longitude: Double)?,
        radiusMeters: Double,
        limit: Int
    ) async throws -> [MapPlaceItem]

    func calculateRoute(
        fromAddress: String?,
        fromCoord: (latitude: Double, longitude: Double)?,
        toAddress: String?,
        toCoord: (latitude: Double, longitude: Double)?,
        mode: String?
    ) async throws -> RouteInfo

    func calculateEta(
        fromAddress: String?,
        fromCoord: (latitude: Double, longitude: Double)?,
        toAddress: String?,
        toCoord: (latitude: Double, longitude: Double)?,
        mode: String?
    ) async throws -> EtaInfo

    func navigationURL(
        fromAddress: String?,
        fromCoord: (latitude: Double, longitude: Double)?,
        toAddress: String?,
        toCoord: (latitude: Double, longitude: Double)?,
        mode: String?
    ) -> URL?
}

public extension MapKitProviding {
    func navigationURL(
        fromAddress: String?,
        fromCoord: (latitude: Double, longitude: Double)?,
        toAddress: String?,
        toCoord: (latitude: Double, longitude: Double)?,
        mode: String?
    ) -> URL? {
        var components = URLComponents(string: "http://maps.apple.com/")
        var items: [URLQueryItem] = []
        if let s = fromAddress, !s.isEmpty {
            items.append(URLQueryItem(name: "saddr", value: s))
        } else if let c = fromCoord {
            items.append(URLQueryItem(name: "saddr", value: "\(c.latitude),\(c.longitude)"))
        }
        if let d = toAddress, !d.isEmpty {
            items.append(URLQueryItem(name: "daddr", value: d))
        } else if let c = toCoord {
            items.append(URLQueryItem(name: "daddr", value: "\(c.latitude),\(c.longitude)"))
        }
        let dirMode: String
        switch mode?.lowercased() {
        case "walking": dirMode = "w"
        case "transit": dirMode = "r"
        default: dirMode = "d"
        }
        items.append(URLQueryItem(name: "dirflg", value: dirMode))
        components?.queryItems = items
        return components?.url
    }
}

// MARK: - Tools

/// Unified tool for device GPS location and forward/reverse geocoding.
public struct LocationInfoTool: Tool {
    private let provider: any LocationProviding
    public init(provider: any LocationProviding) { self.provider = provider }

    public static let schema: ToolSchema = ToolSchema(
        name: "location_info_tool",
        description: "Get device GPS location and reverse-geocoded address (country, province, city, district, street), OR convert a natural language address into GPS coordinates.",
        parameters: [
            ToolParam(name: "action", kind: .string,
                      description: "Operation to perform: \"current\" (default, get current GPS location & address) or \"search\" (convert an address string into GPS coordinates)",
                      required: false),
            ToolParam(name: "address", kind: .string,
                      description: "The natural language address to convert to GPS coordinates. Required when action is \"search\"",
                      required: false),
            ToolParam(name: "include_address", kind: .boolean,
                      description: "Used with action \"current\". Whether to perform reverse geocoding for address details (default true)",
                      required: false),
        ]
    )

    public var schema: ToolSchema { Self.schema }

    public func execute(argumentsJSON: String) async -> String {
        let call = ToolCall(name: "location_info_tool", argumentsJSON: argumentsJSON)
        let action = (call.arg("action") ?? "current").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        if action == "search" {
            guard let address = call.arg("address")?.trimmingCharacters(in: .whitespacesAndNewlines), !address.isEmpty else {
                return "Error: parameter 'address' is required for search action."
            }
            do {
                let coords = try await provider.geocode(address: address)
                guard !coords.isEmpty else {
                    return "No GPS coordinates found for \"\(address)\"."
                }
                let lines = coords.map { c in
                    let nameStr = (c.displayName?.isEmpty == false) ? " (\(c.displayName!))" : ""
                    return String(format: "• %.5f, %.5f%@", c.latitude, c.longitude, nameStr)
                }
                return "Coordinates for \"\(address)\":\n" + lines.joined(separator: "\n")
            } catch {
                return "Failed to geocode address: \(errorText(error))."
            }
        }

        // action: "current"
        do {
            let fix = try await provider.currentLocation()
            var parts: [String] = []
            let coordsStr = String(format: "%.5f, %.5f (±%dm)", fix.latitude, fix.longitude, max(0, Int(fix.accuracy.rounded())))
            parts.append("Coordinates: \(coordsStr)")

            if let p = fix.placemark {
                if let formatted = p.formattedAddress, !formatted.isEmpty {
                    parts.append("Address: \(formatted)")
                }
                var details: [String] = []
                if let c = p.country { details.append("Country: \(c)") }
                if let s = p.administrativeArea { details.append("State/Province: \(s)") }
                if let city = p.locality { details.append("City: \(city)") }
                if let d = p.subLocality { details.append("District: \(d)") }
                if let street = p.thoroughfare {
                    let num = p.subThoroughfare.map { " \($0)" } ?? ""
                    details.append("Street: \(street)\(num)")
                }
                if let code = p.postalCode { details.append("Postal Code: \(code)") }
                if !details.isEmpty {
                    parts.append("Details: " + details.joined(separator: ", "))
                }
            } else if let loc = fix.locality, !loc.isEmpty {
                parts.append("Locality: \(loc)")
            }

            return parts.joined(separator: "\n")
        } catch LocationError.denied {
            return "Location access is off — enable it in Settings to use your location."
        } catch LocationError.timeout {
            return "Couldn't get your location in time — please try again in a moment."
        } catch LocationError.unavailable(let why) {
            return "Location is unavailable right now (\(why))."
        } catch {
            return "Location is unavailable right now."
        }
    }
}

/// Tool for place/POI search, route navigation planning, ETA estimation, and opening Apple Maps.
public struct MapKitTool: Tool {
    private let provider: any MapKitProviding
    public init(provider: any MapKitProviding) { self.provider = provider }

    public static let schema: ToolSchema = ToolSchema(
        name: "map_kit_tool",
        description: "MapKit tool for place/POI search, road route planning with turn-by-turn steps, ETA estimation, and opening Apple Maps navigation natively on device.",
        parameters: [
            ToolParam(name: "action", kind: .string,
                      description: "Action to perform: \"search_places\" (find POIs near a location), \"get_route\" (road route with steps, distance, duration), \"get_eta\" (quick ETA only), \"open_navigation\" (launch Apple Maps for navigation)"),
            ToolParam(name: "query", kind: .string,
                      description: "Search keyword for search_places (e.g. \"coffee shop\", \"gas station\", \"故宫\")", required: false),
            ToolParam(name: "latitude", kind: .number,
                      description: "User or center latitude for search_places", required: false),
            ToolParam(name: "longitude", kind: .number,
                      description: "User or center longitude for search_places", required: false),
            ToolParam(name: "radius_meters", kind: .number,
                      description: "Search radius in meters for search_places (default 1000)", required: false),
            ToolParam(name: "limit", kind: .number,
                      description: "Maximum number of results to return (default 10)", required: false),
            ToolParam(name: "from_address", kind: .string,
                      description: "Starting address for route or ETA (e.g. \"Hangzhou East Station\")", required: false),
            ToolParam(name: "from_latitude", kind: .number,
                      description: "Starting latitude for route or ETA", required: false),
            ToolParam(name: "from_longitude", kind: .number,
                      description: "Starting longitude for route or ETA", required: false),
            ToolParam(name: "to_address", kind: .string,
                      description: "Destination address for route or ETA (e.g. \"West Lake\")", required: false),
            ToolParam(name: "to_latitude", kind: .number,
                      description: "Destination latitude for route or ETA", required: false),
            ToolParam(name: "to_longitude", kind: .number,
                      description: "Destination longitude for route or ETA", required: false),
            ToolParam(name: "mode", kind: .string,
                      description: "Transport mode: \"automobile\" (default), \"walking\", or \"transit\"", required: false),
        ]
    )

    public var schema: ToolSchema { Self.schema }

    public func execute(argumentsJSON: String) async -> String {
        let call = ToolCall(name: "map_kit_tool", argumentsJSON: argumentsJSON)
        guard let action = call.arg("action")?.trimmingCharacters(in: .whitespacesAndNewlines), !action.isEmpty else {
            return "Error: missing 'action' parameter. Supported actions: search_places, get_route, get_eta, open_navigation."
        }

        func extractCoord(_ latKey: String, _ lonKey: String) -> (latitude: Double, longitude: Double)? {
            if let latStr = call.arg(latKey), let lat = Double(latStr),
               let lonStr = call.arg(lonKey), let lon = Double(lonStr) {
                return (lat, lon)
            }
            return nil
        }

        do {
            switch action {
            case "search_places":
                guard let query = call.arg("query")?.trimmingCharacters(in: .whitespacesAndNewlines), !query.isEmpty else {
                    return "Error: parameter 'query' is required for search_places."
                }
                let center = extractCoord("latitude", "longitude")
                let radius = call.arg("radius_meters").flatMap { Double($0) } ?? 1000.0
                let limit = call.arg("limit").flatMap { Int(Double($0) ?? -1) } ?? 10

                let items = try await provider.searchPlaces(query: query, center: center, radiusMeters: radius, limit: max(1, limit))
                guard !items.isEmpty else {
                    return "No places found matching \"\(query)\"."
                }
                let eventSuffix = items.count == 1 ? "" : "s"
                let lines = items.map { item -> String in
                    var desc = "• \(item.name)"
                    if let d = item.distanceMeters { desc += " (\(d)m away)" }
                    if !item.address.isEmpty { desc += " — \(item.address)" }
                    if let p = item.phoneNumber, !p.isEmpty { desc += " [Tel: \(p)]" }
                    return desc
                }
                return "Found \(items.count) place\(eventSuffix) matching \"\(query)\":\n" + lines.joined(separator: "\n")

            case "get_route":
                let fromAddr = call.arg("from_address")
                let fromCoord = extractCoord("from_latitude", "from_longitude")
                let toAddr = call.arg("to_address")
                let toCoord = extractCoord("to_latitude", "to_longitude")
                let mode = call.arg("mode")

                let route = try await provider.calculateRoute(
                    fromAddress: fromAddr,
                    fromCoord: fromCoord,
                    toAddress: toAddr,
                    toCoord: toCoord,
                    mode: mode
                )

                var sections: [String] = []
                sections.append(String(format: "Route: %.1f km, approximately %.0f minutes.", route.distanceKilometers, route.durationMinutes))
                if !route.steps.isEmpty {
                    sections.append("\nDirections:")
                    let stepLines = route.steps.map { s in
                        "• \(s.instruction) (\(s.distanceMeters)m)"
                    }
                    sections.append(stepLines.joined(separator: "\n"))
                }
                return sections.joined(separator: "\n")

            case "get_eta":
                let fromAddr = call.arg("from_address")
                let fromCoord = extractCoord("from_latitude", "from_longitude")
                let toAddr = call.arg("to_address")
                let toCoord = extractCoord("to_latitude", "to_longitude")
                let mode = call.arg("mode")

                let eta = try await provider.calculateEta(
                    fromAddress: fromAddr,
                    fromCoord: fromCoord,
                    toAddress: toAddr,
                    toCoord: toCoord,
                    mode: mode
                )
                let f = DateFormatter()
                f.timeStyle = .short
                f.dateStyle = .none
                let arrivalStr = f.string(from: eta.expectedArrival)
                return String(format: "ETA: %.1f km, ~%.0f minutes (Expected arrival: %@).", eta.distanceKilometers, eta.durationMinutes, arrivalStr)

            case "open_navigation":
                let fromAddr = call.arg("from_address")
                let fromCoord = extractCoord("from_latitude", "from_longitude")
                let toAddr = call.arg("to_address")
                let toCoord = extractCoord("to_latitude", "to_longitude")
                let mode = call.arg("mode")

                guard let url = provider.navigationURL(
                    fromAddress: fromAddr,
                    fromCoord: fromCoord,
                    toAddress: toAddr,
                    toCoord: toCoord,
                    mode: mode
                ) else {
                    return "Error: cannot construct navigation URL."
                }
                return "Navigation URL ready: \(url.absoluteString)"

            default:
                return "Error: unknown action '\(action)'. Supported actions: search_places, get_route, get_eta, open_navigation."
            }
        } catch {
            return "Map operation failed: \(errorText(error))."
        }
    }
}

// MARK: - Helpers

private func errorText(_ error: Error) -> String {
    if case MapKitError.searchFailed(let m) = error { return m }
    if case MapKitError.routeFailed(let m) = error { return m }
    if case MapKitError.etaFailed(let m) = error { return m }
    if case MapKitError.invalidParameters(let m) = error { return m }
    if case LocationError.unavailable(let m) = error { return m }
    return error.localizedDescription.isEmpty ? "\(error)" : error.localizedDescription
}
