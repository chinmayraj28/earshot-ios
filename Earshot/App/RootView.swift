import EarshotKit
import SwiftUI

/// Chooses between onboarding and the main app, keeps the radio on while the app is in
/// the foreground, and presents incoming connection requests over whatever is on screen.
struct RootView: View {
    let options: LaunchOptions
    let demoWorld: DemoWorld?
    let router: AppRouter

    @Environment(Messenger.self) private var messenger
    @Environment(NotificationManager.self) private var notifications
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        @Bindable var router = router
        ZStack {
            if messenger.profile.hasCompletedOnboarding {
                NavigationStack(path: $router.path) {
                    HomeView()
                        .navigationDestination(for: Route.self, destination: destination)
                }
                .transition(.opacity)
            } else {
                OnboardingView(initialStep: options.onboardingStep ?? 0) { name in
                    messenger.completeOnboarding(displayName: name)
                    goOnAir()
                }
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.35), value: messenger.profile.hasCompletedOnboarding)
        .environment(router)
        .tint(Palette.accent)
        .sheet(item: $router.presentedRequest) { presented in
            IncomingRequestSheet(requestID: presented.id)
                .environment(router)
        }
        .sensoryFeedback(.success, trigger: router.connectionCount)
        .onChange(of: messenger.requests) { _, requests in
            router.handle(requests, messenger: messenger)
        }
        .onChange(of: messenger.profile.hasCompletedOnboarding) { _, completed in
            // "Delete everything" returns to onboarding; drop any screens that pointed at old data.
            if !completed {
                router.popToRoot()
                router.presentedRequest = nil
            }
        }
        .onChange(of: scenePhase) { _, phase in
            // Earshot keeps listening in the background (Bluetooth background modes), so there
            // is deliberately no `stop()` here. Coming to the foreground retries a radio that
            // was unavailable and refreshes the notification permission shown in Settings.
            guard phase == .active else { return }
            goOnAir()
            Task { await notifications.refreshPermission() }
        }
        .task {
            goOnAir()
            await runLaunchExtras()
        }
    }

    /// Starts the radios, but only once the person has finished onboarding:
    /// the first `start()` is what makes iOS ask for Bluetooth access.
    /// (`AppEnvironment` also starts it at process launch for returning users.)
    private func goOnAir() {
        guard messenger.profile.hasCompletedOnboarding else { return }
        messenger.start()
    }

    @ViewBuilder
    private func destination(_ route: Route) -> some View {
        switch route {
        case .chat(let id): ChatView(contactID: id)
        case .contact(let id): ContactDetailView(contactID: id)
        case .settings: SettingsView()
        case .howItWorks: HowItWorksView()
        case .privacy: PrivacyView()
        case .blocked: BlockedContactsView()
        }
    }

    private func runLaunchExtras() async {
        #if DEBUG
        if let screen = options.screen {
            // Push after the first frame, the way a tap would, rather than during launch.
            try? await Task.sleep(for: .milliseconds(600))
            open(screen: screen)
        }
        if let leaver = options.demoLeaver, let demoWorld {
            Task {
                try? await Task.sleep(for: .seconds(6))
                demoWorld.setInRange(false, name: leaver)
            }
        }
        #endif
        if options.demoRequest, let demoWorld {
            try? await Task.sleep(for: .seconds(2))
            demoWorld.receiveRequest()
        }
    }

    #if DEBUG
    /// Opens a screen named on the command line (debug builds only, for screenshots).
    private func open(screen: String) {
        func contactID(named name: String) -> ContactID? {
            messenger.contacts.first { $0.displayName == name }?.id
        }
        let parts = screen.split(separator: ":", maxSplits: 1).map(String.init)
        switch (parts.first, parts.count > 1 ? parts[1] : nil) {
        case ("settings", _): router.path = [.settings]
        case ("howItWorks", _): router.path = [.settings, .howItWorks]
        case ("privacy", _): router.path = [.settings, .privacy]
        case ("chat", let name?): if let id = contactID(named: name) { router.path = [.chat(id)] }
        case ("contact", let name?): if let id = contactID(named: name) { router.path = [.chat(id), .contact(id)] }
        default: break
        }
    }
    #endif
}
