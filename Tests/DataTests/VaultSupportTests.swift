import AppKit
import Domain
import Foundation
@testable import UI
import XCTest

final class OTPCodeGeneratorTests: XCTestCase {
    private static let sha1Seed = Data("12345678901234567890".utf8)
    private static let sha256Seed = Data("12345678901234567890123456789012".utf8)
    private static let sha512Seed = Data("1234567890123456789012345678901234567890123456789012345678901234".utf8)

    private func code(_ seed: Data, _ algorithm: VaultOTPAlgorithm, at time: TimeInterval, digits: Int = 8, period: Int = 30, timeBase: TimeInterval = 0) -> OTPCodeState? {
        let config = VaultOTPConfiguration(secret: seed, digits: digits, period: period, timeBase: timeBase, algorithm: algorithm)
        return OTPCodeGenerator.makeCodeState(from: config, now: Date(timeIntervalSince1970: time))
    }

    func testRFC6238Vectors() {
        let vectors: [(TimeInterval, String, String, String)] = [
            (59, "94287082", "46119246", "90693936"),
            (1_111_111_109, "07081804", "68084774", "25091201"),
            (1_111_111_111, "14050471", "67062674", "99943326"),
            (1_234_567_890, "89005924", "91819424", "93441116"),
            (2_000_000_000, "69279037", "90698825", "38618901"),
            (20_000_000_000, "65353130", "77737706", "47863826")
        ]
        for (time, sha1, sha256, sha512) in vectors {
            XCTAssertEqual(code(Self.sha1Seed, .sha1, at: time)?.code, sha1, "SHA1 at \(time)")
            XCTAssertEqual(code(Self.sha256Seed, .sha256, at: time)?.code, sha256, "SHA256 at \(time)")
            XCTAssertEqual(code(Self.sha512Seed, .sha512, at: time)?.code, sha512, "SHA512 at \(time)")
        }
    }

    func testSixDigitsKeepLeadingZerosAndMatchHOTP() {
        // RFC 4226 HOTP values for counters 0, 1 and 9 with the same seed.
        XCTAssertEqual(code(Self.sha1Seed, .sha1, at: 0, digits: 6)?.code, "755224")
        XCTAssertEqual(code(Self.sha1Seed, .sha1, at: 30, digits: 6)?.code, "287082")
        XCTAssertEqual(code(Self.sha1Seed, .sha1, at: 270, digits: 6)?.code, "520489")
        XCTAssertEqual(code(Self.sha1Seed, .sha1, at: 1_111_111_109, digits: 8)?.code.count, 8)
        XCTAssertEqual(code(Self.sha1Seed, .sha1, at: 1_111_111_109, digits: 7)?.code, "7081804")
    }

    func testRemainingSecondsAndPeriod() throws {
        let start = try XCTUnwrap(code(Self.sha1Seed, .sha1, at: 1_234_567_890))
        XCTAssertEqual(start.remainingSeconds, 30, "a fresh period has all of it left")
        XCTAssertEqual(start.period, 30)
        XCTAssertEqual(code(Self.sha1Seed, .sha1, at: 59)?.remainingSeconds, 1)
        XCTAssertEqual(code(Self.sha1Seed, .sha1, at: 70, period: 60)?.remainingSeconds, 50)
        XCTAssertEqual(code(Self.sha1Seed, .sha1, at: 10, period: 0)?.period, 1, "a zero period is treated as one second")
    }

    func testTimeBaseShiftsTheCounter() {
        XCTAssertEqual(code(Self.sha1Seed, .sha1, at: 1_030, digits: 6, timeBase: 1_000)?.code, "287082")
        XCTAssertNil(code(Self.sha1Seed, .sha1, at: 999, timeBase: 1_000), "no code before the time base")
    }

    func testBigEndianCounterAndPadding() {
        XCTAssertEqual(UInt64(0x0102_0304_0506_0708).bigEndianData, Data([1, 2, 3, 4, 5, 6, 7, 8]))
        XCTAssertEqual("42".leftPadded(to: 6, with: "0"), "000042")
        XCTAssertEqual("123456".leftPadded(to: 6, with: "0"), "123456")
        XCTAssertEqual("1234567".leftPadded(to: 6, with: "0"), "1234567")
        XCTAssertEqual("".leftPadded(to: 2, with: "x"), "xx")
    }
}

final class OTPSecretFormatterTests: XCTestCase {
    func testRFC4648VectorsWithoutPadding() {
        let vectors = ["": "", "f": "MY", "fo": "MZXQ", "foo": "MZXW6", "foob": "MZXW6YQ", "fooba": "MZXW6YTB", "foobar": "MZXW6YTBOI"]
        for (input, expected) in vectors {
            XCTAssertEqual(OTPSecretFormatter.encodeBase32(Data(input.utf8)), expected, input)
        }
    }

    func testEncodesBinarySecrets() {
        XCTAssertEqual(OTPSecretFormatter.encodeBase32(Data("12345678901234567890".utf8)), "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ")
        XCTAssertEqual(OTPSecretFormatter.encodeBase32(Data([0xFF, 0xFF, 0xFF, 0xFF, 0xFF])), "77777777")
        XCTAssertEqual(OTPSecretFormatter.encodeBase32(Data([0x00])), "AA")
    }
}

final class DefaultKeePassIconMapperTests: XCTestCase {
    func testEveryStandardIconHasASymbol() {
        XCTAssertEqual(DefaultKeePassIconMapper.availableIconIDs, Array(0...68))
        for id in DefaultKeePassIconMapper.availableIconIDs {
            XCTAssertNotNil(DefaultKeePassIconMapper.symbolName(for: id), "icon \(id)")
        }
        XCTAssertEqual(DefaultKeePassIconMapper.symbolName(for: 0), "key.fill")
        XCTAssertEqual(DefaultKeePassIconMapper.symbolName(for: 48), "folder.fill")
        XCTAssertNil(DefaultKeePassIconMapper.symbolName(for: nil))
        XCTAssertNil(DefaultKeePassIconMapper.symbolName(for: -1))
        XCTAssertNil(DefaultKeePassIconMapper.symbolName(for: 69))
    }

    func testSymbolsExistInSFSymbols() {
        for id in DefaultKeePassIconMapper.availableIconIDs {
            guard let name = DefaultKeePassIconMapper.symbolName(for: id) else {
                continue
            }
            XCTAssertNotNil(NSImage(systemSymbolName: name, accessibilityDescription: nil), "icon \(id): \(name)")
        }
    }
}

final class EntryRevisionSnapshotTests: XCTestCase {
    private let otp = VaultOTPConfiguration(secret: Data("secret".utf8), digits: 6, period: 30, timeBase: 0, algorithm: .sha1)

    private func revision(_ revision: VaultEntryRevision, at index: Int = 0) -> EntryRevisionSnapshot {
        EntryRevisionSnapshot.revision((offset: index, element: revision))
    }

    func testSnapshotsCarryEntryAndRevisionFields() {
        let older = VaultEntryRevision(modifiedAt: Date(timeIntervalSince1970: 10), groupPath: "Root", title: "Mail", iconID: 3)
        let entry = VaultEntry(groupPath: "Root.Work", title: "Mail", username: "anna", iconID: 4, otp: otp, otpStorageStyle: .native, history: [older])
        let current = EntryRevisionSnapshot.current(entry)
        XCTAssertTrue(current.isCurrent)
        XCTAssertNil(current.historyIndex)
        XCTAssertEqual(current.id, entry.id)
        XCTAssertEqual(current.otpStorageStyle, .native)

        let past = revision(older, at: 2)
        XCTAssertFalse(past.isCurrent)
        XCTAssertEqual(past.historyIndex, 2)
        XCTAssertEqual(past.iconID, 3)
        XCTAssertEqual(past.modifiedAt, Date(timeIntervalSince1970: 10))
    }

    func testDiffListsEveryChangedField() {
        let older = revision(VaultEntryRevision(
            groupPath: "Root.Work",
            title: "Old",
            username: "anna",
            password: "one",
            url: URL(string: "https://a.example.com"),
            notes: "notes",
            customFields: [
                VaultCustomField(key: "A", value: "1", isProtected: false),
                VaultCustomField(key: "B", value: "2", isProtected: false)
            ],
            iconID: 0
        ))
        let newer = EntryRevisionSnapshot.current(VaultEntry(
            groupPath: "Root",
            title: "New",
            username: " anna ",
            password: "two",
            url: URL(string: "https://b.example.com"),
            notes: "notes\n",
            customFields: [
                VaultCustomField(key: "B", value: "3", isProtected: false),
                VaultCustomField(key: "C", value: "4", isProtected: true)
            ],
            attachments: [VaultAttachment(name: "key.pem", data: Data([1]))],
            iconID: 5,
            otp: otp,
            otpStorageStyle: .otpAuth
        ))
        XCTAssertEqual(newer.diffDetails(comparedTo: older), [
            "Title: \"Old\" -> \"New\"",
            "Password updated",
            "Website: \"https://a.example.com\" -> \"https://b.example.com\"",
            "Moved: \"Root.Work\" -> \"Root\"",
            "Icon changed",
            "One-time password configuration updated",
            "Attachments updated",
            "Custom field removed: A",
            "Custom field updated: B",
            "Custom field added: C"
        ])
    }

    func testEmptyValuesShowAsDashes() {
        let older = revision(VaultEntryRevision(groupPath: "", title: "Mail", notes: nil))
        let newer = EntryRevisionSnapshot.current(VaultEntry(groupPath: "Root", title: "Mail", username: "bob", notes: "hello"))
        XCTAssertEqual(newer.diffDetails(comparedTo: older), [
            "Username: \"-\" -> \"bob\"",
            "Moved: \"-\" -> \"Root\"",
            "Notes updated"
        ])
        let cleared = EntryRevisionSnapshot.current(VaultEntry(groupPath: "", title: "Mail", url: nil))
        let withURL = revision(VaultEntryRevision(title: "Mail", url: URL(string: "https://x.example")))
        XCTAssertEqual(cleared.diffDetails(comparedTo: withURL), ["Website: \"https://x.example\" -> \"-\""])
    }

    func testUnchangedRevisionHasNoDetails() {
        let attachments = [VaultAttachment(name: "a", data: Data([1])), VaultAttachment(name: "b", data: Data([2]))]
        let older = revision(VaultEntryRevision(title: "Same", password: "pw", attachments: attachments, otp: otp, otpStorageStyle: .native))
        let newer = EntryRevisionSnapshot.current(VaultEntry(
            title: "Same",
            username: "",
            password: "pw",
            attachments: attachments.reversed(),
            otp: otp,
            otpStorageStyle: .native
        ))
        XCTAssertEqual(newer.diffDetails(comparedTo: older), [], "attachment order and nil vs empty username are not changes")
    }

    func testSubtleOTPAndCustomFieldChanges() {
        let older = revision(VaultEntryRevision(
            title: "Mail",
            customFields: [VaultCustomField(key: "PIN", value: "1", isProtected: false)],
            otp: otp,
            otpStorageStyle: .otpAuth
        ))
        let newer = EntryRevisionSnapshot.current(VaultEntry(
            title: "Mail",
            customFields: [VaultCustomField(key: "PIN", value: "1", isProtected: true)],
            otp: otp,
            otpStorageStyle: .native
        ))
        XCTAssertEqual(newer.diffDetails(comparedTo: older), [
            "One-time password configuration updated",
            "Custom field updated: PIN"
        ])
    }
}
