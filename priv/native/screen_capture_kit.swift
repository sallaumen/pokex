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
    guard type == .screen,
          sampleBuffer.isValid,
          let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)
    else {
      return
    }

    lock.lock()
    latestFrame = pixelBuffer
    stoppedError = nil
    lock.unlock()
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
    configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
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

@main
struct ScreenCaptureKitHelper {
  static func main() {
    let writer = JsonWriter()

    Task {
      do {
        let runtime = try await withTimeout(seconds: 12.0) {
          let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
          )

          return try await CaptureRuntime.start(from: content)
        }

        writer.write([
          "ready": true,
          "display_width": runtime.display.width,
          "display_height": runtime.display.height,
          "scale": Double(runtime.scale),
        ])

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
      } catch {
        writer.write(["ready": false, "error": "\(error)"])
        exit(1)
      }
    }

    RunLoop.main.run()
  }
}
