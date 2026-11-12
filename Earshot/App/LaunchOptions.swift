import EarshotKit
import Foundation

/// Launch arguments understood by the app.
///
/// - `-demo <populated|firstRun|empty>`: simulated nearby people (previews, screenshots, UI tests).
/// - `-demoRequest`: with `-demo`, a new person sends you a request about 2 s after launch.
/// - `-demoNotificationPrompt`: with `-demo`, the notification explainer is shown after the first
///   new contact connects (demo mode otherwise skips it so it can't get in the way of UI tests).
/// - `-demoRelay <sealed,delivered,carrying>`: with `-demo populated`, puts relaying into demo
///   states: Jonas's waiting message sealed with friends (`-demoRelayHandoffs N`, default 2), his
///   last message delivered through friends with a reply that came the same way, and this phone
///   carrying sealed messages for friends. Any combination, comma-separated.
/// - `-ephemeral`: real radios, nothing saved.
/// - Debug builds only: `-screen <settings|howItWorks|privacy|rangeTest|chat:Name|contact:Name>` opens a
///   screen at launch, and `-onboardingStep <0|1|2>` starts onboarding on a given step.
///   `-simulateBluetoothDenied` shows the "Bluetooth access denied" state, and
///   `-demoLeave <Name>` makes a demo person walk out of range about 6 s after launch.
///   These exist so screenshots of inner screens and states can be taken from the command line.
///   `-useSamplePhoto` makes the photo button attach a built-in picture instead of opening the
///   system photo picker (which UI tests cannot drive reliably).
struct LaunchOptions: Sendable {
    var demoScenario: DemoWorld.Scenario?
    var demoRequest = false
    /// With `-demo`: show the notification explainer after the first new contact connects,
    /// whatever the system permission state is. Without it, demo mode never shows the explainer.
    var demoNotificationPrompt = false
    var demoRelay = DemoWorld.RelayDemo()
    var isEphemeral = false
    var screen: String?
    var onboardingStep: Int?
    var simulateBluetoothDenied = false
    /// Name of a demo person who walks out of range a few seconds after launch.
    var demoLeaver: String?
    /// Debug builds: the photo button uses `DemoWorld.samplePhoto` instead of the system picker.
    var useSamplePhoto = false

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
            let relayStates = Set((value(after: "-demoRelay") ?? "").split(separator: ",").map(String.init))
            if relayStates.contains("sealed") {
                demoRelay.sealedHandoffs = value(after: "-demoRelayHandoffs").flatMap(Int.init) ?? 2
            }
            demoRelay.deliveredViaFriends = relayStates.contains("delivered")
            demoRelay.carrying = relayStates.contains("carrying")
        }
        isEphemeral = arguments.contains("-ephemeral")
        #if DEBUG
        screen = value(after: "-screen")
        onboardingStep = value(after: "-onboardingStep").flatMap(Int.init)
        simulateBluetoothDenied = arguments.contains("-simulateBluetoothDenied")
        demoLeaver = value(after: "-demoLeave")
        useSamplePhoto = arguments.contains("-useSamplePhoto")
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
    /// Bluetooth link events for Settings › Range test.
    let rangeLog: RangeLog
    /// Kept alive for the app's lifetime when running in demo mode.
    let demoWorld: DemoWorld?

    init(options: LaunchOptions = LaunchOptions()) {
        self.options = options
        let world: DemoWorld?
        let messenger: Messenger
        let transport: Transport?
        #if DEBUG
        if options.simulateBluetoothDenied {
            (world, transport) = (nil, nil)
            messenger = DeniedTransport.messenger()
        } else {
            (world, messenger, transport) = Self.make(options)
        }
        #else
        (world, messenger, transport) = Self.make(options)
        #endif
        rangeLog = RangeLog(transport: transport, demo: options.demoScenario != nil)
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

    private static func make(_ options: LaunchOptions) -> (DemoWorld?, Messenger, Transport?) {
        if let scenario = options.demoScenario {
            let world = DemoWorld(scenario: scenario, relay: options.demoRelay)
            return (world, world.messenger, nil)
        }
        let transport = Radio.standard.makeTransport()
        return (nil, options.isEphemeral ? .ephemeral(transport: transport) : .live(transport: transport), transport)
    }
}
