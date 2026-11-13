import Foundation
import Testing
@testable import EarshotKit

@MainActor
@Suite struct DemoPhotoTests {
    @Test func demoContactsReceivePhotosAndElenaRunsAnOlderEarshot() async throws {
        let world = DemoWorld(scenario: .populated, latency: nil)
        let me = world.messenger
        me.start()
        let maya = try #require(me.contacts.first { $0.displayName == "Jensen Huang" })
        let jonas = try #require(me.contacts.first { $0.displayName == "Alice Huang" })
        let stored = try #require(me.messages(for: jonas.id).first { $0.photo != nil }, "the history includes a photo")
        #expect(me.photoSource(for: stored) != nil)
        await waitUntil("Jensen connects") { me.canSendPhoto(to: maya.id) }

        let photo = try #require(DemoWorld.samplePhoto)
        let sent = try #require(me.sendPhoto(photo, to: maya.id))
        await waitUntil("delivered") { me.messages(for: maya.id).first { $0.id == sent.id }?.status == .delivered }
        await waitUntil("Jensen replies", timeout: .seconds(5)) { me.messages(for: maya.id).last?.text.contains("photo") == true }

        let elena = try #require(me.nearbyPeers.first { $0.displayName == "Aubrey Graham" })
        me.connect(to: elena)
        await waitUntil("Aubrey accepts", timeout: .seconds(5)) {
            me.contacts.contains { $0.displayName == "Aubrey Graham" && me.linkState(for: $0.id) == .connected }
        }
        let elenaID = try #require(me.contacts.first { $0.displayName == "Aubrey Graham" }).id
        #expect(!me.canSendPhoto(to: elenaID))
        me.send("Hi Aubrey", to: elenaID)
        #expect(me.messages(for: elenaID).last?.status == .delivered)
    }
}
