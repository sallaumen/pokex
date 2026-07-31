defmodule PokexWeb.Panel.CombosCard do
  @moduledoc """
  The combos card: what exists, whether it is on, WHY one did not run — and
  the editor where combos are built.

  The editor was rebuilt 2026-07-30 for two real defects. First, the fields
  had no server-side value while the panel re-renders on every worker
  snapshot (~10x/s), so everything typed vanished on blur — the DRAFT now
  lives in the assigns, and no re-render erases it. Second, the form could
  only build ONE combo shape (swap → skill → bring the counter), so a plain
  "skill 1, wait, skill 2" — the auto-revive stun — was impossible to create;
  steps are now free-form.

  The swap step still offers the team READ FROM THE SCREEN (a swap to someone
  not in the hotkeys never runs), but that no longer blocks the whole editor:
  a skills-only combo needs no team at all.
  """
  use PokexWeb, :html

  attr :combos, :list, required: true
  attr :enabled, :boolean, required: true
  attr :skip, :map, default: nil
  attr :team, :list, default: []
  attr :draft, :map, required: true
  attr :rescue_combo, :string, default: ""

  def combos_card(assigns) do
    ~H"""
    <section id="combos-card" class="rounded-lg border border-pk-line bg-pk-surface p-3">
      <div class="flex items-center justify-between">
        <div class="min-w-0">
          <p class="text-pk-body font-semibold">Combos</p>
          <p class="mt-0.5 text-pk-body leading-tight text-pk-text-2">
            sequências que ele joga sozinho ao engajar
          </p>
        </div>
        <input
          id="combos-enabled-toggle"
          type="checkbox"
          class="toggle toggle-success toggle-sm shrink-0"
          checked={@enabled}
          phx-click="toggle_combos_enabled"
          aria-label="Combos ligados"
        />
      </div>

      <%!-- A combo that MATCHED and could not run. Silence here is what cost him
            a whole night of Water fights with nothing to show. --%>
      <p
        :if={@skip}
        id="combo-skip"
        class="mt-2 rounded-lg border border-pk-warn-line bg-pk-warn-dim px-2.5 py-1.5 text-pk-body text-pk-warn"
      >
        <.icon name="hero-exclamation-triangle" class="size-3.5 shrink-0" />
        {skip_text(@skip)}
      </p>

      <ul :if={@combos != []} id="combo-list" class="mt-2 space-y-1.5">
        <li
          :for={combo <- @combos}
          id={"combo-#{Phoenix.HTML.html_escape(combo.name) |> Phoenix.HTML.safe_to_string()}"}
          class="rounded-lg border border-pk-line bg-pk-sunken px-2.5 py-2"
        >
          <div class="flex items-center gap-2">
            <p class={[
              "min-w-0 flex-1 truncate text-pk-body font-semibold",
              if(combo.enabled?, do: "text-pk-text", else: "text-pk-text-3 line-through")
            ]}>
              {combo.name}
            </p>
            <%!-- Which combo hangs off the revive: the Support card picks it,
                  but THIS is where the sequence is inspected — the badge keeps
                  him from editing the wrong combo. --%>
            <span
              :if={combo.name == @rescue_combo}
              data-testid="combo-rescue-badge"
              class="shrink-0 rounded border border-pk-ok-line bg-pk-ok-dim px-1.5 py-0.5 font-mono text-pk-meta text-pk-ok"
              title="Este combo é o stun que roda antes do revive automático"
            >
              🚑 no revive
            </span>
            <span class="shrink-0 font-mono text-pk-meta text-pk-text-2">
              {trigger_text(combo.trigger)}
            </span>
            <span
              :if={combo.dungeon}
              class="shrink-0 rounded border border-pk-line-strong px-1.5 py-0.5 font-mono text-pk-meta text-pk-text-2"
              title={"Só vale na dungeon #{combo.dungeon}"}
            >
              DG {combo.dungeon}
            </span>
            <input
              type="checkbox"
              class="toggle toggle-success toggle-xs shrink-0"
              checked={combo.enabled?}
              phx-click="toggle_combo"
              phx-value-name={combo.name}
              aria-label={"Combo #{combo.name} ligado"}
            />
            <button
              phx-click="delete_combo"
              phx-value-name={combo.name}
              data-confirm={"Excluir o combo \"#{combo.name}\"?"}
              class="shrink-0 text-pk-text-2 transition hover:text-pk-danger"
              aria-label={"Excluir o combo #{combo.name}"}
            >
              <.icon name="hero-trash" class="size-3.5" />
            </button>
          </div>
          <div class="mt-1.5 flex flex-wrap gap-1">
            <span
              :for={{step, index} <- Enum.with_index(combo.steps)}
              class={[
                "rounded border px-1.5 py-0.5 font-mono text-pk-meta",
                step_class(step, @team)
              ]}
              title={step_detail(step, @team)}
            >
              {index + 1}. {step_text(step)}
            </span>
          </div>
        </li>
      </ul>

      <p :if={@combos == []} class="mt-2 text-pk-body text-pk-text-3">
        Nenhum combo ainda. Monte o primeiro abaixo.
      </p>

      <details id="combo-builder" class="group mt-2.5 border-t border-pk-line pt-2.5">
        <summary class="flex cursor-pointer list-none items-center gap-1.5 font-mono text-pk-meta uppercase tracking-[0.12em] text-pk-text-3 transition hover:text-pk-text-2 [&::-webkit-details-marker]:hidden">
          <.icon name="hero-plus-circle" class="size-3" /> Novo combo
        </summary>

        <form
          id="combo-form"
          phx-change="combo_draft"
          phx-submit="save_combo"
          class="mt-2 grid gap-1.5"
        >
          <input
            id="combo-name"
            name="name"
            value={@draft.name}
            phx-debounce="blur"
            placeholder="nome (ex.: resgate)"
            class="input input-bordered h-8 w-full bg-pk-bg text-pk-body"
          />

          <div class="flex gap-1.5">
            <select
              id="combo-trigger-kind"
              name="trigger_kind"
              class="h-8 flex-1 rounded border border-pk-line-strong bg-pk-bg px-1.5 text-pk-body text-pk-text"
            >
              <option value="element" selected={@draft.trigger_kind == "element"}>
                quando o inimigo for do tipo
              </option>
              <option value="species" selected={@draft.trigger_kind == "species"}>
                quando o inimigo for
              </option>
              <option value="any" selected={@draft.trigger_kind == "any"}>
                contra qualquer inimigo
              </option>
              <option value="rescue_only" selected={@draft.trigger_kind == "rescue_only"}>
                só no resgate (nunca em luta)
              </option>
            </select>
            <input
              :if={@draft.trigger_kind in ["element", "species"]}
              id="combo-trigger-value"
              name="trigger_value"
              value={@draft.trigger_value}
              phx-debounce="blur"
              placeholder={if @draft.trigger_kind == "element", do: "Water", else: "Magikarp"}
              class="input input-bordered h-8 w-28 bg-pk-bg text-pk-body"
            />
          </div>

          <%!-- The trigger that reserves the skills: a rescue-only combo is
                never spent on a regular fight — it waits for the moment the
                pokémon goes down. --%>
          <p
            :if={@draft.trigger_kind == "rescue_only"}
            class="text-pk-body leading-tight text-pk-text-2"
          >
            Este combo nunca roda numa luta. Escolha ele no card do <b>Suporte</b>
            para ele virar o stun que acontece antes do revive.
          </p>

          <input
            :if={@draft.trigger_kind != "rescue_only"}
            id="combo-dungeon"
            name="dungeon"
            value={@draft.dungeon}
            phx-debounce="blur"
            placeholder="dungeon (vazio = todas)"
            class="input input-bordered h-8 w-full bg-pk-bg text-pk-body"
          />

          <%!-- Free-form steps: a combo is a sequence, not a fixed-shape form
                (the 1→2 stun was impossible to build before). --%>
          <div class="rounded-lg border border-pk-line bg-pk-sunken p-2">
            <div :if={@draft.steps != []} class="mb-1.5 flex flex-wrap gap-1">
              <span
                :for={{step, index} <- Enum.with_index(@draft.steps)}
                class="flex items-center gap-1 rounded border border-pk-line-strong px-1.5 py-0.5 font-mono text-pk-meta text-pk-text-2"
              >
                {index + 1}. {step_text(step)}
                <button
                  type="button"
                  phx-click="remove_combo_step"
                  phx-value-index={index}
                  class="text-pk-text-3 transition hover:text-pk-danger"
                  aria-label={"Remover passo #{index + 1}"}
                >
                  ✕
                </button>
              </span>
            </div>
            <p :if={@draft.steps == []} class="mb-1.5 text-pk-body text-pk-text-3">
              Sem passos ainda — monte a sequência abaixo.
            </p>

            <div class="flex gap-1.5">
              <select
                id="combo-step-kind"
                name="step_kind"
                class="h-8 flex-1 rounded border border-pk-line-strong bg-pk-bg px-1.5 text-pk-body text-pk-text"
              >
                <option value="skill" selected={@draft.step_kind == "skill"}>usar skill</option>
                <option value="wait" selected={@draft.step_kind == "wait"}>esperar</option>
                <option value="swap_member" selected={@draft.step_kind == "swap_member"}>
                  trocar pra
                </option>
                <option value="swap_counter" selected={@draft.step_kind == "swap_counter"}>
                  trazer quem tem vantagem
                </option>
              </select>

              <select
                :if={@draft.step_kind == "swap_member" and @team != []}
                id="combo-step-member"
                name="step_value"
                class="h-8 w-32 rounded border border-pk-line-strong bg-pk-bg px-1.5 text-pk-body text-pk-text"
              >
                <option :for={name <- @team} value={name} selected={@draft.step_value == name}>
                  {name}
                </option>
              </select>
              <input
                :if={@draft.step_kind in ["skill", "wait"]}
                id="combo-step-value"
                name="step_value"
                value={@draft.step_value}
                phx-debounce="blur"
                placeholder={if @draft.step_kind == "skill", do: "1", else: "500"}
                class="input input-bordered h-8 w-20 bg-pk-bg text-center font-mono text-pk-body"
              />

              <button
                type="button"
                id="combo-add-step"
                phx-click="add_combo_step"
                class="btn h-8 border border-pk-line-strong bg-transparent px-2.5 text-pk-body font-semibold text-pk-text-2 hover:bg-pk-raised hover:text-white"
              >
                + passo
              </button>
            </div>

            <p
              :if={@draft.step_kind == "swap_member" and @team == []}
              class="mt-1.5 text-pk-body text-pk-warn"
            >
              Ainda não li teu time na tela — ensine os retratos em
              <.link navigate={~p"/time"} class="underline">Time</.link>
              pra poder trocar. Skills e esperas funcionam sem isso.
            </p>
            <p :if={@draft.step_kind == "wait"} class="mt-1.5 text-pk-body text-pk-text-3">
              Espera em milissegundos (500 = meio segundo).
            </p>
          </div>

          <button class="btn h-8 border border-pk-ok-line bg-transparent text-pk-body font-semibold text-pk-ok hover:bg-pk-ok-dim">
            Salvar combo
          </button>
        </form>
      </details>
    </section>
    """
  end

  defp trigger_text({:enemy_element, element}), do: "tipo #{element}"
  defp trigger_text({:enemy_species, species}), do: species
  defp trigger_text({:any_enemy}), do: "qualquer inimigo"
  defp trigger_text({:rescue_only}), do: "só no resgate"
  defp trigger_text(_none), do: "sem gatilho"

  defp step_text({:swap_member, name}), do: "troca #{name}"
  defp step_text({:swap_counter}), do: "traz counter"
  defp step_text({:skill, key}), do: "skill #{key}"
  defp step_text({:wait, ms}) when is_integer(ms), do: "espera #{ms}ms"
  # A wait step stores the SETTING it follows, so the tuned value is never
  # duplicated into the combo. Print what it currently means — "espera
  # combo_swap_wait_ms" is an internal name leaking onto Lucas's screen, and it
  # does not answer the only question the chip is there to answer: how long.
  defp step_text({:wait, setting}) when is_atom(setting), do: "espera #{wait_ms(setting)}ms"
  defp step_text(_unknown), do: "passo inválido"

  defp wait_ms(setting) do
    case Pokex.Settings.get(setting) do
      ms when is_integer(ms) -> ms
      _unset -> "?"
    end
  end

  # A swap to somebody who is not in the hotkeys right now cannot run — say it on
  # the chip instead of letting him find out mid-fight (or never).
  defp step_class({:swap_member, name}, team) do
    if name in team,
      do: "border-pk-line-strong text-pk-text-2",
      else: "border-pk-danger-line bg-pk-danger-dim text-pk-danger"
  end

  defp step_class(_step, _team), do: "border-pk-line-strong text-pk-text-2"

  defp step_detail({:swap_member, name}, team) do
    if name in team,
      do: "#{name} está nos atalhos agora.",
      else: "#{name} NÃO está nos atalhos — este combo não vai rodar."
  end

  # The setting name still belongs SOMEWHERE — a hover away, not on the chip.
  defp step_detail({:wait, setting}, _team) when is_atom(setting),
    do: "espera o valor de #{setting} (ajustável nas configurações)"

  defp step_detail(_step, _team), do: nil

  defp skip_text(%{combo: combo, enemy: enemy, reason: reason}),
    do: "#{combo} não rodou contra #{enemy}: #{reason_text(reason)}"

  defp reason_text({:not_on_screen, name}), do: "#{name} não está nos atalhos"
  defp reason_text({:no_counter, enemy}), do: "ninguém no time responde #{enemy}"
  defp reason_text({:bad_step, _step}), do: "um passo do combo não faz sentido"
  defp reason_text(other), do: inspect(other)
end
