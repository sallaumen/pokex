defmodule Pokex.Bots.SkillRack do
  @moduledoc """
  A barra como ela está AGORA, tecla por tecla, com as duas fontes lado a lado.

  A prontidão de uma tecla tem duas testemunhas e elas nem sempre concordam: a
  TELA (a barra do jogo, lida por comparação de pixel contra uma referência da
  calibração) e o RELÓGIO (`Pokex.Bots.SkillClock`, o que o bot carimbou ter
  apertado, cruzado com o cooldown que ele escreveu no `/time`).

  Enquanto as duas moravam só dentro da decisão, uma discordância era invisível
  — e discordância é exatamente o defeito que custou a caçada de 27/08: o jogo
  escrevia `12`, `32` e `32` em cima das teclas 3, 4 e 5, a leitura respondia
  "3 e 5 prontas", e a rotação passou dezenove segundos apertando as duas. Nada
  em tela nenhuma dizia isso.

  Então este módulo não escolhe uma testemunha: ele mostra as duas, e diz qual
  delas a rotação vai obedecer. `state` é a resposta OBEDECIDA — vem do mesmo
  `SkillClock.ready/4` que o combate chama, nunca de uma segunda regra parecida
  — e `disagree?` marca a linha onde vale a pena olhar.

  Puro no que dá pra ser: recebe o `now`, lê o relógio (ETS) e devolve uma
  lista. Nenhuma captura, nenhuma decisão.
  """

  alias Pokex.Bots.SkillClock

  @type tile :: %{
          key: String.t(),
          job: String.t(),
          screen: :ready | :cooling | :unknown,
          clock: :ready | :cooling | :unknown,
          state: :ready | :cooling,
          left_ms: non_neg_integer,
          written_ms: pos_integer | nil,
          muted?: boolean,
          disagree?: boolean
        }

  @doc """
  Uma peça por tecla da barra, na ordem da barra.

  `loadout` é a visão que a página já tem (`opening`, `reserved`, `buffs`,
  `heal`, `single`, `cooldowns`); `screen` é `Pokex.Perception.ready_skills/1`
  — lista de prontas, ou `nil` quando a barra não foi lida.
  """
  @spec build(map | nil, [String.t()] | nil, integer) :: [tile]
  def build(loadout, screen, now \\ System.monotonic_time(:millisecond))

  def build(nil, _screen, _now), do: []

  def build(loadout, screen, now) do
    keys = order(loadout)
    cooldowns = Map.get(loadout, :cooldowns) || %{}
    offered = SkillClock.ready(screen, keys, cooldowns, now) || []

    Enum.map(keys, &tile(&1, loadout, screen, cooldowns, offered, now))
  end

  @doc """
  A ordem da FILEIRA, com o zero por último — que é onde ele está na barra.

  As de alvo único entram mesmo com a rotação sem elas: a barra é o que ELE
  tem, não o que o bot vai apertar, e uma tecla que some da tela é uma tecla
  que ele não sabe que existe. Quem diz que ela está fora é o `job`.
  """
  @spec order(map) :: [String.t()]
  def order(loadout) do
    [:opening, :reserved, :buffs, :single, :heal]
    |> Enum.flat_map(&(Map.get(loadout, &1) || []))
    |> Enum.uniq()
    |> Enum.sort_by(&slot_number/1)
  end

  defp slot_number("0"), do: 10

  defp slot_number(key) do
    case Integer.parse(key) do
      {n, ""} -> n
      # uma tecla que não é número (f4, shift+1) vai pro fim, em ordem estável
      _not_a_slot -> 99
    end
  end

  defp tile(key, loadout, screen, cooldowns, offered, now) do
    written = written_ms(cooldowns, key)
    cooling = SkillClock.cooling_ms(key, cooldowns, now)
    deaf = SkillClock.deaf_ms(key, cooldowns, now)
    screen_says = screen_says(key, screen)
    clock_says = clock_says(key, written, max(cooling, deaf))
    state = if key in offered, do: :ready, else: :cooling

    %{
      key: key,
      job: job_of(key, loadout),
      screen: screen_says,
      clock: clock_says,
      state: state,
      # QUANTO FALTA, e zero quer dizer "ninguém sabe" quando o estado é frio:
      # a tela pode dizer que a tecla está fria sem que exista número nenhum
      # escrito pra ela. Um contador que inventa segundos é pior que um traço.
      left_ms: if(state == :cooling, do: max(cooling, deaf), else: 0),
      written_ms: written,
      muted?: deaf > 0,
      disagree?: disagree?(screen_says, clock_says)
    }
  end

  defp written_ms(cooldowns, key) do
    case Map.get(cooldowns, key) do
      ms when is_integer(ms) and ms > 0 -> ms
      _nao_escrito -> nil
    end
  end

  defp screen_says(_key, nil), do: :unknown
  defp screen_says(key, ready), do: if(key in ready, do: :ready, else: :cooling)

  # O relógio só fala de tecla com cooldown ESCRITO ou já pega mentindo. Sem
  # isso ele não está dizendo "pronta": está dizendo que não sabe, e as duas
  # coisas não podem virar a mesma cor.
  defp clock_says(_key, nil, 0), do: :unknown
  defp clock_says(_key, _written, left) when left > 0, do: :cooling

  defp clock_says(key, _written, _zero),
    do: if(SkillClock.last_press(key), do: :ready, else: :unknown)

  defp disagree?(same, same), do: false
  defp disagree?(:unknown, _clock), do: false
  defp disagree?(_screen, :unknown), do: false
  defp disagree?(_screen, _clock), do: true

  # A ORDEM IMPORTA: `reserved` é a lista de EXCLUSÃO da rotação e junta
  # controle com escudo, então o escudo tem que ser perguntado antes — numa tela
  # de diagnóstico, chamar o escudo de controle mente sobre a coisa exata que
  # ela existe pra mostrar.
  @jobs [
    {:shield, "escudo"},
    {:reserved, "controle (guardado pro revive)"},
    {:buffs, "aura"},
    {:heal, "cura"},
    {:opening, "dano"},
    {:single, "alvo único (fora da rotação)"}
  ]

  @doc "O que essa tecla faz nesta caçada."
  @spec job_of(String.t(), map) :: String.t()
  def job_of(key, loadout) do
    Enum.find_value(@jobs, "sem trabalho", fn {field, label} ->
      key in (Map.get(loadout, field) || []) and label
    end)
  end

  @doc "Quantas estão prontas de verdade — as que a rotação pode apertar agora."
  @spec ready_count([tile]) :: non_neg_integer
  def ready_count(tiles), do: Enum.count(tiles, &(&1.state == :ready))

  @doc """
  Quanto da recuperação já passou, em 0-100, pra desenhar o trilho que enche.
  Sem número escrito não há fração — a peça mostra o estado, não uma barra
  inventada.
  """
  @spec recovered_pct(tile) :: non_neg_integer | nil
  def recovered_pct(%{state: :ready}), do: 100
  def recovered_pct(%{left_ms: 0}), do: nil

  def recovered_pct(%{left_ms: left} = tile) do
    # Uma tecla calada por mentira da barra é segurada pelo assumido quando
    # ninguém escreveu o número dela — o trilho tem que medir a mesma coisa que
    # a contagem, ou os dois contam histórias diferentes da mesma espera.
    total = tile.written_ms || (tile.muted? && SkillClock.assumed_ms())

    if total, do: round(max(total - left, 0) * 100 / total)
  end
end
