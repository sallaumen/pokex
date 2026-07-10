import {decide} from "./fishing_pilot"

const WIDTH = 420
const HEIGHT = 680
const TAU = Math.PI * 2

const TRACK = {
  x: 250,
  top: 76,
  bottom: 624,
  width: 16,
}

const FISH_X = 198
const FISH_HEIGHT = 42
const BAR_HEIGHT = 78

const FISH_COLORS = [
  {body: "#4f8a3e", fin: "#2f5f31", belly: "#6fb45d"},
  {body: "#ef5fa8", fin: "#b82e75", belly: "#ff91c4"},
  {body: "#2b8de3", fin: "#185a9d", belly: "#75baff"},
  {body: "#e23b35", fin: "#98211d", belly: "#ff776f"},
  {body: "#f4b63f", fin: "#b87d16", belly: "#ffe08a"},
]

const clamp = (value, min, max) => Math.min(max, Math.max(min, value))
const lerp = (a, b, t) => a + (b - a) * t
const rand = (min, max) => min + Math.random() * (max - min)

const roundedRect = (ctx, x, y, width, height, radius) => {
  const r = Math.min(radius, width / 2, height / 2)

  ctx.beginPath()
  ctx.moveTo(x + r, y)
  ctx.arcTo(x + width, y, x + width, y + height, r)
  ctx.arcTo(x + width, y + height, x, y + height, r)
  ctx.arcTo(x, y + height, x, y, r)
  ctx.arcTo(x, y, x + width, y, r)
  ctx.closePath()
}

const formatPercent = value => `${Math.round(value)}%`
const formatPx = value => `${Math.round(value)}px`

const FishingLab = {
  mounted() {
    this.canvas = this.el.querySelector("#fishing-game-canvas")
    this.ctx = this.canvas.getContext("2d", {willReadFrequently: true})
    this.backgroundCanvas = document.createElement("canvas")
    this.backgroundCanvas.width = WIDTH
    this.backgroundCanvas.height = HEIGHT
    this.backgroundCtx = this.backgroundCanvas.getContext("2d", {willReadFrequently: true})
    this.backgroundData = null

    this.config = {
      difficulty: 0.65,
      latencyMs: 110,
      deadbandPx: 13,
      minToggleMs: Number(this.el.dataset.minToggleMs || 50),
      useVision: true,
      visionFps: 7,
      lossPct: 0,
      pilot: "predictive",
    }

    this.running = true
    this.auto = true
    this.round = 1
    this.lastSampleAt = 0
    this.score = {wins: 0, losses: 0}
    this.pilotView = {targetY: null, ageMs: null}
    this.lastFrameAt = performance.now()
    this.lastUiAt = 0
    this.cleanup = []
    this.loop = this.loop.bind(this)

    this.bindControls()
    this.drawBackground()
    this.resetRound(true)
    this.frameId = requestAnimationFrame(this.loop)
  },

  destroyed() {
    cancelAnimationFrame(this.frameId)
    this.cleanup.forEach(cleanup => cleanup())
  },

  bindControls() {
    const listen = (node, event, handler, options) => {
      node.addEventListener(event, handler, options)
      this.cleanup.push(() => node.removeEventListener(event, handler, options))
    }

    listen(this.canvas, "pointerdown", () => this.canvas.focus())

    listen(window, "keydown", event => {
      if (event.code !== "Space" || this.auto || this.editableTarget(event.target)) return
      event.preventDefault()
      this.setPressing(true, performance.now())
    })

    listen(window, "keyup", event => {
      if (event.code !== "Space" || this.auto || this.editableTarget(event.target)) return
      event.preventDefault()
      this.setPressing(false, performance.now())
    })

    this.el.querySelectorAll("[data-lab-action]").forEach(node => {
      const event = node.type === "checkbox" ? "change" : "click"
      listen(node, event, () => this.handleAction(node.dataset.labAction, node))
    })

    this.el.querySelectorAll("[data-lab-range]").forEach(node => {
      listen(node, "input", () => this.handleRange(node))
    })

    this.el.querySelectorAll("[data-lab-pilot]").forEach(node => {
      listen(node, "click", () => this.setPilot(node.dataset.labPilot))
    })
  },

  editableTarget(target) {
    return ["INPUT", "TEXTAREA", "SELECT", "BUTTON"].includes(target?.tagName)
  },

  handleAction(action, node) {
    const now = performance.now()

    switch (action) {
      case "toggle-running":
        this.running = !this.running
        this.lastFrameAt = now
        if (!this.running) this.forcePressing(false, now)
        this.setMessage(this.running ? "Rodada retomada." : "Rodada pausada.")
        break
      case "reset":
        this.resetScore()
        this.round = 1
        this.resetRound(true)
        break
      case "toggle-auto":
        this.auto = !this.auto
        this.ai.queue = []
        this.ai.history = []
        this.pilotView = {targetY: null, ageMs: null}
        this.forcePressing(false, now)
        this.setMessage(
          this.auto
            ? "Piloto automatico ligado. Ele usa a leitura atrasada do detector."
            : "Modo manual ligado. Clique no canvas e segure Space para subir."
        )
        break
      case "new-fish":
        this.pickFishColor()
        this.setMessage("Cor do peixe trocada; o detector continua usando diferenca de fundo.")
        break
      case "toggle-vision":
        this.config.useVision = node.checked
        this.ai.queue = []
        this.ai.history = []
        this.resetScore()
        this.setMessage(
          this.config.useVision
            ? "Deteccao por pixels ligada."
            : "Visao desligada: o piloto usa a posicao real do simulador."
        )
        break
      default:
        break
    }
  },

  handleRange(node) {
    const value = Number(node.value)

    switch (node.dataset.labRange) {
      case "difficulty":
        this.config.difficulty = value / 100
        this.setOutput("difficulty", `${value}%`)
        break
      case "latency":
        this.config.latencyMs = value
        this.setOutput("latency", `${value}ms`)
        break
      case "deadband":
        this.config.deadbandPx = value
        this.setOutput("deadband", `${value}px`)
        break
      case "vision-fps":
        this.config.visionFps = value
        this.setOutput("vision-fps", `${value} fps · ~${Math.round(1000 / value)}ms`)
        break
      case "loss":
        this.config.lossPct = value
        this.setOutput("loss", `${value}%`)
        break
      default:
        break
    }

    this.resetScore()
  },

  setPilot(pilot) {
    if (this.config.pilot === pilot) return

    this.config.pilot = pilot
    this.ai.queue = []
    this.ai.history = []
    this.pilotView = {targetY: null, ageMs: null}
    this.resetScore()

    this.el.querySelectorAll("[data-lab-pilot]").forEach(node => {
      node.classList.toggle("btn-active", node.dataset.labPilot === pilot)
    })

    this.setMessage(
      pilot === "predictive"
        ? "Piloto preditivo: extrapola a posicao do peixe entre leituras."
        : "Piloto reativo: age sobre a ultima leitura crua."
    )
  },

  resetScore() {
    this.score = {wins: 0, losses: 0}
  },

  resetRound(resetStats) {
    const now = performance.now()
    this.running = true
    this.roundResetAt = null

    this.fish = {
      y: rand(TRACK.top + 90, TRACK.bottom - 90),
      vy: 0,
      phaseA: rand(0, TAU),
      phaseB: rand(0, TAU),
      impulse: 0,
      nextImpulseAt: now + rand(500, 1300),
      color: this.fish?.color || FISH_COLORS[0],
    }

    if (!this.fish.color || resetStats) this.pickFishColor()

    this.bar = {
      y: (TRACK.top + TRACK.bottom) / 2,
      vy: 0,
      pressing: false,
      lastToggleAt: now,
    }

    this.ai = {
      queue: [],
      history: [],
    }

    this.lastSampleAt = 0
    this.pilotView = {targetY: null, ageMs: null}

    this.vision = {
      y: this.fish.y,
      confidence: 1,
      fps: 0,
      lastAt: now,
    }

    this.progress = 0
    this.elapsed = 0
    this.metrics = {
      overlap: 0,
      averageError: 0,
      actionTimes: [],
    }

    this.setMessage("Rodada local pronta. O piloto esta limitado a trocas de input de 50ms ou mais.")
  },

  pickFishColor() {
    const current = this.fish?.color
    let next = FISH_COLORS[Math.floor(Math.random() * FISH_COLORS.length)]

    if (current && FISH_COLORS.length > 1) {
      while (next === current) next = FISH_COLORS[Math.floor(Math.random() * FISH_COLORS.length)]
    }

    if (this.fish) this.fish.color = next
  },

  loop(now) {
    const dt = clamp((now - this.lastFrameAt) / 1000, 0, 0.04)
    this.lastFrameAt = now

    if (this.roundResetAt && now >= this.roundResetAt) {
      this.round += 1
      this.resetRound(false)
    }

    if (this.running) {
      this.updateAi(now)
      this.updateFish(dt, now)
      this.updateBar(dt)
      this.updateProgress(dt, now)
    }

    this.draw()
    this.sampleObservation(now)
    this.updateUi(now)
    this.frameId = requestAnimationFrame(this.loop)
  },

  updateFish(dt, now) {
    const difficulty = this.config.difficulty
    const center = (TRACK.top + TRACK.bottom) / 2
    const amplitude = 128 + difficulty * 42

    if (now >= this.fish.nextImpulseAt) {
      this.fish.impulse = rand(-95, 95) * difficulty
      this.fish.nextImpulseAt = now + rand(520, 1550 - difficulty * 420)
    }

    this.fish.phaseA += dt * (1.35 + difficulty * 1.3)
    this.fish.phaseB += dt * (0.55 + difficulty * 0.95)

    const wave =
      Math.sin(this.fish.phaseA) * amplitude +
      Math.sin(this.fish.phaseB + 1.8) * amplitude * 0.32 +
      Math.sin(this.fish.phaseA * 0.37 + 0.9) * amplitude * 0.18

    const target = clamp(
      center + wave + this.fish.impulse,
      TRACK.top + FISH_HEIGHT / 2,
      TRACK.bottom - FISH_HEIGHT / 2
    )

    this.fish.vy += (target - this.fish.y) * (7.5 + difficulty * 6.5) * dt
    this.fish.vy += rand(-1, 1) * 58 * difficulty * dt
    this.fish.vy *= Math.pow(0.08, dt)
    this.fish.vy = clamp(this.fish.vy, -520, 520)
    this.fish.y += this.fish.vy * dt

    if (this.fish.y < TRACK.top + FISH_HEIGHT / 2) {
      this.fish.y = TRACK.top + FISH_HEIGHT / 2
      this.fish.vy = Math.abs(this.fish.vy) * 0.35
    } else if (this.fish.y > TRACK.bottom - FISH_HEIGHT / 2) {
      this.fish.y = TRACK.bottom - FISH_HEIGHT / 2
      this.fish.vy = -Math.abs(this.fish.vy) * 0.35
    }
  },

  updateBar(dt) {
    const top = TRACK.top + BAR_HEIGHT / 2
    const bottom = TRACK.bottom - BAR_HEIGHT / 2
    const thrust = 1690
    const gravity = 1470

    this.bar.vy += (this.bar.pressing ? -thrust : gravity) * dt
    this.bar.vy *= Math.pow(0.16, dt)
    this.bar.vy = clamp(this.bar.vy, -650, 650)
    this.bar.y += this.bar.vy * dt

    if (this.bar.y < top) {
      this.bar.y = top
      this.bar.vy = Math.max(0, this.bar.vy) * 0.35
    } else if (this.bar.y > bottom) {
      this.bar.y = bottom
      this.bar.vy = Math.min(0, this.bar.vy) * 0.35
    }
  },

  updateProgress(dt, now) {
    const overlap = this.overlapRatio()
    const error = Math.abs(this.bar.y - this.fish.y)

    this.metrics.overlap = lerp(this.metrics.overlap, overlap, 0.08)
    this.metrics.averageError = lerp(this.metrics.averageError, error, 0.05)

    if (overlap > 0.34) {
      this.progress += dt * (14 + overlap * 24)
    } else {
      this.progress -= dt * (7 + (0.34 - overlap) * 18)
    }

    this.elapsed += dt
    this.progress = clamp(this.progress, -30, 100)

    if (!this.roundResetAt && (this.progress >= 100 || this.progress <= -30 || this.elapsed > 45)) {
      const won = this.progress >= 100
      if (won) this.score.wins += 1
      else this.score.losses += 1
      this.running = false
      this.forcePressing(false, now)
      this.roundResetAt = now + 950
      this.setMessage(won ? "Captura simulada concluida." : "Rodada perdida; reiniciando.")
    }

  },

  updateAi(now) {
    if (!this.auto) return

    while (this.ai.queue.length > 0 && this.ai.queue[0].readyAt <= now) {
      const observation = this.ai.queue.shift()
      this.ai.history.push({y: observation.y, at: observation.at})
      if (this.ai.history.length > 4) this.ai.history.splice(0, this.ai.history.length - 4)
    }

    const result = decide(
      {
        pilot: this.config.pilot,
        deadbandPx: this.config.deadbandPx,
        trackTop: TRACK.top,
        trackBottom: TRACK.bottom,
      },
      this.ai.history,
      {y: this.bar.y, vy: this.bar.vy, pressing: this.bar.pressing},
      now
    )

    this.pilotView = {targetY: result.targetY, ageMs: result.ageMs}
    this.setPressing(result.desired, now)
  },

  setPressing(pressing, now) {
    if (this.bar.pressing === pressing) return
    if (now - this.bar.lastToggleAt < this.config.minToggleMs) return

    this.bar.pressing = pressing
    this.bar.lastToggleAt = now
    this.metrics.actionTimes.push(now)
  },

  forcePressing(pressing, now) {
    if (this.bar.pressing !== pressing) this.metrics.actionTimes.push(now)
    this.bar.pressing = pressing
    this.bar.lastToggleAt = now
  },

  overlapRatio() {
    const fishTop = this.fish.y - FISH_HEIGHT / 2
    const fishBottom = this.fish.y + FISH_HEIGHT / 2
    const barTop = this.bar.y - BAR_HEIGHT / 2
    const barBottom = this.bar.y + BAR_HEIGHT / 2
    const overlap = Math.max(0, Math.min(fishBottom, barBottom) - Math.max(fishTop, barTop))

    return clamp(overlap / FISH_HEIGHT, 0, 1)
  },

  sampleObservation(now) {
    if (now - this.lastSampleAt < 1000 / this.config.visionFps) return
    this.lastSampleAt = now

    const observation = this.config.useVision
      ? this.detectFish(now)
      : {y: this.fish.y, confidence: 1, fps: this.nextFps(now)}

    // Simulated failed read: the sampling tick still happened (no early retry),
    // but nothing downstream sees it — no marker update, no queue push.
    if (Math.random() * 100 < this.config.lossPct) return

    this.vision = {
      y: observation.y,
      confidence: observation.confidence,
      fps: observation.fps,
      lastAt: now,
    }

    if (observation.y == null) return

    const jitter = rand(-18, 26)
    this.ai.queue.push({
      y: observation.y,
      at: now,
      readyAt: now + this.config.latencyMs + jitter,
    })

    if (this.ai.queue.length > 8) this.ai.queue.splice(0, this.ai.queue.length - 8)
  },

  nextFps(now) {
    const delta = Math.max(1, now - (this.vision?.lastAt || now - 16))
    return lerp(this.vision?.fps || 0, 1000 / delta, 0.08)
  },

  detectFish(now) {
    const frame = this.ctx.getImageData(0, 0, WIDTH, HEIGHT)
    const pixels = frame.data
    const background = this.backgroundData
    let count = 0
    let sumY = 0
    let sumX = 0

    for (let y = TRACK.top - 28; y <= TRACK.bottom + 28; y += 2) {
      for (let x = FISH_X - 58; x <= FISH_X + 38; x += 2) {
        const index = (y * WIDTH + x) * 4
        const diff =
          Math.abs(pixels[index] - background[index]) +
          Math.abs(pixels[index + 1] - background[index + 1]) +
          Math.abs(pixels[index + 2] - background[index + 2])

        if (diff > 64) {
          count += 1
          sumY += y
          sumX += x
        }
      }
    }

    const fps = this.nextFps(now)

    if (count < 18) {
      return {y: null, x: null, confidence: 0, fps}
    }

    return {
      y: sumY / count,
      x: sumX / count,
      confidence: clamp((count - 18) / 95, 0, 1),
      fps,
    }
  },

  drawBackground() {
    const ctx = this.backgroundCtx
    const gradient = ctx.createLinearGradient(0, 0, 0, HEIGHT)
    gradient.addColorStop(0, "#b99567")
    gradient.addColorStop(0.18, "#d0ad78")
    gradient.addColorStop(0.19, "#b8b8a6")
    gradient.addColorStop(0.27, "#8d715c")
    gradient.addColorStop(1, "#6f5f52")
    ctx.fillStyle = gradient
    ctx.fillRect(0, 0, WIDTH, HEIGHT)

    ctx.save()
    ctx.globalAlpha = 0.22
    ctx.strokeStyle = "#f5cf91"
    ctx.lineWidth = 2
    for (let x = -HEIGHT; x < WIDTH; x += 34) {
      ctx.beginPath()
      ctx.moveTo(x, 0)
      ctx.lineTo(x + HEIGHT, HEIGHT)
      ctx.stroke()
    }
    ctx.restore()

    ctx.fillStyle = "#d9d8c8"
    for (let x = 0; x < WIDTH; x += 24) {
      ctx.fillRect(x, 132, 22, 22)
    }

    ctx.save()
    ctx.globalAlpha = 0.24
    ctx.strokeStyle = "#3b302a"
    ctx.lineWidth = 2
    for (let y = 174; y < HEIGHT; y += 54) {
      ctx.beginPath()
      ctx.moveTo(0, y)
      ctx.lineTo(WIDTH, y + 18)
      ctx.stroke()
    }

    for (let x = 26; x < WIDTH; x += 72) {
      ctx.beginPath()
      ctx.moveTo(x, 166)
      ctx.lineTo(x - 38, HEIGHT)
      ctx.stroke()
    }
    ctx.restore()

    ctx.save()
    ctx.shadowColor = "rgba(0, 0, 0, 0.36)"
    ctx.shadowBlur = 8
    ctx.shadowOffsetY = 2
    roundedRect(ctx, TRACK.x - TRACK.width / 2, TRACK.top, TRACK.width, TRACK.bottom - TRACK.top, 8)
    ctx.fillStyle = "#202233"
    ctx.fill()
    ctx.restore()

    roundedRect(ctx, TRACK.x - 3, TRACK.top + 8, 6, TRACK.bottom - TRACK.top - 16, 4)
    ctx.fillStyle = "#3f4360"
    ctx.fill()

    this.backgroundData = ctx.getImageData(0, 0, WIDTH, HEIGHT).data
  },

  draw() {
    const ctx = this.ctx
    ctx.drawImage(this.backgroundCanvas, 0, 0)
    this.drawFish(ctx)
    this.drawBar(ctx)
    this.drawVisionMarker(ctx)
    this.drawPilotMarker(ctx)
    this.drawHud(ctx)
  },

  drawFish(ctx) {
    const color = this.fish.color
    const tilt = clamp(this.fish.vy / 850, -0.38, 0.38)

    ctx.save()
    ctx.translate(FISH_X, this.fish.y)
    ctx.rotate(tilt)
    ctx.shadowColor = "rgba(0, 0, 0, 0.38)"
    ctx.shadowBlur = 6
    ctx.shadowOffsetY = 2

    ctx.fillStyle = color.fin
    ctx.beginPath()
    ctx.moveTo(-32, 0)
    ctx.lineTo(-55, -18)
    ctx.lineTo(-50, 0)
    ctx.lineTo(-55, 18)
    ctx.closePath()
    ctx.fill()

    ctx.fillStyle = color.body
    ctx.strokeStyle = "#172315"
    ctx.lineWidth = 4
    ctx.beginPath()
    ctx.ellipse(-4, 0, 35, 20, 0, 0, TAU)
    ctx.fill()
    ctx.stroke()

    ctx.fillStyle = color.belly
    ctx.beginPath()
    ctx.ellipse(3, 8, 20, 7, -0.1, 0, TAU)
    ctx.fill()

    ctx.fillStyle = "#172315"
    ctx.beginPath()
    ctx.arc(23, -4, 3.4, 0, TAU)
    ctx.fill()

    ctx.strokeStyle = color.fin
    ctx.lineWidth = 5
    ctx.beginPath()
    ctx.moveTo(-4, -18)
    ctx.quadraticCurveTo(4, -31, 16, -18)
    ctx.stroke()

    ctx.restore()
  },

  drawBar(ctx) {
    const barTop = this.bar.y - BAR_HEIGHT / 2
    const x = TRACK.x - 9

    ctx.save()
    ctx.shadowColor = "rgba(56, 189, 248, 0.45)"
    ctx.shadowBlur = this.bar.pressing ? 18 : 8
    roundedRect(ctx, x, barTop, 18, BAR_HEIGHT, 9)
    ctx.fillStyle = this.bar.pressing ? "#38bdf8" : "#0ea5e9"
    ctx.fill()
    ctx.restore()

    roundedRect(ctx, x + 4, barTop + 7, 10, BAR_HEIGHT - 14, 6)
    ctx.fillStyle = "rgba(255, 255, 255, 0.36)"
    ctx.fill()
  },

  drawVisionMarker(ctx) {
    if (!this.config.useVision || this.vision?.y == null) return

    ctx.save()
    ctx.globalAlpha = clamp(this.vision.confidence, 0.25, 1)
    ctx.strokeStyle = "#f8fafc"
    ctx.lineWidth = 2
    ctx.setLineDash([5, 5])
    ctx.beginPath()
    ctx.moveTo(FISH_X - 68, this.vision.y)
    ctx.lineTo(TRACK.x + 34, this.vision.y)
    ctx.stroke()
    ctx.restore()
  },

  drawPilotMarker(ctx) {
    if (!this.auto || this.pilotView?.targetY == null) return

    ctx.save()
    ctx.strokeStyle = "#facc15"
    ctx.lineWidth = 2
    ctx.setLineDash([8, 4])
    ctx.beginPath()
    ctx.moveTo(FISH_X - 68, this.pilotView.targetY)
    ctx.lineTo(TRACK.x + 34, this.pilotView.targetY)
    ctx.stroke()
    ctx.restore()
  },

  drawHud(ctx) {
    ctx.save()
    ctx.font = "700 24px ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, sans-serif"
    ctx.textAlign = "left"
    ctx.lineWidth = 5
    ctx.strokeStyle = "rgba(0, 0, 0, 0.72)"
    ctx.fillStyle = "#ffffff"
    const label = formatPercent(this.progress)
    ctx.strokeText(label, TRACK.x + 18, this.fish.y + 8)
    ctx.fillText(label, TRACK.x + 18, this.fish.y + 8)

    if (!this.running) {
      ctx.fillStyle = "rgba(15, 23, 42, 0.58)"
      ctx.fillRect(0, 0, WIDTH, HEIGHT)
      ctx.fillStyle = "#ffffff"
      ctx.textAlign = "center"
      ctx.font = "700 28px ui-sans-serif, system-ui"
      ctx.fillText(this.roundResetAt ? "Nova rodada..." : "Pausado", WIDTH / 2, HEIGHT / 2)
    }

    ctx.restore()
  },

  updateUi(now) {
    if (now - this.lastUiAt < 80) return
    this.lastUiAt = now

    const cutoff = now - 60_000
    this.metrics.actionTimes = this.metrics.actionTimes.filter(at => at >= cutoff)

    this.setStat("progress", formatPercent(this.progress))
    this.setStat("overlap", formatPercent(this.metrics.overlap * 100))
    this.setStat("vision-fps", Math.round(this.vision.fps || 0))
    this.setStat("actions", this.metrics.actionTimes.length)
    this.setStat("confidence", formatPercent((this.vision.confidence || 0) * 100))
    this.setStat("error", formatPx(this.metrics.averageError))
    this.setStat("round", this.round)
    this.setStat("score", `${this.score.wins}V · ${this.score.losses}D`)
    this.setStat("reading-age", this.readingAgeLabel(now))

    const press = this.el.querySelector('[data-stat="press-state"]')
    if (press) {
      press.textContent = this.bar.pressing ? "segurando" : "solto"
      press.className = this.bar.pressing ? "badge badge-info" : "badge badge-ghost"
    }

    this.setLabel("running", this.running ? "Pausar" : "Retomar")
    this.setLabel("auto", this.auto ? "Auto ligado" : "Manual")
  },

  readingAgeLabel(now) {
    const newest = this.ai.history[this.ai.history.length - 1]
    if (!newest) return "—"
    return `${Math.round(now - newest.at)}ms`
  },

  setStat(name, value) {
    const node = this.el.querySelector(`[data-stat="${name}"]`)
    if (node) node.textContent = value
  },

  setOutput(name, value) {
    const node = this.el.querySelector(`[data-output="${name}"]`)
    if (node) node.textContent = value
  },

  setLabel(name, value) {
    const node = this.el.querySelector(`[data-label="${name}"]`)
    if (node) node.textContent = value
  },

  setMessage(message) {
    const node = this.el.querySelector('[data-stat="message"]')
    if (node) node.textContent = message
  },
}

export default FishingLab
