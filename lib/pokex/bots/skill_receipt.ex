defmodule Pokex.Bots.SkillReceipt do
  @moduledoc """
  Did the skill actually go off?

  Pressing a key proves nothing. The window can be unfocused, the safety gate shut, the mana
  short, the client busy, and the bot happily carries on as if the screen had answered. In
  fishing that cost a few seconds. Hunting is another game, harder and more dangerous by his
  account, and the press that matters most is the crowd control that puts everything around him
  to sleep BEFORE his pokémon leaves the field.

  There is a receipt, and it was already on screen: **the cooldown**. A skill that fired is no
  longer ready. So a press is confirmed by comparing the skill bar before and after it: no new
  perception, no new calibration, just reading what the game already answers with.

  Four outcomes per key, and the last two are the important ones:

    * `fired` - it was ready, and now it is not;
    * `missed` - it was ready, and it still is: the press did not land;
    * `unknown` - it was already cooling (nothing to fire), or the bar could not be read.
      Never counted as fired. A caller that treats "I could not see" as "it worked" is
      exactly the caller that strips the field with the mobs wide awake.
    * `off_bar` - the key is not a hotbar slot, so this receipt could never have said
      anything about it. NOT the same as `unknown`, and filing it as one is how a whole
      night of data lies.

  A DIFERENÇA ENTRE OS DOIS ÚLTIMOS CUSTOU CINCO DIAS DE MEDIÇÃO. No modo Auto
  Combo dele a tecla apertada é `shift+3`, que dispara a corrente DENTRO do jogo
  e não é slot nenhum da barra: o recibo saía `unknown` em 100% das prensas por
  construção. Contados nos eventos de 08 a 12/09: 10.978 recibos, 3 `fired`. Um
  gráfico disso diz "a barra está cega" com a mesma cara que "essa pergunta não
  cabia aqui" — e as duas coisas pedem consertos opostos.
  """

  @type reading :: [String.t()] | nil
  @type check :: %{
          fired: [String.t()],
          missed: [String.t()],
          unknown: [String.t()],
          off_bar: [String.t()]
        }

  @doc """
  Compares the ready keys before and after the press.

  `before` and `later` are `ready_keys` readings (see
  `Pokex.Perception.ready_skills/1`) — `nil` when the bar had no reading at
  all, which makes every key unknown.
  """
  @spec check(reading, reading, [String.t()]) :: check
  def check(before, later, keys) do
    keys
    |> Enum.reduce(%{fired: [], missed: [], unknown: [], off_bar: []}, fn key, acc ->
      Map.update!(acc, verdict_for(before, later, key), &[key | &1])
    end)
    |> Map.new(fn {outcome, keys} -> {outcome, Enum.reverse(keys)} end)
  end

  # A pergunta só existe pra tecla que é slot: o resto o cooldown não responde.
  defp verdict_for(_before, _later, key) when not is_binary(key), do: :off_bar

  defp verdict_for(before, later, key) do
    if hotbar?(key), do: on_bar_verdict(before, later, key), else: :off_bar
  end

  defp hotbar?(key), do: key in ~w(1 2 3 4 5 6 7 8 9 0)

  defp on_bar_verdict(nil, _later, _key), do: :unknown
  defp on_bar_verdict(_before, nil, _key), do: :unknown

  defp on_bar_verdict(before, later, key) do
    cond do
      # it was cooling already: there was nothing for the press to spend
      key not in before -> :unknown
      key in later -> :missed
      true -> :fired
    end
  end

  @doc """
  What the caller should act on.

  `{:missed, keys}` outranks everything else: something provably did not
  happen, and the caller can press it again. `:unconfirmed` is the honest
  middle — nothing is known to have failed, but nothing is known to have
  worked either, so a caller about to do something irreversible should treat
  it as a warning rather than as a green light.
  """
  @spec verdict(check) :: :confirmed | :unconfirmed | {:missed, [String.t()]}
  def verdict(%{missed: [_ | _] = missed}), do: {:missed, missed}
  def verdict(%{unknown: [_ | _]}), do: :unconfirmed
  # Nada foi visto porque não havia o que ver: continua sendo o meio honesto —
  # quem ia fazer algo irreversível não ganhou luz verde nenhuma.
  def verdict(%{off_bar: [_ | _]}), do: :unconfirmed
  def verdict(%{}), do: :confirmed
end
