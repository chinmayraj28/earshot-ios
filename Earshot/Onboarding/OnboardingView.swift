import EarshotKit
import SwiftUI

/// First-run flow: the promise, your name, and how it works. Three steps.
/// The last button turns Earshot on, which is when iOS asks for Bluetooth access.
struct OnboardingView: View {
    var initialStep = 0
    let onFinish: (String) -> Void

    @State private var step = 0
    @State private var name = ""
    @FocusState private var nameFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize

    private let stepCount = 3
    private var cleanName: String { Limits.sanitizedName(name) }
    private var nameIsValid: Bool { !cleanName.isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            ScrollView {
                Group {
                    switch step {
                    case 0: welcome
                    case 1: nameStep
                    default: howItWorks
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 12)
                .padding(.bottom, 24)
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
                .id(step)
                .transition(stepTransition)
                // At the largest text sizes the buttons scroll with the content so the words get the screen.
                if typeSize.isAccessibilitySize { footer }
            }
            .scrollBounceBehavior(.basedOnSize)
            if !typeSize.isAccessibilitySize { footer }
        }
        .screenBackground()
        .onAppear { step = min(max(initialStep, 0), stepCount - 1) }
    }

    private var stepTransition: AnyTransition {
        reduceMotion ? .opacity : .asymmetric(insertion: .opacity.combined(with: .offset(x: 24)),
                                              removal: .opacity.combined(with: .offset(x: -24)))
    }

    private func go(to newStep: Int) {
        withAnimation(.easeInOut(duration: 0.3)) { step = newStep }
        if newStep == 1 {
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(350))
                nameFocused = true
            }
        } else {
            nameFocused = false
        }
    }

    // MARK: Chrome

    private var topBar: some View {
        HStack {
            if step > 0 {
                Button {
                    go(to: step - 1)
                } label: {
                    Label("Back", systemImage: "chevron.backward")
                        .labelStyle(.iconOnly)
                        .font(.body.weight(.semibold))
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("Back")
            }
            Spacer()
            HStack(spacing: 6) {
                ForEach(0..<stepCount, id: \.self) { index in
                    Capsule()
                        .fill(index == step ? Palette.accent : Palette.separator)
                        .frame(width: index == step ? 22 : 8, height: 8)
                }
            }
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
            .accessibilityElement()
            .accessibilityLabel("Step \(step + 1) of \(stepCount)")
            Spacer()
            if step > 0 { Color.clear.frame(width: 44, height: 44) }
        }
        .frame(minHeight: 44)
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .animation(.easeInOut(duration: 0.25), value: step)
    }

    @ViewBuilder private var footer: some View {
        VStack(spacing: 12) {
            if step == 2 {
                permissionNote
                Button("Turn On Earshot") { onFinish(cleanName) }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(!nameIsValid)
                    .accessibilityIdentifier("onboarding.turnOn")
                    .accessibilityHint("Starts looking for people nearby. iOS will ask for Bluetooth access.")
            } else {
                Button(step == 0 ? "Get Started" : "Continue") { go(to: step + 1) }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(step == 1 && !nameIsValid)
                    .accessibilityIdentifier("onboarding.continue")
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 12)
        .padding(.bottom, 16)
        .frame(maxWidth: 560)
        .background(Palette.background.ignoresSafeArea())
    }

    /// Said right before the button that triggers the system prompt.
    private var permissionNote: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "hand.raised.fill")
                .foregroundStyle(Palette.accent)
                .accessibilityHidden(true)
            Text("Next, iOS will ask to let Earshot use Bluetooth. Choose **Allow** — that's how Earshot finds phones nearby. Nothing is sent to the internet.")
                .font(.footnote)
                .foregroundStyle(Palette.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("onboarding.permissionNote")
    }

    // MARK: Steps

    private var welcome: some View {
        VStack(spacing: 28) {
            EarshotRings(animated: true)
                .frame(maxWidth: 220)
                .padding(.top, 24)
            VStack(spacing: 14) {
                Text("Earshot")
                    .font(.display(.largeTitle, weight: .heavy))
                    .foregroundStyle(Palette.ink)
                    .accessibilityAddTraits(.isHeader)
                Text("Reach people nearby when the network is gone.")
                    .font(.display(.title2, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                    .multilineTextAlignment(.center)
                Text("Text the people around you on a stalled train, at a packed festival or deep inside a building — no internet, no mobile signal, no account. Messages are end-to-end encrypted and stay on your phones.")
                    .font(.body)
                    .foregroundStyle(Palette.inkSecondary)
                    .multilineTextAlignment(.center)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var nameStep: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("What should people nearby call you?")
                .font(.display(.title, weight: .bold))
                .foregroundStyle(Palette.ink)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
                .padding(.top, 24)

            VStack(alignment: .leading, spacing: 8) {
                TextField("Your name", text: $name)
                    .font(.title3)
                    .foregroundStyle(Palette.ink)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
                    .submitLabel(.continue)
                    .focused($nameFocused)
                    .padding(.horizontal, 16)
                    .frame(minHeight: 56)
                    .background(Palette.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(nameFocused ? Palette.accent : Palette.separator, lineWidth: nameFocused ? 2 : 1)
                    }
                    .onChange(of: name) { _, newValue in
                        if newValue.count > Limits.maxNameLength {
                            name = String(newValue.prefix(Limits.maxNameLength))
                        }
                    }
                    .onSubmit { if nameIsValid { go(to: 2) } }
                    .accessibilityIdentifier("onboarding.nameField")
                    .accessibilityHint("Up to \(Limits.maxNameLength) characters.")

                HStack(alignment: .firstTextBaseline) {
                    Text("Shown to people near you who use Earshot. A first name or nickname is plenty — you can change it later.")
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 12)
                    Text("\(name.count)/\(Limits.maxNameLength)")
                        .monospacedDigit()
                        .accessibilityLabel("\(name.count) of \(Limits.maxNameLength) characters")
                }
                .font(.footnote)
                .foregroundStyle(Palette.inkSecondary)
            }
        }
    }

    private var howItWorks: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("How Earshot works")
                .font(.display(.title, weight: .bold))
                .foregroundStyle(Palette.ink)
                .accessibilityAddTraits(.isHeader)
                .padding(.top, 24)
            ExplainerRow(systemImage: "antenna.radiowaves.left.and.right",
                         title: "Bluetooth, phone to phone",
                         detail: "No Wi‑Fi, internet or mobile signal. Range is about one room — a few tens of metres in the open, less through walls and bodies.")
            ExplainerRow(systemImage: "lock.iphone",
                         title: "Works in your pocket",
                         detail: "Once you've opened Earshot, a contact nearby can reach you while your phone is locked, and you can get a notification.")
            ExplainerRow(systemImage: "info.circle",
                         title: "Good to know",
                         detail: "The sender needs Earshot open. Two locked phones don't find each other until someone opens Earshot. Swiping it away or restarting your phone stops it until you open it again. In the background, messages can take up to a minute or so.")
        }
    }
}

#Preview("Onboarding") {
    OnboardingView { _ in }
}
