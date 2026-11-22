import SwiftUI
import WidgetKit

struct FuelRangeEntry: TimelineEntry {
    let date: Date
    let state: VehicleStateResponse?
}

struct FuelRangeProvider: TimelineProvider {
    func placeholder(in context: Context) -> FuelRangeEntry {
        FuelRangeEntry(date: Date(), state: .preview)
    }

    func getSnapshot(in context: Context, completion: @escaping (FuelRangeEntry) -> Void) {
        if context.isPreview {
            completion(FuelRangeEntry(date: Date(), state: .preview))
            return
        }
        Task {
            let state = await VehicleStateClient.fetchState()
            completion(FuelRangeEntry(date: Date(), state: state))
        }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<FuelRangeEntry>) -> Void) {
        Task {
            let state = await VehicleStateClient.fetchState()
            let now = Date()
            let entry = FuelRangeEntry(date: now, state: state)
            let nextRefresh = Calendar.current.date(byAdding: .minute, value: 15, to: now) ?? now.addingTimeInterval(900)
            completion(Timeline(entries: [entry], policy: .after(nextRefresh)))
        }
    }
}

private enum YarisPalette {
    static let canvas = Color(red: 0.980, green: 0.976, blue: 0.957)
    static let paper = Color.white
    static let line = Color(red: 0.910, green: 0.902, blue: 0.875)
    static let red = Color(red: 0.659, green: 0.184, blue: 0.212)
    static let blue = Color(red: 0.208, green: 0.282, blue: 0.910)
    static let ink = Color(red: 0.094, green: 0.106, blue: 0.141)
    static let muted = Color(red: 0.431, green: 0.451, blue: 0.510)
    static let green = Color(red: 0.118, green: 0.557, blue: 0.353)
}

struct FuelRangeWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: FuelRangeEntry

    private var tankLiters: Double {
        entry.state?.tankCapacityLiters ?? 36.0
    }

    private var fuelPercent: Double? {
        if let pct = entry.state?.fuelLevelPercent { return min(max(pct, 0), 100) }
        if let liters = entry.state?.fuelLevelLiters {
            return min(max((liters / tankLiters) * 100.0, 0), 100)
        }
        return nil
    }

    private var rangeText: String {
        if let km = entry.state?.estimatedRangeKm {
            return "\(Int(km.rounded()))"
        }
        return "--"
    }

    private var fuelLitersText: String {
        if let liters = entry.state?.fuelLevelLiters {
            return String(format: "%.1f L", liters)
        }
        return "-- L"
    }

    private var fuelPctText: String {
        if let pct = fuelPercent {
            return "\(Int(pct.rounded()))%"
        }
        return "待 OBD"
    }

    var body: some View {
        Group {
            if family == .systemSmall {
                smallBody
            } else {
                mediumBody
            }
        }
        .containerBackground(YarisPalette.canvas, for: .widget)
    }

    private var headerBadge: some View {
        HStack(spacing: 6) {
            Text("YARIS")
                .font(.system(size: 10, weight: .heavy, design: .rounded))
                .foregroundColor(.white)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(YarisPalette.red)
                .clipShape(Capsule())
            Spacer(minLength: 4)
            HStack(spacing: 4) {
                Circle()
                    .fill((entry.state?.online ?? false) ? YarisPalette.green : YarisPalette.muted)
                    .frame(width: 6, height: 6)
                Text((entry.state?.online ?? false) ? "在线" : "驻车")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundColor(YarisPalette.muted)
            }
        }
    }

    private var fuelBar: some View {
        GeometryReader { geo in
            let ratio = CGFloat((fuelPercent ?? 0) / 100.0)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(YarisPalette.line)
                    .frame(height: 8)
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: (fuelPercent ?? 100) < 20
                                ? [YarisPalette.red, Color.orange]
                                : [YarisPalette.blue, YarisPalette.red],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: max(ratio > 0 ? 10 : 0, geo.size.width * ratio), height: 8)
            }
        }
        .frame(height: 8)
    }

    private var smallBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerBadge
            Spacer(minLength: 8)
            Text("剩余续航")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(YarisPalette.muted)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(rangeText)
                    .font(.system(size: 32, weight: .heavy, design: .rounded))
                    .foregroundColor(YarisPalette.ink)
                    .minimumScaleFactor(0.7)
                    .lineLimit(1)
                Text("km")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(YarisPalette.muted)
            }
            Spacer(minLength: 8)
            fuelBar
            Spacer(minLength: 6)
            HStack {
                Text(fuelLitersText)
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundColor(YarisPalette.ink)
                Spacer()
                Text(fuelPctText)
                    .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                    .foregroundColor(YarisPalette.red)
            }
        }
        .padding(14)
    }

    private var mediumBody: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 0) {
                headerBadge
                Spacer(minLength: 8)
                Text("预估剩余续航")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundColor(YarisPalette.muted)
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(rangeText)
                        .font(.system(size: 36, weight: .heavy, design: .rounded))
                        .foregroundColor(YarisPalette.ink)
                        .minimumScaleFactor(0.7)
                        .lineLimit(1)
                    Text("km")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(YarisPalette.muted)
                }
                Spacer(minLength: 8)
                fuelBar
                Spacer(minLength: 6)
                HStack {
                    Text("油量 \(fuelLitersText) / \(Int(tankLiters))L")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundColor(YarisPalette.ink)
                    Spacer()
                    Text(fuelPctText)
                        .font(.system(size: 11.5, weight: .bold))
                        .foregroundColor(YarisPalette.red)
                }
            }
            .frame(maxWidth: .infinity)

            VStack(spacing: 8) {
                metricTile(
                    title: "混动电池",
                    value: entry.state?.batterySoc.map { "\(Int($0.rounded()))%" } ?? "--",
                    tint: YarisPalette.green
                )
                metricTile(
                    title: "12V 蓄电池",
                    value: entry.state?.aux12vVoltage.map { String(format: "%.1fV", $0) } ?? "--",
                    tint: YarisPalette.blue
                )
                metricTile(
                    title: "总里程",
                    value: entry.state?.totalOdometerKm.map { "\(Int($0.rounded())) km" } ?? "--",
                    tint: YarisPalette.ink
                )
            }
            .frame(width: 116)
        }
        .padding(14)
    }

    private func metricTile(title: String, value: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(YarisPalette.muted)
            Text(value)
                .font(.system(size: 13.5, weight: .bold, design: .rounded))
                .foregroundColor(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(YarisPalette.paper)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(YarisPalette.line, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

struct FuelRangeWidget: Widget {
    let kind = "MyYarisFuelRangeWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: FuelRangeProvider()) { entry in
            FuelRangeWidgetView(entry: entry)
        }
        .configurationDisplayName("Yaris 油量与续航")
        .description("实时查看剩余油量、预估续航、混动电池与 12V 电压")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
