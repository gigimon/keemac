@testable import Data
import Domain
import Foundation
import KeePassKit
import XCTest

final class VaultMergeDiffTests: XCTestCase {
    private let t1 = Date(timeIntervalSince1970: 1_700_000_000)
    private var t2: Date { t1.addingTimeInterval(60) }
    private var t3: Date { t1.addingTimeInterval(120) }

    private func entry(
        _ id: UUID,
        _ title: String,
        group: String = "Root",
        trashed: Bool = false,
        modified: Date?,
        password: String = "pw",
        history: [Date] = []
    ) -> VaultEntry {
        VaultEntry(
            id: id,
            groupPath: group,
            isTrashed: trashed,
            modifiedAt: modified,
            title: title,
            password: password,
            history: history.map { VaultEntryRevision(modifiedAt: $0, title: title) }
        )
    }

    func testChangedFields() {
        let otp = VaultOTPConfiguration(secret: Data([1]), digits: 6, period: 30, timeBase: 0, algorithm: .sha1)
        let old = VaultEntry(title: "A", username: "u", password: "p", url: URL(string: "https://a"), notes: "n", tags: ["t"])
        let new = VaultEntry(
            expiresAt: t1,
            title: "B",
            username: "v",
            password: "q",
            url: URL(string: "https://b"),
            notes: "m",
            tags: ["s"],
            customFields: [VaultCustomField(key: "k", value: "v", isProtected: false)],
            attachments: [VaultAttachment(name: "f", data: Data([1]))],
            otp: otp
        )
        XCTAssertEqual(VaultMergeDiff.changedFields(from: old, to: new), [
            "title", "username", "password", "website", "notes", "tags", "one-time password", "attachments", "custom fields", "expiry"
        ])
        XCTAssertEqual(VaultMergeDiff.changedFields(from: old, to: old), [])

        let renamedAttachment = VaultEntry(title: "A", attachments: [VaultAttachment(name: "g", data: Data([1]))])
        let changedAttachment = VaultEntry(title: "A", attachments: [VaultAttachment(name: "g", data: Data([2]))])
        XCTAssertEqual(VaultMergeDiff.changedFields(from: renamedAttachment, to: changedAttachment), ["attachments"])
    }

    func testSameMomentAndConflicts() {
        XCTAssertTrue(VaultMergeDiff.sameMoment(t1, t1.addingTimeInterval(0.9)), "KDBX keeps whole seconds")
        XCTAssertFalse(VaultMergeDiff.sameMoment(t1, t1.addingTimeInterval(1)))
        XCTAssertTrue(VaultMergeDiff.sameMoment(nil, nil))
        XCTAssertFalse(VaultMergeDiff.sameMoment(t1, nil))

        let id = UUID()
        XCTAssertFalse(VaultMergeDiff.isConflict(local: entry(id, "A", modified: t1), external: entry(id, "A", modified: t1)))
        XCTAssertTrue(VaultMergeDiff.isConflict(local: entry(id, "A", modified: t1), external: entry(id, "A", modified: t2)))
        XCTAssertFalse(
            VaultMergeDiff.isConflict(local: entry(id, "A", modified: t1), external: entry(id, "A", modified: t2, history: [t1])),
            "the other side edited on top of ours"
        )
        XCTAssertFalse(VaultMergeDiff.isConflict(local: entry(id, "A", modified: t2, history: [t1]), external: entry(id, "A", modified: t1)))
    }

    func testAppliedChanges() {
        let edited = UUID(), moved = UUID(), restored = UUID(), removed = UUID(), trashedNow = UUID(), added = UUID(), addedTrashed = UUID(), same = UUID()
        let before = [
            entry(edited, "Edited", modified: t1),
            entry(moved, "Moved", modified: t1),
            entry(restored, "Restored", trashed: true, modified: t1),
            entry(removed, "Removed", modified: t1),
            entry(trashedNow, "Trashed", group: "Root.Work", modified: t1),
            entry(same, "Same", modified: t1)
        ]
        let after = [
            entry(edited, "Edited", group: "Root.Work", modified: t2, password: "new"),
            entry(moved, "Moved", group: "Root.Archive", modified: t1),
            entry(restored, "Restored", modified: t1),
            entry(trashedNow, "Trashed", group: "Root.Recycle Bin", trashed: true, modified: t2),
            entry(added, "Added", modified: t2),
            entry(addedTrashed, "Gone", trashed: true, modified: t2),
            entry(same, "Same", modified: t1)
        ]
        let external = [entry(edited, "Edited", modified: t2, password: "new")]

        let summary = VaultMergeDiff.applied(before: before, after: after, external: external)
        XCTAssertEqual(summary.changes.map(\.kind), [.added, .added, .updated, .deleted, .deleted, .moved])
        XCTAssertEqual(summary.changes.map(\.title), ["Added", "Restored", "Edited", "Removed", "Trashed", "Moved"])

        let update = summary.changes[2]
        XCTAssertEqual(update.changedFields, ["password"])
        XCTAssertEqual(update.previousGroupPath, "Root")
        XCTAssertTrue(update.isConflict, "both sides changed it without seeing the other")
        XCTAssertEqual(summary.changes[4].groupPath, "Root.Work", "a trashed entry is reported where it was")
        XCTAssertEqual(summary.changes[5].previousGroupPath, "Root")
    }

    func testLocalWinnerOfAConflictIsReported() {
        let id = UUID()
        let previous = entry(id, "Mail", modified: t3)
        let merged = entry(id, "Mail", modified: t3, history: [t2])
        let external = entry(id, "Mail", modified: t2, password: "theirs")
        let summary = VaultMergeDiff.applied(before: [previous], after: [merged], external: [external])
        XCTAssertEqual(summary.changes.count, 1)
        XCTAssertEqual(summary.changes.first?.kind, .updated)
        XCTAssertEqual(summary.changes.first?.changedFields, [])
        XCTAssertEqual(summary.conflictCount, 1)

        let alreadyKnown = VaultMergeDiff.applied(before: [entry(id, "Mail", modified: t3, history: [t2])], after: [merged], external: [external])
        XCTAssertTrue(alreadyKnown.isEmpty, "a version already in history is not news")
    }

    func testPredictedChanges() {
        let newer = UUID(), older = UUID(), deleted = UUID(), kept = UUID(), fresh = UUID(), freshTrashed = UUID(), undated = UUID()
        let local = [
            entry(newer, "Newer", modified: t1),
            entry(older, "Older", modified: t2),
            entry(deleted, "Deleted", modified: t1),
            entry(kept, "Kept", modified: t1),
            entry(undated, "Undated", modified: nil)
        ]
        let external = [
            entry(newer, "Newer", modified: t2, password: "changed", history: [t1]),
            entry(older, "Older", modified: t1, password: "stale"),
            entry(fresh, "Fresh", modified: t1),
            entry(freshTrashed, "Fresh trash", trashed: true, modified: t1),
            entry(undated, "Undated", group: "Root.Work", modified: t1)
        ]
        let summary = VaultMergeDiff.predicted(local: local, external: external, externalDeletedIDs: [deleted, UUID()])
        XCTAssertEqual(summary.changes.map(\.title), ["Fresh", "Newer", "Deleted", "Undated"])
        XCTAssertEqual(summary.changes.map(\.kind), [.added, .updated, .deleted, .moved])
        XCTAssertEqual(summary.changes[1].changedFields, ["password"])
        XCTAssertFalse(summary.changes[1].isConflict, "the newer version was made on top of ours")

        let diverged = VaultMergeDiff.predicted(local: [local[0]], external: [entry(newer, "Newer", modified: t2, password: "changed")], externalDeletedIDs: [])
        XCTAssertEqual(diverged.conflictCount, 1)
    }
}

final class KDBXHeaderReaderTests: XCTestCase {
    private func le<T: FixedWidthInteger>(_ value: T) -> [UInt8] {
        withUnsafeBytes(of: value.littleEndian) { Array($0) }
    }

    private func bytes(_ uuid: UUID) -> [UInt8] {
        withUnsafeBytes(of: uuid.uuid) { Array($0) }
    }

    private func header(major: UInt16, minor: UInt16 = 1, signature2: UInt32 = 0xB54B_FB67, fields: [(UInt8, [UInt8])], end: Bool = true) -> Data {
        var data = le(UInt32(0x9AA2_D903)) + le(signature2) + le(minor) + le(major)
        for (id, value) in fields + (end ? [(0, [0x0D, 0x0A, 0x0D, 0x0A])] : []) {
            data.append(id)
            data += major >= 4 ? le(UInt32(value.count)) : le(UInt16(value.count))
            data += value
        }
        return Data(data)
    }

    private func variantDictionary(kdf: UUID) -> [UInt8] {
        var data = le(UInt16(0x0100))
        data += [0x05] + le(UInt32(1)) + Array("I".utf8) + le(UInt32(8)) + le(UInt64(2))
        data += [0x42] + le(UInt32(5)) + Array("$UUID".utf8) + le(UInt32(16)) + bytes(kdf)
        data += [0x00]
        return data
    }

    func testKDBX4Header() throws {
        let data = header(major: 4, fields: [
            (3, [1, 0, 0, 0]),
            (2, bytes(KPKChaCha20Cipher.uuid())),
            (11, variantDictionary(kdf: KPKArgon2IDKeyDerivation.uuid()))
        ])
        let info = try XCTUnwrap(KDBXHeaderReader.parse(data))
        XCTAssertEqual(info, VaultFileInfo(majorVersion: 4, minorVersion: 1, cipher: .chacha20, kdf: .argon2id))

        let argon2d = KDBXHeaderReader.parse(header(major: 4, minor: 0, fields: [
            (2, bytes(KPKTwofishCipher.uuid())),
            (11, variantDictionary(kdf: KPKArgon2DKeyDerivation.uuid()))
        ]))
        XCTAssertEqual(argon2d, VaultFileInfo(majorVersion: 4, minorVersion: 0, cipher: .twofish, kdf: .argon2d))
    }

    func testAESKDFIdentifiers() throws {
        let kdbx4AES = try XCTUnwrap(UUID(uuidString: "7C02BB82-79A7-4AC0-927D-114A00648238"))
        XCTAssertEqual(KDBXHeaderReader.parse(header(major: 4, fields: [(11, variantDictionary(kdf: kdbx4AES))]))?.kdf, .aes)
        XCTAssertEqual(KDBXHeaderReader.parse(header(major: 4, fields: [(11, variantDictionary(kdf: KPKAESKeyDerivation.uuid()))]))?.kdf, .aes)

        let kdbx3 = KDBXHeaderReader.parse(header(major: 3, fields: [(2, bytes(KPKAESCipher.uuid())), (6, le(UInt64(60_000)))]))
        XCTAssertEqual(kdbx3, VaultFileInfo(majorVersion: 3, minorVersion: 1, cipher: .aes256, kdf: .aes))
    }

    func testUnknownValuesAreLeftOut() {
        let unknown = KDBXHeaderReader.parse(header(major: 4, fields: [
            (2, bytes(UUID())),
            (11, variantDictionary(kdf: UUID())),
            (99, [1, 2, 3])
        ]))
        XCTAssertEqual(unknown, VaultFileInfo(majorVersion: 4, minorVersion: 1, cipher: nil, kdf: nil))

        XCTAssertNil(KDBXHeaderReader.parse(header(major: 4, fields: [(2, [1, 2, 3])]))?.cipher, "a cipher ID must be 16 bytes")
        let brokenDictionary = KDBXHeaderReader.parse(header(major: 4, fields: [(11, le(UInt16(0x0100)) + [0x42] + le(UInt32(200)))]))
        XCTAssertNotNil(brokenDictionary)
        XCTAssertNil(brokenDictionary?.kdf)
        XCTAssertNil(KDBXHeaderReader.parse(header(major: 4, fields: [(11, [0x01])]))?.kdf)
    }

    func testRejectsOtherFiles() {
        XCTAssertNil(KDBXHeaderReader.parse(Data()))
        XCTAssertNil(KDBXHeaderReader.parse(Data([0x03, 0xD9, 0xA2])))
        XCTAssertNil(KDBXHeaderReader.parse(header(major: 4, signature2: 0xB54B_FB65, fields: [])), "KeePass 1")
        XCTAssertNil(KDBXHeaderReader.parse(header(major: 2, fields: [])))
        XCTAssertNil(KDBXHeaderReader.parse(header(major: 5, fields: [])))
        XCTAssertNil(KDBXHeaderReader.parse(Data("<?xml version=\"1.0\"?>".utf8)))
    }

    func testRejectsTruncatedHeaders() {
        XCTAssertNil(KDBXHeaderReader.parse(header(major: 4, fields: [(2, bytes(KPKAESCipher.uuid()))], end: false)), "no end field")
        let full = header(major: 4, fields: [(2, bytes(KPKAESCipher.uuid()))])
        XCTAssertNil(KDBXHeaderReader.parse(full.prefix(20)), "value cut off")
        XCTAssertNil(KDBXHeaderReader.parse(full.prefix(14)), "length cut off")
        XCTAssertNotNil(KDBXHeaderReader.parse(full))
    }

    func testReadsFromFile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Header.kdbx")
        try (header(major: 4, fields: [(2, bytes(KPKChaCha20Cipher.uuid()))]) + Data(count: 64)).write(to: url)
        XCTAssertEqual(KDBXHeaderReader.read(from: url)?.cipher, .chacha20)
        XCTAssertNil(KDBXHeaderReader.read(from: directory.appendingPathComponent("Missing.kdbx")))
    }
}
