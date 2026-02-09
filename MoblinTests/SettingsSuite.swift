@testable import Moblin
import Testing

struct SettingsSuite {
    @Test
    func chatFilter() {
        let filter = SettingsChatFilter()
        filter.user = ""
        filter.messageStartWords = ["!"]
        #expect(filter.isMatching(user: "erik", segments: [.init(id: 0, text: "!moblin")]))
        #expect(filter.isMatching(user: "erik", segments: [.init(id: 0, text: "!")]))
        #expect(!filter.isMatching(user: "erik", segments: [.init(id: 0, text: "@foo")]))
        #expect(!filter.isMatching(user: "erik", segments: [.init(id: 0, text: "@")]))
        filter.messageStartWords = ["hell", "h"]
        #expect(filter.isMatching(user: "erik",
                                  segments: [
                                      .init(id: 0, text: "hell"),
                                      .init(id: 0, text: "hi"),
                                      .init(id: 0, text: "ho"),
                                  ]))
        #expect(!filter.isMatching(user: "erik",
                                   segments: [
                                       .init(id: 0, text: "hello"),
                                       .init(id: 0, text: "hi"),
                                       .init(id: 0, text: "ho"),
                                   ]))
    }

    @Test
    func whipProtocol() {
        let stream = SettingsStream(name: "WHIP")
        stream.url = "https://whip.example.com/live/123"
        #expect(stream.getProtocol() == .whip)
        #expect(stream.protocolString() == "WHIP")

        stream.url = "whips://whip.example.com/live/123"
        #expect(stream.getProtocol() == .whip)
        #expect(stream.protocolString() == "WHIP")

        stream.url = "whip://whip.example.com/live/123"
        #expect(stream.getProtocol() == .whip)
        #expect(stream.protocolString() == "WHIP")
    }

    @Test
    func whipUrlValidation() {
        #expect(isValidUrl(url: "https://whip.example.com/live/123") == nil)
        #expect(isValidUrl(url: "whips://whip.example.com/live/123") == nil)
        #expect(isValidUrl(url: "whip://whip.example.com/live/123") == nil)
    }
}
