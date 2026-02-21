//
//  LLMVisionService.swift
//  peek
//
//  Calls a vision LLM (OpenAI GPT-4o) with a screenshot and user question;
//  returns a text answer and optional normalized bounding box for on-screen highlight.
//

import AppKit
import Foundation

// MARK: - API key storage (Run scheme env or Info.plist)

enum LLMVisionService {
    private static let infoPlistKey = "OpenAIAPIKey"

    /// API key is read from OPENAI_API_KEY environment variable (set in Run scheme: Edit Scheme → Run → Arguments → Environment Variables)
    /// or from Info.plist key OpenAIAPIKey if present.
    static var apiKey: String? {
        // Debug: trace where the key comes from and if it looks valid
        let fromPlist = Bundle.main.object(forInfoDictionaryKey: infoPlistKey) as? String
        let fromEnv = ProcessInfo.processInfo.environment["OPENAI_API_KEY"]
        debugLogAPIKey(fromPlist: fromPlist, fromEnv: fromEnv)

        if let key = fromPlist, !key.isEmpty {
            return key.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let key = fromEnv, !key.isEmpty {
            return key.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    /// Call from app launch or when debugging API key injection (Info.plist vs xcconfig).
    static func debugLogAPIKey(fromPlist: String? = nil, fromEnv: String? = nil) {
        let plist = fromPlist ?? (Bundle.main.object(forInfoDictionaryKey: infoPlistKey) as? String)
        let env = fromEnv ?? ProcessInfo.processInfo.environment["OPENAI_API_KEY"]
        print("[OpenAI API key debug]")
        print("  Info.plist key '\(infoPlistKey)': \(describeKey(plist))")
        print("  ENV OPENAI_API_KEY: \(describeKey(env))")
        if let raw = plist {
            if raw != raw.trimmingCharacters(in: .whitespacesAndNewlines) {
                print("  ⚠️ Info.plist value has leading/trailing whitespace")
            }
        }
        if let raw = env, raw != raw.trimmingCharacters(in: .whitespacesAndNewlines) {
            print("  ⚠️ ENV value has leading/trailing whitespace")
        }
    }

    private static func describeKey(_ value: String?) -> String {
        guard let v = value else { return "nil" }
        if v.isEmpty { return "empty string" }
        let trimmed = v.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasSpace = v != trimmed
        let preview = v.count > 11 ? "\(v.prefix(7))…\(v.suffix(4))" : "\(v.prefix(7))…"
        return "length=\(v.count)\(hasSpace ? ", has leading/trailing space" : ""), preview=\"\(preview)\""
    }

    /// Response from the vision LLM: answer text and optional normalized (0–1) bounding box.
    struct VisionResponse: Sendable {
        var answer: String
        var boundingBox: (x: Double, y: Double, width: Double, height: Double)?
    }

    private static let systemPrompt = """
    The user is asking about a screenshot of their screen (e.g. "Where do I click?", "How do I do this?", "Which button?", "How do I click on this part?"). Your job is to answer in text AND to return a bounding box so the app can highlight the relevant area on screen.

    Reply with JSON only, no other text. Use this exact format:
    {"answer": "short explanation of where to click or what to do", "boundingBox": {"x": 0.0, "y": 0.0, "width": 0.0, "height": 0.0}}

    Rules:
    - answer: Brief, helpful text (e.g. "Click the Settings gear in the top-right" or "Use the Search field at the top").
    - boundingBox: REQUIRED whenever the user is asking where to click, which element to use, or how to do something that involves a specific visible UI element. Give the region the user should interact with (button, menu item, icon, field, etc.). Use top-left (x, y) and size (width, height), all normalized 0.0–1.0 relative to the image (0,0 = top-left of image, 1,1 = bottom-right). Only omit boundingBox or set it to null if the question has no single target (e.g. general explanation with no specific element).

    When in doubt, include a bounding box for the most relevant element so we can show a highlight on screen.
    """

    private static func log(_ message: String) {
        print("[LLMVision] \(message)")
    }

    /// Sends the image and question to the vision API; returns answer and optional normalized bbox.
    static func ask(image: NSImage, question: String) async throws -> VisionResponse {
        log("ask() called — question: \"\(question)\"")
        log("input image size: \(image.size.width)x\(image.size.height) points")

        guard let key = apiKey, !key.isEmpty else {
            log("error: missing API key")
            throw LLMVisionError.missingAPIKey
        }

        let base64 = try encodeImageAsBase64(image)
        log("image encoded as base64, length: \(base64.count) chars")

        let body = buildOpenAIRequestBody(imageBase64: base64, userMessage: question)
        log("sending request to OpenAI (model: gpt-4o, user message length: \(question.count))")

        let (data, response) = try await performRequest(body: body, apiKey: key)

        guard let http = response as? HTTPURLResponse else {
            log("error: response was not HTTPURLResponse")
            throw LLMVisionError.invalidResponse
        }
        log("HTTP status: \(http.statusCode), response body length: \(data.count) bytes")

        guard (200 ..< 300).contains(http.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "Unknown error"
            log("API error body: \(message)")
            throw LLMVisionError.apiError(statusCode: http.statusCode, body: message)
        }

        let result = try parseOpenAIResponse(data: data)
        log("result — answer: \"\(result.answer)\"")
        if let bbox = result.boundingBox {
            log("result — boundingBox: x=\(bbox.x), y=\(bbox.y), width=\(bbox.width), height=\(bbox.height)")
        } else {
            log("result — boundingBox: nil")
        }
        return result
    }

    // MARK: - Image encoding

    private static func encodeImageAsBase64(_ image: NSImage) throws -> String {
        log("encoding image to PNG then base64")
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let pngData = bitmap.representation(using: .png, properties: [:]) else {
            log("error: image encoding failed (TIFF/bitmap/PNG)")
            throw LLMVisionError.imageEncodingFailed
        }
        let base64 = pngData.base64EncodedString()
        log("PNG size: \(pngData.count) bytes")
        return base64
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
        log("POST \(url.absoluteString), body size: \(request.httpBody?.count ?? 0) bytes")
        let (data, response) = try await URLSession.shared.data(for: request)
        log("request completed")
        return (data, response)
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
        log("parsing OpenAI response")
        let decoded = try JSONDecoder().decode(OpenAIResponse.self, from: data)
        guard let content = decoded.choices?.first?.message.content, !content.isEmpty else {
            log("error: choices empty or message content empty")
            throw LLMVisionError.emptyContent
        }
        log("raw LLM content (\(content.count) chars): \(content)")
        let jsonString = extractJSON(from: content)
        log("extracted JSON length: \(jsonString.count)")
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
        log("parsed — answer: \"\(answer)\", boundingBox present: \(bbox != nil)")
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
            return "OpenAI API key is not set. Set OPENAI_API_KEY in the Run scheme: Product → Scheme → Edit Scheme → Run → Arguments → Environment Variables."
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
