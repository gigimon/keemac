import Darwin
import Foundation

// Native messaging host for KeePassXC-Browser. The browser starts it and talks over stdio
// (4-byte native-endian length + JSON); KeeMac's socket uses the same framing, so the bytes
// are relayed unchanged in both directions. Keep the socket path in sync with BrowserProtocol.socketPath.
// KEEMAC_BROWSER_SOCKET overrides the path (tests).

func socketPath() -> String {
    if let override = ProcessInfo.processInfo.environment["KEEMAC_BROWSER_SOCKET"], !override.isEmpty {
        return override
    }
    var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
    let length = confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, buffer.count)
    var directory = NSTemporaryDirectory()
    if length > 0, length <= buffer.count {
        directory = String(decoding: buffer.prefix(length - 1).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
    if !directory.hasSuffix("/") {
        directory += "/"
    }
    return directory + "KeeMac.BrowserServer"
}

func connectToKeeMac() -> Int32? {
    let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
    guard descriptor >= 0 else {
        return nil
    }
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let path = Array(socketPath().utf8CString)
    guard path.count <= MemoryLayout.size(ofValue: address.sun_path) else {
        close(descriptor)
        return nil
    }
    withUnsafeMutableBytes(of: &address.sun_path) { buffer in
        path.withUnsafeBytes { buffer.copyMemory(from: $0) }
    }
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    let result = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    guard result == 0 else {
        close(descriptor)
        return nil
    }
    return descriptor
}

/// Copies everything from `source` to `destination` until either side closes.
func relay(from source: Int32, to destination: Int32) {
    var buffer = [UInt8](repeating: 0, count: 64 * 1024)
    while true {
        let count = read(source, &buffer, buffer.count)
        if count < 0, errno == EINTR {
            continue
        }
        guard count > 0 else {
            return
        }
        var offset = 0
        while offset < count {
            let written = buffer[offset..<count].withUnsafeBytes { write(destination, $0.baseAddress, $0.count) }
            if written < 0, errno == EINTR {
                continue
            }
            guard written > 0 else {
                return
            }
            offset += written
        }
    }
}

signal(SIGPIPE, SIG_IGN)

guard let server = connectToKeeMac() else {
    FileHandle.standardError.write(Data("KeeMac is not running or browser integration is off.\n".utf8))
    exit(1)
}

let browserToKeeMac = Thread {
    relay(from: STDIN_FILENO, to: server)
    exit(0)
}
browserToKeeMac.start()

relay(from: server, to: STDOUT_FILENO)
exit(0)
