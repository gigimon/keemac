import Foundation

enum TestSupport {
    static func makeTemporaryFile(
        fileExtension: String? = nil,
        contents: Data = Data()
    ) throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("KeeMacTests", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        var fileName = UUID().uuidString
        if let fileExtension, !fileExtension.isEmpty {
            fileName += ".\(fileExtension)"
        }
        let url = root.appendingPathComponent(fileName)
        try contents.write(to: url, options: .atomic)
        return url
    }

    static func removeIfExists(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}
