import CryptoKit
import Darwin
import Foundation

// The file hash identifies
// bytes observed at the embedded-helper path, not the image the kernel ran.
nonisolated struct SectionsBuildAttribution: Sendable {

  static func lowercaseHex(_ value: String, count: Int) -> Bool {
    value.utf8.count == count
      && value.utf8.allSatisfy {
        ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102)
      }
  }

  static func helperDigest(_ helper: URL, deadline: UInt64) throws -> String {
    let bytes = try boundedFile(helper, maximum: 16 * 1024 * 1024, deadline: deadline)
    guard DispatchTime.now().uptimeNanoseconds < deadline else {
      throw AttributionFailure.unverified
    }
    let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    guard DispatchTime.now().uptimeNanoseconds < deadline else {
      throw AttributionFailure.unverified
    }
    return digest
  }

  // Byte and admission/time checks, not cancellation of an in-flight read.
  // All paths come from the app bundle, never the helper's JSON response.
  private static func boundedFile(_ url: URL, maximum: Int, deadline: UInt64) throws -> Data {
    let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW)
    guard descriptor >= 0 else { throw AttributionFailure.unverified }
    defer { close(descriptor) }
    var initial = stat()
    guard fstat(descriptor, &initial) == 0,
      initial.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
      initial.st_size >= 0, initial.st_size <= maximum
    else { throw AttributionFailure.unverified }
    var result = Data()
    var buffer = [UInt8](repeating: 0, count: 65536)
    while true {
      guard DispatchTime.now().uptimeNanoseconds < deadline else {
        throw AttributionFailure.unverified
      }
      let count = read(descriptor, &buffer, min(buffer.count, maximum + 1 - result.count))
      guard count >= 0 else { throw AttributionFailure.unverified }
      if count == 0 { break }
      result.append(contentsOf: buffer.prefix(count))
      guard result.count <= maximum else { throw AttributionFailure.unverified }
    }
    var final = stat()
    guard fstat(descriptor, &final) == 0,
      initial.st_dev == final.st_dev, initial.st_ino == final.st_ino,
      initial.st_size == final.st_size,
      initial.st_mtimespec.tv_sec == final.st_mtimespec.tv_sec,
      initial.st_mtimespec.tv_nsec == final.st_mtimespec.tv_nsec,
      initial.st_ctimespec.tv_sec == final.st_ctimespec.tv_sec,
      initial.st_ctimespec.tv_nsec == final.st_ctimespec.tv_nsec,
      result.count == Int(final.st_size)
    else { throw AttributionFailure.unverified }
    return result
  }

  enum AttributionFailure: Error { case unverified }
}
