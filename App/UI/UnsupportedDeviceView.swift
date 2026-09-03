import SwiftUI

struct UnsupportedDeviceView: View {
    var body: some View {
        ContentUnavailableView {
            Label("LiDAR required", systemImage: "camera.metering.unknown")
        } description: {
            Text("RoomMapper needs ARKit scene depth, which is only available on iPhone and iPad models with a LiDAR scanner (iPhone 12 Pro and later Pro models).")
        }
        .padding()
    }
}
