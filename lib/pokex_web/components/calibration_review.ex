defmodule PokexWeb.CalibrationReview do
  @moduledoc """
  "Áreas que o bot está usando" — the review panel, laid out around the one
  question it exists to answer.

  It used to be six coloured alert boxes stacked at the same weight (an
  explanation, a nudge pad, a form, the ruler, a legend, the photo), so colour
  was doing two jobs at once: naming an area AND signalling urgency. With
  everything shouting, nothing could — "18 números são de OUTRA tela" sat at
  exactly the same volume as a paragraph he had already read forty times
  (Lucas, 2026-08-10: "ta ruim de usar, confuso").

  The order here is the order of his questions:

  1. **is something wrong?** — one alert, the most severe, with its way out;
  2. **is it in the right place?** — the crops, at reading size, right away;
  3. **fix it** — the three tools, one open at a time, behind a row of buttons;
  4. **why / where** — explanation, legend and the full photo, folded away.

  Colour still names the area (the dot on each tool matches its overlay), but
  weight is reserved for urgency: tools sit on the neutral raised surface and
  only a real problem gets the warning tint.
  """
  use PokexWeb, :html

  alias Pokex.Calibration
  alias Pokex.Bots.Catcher.SpotScan
  alias PokexWeb.CalibrationOverlay

  @tools [
    {:skills, "barra de skills", "bg-secondary"},
    {:battle, "linha da batalha", "bg-error"},
    {:ruler, "régua da tela", "bg-pk-warn"}
  ]

  @doc "The tools row, as data — the dot colour is the area's colour on the photo."
  def tools, do: @tools

  attr :review, :map, required: true, doc: "the screenshot + its calibration"
  attr :tool, :atom, default: nil, doc: "which tool is open (nil = none)"
  attr :row_height, :integer, required: true
  attr :max_rows, :integer, required: true
  attr :battle_msg, :string, default: nil
  attr :scale_ratio, :any, default: nil
  attr :scale_proposals, :any, default: nil, doc: "nil = not measured yet"
  attr :scale_msg, :string, default: nil
  attr :adjust_target, :any, default: nil
  attr :adjust_step, :integer, default: 5
  attr :coord_probe, :any, default: nil

  def panel(assigns) do
    assigns = assign(assigns, :pending, pending(assigns.scale_proposals))

    ~H"""
    <div id="review-panel" class="space-y-3 rounded-2xl border border-pk-line bg-pk-surface p-4">
      <div class="flex items-center justify-between gap-2">
        <h2 class="text-pk-title font-bold">Áreas que o bot está usando</h2>
        <button
          class="rounded-lg border border-pk-line-strong px-2.5 py-1 text-pk-meta font-semibold text-pk-text-2 hover:border-pk-ok/60 hover:bg-pk-raised hover:text-white"
          phx-click="close_review"
        >
          Fechar
        </button>
      </div>

      <.numbers_alert pending={@pending} ratio={@scale_ratio} open?={@tool == :ruler} />

      <p :if={@scale_msg} id="screen-scale-msg" class="text-pk-body text-pk-ok">{@scale_msg}</p>

      <CalibrationOverlay.read_crops
        screen={@review}
        calib={@review.calib}
        adjustable?={true}
        adjust_target={@adjust_target}
        adjust_step={@adjust_step}
        coord_probe={@coord_probe}
      />

      <div class="space-y-2 border-t border-pk-line pt-3">
        <div class="flex flex-wrap items-center gap-2">
          <span class="text-pk-body text-pk-text-3">Ajustar:</span>
          <.tool_button
            :for={{key, label, dot} <- tools()}
            key={key}
            label={label}
            dot={dot}
            open?={@tool == key}
            badge={key == :ruler && @pending}
          />
        </div>

        <.skills_tool :if={@tool == :skills} calib={@review.calib} />
        <.battle_tool
          :if={@tool == :battle}
          row_height={@row_height}
          max_rows={@max_rows}
          battle_msg={@battle_msg}
        />
        <.ruler_tool :if={@tool == :ruler} proposals={@scale_proposals} pending={@pending} />
      </div>

      <div class="flex flex-wrap gap-x-4 gap-y-1 border-t border-pk-line pt-3 text-pk-body">
        <details id="review-how" class="min-w-0">
          <summary class="cursor-pointer text-pk-text-2 hover:text-pk-text">
            Como estas áreas são escolhidas
          </summary>
          <p class="mt-1.5 max-w-prose leading-relaxed text-pk-text-2">
            Duas são <b>automáticas</b>, tiradas do seu personagem: a caixa do <b>mini game</b>
            (3 tiles pra cada lado, de 3 acima a 7 abaixo dele) e a <b>busca de corpos</b>
            (raio em tiles, no ⚙️). Marcar a faixa do mini game à mão continua valendo mais —
            deixa a busca ainda mais barata e certeira.
          </p>
        </details>

        <details id="review-photo" class="min-w-0 flex-1">
          <summary class="cursor-pointer text-pk-text-2 hover:text-pk-text">
            A foto da tela inteira, com as marcações
          </summary>
          <div class="mt-2 space-y-2">
            <CalibrationOverlay.legend />
            <div class="relative overflow-hidden rounded-lg border border-pk-line">
              <img
                src={@review.src}
                class="w-full"
                alt="A tela do jogo com as áreas calibradas desenhadas por cima"
              />
              <CalibrationOverlay.overlays
                screen={@review}
                water_point={@review.calib.water_point}
                glow_region={@review.calib.glow_region}
                battle_region={@review.calib.battle_region}
                skill_bar_region={@review.calib.skill_bar_region}
                skill_bar_count={@review.calib.skill_bar_count || 0}
                neutral_point={@review.calib.neutral_point}
                player_point={Calibration.player_point(@review.calib)}
                pokemon_hp_region={@review.calib.pokemon_hp_region}
                pokemon_photo_point={@review.calib.pokemon_photo_point}
                mini_game_region={Calibration.mini_game_region(@review.calib)}
                minimap_region={Calibration.minimap_region(@review.calib)}
                minimap_coord_region={Calibration.minimap_coord_region(@review.calib)}
                minimap_player_point={Calibration.minimap_player_point(@review.calib)}
                scan_region={scan_region(@review.calib)}
                bands={Calibration.battle_row_bands(@review.calib, @row_height, @max_rows)}
              />
            </div>
          </div>
        </details>
      </div>
    </div>
    """
  end

  # THE alert, and the only one: a number in force that belongs to another
  # screen makes every reading wrong while the marks look perfect. It used to
  # take a click on "Conferir a régua da tela" to even learn this — the check
  # is pure arithmetic over the calibration, so now the panel simply knows.
  attr :pending, :integer, required: true
  attr :ratio, :any, required: true
  attr :open?, :boolean, required: true

  defp numbers_alert(%{pending: 0} = assigns), do: ~H""

  defp numbers_alert(assigns) do
    ~H"""
    <div
      id="numbers-alert"
      role="status"
      class="flex flex-wrap items-center gap-2 rounded-lg border border-pk-warn-line bg-pk-warn-dim px-3 py-2"
    >
      <.icon name="hero-exclamation-triangle" class="size-4 shrink-0 text-pk-warn" />
      <p class="flex-1 text-pk-body text-pk-text">
        <b class="text-pk-warn">{@pending} números são de outra tela</b>
        <span class="text-pk-text-2">— {origin(@ratio)}</span>
      </p>
      <button
        :if={not @open?}
        class="rounded-lg border border-pk-line-strong px-2.5 py-1 text-pk-meta font-semibold text-pk-text-2 hover:bg-pk-raised hover:text-white"
        phx-click="open_tool"
        phx-value-tool="ruler"
      >
        Ver a lista
      </button>
      <button
        id="apply-screen-scale"
        class="rounded-lg border border-pk-warn-line bg-pk-warn/15 px-2.5 py-1 text-pk-meta font-bold text-pk-warn hover:bg-pk-warn/25"
        phx-click="apply_screen_scale"
      >
        Corrigir os {@pending}
      </button>
    </div>
    """
  end

  defp origin(ratio) when is_number(ratio) do
    if Pokex.ScreenScale.matches_reference?(ratio),
      do: "esta é a tela em que eles foram medidos, então esses vieram de outra",
      else: "esta tela mede #{Float.round(ratio, 2)}× a de referência"
  end

  defp origin(_unmeasured), do: "medidos noutra tela"

  attr :key, :atom, required: true
  attr :label, :string, required: true
  attr :dot, :string, required: true
  attr :open?, :boolean, required: true
  attr :badge, :any, default: false

  defp tool_button(assigns) do
    ~H"""
    <button
      id={"tool-#{@key}"}
      phx-click="open_tool"
      phx-value-tool={@key}
      aria-expanded={to_string(@open?)}
      class={[
        "flex items-center gap-1.5 rounded-lg border px-2.5 py-1 text-pk-body transition",
        @open? && "border-pk-ok/60 bg-pk-raised font-semibold text-white",
        !@open? && "border-pk-line-strong text-pk-text-2 hover:bg-pk-raised hover:text-white"
      ]}
    >
      <span class={["size-2 shrink-0 rounded-full", @dot]} />
      {@label}
      <span
        :if={is_integer(@badge) and @badge > 0}
        class="pk-num rounded-full bg-pk-warn/20 px-1.5 text-pk-meta font-bold text-pk-warn"
      >
        {@badge}
      </span>
    </button>
    """
  end

  # The box is cut into numbered CELLS and cell i IS hotkey i. One cell off and
  # every cooldown read is the neighbour's — which silently shuts the "só pescar
  # quando dá pra matar" gate (#158).
  attr :calib, :map, required: true

  defp skills_tool(assigns) do
    ~H"""
    <div
      :if={@calib.skill_bar_region && @calib.skill_bar_count}
      id="skill-bar-nudge"
      class="flex flex-wrap items-center gap-2 rounded-lg border border-pk-line bg-pk-raised px-3 py-2 text-pk-body"
    >
      <span class="flex-1 text-pk-text-2">
        Os números <b class="text-pk-text">1…{@calib.skill_bar_count}</b>
        na barra têm que cair em cima das skills certas — é célula por célula que o bot lê o
        cooldown.
      </span>
      <button
        class="rounded-lg border border-pk-line-strong px-2.5 py-1 text-pk-meta font-semibold text-pk-text-2 hover:bg-pk-surface hover:text-white"
        phx-click="nudge_skill_bar"
        phx-value-cells="-1"
      >
        ◀ uma casa
      </button>
      <button
        class="rounded-lg border border-pk-line-strong px-2.5 py-1 text-pk-meta font-semibold text-pk-text-2 hover:bg-pk-surface hover:text-white"
        phx-click="nudge_skill_bar"
        phx-value-cells="1"
      >
        uma casa ▶
      </button>
    </div>
    """
  end

  # The red L bands are drawn from these two numbers, and they live next to the
  # bands on purpose: change one and the ladder moves while he watches.
  attr :row_height, :integer, required: true
  attr :max_rows, :integer, required: true
  attr :battle_msg, :string, default: nil

  defp battle_tool(assigns) do
    ~H"""
    <div
      id="battle-rows"
      class="flex flex-wrap items-center gap-2 rounded-lg border border-pk-line bg-pk-raised px-3 py-2 text-pk-body"
    >
      <form id="battle-rows-form" phx-change="save_battle_rows" class="flex items-center gap-1">
        <label for="battle-row-height" class="text-pk-text-2">linha de</label>
        <input
          id="battle-row-height"
          name="battle_row_height"
          type="number"
          aria-label="Altura de uma linha da lista de batalha, em pontos"
          min="8"
          max="200"
          value={@row_height}
          phx-debounce="400"
          class="pk-num w-16 rounded-md border border-pk-line-strong bg-pk-surface px-1.5 py-0.5 text-center text-pk-text"
        />
        <span class="text-pk-text-2">pt ·</span>
        <input
          id="battle-max-rows"
          name="battle_max_rows"
          type="number"
          aria-label="Quantas linhas da lista de batalha o bot olha"
          min="1"
          max="12"
          value={@max_rows}
          phx-debounce="400"
          class="pk-num w-14 rounded-md border border-pk-line-strong bg-pk-surface px-1.5 py-0.5 text-center text-pk-text"
        />
        <span class="text-pk-text-2">linhas</span>
      </form>
      <button
        class="rounded-lg border border-pk-line-strong px-2.5 py-1 text-pk-meta font-semibold text-pk-text-2 hover:bg-pk-surface hover:text-white"
        phx-click="measure_battle_rows"
      >
        Medir pelas barras de vida
      </button>
      <p :if={@battle_msg} id="battle-rows-msg" class="w-full text-pk-meta text-pk-text-3">
        {@battle_msg}
      </p>
    </div>
    """
  end

  # The numbers, not the boxes: a calibration can be perfect and the bot still
  # blind, because every threshold and every box SIZE was measured on one screen.
  attr :proposals, :any, required: true
  attr :pending, :integer, required: true

  defp ruler_tool(assigns) do
    ~H"""
    <div
      id="screen-scale"
      class="space-y-2 rounded-lg border border-pk-line bg-pk-raised px-3 py-2 text-pk-body"
    >
      <%!-- "nothing to adjust" and "never measured" are different answers, and
            saying the first when the second is true is how a broken ruler reads
            as a clean bill of health. --%>
      <p :if={@proposals == []} class="text-pk-text-2">
        Todo número em uso é o desta tela — não há o que ajustar.
      </p>
      <p :if={is_nil(@proposals)} class="text-pk-text-2">
        Ainda não deu pra medir — a régua é a barra de skills, e ela precisa estar calibrada.
      </p>

      <div :if={@pending > 0} class="max-h-56 overflow-y-auto rounded border border-pk-line">
        <table class="w-full text-left">
          <tbody>
            <tr :for={p <- @proposals} class="border-b border-pk-line last:border-0">
              <td class="px-2 py-1 font-mono text-pk-meta text-pk-text-2">{p.key}</td>
              <td class="pk-num px-2 py-1 text-right font-mono text-pk-meta text-pk-text-3">
                {p.from}
              </td>
              <td class="pk-num px-2 py-1 font-mono text-pk-meta font-bold text-pk-text">
                → {p.to}
              </td>
              <td class="px-2 py-1 text-pk-meta text-pk-text-3">
                {if p.family == :area, do: "área ×r²", else: "medida ×r"}
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </div>
    """
  end

  defp pending(proposals) when is_list(proposals), do: length(proposals)
  defp pending(_not_measured), do: 0

  defp scan_region(calib) do
    case SpotScan.region(calib) do
      {:ok, region} -> region
      _uncalibrated -> nil
    end
  end
end
