import SwiftUI

@main
struct AtelierApp: App {
    @StateObject private var client = AtelierClientModel()

    var body: some Scene {
        WindowGroup("Atelier") {
            ContentView()
                .environmentObject(client)
                .frame(minWidth: 900, minHeight: 600)
                .task { await client.ensureConnected() }
        }
        .defaultSize(width: 1100, height: 720)
    }
}
