import Cocoa
import FlutterMacOS
import Security
import XCTest
@testable import synapse

class RunnerTests: XCTestCase {

  func testVaultAccessManagerReleasesEachStartedLeaseExactlyOnce() throws {
    var starts = 0
    var stops: [URL] = []
    let manager = VaultAccessManager(
      startAccessing: { _ in
        starts += 1
        return true
      },
      stopAccessing: { stops.append($0) },
      makeBookmark: { _ in Data([1, 2, 3]) },
      makeToken: { "lease-1" })
    let url = URL(fileURLWithPath: "/vault/one")

    let payload = try manager.createLease(for: url)

    XCTAssertEqual(payload["rootPath"] as? String, "/vault/one")
    XCTAssertEqual(payload["bookmarkBase64"] as? String, "AQID")
    XCTAssertEqual(payload["leaseToken"] as? String, "lease-1")
    XCTAssertEqual(manager.activeLeaseCount, 1)
    XCTAssertEqual(starts, 1)

    manager.release(token: "lease-1")
    manager.release(token: "lease-1")

    XCTAssertEqual(manager.activeLeaseCount, 0)
    XCTAssertEqual(stops, [url])
  }

  func testVaultAccessManagerReleaseAllStopsEveryRemainingLease() throws {
    var tokens = ["lease-1", "lease-2"]
    var stops: [URL] = []
    let manager = VaultAccessManager(
      startAccessing: { _ in true },
      stopAccessing: { stops.append($0) },
      makeBookmark: { _ in Data([4]) },
      makeToken: { tokens.removeFirst() })
    let first = URL(fileURLWithPath: "/vault/one")
    let second = URL(fileURLWithPath: "/vault/two")

    _ = try manager.createLease(for: first)
    _ = try manager.createLease(for: second)
    manager.releaseAll()
    manager.releaseAll()

    XCTAssertEqual(manager.activeLeaseCount, 0)
    XCTAssertEqual(Set(stops), Set([first, second]))
    XCTAssertEqual(stops.count, 2)
  }

  func testVaultAccessManagerStopsAccessWhenBookmarkCreationFails() {
    enum TestError: Error { case bookmark }
    let url = URL(fileURLWithPath: "/vault/failure")
    var stops: [URL] = []
    let manager = VaultAccessManager(
      startAccessing: { _ in true },
      stopAccessing: { stops.append($0) },
      makeBookmark: { _ in throw TestError.bookmark },
      makeToken: { "unused" })

    XCTAssertThrowsError(try manager.createLease(for: url))
    XCTAssertEqual(manager.activeLeaseCount, 0)
    XCTAssertEqual(stops, [url])
  }

  func testSignedDebugCanRoundTripTemporaryKeychainItem() {
    let service = "co.onecoos.synapse.RunnerTests"
    let account = UUID().uuidString
    let expected = Data("synapse-keychain-test".utf8)
    let baseQuery: [CFString: Any] = [
      kSecClass: kSecClassGenericPassword,
      kSecAttrService: service,
      kSecAttrAccount: account,
    ]

    SecItemDelete(baseQuery as CFDictionary)
    defer { SecItemDelete(baseQuery as CFDictionary) }

    var addQuery = baseQuery
    addQuery[kSecValueData] = expected
    XCTAssertEqual(
      SecItemAdd(addQuery as CFDictionary, nil),
      errSecSuccess,
      "Signed Debug must be able to write to the macOS Keychain."
    )

    var readQuery = baseQuery
    readQuery[kSecReturnData] = true
    readQuery[kSecMatchLimit] = kSecMatchLimitOne
    var result: CFTypeRef?
    XCTAssertEqual(
      SecItemCopyMatching(readQuery as CFDictionary, &result),
      errSecSuccess,
      "Signed Debug must be able to read back its Keychain item."
    )
    XCTAssertEqual(result as? Data, expected)
    XCTAssertEqual(SecItemDelete(baseQuery as CFDictionary), errSecSuccess)
  }

}
