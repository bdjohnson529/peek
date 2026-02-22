//
//  LLMVisionService.swift
//  peek
//
//  Facade for vision LLM: shared types, image encoding, and delegation to OpenAI or Vertex.
//

import AppKit
import Foundation

/// User-selectable vision backend.
enum VisionProvider: String, CaseIterable {
    case openAI
    case vertex
}

/// Response from the vision LLM: answer text and optional bounding box in image pixel coordinates.
struct VisionResponse: Sendable {
    var answer: String
    var boundingBox: (x: Double, y: Double, width: Double, height: Double)?
}

enum LLMVisionError: Error, LocalizedError {
    case missingAPIKey
    case imageEncodingFailed
    case invalidResponse
    case apiError(statusCode: Int, body: String)
    case emptyContent
    case missingVertexConfig
    case vertexAuthFailed(String)

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
        case .missingVertexConfig:
            return "Vertex AI config missing. Set GOOGLE_CLOUD_PROJECT and GOOGLE_CLOUD_LOCATION (env or plist)."
        case .vertexAuthFailed(let message):
            return "Vertex AI auth failed: \(message)"
        }
    }
}

enum LLMVisionService {
    private static func log(_ message: String) {
        print("[LLMVision] \(message)")
    }

    /// If set (e.g. "1"), the exact PNG sent to the vision API is written to disk for inspection.
    /// Path: ~/Desktop/peek-screenshot-<timestamp>.png
    private static var saveScreenshotToDisk: Bool {
        ProcessInfo.processInfo.environment["PEEK_SAVE_SCREENSHOT"] == "1"
    }

    private static func encodeImageAsBase64(_ image: NSImage) throws -> (base64: String, pngData: Data) {
        log("encoding image to PNG then base64")
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let pngData = bitmap.representation(using: .png, properties: [:]) else {
            log("error: image encoding failed (TIFF/bitmap/PNG)")
            throw LLMVisionError.imageEncodingFailed
        }
        let base64 = pngData.base64EncodedString()
        log("PNG size: \(pngData.count) bytes, dimensions: \(bitmap.pixelsWide)x\(bitmap.pixelsHigh) px")
        return (base64, pngData)
    }

    private static func writeScreenshotToDisk(pngData: Data, imagePixelWidth: Int, imagePixelHeight: Int) {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HH-mm-ss"
        let name = "peek-screenshot-\(formatter.string(from: Date())).png"
        let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first!
        let url = desktop.appendingPathComponent(name)
        do {
            try pngData.write(to: url)
            log("saved screenshot to disk: \(url.path) (\(imagePixelWidth)x\(imagePixelHeight) px, \(pngData.count) bytes)")
        } catch {
            log("failed to save screenshot: \(error)")
        }
    }

    /// Sends the image and question to the selected vision API; returns answer and optional bbox in pixel coordinates.
    static func ask(provider: VisionProvider, image: NSImage, question: String, imagePixelWidth: Int, imagePixelHeight: Int) async throws -> VisionResponse {
        log("ask(provider: \(provider.rawValue)) — question: \"\(question)\", image: \(imagePixelWidth)x\(imagePixelHeight) px")

        let (base64, pngData) = try encodeImageAsBase64(image)
        log("image encoded as base64, length: \(base64.count) chars")
        if saveScreenshotToDisk {
            writeScreenshotToDisk(pngData: pngData, imagePixelWidth: imagePixelWidth, imagePixelHeight: imagePixelHeight)
        }

        switch provider {
        case .openAI:
            let result = try await OpenAIVisionClient.ask(imageBase64: base64, question: question, imagePixelWidth: imagePixelWidth, imagePixelHeight: imagePixelHeight)
            log("result — answer: \"\(result.answer)\"")
            if let bbox = result.boundingBox {
                log("result — boundingBox: x=\(bbox.x), y=\(bbox.y), width=\(bbox.width), height=\(bbox.height)")
            } else {
                log("result — boundingBox: nil")
            }
            return result
        case .vertex:
            let result = try await VertexVisionClient.ask(imageBase64: base64, question: question, imagePixelWidth: imagePixelWidth, imagePixelHeight: imagePixelHeight)
            log("result — answer: \"\(result.answer)\"")
            if let bbox = result.boundingBox {
                log("result — boundingBox: x=\(bbox.x), y=\(bbox.y), width=\(bbox.width), height=\(bbox.height)")
            } else {
                log("result — boundingBox: nil")
            }
            return result
        }
    }
}
