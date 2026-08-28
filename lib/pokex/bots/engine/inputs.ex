defmodule Pokex.Bots.Engine.Inputs do
  @moduledoc """
  What the decision is HANDED about the hands — composed once, for every caller.

  This module exists because the same map was being built twice, and the two
  copies drifted. `Engine.Worker` composed it from the live `%Loadout{}`; the
  bench re-derived it from the simulated world's key kinds. They disagreed in
  two fields, and the disagreement is exactly the kind that makes a night's
  measurement describe a bot nobody runs.

  It is the fourth time this shape of defect is paid for: the bench
  reimplemented the opening combo instead of calling `Strategy` (#358), built
  its world from two seed knobs and ignored the /sim table (#358), treated a
  six-key burst as one instantaneous event (#367), and pinned `luring?` to
  false. A decision input the bench DERIVES is a decision input that can drift;
  one it CALLS cannot.
  """

  alias Pokex.Bots.Combat.{Loadout, Strategy}

  @typedoc "The `hands` half of the decision world."
  @type t :: %{
          opening: [String.t()],
          small: [String.t()],
          single: [String.t()],
          crowd: [String.t()]
        }

  @doc """
  The keys the decision may plan with, for `loadout` under the bar in `picture`.

  `crowd` is the CONTROL keys and nothing else. It used to be
  `Strategy.reserved/1`, which is the EXCLUSION list — control plus the shield,
  "a button whose whole value is being unspent when the trouble arrives", by its
  own doc. The brain spends what is in this field: `Logic.control_ready?/1`
  answers yes when ANY key here is ready, and R10 then stamps `:stunned` and
  fires the revive inside the window. With the control on cooldown and the
  shield ready, that answered yes, the shield went out (a shield puts nothing to
  sleep), and the revive landed in a wide-awake pile — the one thing
  `rescue_stun_first` exists to prevent.

  The exclusion still uses `reserved/1`. If the aura should ride along with the
  control, that is a rule of its own with a field of its own, not a list reused
  for the opposite meaning.
  """
  # A picture is the WHOLE situation map, and this reads one field of it: a
  # closed map here made every real caller (o worker e a bancada) break the
  # contract, and o dialyzer do CI ficou vermelho na main.
  @spec hands(
          Loadout.t() | nil,
          %{:ready_keys => [String.t()] | nil, optional(atom()) => any()},
          map
        ) :: t
  def hands(loadout, picture, config \\ %{})

  def hands(nil, _picture, _config), do: %{opening: [], small: [], single: [], crowd: []}

  def hands(%Loadout{} = loadout, picture, config) do
    %{
      opening:
        Strategy.opening(loadout,
          single_target?: single?(config),
          aura_ready?: Loadout.aura_ready?(loadout, picture.ready_keys),
          shield_ready?: shield?(loadout, picture, config)
        ),
      # A MÃO PEQUENA: a primeira tecla de DANO, sem escudo e sem aura. É o
      # que uma pilha que a régua já chamou de "não vale a área" merece quando
      # a paciência obriga a limpá-la mesmo assim — gastar a rajada inteira num
      # bicho bobo foi como a barra chegou vazia na pilha de verdade (28/08).
      small:
        loadout
        |> Strategy.opening(single_target?: single?(config))
        |> Enum.take(1),
      # A MESMA REGRA aqui: `single` é o que a fase `:skipping` gasta nas teclas
      # BARATAS, e uma tecla que não machuca não é barata, é perdida. Com a área
      # vazia ela volta, pelo mesmo motivo de sempre.
      single: if(single?(config) or loadout.aoe == [], do: loadout.single, else: []),
      crowd: loadout.crowd
    }
  end

  # A AURA DE DEFESA, pela régua dele: a partir de dois em cima, com a tecla
  # pronta. O número é o mesmo que o `Combat.Logic` usa na rotação sustentada —
  # uma regra, um knob, senão a abertura e o resto da luta discordam sobre
  # quando ele fica indestrutível.
  defp single?(config), do: Map.get(config, :single_target, false)

  defp shield?(loadout, picture, config) do
    quantos = Map.get(picture, :enemies)

    is_integer(quantos) and quantos >= Map.get(config, :shield_from, 2) and
      Loadout.shield_ready?(loadout, picture.ready_keys)
  end
end
