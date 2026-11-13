import CoreGraphics
import Foundation
import ScreenCaptureKit
import Vision

public enum OCRFallback {
    public static func isScreenRecordingTrusted() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    @discardableResult
    public static func requestScreenRecordingAccess() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    /// Converts a Vision normalized bounding box (bottom-left origin, 0...1) into top-left macOS screen coordinates.
    public static func visionBoxToScreenRect(_ box: CGRect, in windowBounds: Rect) -> Rect {
        let sx = windowBounds.x + Double(box.origin.x) * windowBounds.width
        let sy = windowBounds.y + (1.0 - Double(box.origin.y) - Double(box.size.height)) * windowBounds.height
        let sw = Double(box.size.width) * windowBounds.width
        let sh = Double(box.size.height) * windowBounds.height
        return Rect(x: sx, y: sy, width: sw, height: sh)
    }

    public static func recognizeWindowText(
        window: WindowInfo,
        startingIdIndex: Int,
        maxItems: Int = 80
    ) -> (elements: [UIElementNode], note: String?) {
        guard isScreenRecordingTrusted() else {
            return (
                [],
                "OCR fallback skipped: Screen Recording permission is not granted (System Settings > Privacy & Security > Screen Recording)."
            )
        }

        let captureResult = captureWindowCGImage(windowNumber: window.windowNumber, bounds: window.bounds)
        switch captureResult {
        case .failure(let error):
            return ([], "OCR capture failed: \(error.localizedDescription)")
        case .success(let cgImage):
            return recognizeText(
                in: cgImage,
                windowBounds: window.bounds,
                startingIdIndex: startingIdIndex,
                maxItems: maxItems
            )
        }
    }

    private static func recognizeText(
        in cgImage: CGImage,
        windowBounds: Rect,
        startingIdIndex: Int,
        maxItems: Int
    ) -> (elements: [UIElementNode], note: String?) {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return ([], "Vision OCR failed: \(error.localizedDescription)")
        }

        guard let observations = request.results, !observations.isEmpty else {
            return ([], "OCR found no readable text in window.")
        }

        // Sort top-to-bottom, then left-to-right for natural reading order
        let sorted = observations.sorted { a, b in
            let ay = 1.0 - a.boundingBox.midY
            let by = 1.0 - b.boundingBox.midY
            if abs(ay - by) > 0.015 {
                return ay < by
            }
            return a.boundingBox.minX < b.boundingBox.minX
        }

        var nodes: [UIElementNode] = []
        var nextIndex = startingIdIndex

        for obs in sorted {
            if nodes.count >= maxItems { break }
            guard let candidate = obs.topCandidates(1).first else { continue }
            let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }

            let rect = visionBoxToScreenRect(obs.boundingBox, in: windowBounds)
            guard !rect.isEmpty else { continue }

            let node = UIElementNode(
                id: "e\(nextIndex)",
                role: "ocr_text",
                rawRole: "VisionOCRText",
                label: text,
                value: nil,
                bounds: rect,
                enabled: true,
                focused: false,
                selected: nil,
                checked: nil,
                actions: ["click"],
                isInteractive: true,
                source: .ocr,
                depth: 1
            )
            nodes.append(node)
            nextIndex += 1
        }

        return (nodes, nodes.isEmpty ? nil : "Augmented with \(nodes.count) local Vision OCR text regions.")
    }

    private final class ImageCaptureBox: @unchecked Sendable {
        var result: Result<CGImage, Error> = .failure(NSError(domain: "cuflllm.ocr", code: -1, userInfo: [NSLocalizedDescriptionKey: "OCR capture timed out"]))
    }

    private static func captureWindowCGImage(windowNumber: Int, bounds: Rect) -> Result<CGImage, Error> {
        let sem = DispatchSemaphore(value: 0)
        let box = ImageCaptureBox()

        Task.detached {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                let filter: SCContentFilter
                let config = SCStreamConfiguration()
                config.showsCursor = false

                if let scWindow = content.windows.first(where: { Int($0.windowID) == windowNumber }) {
                    filter = SCContentFilter(desktopIndependentWindow: scWindow)
                    config.width = max(1, Int(scWindow.frame.width * 2))
                    config.height = max(1, Int(scWindow.frame.height * 2))
                } else if let display = content.displays.first {
                    filter = SCContentFilter(display: display, excludingWindows: [])
                    config.sourceRect = CGRect(x: bounds.x, y: bounds.y, width: bounds.width, height: bounds.height)
                    config.width = max(1, Int(bounds.width * 2))
                    config.height = max(1, Int(bounds.height * 2))
                } else {
                    throw NSError(domain: "cuflllm.ocr", code: -2, userInfo: [NSLocalizedDescriptionKey: "No captureable display or window found"])
                }

                let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                box.result = .success(image)
            } catch {
                box.result = .failure(error)
            }
            sem.signal()
        }

        _ = sem.wait(timeout: .now() + 4.0)
        return box.result
    }
}
