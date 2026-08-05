// Dragging a combo step. The hook reports only WHERE the step was picked up
// and where it was dropped — the reordering itself is Pokex.Combos.Edit.move/3
// on the server, so the part that can be wrong is covered by tests.
//
// Listeners are delegated on the <ul>, because the panel re-renders ~10x/s and
// per-<li> listeners would be lost on every patch.
const ComboDrag = {
  mounted() {
    this.from = null

    this.el.addEventListener("dragstart", e => {
      const item = e.target.closest("[data-index]")
      if (!item) return
      this.from = Number(item.dataset.index)
      // Firefox only starts a drag when data is set
      e.dataTransfer.setData("text/plain", String(this.from))
      e.dataTransfer.effectAllowed = "move"
      item.classList.add("opacity-50")
    })

    // Without this, the browser refuses the drop
    this.el.addEventListener("dragover", e => {
      if (this.from !== null) e.preventDefault()
    })

    this.el.addEventListener("drop", e => {
      const item = e.target.closest("[data-index]")
      if (this.from === null || !item) return
      e.preventDefault()
      const to = Number(item.dataset.index)
      if (to !== this.from) this.pushEvent("move_combo_step", {from: this.from, to})
      this.from = null
    })

    this.el.addEventListener("dragend", () => {
      this.from = null
      this.el.querySelectorAll(".opacity-50").forEach(el => el.classList.remove("opacity-50"))
    })
  },
}

export default ComboDrag
