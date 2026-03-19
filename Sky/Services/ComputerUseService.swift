import Accessibility
import AppKit
import ScreenCaptureKit

/// Primary computer-use service — Accessibility Tree first, vision fallback.
/// AX path: instant, free, works for all native apps and most web content.
/// Vision path: screenshot + Claude vision, used only when AX finds nothing.
@MainActor
final class ComputerUseService {
    static let shared = ComputerUseService()
    private init() {}

    // MARK: - Public Types

    struct AXElement: @unchecked Sendable {
        let element: AXUIElement
        let label: String
        let role: String
        let position: CGPoint   // centre in global screen coordinates
        let size: CGSize
    }

    enum ClickMethod {
        case axPress         // AXUIElementPerformAction kAXPressAction
        case axCGEvent       // CGEvent at AX-provided coordinates
        case visionCGEvent   // CGEvent at vision-derived coordinates
    }

    struct ClickResult {
        let label: String
        let method: ClickMethod
    }

    enum ComputerUseError: Error, LocalizedError {
        case noFrontmostApp
        case elementNotFound(String)
        case clickFailed
        case visionFailed(String)
        case screenCaptureFailed
        case permissionDenied

        var errorDescription: String? {
            switch self {
            case .noFrontmostApp:         return "No app is currently active"
            case .elementNotFound(let q): return "Could not find '\(q)' on screen"
            case .clickFailed:            return "Click action failed"
            case .visionFailed(let msg):  return msg
            case .screenCaptureFailed:    return "Could not capture screen"
            case .permissionDenied:       return "Accessibility permission required"
            }
        }
    }

    // MARK: - Main Entry Point

    /// Finds and clicks a UI element matching `instruction`.
    /// Tries Accessibility Tree first, falls back to vision if nothing found.
    func findAndClick(instruction: String) async throws -> ClickResult {
        print("🟢 [ComputerUse] findAndClick: '\(instruction)'")
        guard AXIsProcessTrusted() else {
            throw ComputerUseError.permissionDenied
        }

        // AX fast path
        if let result = try? await findAndClickViaAccessibility(instruction: instruction) {
            return result
        }

        // Vision fallback
        print("🟢 [ComputerUse] AX found nothing — trying vision fallback")
        return try await findAndClickViaVision(instruction: instruction)
    }

    // MARK: - Accessibility Tree Path

    func findAndClickViaAccessibility(instruction: String) async throws -> ClickResult {
        guard let app = NSWorkspace.shared.frontmostApplication else {
            throw ComputerUseError.noFrontmostApp
        }
        print("🟢 [AX] Scanning: \(app.localizedName ?? "unknown")")

        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        let elements = collectInteractiveElements(from: axApp, depth: 0)
        print("🟢 [AX] Found \(elements.count) interactive elements")
        elements.forEach { print("🟢 [AX]   '\($0.label)' role=\($0.role)") }

        guard let best = bestMatch(for: instruction, in: elements) else {
            throw ComputerUseError.elementNotFound(instruction)
        }
        print("🟢 [AX] Best match: '\(best.label)' at \(best.position)")

        // Try AX press action first (works for buttons, links, menu items)
        let pressResult = AXUIElementPerformAction(best.element, kAXPressAction as CFString)
        if pressResult == .success {
            print("🟢 [AX] Press action succeeded")
            return ClickResult(label: best.label, method: .axPress)
        }

        // Fall back to CGEvent at AX-provided coordinates
        print("🟢 [AX] Press failed (\(pressResult.rawValue)) — CGEvent at \(best.position)")
        try postMouseClick(at: best.position)
        return ClickResult(label: best.label, method: .axCGEvent)
    }

    // MARK: - AX Tree Walker

    private func collectInteractiveElements(from element: AXUIElement, depth: Int) -> [AXElement] {
        guard depth < 12 else { return [] }
        var results: [AXElement] = []

        let role        = stringAttr(kAXRoleAttribute, of: element) ?? ""
        let title       = stringAttr(kAXTitleAttribute, of: element) ?? ""
        let desc        = stringAttr(kAXDescriptionAttribute, of: element) ?? ""
        let value       = stringAttr(kAXValueAttribute, of: element) ?? ""
        let placeholder = stringAttr(kAXPlaceholderValueAttribute, of: element) ?? ""
        let help        = stringAttr(kAXHelpAttribute, of: element) ?? ""

        let label = [title, desc, value, placeholder, help]
            .first(where: { !$0.isEmpty }) ?? ""

        let interactiveRoles: Set<String> = [
            kAXButtonRole as String,
            "AXLink",
            kAXMenuItemRole as String,
            kAXCheckBoxRole as String,
            kAXRadioButtonRole as String,
            kAXPopUpButtonRole as String,
            kAXComboBoxRole as String,
            kAXTextFieldRole as String,
            "AXSearchField",
            "AXMenuItem",
            "AXMenuButton",
            "AXWebArea",
            "AXGroup",      // web buttons often render as AXGroup
            "AXStaticText"  // clickable text links
        ]

        // Checkboxes and radio buttons are always included even if unlabelled —
        // use a fallback label so they appear in Claude's element list.
        let isSelectable = role == (kAXCheckBoxRole as String) || role == (kAXRadioButtonRole as String)
        let effectiveLabel = label.isEmpty && isSelectable ? "checkbox" : label

        var shouldAdd = interactiveRoles.contains(role) && !effectiveLabel.isEmpty

        // For generic roles, only include if the element is marked enabled
        if role == "AXGroup" || role == "AXStaticText" {
            var enabledRef: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXEnabledAttribute as CFString, &enabledRef)
            shouldAdd = shouldAdd && (enabledRef as? Bool ?? false)
        }

        if shouldAdd {
            var pos = CGPoint.zero
            var size = CGSize.zero
            var posRef: CFTypeRef?
            var sizeRef: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posRef)
            AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef)
            if let p = posRef  { AXValueGetValue(p  as! AXValue, .cgPoint, &pos) }
            if let s = sizeRef { AXValueGetValue(s as! AXValue, .cgSize, &size) }
            let centre = CGPoint(x: pos.x + size.width / 2, y: pos.y + size.height / 2)
            results.append(AXElement(element: element, label: effectiveLabel, role: role,
                                     position: centre, size: size))
        }

        var childrenRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef)
        if let children = childrenRef as? [AXUIElement] {
            for child in children {
                results.append(contentsOf: collectInteractiveElements(from: child, depth: depth + 1))
            }
        }
        return results
    }

    private func stringAttr(_ attr: String, of element: AXUIElement) -> String? {
        var ref: CFTypeRef?
        AXUIElementCopyAttributeValue(element, attr as CFString, &ref)
        return ref as? String
    }

    // MARK: - Internal API for FlowExecutionService

    /// Returns all interactive AX elements from the focused (or main) window of axApp.
    /// Falls back to system-wide AX to reach into sandboxed WebKit content processes
    /// when the app's own tree returns fewer than 20 elements.
    func collectElements(from axApp: AXUIElement) -> [AXElement] {
        var windowRef: CFTypeRef?
        AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &windowRef)
        if windowRef == nil {
            AXUIElementCopyAttributeValue(axApp, kAXMainWindowAttribute as CFString, &windowRef)
        }

        var results: [AXElement]
        if let windowRef {
            results = collectInteractiveElements(from: windowRef as! AXUIElement, depth: 0)
        } else {
            results = collectInteractiveElements(from: axApp, depth: 0)
        }

        // If very few elements found, the browser is sandboxing web content.
        // Use system-wide focus to reach into the WebKit/web content process.
        if results.count < 20 {
            let systemWide = AXUIElementCreateSystemWide()
            var focusedRef: CFTypeRef?
            AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focusedRef)
            if let focusedRef {
                let focused = focusedRef as! AXUIElement
                let webRoot = findWebArea(from: focused) ?? focused
                let webElements = collectInteractiveElements(from: webRoot, depth: 0)
                print("🟢 [AX] System-wide found \(webElements.count) additional elements")
                var seen = Set(results.map { "\($0.role):\($0.label)" })
                for el in webElements {
                    let key = "\(el.role):\(el.label)"
                    if seen.insert(key).inserted {
                        results.append(el)
                    }
                }
            }
        }

        return results
    }

    /// Walks up the AX tree from a focused element to find the web content area root.
    private func findWebArea(from element: AXUIElement) -> AXUIElement? {
        var current = element
        for _ in 0..<15 {
            var roleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(current, kAXRoleAttribute as CFString, &roleRef)
            let role = roleRef as? String ?? ""
            if role == "AXWebArea" || role == "AXScrollArea" {
                return current
            }
            var parentRef: CFTypeRef?
            let result = AXUIElementCopyAttributeValue(current, kAXParentAttribute as CFString, &parentRef)
            guard result == .success, let parentRef else { return nil }
            current = parentRef as! AXUIElement
        }
        return nil
    }

    /// Returns the best matching element for the given target description, or nil.
    func findBestElement(matching target: String, in elements: [AXElement]) -> AXElement? {
        bestMatch(for: target, in: elements)
    }

    /// Posts a left mouse click at the given global screen position.
    func clickAt(_ position: CGPoint) throws {
        try postMouseClick(at: position)
    }

    // MARK: - Matching

    private func bestMatch(for instruction: String, in elements: [AXElement]) -> AXElement? {
        let lower = instruction.lowercased()

        // Role-based shortcut: "checkbox", "axcheckbox", or "select all" → find checkbox or Select all
        if lower.contains("checkbox") || lower == "axcheckbox" || lower.contains("select all") {
            // First try actual AXCheckBox element
            if let checkbox = elements.first(where: { $0.role == kAXCheckBoxRole as String }) {
                print("🟢 [AX] Checkbox found by role at \(checkbox.position)")
                return checkbox
            }
            // Fall back to "Select all" link which also selects the item
            if let selectAll = elements.first(where: { $0.label.lowercased().contains("select all") }) {
                print("🟢 [AX] No checkbox found, using 'Select all' at \(selectAll.position)")
                return selectAll
            }
        }

        let stopWords: Set<String> = [
            "the", "a", "an", "click", "press", "tap", "button", "on",
            "please", "that", "this", "find", "open", "select", "choose", "hit"
        ]
        let keywords = lower
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !stopWords.contains($0) && $0.count > 1 }
        print("🟢 [AX] Keywords: \(keywords)")

        var scored: [(AXElement, Int)] = elements.compactMap { el in
            let elLower = el.label.lowercased()
            var score = 0
            if elLower == lower        { score += 200 }
            if elLower.contains(lower) { score += 80  }
            for kw in keywords {
                if elLower == kw              { score += 60 }
                else if elLower.hasPrefix(kw) { score += 40 }
                else if elLower.contains(kw)  { score += 20 }
            }
            if el.role == kAXButtonRole as String { score += 10 }
            if el.role == "AXLink"                { score += 5  }
            guard score > 0 else { return nil }
            return (el, score)
        }
        scored.sort { $0.1 > $1.1 }
        print("🟢 [AX] Top 3 matches: \(scored.prefix(3).map { "'\($0.0.label)' score=\($0.1)" })")
        return scored.first?.0
    }

    // MARK: - CGEvent Click

    private func postMouseClick(at position: CGPoint) throws {
        // AX coordinates are already in global screen space — no conversion needed.
        print("🟢 [CGEvent] Clicking at \(position)")
        guard let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown,
                                 mouseCursorPosition: position, mouseButton: .left),
              let up   = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp,
                                 mouseCursorPosition: position, mouseButton: .left) else {
            throw ComputerUseError.clickFailed
        }
        down.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.05)
        up.post(tap: .cghidEventTap)
        print("🟢 [CGEvent] Click posted")
    }

    // MARK: - Vision Fallback

    func findAndClickViaVision(instruction: String) async throws -> ClickResult {
        guard CGPreflightScreenCaptureAccess() else {
            CGRequestScreenCaptureAccess()
            throw ComputerUseError.permissionDenied
        }

        let screenshot = try await captureScreen()
        print("🟢 [Vision] Screenshot: \(screenshot.size.width)x\(screenshot.size.height)")

        guard let tiffData = screenshot.tiffRepresentation,
              let bitmap   = NSBitmapImageRep(data: tiffData),
              let jpegData = bitmap.representation(using: .jpeg,
                                                   properties: [.compressionFactor: 0.85]) else {
            throw ComputerUseError.screenCaptureFailed
        }
        let base64 = jpegData.base64EncodedString()

        let w = Int(screenshot.size.width)
        let h = Int(screenshot.size.height)
        let prompt = """
        You are analyzing a macOS screenshot to find a UI element.
        Task: \(instruction)
        Image size: \(w) x \(h) logical points.
        Return ONLY raw JSON, no markdown, no backticks:
        {"found": true, "x": 523, "y": 187, "label": "element description", "confidence": 0.95}
        Rules:
        - x and y are INTEGER logical point coordinates from TOP-LEFT of image
        - x must be 0 to \(w), y must be 0 to \(h)
        - coordinates are the CENTER of the element
        - NOT normalized values — real pixel positions
        - if not found: {"found": false, "x": 0, "y": 0, "label": "", "confidence": 0.0}
        """

        let responseText = try await callVisionAPI(base64Image: base64, prompt: prompt)
        print("🟢 [Vision] API response: \(responseText)")

        let clean = responseText
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let data      = clean.data(using: .utf8),
              let json       = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let found      = json["found"] as? Bool, found,
              let x          = (json["x"] as? NSNumber)?.doubleValue,
              let y          = (json["y"] as? NSNumber)?.doubleValue,
              let label      = json["label"] as? String,
              let confidence = (json["confidence"] as? NSNumber)?.floatValue,
              confidence > 0.4 else {
            throw ComputerUseError.elementNotFound(instruction)
        }

        print("🟢 [Vision] Found '\(label)' at (\(x), \(y)) confidence=\(confidence)")

        // Vision coordinates are logical points in the screenshot (top-left origin).
        // Add the focused window's origin to get global screen coordinates.
        let globalPoint = try visionToScreenCoordinates(CGPoint(x: x, y: y))
        try postMouseClick(at: globalPoint)
        return ClickResult(label: label, method: .visionCGEvent)
    }

    private func visionToScreenCoordinates(_ point: CGPoint) throws -> CGPoint {
        guard let app = NSWorkspace.shared.frontmostApplication else {
            throw ComputerUseError.noFrontmostApp
        }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var windowRef: CFTypeRef?
        AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &windowRef)
        guard let windowRef else { return point }
        let window = windowRef as! AXUIElement // safe: AX guarantees this type
        var posRef: CFTypeRef?
        AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &posRef)
        var origin = CGPoint.zero
        if let posRef { AXValueGetValue(posRef as! AXValue, .cgPoint, &origin) }
        let result = CGPoint(x: origin.x + point.x, y: origin.y + point.y)
        print("🟢 [Vision] Coord: vision(\(point.x),\(point.y)) + windowOrigin(\(origin.x),\(origin.y)) = global(\(result.x),\(result.y))")
        return result
    }

    private func callVisionAPI(base64Image: String, prompt: String) async throws -> String {
        let config = ConfigService.shared.config
        if config.aiProvider == "openai" && !config.openaiApiKey.isEmpty {
            return try await callOpenAIVision(base64Image: base64Image, prompt: prompt)
        }
        return try await callAnthropicVision(base64Image: base64Image, prompt: prompt)
    }

    private func callAnthropicVision(base64Image: String, prompt: String) async throws -> String {
        let body: [String: Any] = [
            "model": Constants.API.model,
            "max_tokens": 256,
            "messages": [[
                "role": "user",
                "content": [
                    ["type": "image", "source": [
                        "type": "base64",
                        "media_type": "image/jpeg",
                        "data": base64Image
                    ]],
                    ["type": "text", "text": prompt]
                ]
            ]]
        ]
        var request = URLRequest(url: URL(string: Constants.API.anthropicBaseURL)!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(ConfigService.shared.config.anthropicAPIKey, forHTTPHeaderField: "x-api-key")
        request.setValue(Constants.API.anthropicVersion, forHTTPHeaderField: "anthropic-version")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, _) = try await URLSession.shared.data(for: request)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let content = (json?["content"] as? [[String: Any]])?.first
        return content?["text"] as? String ?? ""
    }

    private func callOpenAIVision(base64Image: String, prompt: String) async throws -> String {
        let body: [String: Any] = [
            "model": Constants.OpenAI.model,
            "max_tokens": 256,
            "messages": [[
                "role": "user",
                "content": [
                    ["type": "image_url", "image_url": [
                        "url": "data:image/jpeg;base64,\(base64Image)"
                    ]],
                    ["type": "text", "text": prompt]
                ]
            ]]
        ]
        var request = URLRequest(url: URL(string: Constants.OpenAI.baseURL)!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(ConfigService.shared.config.openaiApiKey)",
                         forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, _) = try await URLSession.shared.data(for: request)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let choices = json?["choices"] as? [[String: Any]]
        let message = choices?.first?["message"] as? [String: Any]
        return message?["content"] as? String ?? ""
    }

    // MARK: - Screen Capture

    func captureScreen() async throws -> NSImage {
        guard let app = NSWorkspace.shared.frontmostApplication else {
            throw ComputerUseError.noFrontmostApp
        }
        if #available(macOS 14.0, *) {
            return try await captureViaScreenCaptureKit(pid: app.processIdentifier)
        } else {
            return try captureFallback()
        }
    }

    @available(macOS 14.0, *)
    private func captureViaScreenCaptureKit(pid: pid_t) async throws -> NSImage {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true)
        guard let window = content.windows.first(where: {
            $0.owningApplication?.processID == pid
        }) else {
            throw ComputerUseError.screenCaptureFailed
        }
        let config = SCStreamConfiguration()
        config.scalesToFit = false
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let cgImage = try await SCScreenshotManager.captureImage(
            contentFilter: filter, configuration: config)
        return NSImage(cgImage: cgImage, size: window.frame.size)
    }

    private func captureFallback() throws -> NSImage {
        let bounds = CGDisplayBounds(CGMainDisplayID())
        guard let cgImage = CGWindowListCreateImage(
            bounds, .optionAll, kCGNullWindowID, .bestResolution) else {
            throw ComputerUseError.screenCaptureFailed
        }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }
}
