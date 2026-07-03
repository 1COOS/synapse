import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)
    VaultAccessChannel.register(with: flutterViewController)

    super.awakeFromNib()
  }
}

private final class VaultAccessChannel: NSObject {
  private static var instance: VaultAccessChannel?

  private var activeURLs: [URL] = []

  static func register(with controller: FlutterViewController) {
    let instance = VaultAccessChannel()
    VaultAccessChannel.instance = instance
    let channel = FlutterMethodChannel(
      name: "synapse/vault_access",
      binaryMessenger: controller.engine.binaryMessenger)
    channel.setMethodCallHandler(instance.handle)
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "pickDirectory":
      pickDirectory(result: result)
    case "startAccessingBookmark":
      guard
        let arguments = call.arguments as? [String: Any],
        let bookmarkBase64 = arguments["bookmarkBase64"] as? String
      else {
        result(FlutterError(
          code: "invalid-arguments",
          message: "bookmarkBase64 is required.",
          details: nil))
        return
      }
      startAccessingBookmark(bookmarkBase64, result: result)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func pickDirectory(result: @escaping FlutterResult) {
    DispatchQueue.main.async {
      let panel = NSOpenPanel()
      panel.canChooseDirectories = true
      panel.canChooseFiles = false
      panel.allowsMultipleSelection = false
      panel.canCreateDirectories = true
      panel.prompt = "选择 Vault"

      let completion: (NSApplication.ModalResponse) -> Void = { response in
        guard response == .OK, let url = panel.url else {
          result(nil)
          return
        }
        do {
          result(try self.payload(for: url))
        } catch {
          result(FlutterError(
            code: "bookmark-create-failed",
            message: error.localizedDescription,
            details: nil))
        }
      }

      if let window = NSApplication.shared.keyWindow ?? NSApplication.shared.mainWindow {
        panel.beginSheetModal(for: window, completionHandler: completion)
      } else {
        completion(panel.runModal())
      }
    }
  }

  private func startAccessingBookmark(_ bookmarkBase64: String, result: @escaping FlutterResult) {
    guard let bookmarkData = Data(base64Encoded: bookmarkBase64) else {
      result(FlutterError(
        code: "invalid-bookmark",
        message: "bookmarkBase64 is not valid Base64.",
        details: nil))
      return
    }

    do {
      var isStale = false
      let url = try URL(
        resolvingBookmarkData: bookmarkData,
        options: [.withSecurityScope],
        relativeTo: nil,
        bookmarkDataIsStale: &isStale)
      result(try payload(for: url, fallbackBookmarkBase64: isStale ? nil : bookmarkBase64))
    } catch {
      result(FlutterError(
        code: "bookmark-resolve-failed",
        message: error.localizedDescription,
        details: nil))
    }
  }

  private func payload(
    for url: URL,
    fallbackBookmarkBase64: String? = nil
  ) throws -> [String: Any] {
    if url.startAccessingSecurityScopedResource() {
      activeURLs.append(url)
    }
    let bookmarkBase64: String
    if let fallbackBookmarkBase64 {
      bookmarkBase64 = fallbackBookmarkBase64
    } else {
      let bookmarkData = try url.bookmarkData(
        options: [.withSecurityScope],
        includingResourceValuesForKeys: nil,
        relativeTo: nil)
      bookmarkBase64 = bookmarkData.base64EncodedString()
    }
    return [
      "rootPath": url.path,
      "bookmarkBase64": bookmarkBase64,
    ]
  }
}
