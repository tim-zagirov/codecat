import Foundation

/// Unix datagram socket server. One event = one datagram, no accept loop.
///
/// The read source is attached to the `.main` dispatch queue so that
/// `onEvent` is always invoked on the main thread — required because its
/// consumer (`SessionStore`) is not thread-safe and is bound to SwiftUI views.
public final class HookSocketServer {
    private let path: URL
    private let onEvent: (HookEvent) -> Void
    private var fd: Int32 = -1
    private var source: DispatchSourceRead?

    public init(path: URL, onEvent: @escaping (HookEvent) -> Void) {
        self.path = path
        self.onEvent = onEvent
    }

    public func start() throws {
        unlink(path.path)
        let newFd = socket(AF_UNIX, SOCK_DGRAM, 0)
        guard newFd >= 0 else { throw POSIXError(.EBADF) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let ok = path.path.withCString { cstr -> Bool in
            let len = strlen(cstr)
            guard len < MemoryLayout.size(ofValue: addr.sun_path) else { return false }
            withUnsafeMutableBytes(of: &addr.sun_path) { dst in
                dst.baseAddress!.copyMemory(from: cstr, byteCount: len + 1)
            }
            return true
        }
        guard ok else { close(newFd); throw POSIXError(.ENAMETOOLONG) }

        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(newFd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else { close(newFd); throw POSIXError(.EADDRINUSE) }

        fd = newFd
        let src = DispatchSource.makeReadSource(fileDescriptor: newFd, queue: .main)
        src.setEventHandler { [weak self] in self?.readDatagram() }
        src.resume()
        source = src
    }

    public func stop() {
        source?.cancel()
        source = nil
        if fd >= 0 { close(fd); fd = -1 }
        unlink(path.path)
    }

    private func readDatagram() {
        var buffer = [UInt8](repeating: 0, count: 65536)
        let n = recv(fd, &buffer, buffer.count, 0)
        guard n > 0 else { return }
        let data = Data(buffer[0..<n])
        if let event = try? JSONDecoder().decode(HookEvent.self, from: data) {
            onEvent(event)
        }
    }
}

/// One-shot fire-and-forget client used by the `codecat-hook` CLI: sends a
/// single datagram and never blocks the caller on failure.
public enum HookSocketClient {
    @discardableResult
    public static func send(_ data: Data, to path: URL) -> Bool {
        let fd = socket(AF_UNIX, SOCK_DGRAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let ok = path.path.withCString { cstr -> Bool in
            let len = strlen(cstr)
            guard len < MemoryLayout.size(ofValue: addr.sun_path) else { return false }
            withUnsafeMutableBytes(of: &addr.sun_path) { dst in
                dst.baseAddress!.copyMemory(from: cstr, byteCount: len + 1)
            }
            return true
        }
        guard ok else { return false }

        let sent = data.withUnsafeBytes { raw in
            withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(fd, raw.baseAddress, raw.count, 0, $0,
                           socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
        }
        return sent == data.count
    }
}
