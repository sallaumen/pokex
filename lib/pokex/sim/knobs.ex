defmodule Pokex.Sim.Knobs do
  @moduledoc """
  The simulated world's numbers that are NOT the simulator's to invent.

  `Sim.World` labels every knob `measured`, `inherited` or `invented`. The
  inherited ones have an owner elsewhere — the floors between two revives belong
  to `PlayerSupport`, the support ladder's thresholds belong to his settings —
  and a copy of them living in `@default_knobs` is a copy that drifts. It has
  drifted twice already: `revive_cooldown_ms` said 2s against a 60s setting, and
  the bench learned to read `Settings` while the live runner kept the literal,
  so the tab he actually plays in had a revive floor of a full minute and a
  fallen pokémon that could never come back.

  Two readings, for two different questions:

    * `:seeds` — reproducible. A bench verdict has to answer the same on his
      machine and in CI, whatever he tuned today.
    * `:live` — HIS bot. The tab on `/sim` exists to show what his own settings
      do, so it reads what is in force.
  """

  alias Pokex.Settings

  # world knob => the setting that owns it
  @world %{
    revive_cooldown_ms: :rescue_cooldown_ms,
    fainted_revive_cooldown_ms: :fainted_revive_cooldown_ms
  }

  # …and the support ladder, whose three rungs the simulated hands obey.
  @support %{
    heal_skill_enabled: :heal_skill_enabled,
    heal_pct: :pokemon_hp_heal_pct,
    heal_skill_cooldown_ms: :heal_skill_cooldown_ms,
    # …e a aura de defesa, o degrau acima da cura (02/09)
    shield_skill_enabled: :shield_skill_enabled,
    shield_pct: :pokemon_hp_shield_pct,
    shield_skill_cooldown_ms: :shield_skill_cooldown_ms,
    potion_enabled: :potion_enabled,
    potion_pct: :pokemon_hp_potion_pct,
    potion_cooldown_ms: :potion_cooldown_ms,
    # …e o prefixo do resgate: o stun de área guardado pra este momento, e os
    # milissegundos que o pokémon fica em campo DEPOIS dele, tanqueando, pra que
    # a pilha esteja mesmo dormindo antes de o campo esvaziar.
    rescue_stun_first: :rescue_stun_first,
    rescue_stun_settle_ms: :rescue_stun_settle_ms,
    # …e o PREÇO DE CADA TECLA. As teclas de uma rajada saem uma a cada tanto, e
    # o corpo é um só: enquanto a rajada sai, não se anda nem se aperta mais
    # nada. É o número que a Central chama de "o que limita o dano da caçada", e
    # que a bancada media como zero.
    skill_gap_ms: :combat_skill_gap_ms,
    # …E A CORRENTE DO CLIENTE. No Auto Combo o bot aperta uma tecla e é o JOGO
    # que dispara as skills — então quem tem que saber disso é o mundo simulado,
    # não o bot. Sem isto a bancada mediria um bot apertando uma tecla que o
    # mundo ignora: zero mortos, e o veredito culpando a regra em vez do modelo.
    # É a quinta vez que a bancada mediria um parecido.
    combo_key: :auto_combo_key,
    # A CERCA DO BOT (a crença), não a física da corrente: é ela que o cérebro
    # simulado consulta pra saber se ainda está no meio do combo. A duração real
    # da corrente é `combo_chain_ms`, knob do mundo — as duas são a mesma medida
    # com folga diferente, e confundi-las provaria um combo que o jogo não dá.
    combo_window_ms: :auto_combo_window_ms,
    # …e QUANTO ELE INSISTE numa parede antes de desistir do canto. O caminhante
    # simulado não tem o `unstick/3` do cavebot, então sem um teto ele encosta
    # numa pedra e fica lá o resto da corrida — reportando mortos/min de uma
    # caçada que nunca andou. O dono do número é o cavebot, não este arquivo.
    walk_timeout_ms: :cavebot_walk_timeout_ms
  }

  @type source :: :seeds | :live

  @doc "The world knobs whose authority is `Settings`."
  @spec world(source) :: map
  def world(source \\ :seeds), do: read(@world, source)

  @doc "The support ladder the simulated hands obey."
  @spec support(source) :: map
  def support(source \\ :seeds), do: read(@support, source)

  @doc """
  How long a cleared nest takes to come back, for a world that is a HUNT rather
  than a controlled experiment.

  A map that empties once and stays empty is a single fight wearing a night's
  clothes, and it is what the live tab showed until 2026-08-25. Scenarios that
  need a frozen map still pin `respawn_ms: nil` themselves.

  É do simulador, não do bot — por isso é um número daqui e não um ajuste
  (era `sim_respawn_ms` no `Settings` até 02/09).
  """
  @respawn_ms 20_000

  @spec respawn_ms(source) :: pos_integer
  def respawn_ms(_source), do: @respawn_ms

  defp read(knobs, :seeds) do
    seeds = Settings.defaults()
    Map.new(knobs, fn {knob, setting} -> {knob, Map.fetch!(seeds, setting)} end)
  end

  defp read(knobs, _live),
    do: Map.new(knobs, fn {knob, setting} -> {knob, Settings.get(setting)} end)
end
