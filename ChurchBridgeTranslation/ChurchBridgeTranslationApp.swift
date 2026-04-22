import SwiftUI

@main
struct ChurchBridgeTranslationApp: App {
    @State private var viewModel = TranslationTestViewModel()

    var body: some Scene {
        WindowGroup {
            TranslationTestView(viewModel: viewModel)
                .preferredColorScheme(.dark)
        }
    }
}
