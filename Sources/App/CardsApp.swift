import SwiftUI

@main
struct CardsApp: App {
    var body: some Scene {
        WindowGroup {
            HubView()
                // No theme variants: the whole app keeps the dark look
                // regardless of the system light/dark setting.
                .preferredColorScheme(.dark)
        }
    }
}
