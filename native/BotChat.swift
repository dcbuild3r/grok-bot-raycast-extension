import AppKit
import WebKit

struct ChatRequest: Decodable {
  let name: String
  let iconPath: String
  let color: String?
  let assetsPath: String
  let draft: String
  let messages: [ChatEntry]
  let previewPath: String?
  let windowPosition: String?
  let windowSize: String?
  let textSize: Double?
}

struct ChatEntry: Codable {
  let id: String
  let role: String
  let text: String
  let timestamp: Double
  let attachment: String?
}

func emit(_ event: [String: Any]) {
  guard let data = try? JSONSerialization.data(withJSONObject: event) else { return }
  FileHandle.standardOutput.write(data + Data([10]))
}

func iconData(path: String, hex: String?) -> String {
  guard let image = NSImage(contentsOfFile: path) else { return "" }
  var icon = image
  if let hex,
    let number = UInt32(hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16)
  {
    let color = NSColor(
      srgbRed: CGFloat((number >> 16) & 255) / 255, green: CGFloat((number >> 8) & 255) / 255,
      blue: CGFloat(number & 255) / 255, alpha: 1)
    icon = NSImage(size: NSSize(width: 96, height: 96), flipped: false) { rect in
      color.setFill()
      rect.fill()
      image.draw(in: rect, from: .zero, operation: .destinationIn, fraction: 1)
      return true
    }
  }
  guard let tiff = icon.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
    let png = bitmap.representation(using: .png, properties: [:])
  else { return "" }
  return "data:image/png;base64," + png.base64EncodedString()
}

final class ChatController: NSObject, NSApplicationDelegate, NSWindowDelegate, WKNavigationDelegate,
  WKScriptMessageHandler
{
  let request: ChatRequest
  let htmlURL: URL
  var window: NSWindow!
  var webView: WKWebView!
  var draft: String
  var sending = false
  var ready = false
  var queued: [[String: Any]] = []

  init(request: ChatRequest) {
    self.request = request
    draft = request.draft
    htmlURL = URL(fileURLWithPath: request.assetsPath).appendingPathComponent("chat.html")
  }

  func start() {
    let config = WKWebViewConfiguration()
    config.websiteDataStore = .nonPersistent()
    config.preferences.javaScriptCanOpenWindowsAutomatically = false
    config.userContentController.add(self, name: "chat")
    let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1100, height: 850)
    let preferred: NSSize
    switch request.windowSize {
    case "small": preferred = NSSize(width: 480, height: 520)
    case "medium": preferred = NSSize(width: 680, height: 620)
    default: preferred = NSSize(width: 900, height: 740)
    }
    let size = NSSize(
      width: min(preferred.width, visible.width - 40),
      height: min(preferred.height, visible.height - 40))
    // Corner positions sit flush against the usable screen area, inside the menu bar and Dock.
    let position = request.windowPosition ?? "center"
    let x =
      position.hasSuffix("-left")
      ? visible.minX
      : position.hasSuffix("-right") ? visible.maxX - size.width : visible.midX - size.width / 2
    let y =
      position.hasPrefix("top-")
      ? visible.maxY - size.height
      : position.hasPrefix("bottom-") ? visible.minY : visible.midY - size.height / 2
    let frame = NSRect(x: x, y: y, width: size.width, height: size.height)
    window = NSWindow(
      contentRect: frame, styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
      backing: .buffered, defer: false)
    window.title = "Message \(request.name)"
    window.titleVisibility = .hidden
    window.titlebarAppearsTransparent = true
    window.backgroundColor = NSColor(srgbRed: 0.067, green: 0.067, blue: 0.067, alpha: 1)
    window.appearance = NSAppearance(named: .darkAqua)
    window.minSize = NSSize(width: 480, height: 420)
    window.isReleasedWhenClosed = false
    window.delegate = self
    for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
      window.standardWindowButton(kind)?.isHidden = true
    }
    webView = WKWebView(frame: NSRect(origin: .zero, size: size), configuration: config)
    webView.navigationDelegate = self
    // The stylesheet is designed at 15px, so page zoom scales the text and its layout together.
    webView.pageZoom = min(1.5, max(0.6, CGFloat(request.textSize ?? 15) / 15))
    window.contentView = webView
    webView.loadFileURL(htmlURL, allowingReadAccessTo: URL(fileURLWithPath: request.assetsPath))
    if request.previewPath == nil && !CommandLine.arguments.contains("--self-test") {
      window.makeKeyAndOrderFront(nil)
      NSApplication.shared.activate(ignoringOtherApps: true)
    }
  }

  func webView(
    _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
    decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
  ) {
    let allowed =
      navigationAction.targetFrame?.isMainFrame == true
      && navigationAction.request.url?.standardizedFileURL == htmlURL.standardizedFileURL
    decisionHandler(allowed ? .allow : .cancel)
  }

  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    ready = true
    let messageData = try! JSONEncoder().encode(request.messages)
    let messages = try! JSONSerialization.jsonObject(with: messageData)
    let color = request.color ?? "#999999"
    let accent = color.uppercased() == "#FFFFFF" ? "#B5B5B5" : color
    apply([
      "name": request.name, "avatar": iconData(path: request.iconPath, hex: request.color),
      "accent": accent, "draft": draft, "messages": messages,
    ])
    for update in queued { apply(update) }
    if CommandLine.arguments.contains("--self-test") {
      webView.evaluateJavaScript(
        "({bubbles:document.querySelectorAll('.bubble').length, injected:document.querySelectorAll('.bubble img,.bubble script,.bubble iframe').length, composer:!!document.querySelector('#message')})"
      ) { value, error in
        guard error == nil, let result = value as? [String: Any],
          result["bubbles"] as? Int == self.request.messages.count, result["injected"] as? Int == 0,
          result["composer"] as? Bool == true
        else {
          emit(["error": "Chat rendering self-test failed."])
          exit(1)
        }
        webView.evaluateJavaScript(
          "document.querySelector('#message').value='Composer self-test'; document.querySelector('#message').dispatchEvent(new Event('input')); document.querySelector('#composer').requestSubmit();"
        )
      }
      return
    }
    queued.removeAll()
    if let path = request.previewPath {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
        webView.takeSnapshot(with: nil) { image, error in
          guard let tiff = image?.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
            let png = bitmap.representation(using: .png, properties: [:])
          else {
            emit(["error": error?.localizedDescription ?? "Could not render chat preview."])
            exit(1)
          }
          do {
            try png.write(to: URL(fileURLWithPath: path))
            exit(0)
          } catch {
            emit(["error": error.localizedDescription])
            exit(1)
          }
        }
      }
    }
  }

  func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
    emit(["error": error.localizedDescription])
    exit(1)
  }
  func webView(
    _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
    withError error: Error
  ) {
    emit(["error": error.localizedDescription])
    exit(1)
  }

  func apply(_ state: [String: Any]) {
    if !ready {
      queued.append(state)
      return
    }
    if let value = state["sending"] as? Bool { sending = value }
    if state["clearDraft"] as? Bool == true { draft = "" }
    webView.callAsyncJavaScript(
      "window.updateChat(state)", arguments: ["state": state], in: nil, in: .page
    ) { result in
      if case .failure(let error) = result { emit(["error": error.localizedDescription]) }
    }
    if state["focus"] as? Bool == true {
      window.makeKeyAndOrderFront(nil)
      NSApplication.shared.activate(ignoringOtherApps: true)
    }
  }

  func userContentController(
    _ userContentController: WKUserContentController, didReceive message: WKScriptMessage
  ) {
    guard message.frameInfo.isMainFrame,
      message.frameInfo.request.url?.standardizedFileURL == htmlURL.standardizedFileURL,
      let body = message.body as? [String: Any], let type = body["type"] as? String
    else { return }
    switch type {
    case "draft":
      if let text = body["text"] as? String {
        draft = text
        emit(["type": "draft", "text": text])
      }
    case "send":
      guard !sending, let text = body["text"] as? String,
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      else { return }
      if CommandLine.arguments.contains("--self-test") {
        emit([
          "ok": true, "check": "Literal message rendering and owned-main-frame send IPC passed.",
        ])
        exit(0)
      }
      sending = true
      draft = text
      emit(["type": "send", "text": text])
    case "close":
      guard !sending else { return }
      if let text = body["draft"] as? String { draft = text }
      finish(type: "close", back: body["back"] as? Bool ?? false)
    case "open": if !sending { finish(type: "open") }
    default: break
    }
  }

  func finish(type: String, back: Bool = false) {
    emit(["type": type, "draft": draft, "back": back])
    exit(0)
  }
  func windowShouldClose(_ sender: NSWindow) -> Bool { !sending }
  func windowWillClose(_ notification: Notification) { finish(type: "close") }
}

do {
  guard let line = readLine(), let data = line.data(using: .utf8) else {
    throw NSError(
      domain: "GrokBotChat", code: 1,
      userInfo: [NSLocalizedDescriptionKey: "Chat configuration is missing."])
  }
  let request = try JSONDecoder().decode(ChatRequest.self, from: data)
  let app = NSApplication.shared
  app.setActivationPolicy(.accessory)
  let controller = ChatController(request: request)
  app.delegate = controller
  controller.start()
  if request.previewPath == nil && !CommandLine.arguments.contains("--self-test") {
    DispatchQueue.global(qos: .userInitiated).async {
      while let line = readLine() {
        guard let data = line.data(using: .utf8),
          let state = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { continue }
        DispatchQueue.main.async { controller.apply(state) }
      }
      DispatchQueue.main.async { controller.finish(type: "close") }
    }
  }
  app.run()
} catch {
  emit(["error": error.localizedDescription])
  exit(1)
}
