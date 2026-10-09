import Darwin
import Foundation

/// Who is asking: the process on the other end of the socket and its parents (ssh ← git ← Terminal).
public struct SSHAgentClient: Sendable, Equatable {
    public struct Process: Sendable, Equatable {
        public let pid: pid_t
        public let name: String
    }

    /// The connecting process first, then its parents up to (not including) launchd.
    public let processes: [Process]

    public var pid: pid_t? { processes.first?.pid }
    public var name: String { processes.first?.name ?? "ssh" }

    static func of(descriptor: Int32) -> SSHAgentClient {
        var pid: pid_t = 0
        var length = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(descriptor, SOL_LOCAL, LOCAL_PEERPID, &pid, &length) == 0, pid > 0 else {
            return SSHAgentClient(processes: [])
        }
        var processes: [Process] = []
        var current = pid
        while current > 1, processes.count < 8 {
            processes.append(Process(pid: current, name: processName(current)))
            guard let parent = parentPID(of: current), parent != current else { break }
            current = parent
        }
        return SSHAgentClient(processes: processes)
    }

    private static func processName(_ pid: pid_t) -> String {
        var buffer = [CChar](repeating: 0, count: 256)
        let length = proc_name(pid, &buffer, UInt32(buffer.count))
        return length > 0 ? String(cString: buffer) : "pid \(pid)"
    }

    private static func parentPID(of pid: pid_t) -> pid_t? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return pid_t(info.pbi_ppid)
    }
}

/// `session-bind@openssh.com`: the server ssh is talking to, as ssh saw it after key exchange.
public struct SSHSessionBinding: Sendable, Equatable {
    /// The server's host key in the wire format.
    public let hostKey: Data
    public let sessionIdentifier: Data
    /// The server's signature over the session identifier.
    public let signature: Data
    /// The request comes through agent forwarding (`ssh -A`) from that server.
    public let isForwarding: Bool
}

/// One request as the backend sees it.
public struct SSHAgentRequest: Sendable {
    public let connectionID: Int
    public let client: SSHAgentClient
    /// Every `session-bind` on this connection, oldest first; the last one is the server being logged in to.
    public let bindings: [SSHSessionBinding]

    public var destination: SSHSessionBinding? { bindings.last }
    /// Forwarded from another server when any binding says so.
    public var isForwarded: Bool { bindings.contains { $0.isForwarding } }
}

public struct SSHAgentIdentity: Sendable, Equatable {
    public let publicKeyBlob: Data
    public let comment: String

    public init(publicKeyBlob: Data, comment: String) {
        self.publicKeyBlob = publicKeyBlob
        self.comment = comment
    }
}

/// What the agent asks KeeMac for. Answers may wait for the user (confirmation, unlock).
public protocol SSHAgentBackend: Sendable {
    func identities(for request: SSHAgentRequest) async -> [SSHAgentIdentity]
    /// The signature blob, or nil to refuse.
    func sign(publicKeyBlob: Data, data: Data, flags: UInt32, for request: SSHAgentRequest) async -> Data?
}

/// The OpenSSH agent protocol (draft-miller-ssh-agent), without any socket.
public enum SSHAgentProtocol {
    static let failure: UInt8 = 5
    static let success: UInt8 = 6
    static let requestIdentities: UInt8 = 11
    static let identitiesAnswer: UInt8 = 12
    static let signRequest: UInt8 = 13
    static let signResponse: UInt8 = 14
    static let extensionRequest: UInt8 = 27
    public static let maximumMessageSize = 256 * 1024

    /// Parses `session-bind@openssh.com` extension contents.
    static func sessionBinding(_ contents: Data) throws -> SSHSessionBinding {
        var reader = SSHReader(contents)
        let hostKey = try reader.string()
        let sessionIdentifier = try reader.string()
        let signature = try reader.string()
        let forwarding = try reader.byte() != 0
        return SSHSessionBinding(hostKey: hostKey, sessionIdentifier: sessionIdentifier, signature: signature, isForwarding: forwarding)
    }

    static func identitiesAnswer(_ identities: [SSHAgentIdentity]) -> Data {
        var writer = SSHWriter()
        writer.byte(identitiesAnswer)
        writer.uint32(UInt32(identities.count))
        for identity in identities {
            writer.string(identity.publicKeyBlob)
            writer.string(identity.comment)
        }
        return writer.data
    }

    static func signResponse(_ signature: Data) -> Data {
        var writer = SSHWriter()
        writer.byte(signResponse)
        writer.string(signature)
        return writer.data
    }
}

/// Listens on the agent socket. Requests of one connection are answered in order, like ssh expects.
public final class SSHAgentServer: @unchecked Sendable {
    public enum StartError: Error, Equatable {
        /// Another KeeMac (or another agent) already serves this socket.
        case alreadyInUse
        case socketFailure(Int32)
    }

    /// `~/.keemac/agent.sock`: short, no spaces, so it fits `IdentityAgent` and `sockaddr_un`.
    public static var defaultSocketPath: String {
        NSHomeDirectory() + "/.keemac/agent.sock"
    }

    /// Mutable state is touched on `queue` only.
    private final class Connection: @unchecked Sendable {
        let id: Int
        let descriptor: Int32
        let source: DispatchSourceRead
        let client: SSHAgentClient
        var buffer = Data()
        var bindings: [SSHSessionBinding] = []
        /// The request being answered; the next one waits for it.
        var tail: Task<Void, Never>?

        init(id: Int, descriptor: Int32, source: DispatchSourceRead, client: SSHAgentClient) {
            self.id = id
            self.descriptor = descriptor
            self.source = source
            self.client = client
        }
    }

    private let backend: SSHAgentBackend
    public let path: String
    private let queue = DispatchQueue(label: "KeeMac.SSHAgentServer")
    private var listener: DispatchSourceRead?
    private var connections: [Int: Connection] = [:]
    private var nextConnectionID = 1

    public init(backend: SSHAgentBackend, path: String = SSHAgentServer.defaultSocketPath) {
        self.backend = backend
        self.path = path
    }

    deinit {
        listener?.cancel()
        for connection in connections.values {
            connection.source.cancel()
        }
    }

    public var isRunning: Bool {
        queue.sync { listener != nil }
    }

    public func start() throws {
        try queue.sync {
            guard listener == nil else { return }
            let directory = (path as NSString).deletingLastPathComponent
            try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            chmod(directory, 0o700)
            if Self.isServed(path) {
                throw StartError.alreadyInUse
            }
            unlink(path)

            let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
            guard descriptor >= 0 else { throw StartError.socketFailure(errno) }
            guard var address = Self.address(for: path) else {
                close(descriptor)
                throw StartError.socketFailure(ENAMETOOLONG)
            }
            let bound = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard bound == 0, chmod(path, 0o600) == 0, listen(descriptor, 16) == 0 else {
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
            guard let listener else { return }
            listener.cancel()
            self.listener = nil
            for connection in connections.values {
                connection.tail?.cancel()
                connection.source.cancel()
            }
            connections.removeAll()
            unlink(path)
        }
    }

    private func acceptConnections(on listenerDescriptor: Int32) {
        while true {
            let descriptor = accept(listenerDescriptor, nil, nil)
            guard descriptor >= 0 else { return }
            var noSigPipe: Int32 = 1
            setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
            let id = nextConnectionID
            nextConnectionID += 1
            let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
            let connection = Connection(id: id, descriptor: descriptor, source: source, client: SSHAgentClient.of(descriptor: descriptor))
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
            let length = connection.buffer.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
            guard length > 0, length <= SSHAgentProtocol.maximumMessageSize else {
                disconnect(connection)
                return
            }
            guard connection.buffer.count >= 4 + length else { break }
            let message = Data(connection.buffer.dropFirst(4).prefix(length))
            connection.buffer = Data(connection.buffer.dropFirst(4 + length))
            enqueue(message, on: connection)
        }
    }

    private func enqueue(_ message: Data, on connection: Connection) {
        let previous = connection.tail
        connection.tail = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            let reply = await self.reply(to: message, on: connection)
            self.queue.async {
                guard self.connections[connection.id] != nil else { return }
                Self.send(reply, to: connection.descriptor)
            }
        }
    }

    private func reply(to message: Data, on connection: Connection) async -> Data {
        var reader = SSHReader(message)
        guard let type = try? reader.byte() else {
            return Data([SSHAgentProtocol.failure])
        }
        switch type {
        case SSHAgentProtocol.requestIdentities:
            let identities = await backend.identities(for: request(for: connection))
            return SSHAgentProtocol.identitiesAnswer(identities)
        case SSHAgentProtocol.signRequest:
            guard let blob = try? reader.string(), let data = try? reader.string() else {
                return Data([SSHAgentProtocol.failure])
            }
            let flags = (try? reader.uint32()) ?? 0
            guard let signature = await backend.sign(publicKeyBlob: blob, data: data, flags: flags, for: request(for: connection)) else {
                return Data([SSHAgentProtocol.failure])
            }
            return SSHAgentProtocol.signResponse(signature)
        case SSHAgentProtocol.extensionRequest:
            guard let name = try? reader.text(), name == "session-bind@openssh.com",
                  let binding = try? SSHAgentProtocol.sessionBinding(reader.remaining) else {
                return Data([SSHAgentProtocol.failure])
            }
            queue.sync {
                connection.bindings.append(binding)
            }
            return Data([SSHAgentProtocol.success])
        default:
            // Keys live in the database: adding, removing and locking from outside are refused.
            return Data([SSHAgentProtocol.failure])
        }
    }

    private func request(for connection: Connection) -> SSHAgentRequest {
        let bindings = queue.sync { connection.bindings }
        return SSHAgentRequest(connectionID: connection.id, client: connection.client, bindings: bindings)
    }

    private func disconnect(_ connection: Connection) {
        connection.tail?.cancel()
        connection.source.cancel()
        connections[connection.id] = nil
    }

    private static func send(_ message: Data, to descriptor: Int32) {
        var frame = Data()
        let length = UInt32(message.count)
        frame.append(contentsOf: [UInt8(length >> 24), UInt8(length >> 16 & 0xFF), UInt8(length >> 8 & 0xFF), UInt8(length & 0xFF)])
        frame.append(message)
        frame.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let written = write(descriptor, bytes.baseAddress! + offset, bytes.count - offset)
                if written < 0, errno == EINTR || errno == EAGAIN {
                    continue
                }
                guard written > 0 else { return }
                offset += written
            }
        }
    }

    static func address(for path: String) -> sockaddr_un? {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: bytes)
        }
        return address
    }

    /// True when something answers on the socket (another agent is running there).
    static func isServed(_ path: String) -> Bool {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0, var address = address(for: path) else { return false }
        defer { close(descriptor) }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        return connected == 0
    }
}
