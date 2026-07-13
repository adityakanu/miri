import Foundation

public enum MiriProtocol {
    public static let version: UInt16 = 1
    public static let maximumFrameBytes = 16 * 1024 * 1024
}

public enum PayloadKind: String, Codable, Sendable { case json, pcmFloat32 }

public enum MessageType: String, Codable, CaseIterable, Sendable {
    case hello, health, cancel, error
    case audioStart = "audio.start"
    case audioChunk = "audio.chunk"
    case audioStop = "audio.stop"
    case audioEndpoint = "audio.endpoint"
    case transcriptPartial = "transcript.partial"
    case transcriptFinal = "transcript.final"
    case speechStart = "speech.start"
    case speechChunk = "speech.chunk"
    case speechStop = "speech.stop"
    case modelProgress = "model.progress"
    case modelStatus = "model.status"
    case modelInstall = "model.install"
    case modelRemove = "model.remove"
    case wakeStart = "wake.start"
    case wakeChunk = "wake.chunk"
    case wakeStop = "wake.stop"
    case wakeDetected = "wake.detected"
}

public struct MessageEnvelope<Body: Codable & Sendable>: Codable, Sendable {
    public let version: UInt16
    public let requestID: String
    public let sessionID: String?
    public let timestamp: Date
    public let body: Body
    public init(version: UInt16 = MiriProtocol.version, requestID: String, sessionID: String? = nil, timestamp: Date = .now, body: Body) {
        self.version = version; self.requestID = requestID; self.sessionID = sessionID; self.timestamp = timestamp; self.body = body
    }
}

public struct EmptyBody: Codable, Equatable, Sendable { public init() {} }
public struct HelloBody: Codable, Equatable, Sendable {
    public let client: String; public let supportedVersions: [UInt16]
    public init(client: String, supportedVersions: [UInt16] = [MiriProtocol.version]) { self.client = client; self.supportedVersions = supportedVersions }
}
public struct HealthBody: Codable, Equatable, Sendable {
    public let status: String; public let providers: [String: String]
    public init(status: String, providers: [String: String] = [:]) { self.status = status; self.providers = providers }
}
public struct AudioStartBody: Codable, Equatable, Sendable {
    public let sampleRate: Int
    public let channels: Int
    public let format: String
    public let vadEndpointing: Bool
    public let minimumSilenceMilliseconds: Int
    public init(sampleRate: Int = 16_000, channels: Int = 1, format: String = "float32le", vadEndpointing: Bool = false, minimumSilenceMilliseconds: Int = 500) {
        self.sampleRate = sampleRate; self.channels = channels; self.format = format
        self.vadEndpointing = vadEndpointing; self.minimumSilenceMilliseconds = minimumSilenceMilliseconds
    }
}
public struct WakeStartBody: Codable, Equatable, Sendable {
    public let sampleRate: Int
    public init(sampleRate: Int = 16_000) { self.sampleRate = sampleRate }
}
public struct TranscriptBody: Codable, Equatable, Sendable {
    public let text: String; public let confidence: Double?
    public init(text: String, confidence: Double? = nil) { self.text = text; self.confidence = confidence }
}
public struct SpeechStartBody: Codable, Equatable, Sendable {
    public let text: String; public let voice: String?
    public init(text: String, voice: String? = nil) { self.text = text; self.voice = voice }
}
public struct ModelProgressBody: Codable, Equatable, Sendable {
    public let model: String; public let downloadedBytes: Int64; public let totalBytes: Int64?
    public init(model: String, downloadedBytes: Int64, totalBytes: Int64? = nil) { self.model = model; self.downloadedBytes = downloadedBytes; self.totalBytes = totalBytes }
}
public struct ErrorBody: Codable, Equatable, Sendable {
    public let code: String; public let message: String; public let recoverable: Bool
    public init(code: String, message: String, recoverable: Bool) { self.code = code; self.message = message; self.recoverable = recoverable }
}

public struct FrameHeader: Codable, Equatable, Sendable {
    public let version: UInt16
    public let requestID: String
    public let sessionID: String?
    public let kind: PayloadKind
    public let messageType: String

    public init(version: UInt16 = MiriProtocol.version, requestID: String, sessionID: String? = nil, kind: PayloadKind, messageType: String) {
        self.version = version; self.requestID = requestID; self.sessionID = sessionID
        self.kind = kind; self.messageType = messageType
    }
}

public struct IPCFrame: Equatable, Sendable {
    public let header: FrameHeader
    public let payload: Data
    public init(header: FrameHeader, payload: Data) { self.header = header; self.payload = payload }
}

public enum FrameError: Error, Equatable { case incomplete, oversized, invalidHeader, unsupportedVersion(UInt16) }

public enum FrameCodec {
    public static func encode(_ frame: IPCFrame) throws -> Data {
        let header = try JSONEncoder().encode(frame.header)
        var body = Data(); body.appendUInt32(UInt32(header.count)); body.append(header); body.append(frame.payload)
        guard body.count <= MiriProtocol.maximumFrameBytes else { throw FrameError.oversized }
        var result = Data(); result.appendUInt32(UInt32(body.count)); result.append(body); return result
    }

    public static func decode(_ data: Data) throws -> IPCFrame {
        guard data.count >= 8 else { throw FrameError.incomplete }
        let bodyLength = Int(data.readUInt32(at: 0))
        guard bodyLength <= MiriProtocol.maximumFrameBytes else { throw FrameError.oversized }
        guard data.count == bodyLength + 4 else { throw FrameError.incomplete }
        let headerLength = Int(data.readUInt32(at: 4))
        guard headerLength > 0, 8 + headerLength <= data.count else { throw FrameError.invalidHeader }
        let header = try JSONDecoder().decode(FrameHeader.self, from: data.subdata(in: 8..<(8 + headerLength)))
        guard header.version == MiriProtocol.version else { throw FrameError.unsupportedVersion(header.version) }
        return IPCFrame(header: header, payload: data.subdata(in: (8 + headerLength)..<data.count))
    }
}

public struct FrameStreamDecoder: Sendable {
    private var buffer = Data()
    public init() {}
    public mutating func append(_ bytes: Data) throws -> [IPCFrame] {
        buffer.append(bytes); var frames: [IPCFrame] = []
        while buffer.count >= 4 {
            let length = Int(buffer.readUInt32(at: 0))
            guard length <= MiriProtocol.maximumFrameBytes else { throw FrameError.oversized }
            guard buffer.count >= length + 4 else { break }
            let encoded = buffer.prefix(length + 4)
            frames.append(try FrameCodec.decode(Data(encoded)))
            buffer.removeFirst(length + 4)
        }
        return frames
    }
}

private extension Data {
    mutating func appendUInt32(_ value: UInt32) { var n = value.bigEndian; Swift.withUnsafeBytes(of: &n) { append(contentsOf: $0) } }
    func readUInt32(at offset: Int) -> UInt32 {
        let lower = index(startIndex, offsetBy: offset); let upper = index(lower, offsetBy: 4)
        return subdata(in: lower..<upper).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).bigEndian }
    }
}
