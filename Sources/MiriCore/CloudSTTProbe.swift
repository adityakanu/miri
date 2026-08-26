import Foundation

/// Verifies a cloud speech endpoint by transcribing a short silent clip.
///
/// This exercises the same URL, model, and credential the worker will use, so a
/// success here means voice input will work. Synchronous by design: callers run
/// it off the main actor.
public enum CloudSTTProbe {
    public static func check(settings: STTCloudSettings, apiKey: String?) -> String {
        guard let url = URL(string: settings.trimmedBaseURL + "/audio/transcriptions") else {
            return "The base URL is not valid."
        }
        let boundary = UUID().uuidString
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        field("model", settings.trimmedModel)
        field("response_format", "json")
        if !settings.language.isEmpty { field("language", settings.language) }
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"probe.wav\"\r\nContent-Type: audio/wav\r\n\r\n".utf8))
        body.append(silentWAV(seconds: 1))
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        if let apiKey, !apiKey.isEmpty { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        request.httpBody = body
        request.timeoutInterval = 20

        let semaphore = DispatchSemaphore(value: 0)
        // The completion handler runs on a URLSession queue, so the result
        // crosses a concurrency boundary and needs real protection.
        let outcome = Outcome()
        URLSession.shared.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }
            if let error { outcome.set("Could not reach the endpoint: \(error.localizedDescription)"); return }
            guard let http = response as? HTTPURLResponse else { outcome.set("The endpoint returned no HTTP response."); return }
            switch http.statusCode {
            case 200..<300: outcome.set("Connected. The endpoint accepted a test transcription.")
            case 401, 403: outcome.set("The endpoint rejected the API key (\(http.statusCode)). Check the key.")
            case 404: outcome.set("Not found (404). Check the base URL and model name.")
            case 429: outcome.set("Rate limited (429). The credentials work, but the quota is exhausted.")
            default:
                let detail = data.map { String(decoding: $0.prefix(160), as: UTF8.self) } ?? ""
                outcome.set("The endpoint returned \(http.statusCode). \(detail)")
            }
        }.resume()
        _ = semaphore.wait(timeout: .now() + 25)
        return outcome.value
    }

    private final class Outcome: @unchecked Sendable {
        private let lock = NSLock()
        private var message = "The request did not complete."
        func set(_ value: String) { lock.withLock { message = value } }
        var value: String { lock.withLock { message } }
    }

    /// Minimal 16 kHz mono 16-bit WAV of silence, built without AVFoundation.
    static func silentWAV(seconds: Int) -> Data {
        let sampleRate = 16_000, channels = 1, bitsPerSample = 16
        let frames = sampleRate * seconds
        let dataBytes = frames * channels * bitsPerSample / 8
        var data = Data()
        func ascii(_ text: String) { data.append(Data(text.utf8)) }
        func uint32(_ value: Int) { withUnsafeBytes(of: UInt32(value).littleEndian) { data.append(contentsOf: $0) } }
        func uint16(_ value: Int) { withUnsafeBytes(of: UInt16(value).littleEndian) { data.append(contentsOf: $0) } }
        ascii("RIFF"); uint32(36 + dataBytes); ascii("WAVE")
        ascii("fmt "); uint32(16); uint16(1); uint16(channels)
        uint32(sampleRate); uint32(sampleRate * channels * bitsPerSample / 8)
        uint16(channels * bitsPerSample / 8); uint16(bitsPerSample)
        ascii("data"); uint32(dataBytes)
        data.append(Data(repeating: 0, count: dataBytes))
        return data
    }
}
