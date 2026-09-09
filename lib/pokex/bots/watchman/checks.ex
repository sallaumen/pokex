defmodule Pokex.Bots.Watchman.Checks do
  @moduledoc """
  What the watchman asks, one question at a time, each with the answer he
  needs to hear when it fails: WHICH reading is broken and WHERE to fix it.

  Two kinds of question:

    * **readings** (`readings/1`) — is the skill bar, the battle window, the
      Pokebar and his own life bar being read RIGHT NOW? The watchman samples
      these every second and remembers the last time each was good; a
      reading is a problem only when it has been bad for `watchman_stale_ms`.
      A bar that vanishes for two seconds while the revive recalls the
      pokémon is not a broken bar — on 2026-09-08 a check that looked at the
      current frame alone rang seven times in forty minutes on exactly that;
    * **structure** (`problems/2`) — the character pointer, a bar marked on
      another screen, a screen without a measured tile, his life bar not
      marked at all. True or false at a glance, no sampling.

  Every check here is a way the bot has already hunted blind for real: the
  ultrawide's bar region on the notebook (2026-09-07), the cleared character
  pointer (2026-09-07), the tile of another screen (2026-09-07).

  Pure over the blackboard and the files: nothing here captures.
  """

  alias Pokex.Bots.ActiveBar
  alias Pokex.Calibration
  alias Pokex.Characters
  alias Pokex.Perception.WorldState
  alias Pokex.Settings

  # A fact older than this is not "good now": the feeds publish several times a
  # second, so three seconds of silence is a feed that stopped.
  @fresh_ms 3_000

  @reading_keys [:skill_bar, :battle, :pokemon, :player]

  @type problem :: {atom, String.t()}

  @doc "The readings the watchman samples."
  @spec reading_keys() :: [atom]
  def reading_keys, do: @reading_keys

  @doc "Whether each reading is good right now."
  @spec readings(integer) :: %{atom => boolean}
  def readings(now) do
    %{
      skill_bar: read?(WorldState.get(:skill_bar, @fresh_ms, now), :ready_keys),
      battle:
        match?({:ok, %{enemies: e}} when is_list(e), WorldState.get(:battle, @fresh_ms, now)),
      pokemon: read?(WorldState.get(:pokemon, @fresh_ms, now), :hp_pct),
      player: match?({:ok, %{readable?: true}}, WorldState.get(:player, @fresh_ms, now))
    }
  end

  @doc """
  Every problem standing now, in a fixed order. `last_good` is when each
  reading was last good (the watchman's memory); a reading missing from it is
  taken as good now.
  """
  @spec problems(integer, %{atom => integer}) :: [problem]
  def problems(now, last_good) do
    calib = calibration()
    stale = Settings.get(:watchman_stale_ms)

    []
    |> character()
    |> skill_bar(now, last_good, stale, calib)
    |> battle(now, last_good, stale)
    |> pokemon(now, last_good, stale)
    |> player(now, last_good, stale, calib)
    |> tile(calib)
    |> Enum.reverse()
  end

  defp character(problems) do
    if Characters.active() == "" and Characters.list() != [] do
      [
        {:character,
         "nenhum personagem ativo — o time em uso é o legado, que pode ser de OUTRO " <>
           "personagem; escolha o seu no seletor do cabeçalho"}
        | problems
      ]
    else
      problems
    end
  end

  defp skill_bar(problems, now, last_good, stale, calib) do
    bar = ActiveBar.current()
    name = bar.name || "pokémon"

    cond do
      bar.region == nil ->
        [{:skill_bar, no_bar_here(calib)} | problems]

      outside?(bar.region, calib) ->
        {x, _y, _w, _h} = bar.region

        [
          {:skill_bar,
           "a barra de skills do #{name} está marcada fora desta tela (x=#{x}, foi calibrada " <>
             "noutra tela) — recalibre a dele em /calibration"}
          | problems
        ]

      bad_for?(last_good, :skill_bar, now, stale) ->
        [
          {:skill_bar,
           "a barra de skills do #{name} não é reconhecida há mais de #{seconds(stale)} s — " <>
             "combo e revive andam pelo relógio; recalibre a barra dele em /calibration"}
          | problems
        ]

      true ->
        problems
    end
  end

  # No bar on THIS screen — and the bar is per screen since 09/09: the notebook's
  # Torterra bar does not exist on the ultrawide, and a run there hunted five
  # minutes blind of its cooldowns with alarms saying "recalibre" and nothing
  # saying why. Naming the screen that has it is the whole message.
  defp no_bar_here(calib) do
    name = Pokex.Pokedex.Team.active() || "pokémon"

    case Pokex.Pokedex.Team.bar_screens(name) do
      [] ->
        "#{name} está sem barra de skills calibrada — calibre a dele em /calibration"

      screens ->
        "#{name} tem barra de skills calibrada só #{screens_text(screens)} — nesta tela " <>
          "(#{screen_text(calib)}) não; calibre a dele em /calibration"
    end
  end

  defp screens_text(screens) do
    screens
    |> Enum.map(fn
      {w, h} -> "na tela #{w}×#{h}"
      nil -> "noutra tela"
    end)
    |> Enum.uniq()
    |> Enum.join(" e ")
  end

  defp screen_text(%Calibration{screen_w: w, screen_h: h}) when is_integer(w) and is_integer(h),
    do: "#{w}×#{h}"

  defp screen_text(_no_screen), do: "?"

  defp battle(problems, now, last_good, stale) do
    if bad_for?(last_good, :battle, now, stale) do
      [
        {:battle,
         "a janela de batalha não é lida há mais de #{seconds(stale)} s — o jogo está na " <>
           "frente, inteiro na tela, com a janela de batalha aberta?"}
        | problems
      ]
    else
      problems
    end
  end

  defp pokemon(problems, now, last_good, stale) do
    if bad_for?(last_good, :pokemon, now, stale) do
      [
        {:pokemon,
         "a vida do pokémon (Pokebar) não é lida há mais de #{seconds(stale)} s — " <>
           "recalibre a Pokebar em /calibration"}
        | problems
      ]
    else
      problems
    end
  end

  defp player(problems, now, last_good, stale, calib) do
    cond do
      calib == nil or calib.player_hp_region == nil ->
        [
          {:player,
           "a barra de vida do PERSONAGEM não está marcada — marque em /calibration; é ela " <>
             "que grita quando VOCÊ está morrendo"}
          | problems
        ]

      bad_for?(last_good, :player, now, stale) ->
        [
          {:player,
           "a vida do PERSONAGEM não é lida há mais de #{seconds(stale)} s — recalibre a " <>
             "barra de vida dele em /calibration"}
          | problems
        ]

      true ->
        problems
    end
  end

  # The tile comes from the screen (`Pokex.Screen.Tile`), and a screen nobody
  # measured has none: every distance from the character would be in a made-up
  # unit. The preflight refuses it; this catches a calibration swapped under a
  # running bot.
  defp tile(problems, %Calibration{} = calib) do
    case Calibration.tile(calib) do
      {:ok, _px} ->
        problems

      {:unknown, {w, h}} ->
        [
          {:tile,
           "esta tela (#{w}×#{h}) não tem o tamanho do tile medido — o bot conhece " <>
             "#{Pokex.Screen.Tile.known_text()}; meça o tile desta tela e cadastre em " <>
             "Pokex.Screen.Tile"}
          | problems
        ]
    end
  end

  defp tile(problems, _no_calibration), do: problems

  # A reading never sampled is taken as good: the watchman's grace covers the
  # start, and a stale entry is the only proof of a broken reading.
  defp bad_for?(last_good, key, now, stale) do
    case Map.get(last_good, key) do
      at when is_integer(at) -> now - at > stale
      nil -> false
    end
  end

  defp read?({:ok, obs}, key), do: is_list(Map.get(obs, key)) or is_integer(Map.get(obs, key))
  defp read?(_unread, _key), do: false

  defp outside?({x, y, w, h}, %Calibration{screen_w: sw, screen_h: sh})
       when is_integer(sw) and is_integer(sh),
       do: x + w > sw or y + h > sh

  defp outside?(_region, _no_screen), do: false

  defp seconds(ms), do: div(ms, 1_000)

  defp calibration do
    case Calibration.load() do
      {:ok, %Calibration{} = calib} -> calib
      _none -> nil
    end
  end
end
