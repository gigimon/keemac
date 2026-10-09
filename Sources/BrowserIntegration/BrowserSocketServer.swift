import Darwin
import Foundation

/// Listens on `BrowserProtocol.socketPath` for `keemac-proxy` connections.
/// Frames are a 4-byte native-endian length followed by the JSON message, the same as native messaging.
public final class BrowserSocketServer: @unchecked Sendable {
    public enum StartError: Error {
        /// Another KeeMac instance already serves the socket.
        case alreadyInUse
        case socketFailure(Int32)
    }

    private final class Connection {
        let id: Int
        let descriptor: Int32
        let source: DispatchSourceRead
        var buffer = Data()

        init(id: Int, descriptor: Int32, source: DispatchSourceRead) {
            self.id = id
            self.descriptor = descriptor
            self.source = source
        }
    }

    private let handler: BrowserMessageHandler
    private let path: String
    /// Guards every member below.
    private let queue = DispatchQueue(label: "KeeMac.BrowserSocketServer")
    private var listener: DispatchSourceRead?
    private var connections: [Int: Connection] = [:]
    private var nextConnectionID = 1

    public init(handler: BrowserMessageHandler, path: String = BrowserProtocol.socketPath) {
        self.handler = handler
        self.path = path
    }

    deinit {
        listener?.cancel()
        for connection in connections.values {
            connection.source.cancel()
        }
    }

    public func start() throws {
        try queue.sync {
            guard listener == nil else {
                return
            }
            if Self.isServed(path) {
                throw StartError.alreadyInUse
            }
            unlink(path)

            let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
            guard descriptor >= 0 else {
                throw StartError.socketFailure(errno)
            }
            guard var address = Self.address(for: path) else {
                close(descriptor)
                throw StartError.socketFailure(ENAMETOOLONG)
            }
            let bound = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard bound == 0, chmod(path, 0o600) == 0, listen(descriptor, 8) == 0 else {
                let code = errno
                close(descriptor)
                unlink(path)
                throw StartError.socketFailure(code)
            }
            _ = fcntl(descriptor, F_SETFL, O_NONBLOCK)

            let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
            source.setEventHandler { [weak self] in
                self?.acceptConnections(on: descriptor)
            }
            source.setCancelHandler {
                close(descriptor)
            }
            source.resume()
            listener = source
        }
    }

    public func stop() {
        queue.sync {
            guard let listener else {
                return
            }
            listener.cancel()
            self.listener = nil
            for connection in connections.values {
                connection.source.cancel()
            }
            connections.removeAll()
            unlink(path)
        }
    }

    public var isRunning: Bool {
        queue.sync { listener != nil }
    }

    /// Sends an unsolicited message to every connected browser.
    public func broadcast(_ message: Data) {
        queue.async {
            for connection in self.connections.values {
                Self.send(message, to: connection.descriptor)
            }
        }
    }

    private func acceptConnections(on listenerDescriptor: Int32) {
        while true {
            let descriptor = accept(listenerDescriptor, nil, nil)
            guard descriptor >= 0 else {
                return
            }
            var noSigPipe: Int32 = 1
            setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

            let id = nextConnectionID
            nextConnectionID += 1
            let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
            let connection = Connection(id: id, descriptor: descriptor, source: source)
            source.setEventHandler { [weak self] in
                self?.readAvailable(from: connection)
            }
            source.setCancelHandler {
                close(descriptor)
            }
            connections[id] = connection
            source.resume()
        }
    }

    private func readAvailable(from connection: Connection) {
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        let count = read(connection.descriptor, &chunk, chunk.count)
        if count < 0, errno == EINTR || errno == EAGAIN {
            return
        }
        guard count > 0 else {
            disconnect(connection)
            return
        }
        connection.buffer.append(contentsOf: chunk[0..<count])

        while connection.buffer.count >= 4 {
            let length = connection.buffer.prefix(4).withUnsafeBytes { Int($0.loadUnaligned(as: UInt32.self)) }
            guard length <= BrowserProtocol.maximumMessageSize else {
                disconnect(connection)
                return
            }
            guard connection.buffer.count >= 4 + length else {
                break
            }
            let message = Data(connection.buffer.dropFirst(4).prefix(length))
            connection.buffer = Data(connection.buffer.dropFirst(4 + length))
            dispatch(message, from: connection)
        }
    }

    private func dispatch(_ message: Data, from connection: Connection) {
        let handler = handler
        let id = connection.id
        let descriptor = connection.descriptor
        Task { [weak self] in
            let reply = await handler.handle(message, from: id)
            self?.deliver(reply, to: id, descriptor: descriptor)
        }
    }

    private func deliver(_ reply: Data, to id: Int, descriptor: Int32) {
        queue.async {
            guard self.connections[id] != nil else {
                return
            }
            Self.send(reply, to: descriptor)
        }
    }

    private func disconnect(_ connection: Connection) {
        connection.source.cancel()
        connections[connection.id] = nil
        let handler = handler
        let id = connection.id
        Task {
            await handler.endSession(id)
        }
    }

    private static func send(_ message: Data, to descriptor: Int32) {
        var length = UInt32(message.count)
        var frame = Data(bytes: &length, count: 4)
        frame.append(message)
        frame.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = write(descriptor, buffer.baseAddress! + offset, buffer.count - offset)
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

    private static func address(for path: String) -> sockaddr_un? {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8CString)
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            return nil
        }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            bytes.withUnsafeBytes { buffer.copyMemory(from: $0) }
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        return address
    }

    /// True when something accepts connections on `path`, so a stale socket file can be told from a live one.
    private static func isServed(_ path: String) -> Bool {
        guard var address = address(for: path) else {
            return false
        }
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            return false
        }
        defer { Darwin.close(descriptor) }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        return result == 0
    }
}
