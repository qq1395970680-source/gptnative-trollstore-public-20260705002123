import SwiftUI

@main
struct GPTNativeApp: App {
    var body: some Scene {
        WindowGroup {
            ChatGPTLoginView()
                .preferredColorScheme(nil)
        }
    }
}
