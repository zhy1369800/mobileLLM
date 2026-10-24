// SPDX-License-Identifier: MIT

import XCTest
@testable import LLMCore

final class LocationToolTests: XCTestCase {

    // MARK: - LocationInfoTool (current)

    func testLocationInfoToolCurrentWithFullPlacemark() async {
        let placemark = PlacemarkInfo(
            name: "Apple Park",
            country: "United States",
            administrativeArea: "California",
            locality: "Cupertino",
            subLocality: "Monta Vista",
            thoroughfare: "Infinite Loop",
            subThoroughfare: "1",
            postalCode: "95014",
            formattedAddress: "1 Infinite Loop, Cupertino, CA 95014"
        )
        let fix = LocationFix(
            latitude: 37.33182,
            longitude: -122.03118,
            accuracy: 5,
            placemark: placemark
        )
        let tool = LocationInfoTool(provider: FakeLocationProvider(result: .success(fix)))
        let out = await tool.execute(argumentsJSON: #"{"action":"current"}"#)

        XCTAssertTrue(out.contains("37.33182"))
        XCTAssertTrue(out.contains("-122.03118"))
        XCTAssertTrue(out.contains("1 Infinite Loop, Cupertino, CA 95014"))
        XCTAssertTrue(out.contains("Cupertino"))
    }

    func testLocationInfoToolCurrentDefaultAction() async {
        let fix = LocationFix(latitude: 30.25, longitude: 120.15, accuracy: 10, locality: "Hangzhou")
        let tool = LocationInfoTool(provider: FakeLocationProvider(result: .success(fix)))
        let out = await tool.execute(argumentsJSON: "{}")

        XCTAssertTrue(out.contains("30.25000, 120.15000"))
        XCTAssertTrue(out.contains("Hangzhou"))
    }

    func testLocationInfoToolCurrentDenied() async {
        let tool = LocationInfoTool(provider: FakeLocationProvider(result: .failure(.denied)))
        let out = await tool.execute(argumentsJSON: #"{"action":"current"}"#)
        XCTAssertTrue(out.contains("Location access is off"), out)
    }

    func testLocationInfoToolCurrentTimeout() async {
        let tool = LocationInfoTool(provider: FakeLocationProvider(result: .failure(.timeout)))
        let out = await tool.execute(argumentsJSON: "{}")
        XCTAssertTrue(out.contains("try again"), out)
    }

    // MARK: - LocationInfoTool (search / forward geocoding)

    func testLocationInfoToolSearchSuccess() async {
        let coords = [
            GeocodedCoordinate(latitude: 30.243, longitude: 120.142, displayName: "West Lake, Hangzhou")
        ]
        var provider = FakeLocationProvider(result: .failure(.denied))
        provider.geocodeResults = coords
        let tool = LocationInfoTool(provider: provider)
        let out = await tool.execute(argumentsJSON: #"{"action":"search","address":"West Lake"}"#)

        XCTAssertTrue(out.contains("Coordinates for \"West Lake\":"), out)
        XCTAssertTrue(out.contains("30.24300, 120.14200"))
        XCTAssertTrue(out.contains("West Lake, Hangzhou"))
    }

    func testLocationInfoToolSearchMissingAddress() async {
        let tool = LocationInfoTool(provider: FakeLocationProvider(result: .failure(.denied)))
        let out = await tool.execute(argumentsJSON: #"{"action":"search"}"#)
        XCTAssertTrue(out.contains("parameter 'address' is required"), out)
    }

    func testLocationInfoToolSearchNoResults() async {
        var provider = FakeLocationProvider(result: .failure(.denied))
        provider.geocodeResults = []
        let tool = LocationInfoTool(provider: provider)
        let out = await tool.execute(argumentsJSON: #"{"action":"search","address":"Nonexistent Place"}"#)
        XCTAssertTrue(out.contains("No GPS coordinates found"), out)
    }

    // MARK: - MapKitTool

    func testMapKitToolSearchPlaces() async {
        let places = [
            MapPlaceItem(
                name: "Starbucks",
                phoneNumber: "123-456",
                url: "https://starbucks.com",
                latitude: 37.33,
                longitude: -122.03,
                address: "Cupertino Main St",
                distanceMeters: 250
            )
        ]
        let fakeMapKit = FakeMapKitProvider(placesToReturn: places)
        let tool = MapKitTool(provider: fakeMapKit)
        let out = await tool.execute(argumentsJSON: #"{"action":"search_places","query":"coffee"}"#)

        XCTAssertTrue(out.contains("Found 1 place matching \"coffee\":"), out)
        XCTAssertTrue(out.contains("Starbucks"))
        XCTAssertTrue(out.contains("250m away"))
        XCTAssertTrue(out.contains("Cupertino Main St"))
        XCTAssertTrue(out.contains("Tel: 123-456"))
    }

    func testMapKitToolGetRoute() async {
        let steps = [
            RouteStepInfo(instruction: "Turn right onto Apple Park Way", distanceMeters: 400),
            RouteStepInfo(instruction: "Arrive at destination", distanceMeters: 50)
        ]
        let route = RouteInfo(distanceKilometers: 5.2, durationMinutes: 12, steps: steps)
        let fakeMapKit = FakeMapKitProvider(routeToReturn: route)
        let tool = MapKitTool(provider: fakeMapKit)
        let out = await tool.execute(argumentsJSON: #"{"action":"get_route","from_address":"A","to_address":"B"}"#)

        XCTAssertTrue(out.contains("Route: 5.2 km, approximately 12 minutes."), out)
        XCTAssertTrue(out.contains("Turn right onto Apple Park Way (400m)"))
    }

    func testMapKitToolGetEta() async {
        let arrival = Date(timeIntervalSince1970: 1_800_000_000)
        let eta = EtaInfo(distanceKilometers: 10.5, durationMinutes: 20, expectedArrival: arrival)
        let fakeMapKit = FakeMapKitProvider(etaToReturn: eta)
        let tool = MapKitTool(provider: fakeMapKit)
        let out = await tool.execute(argumentsJSON: #"{"action":"get_eta","from_address":"A","to_address":"B"}"#)

        XCTAssertTrue(out.contains("ETA: 10.5 km, ~20 minutes"), out)
    }

    func testMapKitToolOpenNavigation() async {
        let fakeMapKit = FakeMapKitProvider()
        let tool = MapKitTool(provider: fakeMapKit)
        let out = await tool.execute(argumentsJSON: #"{"action":"open_navigation","to_address":"West Lake","mode":"walking"}"#)

        XCTAssertTrue(out.contains("Navigation URL ready:"), out)
        XCTAssertTrue(out.contains("http://maps.apple.com/"))
        XCTAssertTrue(out.contains("dirflg=w"))
    }

    func testMapKitToolMissingAction() async {
        let tool = MapKitTool(provider: FakeMapKitProvider())
        let out = await tool.execute(argumentsJSON: "{}")
        XCTAssertTrue(out.contains("missing 'action' parameter"), out)
    }
}
