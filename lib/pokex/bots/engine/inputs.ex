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

  alias Pokex.Bots.Combat.{Loadout, Plan}

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
          map,
          atom | nil
        ) :: t
  def hands(loadout, picture, config \\ %{}, mode \\ nil) do
    plan = Plan.for(mode)

    ctx = %{
      enemies: Map.get(picture, :enemies),
      ready_keys: picture.ready_keys,
      config: config
    }

    %{
      opening: plan.opening(loadout, ctx),
      # A MÃO PEQUENA: a primeira tecla de DANO, sem escudo e sem aura. É o
      # que uma pilha que a régua já chamou de "não vale a área" merece quando
      # a paciência obriga a limpá-la mesmo assim — gastar a rajada inteira num
      # bicho bobo foi como a barra chegou vazia na pilha de verdade (28/08).
      small: plan.small(loadout, ctx),
      # A MESMA REGRA aqui: `single` é o que a fase `:skipping` gasta nas teclas
      # BARATAS, e uma tecla que não machuca não é barata, é perdida.
      single: plan.single(loadout, ctx),
      # …e o CONTROLE é do modo também: no Auto Combo o stun é a última metade
      # do combo do jogo, e não uma tecla que o cérebro gasta.
      crowd: plan.crowd(loadout, ctx)
    }
  end
end
