defmodule Pokex.Bots.ShinyReadiness do
  @moduledoc """
  "Vou pegar um shiny esta noite?" — answered in one place, in the order the
  steps have to happen.

  The machinery is finished and spread over four pages: the colour is taught in
  the calibration, the floor is measured there too, the hunter's switch lives in
  the editors, the ball is chosen there too, and the hunt is watched on the
  Central. Nothing said which of those was missing, so every one of them failed
  SILENTLY: a hunter armed over zero rules reads `—/— px` forever, a rule saved
  and never proven never scans, and `special_colors.json` simply not existing
  looks exactly like a night where no shiny walked past.

  This module is the single source of truth those screens read. `gaps` are the
  steps that make a shiny IMPOSSIBLE, first one first; `notes` are the ones
  that only make it worse (the wrong ball, a route that never stops). Every
  entry carries where to go and what the link should say, because "está
  faltando alguma coisa" without a door is the same silence with more words.
  """

  alias Pokex.Bots.Catcher.Balls
  alias Pokex.Settings
  alias Pokex.Vision.ColorRules

  @type step :: %{key: atom, text: String.t(), href: String.t(), link: String.t()}
  @type t :: %{armed: [String.t()], gaps: [step], notes: [step]}

  @calibration "/calibration"
  # o cartão do caçador mora DENTRO do overlay dos Editores, não no painel: o
  # ponteiro do /config dizia "/" e quem o seguia chegava numa tela sem cartão
  @editors "/config/editores"
  @config "/config"

  @doc "Every step still between him and a shiny in the bag."
  @spec check() :: t
  def check do
    rules = ColorRules.list()
    armed = ColorRules.armed()
    names = Enum.map(armed, & &1.name)

    %{armed: names, gaps: gaps(rules, armed), notes: notes(names, armed)}
  end

  @doc "Nothing blocking: the hunter scans and a sighting becomes a ball."
  @spec ready?(t) :: boolean
  def ready?(%{gaps: gaps}), do: gaps == []

  # ONE step at a time, and only the one he can act on now: listing "ensine uma
  # cor" next to "ligue o caçador" invites doing the second first, which arms a
  # watcher over nothing — the exact silence this module exists to end.
  defp gaps([], _armed),
    do: [
      step(
        :no_rule,
        "nenhuma cor de shiny ensinada — o caçador não tem o que procurar",
        @calibration,
        "ensinar a cor"
      )
    ]

  # NOMEIE A REGRA CERTA. Nada está armado, então nenhuma regra é provada E
  # ligada: toda provada aqui está desligada, e toda ligada está sem prova.
  # Dizer "a cor X" pegando a primeira da lista mandava ele medir o chão de uma
  # regra que já tinha prova, ou ligar uma que já estava ligada.
  defp gaps(rules, []) do
    case Enum.find(rules, &is_map(&1["proven"])) do
      nil ->
        [
          step(
            :unproven,
            "#{quoted(hd(rules))} sem prova do chão — uma regra não provada não varre nada",
            @calibration,
            "medir o chão"
          )
        ]

      proven ->
        [
          step(
            :disabled,
            "#{quoted(proven)} está desligada na lista de cores",
            @calibration,
            "ligar a regra"
          )
        ]
    end
  end

  defp gaps(_rules, _armed) do
    if Settings.get(:shiny_guard_enabled),
      do: [],
      else: [
        step(
          :guard_off,
          "o caçador de shiny está desligado — a cor está pronta e ninguém procura",
          @editors,
          "ligar o caçador"
        )
      ]
  end

  # The two that cost a shiny instead of losing it: the wrong ball leaves, or
  # the road walks off the corpse before the ball does.
  defp notes(_names, []), do: []

  defp notes(names, _armed) do
    default = Balls.default_key()

    ball =
      if Enum.any?(names, &(Balls.key_for(&1) != default)) do
        []
      else
        [
          step(
            :default_ball,
            "o shiny vai levar a bola padrão (#{Balls.label(default)}) — nenhuma regra de bola cita o nome dele",
            @editors,
            "escolher a bola"
          )
        ]
      end

    hold =
      if Settings.get(:engine_capture_hold_ms) > 0 do
        []
      else
        [
          step(
            :no_hold,
            "a rota não para pra bola — o corpo sai da tela antes da segunda foto",
            @config,
            "dar tempo à bola"
          )
        ]
      end

    ball ++ hold
  end

  defp quoted(%{"name" => name}) when is_binary(name), do: "a cor “#{name}”"
  defp quoted(_nameless), do: "a cor ensinada"

  defp step(key, text, href, link),
    do: %{key: key, text: text, href: href, link: link}
end
