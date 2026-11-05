import Foundation

enum WhisperServerError: LocalizedError {
    case badResponse(Int)

    var errorDescription: String? {
        switch self {
        case .badResponse(let status): "辨識伺服器回應 \(status)"
        }
    }
}

/// Requests to a local speech server with whisper-server's /inference interface, which Articulate's TEA server speaks.
enum WhisperServer {
    /// One request to a server with whisper-server's /inference interface (also Articulate's TEA server).
    /// `traditionalize` converts Simplified output; leave it off for models that already write Traditional.
    static func inference(port: Int, samples: [Float], prompt: String, traditionalize: Bool) async throws -> String {
        let wav = wavData(samples)
        let boundary = "articulate-\(UUID().uuidString)"
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        field("response_format", "json")
        field("language", "zh")
        field("temperature", "0.0")
        if !prompt.isEmpty { field("prompt", prompt) }
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\nContent-Type: audio/wav\r\n\r\n".utf8))
        body.append(wav)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/inference")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw WhisperServerError.badResponse(status) }
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let text = (object?["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard traditionalize else { return text }
        return text.applyingTransform(StringTransform("Hans-Hant"), reverse: false) ?? text
    }

    static func wavData(_ samples: [Float]) -> Data {
        var data = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        let bytes = UInt32(samples.count * 2)
        data.append(Data("RIFF".utf8)); u32(36 + bytes); data.append(Data("WAVEfmt ".utf8))
        u32(16); u16(1); u16(1); u32(16000); u32(32000); u16(2); u16(16)
        data.append(Data("data".utf8)); u32(bytes)
        for s in samples {
            let v = Int16(max(-1, min(1, s)) * 32767)
            withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) }
        }
        return data
    }
}
