import Foundation

public struct Rect: Codable, Sendable, Equatable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var centerX: Double { x + width / 2.0 }
    public var centerY: Double { y + height / 2.0 }
    public var maxX: Double { x + width }
    public var maxY: Double { y + height }
    public var isEmpty: Bool { width <= 1.0 || height <= 1.0 }

    public func intersects(_ other: Rect) -> Bool {
        guard !isEmpty, !other.isEmpty else { return false }
        return x < other.maxX && maxX > other.x && y < other.maxY && maxY > other.y
    }

    public func intersection(_ other: Rect) -> Rect? {
        guard intersects(other) else { return nil }
        let ix = max(x, other.x)
        let iy = max(y, other.y)
        let imaxX = min(maxX, other.maxX)
        let imaxY = min(maxY, other.maxY)
        let w = imaxX - ix
        let h = imaxY - iy
        guard w > 1.0, h > 1.0 else { return nil }
        return Rect(x: ix, y: iy, width: w, height: h)
    }

    public func contains(x px: Double, y py: Double) -> Bool {
        px >= x && px <= maxX && py >= y && py <= maxY
    }

    public var compactString: String {
        "\(Int(x.rounded())),\(Int(y.rounded())) \(Int(width.rounded()))x\(Int(height.rounded()))"
    }
}

public enum OCRMode: String, Codable, Sendable {
    case auto
    case always
    case never
}

public enum SnapshotFormat: String, Codable, Sendable {
    case text
    case json
}

public enum ElementSource: String, Codable, Sendable {
    case ax
    case ocr
}

public struct WindowInfo: Codable, Sendable, Equatable {
    public var id: String
    public var windowNumber: Int
    public var pid: Int32
    public var appName: String
    public var bundleId: String?
    public var title: String
    public var bounds: Rect
    public var layer: Int
    public var isFocused: Bool
    public var isOnScreen: Bool

    public init(
        id: String,
        windowNumber: Int,
        pid: Int32,
        appName: String,
        bundleId: String?,
        title: String,
        bounds: Rect,
        layer: Int,
        isFocused: Bool,
        isOnScreen: Bool
    ) {
        self.id = id
        self.windowNumber = windowNumber
        self.pid = pid
        self.appName = appName
        self.bundleId = bundleId
        self.title = title
        self.bounds = bounds
        self.layer = layer
        self.isFocused = isFocused
        self.isOnScreen = isOnScreen
    }
}

public struct UIElementNode: Codable, Sendable, Equatable {
    public var id: String
    public var role: String
    public var rawRole: String
    public var label: String
    public var value: String?
    public var bounds: Rect
    public var enabled: Bool
    public var focused: Bool
    public var selected: Bool?
    public var checked: Bool?
    public var actions: [String]
    public var isInteractive: Bool
    public var source: ElementSource
    public var depth: Int

    public init(
        id: String,
        role: String,
        rawRole: String,
        label: String,
        value: String? = nil,
        bounds: Rect,
        enabled: Bool = true,
        focused: Bool = false,
        selected: Bool? = nil,
        checked: Bool? = nil,
        actions: [String] = [],
        isInteractive: Bool = false,
        source: ElementSource = .ax,
        depth: Int = 0
    ) {
        self.id = id
        self.role = role
        self.rawRole = rawRole
        self.label = label
        self.value = value
        self.bounds = bounds
        self.enabled = enabled
        self.focused = focused
        self.selected = selected
        self.checked = checked
        self.actions = actions
        self.isInteractive = isInteractive
        self.source = source
        self.depth = depth
    }
}

public struct ScreenSnapshot: Codable, Sendable, Equatable {
    public var timestamp: String
    public var frontApp: String
    public var frontBundleId: String?
    public var frontPid: Int32
    public var focusedWindow: WindowInfo?
    public var windows: [WindowInfo]
    public var elements: [UIElementNode]
    public var totalVisitedNodes: Int
    public var truncated: Bool
    public var notes: [String]

    public init(
        timestamp: String,
        frontApp: String,
        frontBundleId: String?,
        frontPid: Int32,
        focusedWindow: WindowInfo?,
        windows: [WindowInfo],
        elements: [UIElementNode],
        totalVisitedNodes: Int = 0,
        truncated: Bool = false,
        notes: [String] = []
    ) {
        self.timestamp = timestamp
        self.frontApp = frontApp
        self.frontBundleId = frontBundleId
        self.frontPid = frontPid
        self.focusedWindow = focusedWindow
        self.windows = windows
        self.elements = elements
        self.totalVisitedNodes = totalVisitedNodes
        self.truncated = truncated
        self.notes = notes
    }
}

public struct ScreenDiff: Codable, Sendable, Equatable {
    public var appChanged: Bool
    public var windowChanged: Bool
    public var previousApp: String
    public var currentApp: String
    public var previousWindowTitle: String
    public var currentWindowTitle: String
    public var addedElements: [UIElementNode]
    public var removedCount: Int
    public var changedValues: [String]

    public init(
        appChanged: Bool,
        windowChanged: Bool,
        previousApp: String,
        currentApp: String,
        previousWindowTitle: String,
        currentWindowTitle: String,
        addedElements: [UIElementNode],
        removedCount: Int,
        changedValues: [String]
    ) {
        self.appChanged = appChanged
        self.windowChanged = windowChanged
        self.previousApp = previousApp
        self.currentApp = currentApp
        self.previousWindowTitle = previousWindowTitle
        self.currentWindowTitle = currentWindowTitle
        self.addedElements = addedElements
        self.removedCount = removedCount
        self.changedValues = changedValues
    }
}

public struct MenuItemInfo: Codable, Sendable, Equatable {
    public var id: String
    public var path: String
    public var title: String
    public var shortcut: String?
    public var enabled: Bool

    public init(id: String, path: String, title: String, shortcut: String? = nil, enabled: Bool = true) {
        self.id = id
        self.path = path
        self.title = title
        self.shortcut = shortcut
        self.enabled = enabled
    }
}

public enum ActionKind: String, Codable, Sendable {
    case click
    case doubleClick = "double_click"
    case rightClick = "right_click"
    case clickPoint = "click_point"
    case typeText = "type_text"
    case pressKey = "press_key"
    case scroll
    case focus
    case openApp = "open_app"
    case focusWindow = "focus_window"
    case clickMenu = "click_menu"
}

public enum ScrollDirection: String, Codable, Sendable {
    case up
    case down
    case left
    case right
}

public struct ActionRequest: Codable, Sendable {
    public var action: ActionKind
    public var id: String?
    public var x: Double?
    public var y: Double?
    public var text: String?
    public var clearFirst: Bool?
    public var pressEnter: Bool?
    public var key: String?
    public var modifiers: [String]?
    public var direction: ScrollDirection?
    public var amount: Int?
    public var appName: String?
    public var windowId: String?
    public var menuPath: String?
    public var clickMode: String?
    public var settleMs: Int?
    public var includeSnapshot: Bool?
    public var maxElements: Int?
    public var ocr: OCRMode?

    public init(
        action: ActionKind,
        id: String? = nil,
        x: Double? = nil,
        y: Double? = nil,
        text: String? = nil,
        clearFirst: Bool? = nil,
        pressEnter: Bool? = nil,
        key: String? = nil,
        modifiers: [String]? = nil,
        direction: ScrollDirection? = nil,
        amount: Int? = nil,
        appName: String? = nil,
        windowId: String? = nil,
        menuPath: String? = nil,
        clickMode: String? = nil,
        settleMs: Int? = nil,
        includeSnapshot: Bool? = nil,
        maxElements: Int? = nil,
        ocr: OCRMode? = nil
    ) {
        self.action = action
        self.id = id
        self.x = x
        self.y = y
        self.text = text
        self.clearFirst = clearFirst
        self.pressEnter = pressEnter
        self.key = key
        self.modifiers = modifiers
        self.direction = direction
        self.amount = amount
        self.appName = appName
        self.windowId = windowId
        self.menuPath = menuPath
        self.clickMode = clickMode
        self.settleMs = settleMs
        self.includeSnapshot = includeSnapshot
        self.maxElements = maxElements
        self.ocr = ocr
    }

    enum CodingKeys: String, CodingKey {
        case action
        case id
        case x
        case y
        case text
        case clearFirst = "clear_first"
        case pressEnter = "press_enter"
        case key
        case modifiers
        case direction
        case amount
        case appName = "app_name"
        case windowId = "window_id"
        case menuPath = "menu_path"
        case clickMode = "click_mode"
        case settleMs = "settle_ms"
        case includeSnapshot = "include_snapshot"
        case maxElements = "max_elements"
        case ocr
    }
}

public struct ActionResult: Codable, Sendable {
    public var ok: Bool
    public var message: String
    public var diff: ScreenDiff?
    public var snapshot: ScreenSnapshot?
    public var compactText: String?

    public init(
        ok: Bool,
        message: String,
        diff: ScreenDiff? = nil,
        snapshot: ScreenSnapshot? = nil,
        compactText: String? = nil
    ) {
        self.ok = ok
        self.message = message
        self.diff = diff
        self.snapshot = snapshot
        self.compactText = compactText
    }

    enum CodingKeys: String, CodingKey {
        case ok
        case message
        case diff
        case snapshot
        case compactText = "compact_text"
    }
}

public struct BatchActionRequest: Codable, Sendable {
    public var actions: [ActionRequest]
    public var stopOnError: Bool?
    public var stepSettleMs: Int?
    public var finalSettleMs: Int?
    public var includeSnapshot: Bool?
    public var maxElements: Int?
    public var ocr: OCRMode?

    public init(
        actions: [ActionRequest],
        stopOnError: Bool? = true,
        stepSettleMs: Int? = nil,
        finalSettleMs: Int? = nil,
        includeSnapshot: Bool? = true,
        maxElements: Int? = nil,
        ocr: OCRMode? = nil
    ) {
        self.actions = actions
        self.stopOnError = stopOnError
        self.stepSettleMs = stepSettleMs
        self.finalSettleMs = finalSettleMs
        self.includeSnapshot = includeSnapshot
        self.maxElements = maxElements
        self.ocr = ocr
    }

    enum CodingKeys: String, CodingKey {
        case actions
        case stopOnError = "stop_on_error"
        case stepSettleMs = "step_settle_ms"
        case finalSettleMs = "final_settle_ms"
        case includeSnapshot = "include_snapshot"
        case maxElements = "max_elements"
        case ocr
    }
}

public struct BatchActionResult: Codable, Sendable {
    public var ok: Bool
    public var completedCount: Int
    public var totalCount: Int
    public var steps: [String]
    public var diff: ScreenDiff?
    public var snapshot: ScreenSnapshot?
    public var compactText: String?

    public init(
        ok: Bool,
        completedCount: Int,
        totalCount: Int,
        steps: [String],
        diff: ScreenDiff? = nil,
        snapshot: ScreenSnapshot? = nil,
        compactText: String? = nil
    ) {
        self.ok = ok
        self.completedCount = completedCount
        self.totalCount = totalCount
        self.steps = steps
        self.diff = diff
        self.snapshot = snapshot
        self.compactText = compactText
    }

    enum CodingKeys: String, CodingKey {
        case ok
        case completedCount = "completed_count"
        case totalCount = "total_count"
        case steps
        case diff
        case snapshot
        case compactText = "compact_text"
    }
}

public struct DoctorReport: Codable, Sendable {
    public var accessibilityTrusted: Bool
    public var screenRecordingTrusted: Bool
    public var frontmostApp: String?
    public var visibleWindowCount: Int
    public var notes: [String]

    public init(
        accessibilityTrusted: Bool,
        screenRecordingTrusted: Bool,
        frontmostApp: String?,
        visibleWindowCount: Int,
        notes: [String]
    ) {
        self.accessibilityTrusted = accessibilityTrusted
        self.screenRecordingTrusted = screenRecordingTrusted
        self.frontmostApp = frontmostApp
        self.visibleWindowCount = visibleWindowCount
        self.notes = notes
    }
}
