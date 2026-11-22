import SwiftUI
import WidgetKit

@main
struct MyYarisWidgetsBundle: WidgetBundle {
    var body: some Widget {
        FuelRangeWidget()
        ParkingLocationWidget()
    }
}
