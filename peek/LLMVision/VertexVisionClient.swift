//
//  VertexVisionClient.swift
//  peek
//
//  Google Vertex AI Gemini bounding-box API: screenshot + question → answer and optional pixel bbox.
//  Uses 0–1000 normalized coordinates; converts to image pixel space.
//  Auth: Application Default Credentials via `gcloud auth application-default login`, or set GOOGLE_APPLICATION_CREDENTIALS to a service account JSON path.
//

import Foundation

enum VertexVisionClient {
    private static let projectKey = "GOOGLE_CLOUD_PROJECT"
    private static let locationKey = "GOOGLE_CLOUD_LOCATION"
    private static let defaultLocation = "us-central1"

    private static func log(_ message: String) {
        print("[VertexVision] \(message)")
    }

    /// Project ID from env or Info.plist.
    private static var projectID: String? {
        (Bundle.main.object(forInfoDictionaryKey: projectKey) as? String)
            ?? ProcessInfo.processInfo.environment[projectKey]
            ?? ProcessInfo.processInfo.environment["GCLOUD_PROJECT"]
    }

    /// Location from env or Info.plist (e.g. us-central1).
    private static var location: String {
        (Bundle.main.object(forInfoDictionaryKey: locationKey) as? String)
            ?? ProcessInfo.processInfo.environment[locationKey]
            ?? defaultLocation
    }

    /// Obtain Bearer token using Application Default Credentials (gcloud auth application-default login or GOOGLE_APPLICATION_CREDENTIALS).
    private static func getAccessToken() async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/gcloud")
        process.arguments = ["auth", "application-default", "print-access-token"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw LLMVisionError.vertexAuthFailed("gcloud auth application-default print-access-token failed (run: gcloud auth application-default login)")
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let token = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty else {
            throw LLMVisionError.vertexAuthFailed("empty access token")
        }
        return token
    }

    /// Calls Vertex AI generateContent (Gemini); returns answer and optional bbox in image pixel coordinates.
    static func ask(imageBase64: String, question: String, imagePixelWidth: Int, imagePixelHeight: Int) async throws -> VisionResponse {
        guard let project = projectID, !project.isEmpty else {
            log("error: missing project ID")
            throw LLMVisionError.missingVertexConfig
        }
        let loc = location
        let token = try await getAccessToken()
        log("sending request to Vertex AI (project: \(project), location: \(loc))")

        let url = URL(string: "https://\(loc)-aiplatform.googleapis.com/v1/projects/\(project)/locations/\(loc)/publishers/google/models/gemini-2.5-flash:generateContent")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try buildRequestBody(imageBase64: imageBase64, question: question)
        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw LLMVisionError.invalidResponse
        }
        log("HTTP status: \(http.statusCode)")
        guard (200 ..< 300).contains(http.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw LLMVisionError.apiError(statusCode: http.statusCode, body: message)
        }

        return try parseResponse(data: data, imagePixelWidth: imagePixelWidth, imagePixelHeight: imagePixelHeight)
    }

    private static func buildRequestBody(imageBase64: String, question: String) throws -> Data {
        let systemInstruction = """
        You are helping with a screenshot of the user's screen. Reply with JSON only. \
        Include a short "answer" and a single bounding box "box_2d" for the UI element the user is asking about. \
        box_2d format: [y_min, x_min, y_max, x_max] in normalized 0-1000 coordinates (top-left origin). \
        Return only one box; omit box_2d if there is no single target element.
        """
        let body: [String: Any] = [
            "contents": [
                [
                    "role": "user",
                    "parts": [
                        ["inlineData": ["mimeType": "image/png", "data": imageBase64]],
                        ["text": question]
                    ]
                ]
            ],
            "systemInstruction": [
                "parts": [["text": systemInstruction]]
            ],
            "generationConfig": [
                "temperature": 0.5,
                "maxOutputTokens": 500,
                "responseMimeType": "application/json",
                "responseSchema": [
                    "type": "OBJECT",
                    "properties": [
                        "answer": ["type": "STRING"],
                        "box_2d": [
                            "type": "ARRAY",
                            "items": ["type": "INTEGER"],
                            "description": "Optional [y_min, x_min, y_max, x_max] 0-1000"
                        ]
                    ],
                    "required": ["answer"]
                ] as [String: Any]
            ] as [String: Any]
        ]
        return try JSONSerialization.data(withJSONObject: body)
    }

    private struct VertexCandidate: Decodable {
        let content: VertexContent?
    }
    private struct VertexContent: Decodable {
        let parts: [VertexPart]?
    }
    private struct VertexPart: Decodable {
        let text: String?
    }
    private struct VertexResponse: Decodable {
        let candidates: [VertexCandidate]?
    }
    private struct RawVertexOutput: Decodable {
        let answer: String?
        let box_2d: [Int]?
    }

    private static func parseResponse(data: Data, imagePixelWidth: Int, imagePixelHeight: Int) throws -> VisionResponse {
        let decoded = try JSONDecoder().decode(VertexResponse.self, from: data)
        guard let text = decoded.candidates?.first?.content?.parts?.first?.text, !text.isEmpty else {
            throw LLMVisionError.emptyContent
        }
        let jsonData = Data(text.trimmingCharacters(in: .whitespacesAndNewlines).utf8)
        let raw = try JSONDecoder().decode(RawVertexOutput.self, from: jsonData)
        let answer = raw.answer ?? ""

        var bbox: (x: Double, y: Double, width: Double, height: Double)?
        if let box = raw.box_2d, box.count >= 4 {
            let yMin = box[0]
            let xMin = box[1]
            let yMax = box[2]
            let xMax = box[3]
            let w = Double(imagePixelWidth)
            let h = Double(imagePixelHeight)
            let xMinPx = Double(xMin) / 1000.0 * w
            let yMinPx = Double(yMin) / 1000.0 * h
            let xMaxPx = Double(xMax) / 1000.0 * w
            let yMaxPx = Double(yMax) / 1000.0 * h
            let width = xMaxPx - xMinPx
            let height = yMaxPx - yMinPx
            if width > 0, height > 0 {
                bbox = (xMinPx, yMinPx, width, height)
            }
        }
        log("parsed — answer: \"\(answer)\", boundingBox: \(String(describing: bbox))")
        return VisionResponse(answer: answer, boundingBox: bbox)
    }
}
