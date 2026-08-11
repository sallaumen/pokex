defmodule PokexWeb.TimersLive do
  @moduledoc """
  The scheduled actions, with the clock running: what goes off, how far away it
  is, and what it would press if it went off right now.

  He asked for the countdown by name — "tendo um timer desse disparo em algum
  lugar" — and it is the part that makes the feature judgeable: a schedule you
  cannot watch is a schedule you have to trust.
  """
  use PokexWeb, :live_view

  alias Pokex.Bots.Combat.Loadout
  alias Pokex.Bots.Timers.Worker
  alias Pokex.Pokedex.SkillProfile
  alias Pokex.Timers
  alias Pokex.Timers.Store

  @tick_ms 1_000

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Pokex.PubSub, Worker.topic())
      :timer.send_interval(@tick_ms, self(), :refresh)
    end

    {:ok,
     socket
     |> assign(page_title: "Timers", fired: [], form_error: nil)
     |> load()}
  end

  @impl true
  def handle_info(:refresh, socket), do: {:noreply, load(socket)}

  def handle_info({:timer_fired, _id, text}, socket),
    do: {:noreply, assign(socket, fired: Enum.take([text | socket.assigns.fired], 8))}

  def handle_info(_other, socket), do: {:noreply, socket}

  @impl true
  def handle_event("toggle", %{"id" => id, "enabled" => enabled}, socket) do
    Store.toggle(id, enabled == "true")
    announce()
    {:noreply, load(socket)}
  end

  def handle_event("delete", %{"id" => id}, socket) do
    Store.delete(id)
    announce()
    {:noreply, load(socket)}
  end

  def handle_event("save", params, socket) do
    case Timers.from_form(params) do
      {:ok, timer} ->
        Store.add(timer)
        announce()
        {:noreply, socket |> assign(form_error: nil) |> load()}

      :error ->
        {:noreply,
         assign(socket,
           form_error:
             "faltou alguma coisa: nome, um intervalo maior que zero (zero só vale na mobada) " <>
               "e ou um trabalho ou teclas"
         )}
    end
  end

  # The running worker holds the clocks, so the countdown comes from IT and not
  # from a second one kept here — two clocks disagreeing is how a panel starts
  # lying about a bot.
  defp load(socket) do
    status =
      try do
        Worker.status()
      catch
        :exit, _not_running -> %{running?: false, timers: [], loadout: nil}
      end

    # A RUNNING worker's loadout is the one the presses will actually use, so it
    # wins. A stopped one's is a leftover from its last run — trusting it made
    # the page show a pokémon he had already changed.
    loadout = if status.running?, do: status.loadout, else: Loadout.current()

    # The LIST is configuration and comes from the store, always. Only the
    # countdowns come from the worker, matched by id: a timer he just added has
    # to appear immediately, even though the worker has not re-read yet, and one
    # he deleted must not linger because the worker still holds it.
    live = Map.new(status.timers, &{&1.timer.id, &1})

    rows =
      for timer <- Store.all() do
        %{
          timer: timer,
          remaining: live[timer.id][:remaining],
          keys: Timers.keys_for(timer, loadout),
          last_fired: live[timer.id][:last_fired]
        }
      end

    assign(socket, running?: status.running?, rows: rows, loadout: loadout)
  end

  defp announce, do: Phoenix.PubSub.broadcast(Pokex.PubSub, Worker.topic(), {:timers_changed})

  defp countdown(%{remaining: nil}), do: nil
  defp countdown(%{remaining: ms}) when ms <= 0, do: "agora"
  defp countdown(%{remaining: ms}), do: Timers.duration(ms)

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_page={:timers}
      {Layouts.header(assigns)}
      max_width="max-w-[900px]"
    >
      <div class="space-y-3">
        <section class="rounded-lg border border-pk-line bg-pk-surface p-3">
          <h2 class="text-pk-body font-bold">Ações no relógio</h2>
          <p class="mt-0.5 text-pk-meta leading-relaxed text-pk-text-3">
            Coisas que o bot aperta porque um relógio mandou, não porque viu algo na tela.
            <b class="text-pk-text-2">a cada</b>
            conta do próprio último disparo — a berry de 55 minutos.
            <b class="text-pk-text-2">depois de começar a mobar</b>
            conta do instante que a caçada começou a juntar bicho, e sai <b class="text-pk-text-2">uma vez por trecho</b>.
          </p>
          <p class="mt-1.5 font-mono text-pk-meta text-pk-text-3">
            <span :if={@running?} class="text-pk-ok">● os relógios estão correndo</span>
            <span :if={!@running?} class="text-pk-warn">
              ○ o bot está parado — nada dispara, e as contagens só voltam com ele
            </span>
            · em campo: {(@loadout && @loadout.name) || "ninguém escolhido no /time"}
          </p>
        </section>

        <section id="timers-list" class="rounded-lg border border-pk-line bg-pk-surface p-3">
          <p :if={@rows == []} class="text-pk-meta text-pk-text-3">
            nada agendado ainda — o formulário abaixo cria o primeiro
          </p>

          <ul class="space-y-1">
            <li
              :for={row <- @rows}
              id={"timer-" <> row.timer.id}
              class="flex flex-wrap items-center gap-2 rounded-lg border border-pk-line bg-pk-raised px-2.5 py-2"
            >
              <button
                phx-click="toggle"
                phx-value-id={row.timer.id}
                phx-value-enabled={to_string(!row.timer.enabled?)}
                aria-label={"Ligar ou desligar " <> row.timer.name}
                class={[
                  "shrink-0 cursor-pointer rounded border px-2 py-1 font-mono text-pk-meta transition",
                  if(row.timer.enabled?,
                    do: "border-pk-ok-line bg-pk-ok-dim text-pk-ok",
                    else: "border-pk-line text-pk-text-3 hover:text-pk-text"
                  )
                ]}
              >
                {if row.timer.enabled?, do: "ligado", else: "desligado"}
              </button>

              <span class="min-w-0 flex-1">
                <span class="text-pk-body font-semibold">{row.timer.name}</span>
                <span class="ml-1.5 font-mono text-pk-meta text-pk-text-3">
                  {Timers.interval_text(row.timer)}
                </span>
              </span>

              <span class="font-mono text-pk-meta">
                <span :if={row.keys != []} class="text-pk-text-2">
                  {Enum.join(row.keys, " ")}
                </span>
                <span :if={row.keys == []} class="text-pk-warn" title="nada pra apertar agora">
                  {(row.timer.category && "sem #{SkillProfile.label(row.timer.category)}") ||
                    "sem tecla"}
                </span>
              </span>

              <span
                id={"timer-countdown-" <> row.timer.id}
                class="w-20 shrink-0 text-right font-mono text-pk-meta text-pk-ok"
              >
                {countdown(row) || "—"}
              </span>

              <button
                phx-click="delete"
                phx-value-id={row.timer.id}
                title="apagar"
                aria-label={"Apagar " <> row.timer.name}
                class="cursor-pointer text-pk-text-3 hover:text-pk-danger"
              >
                ×
              </button>
            </li>
          </ul>
        </section>

        <section class="rounded-lg border border-pk-line bg-pk-surface p-3">
          <h2 class="mb-2 font-mono text-pk-meta font-bold uppercase tracking-[0.12em] text-pk-text-3">
            nova ação
          </h2>

          <form id="timer-form" phx-submit="save" class="flex flex-wrap items-end gap-2">
            <label class="flex flex-col gap-1 font-mono text-pk-meta text-pk-text-3">
              nome
              <input
                name="name"
                placeholder="berry de XP"
                autocomplete="off"
                class="h-8 w-44 rounded border border-pk-line bg-pk-sunken px-2 text-pk-body text-pk-text focus:border-pk-ok focus:outline-none"
              />
            </label>

            <label class="flex flex-col gap-1 font-mono text-pk-meta text-pk-text-3">
              quando
              <select
                name="trigger"
                class="h-8 rounded border border-pk-line bg-pk-sunken px-1 text-pk-meta text-pk-text focus:border-pk-ok focus:outline-none"
              >
                <option :for={trigger <- Timers.triggers()} value={trigger}>
                  {Timers.trigger_label(trigger)}
                </option>
              </select>
            </label>

            <label class="flex flex-col gap-1 font-mono text-pk-meta text-pk-text-3">
              quanto
              <span class="flex items-center gap-1">
                <input
                  name="after"
                  type="number"
                  min="0"
                  value="55"
                  class="h-8 w-16 rounded border border-pk-line bg-pk-sunken px-1 text-center text-pk-body text-pk-text focus:border-pk-ok focus:outline-none"
                />
                <select
                  name="unit"
                  class="h-8 rounded border border-pk-line bg-pk-sunken px-1 text-pk-meta text-pk-text focus:border-pk-ok focus:outline-none"
                >
                  <option value="min">min</option>
                  <option value="s">s</option>
                </select>
              </span>
            </label>

            <label class="flex flex-col gap-1 font-mono text-pk-meta text-pk-text-3">
              trabalho
              <select
                name="category"
                class="h-8 rounded border border-pk-line bg-pk-sunken px-1 text-pk-meta text-pk-text focus:border-pk-ok focus:outline-none"
              >
                <option value="">— tecla fixa —</option>
                <option :for={category <- SkillProfile.categories()} value={category}>
                  {SkillProfile.icon(category)} {SkillProfile.label(category)}
                </option>
              </select>
            </label>

            <label class="flex flex-col gap-1 font-mono text-pk-meta text-pk-text-3">
              ou teclas
              <input
                name="keys"
                placeholder="8 9"
                autocomplete="off"
                class="h-8 w-24 rounded border border-pk-line bg-pk-sunken px-2 text-pk-body text-pk-text focus:border-pk-ok focus:outline-none"
              />
            </label>

            <button class="btn h-8 border-0 bg-pk-ok px-3 text-pk-meta font-bold text-pk-bg hover:brightness-110">
              Agendar
            </button>
          </form>

          <p class="mt-1.5 font-mono text-pk-meta text-pk-text-3">
            escolher um <b class="text-pk-text-2">trabalho</b>
            faz a ação seguir o pokémon em campo — "a aura" é a aura de quem estiver fora, e
            continua certa depois de trocar. Uma <b class="text-pk-text-2">tecla fixa</b>
            é pra o que não é skill, como as berries.
          </p>

          <p :if={@form_error} id="timer-form-error" class="mt-1.5 text-pk-meta text-pk-warn">
            {@form_error}
          </p>
        </section>

        <section :if={@fired != []} class="rounded-lg border border-pk-line bg-pk-surface p-3">
          <h2 class="mb-1 font-mono text-pk-meta font-bold uppercase tracking-[0.12em] text-pk-text-3">
            disparos desta sessão
          </h2>
          <ul id="timers-fired" class="space-y-0.5 font-mono text-pk-meta text-pk-text-2">
            <li :for={line <- @fired}>{line}</li>
          </ul>
        </section>
      </div>
    </Layouts.app>
    """
  end
end
