import AppKit
import ApplicationServices
import Darwin
import Foundation

struct Request: Decodable {
  let id: String
  let name: String
  let message: String
  let accountSlot: String
  let accountPath: String
  let selectionPath: String
  let lockPath: String
  let allowBackgroundReuse: Bool?
}

struct BridgeError: LocalizedError {
  let message: String
  var errorDescription: String? { message }
  init(_ message: String) { self.message = message }
}

func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
  var value: CFTypeRef?
  guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else {
    return nil
  }
  return value
}

func string(_ element: AXUIElement, _ name: String) -> String {
  attribute(element, name) as? String ?? ""
}

func children(_ element: AXUIElement) -> [AXUIElement] {
  attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
}

func label(_ element: AXUIElement) -> String {
  let description = string(element, kAXDescriptionAttribute)
  return description.isEmpty ? string(element, kAXTitleAttribute) : description
}

// Control searches avoid walking potentially very large conversation transcripts.
func find(_ root: AXUIElement, matching: (AXUIElement) -> Bool) -> AXUIElement? {
  var pending = [root]
  var visited = 0
  while let element = pending.popLast(), visited < 8000 {
    visited += 1
    if matching(element) { return element }
    if label(element) == "Conversation transcript" { continue }
    pending.append(contentsOf: children(element).reversed())
  }
  return nil
}

func heading(_ root: AXUIElement, name: String) -> Bool {
  find(root) {
    string($0, kAXRoleAttribute) == "AXHeading" && label($0) == name
  } != nil
}

func composer(_ root: AXUIElement) -> AXUIElement? {
  find(root) {
    string($0, kAXRoleAttribute) == kAXTextAreaRole && label($0) == "Prompt"
  }
}

// An app in the background can report no focused window, so its main window is the fallback.
func focusedWindow(_ root: AXUIElement) -> AXUIElement? {
  for name in [kAXFocusedWindowAttribute, kAXMainWindowAttribute] {
    if let value = attribute(root, name), CFGetTypeID(value) == AXUIElementGetTypeID() {
      return unsafeBitCast(value, to: AXUIElement.self)
    }
  }
  return nil
}

func sameWindow(_ root: AXUIElement, _ window: AXUIElement) -> Bool {
  guard let focused = focusedWindow(root) else { return false }
  return CFEqual(focused, window)
}

func sendButton(_ root: AXUIElement) -> AXUIElement? {
  find(root) {
    string($0, kAXRoleAttribute) == kAXButtonRole && label($0) == "Send message"
  }
}

func slice(_ path: String) -> [String: Any]? {
  guard let data = FileManager.default.contents(atPath: path),
    let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
    json["schemaVersion"] as? Int == 1
  else { return nil }
  return json
}

func selected(_ request: Request) -> Bool {
  guard slice(request.accountPath)?["value"] as? String == request.accountSlot,
    let selection = slice(request.selectionPath)?["value"] as? [String: Any]
  else { return false }
  return selection["agentId"] as? String == request.id
}

func waitFor(_ seconds: TimeInterval, condition: () -> Bool) -> Bool {
  let deadline = Date().addingTimeInterval(seconds)
  repeat {
    if condition() { return true }
    RunLoop.current.run(until: Date().addingTimeInterval(0.15))
  } while Date() < deadline
  return false
}

func send(_ request: Request) throws {
  guard request.id.range(of: "^[A-Za-z0-9_-]{1,128}$", options: .regularExpression) != nil,
    !request.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  else {
    throw BridgeError("Choose a bot and enter a message.")
  }
  guard AXIsProcessTrusted() else {
    throw BridgeError(
      "Allow Raycast in System Settings → Privacy & Security → Accessibility, then try again.")
  }

  try FileManager.default.createDirectory(
    atPath: (request.lockPath as NSString).deletingLastPathComponent,
    withIntermediateDirectories: true)
  let lock = Darwin.open(request.lockPath, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
  guard lock >= 0 else { throw BridgeError("Could not create the message lock.") }
  defer { Darwin.close(lock) }
  guard flock(lock, LOCK_EX | LOCK_NB) == 0 else {
    throw BridgeError("Another message is being sent. Wait for it to finish.")
  }

  let bundleID = "com.anysphere.sand"
  guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
    throw BridgeError("Install and sign in to the Grok Bot macOS app first.")
  }
  // Electron publishes window content to Accessibility in the background only on request.
  let publishContent = { (root: AXUIElement) in
    AXUIElementSetMessagingTimeout(root, 1)
    AXUIElementSetAttributeValue(root, "AXManualAccessibility" as CFString, kCFBooleanTrue)
  }
  let running = { NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first }
  let readyWindow = { (root: AXUIElement) -> AXUIElement? in
    guard let window = focusedWindow(root), selected(request),
      heading(window, name: request.name), composer(window) != nil
    else { return nil }
    return window
  }
  var targetWindow: AXUIElement?
  if request.allowBackgroundReuse == true, let app = running(), selected(request) {
    let root = AXUIElementCreateApplication(app.processIdentifier)
    publishContent(root)
    // The first request after Grok Bot starts takes a few seconds to publish the content.
    _ = waitFor(
      4,
      condition: {
        targetWindow = readyWindow(root)
        return targetWindow != nil
      })
  }
  // The chat link is needed only when Grok Bot does not already show this bot.
  if targetWindow == nil {
    var components = URLComponents(string: "grokbot://app/v1/agent")!
    components.queryItems = [URLQueryItem(name: "id", value: request.id)]
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.activates = false
    var opened = false
    var openError: Error?
    NSWorkspace.shared.open(
      [components.url!], withApplicationAt: appURL, configuration: configuration
    ) { _, error in
      openError = error
      opened = true
    }
    guard waitFor(10, condition: { opened }), openError == nil else {
      throw BridgeError("Grok Bot could not open the selected chat.")
    }
  }
  guard let app = running() else {
    throw BridgeError("Grok Bot is unavailable.")
  }
  let root = AXUIElementCreateApplication(app.processIdentifier)
  publishContent(root)
  guard
    targetWindow != nil
      || waitFor(
        12,
        condition: {
          targetWindow = readyWindow(root)
          return targetWindow != nil
        }), let window = targetWindow
  else {
    throw BridgeError(
      "The selected chat did not become ready. Check Grok Bot and refresh the bot list.")
  }
  let windows = attribute(root, kAXWindowsAttribute) as? [AXUIElement] ?? []
  guard windows.filter({ heading($0, name: request.name) }).count == 1 else {
    throw BridgeError(
      "Multiple Grok windows have this bot name. Close the extra chat windows and try again.")
  }
  guard sameWindow(root, window), let prompt = composer(window) else {
    throw BridgeError("Grok Bot’s message composer is unavailable.")
  }
  guard string(prompt, kAXValueAttribute).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
    sendButton(window) == nil
  else {
    throw BridgeError(
      "This chat already has a draft or attachment. Send or clear it in Grok Bot, then try again.")
  }

  guard selected(request), sameWindow(root, window), heading(window, name: request.name) else {
    throw BridgeError("The active chat changed. Select the bot again before sending.")
  }
  let result = AXUIElementSetAttributeValue(
    prompt, kAXValueAttribute as CFString, request.message as CFString)
  guard result == .success else {
    throw BridgeError(
      "Grok Bot could not accept text through Accessibility. Check Raycast’s Accessibility permission."
    )
  }
  // Grok Bot can replace the composer element while it publishes content, so each check finds it again.
  let draft = { composer(window).map { string($0, kAXValueAttribute) } }
  guard waitFor(3, condition: { draft() == request.message }),
    selected(request), sameWindow(root, window), heading(window, name: request.name)
  else {
    throw BridgeError(
      "The composer changed while preparing the message. Review the draft in Grok Bot.")
  }
  guard let button = sendButton(window), attribute(button, kAXEnabledAttribute) as? Bool == true
  else {
    throw BridgeError(
      "Grok Bot’s Send message button is unavailable. The message remains in the composer.")
  }
  guard draft() == request.message, selected(request),
    sameWindow(root, window), heading(window, name: request.name)
  else {
    throw BridgeError("The active chat or draft changed. Review Grok Bot before trying again.")
  }
  guard AXUIElementPerformAction(button, kAXPressAction as CFString) == .success else {
    throw BridgeError("Grok Bot did not accept the send action. Check the chat before retrying.")
  }
  guard
    waitFor(
      5,
      condition: {
        guard selected(request), sameWindow(root, window), heading(window, name: request.name),
          let current = composer(window)
        else { return false }
        return string(current, kAXValueAttribute).trimmingCharacters(in: .whitespacesAndNewlines)
          .isEmpty
      })
  else {
    throw BridgeError(
      "Send status is uncertain. Check the chat before retrying to avoid a duplicate message.")
  }
}

do {
  let request = try JSONDecoder().decode(
    Request.self, from: FileHandle.standardInput.readDataToEndOfFile())
  try send(request)
  print("{\"ok\":true}")
} catch {
  let data = try! JSONSerialization.data(withJSONObject: [
    "ok": false, "error": error.localizedDescription,
  ])
  print(String(decoding: data, as: UTF8.self))
  exit(1)
}
