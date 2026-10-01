import XCTest
@testable import ProductiveCore

final class FileTokenStoreTests: XCTestCase {
    func testWriteReadPermissionsAndDelete() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tempo-token-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = FileTokenStore(directory: dir, migrateFrom: nil)
        XCTAssertNil(store.read())

        XCTAssertTrue(store.write("secret-1"))
        XCTAssertEqual(store.read(), "secret-1")
        let fileMode = try FileManager.default.attributesOfItem(atPath: store.url.path)[.posixPermissions] as? Int
        let dirMode = try FileManager.default.attributesOfItem(atPath: dir.path)[.posixPermissions] as? Int
        XCTAssertEqual(fileMode, 0o600)
        XCTAssertEqual(dirMode, 0o700)

        XCTAssertTrue(store.write("s2"))
        XCTAssertEqual(store.read(), "s2", "a shorter token replaces the old one completely")

        XCTAssertTrue(store.write(""))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.url.path))
        XCTAssertNil(store.read())
    }
}
