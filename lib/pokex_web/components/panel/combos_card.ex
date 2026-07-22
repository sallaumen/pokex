defmodule PokexWeb.Panel.CombosCard do
  @moduledoc """
  The combos card: what sequences exist, whether they are on, and — the part
  that was missing — WHY one did not run.

  Until now combos lived only in `~/.pokex/combos.json`. Worse, a combo that
  matched and could not be played refused in a `Logger.debug`, so switching the
  feature on and seeing nothing happen was indistinguishable from having no
  combo for that enemy. The refusal is shown here in his own words.

  The builder offers the team READ FROM THE SCREEN rather than a free text
  field: a swap to a name that is in no hotkey can never run, and the seeded
  combo is exactly that mistake (it asks for Jigglypuff; his team carries
  Wigglytuff).
  """
  use PokexWeb, :html

  attr :combos, :list, required: true
  attr :enabled, :boolean, required: true
  attr :skip, :map, default: nil
  attr :team, :list, default: []

  def combos_card(assigns) do
    ~H"""
    <section id="combos-card" class="rounded-lg border border-[#232b30] bg-[#111519] p-3">
      <div class="flex items-center justify-between">
        <div class="min-w-0">
          <p class="text-xs font-semibold">Combos</p>
          <p class="mt-0.5 text-[11px] leading-tight text-[#7f8992]">
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
        class="mt-2 rounded-lg border border-[#674f20] bg-[#211b0d] px-2.5 py-1.5 text-[11px] text-[#e7ca82]"
      >
        <.icon name="hero-exclamation-triangle" class="size-3.5 shrink-0" />
        {skip_text(@skip)}
      </p>

      <ul :if={@combos != []} id="combo-list" class="mt-2 space-y-1.5">
        <li
          :for={combo <- @combos}
          id={"combo-#{Phoenix.HTML.html_escape(combo.name) |> Phoenix.HTML.safe_to_string()}"}
          class="rounded-lg border border-[#232b30] bg-[#101418] px-2.5 py-2"
        >
          <div class="flex items-center gap-2">
            <p class={[
              "min-w-0 flex-1 truncate text-[13px] font-semibold",
              if(combo.enabled?, do: "text-[#d9dde1]", else: "text-[#6d7780] line-through")
            ]}>
              {combo.name}
            </p>
            <span class="shrink-0 font-mono text-[9px] text-[#7f8992]">
              {trigger_text(combo.trigger)}
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
              class="shrink-0 text-[#7f8992] transition hover:text-[#ff9ca4]"
              aria-label={"Excluir o combo #{combo.name}"}
            >
              <.icon name="hero-trash" class="size-3.5" />
            </button>
          </div>
          <div class="mt-1.5 flex flex-wrap gap-1">
            <span
              :for={{step, index} <- Enum.with_index(combo.steps)}
              class={[
                "rounded border px-1.5 py-0.5 font-mono text-[9px]",
                step_class(step, @team)
              ]}
              title={step_detail(step, @team)}
            >
              {index + 1}. {step_text(step)}
            </span>
          </div>
        </li>
      </ul>

      <p :if={@combos == []} class="mt-2 text-[11px] text-[#69737b]">
        Nenhum combo ainda. Monte o primeiro abaixo.
      </p>

      <details id="combo-builder" class="group mt-2.5 border-t border-[#222a2f] pt-2.5">
        <summary class="flex cursor-pointer list-none items-center gap-1.5 font-mono text-[10px] uppercase tracking-[0.12em] text-[#69737b] transition hover:text-[#9aa3aa] [&::-webkit-details-marker]:hidden">
          <.icon name="hero-plus-circle" class="size-3" /> Novo combo
        </summary>

        <p :if={@team == []} class="mt-2 text-[11px] text-[#e7ca82]">
          Ainda não li teu time na tela — sem isso não dá pra escolher pra quem trocar.
          Ensine os retratos em <.link navigate={~p"/time"} class="underline">Time</.link>.
        </p>

        <form
          :if={@team != []}
          id="combo-form"
          phx-submit="save_combo"
          class="mt-2 grid gap-1.5"
        >
          <input
            name="name"
            placeholder="nome (ex.: dorme)"
            required
            class="input input-bordered h-8 w-full bg-[#090d0f] text-[12px]"
          />
          <div class="flex gap-1.5">
            <select
              name="trigger_kind"
              class="h-8 flex-1 rounded border border-[#293238] bg-[#090d0f] px-1.5 text-[12px] text-[#dce1e4]"
            >
              <option value="element">quando o inimigo for do tipo</option>
              <option value="species">quando o inimigo for</option>
            </select>
            <input
              name="trigger_value"
              placeholder="Water"
              required
              class="input input-bordered h-8 w-28 bg-[#090d0f] text-[12px]"
            />
          </div>
          <div class="flex gap-1.5">
            <%!-- the team as READ, so a swap to someone with no hotkey is not offerable --%>
            <select
              name="member"
              class="h-8 flex-1 rounded border border-[#293238] bg-[#090d0f] px-1.5 text-[12px] text-[#dce1e4]"
            >
              <option :for={name <- @team} value={name}>trocar pra {name}</option>
            </select>
            <input
              name="skill"
              placeholder="skill"
              required
              class="input input-bordered h-8 w-20 bg-[#090d0f] text-center font-mono text-[12px]"
            />
          </div>
          <label class="flex items-center gap-1.5 text-[11px] text-[#8b949d]">
            <input type="checkbox" name="counter" checked class="checkbox checkbox-xs" />
            no fim, trazer quem tem vantagem contra o inimigo
          </label>
          <button class="btn h-8 border-0 bg-[#37d07d] text-[11px] font-bold text-[#06140c] hover:bg-[#45dd88]">
            Salvar combo
          </button>
        </form>
      </details>
    </section>
    """
  end

  defp trigger_text({:enemy_element, element}), do: "tipo #{element}"
  defp trigger_text({:enemy_species, species}), do: species
  defp trigger_text(_none), do: "sem gatilho"

  defp step_text({:swap_member, name}), do: "troca #{name}"
  defp step_text({:swap_counter}), do: "traz counter"
  defp step_text({:skill, key}), do: "skill #{key}"
  defp step_text({:wait, ms}) when is_integer(ms), do: "espera #{ms}ms"
  defp step_text({:wait, setting}), do: "espera #{setting}"
  defp step_text(_unknown), do: "passo inválido"

  # A swap to somebody who is not in the hotkeys right now cannot run — say it on
  # the chip instead of letting him find out mid-fight (or never).
  defp step_class({:swap_member, name}, team) do
    if name in team,
      do: "border-[#293238] text-[#98a1a8]",
      else: "border-[#5f292f] bg-[#241114] text-[#ff9ca4]"
  end

  defp step_class(_step, _team), do: "border-[#293238] text-[#98a1a8]"

  defp step_detail({:swap_member, name}, team) do
    if name in team,
      do: "#{name} está nos atalhos agora.",
      else: "#{name} NÃO está nos atalhos — este combo não vai rodar."
  end

  defp step_detail(_step, _team), do: nil

  defp skip_text(%{combo: combo, enemy: enemy, reason: reason}),
    do: "#{combo} não rodou contra #{enemy}: #{reason_text(reason)}"

  defp reason_text({:not_on_screen, name}), do: "#{name} não está nos atalhos"
  defp reason_text({:no_counter, enemy}), do: "ninguém no time responde #{enemy}"
  defp reason_text({:bad_step, _step}), do: "um passo do combo não faz sentido"
  defp reason_text(other), do: inspect(other)
end
