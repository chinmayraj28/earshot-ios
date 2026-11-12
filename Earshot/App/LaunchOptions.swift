import EarshotKit
import Foundation

/// Launch arguments understood by the app.
///
/// - `-demo <populated|firstRun|empty>`: simulated nearby people (previews, screenshots, UI tests).
/// - `-demoRequest`: with `-demo`, a new person sends you a request about 2 s after launch.
/// - `-demoNotificationPrompt`: with `-demo`, the notification explainer is shown after the first
///   new contact connects (demo mode otherwise skips it so it can't get in the way of UI tests).
/// - `-ephemeral`: real radios, nothing saved.
/// - Debug builds only: `-screen <settings|howItWorks|privacy|chat:Name|contact:Name>` opens a
///   screen at launch, and `-onboardingStep <0|1|2>` starts onboarding on a given step.
///   `-simulateBluetoothDenied` shows the "Bluetooth access denied" state, and
///   `-demoLeave <Name>` makes a demo person walk out of range about 6 s after launch.
///   These exist so screenshots of inner screens and states can be taken from the command line.
struct LaunchOptions: Sendable {
    var demoScenario: DemoWorld.Scenario?
    var demoRequest = false
    /// With `-demo`: show the notification explainer after the first new contact connects,
    /// whatever the system permission state is. Without it, demo mode never shows the explainer.
    var demoNotificationPrompt = false
    var isEphemeral = false
    var screen: String?
    var onboardingStep: Int?
    var simulateBluetoothDenied = false
    /// Name of a demo person who walks out of range a few seconds after launch.
    var demoLeaver: String?

    init(arguments: [String] = ProcessInfo.processInfo.arguments) {
        func value(after flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
            let value = arguments[index + 1]
            return value.hasPrefix("-") ? nil : value
        }
        if arguments.contains("-demo") {
            demoScenario = value(after: "-demo").flatMap(DemoWorld.Scenario.init(rawValue:)) ?? .populated
            demoRequest = arguments.contains("-demoRequest")
            demoNotificationPrompt = arguments.contains("-demoNotificationPrompt")
        }
        isEphemeral = arguments.contains("-ephemeral")
        #if DEBUG
        screen = value(after: "-screen")
        onboardingStep = value(after: "-onboardingStep").flatMap(Int.init)
        simulateBluetoothDenied = arguments.contains("-simulateBluetoothDenied")
        demoLeaver = value(after: "-demoLeave")
        #endif
    }
}

/// Builds the one `Messenger` the app uses, according to the launch arguments, and the
/// objects that live as long as the process: navigation and notifications.
///
/// Created in `EarshotApp.init`, which also runs when iOS relaunches Earshot in the
/// background (Bluetooth state restoration) with no screen showing. That is why the
/// messenger is started here and not only from a view.
@MainActor
final class AppEnvironment {
    let messenger: Messenger
    let options: LaunchOptions
    let router = AppRouter()
    let notifications: NotificationManager
    /// Kept alive for the app's lifetime when running in demo mode.
    let demoWorld: DemoWorld?

    init(options: LaunchOptions = LaunchOptions()) {
        self.options = options
        let world: DemoWorld?
        let messenger: Messenger
        #if DEBUG
        if options.simulateBluetoothDenied {
            world = nil
            messenger = DeniedTransport.messenger()
        } else {
            (world, messenger) = Self.make(options)
        }
        #else
        (world, messenger) = Self.make(options)
        #endif
        demoWorld = world
        self.messenger = messenger
        let isDemo = options.demoScenario != nil
        notifications = NotificationManager(remembersOffer: !isDemo,
                                            offer: isDemo ? (options.demoNotificationPrompt ? .always : .never) : .whenUseful)

        let notifications = notifications
        let router = router
        notifications.attach(messenger: messenger, router: router)
        messenger.onEvent = { event in notifications.handle(event) }
        router.onNewContact = { notifications.offerPermissionIfUseful() }

        // Keep listening from process launch onwards. The first `start()` (and so the
        // Bluetooth permission prompt) still waits until onboarding is finished.
        if messenger.profile.hasCompletedOnboarding { messenger.start() }
    }

    private static func make(_ options: LaunchOptions) -> (DemoWorld?, Messenger) {
        if let scenario = options.demoScenario {
            let world = DemoWorld(scenario: scenario)
            return (world, world.messenger)
        }
        return (nil, options.isEphemeral ? .ephemeral() : .live())
    }
}
