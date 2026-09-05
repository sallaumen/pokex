defmodule PokexWeb.CalibrationLibrary do
  @moduledoc """
  Os dois acervos ensinados, desenhados como TABELA e não como linha de texto.

  O que estava quebrado: cada linha era um `flex-wrap` — o input do nome nascia
  com os 320px que o daisyUI dá a `.input`, e o número de amostras (1, 2 ou 3)
  empurrava o switch pra uma coluna diferente em cada linha. Medido na tela
  dele: o mesmo botão "na mira" caía em x=953, x=1001 e x=1049, e a linha de 3
  amostras estourava pra 69px de altura enquanto as outras tinham 40.

  Com grade de colunas fixas, o switch de 25 corpos nasce no mesmo x — que é o
  que faz o olho varrer a coluna inteira de uma vez em vez de caçar botão por
  botão. Cada célula existe SEMPRE (o selo "×N nesta sessão" vira um vão vazio
  quando não há contagem), senão a linha seguinte escorrega uma coluna.
  """
  use PokexWeb, :html

  alias Pokex.Bots.Catcher.CorpseLibrary
  alias Pokex.Bots.PokemonSprites

  attr :entries, :list, required: true
  attr :counts, :map, default: %{}

  @doc """
  O acervo de corpos: a mira da captura.

  Ordenado por estado — quem está na mira primeiro, vetados no fim, cada grupo
  em ordem alfabética. O veto (#253) é uma decisão que vale a pena ver junta:
  espalhado no meio da lista, ninguém lembra quem desligou.
  """
  def taught_corpses(assigns) do
    assigns = assign(assigns, :entries, sort_by_state(assigns.entries))

    ~H"""
    <ul id="corpse-list" class="@container space-y-1">
      <li
        :for={c <- @entries}
        class={[
          "flex flex-wrap items-center gap-x-3 gap-y-2 rounded-lg border border-pk-line px-2 py-1.5",
          "@xl:grid @xl:grid-cols-[0.125rem_minmax(6rem,13rem)_minmax(0,1fr)_auto_auto_auto_1.75rem]",
          if(CorpseLibrary.enabled?(c), do: "bg-pk-sunken", else: "bg-transparent opacity-70")
        ]}
      >
        <span class={[
          "hidden h-7 w-0.5 shrink-0 rounded-full @xl:block",
          if(CorpseLibrary.enabled?(c), do: "bg-pk-ok", else: "bg-pk-line-strong")
        ]} />

        <%!-- The name is not a label: the ball rules match on it, so a typo
              ("Shiny Craby") silently answers to no rule written for Krabby.
              Editable in place, because deleting and re-teaching would cost
              the photographs — and a real shiny corpse may never come again. --%>
        <form phx-submit="corpse_rename" class="contents" id={"corpse-rename-#{c["slug"]}"}>
          <input type="hidden" name="slug" value={c["slug"]} />
          <input
            name="name"
            value={c["name"]}
            aria-label={"nome de #{c["name"]}"}
            class="input input-ghost h-7 w-40 min-w-0 px-1.5 font-mono text-pk-body text-pk-text focus:bg-pk-raised @xl:w-full"
          />
        </form>

        <.samples
          entries={c["samples"]}
          thumb={&CorpseLibrary.thumb/1}
          event="corpse_delete_sample"
          value_key="idx"
          slug={c["slug"]}
          name={c["name"]}
        />

        <span class="pk-num shrink-0 font-mono text-pk-meta text-pk-text-3">
          {length(c["samples"])}/{CorpseLibrary.max_samples()} chãos
        </span>

        <button
          id={"corpse-toggle-#{c["slug"]}"}
          class={[
            "flex h-7 shrink-0 items-center justify-center gap-1 rounded-md border px-2 text-pk-meta font-bold",
            if(CorpseLibrary.enabled?(c),
              do: "border-pk-ok-line bg-pk-ok-dim text-pk-ok hover:brightness-125",
              else: "border-pk-line-strong bg-transparent text-pk-text-3 hover:text-pk-text"
            )
          ]}
          phx-click="corpse_toggle"
          phx-value-slug={c["slug"]}
          title="Na mira leva Pokébola. Ignorado é um VETO: o corpo mais parecido com ele nunca recebe bola."
        >
          <.icon
            name={if CorpseLibrary.enabled?(c), do: "hero-viewfinder-circle", else: "hero-no-symbol"}
            class="size-3.5"
          />
          {if CorpseLibrary.enabled?(c), do: "na mira", else: "ignorar"}
        </button>

        <%!-- always rendered, empty or not: a cell that disappears slides every
              row after it one column to the left. --%>
        <span class="shrink-0 text-right">
          <span
            :if={Map.get(@counts, c["name"], 0) > 0}
            class="pk-num rounded bg-pk-info-dim px-1.5 py-0.5 font-mono text-pk-meta text-pk-info"
            title="encontrados nesta sessão"
          >
            {Map.get(@counts, c["name"])}× nesta sessão
          </span>
        </span>

        <button
          class="grid size-7 shrink-0 place-items-center rounded-md text-pk-text-3 hover:bg-pk-danger-dim hover:text-pk-danger"
          phx-click="corpse_delete"
          phx-value-slug={c["slug"]}
          aria-label={"apagar o corpo de #{c["name"]} inteiro"}
          title={"apagar o corpo de #{c["name"]} inteiro"}
          data-confirm={"Apagar o corpo de #{c["name"]} inteiro?"}
        >
          <.icon name="hero-trash" class="size-4" />
        </button>
      </li>
    </ul>
    """
  end

  attr :entries, :list, required: true

  @doc """
  O acervo do pokémon dele — mesma grade, uma coluna a menos (não há veto: o
  rastreio olha todos os ângulos que existirem).
  """
  def taught_pokemon(assigns) do
    ~H"""
    <ul id="pokemon-list" class="@container space-y-1">
      <li
        :for={entry <- @entries}
        id={"pokemon-" <> entry["slug"]}
        class={[
          "flex flex-wrap items-center gap-x-3 gap-y-2 rounded-lg border border-pk-line bg-pk-sunken px-2 py-1.5",
          "@xl:grid @xl:grid-cols-[minmax(6rem,13rem)_minmax(0,1fr)_auto_1.75rem]"
        ]}
      >
        <span class="truncate text-pk-body font-semibold text-pk-text">{entry["name"]}</span>

        <.samples
          entries={entry["samples"]}
          thumb={&PokemonSprites.thumb/1}
          event="pokemon_delete_sample"
          value_key="index"
          slug={entry["slug"]}
          name={entry["name"]}
        />

        <span class="pk-num shrink-0 font-mono text-pk-meta text-pk-text-3">
          {length(entry["samples"])}/{PokemonSprites.max_samples()} ângulos
        </span>

        <button
          phx-click="pokemon_delete"
          phx-value-slug={entry["slug"]}
          aria-label={"apagar #{entry["name"]} inteiro"}
          title={"apagar #{entry["name"]} inteiro"}
          data-confirm={"Apagar #{entry["name"]} inteiro?"}
          class="grid size-7 shrink-0 place-items-center rounded-md text-pk-text-3 hover:bg-pk-danger-dim hover:text-pk-danger"
        >
          <.icon name="hero-trash" class="size-4" />
        </button>
      </li>
    </ul>
    """
  end

  attr :entries, :list, required: true
  attr :thumb, :any, required: true
  attr :event, :string, required: true
  attr :value_key, :string, required: true
  attr :slug, :string, required: true
  attr :name, :string, required: true

  # The strip of taught photographs. The ✕ used to appear on hover only —
  # unreachable by keyboard; `group-focus-within` gives it the same visibility
  # when the button is tabbed to.
  defp samples(assigns) do
    ~H"""
    <span class="flex min-w-0 flex-wrap items-center gap-1.5">
      <span
        :for={{sample, idx} <- Enum.with_index(@entries)}
        class="group relative inline-block"
      >
        <span
          :if={sample["painted"]}
          class="absolute -left-1 -top-1 z-10 text-pk-meta leading-none"
          title="pintada à mão — troque quando o corpo real aparecer"
        >
          🎨
        </span>
        <img
          src={@thumb.(sample)}
          alt={"amostra #{idx + 1} de #{@name}"}
          title={"amostra #{idx + 1} · #{sample["added_at"]}#{if sample["painted"], do: " · pintada à mão"}"}
          class="size-10 rounded border border-pk-line bg-pk-bg [image-rendering:pixelated]"
        />
        <button
          class="absolute -right-1 -top-1 hidden size-4 items-center justify-center rounded-full bg-pk-danger text-pk-meta leading-none text-pk-bg group-hover:flex group-focus-within:flex focus-visible:flex"
          phx-click={@event}
          phx-value-slug={@slug}
          {sample_index(@value_key, idx)}
          aria-label={"apagar a amostra #{idx + 1} de #{@name}"}
          data-confirm="Apagar esta amostra?"
        >
          ✕
        </button>
      </span>
    </span>
    """
  end

  # The two handlers name the index differently ("idx" for the body, "index" for the pokémon);
  # the strip is the same, so the parameter name becomes data.
  defp sample_index("idx", idx), do: %{"phx-value-idx" => idx}
  defp sample_index("index", idx), do: %{"phx-value-index" => idx}

  # Aimed first, vetoed last; alphabetical within each group.
  defp sort_by_state(entries) do
    Enum.sort_by(entries, &{!CorpseLibrary.enabled?(&1), String.downcase(&1["name"] || "")})
  end
end
