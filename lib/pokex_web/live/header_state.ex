defmodule PokexWeb.HeaderState do
  @moduledoc """
  Mantém vivo o header do app em TODAS as páginas.

  O header é o mesmo em toda página (marca, aviso de foco, personagem ativo,
  ligado/parado, navegação), então o estado por trás dele não pode morar dentro
  de uma LiveView só: é montado uma vez aqui, para a `live_session` inteira.

  A posse das mensagens é dividida de propósito. O Painel já assina os tópicos
  dos workers porque precisa do snapshot inteiro (cards e alarme de erro);
  assinar de novo aqui entregaria cada mensagem DUAS vezes pra ele. No painel
  este hook só pega carona no que ele já recebe e devolve a mensagem adiante
  (`:cont`); nas outras páginas ele assina e para a mensagem aqui (`:halt`) —
  uma página sem cláusula pra `{:fishing, _}` levantaria FunctionClauseError no
  `handle_info/2`.
  """
  import Phoenix.Component, only: [assign: 2, assign: 3]
  import Phoenix.LiveView, only: [attach_hook: 4, connected?: 1]

  alias Pokex.Bots.{AlarmCategories, BotSupervisor}
  alias Pokex.Characters
  alias Pokex.Settings

  @focus_topic "focus"
  # A frota que o pill representa: os três workers cujo estado significa "o bot
  # está trabalhando". A caçada entrou na Frente 1 — o cavebot anda a rota com o
  # combate DESLIGADO entre lutas, e sem ele o header jurava "Parado" com o bot
  # caçando (caracterizado na Etapa 0; o teste virou junto com esta linha).
  @worker_topics ["fishing", "combat", "cavebot"]

  def on_mount(:default, _params, _session, socket) do
    owns_workers? = socket.view != PokexWeb.PanelLive

    if connected?(socket) do
      Phoenix.PubSub.subscribe(Pokex.PubSub, @focus_topic)

      if owns_workers?,
        do: Enum.each(@worker_topics, &Phoenix.PubSub.subscribe(Pokex.PubSub, &1))
    end

    socket =
      socket
      |> assign(
        header_owns_workers?: owns_workers?,
        focused?: focused?(),
        characters: Characters.list(),
        active_character: Characters.active(),
        alarm_sound: Settings.get(:alarm_sound),
        alarm_muted_categories: Settings.get(:alarm_muted_categories)
      )
      |> sync_workers(BotSupervisor.status())
      |> attach_hook(:header_state, :handle_info, &info/2)
      |> attach_hook(:header_events, :handle_event, &event/3)

    {:cont, socket}
  end

  @doc """
  Realinha o pill ligado/parado com um `BotSupervisor.status()` recém-lido.

  O painel muda o estado dos workers por ação direta (Iniciar/Parar) e já
  reatribui o status na hora; sem isto o header só descobriria no próximo
  broadcast — o Lucas clicaria "Iniciar" e leria "Parado" por um tick.
  """
  def sync_workers(socket, status) do
    socket
    |> assign(:header_states, %{
      fishing: status.fishing.state,
      combat: status.combat.state,
      cavebot: status.cavebot.state
    })
    |> assign_bot_active()
  end

  defp info({:focus, %{focused?: focused?}}, socket),
    do: {:halt, assign(socket, focused?: focused?)}

  defp info({:fishing, %{state: state}}, socket), do: worker_state(socket, :fishing, state)
  defp info({:combat, %{state: state}}, socket), do: worker_state(socket, :combat, state)
  defp info({:cavebot, %{state: state}}, socket), do: worker_state(socket, :cavebot, state)

  # O RESTO do tráfego dos tópicos que ESTE hook assinou — logs e alarmes que
  # viajam junto com os snapshots ({:fishing_log, _, _}, {:rule_alarm, _}...) —
  # morre aqui nas páginas que não são o painel: a página não pediu essas
  # mensagens e não tem cláusula pra elas (com o bot pescando e a calibração
  # aberta, cada log era um FunctionClauseError que derrubava a LiveView —
  # Lucas, 2026-07-30). No painel (:cont) tudo segue pros handlers dele, que
  # assinou por conta própria.
  @worker_noise [:fishing_log, :combat_log, :cavebot_log, :cavebot_alarm, :rule_alarm]

  defp info(msg, socket)
       when is_tuple(msg) and tuple_size(msg) >= 1 and elem(msg, 0) in @worker_noise,
       do: {if(socket.assigns.header_owns_workers?, do: :halt, else: :cont), socket}

  defp info(_msg, socket), do: {:cont, socket}

  defp worker_state(socket, key, state) do
    socket =
      socket
      |> assign(:header_states, Map.put(socket.assigns.header_states, key, state))
      |> assign_bot_active()

    {if(socket.assigns.header_owns_workers?, do: :halt, else: :cont), socket}
  end

  defp event("set_character", %{"character" => slug}, socket) do
    :ok = Characters.set_active(slug)
    {:halt, assign(socket, active_character: slug)}
  end

  defp event("create_character", %{"name" => name}, socket) do
    case Characters.create(name) do
      {:ok, slug} ->
        :ok = Characters.set_active(slug)
        {:halt, assign(socket, characters: Characters.list(), active_character: slug)}

      {:error, _reason} ->
        {:halt, socket}
    end
  end

  # Som geral: silencia TUDO de uma vez, sem tocar nos setores individuais —
  # reativar o geral devolve o painel exatamente como estava por setor.
  defp event("toggle_alarm_sound", _params, socket) do
    next = not Settings.get(:alarm_sound)
    Settings.put(:alarm_sound, next)
    {:halt, assign(socket, alarm_sound: next)}
  end

  # Mudo POR SETOR (Lucas, 2026-07-30): "canto de comando"/"sessão" costumam
  # ser os barulhentos; Shiny é o que ele quer sempre ligado. `from_string/1`
  # rejeita qualquer valor que não seja um setor conhecido — o clique nunca
  # grava lixo no disco (mesma fronteira do Settings.put/3).
  defp event("toggle_alarm_category", %{"category" => category_text}, socket) do
    if AlarmCategories.from_string(category_text) do
      current = Settings.get(:alarm_muted_categories)

      next =
        if category_text in current,
          do: List.delete(current, category_text),
          else: [category_text | current]

      Settings.put(:alarm_muted_categories, next)
      {:halt, assign(socket, alarm_muted_categories: next)}
    else
      {:halt, socket}
    end
  end

  defp event(_event, _params, socket), do: {:cont, socket}

  # O Catcher fica de fora de propósito: em modo "movimento" ele reporta :manual sempre
  # — escolha de exibição, não sinal de ligado/parado. Mesma regra que o painel usa.
  # A régua do que conta como RODANDO é uma só, BotSupervisor.active?/1 — os
  # estados de parada da caçada (:blocked/:stuck/:fight_stalled) NÃO acendem.
  defp assign_bot_active(socket) do
    assign(
      socket,
      :bot_active?,
      BotSupervisor.any_active?(Map.values(socket.assigns.header_states))
    )
  end

  # O poller de foco pode não ter publicado nada ainda no mount; pergunta direto
  # (falha pro lado de "focado" pra o aviso de pausa nunca aparecer à toa).
  defp focused? do
    Pokex.Bots.Focus.status().focused?
  catch
    _kind, _reason -> true
  end
end
