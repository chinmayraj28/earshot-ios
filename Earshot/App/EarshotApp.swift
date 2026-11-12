import EarshotKit
import SwiftUI
import UIKit

@main
struct EarshotApp: App {
    @State private var environment: AppEnvironment

    init() {
        // Built here, at process launch: iOS may relaunch Earshot in the background with no
        // scene, and the messenger must be listening (and able to notify) even then.
        _environment = State(initialValue: AppEnvironment())
        Self.configureNavigationBarFonts()
    }

    var body: some Scene {
        WindowGroup {
            RootView(options: environment.options, demoWorld: environment.demoWorld, router: environment.router)
                .environment(environment.messenger)
                .environment(environment.notifications)
                .environment(environment.rangeLog)
        }
    }

    /// Rounded type for navigation titles, so headings share the display face.
    private static func configureNavigationBarFonts() {
        func rounded(_ style: UIFont.TextStyle, weight: UIFont.Weight) -> UIFont {
            // Start from the default ("Large") size and let UIFontMetrics apply the person's text size once.
            let base = UIFont.preferredFont(forTextStyle: style,
                                            compatibleWith: UITraitCollection(preferredContentSizeCategory: .large))
            let weighted = UIFont.systemFont(ofSize: base.pointSize, weight: weight)
            guard let descriptor = weighted.fontDescriptor.withDesign(.rounded) else { return weighted }
            return UIFontMetrics(forTextStyle: style).scaledFont(for: UIFont(descriptor: descriptor, size: base.pointSize))
        }
        let bar = UINavigationBar.appearance()
        bar.largeTitleTextAttributes = [.font: rounded(.largeTitle, weight: .bold)]
        bar.titleTextAttributes = [.font: rounded(.headline, weight: .semibold)]
    }
}
