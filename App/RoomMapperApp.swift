import SwiftUI

@main
struct RoomMapperApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
                .preferredColorScheme(.dark)
        }
    }
}

struct RootView: View {
    @State private var environment: AppEnvironment?
    @State private var startupError: String?

    var body: some View {
        Group {
            if !ARSessionController.isSupported {
                UnsupportedDeviceView()
            } else if let environment {
                MapListView(env: environment)
            } else if let startupError {
                ContentUnavailableView("RoomMapper could not start", systemImage: "exclamationmark.triangle", description: Text(startupError))
            } else {
                ProgressView()
                    .task {
                        do {
                            environment = try AppEnvironment()
                        } catch {
                            startupError = String(describing: error)
                        }
                    }
            }
        }
    }
}
