import CoreLocation
import Foundation
import MapKit
import UIKit

struct ParkingInfo: Codable {
    let latitude: Double?
    let longitude: Double?
    let address: String?
    let parkedAt: String?

    enum CodingKeys: String, CodingKey {
        case latitude
        case longitude
        case address
        case parkedAt = "parked_at"
    }
}

struct VehicleStateResponse: Codable {
    let deviceId: String
    let online: Bool
    let tankCapacityLiters: Double?
    let fuelLevelLiters: Double?
    let fuelLevelPercent: Double?
    let estimatedRangeKm: Double?
    let totalOdometerKm: Double?
    let batterySoc: Double?
    let aux12vVoltage: Double?
    let coolantTemp: Double?
    let ambientAirTemp: Double?
    let parking: ParkingInfo?
    let obdUpdatedAt: String?
    let updatedAt: String?

    enum CodingKeys: String, CodingKey {
        case deviceId = "device_id"
        case online
        case tankCapacityLiters = "tank_capacity_liters"
        case fuelLevelLiters = "fuel_level_liters"
        case fuelLevelPercent = "fuel_level_percent"
        case estimatedRangeKm = "estimated_range_km"
        case totalOdometerKm = "total_odometer_km"
        case batterySoc = "battery_soc"
        case aux12vVoltage = "aux_12v_voltage"
        case coolantTemp = "coolant_temp"
        case ambientAirTemp = "ambient_air_temp"
        case parking
        case obdUpdatedAt = "obd_updated_at"
        case updatedAt = "updated_at"
    }

    static let preview = VehicleStateResponse(
        deviceId: "car_p3pro",
        online: true,
        tankCapacityLiters: 36.0,
        fuelLevelLiters: 24.5,
        fuelLevelPercent: 68.1,
        estimatedRangeKm: 551.0,
        totalOdometerKm: 18420.0,
        batterySoc: 62.0,
        aux12vVoltage: 12.6,
        coolantTemp: 82.0,
        ambientAirTemp: 19.0,
        parking: ParkingInfo(
            latitude: 34.4026,
            longitude: 132.7131,
            address: "西条中央 停车场",
            parkedAt: ISO8601DateFormatter().string(from: Date())
        ),
        obdUpdatedAt: ISO8601DateFormatter().string(from: Date()),
        updatedAt: ISO8601DateFormatter().string(from: Date())
    )
}

enum VehicleStateClient {
    static var backendBaseUrl: String {
        let raw = (Bundle.main.object(forInfoDictionaryKey: "MYYARIS_BACKEND_URL") as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return raw.hasSuffix("/") ? String(raw.dropLast()) : raw
    }

    static var apiToken: String {
        (Bundle.main.object(forInfoDictionaryKey: "MYYARIS_API_TOKEN") as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func fetchState(deviceId: String = "car_p3pro") async -> VehicleStateResponse? {
        guard !backendBaseUrl.isEmpty,
              !apiToken.isEmpty,
              let url = URL(string: "\(backendBaseUrl)/api/v1/vehicle/state?device_id=\(deviceId)")
        else {
            return nil
        }

        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        req.httpMethod = "GET"
        req.setValue("Bearer \(apiToken)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
                return nil
            }
            return try JSONDecoder().decode(VehicleStateResponse.self, from: data)
        } catch {
            return nil
        }
    }

    static func parseIsoDate(_ raw: String?) -> Date? {
        guard let raw = raw, !raw.isEmpty else { return nil }
        let f1 = ISO8601DateFormatter()
        f1.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f1.date(from: raw) { return d }
        let f2 = ISO8601DateFormatter()
        f2.formatOptions = [.withInternetDateTime]
        return f2.date(from: raw)
    }

    static func formatRelativeTime(_ raw: String?) -> String {
        guard let date = parseIsoDate(raw) else { return "暂无记录" }
        let sec = Int(Date().timeIntervalSince(date))
        if sec < 60 { return "刚刚" }
        if sec < 3600 { return "\(sec / 60) 分钟前" }
        let df = DateFormatter()
        df.dateFormat = Calendar.current.isDateInToday(date) ? "今日 HH:mm" : "MM/dd HH:mm"
        return df.string(from: date)
    }

    static func reverseGeocode(lat: Double, lon: Double, fallback: String?) async -> String {
        if let fb = fallback?.trimmingCharacters(in: .whitespacesAndNewlines), !fb.isEmpty {
            return fb
        }
        let geocoder = CLGeocoder()
        let location = CLLocation(latitude: lat, longitude: lon)
        do {
            let placemarks = try await geocoder.reverseGeocodeLocation(location)
            if let pm = placemarks.first {
                let parts = [pm.name, pm.thoroughfare, pm.subLocality, pm.locality]
                    .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                var dedup: [String] = []
                for p in parts where !dedup.contains(p) {
                    dedup.append(p)
                }
                if !dedup.isEmpty {
                    return dedup.prefix(2).joined(separator: " · ")
                }
            }
        } catch {}
        return String(format: "%.4f, %.4f", lat, lon)
    }

    static func renderParkingMapSnapshot(lat: Double, lon: Double, size: CGSize) async -> UIImage? {
        let coord = CLLocationCoordinate2D(latitude: lat, longitude: lon)
        let options = MKMapSnapshotter.Options()
        options.region = MKCoordinateRegion(
            center: coord,
            latitudinalMeters: 420,
            longitudinalMeters: 420
        )
        options.size = size
        options.scale = 2.0
        options.mapType = .standard
        options.showsBuildings = true
        options.traitCollection = UITraitCollection(userInterfaceStyle: .light)

        let snapshotter = MKMapSnapshotter(options: options)
        do {
            let snapshot = try await snapshotter.start()
            let point = snapshot.point(for: coord)
            let renderer = UIGraphicsImageRenderer(size: options.size)
            return renderer.image { ctx in
                snapshot.image.draw(at: .zero)

                // Subtle crimson halo
                let haloRect = CGRect(x: point.x - 18, y: point.y - 18, width: 36, height: 36)
                ctx.cgContext.setFillColor(UIColor(red: 0.659, green: 0.184, blue: 0.212, alpha: 0.22).cgColor)
                ctx.cgContext.fillEllipse(in: haloRect)

                // White border ring
                let outerRect = CGRect(x: point.x - 10, y: point.y - 10, width: 20, height: 20)
                ctx.cgContext.setFillColor(UIColor.white.cgColor)
                ctx.cgContext.fillEllipse(in: outerRect)

                // Crimson core pin
                let innerRect = CGRect(x: point.x - 7, y: point.y - 7, width: 14, height: 14)
                ctx.cgContext.setFillColor(UIColor(red: 0.659, green: 0.184, blue: 0.212, alpha: 1.0).cgColor)
                ctx.cgContext.fillEllipse(in: innerRect)
            }
        } catch {
            return nil
        }
    }
}
