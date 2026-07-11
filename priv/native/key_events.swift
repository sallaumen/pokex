// Native key-event helper: posts CGEvents for hold/release/press with ~1-2ms
// latency, replacing the ~60-100ms per-event osascript spawn on the mini-game's
// hot path. Line-based JSON protocol over stdio, one response per command:
//
//   -> {"op":"ping"}
//   <- {"ok":true}
//   -> {"op":"key","action":"down"|"up"|"press","code":49,"app":"wine"}
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
    default:
      emit(["ok": false, "error": "unknown_op:\(op)"])
    }
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
