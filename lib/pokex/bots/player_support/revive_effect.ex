defmodule Pokex.Bots.PlayerSupport.ReviveEffect do
  @moduledoc """
  O juiz de EFEITO do revive: pagou e a vida não voltou?

  A morte de 01/09 às 08:14 (e a segunda, às 08:21): a BAG estava sem revive.
  O F4 aterrissava ("✂️" provou), o jogo aceitava a tecla e não fazia NADA — o
  tanque sangrou 55%→2% com o cérebro pedindo revive a cada 5s pra sempre.
  Dez "o revive não saiu" seguidos e nenhum grito: o desarme de 3-quebras do
  #453 só vigia o revive de RESET (R3b); os revives de BANDA (amarelo/vermelho)
  repetiam mudos. E o alerta de estoque vigia o número DECLARADO
  (`revive_stock`), que dizia 2000.

  Este módulo é puro e julga o que nenhum contador declarado pode mentir: a
  VIDA. Um revive pago com o pokémon machucado tem que curar; se em ~4,5s a
  barra não subiu, é uma quebra. Três seguidas = a bag está seca (ou o jogo
  parou de aceitar F4 — as duas conclusões pedem o mesmo grito). O caído que
  precisa de insistência conta strike direto: pagou e ninguém levantou.

  O worker é quem grita (categoria `:mortal`, que fura o mudo) e pede o
  logout (`player_hp_logout`) — aqui só existe o veredito.
  """

  @probe_max_hp 60
  @probe_after_ms 4_500
  @probe_blind_max_ms 10_000
  @healed_jump 25
  @healed_floor 90
  @streak_to_scream 3
  @scream_refractory_ms 120_000

  @type t :: %{
          probe: nil | %{at: integer, hp: 0..100},
          streak: non_neg_integer,
          screamed_at: nil | integer
        }

  def new, do: %{probe: nil, streak: 0, screamed_at: nil}

  @doc """
  Um resgate foi PAGO com o pokémon nesta vida. Só vidas ≤ #{@probe_max_hp}%
  abrem sonda: um revive de reset em pokémon cheio não tem cura pra medir.
  """
  def paid(judge, hp, now) when is_integer(hp) and hp <= @probe_max_hp,
    do: %{judge | probe: %{at: now, hp: hp}}

  def paid(judge, _healthy_or_unknown, _now), do: judge

  @doc "O caído precisou de INSISTÊNCIA: pagou e ninguém levantou — strike direto."
  def fallen_again(judge, now), do: judge |> strike() |> verdict(now)

  @doc """
  Uma leitura de vida. Fecha a sonda vencida (curou = zera; não curou =
  strike) e devolve `{judge, :quiet | :scream}` — `:scream` no máximo uma vez
  por janela de #{div(@scream_refractory_ms, 1000)}s.
  """
  def tick(judge, hp, _now) when is_integer(hp) and hp >= @healed_floor,
    do: {%{judge | probe: nil, streak: 0}, :quiet}

  def tick(%{probe: %{at: at, hp: was}} = judge, hp, now)
      when is_integer(hp) and now - at >= @probe_after_ms do
    if hp >= was + @healed_jump,
      do: {%{judge | probe: nil, streak: 0}, :quiet},
      else: %{judge | probe: nil} |> strike() |> verdict(now)
  end

  # The probe won and the bar is still unreadable: the pokémon did not come back to the
  # screen. After #{@probe_blind_max_ms}ms of blindness, that IS the break.
  def tick(%{probe: %{at: at}} = judge, hp, now)
      when not is_integer(hp) and now - at >= @probe_blind_max_ms do
    %{judge | probe: nil} |> strike() |> verdict(now)
  end

  def tick(judge, _hp, _now), do: {judge, :quiet}

  defp strike(judge), do: %{judge | streak: judge.streak + 1}

  defp verdict(%{streak: streak} = judge, now) when streak >= @streak_to_scream do
    if judge.screamed_at == nil or now - judge.screamed_at >= @scream_refractory_ms,
      do: {%{judge | screamed_at: now}, :scream},
      else: {judge, :quiet}
  end

  defp verdict(judge, _now), do: {judge, :quiet}

  @doc "Quantas quebras seguidas o juiz viu — pro texto do grito."
  def streak(%{streak: streak}), do: streak
end
