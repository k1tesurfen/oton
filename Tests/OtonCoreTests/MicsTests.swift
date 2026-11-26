import Testing
@testable import OtonCore

@Suite struct MicsTests {
    let builtIn = Mic(name: "MacBook Pro Microphone", uid: "b", kind: .builtIn)
    let samson = Mic(name: "USB Microphone", uid: "s", kind: .usb)
    let webcam = Mic(name: "HD Web Camera", uid: "w", kind: .usb)
    let bose = Mic(name: "Bose QC Ultra", uid: "bt", kind: .bluetooth)
    let teams = Mic(name: "Microsoft Teams Audio", uid: "v", kind: .virtual)

    @Test func preferredWins() {
        let all = [builtIn, samson, webcam, bose]
        #expect(pickMic(all, preferred: ["HD Web Camera", "USB Microphone"], lidClosed: false) == webcam)
        #expect(pickMic(all, preferred: ["usb microphone"], lidClosed: false) == samson)   // case-insensitive
        #expect(pickMic(all, preferred: ["Bose QC Ultra"], lidClosed: false) == bose)      // explicit choice of Bluetooth
    }

    @Test func fallsBackThroughHistoryThenUSBThenBuiltIn() {
        #expect(pickMic([builtIn, webcam], preferred: ["USB Microphone", "HD Web Camera"], lidClosed: false) == webcam)
        #expect(pickMic([builtIn, webcam], preferred: ["Gone"], lidClosed: false) == webcam)
        #expect(pickMic([builtIn, bose, teams], preferred: [], lidClosed: false) == builtIn)
    }

    @Test func neverBuiltInWithLidClosed() {
        #expect(pickMic([builtIn, samson], preferred: ["MacBook Pro Microphone"], lidClosed: true) == samson)
        #expect(pickMic([builtIn], preferred: ["MacBook Pro Microphone"], lidClosed: true) == nil)
        #expect(pickMic([builtIn, bose, teams], preferred: [], lidClosed: true) == nil)   // Bluetooth/virtual never automatic
    }

    @Test func rememberMovesToFront() {
        #expect(remember("B", in: ["A", "b", "C"]) == ["B", "A", "C"])
        #expect(remember("A", in: ["A"]) == ["A"])
    }

    @Test func matching() {
        let names = ["MacBook Pro Microphone", "USB Microphone", "HD Web Camera"]
        #expect(matchMic("2", in: names) == .found("USB Microphone"))
        #expect(matchMic("4", in: names) == .none)
        #expect(matchMic("camera", in: names) == .found("HD Web Camera"))
        #expect(matchMic("usb microphone", in: names) == .found("USB Microphone"))
        #expect(matchMic("microphone", in: names) == .ambiguous(["MacBook Pro Microphone", "USB Microphone"]))
    }
}
