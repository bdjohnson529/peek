//
//  LLMVisionService.swift
//  peek
//
//  Calls a vision LLM (OpenAI GPT-4o) with a screenshot and user question;
//  returns a text answer and optional normalized bounding box for on-screen highlight.
//

import AppKit
import Foundation

// MARK: - API key storage

enum LLMVisionService {
    static let apiKeyUserDefaultsKey = "peek.openai_api_key"

    static var apiKey: String? {
        get { UserDefaults.standard.string(forKey: apiKeyUserDefaultsKey) }
        set { UserDefaults.standard.set(newValue, forKey: apiKeyUserDefaultsKey) }
    }

    /// Response from the vision LLM: answer text and optional normalized (0–1) bounding box.
    struct VisionResponse: Sendable {
        var answer: String
        var boundingBox: (x: Double, y: Double, width: Double, height: Double)?
    }

    private static let systemPrompt = """
    The user is asking about a screenshot of their screen. Reply with JSON only, no other text.
    Use this exact format: {"answer": "short explanation of where to click or what to do", "boundingBox": {"x": 0.0, "y": 0.0, "width": 0.0, "height": 0.0}}
    - answer: brief text for the user.
    - boundingBox: optional. Top-left (x,y) and size (width, height), normalized 0.0–1.0 relative to the image (0,0 = top-left). Only include if there is a specific UI element to highlight (e.g. a button or area to click). If the question doesn't refer to a visible element, omit boundingBox or set it to null.
    """

    /// Sends the image and question to the vision API; returns answer and optional normalized bbox.
    static func ask(image: NSImage, question: String) async throws -> VisionResponse {
        guard let key = apiKey, !key.isEmpty else {
            throw LLMVisionError.missingAPIKey
        }

        let base64 = try encodeImageAsBase64(image)
        let body = buildOpenAIRequestBody(imageBase64: base64, userMessage: question)
        let (data, response) = try await performRequest(body: body, apiKey: key)

        guard let http = response as? HTTPURLResponse else {
            throw LLMVisionError.invalidResponse
        }
        guard (200 ..< 300).contains(http.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw LLMVisionError.apiError(statusCode: http.statusCode, body: message)
        }

        return try parseOpenAIResponse(data: data)
    }

    // MARK: - Image encoding

    private static func encodeImageAsBase64(_ image: NSImage) throws -> String {
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let pngData = bitmap.representation(using: .png, properties: [:]) else {
            throw LLMVisionError.imageEncodingFailed
        }
        return pngData.base64EncodedString()
    }

    // MARK: - OpenAI request

    private static func buildOpenAIRequestBody(imageBase64: String, userMessage: String) -> [String: Any] {
        [
            "model": "gpt-4o",
            "messages": [
                ["role": "system", "content": systemPrompt],
                [
                    "role": "user",
                    "content": [
                        ["type": "text", "text": userMessage],
                        [
                            "type": "image_url",
                            "image_url": ["url": "data:image/png;base64,\(imageBase64)"]
                        ]
                    ]
                ]
            ],
            "max_tokens": 500
        ]
    }

    private static func performRequest(body: [String: Any], apiKey: String) async throws -> (Data, URLResponse) {
        let url = URL(string: "https://api.openai.com/v1/chat/completions")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await URLSession.shared.data(for: request)
    }

    // MARK: - Response parsing

    private struct OpenAIChoice: Decodable {
        let message: OpenAIMessage
    }

    private struct OpenAIMessage: Decodable {
        let content: String
    }

    private struct OpenAIResponse: Decodable {
        let choices: [OpenAIChoice]?
    }

    private static func parseOpenAIResponse(data: Data) throws -> VisionResponse {
        let decoded = try JSONDecoder().decode(OpenAIResponse.self, from: data)
        guard let content = decoded.choices?.first?.message.content, !content.isEmpty else {
            throw LLMVisionError.emptyContent
        }
        let jsonString = extractJSON(from: content)
        let jsonData = Data(jsonString.utf8)

        struct RawBoundingBox: Decodable {
            let x, y, width, height: Double?
        }
        struct RawResponse: Decodable {
            let answer: String?
            let boundingBox: RawBoundingBox?
        }

        let raw = try JSONDecoder().decode(RawResponse.self, from: jsonData)
        let answer = raw.answer ?? ""
        var bbox: (x: Double, y: Double, width: Double, height: Double)? = nil
        if let box = raw.boundingBox,
           let x = box.x, let y = box.y, let w = box.width, let h = box.height,
           (0...1).contains(x), (0...1).contains(y), (0...1).contains(w), (0...1).contains(h) {
            bbox = (x, y, w, h)
        }
        return VisionResponse(answer: answer, boundingBox: bbox)
    }

    /// Strip optional markdown code fence so we can parse JSON.
    private static func extractJSON(from content: String) -> String {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("```") {
            let rest = trimmed.dropFirst(3)
            let afterLang = rest.hasPrefix("json") ? rest.dropFirst(4) : rest
            let end = afterLang.firstIndex(of: "`") ?? afterLang.endIndex
            return String(afterLang[..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return trimmed
    }
}

enum LLMVisionError: Error, LocalizedError {
    case missingAPIKey
    case imageEncodingFailed
    case invalidResponse
    case apiError(statusCode: Int, body: String)
    case emptyContent

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "OpenAI API key is not set. Add it in the overlay settings."
        case .imageEncodingFailed:
            return "Could not encode the screenshot."
        case .invalidResponse:
            return "Invalid response from the API."
        case .apiError(let code, let body):
            return "API error (\(code)): \(body)"
        case .emptyContent:
            return "The model returned no content."
        }
    }
}
