// If you want to use Phoenix channels, run `mix help phx.gen.channel`
// to get started and then uncomment the line below.
// import "./user_socket.js"

// You can include dependencies in two ways.
//
// The simplest option is to put them in assets/vendor and
// import them using relative paths:
//
//     import "../vendor/some-package.js"
//
// Alternatively, you can `npm install some-package --prefix assets` and import
// them using a path starting with the package name:
//
//     import "some-package"
//
// If you have dependencies that try to import CSS, esbuild will generate a separate `app.css` file.
// To load it, simply add a second `<link>` to your `root.html.heex` file.

// Include phoenix_html to handle method=PUT/DELETE in forms and buttons.
import "phoenix_html"
// Establish Phoenix Socket and LiveView configuration.
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import {hooks as colocatedHooks} from "phoenix-colocated/pokex"
import topbar from "../vendor/topbar"
import FishingLab from "./fishing_lab"

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")

const ImgClick = {
  mounted() {
    this.el.addEventListener("click", e => {
      const rect = this.el.getBoundingClientRect()
      this.pushEvent("img_click", {
        x: e.clientX - rect.left,
        y: e.clientY - rect.top,
        cw: rect.width,
        ch: rect.height,
        nw: this.el.naturalWidth,
        nh: this.el.naturalHeight,
      })
    })
  },
}

const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: {_csrf_token: csrfToken},
  hooks: {...colocatedHooks, ImgClick, FishingLab},
  dom: {
    // <details> open state lives only in the browser; without this, every LiveView
    // patch (e.g. each HP-monitor broadcast) re-renders the closed server HTML and
    // instantly collapses whatever the user just opened.
    onBeforeElUpdated(from, to) {
      if (from.tagName === "DETAILS" && from.hasAttribute("open")) {
        to.setAttribute("open", "")
      }
    },
  },
})

let miniGameAudioContext

// One enveloped burst of sequential notes. Muting lives on the SERVER (the
// panel simply stops pushing the event), so this always plays when called.
const playMiniGameChirp = (ctx, notes, at, {type, peak, noteLength, gap}) => {
  const gain = ctx.createGain()
  gain.connect(ctx.destination)
  gain.gain.setValueAtTime(0.0001, at)
  gain.gain.exponentialRampToValueAtTime(peak, at + 0.015)
  gain.gain.exponentialRampToValueAtTime(0.0001, at + (notes.length - 1) * gap + noteLength + 0.05)

  notes.forEach((frequency, index) => {
    const osc = ctx.createOscillator()
    osc.type = type
    osc.frequency.setValueAtTime(frequency, at + index * gap)
    osc.connect(gain)
    osc.start(at + index * gap)
    osc.stop(at + index * gap + noteLength)
  })
}

const playMiniGameTone = transition => {
  const AudioContext = window.AudioContext || window.webkitAudioContext
  if (!AudioContext) return

  miniGameAudioContext = miniGameAudioContext || new AudioContext()

  if (miniGameAudioContext.state === "suspended") {
    miniGameAudioContext.resume().catch(() => {})
  }

  const now = miniGameAudioContext.currentTime

  if (transition === "entered") {
    // ALARM: three loud rising square-wave bursts (~1.3s) — must yank
    // attention from another window, per Lucas (the old sine at 0.12 was
    // too quiet to notice).
    for (let burst = 0; burst < 3; burst++) {
      playMiniGameChirp(miniGameAudioContext, [880, 1244.5], now + burst * 0.42, {
        type: "square",
        peak: 0.4,
        noteLength: 0.16,
        gap: 0.14,
      })
    }
  } else {
    // calm: one soft descending pair — it ended, nothing to react to
    playMiniGameChirp(miniGameAudioContext, [784, 523.25], now, {
      type: "sine",
      peak: 0.07,
      noteLength: 0.24,
      gap: 0.18,
    })
  }
}

window.addEventListener("phx:mini-game-transition", event => {
  playMiniGameTone(event.detail?.transition)
})

// Show progress bar on live navigation and form submits
topbar.config({barColors: {0: "#29d"}, shadowColor: "rgba(0, 0, 0, .3)"})
window.addEventListener("phx:page-loading-start", _info => topbar.show(300))
window.addEventListener("phx:page-loading-stop", _info => topbar.hide())

// connect if there are any LiveViews on the page
liveSocket.connect()

// expose liveSocket on window for web console debug logs and latency simulation:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)  // enabled for duration of browser session
// >> liveSocket.disableLatencySim()
window.liveSocket = liveSocket

// The lines below enable quality of life phoenix_live_reload
// development features:
//
//     1. stream server logs to the browser console
//     2. click on elements to jump to their definitions in your code editor
//
if (process.env.NODE_ENV === "development") {
  window.addEventListener("phx:live_reload:attached", ({detail: reloader}) => {
    // Enable server log streaming to client.
    // Disable with reloader.disableServerLogs()
    reloader.enableServerLogs()

    // Open configured PLUG_EDITOR at file:line of the clicked element's HEEx component
    //
    //   * click with "c" key pressed to open at caller location
    //   * click with "d" key pressed to open at function component definition location
    let keyDown
    window.addEventListener("keydown", e => keyDown = e.key)
    window.addEventListener("keyup", _e => keyDown = null)
    window.addEventListener("click", e => {
      if(keyDown === "c"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtCaller(e.target)
      } else if(keyDown === "d"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtDef(e.target)
      }
    }, true)

    window.liveReloader = reloader
  })
}
