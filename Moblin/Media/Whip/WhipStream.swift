import AVFoundation
import Foundation
import libdatachannel

private let whipQueue = DispatchQueue(label: "com.eerimoq.Moblin.whip")
private let whipH264PayloadType: UInt8 = 98
private let whipOpusPayloadType: UInt8 = 111
private let whipRtpMtu = 1200

private enum WhipRtcError: Error {
    case rtc(Int32)
}

@discardableResult
private func whipCheck(_ result: Int32) throws -> Int32 {
    guard result >= 0 else {
        throw WhipRtcError.rtc(result)
    }
    return result
}

private func whipGetString(_ lambda: (UnsafeMutablePointer<CChar>?, Int32) -> Int32) throws -> String {
    let size = try whipCheck(lambda(nil, 0))
    var buffer = [CChar](repeating: 0, count: Int(size))
    _ = try whipCheck(lambda(&buffer, Int32(size)))
    return String(cString: buffer)
}

private enum WhipConnectionState {
    case new
    case connecting
    case connected
    case disconnected
    case failed
    case closed

    init?(cValue: rtcState) {
        switch cValue {
        case RTC_NEW:
            self = .new
        case RTC_CONNECTING:
            self = .connecting
        case RTC_CONNECTED:
            self = .connected
        case RTC_DISCONNECTED:
            self = .disconnected
        case RTC_FAILED:
            self = .failed
        case RTC_CLOSED:
            self = .closed
        default:
            return nil
        }
    }

    func toString() -> String {
        switch self {
        case .new:
            return "new"
        case .connecting:
            return "connecting"
        case .connected:
            return "connected"
        case .disconnected:
            return "disconnected"
        case .failed:
            return "failed"
        case .closed:
            return "closed"
        }
    }
}

private enum WhipGatheringState {
    case new
    case inProgress
    case complete

    init?(cValue: rtcGatheringState) {
        switch cValue {
        case RTC_GATHERING_NEW:
            self = .new
        case RTC_GATHERING_INPROGRESS:
            self = .inProgress
        case RTC_GATHERING_COMPLETE:
            self = .complete
        default:
            return nil
        }
    }

    func toString() -> String {
        switch self {
        case .new:
            return "new"
        case .inProgress:
            return "in-progress"
        case .complete:
            return "complete"
        }
    }
}

private enum WhipTrackState {
    case connecting
    case open
    case closed
}

private enum WhipIceState {
    case new
    case checking
    case connected
    case completed
    case failed
    case disconnected
    case closed

    init?(cValue: rtcIceState) {
        switch cValue {
        case RTC_ICE_NEW:
            self = .new
        case RTC_ICE_CHECKING:
            self = .checking
        case RTC_ICE_CONNECTED:
            self = .connected
        case RTC_ICE_COMPLETED:
            self = .completed
        case RTC_ICE_FAILED:
            self = .failed
        case RTC_ICE_DISCONNECTED:
            self = .disconnected
        case RTC_ICE_CLOSED:
            self = .closed
        default:
            return nil
        }
    }

    func toString() -> String {
        switch self {
        case .new:
            return "new"
        case .checking:
            return "checking"
        case .connected:
            return "connected"
        case .completed:
            return "completed"
        case .failed:
            return "failed"
        case .disconnected:
            return "disconnected"
        case .closed:
            return "closed"
        }
    }
}

private struct WhipRtpPacket {
    let marker: Bool
    let payloadType: UInt8
    let sequenceNumber: UInt16
    let timestamp: UInt32
    let ssrc: UInt32
    let payload: Data

    func data() -> Data {
        var data = Data(capacity: 12 + payload.count)
        data.append(0x80)
        data.append((marker ? 0x80 : 0x00) | (payloadType & 0x7F))
        data.append(contentsOf: [
            UInt8((sequenceNumber >> 8) & 0xFF),
            UInt8(sequenceNumber & 0xFF),
        ])
        data.append(contentsOf: [
            UInt8((timestamp >> 24) & 0xFF),
            UInt8((timestamp >> 16) & 0xFF),
            UInt8((timestamp >> 8) & 0xFF),
            UInt8(timestamp & 0xFF),
        ])
        data.append(contentsOf: [
            UInt8((ssrc >> 24) & 0xFF),
            UInt8((ssrc >> 16) & 0xFF),
            UInt8((ssrc >> 8) & 0xFF),
            UInt8(ssrc & 0xFF),
        ])
        data.append(payload)
        return data
    }
}

private struct WhipRtpTimestamp {
    private let rate: Double
    private var startedAt: Double?

    init(rate: Double) {
        self.rate = rate
    }

    mutating func convert(_ time: CMTime) -> UInt32 {
        let seconds = time.seconds
        if startedAt == nil {
            startedAt = seconds
        }
        let timestamp = UInt64(max((seconds - (startedAt ?? seconds)) * rate, 0))
        return UInt32(timestamp & 0xFFFF_FFFF)
    }
}

private final class WhipH264Packetizer {
    let ssrc: UInt32
    private let payloadType: UInt8
    private var sequenceNumber: UInt16 = 0
    private var timestamp = WhipRtpTimestamp(rate: 90_000)
    private var sps: Data?
    private var pps: Data?

    init(ssrc: UInt32, payloadType: UInt8) {
        self.ssrc = ssrc
        self.payloadType = payloadType
    }

    func setParameterSets(sps: Data?, pps: Data?) {
        self.sps = sps
        self.pps = pps
    }

    func packetize(sampleBuffer: CMSampleBuffer) -> [Data] {
        var nalUnits = extractNalUnits(sampleBuffer: sampleBuffer)
        guard !nalUnits.isEmpty else {
            return []
        }
        if sampleBuffer.getIsSync() {
            if let sps {
                nalUnits.insert(sps, at: 0)
            }
            if let pps {
                nalUnits.insert(pps, at: min(1, nalUnits.count))
            }
        }
        let packetTimestamp = timestamp.convert(sampleBuffer.presentationTimeStamp)
        var packets: [Data] = []
        for (index, nalUnit) in nalUnits.enumerated() {
            let isLastNal = index == nalUnits.count - 1
            if nalUnit.count <= whipRtpMtu {
                let packet = WhipRtpPacket(
                    marker: isLastNal,
                    payloadType: payloadType,
                    sequenceNumber: sequenceNumber,
                    timestamp: packetTimestamp,
                    ssrc: ssrc,
                    payload: nalUnit
                )
                packets.append(packet.data())
                sequenceNumber &+= 1
            } else {
                let nalHeader = nalUnit[0]
                let fuIndicator = (nalHeader & 0xE0) | 28
                let nalType = nalHeader & 0x1F
                var offset = 1
                var first = true
                while offset < nalUnit.count {
                    let chunkSize = min(whipRtpMtu - 2, nalUnit.count - offset)
                    var fuHeader = nalType
                    if first {
                        fuHeader |= 0x80
                    }
                    let isFinalFragment = offset + chunkSize >= nalUnit.count
                    if isFinalFragment {
                        fuHeader |= 0x40
                    }
                    var payload = Data([fuIndicator, fuHeader])
                    payload.append(contentsOf: nalUnit[offset ..< offset + chunkSize])
                    let packet = WhipRtpPacket(
                        marker: isLastNal && isFinalFragment,
                        payloadType: payloadType,
                        sequenceNumber: sequenceNumber,
                        timestamp: packetTimestamp,
                        ssrc: ssrc,
                        payload: payload
                    )
                    packets.append(packet.data())
                    sequenceNumber &+= 1
                    offset += chunkSize
                    first = false
                }
            }
        }
        return packets
    }

    private func extractNalUnits(sampleBuffer: CMSampleBuffer) -> [Data] {
        guard let (buffer, length) = sampleBuffer.dataBuffer?.getDataPointer() else {
            return []
        }
        let data = Data(bytes: buffer, count: length)
        var nalUnits: [Data] = []
        var offset = 0
        while offset + 4 <= data.count {
            let nalLength = Int(data.getFourBytesBe(offset: offset))
            offset += 4
            guard nalLength > 0, offset + nalLength <= data.count else {
                break
            }
            nalUnits.append(data.subdata(in: offset ..< offset + nalLength))
            offset += nalLength
        }
        return nalUnits
    }
}

private final class WhipOpusPacketizer {
    let ssrc: UInt32

    init(ssrc: UInt32) {
        self.ssrc = ssrc
    }

    func packetize(buffer: AVAudioCompressedBuffer, presentationTimeStamp: CMTime) -> [Data] {
        _ = presentationTimeStamp
        guard buffer.byteLength > 0 else {
            return []
        }

        let allData = Data(bytes: buffer.data, count: Int(buffer.byteLength))
        guard buffer.packetCount > 0, let descriptions = buffer.packetDescriptions else {
            return [allData]
        }

        var packets: [Data] = []
        packets.reserveCapacity(Int(buffer.packetCount))
        for index in 0 ..< Int(buffer.packetCount) {
            let description = descriptions[index]
            let offset = Int(description.mStartOffset)
            let size = Int(description.mDataByteSize)
            guard size > 0, offset >= 0, offset + size <= allData.count else {
                continue
            }
            packets.append(allData.subdata(in: offset ..< offset + size))
        }
        return packets.isEmpty ? [allData] : packets
    }
}

private final class WhipOpusRtpPacketizer {
    private let ssrc: UInt32
    private let payloadType: UInt8
    private var sequenceNumber: UInt16 = 0
    private var timestamp: UInt32 = 0

    init(ssrc: UInt32, payloadType: UInt8) {
        self.ssrc = ssrc
        self.payloadType = payloadType
    }

    func packetize(payload: Data) -> Data {
        let packet = WhipRtpPacket(
            marker: false,
            payloadType: payloadType,
            sequenceNumber: sequenceNumber,
            timestamp: timestamp,
            ssrc: ssrc,
            payload: payload
        )
        sequenceNumber &+= 1
        timestamp &+= 960
        return packet.data()
    }
}

private final class WhipRtcTrack {
    let id: Int32
    var onStateChanged: ((WhipTrackState) -> Void)?
    private(set) var state: WhipTrackState = .connecting {
        didSet {
            guard state != oldValue else {
                return
            }
            onStateChanged?(state)
        }
    }

    init(id: Int32) throws {
        self.id = id
        try whipCheck(id)
        do {
            rtcSetUserPointer(id, Unmanaged.passUnretained(self).toOpaque())
            try whipCheck(rtcSetOpenCallback(id) { _, pointer in
                guard let pointer else {
                    return
                }
                Unmanaged<WhipRtcTrack>.fromOpaque(pointer).takeUnretainedValue().state = .open
            })
            try whipCheck(rtcSetClosedCallback(id) { _, pointer in
                guard let pointer else {
                    return
                }
                Unmanaged<WhipRtcTrack>.fromOpaque(pointer).takeUnretainedValue().state = .closed
            })
            try whipCheck(rtcSetErrorCallback(id) { _, error, pointer in
                guard let pointer else {
                    return
                }
                let track = Unmanaged<WhipRtcTrack>.fromOpaque(pointer).takeUnretainedValue()
                track.state = .closed
                if let error {
                    logger.info("whip: Track error: \(String(cString: error))")
                }
            })
        } catch {
            rtcDeleteTrack(id)
            throw error
        }
    }

    deinit {
        rtcDeleteTrack(id)
    }

    func send(packet: Data) -> Bool {
        guard state == .open else {
            return false
        }
        let result = packet.withUnsafeBytes { pointer in
            rtcSendMessage(id, pointer.bindMemory(to: CChar.self).baseAddress, Int32(packet.count))
        }
        return result >= 0
    }

    func setOpusPacketizer(ssrc: UInt32, payloadType: UInt8) -> Bool {
        var packetizerInit = rtcPacketizerInit(
            ssrc: ssrc,
            cname: nil,
            payloadType: payloadType,
            clockRate: 48_000,
            sequenceNumber: UInt16.random(in: UInt16.min ... UInt16.max),
            timestamp: UInt32.random(in: UInt32.min ... UInt32.max),
            maxFragmentSize: 0,
            nalSeparator: RTC_NAL_SEPARATOR_LENGTH,
            obuPacketization: RTC_OBU_PACKETIZED_OBU,
            playoutDelayId: 0,
            playoutDelayMin: 0,
            playoutDelayMax: 0,
            colorSpaceId: 0,
            colorChromaSitingHorz: 0,
            colorChromaSitingVert: 0,
            colorRange: 0,
            colorPrimaries: 0,
            colorTransfer: 0,
            colorMatrix: 0
        )
        let result = rtcSetOpusPacketizer(id, &packetizerInit)
        if result < 0 {
            logger.info("whip: Native Opus packetizer unavailable (result=\(result)), using RTP fallback")
            return false
        }
        return true
    }
}

private struct WhipRtcTrackConfiguration {
    let codec: rtcCodec
    let payloadType: Int32
    let ssrc: UInt32
    let mid: String
    let profile: String?

    static func makeAudio(ssrc: UInt32) -> Self {
        return .init(codec: RTC_CODEC_OPUS,
                     payloadType: Int32(whipOpusPayloadType),
                     ssrc: ssrc,
                     mid: "0",
                     profile: "minptime=10;useinbandfec=1;stereo=1;sprop-stereo=1")
    }

    static func makeVideo(ssrc: UInt32) -> Self {
        return .init(codec: RTC_CODEC_H264,
                     payloadType: Int32(whipH264PayloadType),
                     ssrc: ssrc,
                     mid: "1",
                     profile: "level-asymmetry-allowed=1;packetization-mode=1;profile-level-id=42e01f")
    }

    func addTrack(connection: Int32, streamId: String) throws -> WhipRtcTrack {
        let name = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(16))
        let trackId = UUID().uuidString
        var trackInit = rtcTrackInit(
            direction: RTC_DIRECTION_SENDONLY,
            codec: codec,
            payloadType: payloadType,
            ssrc: ssrc,
            mid: strdup(mid),
            name: strdup(name),
            msid: strdup(streamId),
            trackId: strdup(trackId),
            profile: profile == nil ? nil : strdup(profile)
        )
        let id = try whipCheck(rtcAddTrackEx(connection, &trackInit))
        return try WhipRtcTrack(id: id)
    }
}

private final class WhipPeerConnection {
    let id: Int32
    var onConnectionStateChanged: ((WhipConnectionState) -> Void)?
    var onGatheringStateChanged: ((WhipGatheringState) -> Void)?
    var onIceStateChanged: ((WhipIceState) -> Void)?
    var onSignalingStateChanged: ((rtcSignalingState) -> Void)?
    var onLocalCandidate: ((String, String) -> Void)?

    init() throws {
        var configuration = rtcConfiguration()
        var createdId: Int32 = -1
        if let stunServer = strdup("stun:stun.l.google.com:19302") {
            var iceServers: [UnsafePointer<CChar>?] = [UnsafePointer(stunServer)]
            iceServers.withUnsafeMutableBufferPointer { buffer in
                configuration.iceServers = buffer.baseAddress
                configuration.iceServersCount = Int32(buffer.count)
                createdId = rtcCreatePeerConnection(&configuration)
            }
            free(stunServer)
        } else {
            createdId = rtcCreatePeerConnection(&configuration)
        }
        id = createdId
        try whipCheck(id)
        do {
            rtcSetUserPointer(id, Unmanaged.passUnretained(self).toOpaque())
            try whipCheck(rtcSetStateChangeCallback(id) { _, state, pointer in
                guard let pointer,
                      let state = WhipConnectionState(cValue: state)
                else {
                    return
                }
                Unmanaged<WhipPeerConnection>.fromOpaque(pointer)
                    .takeUnretainedValue()
                    .onConnectionStateChanged?(state)
            })
            try whipCheck(rtcSetLocalDescriptionCallback(id) { _, _, _, _ in })
            try whipCheck(rtcSetLocalCandidateCallback(id) { _, candidate, mid, pointer in
                guard let pointer else {
                    return
                }
                let candidate = candidate.map { String(cString: $0) } ?? ""
                let mid = mid.map { String(cString: $0) } ?? ""
                Unmanaged<WhipPeerConnection>.fromOpaque(pointer)
                    .takeUnretainedValue()
                    .onLocalCandidate?(candidate, mid)
            })
            try whipCheck(rtcSetSignalingStateChangeCallback(id) { _, state, pointer in
                guard let pointer else {
                    return
                }
                Unmanaged<WhipPeerConnection>.fromOpaque(pointer)
                    .takeUnretainedValue()
                    .onSignalingStateChanged?(state)
            })
            try whipCheck(rtcSetIceStateChangeCallback(id) { _, state, pointer in
                guard let pointer,
                      let state = WhipIceState(cValue: state)
                else {
                    return
                }
                Unmanaged<WhipPeerConnection>.fromOpaque(pointer)
                    .takeUnretainedValue()
                    .onIceStateChanged?(state)
            })
            try whipCheck(rtcSetGatheringStateChangeCallback(id) { _, state, pointer in
                guard let pointer,
                      let state = WhipGatheringState(cValue: state)
                else {
                    return
                }
                Unmanaged<WhipPeerConnection>.fromOpaque(pointer)
                    .takeUnretainedValue()
                    .onGatheringStateChanged?(state)
            })
        } catch {
            rtcDeletePeerConnection(id)
            throw error
        }
    }

    deinit {
        rtcDeletePeerConnection(id)
    }

    func addTrack(configuration: WhipRtcTrackConfiguration, streamId: String) throws -> WhipRtcTrack {
        return try configuration.addTrack(connection: id, streamId: streamId)
    }

    func setLocalDescriptionOffer() throws {
        _ = try "offer".withCString { cType in
            try whipCheck(rtcSetLocalDescription(id, cType))
        }
    }

    func createOffer() throws -> String {
        return try whipGetString { buffer, size in
            rtcCreateOffer(id, buffer, size)
        }
    }

    func getLocalDescription() throws -> String {
        return try whipGetString { buffer, size in
            rtcGetLocalDescription(id, buffer, size)
        }
    }

    func setRemoteAnswer(_ sdp: String) throws {
        _ = try sdp.withCString { cSdp in
            _ = try "answer".withCString { cType in
                try whipCheck(rtcSetRemoteDescription(id, cSdp, cType))
            }
        }
    }

    func close() {
        _ = rtcClosePeerConnection(id)
    }
}

protocol WhipStreamDelegate: AnyObject {
    func whipStreamOnConnected()
    func whipStreamOnDisconnected(reason: String)
}

final class WhipStream {
    private let processor: Processor
    private weak var delegate: WhipStreamDelegate?
    private var peerConnection: WhipPeerConnection?
    private var videoTrack: WhipRtcTrack?
    private var audioTrack: WhipRtcTrack?
    private var videoPacketizer: WhipH264Packetizer?
    private var audioPacketizer: WhipOpusPacketizer?
    private var audioRtpPacketizer: WhipOpusRtpPacketizer?
    private var totalByteCount: Int64 = 0
    private var offerTask: URLSessionTask?
    private var deleteTask: URLSessionTask?
    private var sessionUrl: URL?
    private var endpointUrl: URL?
    private var authorizationHeader: String?
    private var encoding = false
    private var connected = false
    private var stopping = false
    private var offerSent = false
    private var useNativeOpusPacketizer = false

    init(processor: Processor, delegate: WhipStreamDelegate) {
        self.processor = processor
        self.delegate = delegate
    }

    func start(url: String, bearerToken: String) {
        whipQueue.async {
            self.startInternal(url: url, bearerToken: bearerToken)
        }
    }

    func stop() {
        whipQueue.async {
            self.stopInternal(sendDelete: true)
        }
    }

    func getTotalByteCount() -> Int64 {
        return whipQueue.sync {
            totalByteCount
        }
    }

    private func startInternal(url: String, bearerToken: String) {
        stopInternal(sendDelete: true)
        guard let endpointUrl = makeEndpointUrl(url: url) else {
            notifyDisconnected(reason: String(localized: "Malformed WHIP URL"))
            return
        }
        self.endpointUrl = endpointUrl
        authorizationHeader = makeAuthorizationHeader(token: bearerToken)
        totalByteCount = 0
        connected = false
        stopping = false
        offerSent = false
        useNativeOpusPacketizer = false
        logger.info(
            "whip: Start endpoint=\(endpointUrl.absoluteString) auth=\(authorizationHeader == nil ? "none" : "bearer")"
        )
        let audioPacketizer = WhipOpusPacketizer(ssrc: Self.makeSsrc())
        let audioRtpPacketizer = WhipOpusRtpPacketizer(ssrc: audioPacketizer.ssrc, payloadType: whipOpusPayloadType)
        let videoPacketizer = WhipH264Packetizer(ssrc: Self.makeSsrc(), payloadType: whipH264PayloadType)
        self.audioPacketizer = audioPacketizer
        self.audioRtpPacketizer = audioRtpPacketizer
        self.videoPacketizer = videoPacketizer
        do {
            let peerConnection = try WhipPeerConnection()
            peerConnection.onConnectionStateChanged = { [weak self] state in
                whipQueue.async {
                    self?.handleConnectionStateChanged(state: state)
                }
            }
            peerConnection.onGatheringStateChanged = { [weak self] state in
                whipQueue.async {
                    self?.handleGatheringStateChanged(state: state)
                }
            }
            peerConnection.onIceStateChanged = { state in
                whipQueue.async {
                    if state == .failed || state == .disconnected {
                        logger.info("whip: ICE state \(state.toString())")
                    }
                }
            }
            peerConnection.onSignalingStateChanged = { _ in }
            peerConnection.onLocalCandidate = { _, _ in }
            let streamId = UUID().uuidString
            let audioTrack = try peerConnection.addTrack(
                configuration: .makeAudio(ssrc: audioPacketizer.ssrc),
                streamId: streamId
            )
            let videoTrack = try peerConnection.addTrack(
                configuration: .makeVideo(ssrc: videoPacketizer.ssrc),
                streamId: streamId
            )
            useNativeOpusPacketizer = audioTrack.setOpusPacketizer(
                ssrc: audioPacketizer.ssrc,
                payloadType: whipOpusPayloadType
            )
            audioTrack.onStateChanged = { _ in }
            videoTrack.onStateChanged = { _ in }
            self.audioTrack = audioTrack
            self.videoTrack = videoTrack
            self.peerConnection = peerConnection
            try peerConnection.setLocalDescriptionOffer()
            // Fallback: if gathering callback is not delivered, send current local SDP after a short delay.
            whipQueue.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                self?.sendCurrentLocalOfferIfNeeded()
            }
        } catch {
            logger.info("whip: Start failed with error: \(error)")
            notifyDisconnected(reason: String(localized: "WHIP connect failed"))
        }
    }

    private func handleGatheringStateChanged(state: WhipGatheringState) {
        switch state {
        case .complete:
            sendCurrentLocalOfferIfNeeded()
        case .new, .inProgress:
            break
        }
    }

    private func sendCurrentLocalOfferIfNeeded() {
        guard !stopping,
              !offerSent,
              offerTask == nil,
              let endpointUrl,
              let peerConnection
        else {
            return
        }
        do {
            let offer = try peerConnection.getLocalDescription()
            guard !offer.isEmpty else {
                return
            }
            offerSent = true
            sendOffer(endpointUrl: endpointUrl, offer: offer)
        } catch {
            logger.info("whip: Failed to get local offer: \(error)")
        }
    }

    private func handleConnectionStateChanged(state: WhipConnectionState) {
        logger.info("whip: Connection state \(state.toString())")
        switch state {
        case .connected:
            guard !connected, !stopping else {
                return
            }
            connected = true
            startEncoding()
            notifyConnected()
        case .disconnected, .failed, .closed:
            guard !stopping else {
                return
            }
            let reason = String(localized: "WHIP disconnected (\(state.toString()))")
            stopInternal(sendDelete: true)
            notifyDisconnected(reason: reason)
        case .new, .connecting:
            break
        }
    }

    private func sendOffer(endpointUrl: URL, offer: String) {
        var request = URLRequest(url: endpointUrl)
        request.httpMethod = "POST"
        request.setContentType("application/sdp")
        if let authorizationHeader {
            request.setAuthorization(authorizationHeader)
        }
        request.httpBody = offer.utf8Data
        offerTask = URLSession.shared.dataTask(with: request) { data, response, error in
            whipQueue.async {
                self.offerTask = nil
                guard !self.stopping else {
                    return
                }
                if let error {
                    logger.info("whip: Offer request failed with error: \(error)")
                    self.stopInternal(sendDelete: true)
                    self.notifyDisconnected(reason: String(localized: "WHIP offer failed"))
                    return
                }
                guard let response = response as? HTTPURLResponse else {
                    logger.info("whip: Offer response was not HTTP")
                    self.stopInternal(sendDelete: true)
                    self.notifyDisconnected(reason: String(localized: "WHIP bad server response"))
                    return
                }
                logger.info("whip: Offer response status=\(response.statusCode)")
                guard (200 ... 299).contains(response.statusCode) else {
                    self.stopInternal(sendDelete: true)
                    self.notifyDisconnected(
                        reason: String(localized: "WHIP server returned \(response.statusCode)")
                    )
                    return
                }
                if let locationHeader = response.value(forHTTPHeaderField: "Location") {
                    self.sessionUrl = URL(string: locationHeader, relativeTo: endpointUrl)?.absoluteURL
                    logger.info("whip: Session location=\(self.sessionUrl?.absoluteString ?? locationHeader)")
                }
                guard let data, let answer = String(data: data, encoding: .utf8) else {
                    self.stopInternal(sendDelete: true)
                    self.notifyDisconnected(reason: String(localized: "WHIP answer missing"))
                    return
                }
                do {
                    try self.peerConnection?.setRemoteAnswer(answer)
                } catch {
                    logger.info("whip: Failed to set remote answer: \(error)")
                    self.stopInternal(sendDelete: true)
                    self.notifyDisconnected(reason: String(localized: "WHIP answer rejected"))
                }
            }
        }
        offerTask?.resume()
    }

    private func stopInternal(sendDelete: Bool) {
        stopping = true
        stopEncoding()
        offerTask?.cancel()
        offerTask = nil
        deleteTask?.cancel()
        deleteTask = nil
        if sendDelete, let sessionUrl {
            sendDeleteRequest(url: sessionUrl)
        }
        sessionUrl = nil
        endpointUrl = nil
        peerConnection?.close()
        peerConnection = nil
        videoTrack = nil
        audioTrack = nil
        videoPacketizer = nil
        audioPacketizer = nil
        audioRtpPacketizer = nil
        connected = false
        offerSent = false
        stopping = false
    }

    private func sendDeleteRequest(url: URL) {
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setContentType("application/sdp")
        if let authorizationHeader {
            request.setAuthorization(authorizationHeader)
        }
        deleteTask = URLSession.shared.dataTask(with: request) { _, response, error in
            whipQueue.async {
                if let error {
                    logger.info("whip: DELETE failed with error: \(error)")
                    return
                }
                _ = response
            }
        }
        deleteTask?.resume()
    }

    private func startEncoding() {
        guard !encoding else {
            return
        }
        encoding = true
        processorControlQueue.async {
            self.processor.startEncoding(self)
        }
    }

    private func stopEncoding() {
        guard encoding else {
            return
        }
        encoding = false
        processorControlQueue.async {
            self.processor.stopEncoding(self)
        }
    }

    private func notifyConnected() {
        DispatchQueue.main.async {
            self.delegate?.whipStreamOnConnected()
        }
    }

    private func notifyDisconnected(reason: String) {
        DispatchQueue.main.async {
            self.delegate?.whipStreamOnDisconnected(reason: reason)
        }
    }

    private func makeEndpointUrl(url: String) -> URL? {
        guard var components = URLComponents(string: url) else {
            return nil
        }
        switch components.scheme?.lowercased() {
        case "whip":
            components.scheme = "http"
        case "whips":
            components.scheme = "https"
        case "http", "https":
            break
        default:
            return nil
        }
        return components.url
    }

    private func makeAuthorizationHeader(token: String) -> String? {
        let token = token.trim()
        guard !token.isEmpty else {
            return nil
        }
        if token.lowercased().hasPrefix("bearer ") {
            return token
        }
        return "Bearer \(token)"
    }

    private static func makeSsrc() -> UInt32 {
        var ssrc: UInt32 = 0
        while ssrc == 0 {
            ssrc = UInt32.random(in: UInt32.min ... UInt32.max)
        }
        return ssrc
    }

}

extension WhipStream: AudioEncoderDelegate {
    func audioEncoderOutputFormat(_ format: AVAudioFormat) {
        guard format.formatDescription.audioStreamBasicDescription?.mFormatID == kAudioFormatOpus else {
            logger.info("whip: Expected Opus audio for WHIP")
            return
        }
    }

    func audioEncoderOutputBuffer(_ buffer: AVAudioCompressedBuffer, _ presentationTimeStamp: CMTime) {
        whipQueue.async {
            guard self.connected,
                  let packets = self.audioPacketizer?.packetize(
                      buffer: buffer,
                      presentationTimeStamp: presentationTimeStamp
                  )
            else {
                return
            }
            for packet in packets {
                let outgoingPacket: Data
                if self.useNativeOpusPacketizer {
                    outgoingPacket = packet
                } else if let rtpPacketizer = self.audioRtpPacketizer {
                    outgoingPacket = rtpPacketizer.packetize(payload: packet)
                } else {
                    continue
                }
                if self.audioTrack?.send(packet: outgoingPacket) == true {
                    self.totalByteCount += Int64(outgoingPacket.count)
                }
            }
        }
    }
}

extension WhipStream: VideoEncoderDelegate {
    func videoEncoderOutputFormat(_: VideoEncoder, _ formatDescription: CMFormatDescription) {
        whipQueue.async {
            if let config = MpegTsVideoConfigAvc(formatDescription: formatDescription) {
                self.videoPacketizer?.setParameterSets(
                    sps: config.sequenceParameterSet,
                    pps: config.pictureParameterSet
                )
            }
        }
    }

    func videoEncoderOutputSampleBuffer(_: VideoEncoder,
                                        _ sampleBuffer: CMSampleBuffer,
                                        _ decodeTimeStampOffset: CMTime)
    {
        whipQueue.async {
            guard self.connected,
                  let packets = self.videoPacketizer?.packetize(sampleBuffer: sampleBuffer)
            else {
                return
            }
            for packet in packets {
                if self.videoTrack?.send(packet: packet) == true {
                    self.totalByteCount += Int64(packet.count)
                }
            }
        }
    }
}
