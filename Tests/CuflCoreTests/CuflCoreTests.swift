import CoreGraphics
import Foundation
import Testing
@testable import CuflCore

@Suite("CuflCore Unit Tests")
struct CuflCoreTests {
    @Test("Rect geometry and intersection")
    func rectGeometry() {
        let a = Rect(x: 100, y: 100, width: 200, height: 100)
        let b = Rect(x: 250, y: 150, width: 100, height: 100)
        let c = Rect(x: 400, y: 400, width: 50, height: 50)

        #expect(a.intersects(b))
        #expect(!a.intersects(c))
        #expect(a.intersection(b) == Rect(x: 250, y: 150, width: 50, height: 50))
        #expect(a.intersection(c) == nil)
        #expect(a.centerX == 200)
        #expect(a.centerY == 150)
        #expect(Rect(x: 0, y: 0, width: 0.5, height: 20).isEmpty)
    }

    @Test("TreePruner role normalization and adjacent label inference")
    func treePrunerRoleAndAdjacentLabelInference() {
        #expect(TreePruner.normalizeRole("AXButton") == "button")
        #expect(TreePruner.normalizeRole("AXTextField") == "text_field")
        #expect(TreePruner.normalizeRole("AXSecureTextField") == "secure_text_field")
        #expect(TreePruner.isInteractive(rawRole: "AXButton", subrole: nil, actions: ["AXPress"]))
        #expect(!TreePruner.isInteractive(rawRole: "AXGroup", subrole: nil, actions: ["AXPress"]))
        #expect(!TreePruner.isInteractive(rawRole: "AXStaticText", subrole: nil, actions: ["AXPress", "AXShowMenu"]))
        #expect(!TreePruner.isInteractive(rawRole: "AXToolbar", subrole: nil, actions: ["AXPress"]))
        #expect(!TreePruner.isInteractive(rawRole: "AXTabGroup", subrole: nil, actions: ["AXPress"]))

        let nodes = [
            UIElementNode(
                id: "e1",
                role: "static_text",
                rawRole: "AXStaticText",
                label: "Username",
                bounds: Rect(x: 100, y: 200, width: 80, height: 22)
            ),
            UIElementNode(
                id: "e2",
                role: "text_field",
                rawRole: "AXTextField",
                label: "",
                bounds: Rect(x: 200, y: 198, width: 220, height: 26),
                isInteractive: true
            ),
            UIElementNode(
                id: "e3",
                role: "static_text",
                rawRole: "AXStaticText",
                label: "API Key",
                bounds: Rect(x: 100, y: 260, width: 70, height: 20)
            ),
            UIElementNode(
                id: "e4",
                role: "secure_text_field",
                rawRole: "AXSecureTextField",
                label: "",
                value: "[REDACTED]",
                bounds: Rect(x: 100, y: 286, width: 240, height: 28),
                isInteractive: true
            )
        ]

        let inferred = TreePruner.inferAdjacentLabels(nodes)
        #expect(inferred[1].label == "Username")
        #expect(inferred[3].label == "API Key")
        #expect(inferred[3].value == "[REDACTED]")
    }

    @Test("TreeFormatter compact snapshot and diff computation")
    func formatterAndDiff() throws {
        let win1 = WindowInfo(
            id: "w1",
            windowNumber: 11,
            pid: 500,
            appName: "Notes",
            bundleId: "com.apple.Notes",
            title: "Meeting\nNotes",
            bounds: Rect(x: 50, y: 40, width: 900, height: 700),
            layer: 0,
            isFocused: true,
            isOnScreen: true
        )
        let win2 = WindowInfo(
            id: "w2",
            windowNumber: 12,
            pid: 501,
            appName: "Safari",
            bundleId: "com.apple.Safari",
            title: "Docs",
            bounds: Rect(x: 100, y: 80, width: 1000, height: 800),
            layer: 0,
            isFocused: false,
            isOnScreen: true
        )

        let snap1 = ScreenSnapshot(
            timestamp: "2026-11-13T00:00:00Z",
            frontApp: "Notes",
            frontBundleId: "com.apple.Notes",
            frontPid: 500,
            focusedWindow: win1,
            windows: [win1, win2],
            elements: [
                UIElementNode(
                    id: "e1",
                    role: "button",
                    rawRole: "AXButton",
                    label: "New Note",
                    bounds: Rect(x: 80, y: 70, width: 90, height: 28),
                    actions: ["press"],
                    isInteractive: true
                ),
                UIElementNode(
                    id: "e2",
                    role: "text_field",
                    rawRole: "AXTextField",
                    label: "Search",
                    value: "",
                    bounds: Rect(x: 80, y: 110, width: 200, height: 28),
                    focused: true,
                    isInteractive: true
                )
            ]
        )

        let formatted = TreeFormatter.formatSnapshot(snap1)
        #expect(formatted.contains("APP: Notes (com.apple.Notes, pid=500)"))
        #expect(formatted.contains("WINDOW: \"Meeting Notes\" (w1, 50,40 900x700)"))
        #expect(formatted.contains("OTHER_WINDOWS: w2=Safari: Docs"))
        #expect(formatted.contains("e1 | button | \"New Note\" | (80,70 90x28) | press"))

        let snap2 = ScreenSnapshot(
            timestamp: "2026-11-13T00:00:01Z",
            frontApp: "Notes",
            frontBundleId: "com.apple.Notes",
            frontPid: 500,
            focusedWindow: win1,
            windows: [win1, win2],
            elements: [
                snap1.elements[0],
                UIElementNode(
                    id: "e2",
                    role: "text_field",
                    rawRole: "AXTextField",
                    label: "Search",
                    value: "roadmap",
                    bounds: Rect(x: 80, y: 110, width: 200, height: 28),
                    focused: true,
                    isInteractive: true
                ),
                UIElementNode(
                    id: "e3",
                    role: "button",
                    rawRole: "AXButton",
                    label: "Clear",
                    bounds: Rect(x: 260, y: 110, width: 20, height: 20),
                    actions: ["press"],
                    isInteractive: true
                )
            ]
        )

        let diff = try #require(TreeFormatter.computeDiff(previous: snap1, current: snap2))
        #expect(diff.addedElements.count == 1)
        #expect(diff.addedElements.first?.label == "Clear")
        #expect(diff.removedCount == 0)
        #expect(diff.changedValues.count == 1)
    }

    @Test("Vision normalized box to macOS screen rect conversion")
    func visionCoordinateConversion() {
        let win = Rect(x: 100, y: 200, width: 1000, height: 500)
        let box = CGRect(x: 0.1, y: 0.7, width: 0.2, height: 0.1)
        let screen = OCRFallback.visionBoxToScreenRect(box, in: win)

        #expect(abs(screen.x - 200) < 0.001)
        #expect(abs(screen.y - 300) < 0.001)
        #expect(abs(screen.width - 200) < 0.001)
        #expect(abs(screen.height - 50) < 0.001)
    }

    @Test("KeyMapper combo and special key parsing")
    func keyMapper() throws {
        let combo1 = try #require(KeyMapper.parseKeySpec(key: "cmd+shift+p"))
        #expect(combo1.keyCode == 35)
        #expect(combo1.flags.contains(.maskCommand))
        #expect(combo1.flags.contains(.maskShift))

        let combo2 = try #require(KeyMapper.parseKeySpec(key: "return", modifiers: []))
        #expect(combo2.keyCode == 36)

        #expect(KeyMapper.parseKeySpec(key: "not_a_real_key") == nil)
    }

    @Test("HTTPRequestParser partial, GET query, and POST body")
    func httpRequestParser() {
        let partial = Data("GET /state?format=text HTTP/1.1\r\nHost: localhost\r\n".utf8)
        #expect(HTTPRequestParser.parse(partial) == .needMoreData)

        let fullGet = Data("GET /state?format=text&max_elements=50 HTTP/1.1\r\nHost: localhost\r\n\r\n".utf8)
        if case .complete(let req) = HTTPRequestParser.parse(fullGet) {
            #expect(req.method == "GET")
            #expect(req.path == "/state")
            #expect(req.query["format"] == "text")
            #expect(req.query["max_elements"] == "50")
        } else {
            Issue.record("Expected complete GET parse")
        }

        let postBody = "{\"action\":\"click\",\"id\":\"e1\"}"
        let postRaw = "POST /act HTTP/1.1\r\nContent-Type: application/json\r\nContent-Length: \(postBody.utf8.count)\r\n\r\n\(postBody)"
        if case .complete(let req) = HTTPRequestParser.parse(Data(postRaw.utf8)) {
            #expect(req.method == "POST")
            #expect(req.path == "/act")
            #expect(String(data: req.body, encoding: .utf8) == postBody)
        } else {
            Issue.record("Expected complete POST parse")
        }
    }

    @Test("MCPServer initialize, notification, and tools/list")
    func mcpServerProtocol() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let service = CuflService(cacheDirectory: tempDir)
        let mcp = MCPServer(service: service)

        let initLine = #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05"}}"#
        let initResp = try #require(mcp.handleMessageLine(initLine))
        #expect(initResp.contains(#""name":"cufl""#))

        let notifLine = #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#
        #expect(mcp.handleMessageLine(notifLine) == nil)

        let listLine = #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#
        let listResp = try #require(mcp.handleMessageLine(listLine))
        #expect(listResp.contains("cufl_get_screen_state"))
        #expect(listResp.contains("cufl_click"))
        #expect(listResp.contains("cufl_type_text"))
        #expect(listResp.contains("cufl_batch"))
    }

    @Test("BatchActionRequest decoding, empty validation, and HTTP /batch routing")
    func batchValidationAndHTTP() throws {
        let json = """
        {
          "actions": [
            {"action": "open_app", "app_name": "Firefox"},
            {"action": "press_key", "key": "cmd+t"},
            {"action": "type_text", "text": "https://youtube.com", "press_enter": true}
          ],
          "step_settle_ms": 80,
          "stop_on_error": true
        }
        """
        let decoded = try JSONDecoder().decode(BatchActionRequest.self, from: Data(json.utf8))
        #expect(decoded.actions.count == 3)
        #expect(decoded.stepSettleMs == 80)
        #expect(decoded.actions[2].pressEnter == true)

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let service = CuflService(cacheDirectory: tempDir)
        let emptyRes = service.performBatch(BatchActionRequest(actions: []))
        #expect(!emptyRes.ok)
        #expect(emptyRes.completedCount == 0)

        let server = HTTPServer(service: service)
        let req = ParsedHTTPRequest(
            method: "POST",
            path: "/batch",
            query: [:],
            headers: [:],
            body: Data(#"{"actions":[]}"#.utf8)
        )
        let resp = server.handleRequest(req)
        #expect(resp.status == 400)
        #expect(String(data: resp.body, encoding: .utf8)?.contains("empty") == true)
    }
}
