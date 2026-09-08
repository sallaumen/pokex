defmodule Pokex.Bots.Watchman.Checks do
  @moduledoc """
  What the watchman asks, one question at a time, each with the answer he
  needs to hear when it fails: WHICH reading is broken and WHERE to fix it.

  Every check here is a way the bot has already hunted blind for real:

    * the skill bar (2026-09-07): the region travels with the pokémon and was
      the ultrawide's; the notebook answered "outside frame" for a whole run
      and combo and revive went "pelo relógio";
    * the character (2026-09-07): the pointer was cleared at a restart and the
      bot fought as another character's Vespiquen with a Torterra out;
    * the battle window, the Pokebar and HIS life bar: the facts the brain
      decides on, each of which has been unread for hours before;
    * the tile (2026-09-07): 151 points on a 1512-point screen, so the eye
      measured every creature as "1 tile".

  Pure over the blackboard and the files: `run/1` reads, never captures.
  """

  alias Pokex.Bots.ActiveBar
  alias Pokex.Calibration
  alias Pokex.Characters
  alias Pokex.Perception.WorldState
  alias Pokex.Settings

  @type problem :: {atom, String.t()}

  @doc "Every broken reading right now, in a fixed order."
  @spec run(integer) :: [problem]
  def run(now) do
    calib = calibration()
    stale = Settings.get(:watchman_stale_ms)

    []
    |> character()
    |> skill_bar(now, stale, calib)
    |> battle(now, stale)
    |> pokemon(now, stale)
    |> player(now, stale, calib)
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

  defp skill_bar(problems, now, stale, calib) do
    bar = ActiveBar.current()
    name = bar.name || "pokémon"

    cond do
      bar.region == nil ->
        [
          {:skill_bar,
           "#{name} está sem barra de skills calibrada — calibre a dele em /calibration"}
          | problems
        ]

      outside?(bar.region, calib) ->
        {x, _y, _w, _h} = bar.region

        [
          {:skill_bar,
           "a barra de skills do #{name} está marcada fora desta tela (x=#{x}, foi calibrada " <>
             "noutra tela) — recalibre a dele em /calibration"}
          | problems
        ]

      read?(WorldState.get(:skill_bar, stale, now), :ready_keys) ->
        problems

      true ->
        [
          {:skill_bar,
           "a barra de skills do #{name} não é reconhecida há mais de #{seconds(stale)} s — " <>
             "combo e revive andam pelo relógio; recalibre a barra dele em /calibration"}
          | problems
        ]
    end
  end

  defp battle(problems, now, stale) do
    case WorldState.get(:battle, stale, now) do
      {:ok, %{enemies: enemies}} when is_list(enemies) ->
        problems

      _unread ->
        [
          {:battle,
           "a janela de batalha não é lida há mais de #{seconds(stale)} s — o jogo está na " <>
             "frente, inteiro na tela, com a janela de batalha aberta?"}
          | problems
        ]
    end
  end

  defp pokemon(problems, now, stale) do
    if read?(WorldState.get(:pokemon, stale, now), :hp_pct) do
      problems
    else
      [
        {:pokemon,
         "a vida do pokémon (Pokebar) não é lida há mais de #{seconds(stale)} s — " <>
           "recalibre a Pokebar em /calibration"}
        | problems
      ]
    end
  end

  defp player(problems, now, stale, calib) do
    cond do
      calib == nil or calib.player_hp_region == nil ->
        [
          {:player,
           "a barra de vida do PERSONAGEM não está marcada — marque em /calibration; é ela " <>
             "que grita quando VOCÊ está morrendo"}
          | problems
        ]

      match?({:ok, %{readable?: true}}, WorldState.get(:player, stale, now)) ->
        problems

      true ->
        [
          {:player,
           "a vida do PERSONAGEM não é lida há mais de #{seconds(stale)} s — recalibre a " <>
             "barra de vida dele em /calibration"}
          | problems
        ]
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
