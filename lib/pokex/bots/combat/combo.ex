defmodule Pokex.Bots.Combat.Combo do
  @moduledoc """
  A CORRENTE DO JOGO RODANDO — quanto ainda falta pra ela terminar.

  No modo Auto Combo o cliente encadeia as skills ofensivas atrás de um toque
  só, e enquanto essa corrente sai o bot não pode encostar em mais nada: uma
  segunda prensa corta a corrente, e um revive no meio dela recolhe o pokémon
  com metade das skills por sair.

  ## Por que um carimbo, e não um `sleep`

  A decisão chega a cada 200ms e a rajada roda num processo próprio que morre
  em cerca de um segundo — o `burst_pid` (uma rajada em voo) protege por esse
  segundo e não pelos quatro. Uma janela que vive dentro do processo da prensa
  é uma janela que não existe pro tique seguinte.

  Então a janela é um CARIMBO com dono, exatamente como a janela cega do revive
  (`ReviveLedger.landed_within?/1`): quem quer apertar pergunta, e quem responde
  é o relógio das teclas. O eco do `SkillClock` sobrevive ao reset do próprio
  revive, e o `HandWatch` carimba o R que ELE apertou com a própria mão — o que
  é a resposta certa: a corrente está rodando do mesmo jeito.

  ## `nil` é "esta caçada não tem combo"

  Fora do Auto Combo não há corrente pra esperar, e a resposta é `nil` e não
  zero: zero seria "acabou agora", que é uma afirmação sobre uma corrente que
  nunca existiu. Todo consumidor trata `nil` como "não se aplica".
  """

  alias Pokex.Bots.Combat.Loadout
  alias Pokex.Bots.HuntMode
  alias Pokex.Bots.SkillClock
  alias Pokex.Settings

  @doc "A tecla que dispara a corrente."
  @spec key() :: String.t()
  def key, do: Settings.get(:auto_combo_key) |> to_string() |> String.trim()

  @doc "Quanto tempo a corrente ocupa as mãos."
  @spec window_ms() :: non_neg_integer
  def window_ms, do: Settings.get(:auto_combo_window_ms)

  @doc """
  AS TECLAS QUE O JOGO VAI DISPARAR quando a corrente sair — o dano primeiro e o
  controle por último, na mesma ordem que o mundo simulado usa
  (`Sim.World.combo_keys/1`).

  Existe porque o relógio das teclas (`SkillClock`) é a MEMÓRIA DO BOT do que
  foi gasto, e no Auto Combo o bot não aperta nenhuma delas: quem aperta é o
  jogo. Sem carimbá-las, o relógio responde "todas prontas" pra sempre — e foi
  exatamente isso que aconteceu na noite de 02/09 (21 combos, `spent?` falso nas
  210 leituras, zero revives, a pilha crescendo de 5 pra 9 e ficando lá).

  Auras e cura ficam de fora: elas respondem a momentos, não a uma corrente de
  ataque.
  """
  @spec chain_keys(Loadout.t() | nil) :: [String.t()]
  def chain_keys(%Loadout{} = loadout), do: loadout.aoe ++ loadout.single ++ loadout.crowd
  def chain_keys(_no_loadout), do: []

  @doc """
  Quanto falta da corrente em `mode`, em ms — `nil` quando o modo não tem
  corrente, e `0` quando ela já acabou (ou nunca saiu).
  """
  @spec left_ms(HuntMode.t() | nil, integer) :: non_neg_integer | nil
  def left_ms(mode, now \\ now())

  def left_ms(:auto_combo, now) do
    window = window_ms()
    combo_key = key()

    if combo_key == "" or not is_integer(window) or window <= 0,
      do: 0,
      else: remaining(SkillClock.pressed_at(combo_key), window, now)
  end

  def left_ms(_no_combo, _now), do: nil

  @doc """
  A IDADE DO SONO, em ms: há quanto tempo a corrente COMEÇOU — `nil` quando o
  modo não tem corrente ou quando nenhuma saiu ainda.

  É o relógio que licencia o revive a recolher o pokémon sem deixar o
  personagem na frente de bicho acordado (a morte de 03/09, 16:20).

  CONTA DA PRENSA, e isto já foi contado errado. O código acreditava que "no
  Auto Combo a corrente termina em controle, então o fim da corrente É o stun",
  e datava o sono a partir de `pressed_at + window`. No combo DELE o stun é a
  PRIMEIRA skill — "o stun é a primeira coisa do auto-combo, pra já salvar o
  pokémon se ele tiver com baixa vida, não a última coisa, e como ele
  geralmente dura 4,5s, temos de forma muito crítica que usar o revive para
  recuperar os cooldowns dentro desses 4.5s" (12/09). Com a conta velha e os
  números dele (janela 3 s, `stun_window_ms` 5 s), o cérebro se dava por
  coberto até 8 s depois da prensa sobre um sono de 4,5 s: 3,5 segundos de
  proteção que não existem, e é nesse buraco que o revive recolhe o escudo com
  o bicho já acordado.

  Sai do carimbo da tecla e não de uma borda observada: assim um cérebro que
  reiniciou no meio da caçada continua sabendo do sono.
  """
  @spec stun_age_ms(HuntMode.t() | nil, integer) :: non_neg_integer | nil
  def stun_age_ms(mode, now \\ now())

  def stun_age_ms(:auto_combo, now) do
    combo_key = key()

    if combo_key == "", do: nil, else: idade(SkillClock.pressed_at(combo_key), now)
  end

  def stun_age_ms(_no_combo, _now), do: nil

  @doc """
  A corrente ainda está saindo? Só o Auto Combo pode responder que sim.

  É o veredito que a mão consulta antes de cada prensa — no molde do
  `blackout?/1` do combate, que faz a mesma pergunta sobre o F4.
  """
  @spec running?(HuntMode.t() | nil, integer) :: boolean
  def running?(mode, now \\ now()) do
    case left_ms(mode, now) do
      left when is_integer(left) -> left > 0
      _sem_combo -> false
    end
  end

  defp idade(at, now) when is_integer(at), do: max(now - at, 0)
  defp idade(_never_pressed, _now), do: nil

  defp remaining(at, window, now) when is_integer(at), do: max(at + window - now, 0)
  defp remaining(_never_pressed, _janela, _now), do: 0

  defp now, do: System.monotonic_time(:millisecond)
end
