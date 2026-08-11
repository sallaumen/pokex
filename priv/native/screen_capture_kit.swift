import AppKit
import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

final class JsonWriter: @unchecked Sendable {
  private let lock = NSLock()

  func write(_ object: [String: Any]) {
    lock.lock()
    defer { lock.unlock() }

    if let data = try? JSONSerialization.data(withJSONObject: object, options: []),
       let line = String(data: data, encoding: .utf8)
    {
      print(line)
      fflush(stdout)
    }
  }
}

final class FrameStore: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
  private let lock = NSLock()
  private let context = CIContext()
  private var latestFrame: CVPixelBuffer?
  private var stoppedError: String?
  private let pointToPixelScale: CGFloat

  init(pointToPixelScale: CGFloat) {
    self.pointToPixelScale = pointToPixelScale
  }

  func stream(
    _ stream: SCStream,
    didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
    of type: SCStreamOutputType
  ) {
    // The stream queue's implicit autorelease pool drains LAZILY under constant
    // load — at 10fps of ~80MB retina frames the autoreleased sample wrappers
    // piled up to a measured 19GB RSS (2026-07-11), thrashing the helper until
    // every SCK capture timed out and the broker fell back to 250ms
    // screencapture. Drain per frame.
    autoreleasepool {
      guard type == .screen,
            sampleBuffer.isValid,
            let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)
      else {
        return
      }

      // DEEP-COPY the frame and let the pool buffer go. Retaining the pool's CVPixelBuffer
      // (queueDepth 3) starves ScreenCaptureKit's buffer pool after the first frames, and the
      // stream SILENTLY stops delivering — every crop then serves the same stale boot-time
      // frame forever ("fixadamente zero" readings, debugged live 2026-07-10: two server crops
      // 3s apart were byte-identical while the real screen had the lure in the water). ARC keeps
      // the previous copy alive while a writeCrop is still rendering it, so no tearing either.
      guard let copy = deepCopy(pixelBuffer) else { return }

      lock.lock()
      latestFrame = copy
      stoppedError = nil
      lock.unlock()
    }
  }

  private func deepCopy(_ source: CVPixelBuffer) -> CVPixelBuffer? {
    let width = CVPixelBufferGetWidth(source)
    let height = CVPixelBufferGetHeight(source)
    let format = CVPixelBufferGetPixelFormatType(source)

    var created: CVPixelBuffer?

    guard CVPixelBufferCreate(nil, width, height, format, nil, &created) == kCVReturnSuccess,
          let copy = created
    else {
      return nil
    }

    CVPixelBufferLockBaseAddress(source, .readOnly)
    CVPixelBufferLockBaseAddress(copy, [])

    defer {
      CVPixelBufferUnlockBaseAddress(copy, [])
      CVPixelBufferUnlockBaseAddress(source, .readOnly)
    }

    guard let sourceBase = CVPixelBufferGetBaseAddress(source),
          let copyBase = CVPixelBufferGetBaseAddress(copy)
    else {
      return nil
    }

    let sourceStride = CVPixelBufferGetBytesPerRow(source)
    let copyStride = CVPixelBufferGetBytesPerRow(copy)

    if sourceStride == copyStride {
      memcpy(copyBase, sourceBase, sourceStride * height)
    } else {
      let rowBytes = min(sourceStride, copyStride)

      for row in 0..<height {
        memcpy(
          copyBase.advanced(by: row * copyStride),
          sourceBase.advanced(by: row * sourceStride),
          rowBytes
        )
      }
    }

    return copy
  }

  func stream(_ stream: SCStream, didStopWithError error: Error) {
    let message = "ScreenCaptureKit stream stopped: \(error)"

    lock.lock()
    stoppedError = message
    lock.unlock()

    // The Elixir side treats a dead/failed helper as a signal to fall back to screencapture.
    fputs("\(message)\n", stderr)
  }

  func writeCrop(x: Int, y: Int, width: Int, height: Int, path: String) throws {
    // Same autorelease discipline as the stream callback: CI/CG rendering mints
    // autoreleased objects per crop, and crops arrive many times per second.
    try autoreleasepool {
      try writeCropInner(x: x, y: y, width: width, height: height, path: path)
    }
  }

  private func writeCropInner(x: Int, y: Int, width: Int, height: Int, path: String) throws {
    guard width > 0, height > 0 else {
      throw CaptureError.invalidRegion("region must have positive width/height")
    }

    let pixelBuffer = try waitForFrame(timeout: 2.0)

    let frameWidth = CVPixelBufferGetWidth(pixelBuffer)
    let frameHeight = CVPixelBufferGetHeight(pixelBuffer)

    let px = Int((CGFloat(x) * pointToPixelScale).rounded())
    let py = Int((CGFloat(y) * pointToPixelScale).rounded())
    let pw = Int((CGFloat(width) * pointToPixelScale).rounded())
    let ph = Int((CGFloat(height) * pointToPixelScale).rounded())

    guard px >= 0, py >= 0, pw > 0, ph > 0, px + pw <= frameWidth, py + ph <= frameHeight else {
      throw CaptureError.invalidRegion(
        "region \(x),\(y),\(width),\(height) -> \(px),\(py),\(pw),\(ph) outside frame \(frameWidth)x\(frameHeight)"
      )
    }

    let image = CIImage(cvPixelBuffer: pixelBuffer)
    // CIImage uses a bottom-left origin; the bot's screen regions use top-left coordinates.
    let cropRect = CGRect(x: px, y: frameHeight - py - ph, width: pw, height: ph)

    guard let cgImage = context.createCGImage(image.cropped(to: cropRect), from: cropRect) else {
      throw CaptureError.renderFailed
    }

    let url = URL(fileURLWithPath: path)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )

    // The caller asks for the format by extension. PNG exists to TRAVEL; these
    // frames never leave the machine and live for milliseconds. Encoding one
    // cost this helper time and cost Elixir up to 4.7 SECONDS to undo (measured
    // 2026-08-11 on the 3.2 Mpx capture square) for pixels already in memory here.
    if path.hasSuffix(".raw") {
      try writeRaw(cgImage, to: url)
      return
    }

    guard let destination = CGImageDestinationCreateWithURL(
      url as CFURL,
      UTType.png.identifier as CFString,
      1,
      nil
    ) else {
      throw CaptureError.writeFailed("could not create PNG destination")
    }

    CGImageDestinationAddImage(destination, cgImage, nil)

    guard CGImageDestinationFinalize(destination) else {
      throw CaptureError.writeFailed("could not finalize PNG")
    }
  }

  // RGBA8, row-major, behind a 13-byte header: "PXRW", format version, width
  // and height as big-endian UInt32. Reading it back in Elixir is a File.read
  // and one pattern match — 7ms against 4752ms of PNG decode for the same
  // 3.2 Mpx frame.
  private func writeRaw(_ image: CGImage, to url: URL) throws {
    let width = image.width
    let height = image.height
    let bytesPerRow = width * 4
    var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)

    guard let context = CGContext(
      data: &pixels,
      width: width,
      height: height,
      bitsPerComponent: 8,
      bytesPerRow: bytesPerRow,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        | CGBitmapInfo.byteOrder32Big.rawValue
    ) else {
      throw CaptureError.writeFailed("could not create RGBA context")
    }

    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

    var data = Data()
    data.append(contentsOf: Array("PXRW".utf8))
    data.append(1)
    appendBigEndian(&data, UInt32(width))
    appendBigEndian(&data, UInt32(height))
    data.append(contentsOf: pixels)
    try data.write(to: url)
  }

  private func appendBigEndian(_ data: inout Data, _ value: UInt32) {
    data.append(UInt8((value >> 24) & 0xFF))
    data.append(UInt8((value >> 16) & 0xFF))
    data.append(UInt8((value >> 8) & 0xFF))
    data.append(UInt8(value & 0xFF))
  }

  func waitForFrame(timeout: TimeInterval) throws -> CVPixelBuffer {
    let deadline = Date().addingTimeInterval(timeout)

    while Date() < deadline {
      lock.lock()
      let frame = latestFrame
      let error = stoppedError
      lock.unlock()

      if let error {
        throw CaptureError.streamStopped(error)
      }

      if let frame {
        return frame
      }

      Thread.sleep(forTimeInterval: 0.005)
    }

    throw CaptureError.noFrame
  }
}

final class CaptureRuntime: @unchecked Sendable {
  let display: SCDisplay
  let scale: CGFloat
  let store: FrameStore
  let stream: SCStream

  private init(display: SCDisplay, scale: CGFloat, store: FrameStore, stream: SCStream) {
    self.display = display
    self.scale = scale
    self.store = store
    self.stream = stream
  }

  static func start(from content: SCShareableContent) async throws -> CaptureRuntime {
    let (display, scale) = try mainDisplayAndScale(from: content)
    let store = FrameStore(pointToPixelScale: scale)
    let filter = SCContentFilter(display: display, excludingWindows: [])
    let configuration = SCStreamConfiguration()

    configuration.width = display.width
    configuration.height = display.height
    configuration.pixelFormat = kCVPixelFormatType_32BGRA
    configuration.queueDepth = 3
    // 10fps: every frame is deep-copied (~19MB on the 3440x1440 display), and no consumer reads
    // faster than the perception feeds' ~120ms cadence — 30fps would triple the copy cost for
    // frames nobody looks at.
    configuration.minimumFrameInterval = CMTime(value: 1, timescale: 10)
    configuration.showsCursor = false

    let stream = SCStream(filter: filter, configuration: configuration, delegate: store)
    try stream.addStreamOutput(
      store,
      type: .screen,
      sampleHandlerQueue: DispatchQueue(label: "pokex.sck.frames")
    )
    try await stream.startCapture()

    _ = try store.waitForFrame(timeout: 5.0)

    return CaptureRuntime(display: display, scale: scale, store: store, stream: stream)
  }
}

enum CaptureError: Error, CustomStringConvertible {
  case invalidRegion(String)
  case noFrame
  case renderFailed
  case startupTimeout(String)
  case streamStopped(String)
  case writeFailed(String)

  var description: String {
    switch self {
    case .invalidRegion(let message):
      return message
    case .noFrame:
      return "no frame available from ScreenCaptureKit"
    case .renderFailed:
      return "could not render cropped frame"
    case .startupTimeout(let message):
      return message
    case .streamStopped(let message):
      return message
    case .writeFailed(let message):
      return message
    }
  }
}

func mainDisplayAndScale(from content: SCShareableContent) throws -> (SCDisplay, CGFloat) {
  let mainDisplayID = CGMainDisplayID()

  guard let display = content.displays.first(where: { $0.displayID == mainDisplayID })
        ?? content.displays.first
  else {
    throw CaptureError.writeFailed("no capturable display found")
  }

  let screen = NSScreen.screens.first { screen in
    guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
            as? NSNumber
    else {
      return false
    }

    return number.uint32Value == display.displayID
  }

  let scale: CGFloat

  if let screen, screen.frame.width > 0 {
    scale = CGFloat(display.width) / screen.frame.width
  } else {
    scale = NSScreen.main?.backingScaleFactor ?? 1.0
  }

  return (display, max(scale, 1.0))
}

func intField(_ object: [String: Any], _ key: String) throws -> Int {
  if let value = object[key] as? Int {
    return value
  }

  if let value = object[key] as? NSNumber {
    return value.intValue
  }

  throw CaptureError.writeFailed("missing integer field \(key)")
}

func withTimeout<T: Sendable>(
  seconds: TimeInterval,
  operation: @escaping @Sendable () async throws -> T
) async throws -> T {
  try await withThrowingTaskGroup(of: T.self) { group in
    defer { group.cancelAll() }

    group.addTask {
      try await operation()
    }

    group.addTask {
      let nanoseconds = UInt64(seconds * 1_000_000_000)
      try await Task.sleep(nanoseconds: nanoseconds)
      throw CaptureError.startupTimeout("timed out waiting for ScreenCaptureKit startup")
    }

    guard let result = try await group.next() else {
      throw CaptureError.startupTimeout("ScreenCaptureKit startup task ended without a result")
    }

    return result
  }
}

// The runtime lands here once the stream is up. It exists so the stdin loop can start BEFORE
// stream setup: a request that arrives early just answers "stream not ready" instead of the
// loop itself waiting on the stream.
final class RuntimeHolder: @unchecked Sendable {
  private let lock = NSLock()
  private var runtime: CaptureRuntime?

  func set(_ value: CaptureRuntime) {
    lock.lock()
    runtime = value
    lock.unlock()
  }

  func get() -> CaptureRuntime? {
    lock.lock()
    defer { lock.unlock() }
    return runtime
  }
}

@main
struct ScreenCaptureKitHelper {
  static func main() {
    let writer = JsonWriter()
    let holder = RuntimeHolder()

    // stdin loop + LIFELINE, alive from the very first instant: readLine() returning nil means
    // the BEAM closed the port (gave up on us, or died) — exit NOW, whatever the stream setup is
    // doing. The old code only started this loop AFTER the stream came up, so a start that
    // outlived the supervisor's patience left an orphaned helper running its SCStream forever —
    // measured on Lucas's machine: dozens of zombies, each pumping frames, starving the SCK
    // daemon until every new stream start timed out.
    DispatchQueue.global(qos: .userInitiated).async {
      while let line = readLine() {
        guard let data = line.data(using: .utf8) else {
          writer.write(["ok": false, "error": "invalid utf8"])
          continue
        }

        do {
          guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                object["op"] as? String == "capture",
                let path = object["path"] as? String
          else {
            throw CaptureError.writeFailed("invalid request")
          }

          guard let runtime = holder.get() else {
            throw CaptureError.writeFailed("stream not ready")
          }

          try runtime.store.writeCrop(
            x: intField(object, "x"),
            y: intField(object, "y"),
            width: intField(object, "w"),
            height: intField(object, "h"),
            path: path
          )

          writer.write(["ok": true, "path": path])
        } catch {
          writer.write(["ok": false, "error": "\(error)"])
        }
      }

      exit(0)
    }

    Task {
      do {
        let runtime = try await withTimeout(seconds: 12.0) {
          let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
          )

          return try await CaptureRuntime.start(from: content)
        }

        // Publish the runtime BEFORE announcing ready, so a capture that races the announcement
        // can never see "stream not ready".
        holder.set(runtime)

        writer.write([
          "ready": true,
          "display_width": runtime.display.width,
          "display_height": runtime.display.height,
          "scale": Double(runtime.scale),
        ])
      } catch {
        writer.write(["ready": false, "error": "\(error)"])
        exit(1)
      }
    }

    RunLoop.main.run()
  }
}
