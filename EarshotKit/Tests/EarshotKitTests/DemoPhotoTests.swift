import Foundation
import Testing
@testable import EarshotKit

@MainActor
@Suite struct DemoPhotoTests {
    @Test func demoContactsReceivePhotosAndPriyaRunsAnOlderEarshot() async throws {
        let world = DemoWorld(scenario: .populated, latency: nil)
        let me = world.messenger
        me.start()
        let maya = try #require(me.contacts.first { $0.displayName == "Maya Okafor" })
        let jonas = try #require(me.contacts.first { $0.displayName == "Jonas Weber" })
        let stored = try #require(me.messages(for: jonas.id).first { $0.photo != nil }, "the history includes a photo")
        #expect(me.photoSource(for: stored) != nil)
        await waitUntil("Maya connects") { me.canSendPhoto(to: maya.id) }

        let photo = try #require(DemoWorld.samplePhoto)
        let sent = try #require(me.sendPhoto(photo, to: maya.id))
        await waitUntil("delivered") { me.messages(for: maya.id).first { $0.id == sent.id }?.status == .delivered }
        await waitUntil("Maya replies", timeout: .seconds(5)) { me.messages(for: maya.id).last?.text.contains("photo") == true }

        let priya = try #require(me.nearbyPeers.first { $0.displayName == "Priya Raman" })
        me.connect(to: priya)
        await waitUntil("Priya accepts", timeout: .seconds(5)) {
            me.contacts.contains { $0.displayName == "Priya Raman" && me.linkState(for: $0.id) == .connected }
        }
        let priyaID = try #require(me.contacts.first { $0.displayName == "Priya Raman" }).id
        #expect(!me.canSendPhoto(to: priyaID))
        me.send("Hi Priya", to: priyaID)
        #expect(me.messages(for: priyaID).last?.status == .delivered)
    }
}
