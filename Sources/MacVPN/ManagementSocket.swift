import Darwin
import Foundation

/// 管理连接只在专用串行队列读写，凭据通过本机 Unix socket 传给 OpenVPN。
final class ManagementSocket: @unchecked Sendable {
    private let queue = DispatchQueue(label: "MacVPN.Management")
    private let directory: URL?
    let path: String
    private let receive: @Sendable (String) -> Void
    private let didClose: @Sendable () -> Void
    private let expectedUID: uid_t
    private let password: String?
    private var listener: DispatchSourceRead?
    private var reader: DispatchSourceRead?
    private var connection: Int32 = -1
    private var input = Data()

    convenience init(directory: URL, expectedUID: uid_t = 0, receive: @escaping @Sendable (String) -> Void,
                     didClose: @escaping @Sendable () -> Void) throws {
        try self.init(path: directory.appending(path: "management").path, directory: directory,
                      expectedUID: expectedUID, password: nil, receive: receive, didClose: didClose)
    }

    convenience init(connectingTo path: String, password: String, expectedUID: uid_t = 0, receive: @escaping @Sendable (String) -> Void,
                     didClose: @escaping @Sendable () -> Void) throws {
        try self.init(path: path, directory: nil, expectedUID: expectedUID, password: password, receive: receive, didClose: didClose)
    }

    private init(path: String, directory: URL?, expectedUID: uid_t, password: String?, receive: @escaping @Sendable (String) -> Void,
                 didClose: @escaping @Sendable () -> Void) throws {
        self.directory = directory
        self.expectedUID = expectedUID
        self.password = password
        self.receive = receive
        self.didClose = didClose
        self.path = path
        var address = sockaddr_un()
        let pathBytes = Array(path.utf8CString)
        guard pathBytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            throw POSIXError(.ENAMETOOLONG)
        }
        address.sun_family = sa_family_t(AF_UNIX)
        let addressSize = socklen_t(MemoryLayout<sockaddr_un>.size)
        address.sun_len = UInt8(addressSize)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: pathBytes.map(UInt8.init(bitPattern:)))
        }

        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Self.systemError() }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                if directory != nil { return bind(fd, $0, addressSize) }
                return Darwin.connect(fd, $0, addressSize)
            }
        }
        guard result == 0 else {
            let error = Self.systemError()
            Darwin.close(fd)
            throw error
        }
        if directory == nil {
            guard adoptPeer(fd) else { throw POSIXError(.EACCES) }
            return
        }
        guard listen(fd, 4) == 0, fcntl(fd, F_SETFD, FD_CLOEXEC) == 0,
              fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else {
            let error = Self.systemError()
            Darwin.close(fd)
            throw error
        }
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptPeer(from: fd) }
        source.setCancelHandler { Darwin.close(fd) }
        listener = source
        source.resume()
    }

    func send(_ commands: [String]) {
        let data = Data((commands.joined(separator: "\n") + "\n").utf8)
        queue.async { [self] in
            guard connection >= 0 else { return }
            let success = data.withUnsafeBytes { buffer in
                guard let address = buffer.baseAddress else { return true }
                var offset = 0
                while offset < buffer.count {
                    let count = Darwin.send(connection, address.advanced(by: offset), buffer.count - offset, 0)
                    if count < 0, errno == EINTR { continue }
                    guard count > 0 else { return false }
                    offset += count
                }
                return true
            }
            if !success { closeOnQueue(notify: true) }
        }
    }

    func close() {
        queue.async { [self] in closeOnQueue(notify: false) }
    }

    private func acceptPeer(from listenerFD: Int32) {
        guard connection < 0, listener != nil else { return }
        let fd = accept(listenerFD, nil, nil)
        guard fd >= 0 else { return }
        _ = adoptPeer(fd)
    }

    private func adoptPeer(_ fd: Int32) -> Bool {
        var uid: uid_t = 0
        var gid: gid_t = 0
        var noSignal: Int32 = 1
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        guard getpeereid(fd, &uid, &gid) == 0, uid == expectedUID,
              fcntl(fd, F_SETFD, FD_CLOEXEC) == 0,
              setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size)) == 0,
              setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)) == 0 else {
            Darwin.close(fd)
            return false
        }
        listener?.cancel()
        listener = nil
        connection = fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.readPeer(from: fd) }
        source.setCancelHandler { Darwin.close(fd) }
        reader = source
        source.resume()
        let initial = password.map { [$0] } ?? []
        send(initial + ["state on", "log on all", "bytecount 1"])
        return true
    }

    private func readPeer(from fd: Int32) {
        guard connection == fd else { return }
        var bytes = [UInt8](repeating: 0, count: 8_192)
        let count = recv(fd, &bytes, bytes.count, 0)
        if count < 0, errno == EINTR || errno == EAGAIN { return }
        guard count > 0 else {
            closeOnQueue(notify: true)
            return
        }
        input.append(contentsOf: bytes.prefix(count))
        var start = input.startIndex
        while let newline = input[start...].firstIndex(of: 10) {
            var line = input[start..<newline]
            if line.last == 13 { line = line.dropLast() }
            receive(String(decoding: line, as: UTF8.self))
            start = newline + 1
        }
        input.removeSubrange(..<start)
        if input.count > 128_000 { closeOnQueue(notify: true) }
    }

    private func closeOnQueue(notify: Bool) {
        guard listener != nil || reader != nil else { return }
        listener?.cancel()
        reader?.cancel()
        if connection >= 0 { shutdown(connection, SHUT_RDWR) }
        listener = nil
        reader = nil
        connection = -1
        input.removeAll()
        if let directory { try? FileManager.default.removeItem(at: directory) }
        if notify { didClose() }
    }

    private static func systemError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
