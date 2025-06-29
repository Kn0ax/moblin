import Foundation

private let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10.15; rv:124.0) Gecko/20100101 Firefox/124.0"

/// Extracts video ID from YouTube handle by checking if they're currently live
/// Returns nil if the user is not live or if there's an error
func extractVideoIdFromHandle(_ handle: String) -> String? {
    guard let url = URL(string: "https://www.youtube.com/\(handle)/live") else {
        print("YouTubeLiveChat: Invalid URL for handle: \(handle)")
        return nil
    }

    print("YouTubeLiveChat: Checking if \(handle) is live at: \(url)")

    var request = URLRequest(url: url)
    request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
    request.setValue("CONSENT=YES+1", forHTTPHeaderField: "Cookie")

    let semaphore = DispatchSemaphore(value: 0)
    var resultData: Data?
    var resultResponse: URLResponse?
    var resultError: Error?

    let task = URLSession.shared.dataTask(with: request) { data, response, error in
        resultData = data
        resultResponse = response
        resultError = error
        semaphore.signal()
    }

    task.resume()
    semaphore.wait()

    if let error = resultError {
        print("YouTubeLiveChat: Network error: \(error)")
        return nil
    }

    guard let data = resultData else {
        print("YouTubeLiveChat: No data received")
        return nil
    }

    guard let httpResponse = resultResponse as? HTTPURLResponse else {
        print("YouTubeLiveChat: Not an HTTP response")
        return nil
    }

    print("YouTubeLiveChat: HTTP Status: \(httpResponse.statusCode)")

    guard httpResponse.statusCode == 200 else {
        print("YouTubeLiveChat: HTTP error \(httpResponse.statusCode)")
        return nil
    }

    guard let html = String(data: data, encoding: .utf8) else {
        print("YouTubeLiveChat: Could not decode HTML as UTF-8")
        return nil
    }

    print("YouTubeLiveChat: HTML length: \(html.count) characters")

    // Look for the shortlinkUrl in the HTML with multiple patterns
    let patterns = [
        #"<link rel="shortlinkUrl" href="https://youtu\.be/([^"]+)""#,
        #"<link rel='shortlinkUrl' href='https://youtu\.be/([^']+)'"#,
        #"shortlinkUrl[^>]*href=[\"\']https://youtu\.be/([^\"\']+)"#,
    ]

    for (index, pattern) in patterns.enumerated() {
        print("YouTubeLiveChat: Trying pattern \(index + 1): \(pattern)")

        if let regex = try? NSRegularExpression(pattern: pattern, options: []),
           let match = regex.firstMatch(in: html, options: [], range: NSRange(html.startIndex..., in: html)),
           let videoIdRange = Range(match.range(at: 1), in: html)
        {
            let videoId = String(html[videoIdRange])
            print("YouTubeLiveChat: Found video ID: \(videoId)")
            return videoId
        }
    }

    // Check if the HTML contains any shortlinkUrl at all
    if html.contains("shortlinkUrl") {
        print("YouTubeLiveChat: Found 'shortlinkUrl' in HTML but regex didn't match")
        // Extract a snippet around shortlinkUrl for debugging
        if let range = html.range(of: "shortlinkUrl") {
            let start = html.index(range.lowerBound, offsetBy: -50, limitedBy: html.startIndex) ?? html.startIndex
            let end = html.index(range.upperBound, offsetBy: 100, limitedBy: html.endIndex) ?? html.endIndex
            let snippet = String(html[start ..< end])
            print("YouTubeLiveChat: HTML snippet around shortlinkUrl: \(snippet)")
        }
    } else {
        print("YouTubeLiveChat: No 'shortlinkUrl' found in HTML - user is likely not live")
    }

    return nil
}

private let minimumPollDelayMs = 200
private let maximumPollDelayMs = 3000

private func createPaidMessageHighlight(chatDescription: ChatDescription) -> ChatHighlight {
    var amount = ""
    if let text = chatDescription.purchaseAmountText?.simpleText {
        amount = ", \(text)"
    }
    return ChatHighlight.makePaidMessage(amount: amount)
}

private func createPaidStickerHighlight(chatDescription: ChatDescription) -> ChatHighlight {
    var amount = ""
    if let text = chatDescription.purchaseAmountText?.simpleText {
        amount = ", \(text)"
    }
    return ChatHighlight.makePaidSticker(amount: amount)
}

private func createMemberHighlight() -> ChatHighlight {
    return ChatHighlight.makeMember()
}

private struct InvalidationContinuationData: Codable {
    let continuation: String
}

private struct Continuations: Codable {
    let invalidationContinuationData: InvalidationContinuationData
}

private struct Thumbnail: Codable {
    let url: String
}

private struct Image: Codable {
    let thumbnails: [Thumbnail]
}

private struct Emoji: Codable {
    let image: Image
}

private struct Run: Codable {
    let text: String?
    let emoji: Emoji?
}

private struct Message: Codable {
    let runs: [Run]
}

private struct Author: Codable {
    let simpleText: String
}

private struct Amount: Codable {
    let simpleText: String
}

private struct ChatDescription: Codable {
    let authorName: Author
    let message: Message?
    let purchaseAmountText: Amount?
    let headerSubtext: Message?
}

private struct AddChatItemActionItem: Codable {
    let liveChatTextMessageRenderer: ChatDescription?
    let liveChatPaidMessageRenderer: ChatDescription?
    let liveChatPaidStickerRenderer: ChatDescription?
    let liveChatMembershipItemRenderer: ChatDescription?
    // let liveChatSponsorshipsGiftPurchaseAnnouncementRenderer: ?
}

private struct AddChatItemAction: Codable {
    let item: AddChatItemActionItem
}

private struct Action: Codable {
    let addChatItemAction: AddChatItemAction?
}

private struct LiveChatContinuation: Codable {
    let continuations: [Continuations]
    let actions: [Action]?
}

private struct ContinuationContents: Codable {
    let liveChatContinuation: LiveChatContinuation
}

private struct GetLiveChat: Codable {
    let continuationContents: ContinuationContents
}

final class YouTubeLiveChat: NSObject {
    private var model: Model
    private var videoId: String
    private var task: Task<Void, Error>?
    private var emotes: Emotes
    private var settings: SettingsStreamChat
    private var connected: Bool = false
    private var continuation: String = ""
    private var delay = 2000

    init(model: Model, videoId: String, settings: SettingsStreamChat) {
        self.model = model
        self.videoId = videoId
        self.settings = settings.clone()
        emotes = Emotes()
    }

    func start() {
        emotes.start(
            platform: .youtube,
            channelId: videoId,
            onError: handleError,
            onOk: handleOk,
            settings: settings
        )
        task = Task.init {
            while true {
                do {
                    try await getInitialContinuation()
                    connected = true
                    try await readMessages()
                } catch {}
                connected = false
                if Task.isCancelled {
                    break
                }
                try await sleep(seconds: 5)
            }
        }
    }

    func stop() {
        emotes.stop()
        task?.cancel()
        task = nil
        connected = false
    }

    func isConnected() -> Bool {
        return connected
    }

    func hasEmotes() -> Bool {
        return emotes.isReady()
    }

    private func handleError(title: String, subTitle: String) {
        DispatchQueue.main.async {
            self.model.makeErrorToast(title: title, subTitle: subTitle)
        }
    }

    private func handleOk(title: String) {
        DispatchQueue.main.async {
            self.model.makeToast(title: title)
        }
    }

    private func makeLiveChatUrl() -> URL? {
        return URL(string: "https://www.youtube.com/live_chat?is_popout=1&v=\(videoId)")
    }

    private func makeGetLiveChatUrl() -> URL? {
        return URL(string: "https://www.youtube.com/youtubei/v1/live_chat/get_live_chat")
    }

    private func getInitialContinuation() async throws {
        guard let url = makeLiveChatUrl() else {
            throw "Failed to create URL"
        }
        let (data, response) = try await fetch(from: url)
        if !response.isSuccessful {
            throw "Unsuccessful HTTP response"
        }
        guard let body = String(bytes: data, encoding: .utf8) else {
            throw "Not UTF-8 body"
        }
        let re_continuation = /"continuation":"([^"]+)"/
        guard let match = try re_continuation.firstMatch(in: body) else {
            throw "No continuation"
        }
        continuation = String(match.1)
    }

    private func readMessages() async throws {
        guard let url = makeGetLiveChatUrl() else {
            throw "Failed to create URL"
        }
        while true {
            let (data, response) = try await upload(from: url, data: makeGetLiveChatBody())
            if !response.isSuccessful {
                throw "Unsuccessful HTTP response"
            }
            var numberOfMessages = 0
            let getLiveChat = try JSONDecoder().decode(GetLiveChat.self, from: data)
            if let actions = getLiveChat.continuationContents.liveChatContinuation.actions {
                for action in actions {
                    guard let item = action.addChatItemAction?.item else {
                        continue
                    }
                    if let chatDescription = item.liveChatTextMessageRenderer {
                        numberOfMessages += await handleChatDescription(
                            chatDescription: chatDescription,
                            highlight: nil
                        )
                    }
                    if let chatDescription = item.liveChatPaidMessageRenderer {
                        numberOfMessages += await handleChatDescription(
                            chatDescription: chatDescription,
                            highlight: createPaidMessageHighlight(chatDescription: chatDescription)
                        )
                    }
                    if let chatDescription = item.liveChatPaidStickerRenderer {
                        numberOfMessages += await handleChatDescription(
                            chatDescription: chatDescription,
                            highlight: createPaidStickerHighlight(chatDescription: chatDescription)
                        )
                    }
                    if let chatDescription = item.liveChatMembershipItemRenderer {
                        numberOfMessages += await handleChatDescription(
                            chatDescription: chatDescription,
                            highlight: createMemberHighlight()
                        )
                    }
                }
            }
            try updateContinuation(getLiveChat: getLiveChat)
            updateDelayMs(numberOfMessages: numberOfMessages)
            try await sleep(milliSeconds: delay)
        }
    }

    private func updateDelayMs(numberOfMessages: Int) {
        if numberOfMessages > 0 {
            delay = delay * 5 / numberOfMessages
        } else {
            delay = maximumPollDelayMs
        }

        if delay > maximumPollDelayMs {
            delay = maximumPollDelayMs
        }

        if delay < minimumPollDelayMs {
            delay = minimumPollDelayMs
        }
    }

    private func handleChatDescription(chatDescription: ChatDescription,
                                       highlight: ChatHighlight?) async -> Int
    {
        var id = 0
        var segments: [ChatPostSegment] = []
        if let headerSubtext = chatDescription.headerSubtext {
            for run in headerSubtext.runs {
                if let text = run.text {
                    segments += createSegments(message: text, id: &id)
                }
                if let emojiUrl = run.emoji?.image.thumbnails.first?.url {
                    segments.append(.init(id: id, url: URL(string: emojiUrl)))
                    id += 1
                }
            }
        }
        if let message = chatDescription.message {
            for run in message.runs {
                if let text = run.text {
                    segments += createSegments(message: text, id: &id)
                }
                if let emojiUrl = run.emoji?.image.thumbnails.first?.url {
                    segments.append(.init(id: id, url: URL(string: emojiUrl)))
                    id += 1
                }
            }
        }
        guard !segments.isEmpty || highlight != nil else {
            return 0
        }
        let nonMutSegments = segments
        await MainActor.run {
            model.appendChatMessage(platform: .youTube,
                                    messageId: nil,
                                    user: chatDescription.authorName.simpleText,
                                    userId: nil,
                                    userColor: nil,
                                    userBadges: [],
                                    segments: nonMutSegments,
                                    timestamp: model.statusOther.digitalClock,
                                    timestampTime: .now,
                                    isAction: false,
                                    isSubscriber: false,
                                    isModerator: false,
                                    bits: nil,
                                    highlight: highlight, live: true)
        }
        return 1
    }

    private func updateContinuation(getLiveChat: GetLiveChat) throws {
        guard let continuation = getLiveChat.continuationContents.liveChatContinuation.continuations.first
        else {
            throw "Continuation missing"
        }
        self.continuation = continuation.invalidationContinuationData.continuation
    }

    private func makeGetLiveChatBody() -> Data {
        return """
        {
            "context": {
                "client": {
                    "clientName": "WEB",
                    "clientVersion": "2.20210128.02.00"
                }
            },
            "continuation": "\(continuation)"
        }
        """.utf8Data
    }

    private func createSegments(message: String, id: inout Int) -> [ChatPostSegment] {
        var segments: [ChatPostSegment] = []
        for var segment in makeChatPostTextSegments(text: message, id: &id) {
            if let text = segment.text {
                segments += emotes.createSegments(text: text, id: &id)
                segment.text = nil
            }
            if segment.text != nil || segment.url != nil {
                segments.append(segment)
            }
        }
        return segments
    }

    private func fetch(from: URL) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: from)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let response = response.http {
            return (data, response)
        } else {
            throw "Not an HTTP response"
        }
    }

    private func upload(from: URL, data: Data) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: from)
        request.httpMethod = "POST"
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await URLSession.shared.upload(for: request, from: data)
        if let response = response.http {
            return (data, response)
        } else {
            throw "Not an HTTP response"
        }
    }
}
