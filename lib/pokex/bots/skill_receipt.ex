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
    * `refilled` - a revive landed between the two readings, and a revive gives the WHOLE
      bar back. "It was ready and it still is" stops being evidence: the key may well have
      fired and been handed straight back. Not `missed`, because accusing here makes the
      bot press again what already went out.

  A DIFERENÇA ENTRE OS DOIS ÚLTIMOS CUSTOU CINCO DIAS DE MEDIÇÃO. As três teclas
  que ele aperta hoje são `r` (a corrente do Auto Combo, `auto_combo_key`),
  `shift+3` (a postura de defesa) e `shift+1` (a de ataque, aposentada em #643).
  NENHUMA delas é slot da barra: a corrente dispara DENTRO do jogo e a postura
  é um atalho do cliente. O recibo se responde comparando o cooldown de um slot
  antes e depois, então a pergunta nunca coube — `unknown` em 100% das prensas,
  por construção.

  Contado nos recibos de 12/09: 2.146 recibos, e as teclas neles são `r` (1.146),
  `shift+3` (1.000) e `shift+1` (179). De 08 a 12/09: 10.978 recibos, 3 `fired`.
  Um gráfico disso diz "a barra está cega" com a mesma cara que "essa pergunta
  não cabia aqui" — e as duas coisas pedem consertos opostos.
  """

  @type reading :: [String.t()] | nil
  @type check :: %{
          fired: [String.t()],
          missed: [String.t()],
          unknown: [String.t()],
          off_bar: [String.t()],
          refilled: [String.t()]
        }

  @doc """
  Compares the ready keys before and after the press.

  `before` and `later` are `ready_keys` readings (see
  `Pokex.Perception.ready_skills/1`) — `nil` when the bar had no reading at
  all, which makes every key unknown.
  """
  @spec check(reading, reading, [String.t()]) :: check
  def check(before, later, keys), do: check(before, later, keys, false)

  @doc """
  Same, told whether a revive landed inside the window.

  O REVIVE DEVOLVE A BARRA INTEIRA, então um recibo que o atravessa não tem o
  que medir: "estava pronta e continua pronta" deixa de ser prova de que a
  tecla não saiu — ela pode ter saído e voltado. Sem isto o recibo acusa
  `missed` em teclas que funcionaram, e `missed` manda o worker APERTAR DE
  NOVO: a interferência vira gasto.

  É o meio termo que ele pediu (12/09): "se alguma interferência rolar, avisa
  que até deu certo, só que com ressalva" — aqui isso é a caixa `refilled`, que
  o veredito trata como `:unconfirmed` (sem luz verde, sem retentativa) e o
  worker narra como aviso.
  """
  @spec check(reading, reading, [String.t()], boolean) :: check
  def check(before, later, keys, revived?) do
    keys
    |> Enum.reduce(
      %{fired: [], missed: [], unknown: [], off_bar: [], refilled: []},
      fn key, acc -> Map.update!(acc, verdict_for(before, later, key, revived?), &[key | &1]) end
    )
    |> Map.new(fn {outcome, keys} -> {outcome, Enum.reverse(keys)} end)
  end

  # A pergunta só existe pra tecla que é slot: o resto o cooldown não responde.
  defp verdict_for(_before, _later, key, _revived?) when not is_binary(key), do: :off_bar

  defp verdict_for(before, later, key, revived?) do
    if hotbar?(key),
      do: before |> on_bar_verdict(later, key) |> softened(revived?),
      else: :off_bar
  end

  # SÓ A ACUSAÇÃO AMOLECE. `fired` continua `fired` (a tecla esfriou APESAR do
  # revive, o que só acontece se ela saiu depois dele), e `unknown` já é o meio
  # honesto. O que o revive tira é o direito de dizer "não saiu".
  defp softened(:missed, true), do: :refilled
  defp softened(outcome, _revived?), do: outcome

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

  `refilled` cai no meio honesto pela mesma razão que `off_bar`: a pergunta não
  teve como ser respondida. A diferença é que ela CHEGOU A SER FEITA e a
  resposta veio contaminada — por isso ela tem caixa própria e vira aviso no
  diário, em vez de sumir dentro de `unknown`.
  """
  @spec verdict(check) :: :confirmed | :unconfirmed | {:missed, [String.t()]}
  def verdict(%{missed: [_ | _] = missed}), do: {:missed, missed}
  def verdict(%{unknown: [_ | _]}), do: :unconfirmed
  # Nada foi visto porque não havia o que ver: continua sendo o meio honesto —
  # quem ia fazer algo irreversível não ganhou luz verde nenhuma.
  def verdict(%{off_bar: [_ | _]}), do: :unconfirmed
  def verdict(%{refilled: [_ | _]}), do: :unconfirmed
  def verdict(%{}), do: :confirmed
end
