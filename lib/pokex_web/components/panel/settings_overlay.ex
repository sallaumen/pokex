defmodule PokexWeb.Panel.SettingsOverlay do
  @moduledoc """
  The settings panel that opens ON TOP of the dashboard (`/config`).

  The dashboard had become two things stacked (2026-07-30): what Lucas
  watches with the bot running and what he tunes once and forgets. The split
  is by TIME OF USE, not by theme — what changes per session (fishing on,
  capture off) stayed on the dashboard's quick strip; every NUMBER, KEY and
  THRESHOLD lives here.

  A true overlay, not a page: same LiveView, dashboard still mounted behind
  it with the pills moving while he configures. The dedicated route is what
  gives URL, F5 and back — an assign-only modal would give none of the three.

  The events are the SAME as before (function component: clicks bubble up to
  the panel LiveView), so no behavior moved along with the controls.
  """
  use PokexWeb, :html

  attr :rescue_cfg, :map, required: true, doc: "pct, cooldown_s, mode, combo, enabled"
  attr :potion_cfg, :map, required: true, doc: "pct, cooldown_s, enabled"

  attr :fishing_cfg, :map,
    required: true,
    doc: "require_cooldowns, require_pokemon_hp, hook_skills, hp_pct"

  attr :escape_cfg, :map, required: true, doc: "direction, steps, walk_wait_ms"
  attr :support_waits_capture, :boolean, required: true
  attr :reposition_enabled, :boolean, required: true
  attr :player_mode, :string, required: true

  attr :settings_owner, :string,
    default: nil,
    doc: "display name of the character owning the per-character keys; nil = editing the base"

  attr :mode_overrides, :list, required: true
  attr :combos, :list, required: true

  attr :capture_cfg, :map,
    required: true,
    doc: "match_pct, ball_key, ball_needs_click, max_balls, radius_tiles, dry_balls_alarm"

  attr :sweep_cfg, :map, required: true, doc: "enabled, interval_s, radius_tiles, side, msg"

  attr :stock_cfg, :map, required: true, doc: "f1, f2, e, s_q"

  slot :inner_block,
    doc: "the remaining sections (combos, presets, session, advanced) — from the panel's assigns"

  def settings_overlay(assigns) do
    ~H"""
    <div
      id="settings-overlay"
      class="fixed inset-0 z-50 flex justify-end"
      role="dialog"
      aria-modal="true"
      aria-label="Configurações"
    >
      <%!-- The backdrop dims the dashboard without hiding it: it stays live
            behind, and clicking outside is the fastest way out. --%>
      <.link patch={~p"/"} class="absolute inset-0 bg-black/60" aria-label="Fechar configurações">
        <span class="sr-only">Fechar configurações</span>
      </.link>

      <div class="relative flex h-full w-full max-w-xl flex-col border-l border-pk-line bg-pk-bg shadow-2xl">
        <header class="flex h-12 shrink-0 items-center justify-between border-b border-pk-line px-4">
          <h1 class="flex items-center gap-2 text-pk-title font-semibold text-pk-text">
            <.icon name="hero-cog-6-tooth" class="size-4" /> Configurações
          </h1>
          <.link
            id="close-settings"
            patch={~p"/"}
            class="flex size-8 items-center justify-center rounded-lg border border-pk-line-strong text-pk-text-2 transition hover:text-white"
            aria-label="Fechar configurações"
          >
            <.icon name="hero-x-mark" class="size-4" />
          </.link>
        </header>

        <div class="min-h-0 flex-1 space-y-3 overflow-y-auto p-4">
          <p class="text-pk-body leading-tight text-pk-text-2">
            Aqui moram os ajustes que você faz uma vez. O que muda por sessão
            (pesca, luta, captura, loot, revive, poção) ficou na faixa do dashboard.
          </p>

          <%!-- Without this, "mudei aqui e o outro personagem mudou junto?" can
                only be answered by testing. Some keys follow the active
                character now, and most do not — say which is which BEFORE he
                changes anything. --%>
          <section
            id="settings-owner"
            class="flex items-start gap-2 rounded-lg border border-pk-line bg-pk-sunken px-3 py-2.5"
          >
            <.icon name="hero-user-circle" class="mt-0.5 size-4 shrink-0 text-pk-text-3" />
            <p class="text-pk-body leading-tight text-pk-text-2">
              <%= if @settings_owner do %>
                Skills e gates da pesca (marcados <span class="font-mono text-pk-ok">•</span>
                ) são de <strong class="text-pk-ok">{@settings_owner}</strong>
                — os outros personagens têm os deles. O resto desta tela é da máquina e vale pra todos.
              <% else %>
                Sem personagem selecionado: você está editando a
                <strong class="text-pk-text">configuração base</strong>
                — a que todo personagem novo herda e que os outros seguem no que nunca mexeram.
              <% end %>
            </p>
          </section>

          <section class="overflow-hidden rounded-lg border border-pk-line bg-pk-sunken">
            <.group_header
              label="Proteção do Pokémon"
              accent="bg-[#c9772f]"
              note="valem nos dois modos — e continuam valendo com o bot parado, você jogando na mão"
            />

            <div class="space-y-1.5 border-b border-pk-line px-3 py-2.5 font-mono text-pk-meta text-pk-text-3">
              <%!-- The switch belongs BESIDE its own number. Both live in the
                    dashboard's quick strip too, but reading "revive < 65%" in
                    here with no on/off beside it reads as "não dá mais pra
                    desligar" (Lucas, 2026-08-06) — and a revive he cannot stop
                    is a revive looping on a Pokémon that will not come back. --%>
              <form id="rescue-cfg-form" phx-change="save_rescue_cfg" class="flex items-center gap-1">
                <input
                  id="rescue-enabled-toggle"
                  type="checkbox"
                  class="toggle toggle-success toggle-xs shrink-0"
                  checked={@rescue_cfg.enabled}
                  phx-click="toggle_rescue"
                  aria-label="Ligar ou desligar o revive automático"
                />
                <label for="rescue-pct">revive &lt;</label>
                <input
                  id="rescue-pct"
                  name="rescue_pct"
                  type="number"
                  aria-label="Vida mínima para revive, em por cento"
                  min="1"
                  max="90"
                  value={@rescue_cfg.pct}
                  phx-debounce="500"
                  class="h-6 w-12 rounded border border-pk-line-strong bg-pk-bg px-1 text-center font-mono text-pk-meta text-pk-text focus:border-pk-ok focus:outline-none"
                />
                <span>% · a cada</span>
                <input
                  id="rescue-cooldown"
                  name="rescue_cooldown_s"
                  type="number"
                  aria-label="Intervalo mínimo entre revives, em segundos"
                  min="2"
                  max="600"
                  value={@rescue_cfg.cooldown_s}
                  phx-debounce="500"
                  class="h-6 w-12 rounded border border-pk-line-strong bg-pk-bg px-1 text-center font-mono text-pk-meta text-pk-text focus:border-pk-ok focus:outline-none"
                />
                <span>s</span>
              </form>

              <form
                id="rescue-combo-form"
                phx-change="save_rescue_combo_cfg"
                class="flex items-center gap-1"
              >
                <label for="rescue-mode">revive</label>
                <select
                  id="rescue-mode"
                  name="rescue_mode"
                  aria-label="Modo do auto-revive"
                  class="h-6 rounded border border-pk-line-strong bg-pk-bg px-1 font-mono text-pk-meta text-pk-text focus:border-pk-ok focus:outline-none"
                >
                  <option value="direct" selected={@rescue_cfg.mode == "direct"}>direto</option>
                  <option value="combo" selected={@rescue_cfg.mode == "combo"}>com combo</option>
                </select>
                <select
                  :if={@rescue_cfg.mode == "combo"}
                  id="rescue-combo"
                  name="rescue_combo"
                  aria-label="Combo de stun do resgate"
                  class="h-6 rounded border border-pk-line-strong bg-pk-bg px-1 font-mono text-pk-meta text-pk-text focus:border-pk-ok focus:outline-none"
                >
                  <option value="" selected={@rescue_cfg.combo == ""}>escolha o combo…</option>
                  <option
                    :for={combo <- @combos}
                    value={combo.name}
                    selected={@rescue_cfg.combo == combo.name}
                    disabled={not Pokex.Combos.rescue_eligible?(combo)}
                  >
                    {combo.name}{if not Pokex.Combos.rescue_eligible?(combo),
                      do: " (tem troca de time)"}
                  </option>
                </select>
              </form>

              <div
                :if={
                  @rescue_cfg.mode == "combo" and not rescue_combo_ready?(@combos, @rescue_cfg.combo)
                }
                data-testid="rescue-combo-missing"
                class="space-y-1 rounded border border-pk-warn-line bg-pk-warn-dim px-2 py-1.5 text-pk-warn"
              >
                <p>⚠️ modo com combo, mas nenhum combo válido escolhido — o revive vai direto.</p>
                <button
                  id="create-rescue-combo"
                  type="button"
                  phx-click="create_rescue_combo"
                  class="btn h-7 w-full border border-pk-ok-line bg-transparent text-pk-meta font-semibold text-pk-ok hover:bg-pk-ok-dim"
                >
                  criar o combo "resgate" (skill 1 → 2) e usar
                </button>
              </div>
              <p
                :if={@rescue_cfg.mode == "combo" and rescue_combo_preview(@combos, @rescue_cfg.combo)}
                data-testid="rescue-combo-preview"
                class="text-pk-text-3"
              >
                {rescue_combo_preview(@combos, @rescue_cfg.combo)}
              </p>
              <p
                :if={
                  @rescue_cfg.mode == "combo" and
                    rescue_combo_conflicts(@combos, @rescue_cfg.combo) != []
                }
                data-testid="rescue-combo-conflict"
                class="rounded border border-pk-warn-line bg-pk-warn-dim px-2 py-1 text-pk-warn"
              >
                ⚠️ {Enum.join(rescue_combo_conflicts(@combos, @rescue_cfg.combo), ", ")} também na
                rotação do combate — pode estar em cooldown na hora do resgate. Reserve tirando
                de "skills" em Avançado.
              </p>
            </div>

            <form
              id="potion-cfg-form"
              phx-change="save_potion_cfg"
              class="flex items-center gap-1 border-b border-pk-line px-3 py-2.5 font-mono text-pk-meta text-pk-text-3"
            >
              <input
                id="potion-enabled-toggle"
                type="checkbox"
                class="toggle toggle-success toggle-xs shrink-0"
                checked={@potion_cfg.enabled}
                phx-click="toggle_potion"
                aria-label="Ligar ou desligar a poção automática"
              />
              <label for="potion-pct">poção &lt;</label>
              <input
                id="potion-pct"
                name="potion_pct"
                type="number"
                aria-label="Vida mínima para poção, em por cento"
                min="1"
                max="99"
                value={@potion_cfg.pct}
                phx-debounce="500"
                class="h-6 w-12 rounded border border-pk-line-strong bg-pk-bg px-1 text-center font-mono text-pk-meta text-pk-text focus:border-pk-ok focus:outline-none"
              />
              <span>% · a cada</span>
              <input
                id="potion-cooldown"
                name="potion_cooldown_s"
                type="number"
                aria-label="Intervalo mínimo entre poções, em segundos"
                min="1"
                max="600"
                value={@potion_cfg.cooldown_s}
                phx-debounce="500"
                class="h-6 w-12 rounded border border-pk-line-strong bg-pk-bg px-1 text-center font-mono text-pk-meta text-pk-text focus:border-pk-ok focus:outline-none"
              />
              <span>s</span>
            </form>

            <%!-- The revive RECALLS the Pokémon and puts it back; the potion just
                  heals. HP falls through the higher number first, so a revive
                  threshold ABOVE the potion's means the potion can NEVER fire and
                  the Pokémon is pulled out of every fight. Lucas ran an hour with
                  revive 65 / potion 50 (2026-08-07) and read it as "o bot não faz
                  nada certo" — the bot was doing exactly what the numbers said. --%>
            <p
              :if={@rescue_cfg.enabled and @potion_cfg.enabled and @rescue_cfg.pct >= @potion_cfg.pct}
              id="rescue-above-potion"
              class="mx-3 mb-2 rounded border border-pk-warn-line bg-pk-warn-dim px-2 py-1.5 text-pk-body text-pk-warn"
            >
              ⚠️ O revive ({@rescue_cfg.pct}%) dispara ANTES da poção ({@potion_cfg.pct}%) —
              a vida passa pelo número maior primeiro. Assim a poção nunca acontece e o Pokémon é
              recolhido em toda luta. O revive é o socorro caro: deixe-o BEM abaixo da poção.
            </p>
            <.automation_row
              id="automation-support-waits-capture"
              title="Suporte espera a captura"
              description="ordem pós-luta: loot → bola → suporte"
              detail="Poção e reposição só agem quando os corpos foram resolvidos, com teto de 10s pra nunca segurar a cura."
              active={@support_waits_capture}
              event="toggle_support_waits_capture"
            />

            <.group_header
              label="Só no modo Parado"
              accent="bg-[#1D9E75]"
              note="desligam sozinhas quando você troca pro Movimento"
              badge={
                if @mode_overrides == [],
                  do: "no padrão",
                  else: "#{length(@mode_overrides)} exceção(ões)"
              }
            />
            <.automation_row
              id="automation-reposition"
              title="Reposicionar após lutas"
              description="clique do meio no tile calibrado"
              detail="2s depois da luta acabar, volta pro tile de Calibração → Posição do Pokémon. Andando, isso te arrastaria de volta pro spot."
              active={@reposition_enabled}
              override={:reposition_enabled in @mode_overrides}
              event="toggle_reposition"
            />
            <button
              :if={@player_mode == "still"}
              phx-click="relearn_ground"
              class="mx-3 my-2 flex h-8 items-center gap-1.5 rounded-lg border border-pk-line-strong px-3 font-mono text-pk-meta text-pk-text-2 hover:text-white"
            >
              <.icon name="hero-arrow-path" class="size-3" /> Reaprender chão (mudou de spot)
            </button>
            <button
              :if={@mode_overrides != []}
              id="restore-mode-defaults"
              phx-click="restore_mode_defaults"
              class="mx-3 my-2 flex h-8 items-center gap-1.5 rounded-lg border border-pk-warn-line px-3 font-mono text-pk-meta text-pk-warn hover:bg-pk-warn-dim"
            >
              <.icon name="hero-arrow-uturn-left" class="size-3" /> Restaurar padrão do modo
            </button>

            <.automation_row
              id="automation-require-cooldowns"
              title="Só pescar quando dá pra matar"
              description="segura a fisga até uma skill estar pronta"
              active={@fishing_cfg.require_cooldowns}
              event="toggle_require_cooldowns"
              owner={@settings_owner}
            />
            <form
              id="hook-skills-form"
              phx-submit="save_hook_skills"
              class="border-b border-pk-line px-3 py-2.5"
            >
              <label
                for="hook-skills-input"
                class="flex items-center gap-1.5 font-mono text-pk-meta text-pk-text-3"
              >
                Skills necessárias pra matar <.character_key owner={@settings_owner} />
              </label>
              <div class="mt-1.5 flex gap-2">
                <input
                  id="hook-skills-input"
                  name="hook_skills"
                  value={@fishing_cfg.hook_skills}
                  placeholder="4 5 6 7"
                  class="input input-bordered h-9 min-w-0 flex-1 bg-pk-bg font-mono text-pk-title"
                />
                <button class="btn h-9 border border-pk-ok-line bg-transparent px-4 text-pk-body font-semibold text-pk-ok hover:bg-pk-ok-dim">
                  Salvar
                </button>
              </div>
            </form>
            <.automation_row
              id="automation-require-pokemon-hp"
              title="Só pescar com vida"
              description="segura a fisga se o Pokémon está com pouca vida ou fora da pokébola (lê o monitor de suporte)"
              active={@fishing_cfg.require_pokemon_hp}
              event="toggle_require_pokemon_hp"
              owner={@settings_owner}
            />
            <form id="fishing-hp-form" phx-submit="save_fishing_hp_cfg" class="px-3 py-2.5">
              <label
                for="fishing-hp-input"
                class="flex items-center gap-1.5 font-mono text-pk-meta text-pk-text-3"
              >
                Vida mínima pra puxar a vara (%) <.character_key owner={@settings_owner} />
              </label>
              <div class="mt-1.5 flex gap-2">
                <input
                  id="fishing-hp-input"
                  name="fishing_hp_pct"
                  inputmode="numeric"
                  value={@fishing_cfg.hp_pct}
                  class="input input-bordered h-9 min-w-0 flex-1 bg-pk-bg font-mono text-pk-title"
                />
                <button class="btn h-9 border border-pk-ok-line bg-transparent px-4 text-pk-body font-semibold text-pk-ok hover:bg-pk-ok-dim">
                  Salvar
                </button>
              </div>
            </form>
          </section>

          <%!-- Capture used to be file-only — with the real scores hugging the
                ruler (median 75% vs threshold 72%), tuning meant editing JSON. --%>
          <section class="overflow-hidden rounded-lg border border-pk-line bg-pk-sunken">
            <.group_header
              label="Captura (Pokébola)"
              accent="bg-[#8f6ad1]"
              note="a linha 🔎 do feed mostra o melhor score de cada varredura — ajuste o limiar por ela"
            />
            <div class="space-y-1.5 px-3 py-2.5 font-mono text-pk-meta text-pk-text-3">
              <form
                id="capture-cfg-form"
                phx-change="save_capture_cfg"
                class="flex flex-wrap items-center gap-x-1 gap-y-1.5"
              >
                <label for="captura-match">reconhece com ≥</label>
                <input
                  id="captura-match"
                  name="corpse_match_pct"
                  type="number"
                  aria-label="Similaridade mínima pro corpo casar com o acervo, em por cento"
                  min="30"
                  max="99"
                  value={@capture_cfg.match_pct}
                  phx-debounce="500"
                  class="h-6 w-12 rounded border border-pk-line-strong bg-pk-bg px-1 text-center font-mono text-pk-meta text-pk-text focus:border-pk-ok focus:outline-none"
                />
                <span>% · tecla</span>
                <input
                  id="captura-ball-key"
                  name="ball_key"
                  type="text"
                  aria-label="Atalho da Pokébola"
                  value={@capture_cfg.ball_key}
                  phx-debounce="700"
                  class="h-6 w-12 rounded border border-pk-line-strong bg-pk-bg px-1 text-center font-mono text-pk-meta text-pk-text focus:border-pk-ok focus:outline-none"
                />
                <span>· até</span>
                <input
                  id="captura-max-balls"
                  name="corpse_max_balls"
                  type="number"
                  aria-label="Bolas por corpo antes de desistir"
                  min="1"
                  max="9"
                  value={@capture_cfg.max_balls}
                  phx-debounce="500"
                  class="h-6 w-10 rounded border border-pk-line-strong bg-pk-bg px-1 text-center font-mono text-pk-meta text-pk-text focus:border-pk-ok focus:outline-none"
                />
                <span>bola(s)/corpo · varre</span>
                <input
                  id="captura-radius"
                  name="corpse_scan_radius_tiles"
                  type="number"
                  aria-label="Raio da varredura ao redor do personagem, em tiles"
                  min="1"
                  max="8"
                  value={@capture_cfg.radius_tiles}
                  phx-debounce="500"
                  class="h-6 w-10 rounded border border-pk-line-strong bg-pk-bg px-1 text-center font-mono text-pk-meta text-pk-text focus:border-pk-ok focus:outline-none"
                />
                <span>tile(s) · alarme após</span>
                <input
                  id="captura-dry-alarm"
                  name="dry_balls_alarm"
                  type="number"
                  aria-label="Bolas seguidas sem captura confirmada antes do alarme (0 desliga)"
                  min="0"
                  max="999"
                  value={@capture_cfg.dry_balls_alarm}
                  phx-debounce="500"
                  class="h-6 w-12 rounded border border-pk-line-strong bg-pk-bg px-1 text-center font-mono text-pk-meta text-pk-text focus:border-pk-ok focus:outline-none"
                />
                <span>bola(s) seca(s)</span>
              </form>
            </div>
            <.automation_row
              id="automation-ball-click"
              title="Atalho precisa de CLIQUE"
              description="ligue se o atalho da bola armar uma mira que espera clique no alvo"
              detail="A sequência passa a clicar no corpo depois da tecla. Deixe desligado se a bola sai direto (Quick Cast)."
              active={@capture_cfg.ball_needs_click}
              event="toggle_ball_needs_click"
            />

            <%!-- The brute-force net UNDER the aimed capture. Deliberately its
                  own switch: this is what you turn on when you stopped trusting
                  the aim, so it must not hang off the aim's own switch. --%>
            <.group_header
              label="Varredura cega — a rede de segurança"
              accent="bg-[#8f6ad1]"
              note="sem detector nenhum: de tempos em tempos joga a bola em TODO tile ao redor. Só no modo Parado."
            />
            <.automation_row
              id="automation-sweep"
              title="Varrer os tiles ao redor"
              description={"a cada #{@sweep_cfg.interval_s}s, #{sweep_tiles(@sweep_cfg)} bola(s) — #{sweep_side_label(@sweep_cfg.side)}"}
              detail="Independente do botão Captura: não olha corpo, não olha acervo, não pontua nada. Segura durante luta, mini-game e com o jogo fora de foco."
              active={@sweep_cfg.enabled}
              event="toggle_sweep_enabled"
            />
            <div class="space-y-1.5 px-3 py-2.5 font-mono text-pk-meta text-pk-text-3">
              <form
                id="sweep-cfg-form"
                phx-change="save_sweep_cfg"
                class="flex flex-wrap items-center gap-x-1 gap-y-1.5"
              >
                <label for="sweep-interval">a cada</label>
                <input
                  id="sweep-interval"
                  name="sweep_interval_s"
                  type="number"
                  aria-label="Intervalo entre varreduras, em segundos"
                  min="5"
                  max="3600"
                  value={@sweep_cfg.interval_s}
                  phx-debounce="500"
                  class="h-6 w-14 rounded border border-pk-line-strong bg-pk-bg px-1 text-center font-mono text-pk-meta text-pk-text focus:border-pk-ok focus:outline-none"
                />
                <span>s · raio</span>
                <input
                  id="sweep-radius"
                  name="sweep_radius_tiles"
                  type="number"
                  aria-label="Raio da varredura, em tiles"
                  min="1"
                  max="8"
                  value={@sweep_cfg.radius_tiles}
                  phx-debounce="500"
                  class="h-6 w-10 rounded border border-pk-line-strong bg-pk-bg px-1 text-center font-mono text-pk-meta text-pk-text focus:border-pk-ok focus:outline-none"
                />
                <span>tile(s) ·</span>
                <%!-- His spot has the SEA to the left: half the square is water. --%>
                <select
                  id="sweep-side"
                  name="sweep_side"
                  aria-label="Lado que a varredura cobre"
                  class="h-6 rounded border border-pk-line-strong bg-pk-bg px-1 font-mono text-pk-meta text-pk-text focus:border-pk-ok focus:outline-none"
                >
                  <option value="square" selected={@sweep_cfg.side == "square"}>
                    quadrado completo
                  </option>
                  <option value="right" selected={@sweep_cfg.side == "right"}>
                    daqui pra direita →
                  </option>
                  <option value="left" selected={@sweep_cfg.side == "left"}>
                    ← daqui pra esquerda
                  </option>
                </select>
              </form>
              <p id="sweep-cost" class="text-pk-text-3">
                {sweep_tiles(@sweep_cfg)} bola(s) por passada, ~{sweep_seconds(@sweep_cfg)}s de
                mouse — o resto do bot espera a vez, mas não para.
              </p>
              <div class="flex items-center gap-2 pt-0.5">
                <button
                  id="sweep-now"
                  type="button"
                  phx-click="sweep_now"
                  class="btn btn-xs h-8 border border-pk-warn-line bg-transparent px-3 text-pk-body text-pk-warn hover:bg-pk-warn-dim"
                >
                  <.icon name="hero-beaker" class="size-3" /> Varrer agora
                </button>
                <p :if={@sweep_cfg.msg} id="sweep-msg" class="min-w-0 flex-1 text-pk-warn">
                  {@sweep_cfg.msg}
                </p>
              </div>
            </div>
          </section>

          <section class="overflow-hidden rounded-lg border border-pk-line bg-pk-sunken">
            <.group_header
              label="Estoque — alarmes de suprimento"
              accent="bg-[#b8933d]"
              note="alarma quando a contagem lida no HUD cai abaixo do limiar"
            />
            <div class="px-3 py-2.5 font-mono text-pk-meta text-pk-text-3">
              <form
                id="stock-cfg-form"
                phx-change="save_stock_cfg"
                class="flex flex-wrap items-center gap-x-1 gap-y-1.5"
              >
                <label for="estoque-f1">F1 &lt;</label>
                <input
                  id="estoque-f1"
                  name="stock_alert_f1"
                  type="number"
                  aria-label="Limiar de estoque do slot F1"
                  min="0"
                  max="9999"
                  value={@stock_cfg.f1}
                  phx-debounce="500"
                  class="h-6 w-14 rounded border border-pk-line-strong bg-pk-bg px-1 text-center font-mono text-pk-meta text-pk-text focus:border-pk-ok focus:outline-none"
                />
                <label for="estoque-f2">· F2 &lt;</label>
                <input
                  id="estoque-f2"
                  name="stock_alert_f2"
                  type="number"
                  aria-label="Limiar de estoque do slot F2"
                  min="0"
                  max="9999"
                  value={@stock_cfg.f2}
                  phx-debounce="500"
                  class="h-6 w-14 rounded border border-pk-line-strong bg-pk-bg px-1 text-center font-mono text-pk-meta text-pk-text focus:border-pk-ok focus:outline-none"
                />
                <label for="estoque-e">· E &lt;</label>
                <input
                  id="estoque-e"
                  name="stock_alert_e"
                  type="number"
                  aria-label="Limiar de estoque do slot E"
                  min="0"
                  max="9999"
                  value={@stock_cfg.e}
                  phx-debounce="500"
                  class="h-6 w-14 rounded border border-pk-line-strong bg-pk-bg px-1 text-center font-mono text-pk-meta text-pk-text focus:border-pk-ok focus:outline-none"
                />
                <label for="estoque-sq">· S/Q &lt;</label>
                <input
                  id="estoque-sq"
                  name="stock_alert_s_q"
                  type="number"
                  aria-label="Limiar de estoque dos slots S e Q"
                  min="0"
                  max="9999"
                  value={@stock_cfg.s_q}
                  phx-debounce="500"
                  class="h-6 w-14 rounded border border-pk-line-strong bg-pk-bg px-1 text-center font-mono text-pk-meta text-pk-text focus:border-pk-ok focus:outline-none"
                />
              </form>
            </div>
          </section>

          <section class="overflow-hidden rounded-lg border border-pk-line bg-pk-sunken">
            <.group_header label="Fuga de emergência" accent="bg-[#c94f4f]" />
            <div id="automation-escape" class="px-3 py-2.5">
              <div class="flex min-h-10 items-center gap-3">
                <p class="min-w-0 flex-1 text-pk-body leading-tight text-pk-text-2">
                  anda até o tile calibrado (Calibração → Escada de fuga), entra na escada
                  de seta, para TUDO e toca o alarme — vai ser o protocolo anti-shiny
                </p>
                <button
                  id="test-escape"
                  phx-click="test_escape"
                  data-confirm="Vai CLICAR NO JOGO (no tile calibrado), dar os passos de seta e PARAR todos os bots. Testar a fuga agora?"
                  class="btn btn-xs h-8 shrink-0 border border-pk-warn-line bg-transparent px-3 text-pk-body text-pk-warn hover:bg-pk-warn-dim"
                >
                  <.icon name="hero-beaker" class="size-3" /> Testar fuga
                </button>
              </div>
              <form
                id="escape-cfg-form"
                phx-change="save_escape_cfg"
                title="Depois do clique no tile, espera o personagem ANDAR até lá e então dá os passos de seta pra dentro da escada."
                class="mt-1.5 flex flex-wrap items-center gap-1 font-mono text-pk-meta text-pk-text-3"
              >
                <span>entra pra</span>
                <select
                  id="escape-direction"
                  name="escape_direction"
                  aria-label="Direção de entrada na escada"
                  class="h-6 rounded border border-pk-line-strong bg-pk-bg px-1 font-mono text-pk-meta text-pk-text focus:border-pk-ok focus:outline-none"
                >
                  <option value="left" selected={@escape_cfg.direction == "left"}>← esquerda</option>
                  <option value="right" selected={@escape_cfg.direction == "right"}>→ direita</option>
                  <option value="up" selected={@escape_cfg.direction == "up"}>↑ cima</option>
                  <option value="down" selected={@escape_cfg.direction == "down"}>↓ baixo</option>
                </select>
                <span>×</span>
                <input
                  id="escape-steps"
                  name="escape_steps"
                  type="number"
                  aria-label="Quantos passos de seta dar para dentro da escada"
                  min="1"
                  max="10"
                  value={@escape_cfg.steps}
                  phx-debounce="500"
                  class="h-6 w-10 rounded border border-pk-line-strong bg-pk-bg px-1 text-center font-mono text-pk-meta text-pk-text focus:border-pk-ok focus:outline-none"
                />
                <span>passos · espera a caminhada por</span>
                <input
                  id="escape-walk-wait"
                  name="escape_walk_wait_ms"
                  type="number"
                  aria-label="Espera pela caminhada até a escada, em milissegundos"
                  min="0"
                  max="10000"
                  step="100"
                  value={@escape_cfg.walk_wait_ms}
                  phx-debounce="500"
                  class="h-6 w-14 rounded border border-pk-line-strong bg-pk-bg px-1 text-center font-mono text-pk-meta text-pk-text focus:border-pk-ok focus:outline-none"
                />
                <span>ms</span>
              </form>
            </div>
          </section>

          {render_slot(@inner_block)}

          <%!-- Calibration and diagnostics do NOT live here (each is its own
                job), but this is where he comes looking — so the path is
                written down instead of guessed. --%>
          <section class="rounded-lg border border-pk-line bg-pk-surface p-3">
            <p class="text-pk-body font-semibold">Não é aqui</p>
            <div class="mt-1.5 flex flex-wrap gap-2 text-pk-body">
              <.link navigate={~p"/calibration"} class="underline text-pk-text-2">
                Calibração (áreas da tela)
              </.link>
              <.link navigate={~p"/diagnostics"} class="underline text-pk-text-2">
                Diagnóstico (medições e prints)
              </.link>
              <.link navigate={~p"/cavebot"} class="underline text-pk-text-2">Rotas da caçada</.link>
              <.link navigate={~p"/time"} class="underline text-pk-text-2">Retratos do time</.link>
            </div>
          </section>
        </div>
      </div>
    </div>
    """
  end

  @doc """
  The dot marking a field that follows the ACTIVE character, not the machine.

  Only a handful of keys do (`Pokex.Settings.character_keys/0`), and which ones
  is not guessable from the screen — without a per-field mark, "mudei aqui e o
  outro personagem mudou junto?" can only be answered by testing. Renders
  nothing with no character: then every field on this screen is the base's, and
  the banner at the top already says so.
  """
  attr :owner, :string, default: nil

  def character_key(assigns) do
    ~H"""
    <span
      :if={@owner}
      data-testid="character-key"
      class="shrink-0 font-mono text-pk-meta text-pk-ok"
      title={"Este ajuste é de #{@owner} — os outros personagens têm o deles."}
    >
      •<span class="sr-only">ajuste de {@owner}</span>
    </span>
    """
  end

  # --- the two rows the automations block uses (moved over with the panel) ----

  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :description, :string, required: true
  attr :active, :boolean, required: true
  attr :event, :string, required: true
  attr :detail, :string, default: nil
  attr :override, :boolean, default: false
  attr :owner, :string, default: nil, doc: "character this key follows; nil = it is the base's"

  def automation_row(assigns) do
    ~H"""
    <div
      id={@id}
      class={[
        "flex min-h-12 items-center gap-3 border-b border-pk-line px-3 py-2 last:border-b-0",
        @active && "bg-pk-ok-dim"
      ]}
    >
      <span class={[
        "h-7 w-0.5 shrink-0 rounded-full",
        if(@active, do: "bg-pk-ok", else: "bg-transparent")
      ]} />
      <div class="min-w-0 flex-1">
        <p class="flex items-center gap-1.5 text-pk-body font-semibold text-pk-text">
          <span class="truncate">{@title}</span>
          <.character_key owner={@owner} />
          <%!-- YOUR exception to what the mode promises. Without this, the mode and
                the switch can disagree and only the bot knows which won. --%>
          <span
            :if={@override}
            data-testid="override-badge"
            class="shrink-0 rounded border border-pk-warn-line bg-pk-warn-dim px-1 font-mono text-pk-meta text-pk-warn"
            title="Você mudou esta chave: ela não está no padrão do modo."
          >
            manual
          </span>
        </p>
        <%!-- the description WRAPS instead of truncating: a sentence cut mid-word
              ("segura a fisga se o Pokémon está com pou…") tells him less than no
              sentence at all. The long-form explanation still lives in the tooltip. --%>
        <p class="mt-0.5 text-pk-body leading-tight text-pk-text-2" title={@detail}>
          {@description}
        </p>
      </div>
      <input
        id={"#{@id}-toggle"}
        type="checkbox"
        class="toggle toggle-success toggle-sm shrink-0"
        checked={@active}
        phx-click={@event}
        aria-label={@title}
      />
    </div>
    """
  end

  attr :label, :string, required: true
  attr :accent, :string, required: true
  attr :note, :string, default: nil
  attr :badge, :string, default: nil

  # The header has to carry the SCOPE, not whisper it: which of these switches
  # apply to the mode you are in is the whole reason the groups exist, and a
  # side-note in 11px grey lost that argument (Lucas, 2026-07-22: "it's not
  # very clear these are general points"). So the scope is a full sentence on
  # its own line, under a label that is no longer a mono-caps whisper.
  def group_header(assigns) do
    ~H"""
    <div class="flex items-start gap-2 border-y border-pk-line bg-pk-sunken px-3 py-2 first:border-t-0">
      <span class={["mt-1 h-3 w-0.5 shrink-0 rounded-full", @accent]} />
      <div class="min-w-0 flex-1">
        <p class="text-pk-body font-semibold text-pk-text-2">{@label}</p>
        <p :if={@note} class="text-pk-meta text-pk-text-3">{@note}</p>
      </div>
      <span
        :if={@badge}
        class="shrink-0 rounded border border-pk-line-strong px-1.5 py-0.5 font-mono text-pk-meta text-pk-text-3"
      >
        {@badge}
      </span>
    </div>
    """
  end

  # --- what a sweep costs, before you run one ---------------------------------

  defp sweep_tiles(%{radius_tiles: radius, side: side}),
    do: Pokex.Bots.Catcher.Sweep.tile_count(radius, side)

  # Per tile the Body spends the aim settle, the post-throw hold, and one cursor
  # restore (measured ~65ms in Bots.Body's `with_mouse_restore`). Rounded, and
  # labelled "~" on screen — the point is that raising the radius costs SECONDS,
  # which a tile count alone does not say.
  @mouse_restore_ms 65

  defp sweep_seconds(cfg) do
    per_tile =
      Pokex.Settings.get(:capture_aim_settle_ms) + Pokex.Settings.get(:capture_hold_ms) +
        @mouse_restore_ms

    round(sweep_tiles(cfg) * per_tile / 1000)
  end

  defp sweep_side_label("right"), do: "só daqui pra direita"
  defp sweep_side_label("left"), do: "só daqui pra esquerda"
  defp sweep_side_label(_square), do: "quadrado completo"

  # --- what the rescue combo means on screen (moved over with the panel) ------

  defp rescue_combo_ready?(combos, name) do
    case Enum.find(combos, &(&1.name == name)) do
      nil -> false
      combo -> combo.enabled? and Pokex.Combos.rescue_eligible?(combo)
    end
  end

  defp rescue_combo_preview(combos, name) do
    case Enum.find(combos, &(&1.name == name)) do
      nil ->
        nil

      combo ->
        if Pokex.Combos.rescue_eligible?(combo), do: rescue_preview(combo)
    end
  end

  defp rescue_preview(combo) do
    stun = Enum.map(combo.steps, &preview_step/1)

    tail = [
      Pokex.Settings.get(:rescue_key),
      "retrato",
      Pokex.Settings.get(:max_revive_key),
      Pokex.Settings.get(:rescue_key)
    ]

    Enum.join(stun ++ tail, " → ")
  end

  defp preview_step({:skill, key}), do: key
  defp preview_step({:wait, ms}) when is_integer(ms), do: "#{ms}ms"
  defp preview_step({:wait, setting}), do: "#{preview_wait_ms(setting)}ms"

  defp preview_wait_ms(setting) do
    case Pokex.Settings.get(setting) do
      ms when is_integer(ms) -> ms
      _estranho -> Pokex.Settings.get(:rescue_step_ms)
    end
  rescue
    _no_seed -> Pokex.Settings.get(:rescue_step_ms)
  end

  defp rescue_combo_conflicts(combos, name) do
    case Enum.find(combos, &(&1.name == name)) do
      nil ->
        []

      combo ->
        combat_keys = Pokex.Settings.get(:skill_keys)
        for {:skill, key} <- combo.steps, key in combat_keys, uniq: true, do: "skill #{key}"
    end
  end
end
