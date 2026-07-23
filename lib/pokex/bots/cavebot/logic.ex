defmodule Pokex.Bots.Cavebot.Logic do
  @moduledoc """
  Máquina de estados PURA do cavebot, estilo constante.

  O Combat roda o tempo todo: a Logic liga ele no arranque (`:run_combat` no
  primeiro tick) e só desliga quando bloqueia — o Worker, ao ver o primeiro
  `{:block, _}`, para tudo. Entre um waypoint e outro a Logic anda, confirma
  progresso pela posição, cede quando aparece inimigo e retoma a rota depois
  do clear sustentado + dwell.

  Pureza total: sem processo, sem relógio, sem tela, sem Settings. A `config`
  e o `now` (inteiro monotônico em ms) vêm por parâmetro — é o que permite
  testar a máquina inteira sem jogo rodando.

  Estados: `:walking` → `:fighting` → `:post_fight` → `:walking`, com os
  desvios `:stuck` (sem progresso andando), `:fight_stalled` (luta que não
  termina) e `:blocked` (terminal: mudança de andar ou retries esgotados).

  Cegueira (posição desconhecida) NÃO é estado: segurar o passo é o certo, e um
  segundo de leitura ruim é rotina — virar `{:block, _}` seria pior que o mal.
  Mas ela fica MARCADA em `since[:blind]` e legível por `blind_ms/2`, porque
  "parado porque não sei onde estou" e "parado porque travou" são a mesma coisa
  vistos de fora, e não podem ser.
  """

  alias Pokex.Bots.Cavebot.Route

  @enforce_keys [:route, :config]
  defstruct state: :walking,
            route: nil,
            wp_index: 0,
            combat_running?: false,
            since: %{},
            retries: 0,
            config: nil,
            last_pos: nil

  @type state :: :walking | :fighting | :post_fight | :stuck | :fight_stalled | :blocked

  @type action ::
          :none
          | {:walk, integer, integer}
          | :run_combat
          | :halt_combat
          | {:nudge, integer, integer}
          | {:block, atom}

  @type world :: %{
          pos: {integer, integer, integer} | nil,
          enemies: non_neg_integer,
          combat_state: atom
        }

  @type config :: %{
          arrival_tolerance: non_neg_integer,
          walk_timeout_ms: non_neg_integer,
          stuck_max_retries: non_neg_integer,
          clear_debounce_ms: non_neg_integer,
          fight_timeout_ms: non_neg_integer,
          post_kill_dwell_ms: non_neg_integer
        }

  @type t :: %__MODULE__{
          state: state,
          route: Route.t(),
          wp_index: non_neg_integer,
          combat_running?: boolean,
          since: %{optional(atom) => integer},
          retries: non_neg_integer,
          config: config,
          last_pos: {integer, integer, integer} | nil
        }

  @doc """
  Cria a máquina para uma rota: `state: :walking`, `wp_index: 0`,
  `combat_running?: false`. A `config` fica guardada na struct.
  """
  @spec new(Route.t(), config) :: t
  def new(%Route{} = route, config) when is_map(config) do
    %__MODULE__{route: route, config: config}
  end

  @doc """
  Um tick da constante: recebe o mundo observado e o relógio, devolve a
  máquina atualizada e UMA ação para o Worker traduzir.

  Ordem das decisões:

  1. `:blocked` é terminal — sempre `{logic, :none}`.
  2. Mudança de andar (`pos` não-nil com z diferente da rota) bloqueia em
     qualquer estado: `{:block, :floor_changed}`. Safety antes de tudo.
  3. Arranque: com `combat_running?` false, liga o Combat (`:run_combat`)
     e nada mais neste tick.
  4. Despacho por estado.
  """
  @spec step(t, world, integer) :: {t, action}
  def step(%__MODULE__{state: :blocked} = logic, _world, _now), do: {logic, :none}

  def step(%__MODULE__{route: %Route{z: route_z}} = logic, %{pos: pos}, _now)
      when is_tuple(pos) and elem(pos, 2) != route_z do
    {%{logic | state: :blocked}, {:block, :floor_changed}}
  end

  def step(%__MODULE__{combat_running?: false} = logic, _world, _now) do
    {%{logic | combat_running?: true}, :run_combat}
  end

  def step(%__MODULE__{state: :walking} = logic, world, now), do: walk(logic, world, now)
  def step(%__MODULE__{state: :stuck} = logic, world, now), do: stuck(logic, world, now)
  def step(%__MODULE__{state: :fighting} = logic, world, now), do: fight(logic, world, now)

  def step(%__MODULE__{state: :fight_stalled} = logic, world, now),
    do: fight_stalled(logic, world, now)

  def step(%__MODULE__{state: :post_fight} = logic, world, now), do: post_fight(logic, world, now)

  @doc """
  Há quantos ms a máquina está sem saber onde o personagem está — `nil` quando a
  coordenada está sendo lida. É o que o Worker transforma em motivo visível.
  """
  @spec blind_ms(t, integer) :: non_neg_integer | nil
  def blind_ms(%__MODULE__{since: since}, now) do
    case Map.get(since, :blind) do
      nil -> nil
      at -> max(now - at, 0)
    end
  end

  # --- :walking ---

  # Inimigo na tela: o Combat (sempre rodando) já luta — só muda de estado.
  defp walk(logic, %{enemies: enemies}, now) when enemies > 0 do
    since = logic.since |> Map.delete(:clear) |> Map.put(:fight, now)
    {%{logic | state: :fighting, since: since}, :none}
  end

  # Posição desconhecida: segura — nunca anda às cegas. E MARCA a cegueira, pra
  # o Worker poder dizer há quanto tempo está assim.
  defp walk(logic, %{pos: nil}, now), do: {blind(logic, now), :none}

  defp walk(logic, %{pos: {x, y, _} = pos}, now) do
    logic = sighted(logic)
    wp = current_wp(logic)
    dx = wp.x - x
    dy = wp.y - y
    tol = logic.config.arrival_tolerance

    cond do
      abs(dx) <= tol and abs(dy) <= tol ->
        next = rem(logic.wp_index + 1, length(logic.route.waypoints))
        {%{note_progress(logic, pos, now) | wp_index: next}, :none}

      pos != logic.last_pos ->
        {note_progress(logic, pos, now), {:walk, dx, dy}}

      now - Map.get(logic.since, :walk_progress, now) >= logic.config.walk_timeout_ms ->
        {%{logic | state: :stuck, retries: 0}, {:walk, dx, dy}}

      true ->
        {logic, {:walk, dx, dy}}
    end
  end

  # --- :stuck ---

  defp stuck(logic, %{pos: nil}, now), do: {blind(logic, now), :none}

  defp stuck(logic, %{pos: pos} = world, now) do
    logic = sighted(logic)

    if pos != logic.last_pos do
      # Voltou a se mexer: retoma a rota com os retries zerados.
      walk(%{logic | state: :walking, retries: 0}, world, now)
    else
      retries = logic.retries + 1

      if retries > logic.config.stuck_max_retries do
        {%{logic | state: :blocked}, {:block, :stuck}}
      else
        wp = current_wp(logic)
        {x, y, _} = pos
        {%{logic | retries: retries}, {:walk, wp.x - x, wp.y - y}}
      end
    end
  end

  # --- :fighting ---

  # Tela limpa: sustenta o debounce antes de dar a luta por encerrada.
  defp fight(logic, %{enemies: 0}, now) do
    case Map.get(logic.since, :clear) do
      nil ->
        {%{logic | since: Map.put(logic.since, :clear, now)}, :none}

      clear_since ->
        if now - clear_since >= logic.config.clear_debounce_ms do
          since =
            logic.since
            |> Map.drop([:clear, :fight])
            |> Map.put(:dwell, now)

          {%{logic | state: :post_fight, since: since}, :none}
        else
          {logic, :none}
        end
    end
  end

  # Inimigo ainda vivo: zera o clear e vigia o timeout da luta.
  defp fight(logic, _world, now) do
    since = Map.delete(logic.since, :clear)

    case Map.get(since, :fight) do
      nil ->
        {%{logic | since: Map.put(since, :fight, now)}, :none}

      fight_since ->
        if now - fight_since >= logic.config.fight_timeout_ms do
          {%{logic | state: :fight_stalled, since: since, retries: 0}, :none}
        else
          {%{logic | since: since}, :none}
        end
    end
  end

  # --- :fight_stalled ---

  # O nudge é a tentativa de destravar uma luta que não termina — então tem que
  # MEXER o personagem. `{:nudge, 0, 0}` não mexia: o Worker traduz o nudge em
  # `Body.minimap_step/3`, que clica no centro da região do minimapa — o tile
  # onde o personagem já está. Era um no-op garantido, gastando os retries até o
  # `{:block, :fight_stalled}` sem nunca ter tentado nada.
  defp fight_stalled(logic, world, _now) do
    retries = logic.retries + 1

    if retries > logic.config.stuck_max_retries do
      {%{logic | state: :blocked}, {:block, :fight_stalled}}
    else
      {dx, dy} = nudge_step(logic, world)
      {%{logic | retries: retries}, {:nudge, dx, dy}}
    end
  end

  # UM tile na direção do waypoint atual. Sem posição lida — ou já em cima do
  # waypoint — desempata pelo eixo x: qualquer direção serve, (0,0) não.
  defp nudge_step(logic, %{pos: {x, y, _}}) do
    wp = current_wp(logic)
    one_tile(wp.x - x, wp.y - y)
  end

  defp nudge_step(_logic, _world), do: {1, 0}

  defp one_tile(0, 0), do: {1, 0}
  defp one_tile(dx, dy), do: {sign(dx), sign(dy)}

  defp sign(0), do: 0
  defp sign(n) when n > 0, do: 1
  defp sign(_n), do: -1

  # --- :post_fight ---

  defp post_fight(logic, _world, now) do
    dwell_since = Map.get(logic.since, :dwell, now)

    if now - dwell_since >= logic.config.post_kill_dwell_ms do
      since =
        logic.since
        |> Map.delete(:dwell)
        |> Map.put(:walk_progress, now)

      {%{logic | state: :walking, since: since, last_pos: nil}, :none}
    else
      {logic, :none}
    end
  end

  # --- helpers ---

  defp current_wp(logic), do: Enum.at(logic.route.waypoints, logic.wp_index)

  defp note_progress(logic, pos, now) do
    %{logic | last_pos: pos, since: Map.put(logic.since, :walk_progress, now)}
  end

  # O relógio da cegueira marca a PRIMEIRA leitura sem posição e não reinicia
  # nos ticks seguintes — o que interessa é o tempo total às escuras.
  defp blind(%__MODULE__{since: since} = logic, now) do
    if Map.has_key?(since, :blind),
      do: logic,
      else: %{logic | since: Map.put(since, :blind, now)}
  end

  defp sighted(%__MODULE__{since: since} = logic) do
    if Map.has_key?(since, :blind),
      do: %{logic | since: Map.delete(since, :blind)},
      else: logic
  end
end
