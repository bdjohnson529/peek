//
//  OpenAIVisionClient.swift
//  peek
//
//  OpenAI GPT-4o vision API: screenshot + question → answer and optional pixel bounding box.
//

import Foundation

enum OpenAIVisionClient {
    private static let infoPlistKey = "OpenAIAPIKey"

    /// API key from OPENAI_API_KEY env or Info.plist key OpenAIAPIKey.
    static var apiKey: String? {
        let fromPlist = Bundle.main.object(forInfoDictionaryKey: infoPlistKey) as? String
        let fromEnv = ProcessInfo.processInfo.environment["OPENAI_API_KEY"]
        if let key = fromPlist, !key.isEmpty {
            return key.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let key = fromEnv, !key.isEmpty {
            return key.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    /// Call from app launch or when debugging API key injection.
    static func debugLogAPIKey(fromPlist: String? = nil, fromEnv: String? = nil) {
        let plist = fromPlist ?? (Bundle.main.object(forInfoDictionaryKey: infoPlistKey) as? String)
        let env = fromEnv ?? ProcessInfo.processInfo.environment["OPENAI_API_KEY"]
        print("[OpenAI API key debug]")
        print("  Info.plist key '\(infoPlistKey)': \(describeKey(plist))")
        print("  ENV OPENAI_API_KEY: \(describeKey(env))")
        if let raw = plist, raw != raw.trimmingCharacters(in: .whitespacesAndNewlines) {
            print("  ⚠️ Info.plist value has leading/trailing whitespace")
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

    private static func log(_ message: String) {
        print("[OpenAIVision] \(message)")
    }

    private static func systemPrompt(imagePixelWidth: Int, imagePixelHeight: Int) -> String {
        """
        The user is asking about a screenshot of their screen (e.g. "Where do I click?", "How do I do this?", "Which button?", "How do I click on this part?"). Your job is to answer in text AND to return a bounding box so the app can highlight the relevant area on screen.

        The image dimensions are \(imagePixelWidth) x \(imagePixelHeight) pixels. Use these exact dimensions for the bounding box.

        Reply with JSON only, no other text. Use this exact format:
        {"answer": "short explanation of where to click or what to do", "boundingBox": {"x": 0, "y": 0, "width": 0, "height": 0}}

        Rules:
        - answer: Brief, helpful text (e.g. "Click the Settings gear in the top-right" or "Use the Search field at the top").
        - boundingBox: REQUIRED whenever the user is asking where to click, which element to use, or how to do something that involves a specific visible UI element. Return the smallest axis-aligned rectangle that tightly encloses the entire target UI element (button, icon, menu item, or field), with no extra padding. Use top-left (x, y) and size (width, height) in PIXEL coordinates: x and width in range [0, \(imagePixelWidth)], y and height in range [0, \(imagePixelHeight)]. Origin (0,0) is the top-left of the image. Only omit boundingBox or set it to null if the question has no single target (e.g. general explanation with no specific element).

        When in doubt, include a bounding box for the most relevant element so we can show a highlight on screen.
        """
    }

    /// Calls OpenAI vision API; returns answer and optional bbox in image pixel coordinates.
    static func ask(imageBase64: String, question: String, imagePixelWidth: Int, imagePixelHeight: Int) async throws -> VisionResponse {
        guard let key = apiKey, !key.isEmpty else {
            log("error: missing API key")
            throw LLMVisionError.missingAPIKey
        }

        let body = buildRequestBody(imageBase64: imageBase64, userMessage: question, imagePixelWidth: imagePixelWidth, imagePixelHeight: imagePixelHeight)
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

        return try parseResponse(data: data, imagePixelWidth: imagePixelWidth, imagePixelHeight: imagePixelHeight)
    }

    private static func buildRequestBody(imageBase64: String, userMessage: String, imagePixelWidth: Int, imagePixelHeight: Int) -> [String: Any] {
        let prompt = systemPrompt(imagePixelWidth: imagePixelWidth, imagePixelHeight: imagePixelHeight)
        return [
            "model": "gpt-4o",
            "messages": [
                ["role": "system", "content": prompt],
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

    private struct OpenAIChoice: Decodable {
        let message: OpenAIMessage
    }

    private struct OpenAIMessage: Decodable {
        let content: String
    }

    private struct OpenAIResponse: Decodable {
        let choices: [OpenAIChoice]?
    }

    private static func parseResponse(data: Data, imagePixelWidth: Int, imagePixelHeight: Int) throws -> VisionResponse {
        log("parsing OpenAI response")
        let decoded = try JSONDecoder().decode(OpenAIResponse.self, from: data)
        guard let content = decoded.choices?.first?.message.content, !content.isEmpty else {
            log("error: choices empty or message content empty")
            throw LLMVisionError.emptyContent
        }
        log("raw LLM content (\(content.count) chars): \(content)")
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
        var bbox: (x: Double, y: Double, width: Double, height: Double)?
        if let box = raw.boundingBox,
           let x = box.x, let y = box.y, let w = box.width, let h = box.height,
           x >= 0, y >= 0, w > 0, h > 0 {
            let maxX = Double(imagePixelWidth)
            let maxY = Double(imagePixelHeight)
            let clampedX = min(max(0, x), maxX - 1)
            let clampedY = min(max(0, y), maxY - 1)
            let clampedW = min(w, maxX - clampedX)
            let clampedH = min(h, maxY - clampedY)
            bbox = (clampedX, clampedY, clampedW, clampedH)
        }
        log("parsed — answer: \"\(answer)\", boundingBox: \(String(describing: bbox))")
        return VisionResponse(answer: answer, boundingBox: bbox)
    }

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
