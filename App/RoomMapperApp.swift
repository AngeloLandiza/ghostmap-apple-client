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
    /// A join link that arrived before the environment finished starting up.
    @State private var pendingURL: URL?

    var body: some View {
        Group {
            if !ARSessionController.isSupported {
                UnsupportedDeviceView()
            } else if let environment {
                MapListView(env: environment)
                    .onOpenURL { environment.handle(url: $0) }
            } else if let startupError {
                ContentUnavailableView("RoomMapper could not start", systemImage: "exclamationmark.triangle", description: Text(startupError))
            } else {
                ProgressView()
                    .onOpenURL { pendingURL = $0 }
                    .task {
                        do {
                            let environment = try AppEnvironment()
                            // A link that arrived while Metal and the map store were coming up.
                            if let pendingURL { environment.handle(url: pendingURL) }
                            pendingURL = nil
                            self.environment = environment
                        } catch {
                            startupError = String(describing: error)
                        }
                    }
            }
        }
    }
}
