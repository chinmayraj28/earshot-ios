import EarshotKit
import Observation
import SwiftUI

enum Route: Hashable {
    case chat(ContactID)
    case contact(ContactID)
    case settings
    case howItWorks
    case privacy
    case blocked
}

/// Wraps a request token so it can drive `.sheet(item:)`.
struct PresentedRequest: Identifiable, Equatable {
    let id: PeerToken
}

/// Navigation state, plus the glue that turns connection requests into screens.
@MainActor
@Observable
final class AppRouter {
    var path: [Route] = []
    var presentedRequest: PresentedRequest?
    /// Bumped whenever a new conversation opens, to play a success haptic.
    private(set) var connectionCount = 0
    /// Called when a request turns into a new contact (used to offer notifications).
    @ObservationIgnored var onNewContact: (() -> Void)?

    func openChat(_ id: ContactID) {
        path = [.chat(id)]
    }

    func popToRoot() {
        path.removeAll()
    }

    /// Called whenever `messenger.requests` changes.
    /// - A request that reached `.connected` opens its conversation and is dismissed.
    /// - The oldest pending incoming request is presented if nothing else is on screen.
    func handle(_ requests: [ConnectionRequest], messenger: Messenger) {
        for request in requests {
            guard case .connected(let id) = request.state else { continue }
            if presentedRequest?.id == request.id { presentedRequest = nil }
            messenger.dismiss(request)
            connectionCount += 1
            openChat(id)
            onNewContact?()
        }
        if presentedRequest == nil,
           let next = requests.first(where: { $0.direction == .incoming && $0.state == .pending }) {
            presentedRequest = PresentedRequest(id: next.id)
        }
    }

    /// Called when the person finishes with the request sheet (declined, closed after a failure).
    func finishPresentedRequest(messenger: Messenger) {
        presentedRequest = nil
        // Present the next one, if any is waiting.
        handle(messenger.requests, messenger: messenger)
    }
}
