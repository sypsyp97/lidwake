import Darwin
import Foundation

/// One request per connection: the herdr server answers one line, then closes.
public struct HerdrClient: Sendable {
  public static let maxResponseBytes = 4 * 1024 * 1024
  private static let request =
    Array(#"{"id":"lidwake","method":"session.snapshot","params":{}}"#.utf8) + [0x0A]
  private static let chunkSize = 64 * 1024

  private let socketPath: String
  private let timeout: TimeInterval

  public init(socketPath: String, timeout: TimeInterval = 2) {
    self.socketPath = socketPath
    // A zero timeval means "block forever" to setsockopt; keep a floor.
    self.timeout = max(timeout, 0.001)
  }

  public func snapshot() throws -> Data {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw HerdrError.io(errno) }
    defer { close(fd) }

    let deadline = Date().addingTimeInterval(timeout)
    try configure(fd)
    try connect(fd)
    try send(fd, deadline: deadline)
    return try receive(fd, deadline: deadline)
  }

  private func configure(_ fd: Int32) throws {
    let seconds = timeout.rounded(.down)
    var tv = timeval(tv_sec: Int(seconds), tv_usec: Int32((timeout - seconds) * 1_000_000))
    var one: Int32 = 1
    let size = socklen_t(MemoryLayout<timeval>.size)
    guard setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, size) == 0,
      setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, size) == 0,
      setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size)) == 0
    else { throw HerdrError.io(errno) }
  }

  private func connect(_ fd: Int32) throws {
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let path = Array(socketPath.utf8)
    let capacity = MemoryLayout.size(ofValue: address.sun_path)
    guard path.count < capacity else { throw HerdrError.connect(ENAMETOOLONG) }
    withUnsafeMutableBytes(of: &address.sun_path) { buffer in
      buffer.copyBytes(from: path)
    }
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    let result = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
        Darwin.connect(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    guard result == 0 else { throw HerdrError.connect(errno) }
  }

  private func send(_ fd: Int32, deadline: Date) throws {
    var offset = 0
    while offset < Self.request.count {
      let written = Self.request.withUnsafeBytes { bytes in
        write(fd, bytes.baseAddress.map { $0 + offset }, bytes.count - offset)
      }
      if written < 0 {
        try Self.retryOrThrow(errno, deadline: deadline)
        continue
      }
      offset += written
    }
  }

  private func receive(_ fd: Int32, deadline: Date) throws -> Data {
    var response = Data()
    var chunk = [UInt8](repeating: 0, count: Self.chunkSize)
    while true {
      let count = chunk.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
      if count < 0 {
        try Self.retryOrThrow(errno, deadline: deadline)
        continue
      }
      if count == 0 { return response }
      let bytes = chunk[0..<count]
      if let newline = bytes.firstIndex(of: 0x0A) {
        response.append(contentsOf: bytes[..<newline])
        guard response.count <= Self.maxResponseBytes else { throw HerdrError.tooLarge }
        return response
      }
      response.append(contentsOf: bytes)
      guard response.count <= Self.maxResponseBytes else { throw HerdrError.tooLarge }
      guard Date() < deadline else { throw HerdrError.timeout }
    }
  }

  /// EINTR retries until the deadline; SO_*TIMEO expiry is a timeout; anything else is I/O.
  private static func retryOrThrow(_ code: Int32, deadline: Date) throws {
    switch code {
    case EINTR where Date() < deadline: return
    case EINTR, EAGAIN: throw HerdrError.timeout
    default: throw HerdrError.io(code)
    }
  }
}
