import Cocoa
import FlutterMacOS

enum VaultAccessManagerError: LocalizedError {
  case accessDenied
  case invalidToken

  var errorDescription: String? {
    switch self {
    case .accessDenied:
      return "Could not start security-scoped Vault access."
    case .invalidToken:
      return "Could not create a unique Vault access token."
    }
  }
}

final class VaultAccessManager {
  static let shared = VaultAccessManager()

  private struct Lease {
    let url: URL
    let startedAccess: Bool
  }

  typealias StartAccessing = (URL) -> Bool
  typealias StopAccessing = (URL) -> Void
  typealias MakeBookmark = (URL) throws -> Data
  typealias MakeToken = () -> String

  private let startAccessing: StartAccessing
  private let stopAccessing: StopAccessing
  private let makeBookmark: MakeBookmark
  private let makeToken: MakeToken
  private var leases: [String: Lease] = [:]

  init(
    startAccessing: @escaping StartAccessing = { $0.startAccessingSecurityScopedResource() },
    stopAccessing: @escaping StopAccessing = { $0.stopAccessingSecurityScopedResource() },
    makeBookmark: @escaping MakeBookmark = { url in
      try url.bookmarkData(
        options: [.withSecurityScope],
        includingResourceValuesForKeys: nil,
        relativeTo: nil)
    },
    makeToken: @escaping MakeToken = { UUID().uuidString }
  ) {
    self.startAccessing = startAccessing
    self.stopAccessing = stopAccessing
    self.makeBookmark = makeBookmark
    self.makeToken = makeToken
  }

  var activeLeaseCount: Int {
    leases.count
  }

  func createLease(
    for url: URL,
    fallbackBookmarkBase64: String? = nil
  ) throws -> [String: Any] {
    guard startAccessing(url) else {
      throw VaultAccessManagerError.accessDenied
    }
    var ownsStartedAccess = true
    defer {
      if ownsStartedAccess {
        stopAccessing(url)
      }
    }

    let bookmarkBase64: String
    if let fallbackBookmarkBase64, !fallbackBookmarkBase64.isEmpty {
      bookmarkBase64 = fallbackBookmarkBase64
    } else {
      bookmarkBase64 = try makeBookmark(url).base64EncodedString()
    }
    let token = makeToken()
    guard !token.isEmpty, leases[token] == nil else {
      throw VaultAccessManagerError.invalidToken
    }
    leases[token] = Lease(url: url, startedAccess: true)
    ownsStartedAccess = false
    return [
      "rootPath": url.path,
      "bookmarkBase64": bookmarkBase64,
      "leaseToken": token,
    ]
  }

  func release(token: String) {
    guard let lease = leases.removeValue(forKey: token) else {
      return
    }
    if lease.startedAccess {
      stopAccessing(lease.url)
    }
  }

  func releaseAll() {
    let remaining = Array(leases.values)
    leases.removeAll()
    for lease in remaining where lease.startedAccess {
      stopAccessing(lease.url)
    }
  }
}

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    titleVisibility = .hidden
    titlebarAppearsTransparent = true
    styleMask.insert(.fullSizeContentView)
    isMovableByWindowBackground = true

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

  private let accessManager: VaultAccessManager

  init(accessManager: VaultAccessManager = .shared) {
    self.accessManager = accessManager
  }

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
    case "releaseAccess":
      guard
        let arguments = call.arguments as? [String: Any],
        let leaseToken = arguments["leaseToken"] as? String,
        !leaseToken.isEmpty
      else {
        result(FlutterError(
          code: "invalid-arguments",
          message: "leaseToken is required.",
          details: nil))
        return
      }
      accessManager.release(token: leaseToken)
      result(nil)
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
          result(try self.accessManager.createLease(for: url))
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
      result(try accessManager.createLease(
        for: url,
        fallbackBookmarkBase64: isStale ? nil : bookmarkBase64))
    } catch {
      result(FlutterError(
        code: "bookmark-resolve-failed",
        message: error.localizedDescription,
        details: nil))
    }
  }

}
