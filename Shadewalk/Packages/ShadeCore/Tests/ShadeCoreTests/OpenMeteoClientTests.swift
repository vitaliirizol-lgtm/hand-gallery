import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import ShadeCore

final class OpenMeteoClientTests: XCTestCase {
    private let seoul = GeoCoordinate(latitude: 37.5716, longitude: 126.9769)
    /// Coordinates used to capture `open_meteo_elevation.json`.
    private let elevationCoordinates = [
        GeoCoordinate(latitude: 37.5716, longitude: 126.9769),
        GeoCoordinate(latitude: 37.5512, longitude: 126.9882),
        GeoCoordinate(latitude: 37.5796, longitude: 126.9770),
        GeoCoordinate(latitude: 37.5665, longitude: 126.9780),
        GeoCoordinate(latitude: 37.5121, longitude: 127.1025),
    ]

    private func fixture(_ name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"),
                                "missing fixture \(name).json")
        return try Data(contentsOf: url)
    }

    private func queryItems(_ request: URLRequest?) throws -> [String: String] {
        let url = try XCTUnwrap(request?.url)
        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        var out: [String: String] = [:]
        for item in items { out[item.name] = item.value ?? "" }
        XCTAssertEqual(out.count, items.count, "duplicate query items")
        return out
    }

    private func assertThrows(file: StaticString = #filePath, line: UInt = #line,
                              _ body: () async throws -> Void, _ check: (ShadeError) -> Bool) async {
        do {
            try await body()
            XCTFail("expected an error", file: file, line: line)
        } catch let error as ShadeError {
            XCTAssertTrue(check(error), "unexpected \(error)", file: file, line: line)
        } catch {
            XCTFail("expected ShadeError, got \(error)", file: file, line: line)
        }
    }

    private static func isDecodingFailure(_ error: ShadeError) -> Bool {
        if case .decodingFailed = error { return true }
        return false
    }

    // MARK: Forecast

    func testForecastRequestFormatting() async throws {
        let body = try fixture("open_meteo_forecast")
        let stub = StubHTTPClient { _ in (body, 200) }
        _ = try await OpenMeteoClient(http: stub).forecast(at: seoul)

        XCTAssertEqual(stub.requests.count, 1)
        let request = try XCTUnwrap(stub.requests.first)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertNil(request.httpBody)
        XCTAssertEqual(request.url?.scheme, "https")
        XCTAssertEqual(request.url?.host, "api.open-meteo.com")
        XCTAssertEqual(request.url?.path, "/v1/forecast")
        XCTAssertNotNil(request.value(forHTTPHeaderField: "User-Agent"))
        let fields = "temperature_2m,apparent_temperature,uv_index,cloud_cover,is_day"
        XCTAssertEqual(try queryItems(request), [
            "latitude": "37.571600",
            "longitude": "126.976900",
            "current": fields,
            "hourly": fields,
            "forecast_days": "2",
            "timezone": "GMT",
            "timeformat": "unixtime",
        ])
    }

    func testForecastKeepsQueryItemsOfCustomURL() async throws {
        let body = try fixture("open_meteo_forecast")
        let stub = StubHTTPClient { _ in (body, 200) }
        let custom = try XCTUnwrap(URL(string: "https://customer-api.example/v1/forecast?apikey=abc"))
        _ = try await OpenMeteoClient(http: stub, forecastURL: custom).forecast(at: seoul)
        let items = try queryItems(stub.requests.first)
        XCTAssertEqual(items["apikey"], "abc")
        XCTAssertEqual(items["latitude"], "37.571600")
        XCTAssertEqual(stub.requests.first?.url?.host, "customer-api.example")
    }

    func testForecastDecodesRealFixture() async throws {
        let body = try fixture("open_meteo_forecast")
        let forecast = try await OpenMeteoClient(http: StubHTTPClient { _ in (body, 200) }).forecast(at: seoul)

        // Values captured from the live API for Seoul.
        XCTAssertEqual(forecast.current.time, Date(timeIntervalSince1970: 1_790_964_000))
        XCTAssertEqual(forecast.current.temperature, 11.6, accuracy: 1e-9)
        XCTAssertEqual(forecast.current.apparentTemperature ?? .nan, 10.2, accuracy: 1e-9)
        XCTAssertEqual(forecast.current.uvIndex ?? .nan, 0, accuracy: 1e-9)
        XCTAssertEqual(forecast.current.cloudCover ?? .nan, 22, accuracy: 1e-9)
        XCTAssertFalse(forecast.current.isDay)

        // Hourly series cross-checked field by field against the raw JSON.
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let hourly = try XCTUnwrap(json["hourly"] as? [String: Any])
        let times = try XCTUnwrap(hourly["time"] as? [NSNumber])
        let temps = try XCTUnwrap(hourly["temperature_2m"] as? [Any])
        let apparent = try XCTUnwrap(hourly["apparent_temperature"] as? [Any])
        let uv = try XCTUnwrap(hourly["uv_index"] as? [Any])
        let cloud = try XCTUnwrap(hourly["cloud_cover"] as? [Any])
        let isDay = try XCTUnwrap(hourly["is_day"] as? [Any])
        XCTAssertEqual(times.count, 48)

        let valid = times.indices.filter { temps[$0] is NSNumber }
        XCTAssertEqual(forecast.hourly.count, valid.count)
        XCTAssertEqual(forecast.hourly.first?.time, Date(timeIntervalSince1970: 1_790_899_200))
        XCTAssertEqual(forecast.hourly.map(\.time), forecast.hourly.map(\.time).sorted())
        for (snapshot, i) in zip(forecast.hourly, valid) {
            XCTAssertEqual(snapshot.time.timeIntervalSince1970, times[i].doubleValue)
            XCTAssertEqual(snapshot.temperature, (temps[i] as? NSNumber)?.doubleValue ?? .nan, accuracy: 1e-9)
            XCTAssertEqual(snapshot.apparentTemperature, (apparent[i] as? NSNumber)?.doubleValue)
            XCTAssertEqual(snapshot.uvIndex, (uv[i] as? NSNumber)?.doubleValue)
            XCTAssertEqual(snapshot.cloudCover, (cloud[i] as? NSNumber)?.doubleValue)
            XCTAssertEqual(snapshot.isDay, (isDay[i] as? NSNumber)?.intValue == 1)
        }
        XCTAssertTrue(forecast.hourly.contains { $0.isDay })
        XCTAssertTrue(forecast.hourly.contains { !$0.isDay })
        XCTAssertNotNil(forecast.snapshot(at: forecast.current.time))
    }

    func testForecastSkipsNullHoursAndSortsByTime() async throws {
        let body = """
        {"current":{"time":7200,"interval":900,"temperature_2m":30.5,"apparent_temperature":null,
                    "uv_index":null,"cloud_cover":null,"is_day":1},
         "hourly":{"time":[7200,0,3600,10800],
                   "temperature_2m":[31.0,29.0,null,32.5],
                   "apparent_temperature":[33.0,null,30.0],
                   "uv_index":[5.5,4.0,4.5,6.0],
                   "cloud_cover":[10,20,30,40],
                   "is_day":[1,0,1,1]}}
        """
        let stub = StubHTTPClient { _ in (Data(body.utf8), 200) }
        let forecast = try await OpenMeteoClient(http: stub).forecast(at: seoul)
        XCTAssertEqual(forecast.current.temperature, 30.5)
        XCTAssertNil(forecast.current.apparentTemperature)
        XCTAssertTrue(forecast.current.isDay)
        XCTAssertEqual(forecast.hourly.map(\.time.timeIntervalSince1970), [0, 7200, 10800])
        XCTAssertEqual(forecast.hourly.map(\.temperature), [29.0, 31.0, 32.5])
        XCTAssertEqual(forecast.hourly.map(\.apparentTemperature), [nil, 33.0, nil])  // short array → nil
        XCTAssertEqual(forecast.hourly.map(\.isDay), [false, true, true])
    }

    func testForecastWithoutHourlyBlock() async throws {
        let body = #"{"current":{"time":0,"temperature_2m":20,"uv_index":3}}"#
        let forecast = try await OpenMeteoClient(http: StubHTTPClient { _ in (Data(body.utf8), 200) }).forecast(at: seoul)
        XCTAssertEqual(forecast.hourly, [])
        XCTAssertTrue(forecast.current.isDay, "missing is_day falls back to UV > 0")
    }

    func testForecastErrors() async throws {
        let errorBody = try fixture("open_meteo_error")  // real 400 response for latitude 137.5
        let cases: [(Data, Int, (ShadeError) -> Bool)] = [
            (errorBody, 400, { $0 == .badResponse(status: 400) }),
            (Data("<html>Bad Gateway</html>".utf8), 502, { $0 == .badResponse(status: 502) }),
            (errorBody, 200, { error in
                if case let .decodingFailed(detail) = error { return detail.contains("Latitude must be in range") }
                return false
            }),
            (Data("not json".utf8), 200, Self.isDecodingFailure),
            (Data(), 200, Self.isDecodingFailure),
            (Data(#"{"hourly":{"time":[0],"temperature_2m":[1]}}"#.utf8), 200, Self.isDecodingFailure),
            (Data(#"{"current":{"time":0,"temperature_2m":null}}"#.utf8), 200, Self.isDecodingFailure),
            (Data(#"{"current":{"time":"yesterday","temperature_2m":1}}"#.utf8), 200, Self.isDecodingFailure),
        ]
        for (body, status, check) in cases {
            let client = OpenMeteoClient(http: StubHTTPClient { _ in (body, status) })
            await assertThrows({ _ = try await client.forecast(at: self.seoul) }, check)
        }
    }

    func testTransportErrorsAreNetworkUnavailable() async {
        let client = OpenMeteoClient(http: StubHTTPClient { _ in throw URLError(.notConnectedToInternet) })
        await assertThrows({ _ = try await client.forecast(at: self.seoul) }) { $0 == .networkUnavailable }
        await assertThrows({ _ = try await client.elevations(for: [self.seoul]) }) { $0 == .networkUnavailable }

        let cancelled = OpenMeteoClient(http: StubHTTPClient { _ in throw CancellationError() })
        await assertThrows({ _ = try await cancelled.forecast(at: self.seoul) }) { $0 == .cancelled }
    }

    // MARK: Elevation

    func testElevationDecodesRealFixture() async throws {
        let body = try fixture("open_meteo_elevation")
        let stub = StubHTTPClient { _ in (body, 200) }
        let elevations = try await OpenMeteoClient(http: stub).elevations(for: elevationCoordinates)
        XCTAssertEqual(elevations, [35, 270, 42, 34, 17])

        XCTAssertEqual(stub.requests.count, 1)
        let request = try XCTUnwrap(stub.requests.first)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.host, "api.open-meteo.com")
        XCTAssertEqual(request.url?.path, "/v1/elevation")
        XCTAssertEqual(try queryItems(request), [
            "latitude": "37.571600,37.551200,37.579600,37.566500,37.512100",
            "longitude": "126.976900,126.988200,126.977000,126.978000,127.102500",
        ])
    }

    func testElevationEmptyInputMakesNoRequest() async throws {
        let stub = StubHTTPClient { _ in (Data(), 500) }
        let elevations = try await OpenMeteoClient(http: stub).elevations(for: [])
        XCTAssertEqual(elevations, [])
        XCTAssertTrue(stub.requests.isEmpty)
    }

    /// Echo server: elevation of each coordinate = (latitude − 10) × 1000, i.e. its index in the tests below.
    private static func echoElevation(_ request: URLRequest) throws -> (Data, Int) {
        guard let url = request.url,
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let latitudes = items.first(where: { $0.name == "latitude" })?.value?.split(separator: ",") else {
            return (Data(#"{"error":true,"reason":"bad request"}"#.utf8), 400)
        }
        let values = latitudes.compactMap { Double($0) }.map { (($0 - 10) * 1000).rounded() }
        return (try JSONSerialization.data(withJSONObject: ["elevation": values]), 200)
    }

    private func indexedCoordinates(_ count: Int) -> [GeoCoordinate] {
        (0..<count).map { GeoCoordinate(latitude: 10 + Double($0) / 1000, longitude: 127) }
    }

    func testElevationBatchesOf100PreserveOrder() async throws {
        let stub = StubHTTPClient { try Self.echoElevation($0) }
        let elevations = try await OpenMeteoClient(http: stub).elevations(for: indexedCoordinates(250))
        XCTAssertEqual(elevations, (0..<250).map(Double.init))

        XCTAssertEqual(stub.requests.count, 3)
        let sizes = try stub.requests.map { request -> Int in
            let items = try queryItems(request)
            let lat = try XCTUnwrap(items["latitude"]).split(separator: ",").count
            let lon = try XCTUnwrap(items["longitude"]).split(separator: ",").count
            XCTAssertEqual(lat, lon)
            return lat
        }
        XCTAssertEqual(sizes.sorted(), [50, 100, 100])
    }

    func testElevationExactly100IsOneRequestAnd101IsTwo() async throws {
        let one = StubHTTPClient { try Self.echoElevation($0) }
        let elevations = try await OpenMeteoClient(http: one).elevations(for: indexedCoordinates(100))
        XCTAssertEqual(elevations, (0..<100).map(Double.init))
        XCTAssertEqual(one.requests.count, 1)

        let two = StubHTTPClient { try Self.echoElevation($0) }
        let elevations2 = try await OpenMeteoClient(http: two).elevations(for: indexedCoordinates(101))
        XCTAssertEqual(elevations2, (0..<101).map(Double.init))
        XCTAssertEqual(two.requests.count, 2)
    }

    func testElevationCountMismatchIsDecodingFailure() async {
        let stub = StubHTTPClient { _ in (Data(#"{"elevation":[1.0,2.0]}"#.utf8), 200) }
        let client = OpenMeteoClient(http: stub)
        await assertThrows({ _ = try await client.elevations(for: self.elevationCoordinates) }, Self.isDecodingFailure)
    }

    func testElevationMalformedBodiesAreDecodingFailures() async {
        for body in [#"{"elevation":[1.0,null]}"#, #"{"height":[1.0,2.0]}"#, "[]", "<html>"] {
            let client = OpenMeteoClient(http: StubHTTPClient { _ in (Data(body.utf8), 200) })
            await assertThrows({ _ = try await client.elevations(for: Array(self.elevationCoordinates.prefix(2))) },
                               Self.isDecodingFailure)
        }
    }

    func testElevationFailingBatchFailsWholeCall() async {
        // The batch starting at index 100 fails; the others succeed.
        let stub = StubHTTPClient { request in
            if request.url?.query?.contains("latitude=10.100000") == true {
                return (Data(#"{"error":true,"reason":"Too many requests"}"#.utf8), 429)
            }
            return try Self.echoElevation(request)
        }
        let coordinates = indexedCoordinates(250)
        let client = OpenMeteoClient(http: stub)
        await assertThrows({ _ = try await client.elevations(for: coordinates) }) { $0 == .badResponse(status: 429) }
    }

    func testElevationErrorObjectIsDecodingFailure() async throws {
        let errorBody = try fixture("open_meteo_error")
        let client = OpenMeteoClient(http: StubHTTPClient { _ in (errorBody, 200) })
        await assertThrows({ _ = try await client.elevations(for: [self.seoul]) }, Self.isDecodingFailure)
    }
}
