// Native key-event helper: posts CGEvents for hold/release/press with ~1-2ms
// latency, replacing the ~60-100ms per-event osascript spawn on the mini-game's
// hot path. Line-based JSON protocol over stdio, one response per command:
//
//   -> {"op":"ping"}
//   <- {"ok":true}
//   -> {"op":"key","action":"down"|"up"|"press","code":49,"app":"wine"}
//   <- {"ok":true}
//   -> {"op":"middle_click","x":1200,"y":640,"app":"wine"}
//   <- {"ok":true}
//
// Ready line on boot: {"ready":true,"trusted":<bool>} — `trusted` is the
// Accessibility (AXIsProcessTrusted) grant, WITHOUT which posted events are
// silently dropped by macOS; the Elixir side falls back to osascript then.
// TCC identifies this ad-hoc binary by code hash: recompiling voids the grant
// (same story as the ScreenCaptureKit helper), so the Elixir side only
// rebuilds when the SOURCE SHA changes.
//
// Lifeline: the main loop reads stdin; EOF (the BEAM closed the port) exits
// immediately, so no orphan can outlive the app.

import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

@main
struct KeyEventsHelper {
  static func main() {
    // Prompt once when untrusted: pops the System Settings > Accessibility
    // dialog pointing at this helper, so the one-time grant is discoverable.
    let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
    let trusted = AXIsProcessTrustedWithOptions(options as CFDictionary)

    emit(["ready": true, "trusted": trusted])

    while let line = readLine(strippingNewline: true) {
      handle(line: line)
    }

    exit(0)
  }

  static func handle(line: String) {
    guard let data = line.data(using: .utf8),
      let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
      let op = json["op"] as? String
    else {
      emit(["ok": false, "error": "bad_command"])
      return
    }

    switch op {
    case "ping":
      emit(["ok": true])
    case "key":
      handleKey(json)
    case "middle_click":
      handleMiddleClick(json)
    case "middle_watch":
      handleMiddleWatch()
    case "key_watch":
      handleKeyWatch(json)
    default:
      emit(["ok": false, "error": "unknown_op:\(op)"])
    }
  }

  // How many middle clicks HE has made, and where the cursor is now.
  //
  // Not an event tap: `CGEventSource.counterForEventType` is a plain counter
  // of events seen by the session, so this needs no extra permission and
  // cannot swallow or delay one of his clicks. Polling the counter (rather
  // than the button STATE) is what makes a fast click impossible to miss —
  // the count still went up even if the button was already back when we
  // looked.
  //
  // The recorder uses it as the marker he asked for: "quando termino de
  // mobar... eu geralmente clico com o botão do meio do mouse em um ponto da
  // minha tela" (2026-08-11).
  static func handleMiddleWatch() {
    let count = CGEventSource.counterForEventType(.combinedSessionState, eventType: .otherMouseDown)
    let point = CGEvent(source: nil)?.location ?? .zero

    emit([
      "ok": true,
      "count": Int(count),
      "x": Int(point.x.rounded()),
      "y": Int(point.y.rounded()),
      // The SAME clock the key watcher stamps with: the huddle is measured
      // between a click and a key press, and two clocks would make that
      // subtraction meaningless.
      "at": Int(DispatchTime.now().uptimeNanoseconds / 1_000_000),
    ])
  }

  // ---------------------------------------------------------------------
  // Watching HIS keys, so the recording can learn what he was doing.
  //
  // "quando eu aperto Shift+3 é pq eu ja terminei de matar tudo, quando eu
  // aperto shift+1 é por que vou matar monstro" (Lucas, 2026-08-11) — the
  // boundaries of a fight, told by his own hands, plus the skills he fires in
  // between and how long he takes to fire them.
  //
  // Polled, never tapped: `CGEventSource.keyState` only ASKS whether a key is
  // down right now, so nothing is intercepted and no keystroke can be
  // swallowed by us. The polling runs INSIDE the helper at 8ms because a
  // press is ~60-100ms and a round trip from Elixir every 120ms would miss
  // most of them.
  static let watchLock = NSLock()
  static var watchedCodes: [CGKeyCode] = []
  static var wasDown: Set<CGKeyCode> = []
  static var keyBuffer: [[String: Any]] = []
  static var watching = false

  static func handleKeyWatch(_ json: [String: Any]) {
    if let codes = json["codes"] as? [Int] {
      watchLock.lock()
      watchedCodes = codes.map { CGKeyCode($0) }
      watchLock.unlock()
    }

    startWatchingIfNeeded()

    watchLock.lock()
    let events = keyBuffer
    keyBuffer = []
    watchLock.unlock()

    emit(["ok": true, "events": events])
  }

  static func startWatchingIfNeeded() {
    guard !watching else { return }
    watching = true

    Thread.detachNewThread {
      while true {
        pollWatchedKeys()
        usleep(8_000)
      }
    }
  }

  static func pollWatchedKeys() {
    watchLock.lock()
    let codes = watchedCodes
    watchLock.unlock()

    guard !codes.isEmpty else { return }

    let shift = CGEventSource.flagsState(.combinedSessionState).contains(.maskShift)
    let at = Int(DispatchTime.now().uptimeNanoseconds / 1_000_000)

    for code in codes {
      let down = CGEventSource.keyState(.combinedSessionState, key: code)

      watchLock.lock()
      let previously = wasDown.contains(code)

      if down && !previously {
        wasDown.insert(code)
        // A buffer nobody drains must not grow without bound: the recorder
        // drains every ~120ms, and 500 presses is far more than a session
        // between drains could ever produce.
        if keyBuffer.count < 500 {
          keyBuffer.append(["code": Int(code), "shift": shift, "at": at])
        }
      } else if !down && previously {
        wasDown.remove(code)
      }
      watchLock.unlock()
    }
  }

  // Middle click at a screen point (the game's "step here" command for the
  // active Pokémon). cliclick has no middle button, so this is the ONLY path.
  static func handleMiddleClick(_ json: [String: Any]) {
    guard let x = json["x"] as? Double ?? (json["x"] as? Int).map(Double.init),
      let y = json["y"] as? Double ?? (json["y"] as? Int).map(Double.init)
    else {
      emit(["ok": false, "error": "bad_middle_click_command"])
      return
    }

    if let app = json["app"] as? String {
      ensureFrontmost(app)
    }

    let point = CGPoint(x: x, y: y)

    guard
      let down = CGEvent(
        mouseEventSource: nil, mouseType: .otherMouseDown, mouseCursorPosition: point,
        mouseButton: .center),
      let up = CGEvent(
        mouseEventSource: nil, mouseType: .otherMouseUp, mouseCursorPosition: point,
        mouseButton: .center)
    else {
      emit(["ok": false, "error": "middle_click_event_failed"])
      return
    }

    down.post(tap: .cghidEventTap)
    usleep(12_000)
    up.post(tap: .cghidEventTap)
    emit(["ok": true])
  }

  static func handleKey(_ json: [String: Any]) {
    guard let action = json["action"] as? String,
      let code = json["code"] as? Int
    else {
      emit(["ok": false, "error": "bad_key_command"])
      return
    }

    if let app = json["app"] as? String {
      ensureFrontmost(app)
    }

    let key = CGKeyCode(code)

    switch action {
    case "down":
      post(key: key, down: true)
    case "up":
      post(key: key, down: false)
    case "press":
      post(key: key, down: true)
      usleep(12_000)
      post(key: key, down: false)
    default:
      emit(["ok": false, "error": "unknown_action:\(action)"])
      return
    }

    emit(["ok": true])
  }

  static func post(key: CGKeyCode, down: Bool) {
    guard let event = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: down) else {
      return
    }

    event.post(tap: .cghidEventTap)
  }

  // CGEvents posted to the HID tap land in the FRONTMOST app, exactly like
  // System Events keystrokes — so the same focus guard applies, at native
  // speed: frontmost check is ~µs and the activation only happens when the
  // user actually left the game (e.g. watching the panel in the browser).
  static func ensureFrontmost(_ appName: String) {
    let workspace = NSWorkspace.shared

    if workspace.frontmostApplication?.localizedName == appName {
      return
    }

    guard
      let app = workspace.runningApplications.first(where: { $0.localizedName == appName })
    else {
      return
    }

    app.activate(options: [])
    usleep(80_000)
  }

  static func emit(_ payload: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: payload),
      let line = String(data: data, encoding: .utf8)
    else {
      return
    }

    print(line)
    fflush(stdout)
  }
}
