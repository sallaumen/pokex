defmodule PokexWeb.CalibrationSteps do
  @moduledoc """
  The calibration wizard as DATA: what each step asks for, which steps draw the
  screenshot, and where a step sits in the numbered run.

  It left the LiveView because the LiveView was 1900 lines and this is the part
  a person actually reads and edits — the copy Lucas follows while clicking. It
  also carries a rule that has bitten before: `marking?/1` must list EVERY step
  that expects a click on the screenshot, including the standalone quick-fix
  flows. A step missing from it renders its instruction with NO picture under
  it — a black page (2026-07-20: the mini-game quick-fix steps were absent).
  Listing them here, next to the instructions, makes the omission visible.
  """

  @instructions %{
    water: "Clique no PONTO DA ÁGUA onde o bot deve arremessar.",
    battle_a: "Clique no canto SUPERIOR-ESQUERDO da área de criaturas da janela Battle.",
    battle_b:
      "Agora o canto INFERIOR-DIREITO da mesma área (incluindo a coluna do ícone de pokébola).",
    neutral: "Clique num PONTO NEUTRO seguro (sugestão: o tile do seu próprio personagem).",
    player:
      "Clique bem no CENTRO do seu PERSONAGEM — é nele que o bot ancora a barra do minigame de pesca. Fique parado onde vai pescar.",
    skill_a:
      "Canto SUPERIOR-ESQUERDO da barra de skills (bem no início do slot 1). IMPORTANTE: " <>
        "deixe TODAS as skills PRONTAS (sem cooldown) — a foto de cada ícone vira a " <>
        "referência de 'pronta' pro leitor.",
    skill_b:
      "Canto INFERIOR-DIREITO da barra, depois da última skill deste Pokémon. Não inclua outros botões.",
    hp_a:
      "Canto SUPERIOR-ESQUERDO da barra de VIDA do Pokémon principal — bem RENTE à barra, sem pegar o fundo azul acima nem os ícones abaixo.",
    hp_b: "Canto INFERIOR-DIREITO da MESMA barra de vida (colado na barra, só ela).",
    photo: "Centro da FOTO do Pokémon principal (onde o mouse fica pro Shift+Q do revive).",
    mini_game_a:
      "Canto SUPERIOR-ESQUERDO da FAIXA onde a barra do minigame aparece quando você pesca " <>
        "deste lugar (deixe uma folga de 1-2 tiles pra cada lado da barra).",
    mini_game_b:
      "Canto INFERIOR-DIREITO da mesma faixa — cubra a altura TODA da barra, sem pegar os " <>
        "painéis escuros da lateral (Battle/bolsa).",
    pokemon_spot:
      "Clique no TILE onde o seu Pokémon deve FICAR (a posição estratégica de ataque). " <>
        "Depois das lutas, o suporte manda ele de volta pra cá com um clique do meio.",
    escape_point:
      "Clique num TILE LIVRE DO CAMINHO colado na escada (NÃO na escada: clicar nela tenta " <>
        "USÁ-LA, e usar só funciona do lado). A fuga anda até esse tile e aí dá os passos " <>
        "de seta (direção configurada no painel) pra ENTRAR na escada.",
    minimap_a:
      "Canto SUPERIOR-ESQUERDO do MINIMAPA. Pode marcar o widget INTEIRO de uma vez " <>
        "(números da coordenada e barrinha do topo inclusos) — a faixa do texto eu acho " <>
        "sozinho lá dentro.",
    minimap_b: "Canto INFERIOR-DIREITO do mesmo minimapa.",
    minimap_cross:
      "Clique bem no CENTRO da CRUZ do personagem no minimapa — ela é fixa (o mapa " <>
        "desliza por baixo), então este ponto vira a origem de todo passo do cavebot.",
    minimap_coord_search:
      "A faixa da coordenada eu acho SOZINHO: dou um passinho com as setas (o jogo só " <>
        "desenha \"(x, y, z)\" quando a posição MUDA), fotografo e procuro onde consigo LER — " <>
        "é o mesmo estado em que o bot vai ler durante a caçada.",
    minimap_coord_a:
      "Canto SUPERIOR-ESQUERDO da faixa da COORDENADA — o texto \"(x, y, z)\" no topo do " <>
        "minimapa. Deixe folga pra direita: a faixa precisa caber a coordenada mais " <>
        "LONGA (ex.: \"(2782, 30571, 5)\").",
    minimap_coord_b: "Canto INFERIOR-DIREITO da mesma faixa, fechando o texto inteiro."
  }

  @doc """
  Steps that carry COPY but no clickable screenshot — they bring their own UI
  (the coord-band search hovers, photographs and reads instead of asking for
  clicks). Declared as data so the instruction⟺marking contract test can
  except exactly these and still fail loudly on a genuinely forgotten
  `marking?/1` entry (the 2026-07-20 black-page bug).
  """
  def screenless, do: [:minimap_coord_search]

  @doc "What the wizard asks at `step` (nil for a step with no copy)."
  def instruction(step), do: @instructions[step]

  @doc "Every step, with its instruction — the whole script, for tests and docs."
  def all, do: @instructions

  @doc """
  Does `step` expect a click on the screenshot?

  EVERY marking step must be here, quick-fix flows included — a missing one
  renders its instruction over a black page.
  """
  def marking?(step),
    do:
      step in [
        :water,
        :battle_a,
        :battle_b,
        :neutral,
        :player,
        :skill_a,
        :skill_b,
        :hp_a,
        :hp_b,
        :photo,
        :mini_game_a,
        :mini_game_b,
        :minimap_a,
        :minimap_b,
        :minimap_cross,
        :minimap_coord_a,
        :minimap_coord_b,
        :pokemon_spot,
        :escape_point
      ]

  def index(:water), do: 1
  def index(:battle_a), do: 2
  def index(:battle_b), do: 3
  def index(:neutral), do: 4
  def index(:player), do: 5
  def index(:skill_a), do: 6
  def index(:skill_b), do: 7
  def index(:hp_a), do: 8
  def index(:hp_b), do: 9
  def index(:photo), do: 10
  def index(_), do: nil

  @doc "How many steps the FULL wizard has (the quick-fix flows are unnumbered)."
  def total, do: 10
end
