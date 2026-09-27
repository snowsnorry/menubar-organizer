import Foundation
import XCTest
@testable import OrganizerCore

final class LayoutStoreTests: XCTestCase {
    private func withStore(_ body: (LayoutStore, URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(LayoutStore(url: directory.appendingPathComponent("layout.json")), directory)
    }

    private var sample: LayoutDocument {
        LayoutDocument(entries: [.init(id: "app:test", bundleID: "test", name: "Тест", group: .hidden)],
                       hideDelay: 12, launchAtLogin: true)
    }

    func testMissingAndRoundTripWithPrivatePermissions() throws {
        try withStore { store, directory in
            XCTAssertEqual(try store.load().status, .missing)
            XCTAssertEqual(try store.load().document, LayoutDocument())
            try store.save(sample)
            XCTAssertEqual(try store.load().document, sample)
            XCTAssertEqual(try store.load().status, .loaded)
            XCTAssertEqual(try permissions(directory), 0o700)
            XCTAssertEqual(try permissions(store.url), 0o600)
        }
    }

    func testCorruptionPreservedByteForByteAndDefaultPersisted() throws {
        try withStore { store, directory in
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let bad = Data([0xff, 0x00, 0x7b, 0x22])
            try bad.write(to: store.url)
            let result = try store.load()
            guard case .recoveredCorruption(let backup) = result.status else { return XCTFail("Expected recovery") }
            XCTAssertEqual(try Data(contentsOf: backup), bad)
            XCTAssertEqual(try permissions(backup), 0o600)
            XCTAssertEqual(result.document, LayoutDocument())
            XCTAssertEqual(try store.load().status, .loaded)
            XCTAssertEqual(try store.load().document, LayoutDocument())
        }
    }

    func testDirectSaveBacksUpCorruptData() throws {
        try withStore { store, directory in
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let bad = Data("broken".utf8)
            try bad.write(to: store.url)
            try store.save(sample)
            let backups = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "backup" }
            XCTAssertEqual(backups.count, 1)
            XCTAssertEqual(try Data(contentsOf: XCTUnwrap(backups.first)), bad)
            XCTAssertEqual(try store.load().document, sample)
        }
    }

    func testUnsupportedVersionsAreNeverMutatedEvenOnDirectSave() throws {
        for version in [0, 2, 999] {
            try withStore { store, directory in
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let original = Data("{\"version\":\(version),\"futureField\":true}".utf8)
                try original.write(to: store.url)
                XCTAssertThrowsError(try store.load()) {
                    XCTAssertEqual($0 as? LayoutValidationError, .unsupportedVersion(version))
                }
                XCTAssertThrowsError(try LayoutStore(url: store.url).save(sample)) {
                    XCTAssertEqual($0 as? LayoutValidationError, .unsupportedVersion(version))
                }
                XCTAssertEqual(try Data(contentsOf: store.url), original)
                XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["layout.json"])
            }
        }
    }

    func testInvalidSaveLeavesValidFileUntouched() throws {
        try withStore { store, _ in
            try store.save(sample)
            let bytes = try Data(contentsOf: store.url)
            var duplicate = sample
            duplicate.entries.append(duplicate.entries[0])
            XCTAssertThrowsError(try store.save(duplicate)) {
                XCTAssertEqual($0 as? LayoutValidationError, .duplicateIdentity)
            }
            var inconsistent = sample
            inconsistent.entries.append(.init(id: "another", bundleID: "test", name: "Other", group: .visible))
            XCTAssertThrowsError(try store.save(inconsistent)) {
                XCTAssertEqual($0 as? LayoutValidationError, .inconsistentApplicationVisibility)
            }
            XCTAssertEqual(try Data(contentsOf: store.url), bytes)
        }
    }

    func testInvalidCurrentDocumentIsBackedUp() throws {
        try withStore { store, directory in
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var invalid = sample
            invalid.entries.append(.init(id: "another", bundleID: "test", name: "Other", group: .visible))
            let original = try JSONEncoder().encode(invalid)
            try original.write(to: store.url)
            guard case .recoveredCorruption(let backup) = try store.load().status else {
                return XCTFail("Expected recovery")
            }
            XCTAssertEqual(try Data(contentsOf: backup), original)
        }
    }

    func testReplacementLeavesNoTemporaryFilesAndPrivateMetadata() throws {
        try withStore { store, directory in
            try store.save(sample)
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: store.url.path)
            var replacement = sample
            replacement.hideDelay = 60
            try store.save(replacement)
            XCTAssertEqual(try store.load().document, replacement)
            XCTAssertEqual(try permissions(store.url), 0o600)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["layout.json"])
        }
    }

    func testSymlinkDoesNotChangeTarget() throws {
        try withStore { store, directory in
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let target = directory.appendingPathComponent("target")
            let original = Data("private target".utf8)
            try original.write(to: target)
            try FileManager.default.createSymbolicLink(at: store.url, withDestinationURL: target)
            XCTAssertThrowsError(try store.load())
            XCTAssertThrowsError(try store.save(sample))
            XCTAssertEqual(try Data(contentsOf: target), original)
        }
    }

    private func permissions(_ url: URL) throws -> Int {
        try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber).intValue
    }
}
