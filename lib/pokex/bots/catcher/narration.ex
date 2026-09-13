defmodule Pokex.Bots.Catcher.Narration do
  @moduledoc """
  As frases da captura, num lugar só.

  Tudo aqui é PURO: recebe o que já foi medido e devolve texto. Quem transmite
  é o worker (`log/2`), que é o dono do tópico — assim uma frase pode ser
  testada sem subir GenServer nenhum, e mudar uma palavra do diário não passa
  perto da lógica da bola.

  As frases são o que ELE lê na manhã seguinte. Os testes do worker afirmam
  várias delas letra por letra; mudar uma é mudar o que o diário promete.
  """

  alias Pokex.Bots.Catcher.Balls
  alias Pokex.Bots.Catcher.Logic

  @doc """
  A hora da bola: o que a varredura achou no chão.

  A CHAMADA DIZ O QUE ACHOU. "Não vi log, nada a respeito" (11/09) era metade
  da queixa: com o portão fechado a varredura devolvia `nil` e o worker engolia,
  então uma captura que nunca começou e uma que não achou corpo eram a mesma
  tela em branco.

  `nil` quando a leitura não diz nada. `:debug` pra rodada que fecha sem corpo
  (é a regra, não a notícia) e `:macro` pro momento que ele procura no diário.
  """
  @spec cue(map | nil) :: {:macro | :debug, String.t()} | nil
  def cue(nil),
    do: {:debug, "🎯 hora da bola — mas a varredura está fechada agora (luta, modo ou mini-game)"}

  def cue(%{corpses: []}),
    do: {:debug, "🎯 hora da bola — varri e não achei corpo nenhum no chão"}

  def cue(%{corpses: corpses} = obs) do
    case {length(corpses), length(Logic.admissible(obs))} do
      {n, n} ->
        {:macro, "🎯 hora da bola — #{n} corpo(s) no chão"}

      {n, 0} ->
        {:macro,
         "🎯 hora da bola — #{n} mancha(s) com cor de corpo, nenhuma onde o olho viu um bicho de pé: nenhuma bola"}

      {n, k} ->
        {:macro,
         "🎯 hora da bola — #{k} corpo(s) onde um bicho estava de pé (#{n - k} mancha(s) longe da luta, sem bola)"}
    end
  end

  def cue(_sem_leitura), do: nil

  @doc """
  Uma varredura vira UMA linha.

  Antes, os três desfechos — não varri, varri e não achei, varri e achei —
  davam o mesmo silêncio por horas (30/07). A nota do melhor candidato vai
  junto mesmo REPROVADO: a distância até o limiar é o diagnóstico da mira.
  """
  @spec scan(map | nil) :: {:macro | :debug, String.t()} | nil
  def scan(nil), do: nil

  # cegueira é rara e tem que sobreviver a restart → :macro (vai pro JSONL)
  def scan(%{scanning?: false} = obs),
    do: {:macro, "🔎 cego: #{reason_text(Map.get(obs, :reason))}"}

  # rotina em :debug — vive no diário da tela, não incha o histórico em disco
  def scan(%{windows: windows} = obs),
    do: {:debug, "🔎 varri #{windows} janelas#{frame_text(obs)} · " <> best_text(obs)}

  def scan(_sem_leitura), do: nil

  @doc "A queda tem voz: é a linha que ele procura no diário quando a bola não saiu."
  @spec falls([map]) :: [String.t()]
  def falls(anchors) do
    for %{name: name, screen: {x, y}} <- anchors,
        do: "🎯 #{name} caiu em #{x},#{y} — a barra sumiu; a bola vai lá na hora da bola"
  end

  @doc "A bola indo na âncora de um corpo que o rastro guardou."
  @spec anchor_ball(map, integer) :: String.t()
  def anchor_ball(%{name: name, point: {x, y}, fallen_at: fell}, at),
    do: "🌟 bola na âncora do #{name} em #{x},#{y} — caiu há #{div(at - fell, 1000)}s"

  @doc "Quem é o corpo que a bola vai levar."
  @spec recognized(map) :: String.t()
  # Dois caminhos chegam aqui e cada um sabe uma coisa diferente: a foto do
  # corpo sabe QUANTO se parece com a sprite ensinada, a cor sabe QUANTOS
  # pixels da cor achou. Um número só pros dois mentia num deles.
  def recognized(%{name: name, score: score}) when is_number(score),
    do: "🎯 #{name} reconhecido (#{trunc(score * 100)}%)"

  def recognized(%{name: name, px: px}) when is_integer(px),
    do: "🎯 #{name} reconhecido pela cor (#{px} px)"

  def recognized(%{name: name}), do: "🎯 #{name} reconhecido"

  @doc """
  Por que a bola da âncora NÃO saiu.

  Às 17:26:00 de 11/09 duas âncoras foram anunciadas e nenhuma bola saiu, sem
  uma linha dizendo por quê; às 19:51:19 o corpo estava no chão, ele parado do
  lado, e a linha que apareceu foi esta.
  """
  @spec no_ball(map, Logic.t() | nil, atom | String.t()) :: String.t()
  def no_ball(obs, %Logic{} = logic, :logic) do
    "a lógica recusou #{length(obs.corpses)} âncora(s): fila #{length(logic.queue)}, " <>
      "ignorados #{map_size(logic.ignored)}, esta observação #{obs.captured_at}, " <>
      "a última que ela viu #{inspect(logic.last_obs_at)}"
  end

  def no_ball(_obs, _logic, text) when is_binary(text), do: text

  @doc """
  A bola de regra tem nome; a comum é o caso silencioso.

  Dizer "Poké Ball" em todo arremesso enterraria a única linha que importa: a
  bola boa saindo pro bicho que ele está mesmo caçando.
  """
  @spec special_ball(atom | String.t(), String.t()) :: {:macro, String.t()} | nil
  def special_ball(key, name) do
    if key != Balls.default_key(),
      do: {:macro, "🔴 #{Balls.label(key)} (#{key}) para #{name}"}
  end

  @doc """
  Por que a captura está parada, na ordem em que ele quer saber.

  Recebe o que o worker já mediu — este módulo não lê portão nenhum. As
  leituras (`Settings`, o quadro-negro) são as MESMAS que `standing?/0` e
  `scan_obs/1` fazem no worker, e uma segunda cópia delas aqui seria o defeito
  que a Task 4 tirou: duas contas da mesma verdade.
  """
  @spec hold_reason(map) :: String.t() | nil
  def hold_reason(facts) do
    cond do
      facts.mini_game? -> "mini-game em jogo"
      reason = hunt_hold(facts) -> reason
      facts.fight? -> "esperando fim da luta"
      # O portão que ficou fechado um dia inteiro sem dizer o nome (30/07:
      # 1015 mortes, 1015 saques, zero varreduras — a chave era `false` e a
      # única pista era a pílula "só saque"). O motivo agora encabeça a lista
      # em vez de passar por estado normal.
      not facts.capture_enabled? -> "captura DESLIGADA — só saque"
      true -> nil
    end
  end

  @doc """
  A CAÇADA ANDANDO NÃO VARRE — mas a caçada PARADA varre.

  O detector é de mancha que não se move, e um personagem andando move tudo;
  com a estrada segurada pelo cérebro ele está parado de verdade. Isto dizia
  "na caçada só o shiny leva bola", que era verdade enquanto o portão exigia o
  modo Parado — e era a única pista de que a captura nunca rodava numa caçada.
  Parado ainda não basta: com bicho vivo na lista a bola espera.
  """
  @spec hunt_hold(map) :: String.t() | nil
  def hunt_hold(%{still?: true}), do: nil
  def hunt_hold(%{road_held?: false}), do: "andando — a bola sai quando a rota parar"
  def hunt_hold(%{screen_clear?: false}), do: "bicho vivo na tela — a bola espera a lista zerar"
  def hunt_hold(_livre), do: nil

  @doc """
  Por que a bola da ÂNCORA não saiu na queda — e qual dos portões a recusou.

  A linha era uma só, "a âncora caiu com a estrada andando", e ela mentia na
  maioria das vezes: `standing?/0` são TRÊS perguntas e a frase acusava sempre a
  primeira. Em 12/09 ele descreveu o sintoma ("ele não está nem tentando lançar
  a Pokébola nesses cenários") justamente no cenário em que o shiny cai com
  sobrevivente em pé — que é o portão da TELA, não o da estrada. Dez adiamentos
  em três horas, e o diário não sabia dizer de qual se tratava.

  A mesma trinca do `hunt_hold/1`, dita na hora da queda: o portão que recusou é
  o que precisa mudar pra bola sair.
  """
  @spec anchor_hold(map) :: String.t()
  def anchor_hold(%{road_held?: false, screen_clear?: false}),
    do:
      "🌟 a âncora caiu com a estrada andando E bicho vivo na tela — " <>
        "a bola fica pra hora da bola"

  def anchor_hold(%{road_held?: false}),
    do: "🌟 a âncora caiu com a estrada andando — a bola fica pra hora da bola"

  def anchor_hold(%{screen_clear?: false, enemies: n}) when is_integer(n),
    do:
      "🌟 a âncora caiu com #{n} bicho(s) vivo(s) na tela (a estrada estava parada) — " <>
        "a bola fica pra hora da bola"

  def anchor_hold(%{screen_clear?: false}),
    do:
      "🌟 a âncora caiu sem leitura da tela (a estrada estava parada) — " <>
        "a bola fica pra hora da bola"

  def anchor_hold(_outro), do: "🌟 a âncora caiu e a bola não pôde sair — fica pra hora da bola"

  @doc """
  O acervo É a mira — começar com o acervo vazio é mirar em NADA a sessão
  inteira, o que merece sirene, não silêncio.
  """
  @spec capture_off() :: String.t()
  def capture_off,
    do:
      "🔒 captura DESLIGADA (só saque) — ligue o botão Captura no painel; " <>
        "nenhuma Pokébola será arremessada"

  @doc "Quantos pokémon o acervo ensinou — `{:alarm | :log, frase}`."
  @spec corpse_library(non_neg_integer) :: {:alarm | :log, String.t()}
  def corpse_library(0),
    do:
      {:alarm,
       "🎯 acervo de corpos VAZIO — a captura não vai mirar nada; fotografe corpos na calibração"}

  # "N pokémon ensinados", não "N corpos" — "acervo com 10 corpos" foi lido
  # como "10 corpos na tela agora" (30/07).
  def corpse_library(n),
    do: {:log, "🎯 mira pronta — #{n} pokémon ensinado(s) no acervo da calibração"}

  defp frame_text(%{region: {_x, _y, w, h}}), do: " (#{w}×#{h})"
  defp frame_text(_no_region), do: ""

  defp best_text(%{best: nil}), do: "acervo vazio"

  defp best_text(%{best: %{name: name, score: score, point: {x, y}}, threshold: threshold}) do
    verdict = if score >= threshold, do: "✓", else: "✗"
    "melhor: #{name} #{fmt(score)} #{verdict} em #{x},#{y} (limiar #{fmt(threshold)})"
  end

  defp best_text(_no_field), do: "sem leitura"

  defp fmt(n) when is_number(n), do: :erlang.float_to_binary(n / 1, decimals: 2)
  defp fmt(_outro), do: "?"

  @doc "Por que a varredura não enxergou — o motivo cru do detector, em português."
  @spec reason_text(term) :: String.t()
  def reason_text(:no_calibration), do: "sem calibração"
  def reason_text(:no_anchor), do: "sem personagem nem ponto do pokémon calibrados"
  def reason_text(:no_arena), do: "sem arena calibrada"
  def reason_text(:no_screen), do: "a calibração não tem as medidas da tela"

  def reason_text(:outside_arena),
    do: "os tiles ao redor do personagem caem FORA da arena calibrada — recalibre a arena"

  def reason_text({:capture_failed, reason}), do: "captura falhou (#{inspect(reason)})"
  def reason_text(outro), do: inspect(outro)
end
