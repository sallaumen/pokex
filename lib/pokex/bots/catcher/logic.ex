defmodule Pokex.Bots.Catcher.Logic do
  @moduledoc """
  Pure decision core for corpse capture (spec 2026-07-10-corpse-capture-design.md): admit
  detected corpses into a queue, keep exactly ONE ball in flight, confirm each throw against
  observations captured after the ball's flight window (a hit consumes the corpse instantly —
  game rule), retry once, and ignore persistent non-corpses (a parked pet) for a TTL. No I/O,
  no clock: the driver supplies observations and monotonic `now`.
  """

  defstruct state: :idle,
            config: nil,
            queue: [],
            throw: nil,
            ignored: %{},
            last_obs_at: nil,
            # bolas RESOLVIDAS sem captura confirmada, em sequência ("não é
            # corpo" e inconclusivas): ao bater config.dry_balls_alarm, alarme
            # e recomeço — o espelho do arremesso seco da pesca.
            dry_balls: 0,
            error: nil,
            counters: %{captures: 0, throws: 0, ignored: 0}

  def new(config), do: %__MODULE__{config: config}

  def start(%__MODULE__{} = logic, _now) do
    {%{logic | state: :armed, queue: [], throw: nil, ignored: %{}, last_obs_at: nil, error: nil},
     []}
  end

  def stop(logic), do: {%{logic | state: :idle, queue: [], throw: nil}, []}

  @doc "Observation step. obs = %{corpses: [{x,y}], captured_at: ms} | nil (nothing fresh)."
  def step(%__MODULE__{state: :idle} = logic, _obs, _now), do: {logic, []}
  def step(logic, nil, _now), do: {logic, []}

  # A warmup frame (`scanning?: false`) proves nothing about the ground — its `corpses` list
  # is always empty by construction, so letting it fall through would falsely CONFIRM any
  # pending throw as captured (and, worse, admit nothing while wiping the queue's chance to
  # re-admit). Must be checked before the freshness dedup below: a warmup frame is fresh
  # (captured_at keeps advancing) and would otherwise reach the general clause.
  def step(logic, %{scanning?: false}, _now), do: {logic, []}

  def step(%{last_obs_at: last} = logic, %{captured_at: at}, _now)
      when is_integer(last) and at <= last,
      do: {logic, []}

  def step(logic, obs, now) do
    logic = %{prune_ignored(logic, now) | last_obs_at: obs.captured_at}

    {logic, confirm_actions} = confirm(logic, obs, now)
    logic = admit(logic, obs)
    {logic, throw_actions} = maybe_throw(logic, now)

    {logic, confirm_actions ++ throw_actions}
  end

  @doc """
  Poll cadence while work is pending; nil when there is nothing to watch.

  Com uma bola em voo, o wake mira o PRAZO REAL da confirmação
  (`throw.at + corpse_confirm_after_ms`): acordar antes disso rende uma
  varredura que a confirmação descarta ("ainda voando") — era uma varredura
  inteira jogada fora por bola.
  """
  def next_wake(%__MODULE__{state: :idle}, _now), do: nil
  def next_wake(%__MODULE__{throw: nil, queue: []}, _now), do: nil

  def next_wake(%__MODULE__{throw: %{at: at}, config: config}, now),
    do: max(at + config.corpse_confirm_after_ms - now, 1)

  def next_wake(%__MODULE__{config: config}, _now), do: max(config.feed_corpses_ms, 1)

  @doc """
  O instante em que a bola REALMENTE saiu: o driver chama depois do
  Body.perform (a sequência move+espera+tecla leva ~200ms), e a janela de
  confirmação passa a contar da atuação, não da decisão — senão o prazo
  desconta o tempo de fila do Body e a primeira leitura julga cedo demais.
  """
  def ball_flown(%__MODULE__{throw: %{} = throw} = logic, at),
    do: %{logic | throw: %{throw | at: at}}

  def ball_flown(logic, _at), do: logic

  @doc """
  Corpses still being worked (queued + the one ball in flight) — the post-fight
  policy signal: suporte can wait for this to hit zero before healing/moving.
  """
  def pending(%__MODULE__{state: :idle}), do: 0

  def pending(%__MODULE__{queue: queue, throw: throw}),
    do: length(queue) + if(throw, do: 1, else: 0)

  # -- confirmation -------------------------------------------------------------

  defp confirm(%{throw: nil} = logic, _obs, _now), do: {logic, []}

  defp confirm(%{throw: throw, config: config} = logic, obs, now) do
    cond do
      # the ball is still flying — this frame proves nothing
      obs.captured_at < throw.at + config.corpse_confirm_after_ms ->
        {logic, []}

      # A observação chegou TARDE demais (luta longa no meio, captura
      # travada): o chão que ela mostra provavelmente já é OUTRO — julgar
      # agora contaria captura de um corpo que talvez nem seja o mesmo.
      # Inconclusiva: descarta o throw sem contar captura nem gastar bola.
      obs.captured_at > throw.at + config.corpse_confirm_after_ms * 6 ->
        seca(%{logic | throw: nil}, [
          {:log, "confirmação inconclusiva (observação tardia) em #{point_str(throw.point)}"}
        ])

      # past the flight window, still there (moved-or-not is irrelevant) → retry
      present?(obs.corpses, throw.point, config.corpse_match_tolerance_px) and
          throw.balls < config.corpse_max_balls ->
        logic = update_in(logic.counters.throws, &(&1 + 1))

        {%{logic | throw: %{throw | balls: throw.balls + 1, at: now}},
         [
           {:capture_sequence, throw.point},
           {:log, "bola #{throw.balls + 1} em #{point_str(throw.point)}"}
         ]}

      # past the window, still there, and out of balls → not a corpse; ignore
      # for the TTL — guardando a IDENTIDADE: um corpo NOVO de outra espécie
      # caindo no mesmo tile não pode herdar o veto deste.
      present?(obs.corpses, throw.point, config.corpse_match_tolerance_px) ->
        logic = update_in(logic.counters.ignored, &(&1 + 1))

        entrada = %{
          ate: now + config.corpse_ignore_ttl_ms,
          nome: nome_em(obs, throw.point, config.corpse_match_tolerance_px)
        }

        seca(
          %{logic | throw: nil, ignored: Map.put(logic.ignored, throw.point, entrada)},
          [{:log, "não é corpo (#{point_str(throw.point)}); ignorando"}]
        )

      # past the window, gone → captured
      true ->
        logic = update_in(logic.counters.captures, &(&1 + 1))

        {%{logic | throw: nil, dry_balls: 0}, [{:log, "capturado em #{point_str(throw.point)}"}]}
    end
  end

  # O espelho do arremesso seco da pesca: N bolas seguidas resolvidas SEM
  # captura confirmada = ou o atalho não chega no jogo, ou a mira está errada,
  # ou o acervo tem um falso-positivo comendo a fila. Alarme e recomeço;
  # 0 = desligado.
  defp seca(logic, actions) do
    dry = logic.dry_balls + 1
    teto = Map.get(logic.config, :dry_balls_alarm, 0)

    if teto > 0 and dry >= teto do
      {%{logic | dry_balls: 0},
       actions ++
         [
           {:alarm,
            "🥎 #{dry} bolas seguidas sem captura confirmada — o atalho chega no jogo? " <>
              "a mira está no corpo? tem falso-positivo na fila?"}
         ]}
    else
      {%{logic | dry_balls: dry}, actions}
    end
  end

  # A identidade que a varredura já conhece no ponto — pro veto do ignore não
  # contaminar um corpo futuro de OUTRA espécie no mesmo tile.
  defp nome_em(obs, ponto, tolerancia) do
    obs
    |> Map.get(:known, %{})
    |> Enum.find_value(fn {p, %{name: nome}} -> if near?(p, ponto, tolerancia), do: nome end)
  end

  # -- admission ---------------------------------------------------------------

  defp admit(logic, obs) do
    tolerance = logic.config.corpse_match_tolerance_px
    ocupados = logic.queue ++ if logic.throw, do: [logic.throw.point], else: []

    fresh =
      Enum.reject(obs.corpses, fn c ->
        Enum.any?(ocupados, &near?(&1, c, tolerance)) or vetado?(logic, obs, c, tolerance)
      end)

    %{logic | queue: logic.queue ++ fresh}
  end

  # O veto do ignore é por IDENTIDADE quando dá: um ponto vetado como "Pet"
  # não segura um Kingler recém-caído no mesmo tile. Sem nome dos dois lados
  # (acervo antigo, leitura sem known), o veto por ponto continua valendo —
  # falha pro lado conservador.
  defp vetado?(logic, obs, candidato, tolerance) do
    Enum.any?(logic.ignored, fn {ponto, entrada} ->
      near?(ponto, candidato, tolerance) and mesma_identidade?(entrada, obs, candidato, tolerance)
    end)
  end

  defp mesma_identidade?(%{nome: nil}, _obs, _candidato, _tol), do: true

  defp mesma_identidade?(%{nome: nome_vetado}, obs, candidato, tol) do
    case nome_em(obs, candidato, tol) do
      nil -> true
      nome_novo -> nome_novo == nome_vetado
    end
  end

  defp mesma_identidade?(_entrada_antiga, _obs, _candidato, _tol), do: true

  defp maybe_throw(%{throw: nil, queue: [point | rest]} = logic, now) do
    logic = update_in(logic.counters.throws, &(&1 + 1))

    {%{logic | throw: %{point: point, balls: 1, at: now}, queue: rest},
     [{:capture_sequence, point}, {:log, "bola em #{point_str(point)}"}]}
  end

  defp maybe_throw(logic, _now), do: {logic, []}

  defp prune_ignored(logic, now) do
    %{logic | ignored: Map.filter(logic.ignored, fn {_point, entrada} -> ate(entrada) > now end)}
  end

  defp ate(%{ate: expiry}), do: expiry
  defp ate(expiry) when is_integer(expiry), do: expiry

  defp present?(corpses, point, tolerance),
    do: Enum.any?(corpses, &near?(&1, point, tolerance))

  defp near?({ax, ay}, {bx, by}, tolerance),
    do: abs(ax - bx) <= tolerance and abs(ay - by) <= tolerance

  defp point_str({x, y}), do: "#{x},#{y}"
end
