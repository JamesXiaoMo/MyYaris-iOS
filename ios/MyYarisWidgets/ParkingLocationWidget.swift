import SwiftUI
import UIKit
import WidgetKit

struct ParkingLocationEntry: TimelineEntry {
    let date: Date
    let latitude: Double?
    let longitude: Double?
    let placeName: String
    let timeText: String
    let online: Bool
    let mapImage: UIImage?
}

struct ParkingLocationProvider: TimelineProvider {
    func placeholder(in context: Context) -> ParkingLocationEntry {
        ParkingLocationEntry(
            date: Date(),
            latitude: 34.4026,
            longitude: 132.7131,
            placeName: "西条中央 停车场",
            timeText: "刚刚",
            online: false,
            mapImage: nil
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (ParkingLocationEntry) -> Void) {
        if context.isPreview {
            completion(placeholder(in: context))
            return
        }
        Task {
            let entry = await loadEntry(size: context.displaySize)
            completion(entry)
        }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<ParkingLocationEntry>) -> Void) {
        Task {
            let entry = await loadEntry(size: context.displaySize)
            let nextRefresh = Calendar.current.date(byAdding: .minute, value: 15, to: Date()) ?? Date().addingTimeInterval(900)
            completion(Timeline(entries: [entry], policy: .after(nextRefresh)))
        }
    }

    private func loadEntry(size: CGSize) async -> ParkingLocationEntry {
        let state = await VehicleStateClient.fetchState()
        guard let parking = state?.parking,
              let lat = parking.latitude,
              let lon = parking.longitude
        else {
            return ParkingLocationEntry(
                date: Date(),
                latitude: nil,
                longitude: nil,
                placeName: "暂无停车位置",
                timeText: "等待车机上报",
                online: state?.online ?? false,
                mapImage: nil
            )
        }

        let targetSize = CGSize(
            width: max(size.width, 160),
            height: max(size.height, 160)
        )
        async let mapImg = VehicleStateClient.renderParkingMapSnapshot(lat: lat, lon: lon, size: targetSize)
        async let place = VehicleStateClient.reverseGeocode(lat: lat, lon: lon, fallback: parking.address)

        return ParkingLocationEntry(
            date: Date(),
            latitude: lat,
            longitude: lon,
            placeName: await place,
            timeText: VehicleStateClient.formatRelativeTime(parking.parkedAt),
            online: state?.online ?? false,
            mapImage: await mapImg
        )
    }
}

struct ParkingLocationWidgetView: View {
    let entry: ParkingLocationEntry

    private var mapsUrl: URL? {
        guard let lat = entry.latitude, let lon = entry.longitude else { return nil }
        return URL(string: "http://maps.apple.com/?daddr=\(lat),\(lon)&dirflg=w")
    }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            if let img = entry.mapImage {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
            } else {
                Color(red: 0.949, green: 0.957, blue: 0.976)
                    .overlay(
                        Image(systemName: "car.fill")
                            .font(.system(size: 32))
                            .foregroundColor(Color(red: 0.659, green: 0.184, blue: 0.212).opacity(0.35))
                    )
            }

            // Top-left Yaris badge
            VStack {
                HStack {
                    HStack(spacing: 4) {
                        Image(systemName: "parkingsign.circle.fill")
                            .font(.system(size: 11, weight: .bold))
                        Text("YARIS 停车位置")
                            .font(.system(size: 10.5, weight: .bold))
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color(red: 0.659, green: 0.184, blue: 0.212).opacity(0.92))
                    .clipShape(Capsule())
                    Spacer()
                }
                Spacer()
            }
            .padding(10)

            // Bottom floating info card
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.placeName)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(Color(red: 0.094, green: 0.106, blue: 0.141))
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Text(entry.timeText)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundColor(Color(red: 0.431, green: 0.451, blue: 0.510))
                    Spacer(minLength: 4)
                    if mapsUrl != nil {
                        Text("轻点寻车 ↗")
                            .font(.system(size: 10.5, weight: .bold))
                            .foregroundColor(Color(red: 0.208, green: 0.282, blue: 0.910))
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .padding(8)
        }
        .widgetURL(mapsUrl)
        .containerBackground(for: .widget) {
            Color(red: 0.980, green: 0.976, blue: 0.957)
        }
    }
}

struct ParkingLocationWidget: Widget {
    let kind = "MyYarisParkingLocationWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: ParkingLocationProvider()) { entry in
            ParkingLocationWidgetView(entry: entry)
        }
        .configurationDisplayName("Yaris 停车位置")
        .description("在浅色苹果地图上显示车辆最后停车点，轻点一键步行寻车")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
