defmodule Pokex.Bots.Catcher.ShinyAim do
  @moduledoc """
  The aim for a SHINY's corpse, by the same colour that found it alive.

  `SpotScan` aims at taught corpses from the ground around a STANDING character; in a hunt
  nothing is taught for the cave and the character walks. The shiny is the exception that
  pays: the guard (`ShinyGuard`) already knows its palette, and the corpse is the same sprite
  lying down. So the aim is one fresh frame of the guard's square, the proven colour rules on
  it, and one question per blob — is there a living body on it?

  Two things answer that, and the second exists because the first was caught lying.

  **Nobody alive on the screen.** "Quando tá vivo temos que matar e quando tá morto temos que
  capturar" (09/09). While the brain still counts enemies, a ball is either wasted on a live
  creature or thrown instead of the fight that should be killing it — so the aim hands nothing
  over until the battle list is EMPTY. It is the shiny's own colour that turns `heavy?` on and
  makes the hunt kill it first; this is the other half of the same rule.

  **No body within a tile of the blob**, from the eye's `:crowd` reading. It is a second fence,
  not the first one, because it can be blind: measured on his own frame of 09/09, the black
  shiny standing in the lava had NO health bar for the eye to find — zero marks in the whole
  square — so on its own this test would have called a live creature a corpse.

  No reading at all, from either channel, means "cannot tell", which here is "not a corpse": a
  ball is dearer than a scan. The worker also asks for TWO consecutive sightings (`steady/3`),
  the same discipline the guard uses to confirm the living shiny.

  The observation speaks `Catcher.Logic`'s contract (`corpses`, `known`, `captured_at`) plus
  `source: :shiny_aim`, the tag that lets the worker open the mode and fight gates for it.
  Points are SCREEN points; `in_frame` keeps the frame pixel for evidence.
  """

  alias Pokex.Bots.Capture
  alias Pokex.Bots.Catcher.CorpseLibrary
  alias Pokex.Bots.Catcher.SpotScan
  alias Pokex.Bots.ShinyGuard
  alias Pokex.Calibration
  alias Pokex.Perception.WorldState
  alias Pokex.Settings
  alias Pokex.Vision.{ColorMark, ColorRules, Frame, SpriteLibrary}

  # the eye walks at 1 s; its own `crowd_fact_max_age_ms` (600) is a fight cadence
  @crowd_max_age_ms 1_500
  # o quadro do cérebro: ele tica a cada 200ms, e é ele que já desconta a linha
  # do PRÓPRIO pokémon da contagem (a lista crua inclui ela)
  @situation_max_age_ms 2_000

  @type candidate :: %{
          name: String.t(),
          px: non_neg_integer,
          point: {integer, integer},
          in_frame: {integer, integer}
        }

  @doc """
  One fresh look: the guard's square, the armed rules, the eye's latest reading.
  `opts[:capture]` and `opts[:crowd]` are the test seams; nil obs means nothing to say.
  """
  @spec scan(keyword) :: map | nil
  def scan(opts \\ []) do
    capture = Keyword.get(opts, :capture, &Capture.frame/2)
    now = System.monotonic_time(:millisecond)

    with :ok <- screen_clear(Keyword.get(opts, :enemies, :ask), now),
         {:ok, calib} <- Calibration.load(),
         {:ok, {_x, _y, _w, _h} = region} <- SpotScan.region(calib),
         {:ok, %Frame{} = frame} <- capture.(region, "shiny_aim.raw") do
      forbidden = ShinyGuard.forbidden_boxes(calib, frame, region)
      crowd = Keyword.get_lazy(opts, :crowd, fn -> crowd(now) end)
      tile = Calibration.tile_px(calib)

      {candidates, diag} = judge_told(frame, region, ColorRules.armed(), forbidden, crowd, tile)
      obs(candidates, region, now, diag)
    else
      {:blocked, reason} -> %{scanning?: false, source: :shiny_aim, reason: reason}
      {:error, reason} -> %{scanning?: false, source: :shiny_aim, reason: reason}
      _blind -> %{scanning?: false, source: :shiny_aim, reason: :capture_failed}
    end
  end

  @doc """
  NADA VIVO NA TELA. `:ok`, or `{:blocked, reason}` while the brain still counts
  an enemy.

  A contagem é a do CÉREBRO (`:situation`), não a da lista crua: a lista inclui
  a linha do próprio pokémon dele, e cobrar zero dela seria nunca jogar bola
  nenhuma. Quadro velho ou ausente é "não sei", e não saber aqui é não jogar.
  Vale pra toda bola da caçada, não só pra do shiny: a varredura comum também
  confunde bicho de pé com corpo.
  """
  def screen_clear(:ask, now) do
    case WorldState.get(:situation, @situation_max_age_ms, now) do
      {:ok, %{enemies: 0}} -> :ok
      {:ok, %{enemies: n}} when is_integer(n) -> {:blocked, {:alive_on_screen, n}}
      _stale_or_missing -> {:blocked, :no_picture}
    end
  end

  def screen_clear(0, _now), do: :ok
  def screen_clear(n, _now) when is_integer(n), do: {:blocked, {:alive_on_screen, n}}

  @doc """
  The largest blob of each rule, at or above the rule's floor, with NO body within `tile_px`
  of it. `crowd` is the eye's reading (`%{read?: true, hostiles: [%{point}], pet: %{point} | nil}`);
  nil or unread → nothing is a corpse.
  """
  @spec judge(Frame.t(), tuple, list, list, map | nil, pos_integer) :: [candidate]
  def judge(%Frame{} = frame, region, rules, forbidden, crowd, tile_px),
    do: frame |> judge_told(region, rules, forbidden, crowd, tile_px) |> elem(0)

  @doc """
  `judge/6` plus the TALLY of what it threw away: `{candidates, diag}`.

  A look that found nothing said nothing — "acabei de matar um shiny e não vi
  nada" (11/09 09:13): the corpse was on screen with ZERO pixels of the taught
  tone, and the diary had no way of telling that apart from a held look, a
  vetoed corpse, or a blob under a live body. The tally is the difference:
  `biggest_px` is the largest blob of any rule BEFORE the trigger, `above` how
  many passed it, and the rest where each of those went.
  """
  @spec judge_told(Frame.t(), tuple, list, list, map | nil, pos_integer) :: {[candidate], map}
  def judge_told(%Frame{} = frame, region, rules, forbidden, crowd, tile_px) do
    case bodies(crowd) do
      :unknown ->
        {[], %{blind: :no_crowd}}

      bodies ->
        # A LISTA NEGRA, resolvida uma vez pra varredura inteira.
        recusados = CorpseLibrary.aimed()
        piso = Settings.get(:corpse_match_min_similarity)

        {picked, diags} =
          rules
          |> Enum.map(&judge_rule(&1, frame, region, forbidden, tile_px, recusados, piso))
          |> Enum.unzip()

        {kept, bodied} =
          picked
          |> List.flatten()
          |> Enum.split_with(fn cand ->
            not Enum.any?(bodies, &within?(&1, cand.point, tile_px))
          end)

        diag =
          diags
          |> Enum.reduce(%{biggest_px: 0, above: 0, oversized: 0, refused: 0}, fn d, acc ->
            %{
              biggest_px: max(acc.biggest_px, d.biggest_px),
              above: acc.above + d.above,
              oversized: acc.oversized + d.oversized,
              refused: acc.refused + d.refused
            }
          end)
          |> Map.put(:bodied, length(bodied))
          |> Map.put(:trigger, rules |> Enum.map(& &1.min_px) |> Enum.min(fn -> 0 end))

        {kept, diag}
    end
  end

  defp judge_rule(rule, frame, region, forbidden, tile_px, recusados, piso) do
    result =
      ColorMark.scan(frame, rule.specs,
        min_cell_px: rule.min_cell_px,
        # …mais o HUD que a prova do chão aprendeu (uma banda escura vê o
        # próprio cliente, e ele é mais alto que qualquer criatura)
        forbidden: forbidden ++ Map.get(rule, :forbidden, []),
        # os pedaços de um corpo são um corpo: uma bola por bicho, não
        # uma por placa do casco
        merge_px: round(tile_px * frame.scale),
        merge_min_px: div(rule.min_px, 4)
      )

    # TODA MANCHA ACIMA DO GATILHO, não só a maior. Com a lava em 40.000 px
    # e o bicho em 9.000, as duas passam do gatilho mas só a lava era
    # olhada: o shiny ao lado não ficava "abaixo do limiar", ficava sem ser
    # olhado. O teto existe porque aqui cada alvo vira uma bola.
    # …E NENHUMA MAIOR QUE UM BICHO. O corte por tamanho vinha DEPOIS do
    # teto de candidatos, então um aglomerado de cenário de dez tiles não
    # só levava bola: ele ocupava as vagas e EXPULSAVA o bicho da lista.
    # Recusar antes do teto é o que promove o shiny pras vagas livres.
    above = Enum.filter(result.manchas, &(&1.px >= rule.min_px))
    {sized, oversized} = Enum.split_with(above, &creature_sized?(&1.box, tile_px, frame.scale))
    {kept, refused} = Enum.split_with(sized, &(not refused?(&1, rule, frame, recusados, piso)))

    picked =
      kept
      |> Enum.take(Settings.get(:shiny_aim_max_candidates))
      |> Enum.map(&on_screen(&1, rule, region, frame.scale))

    biggest = result.manchas |> Enum.map(& &1.px) |> Enum.max(fn -> 0 end)

    {picked,
     %{
       biggest_px: biggest,
       above: length(above),
       oversized: length(oversized),
       refused: length(refused)
     }}
  end

  @doc "Candidates already seen on the previous scan, within `tolerance` px: two photos, not one."
  @spec steady([candidate], [candidate], non_neg_integer) :: [candidate]
  def steady(candidates, prev, tolerance),
    do:
      Enum.filter(candidates, fn c -> Enum.any?(prev, &within?(&1.point, c.point, tolerance)) end)

  @doc "The Logic's observation for these candidates (`diag` is `judge_told/6`'s tally)."
  def obs(candidates, region, at, diag \\ %{}) do
    %{
      scanning?: true,
      source: :shiny_aim,
      diag: diag,
      corpses: Enum.map(candidates, & &1.point),
      # `score` É SEMELHANÇA, DE 0 A 1. Aqui não há semelhança nenhuma: o que
      # existe é a contagem de pixels da cor na mancha. Postos no mesmo campo,
      # os 1,2 milhão de pixels da mancha dele viravam "reconhecido (120000000%)"
      # no registro da captura.
      known: Map.new(candidates, &{&1.point, %{name: &1.name, px: &1.px}}),
      candidates: candidates,
      region: region,
      captured_at: at
    }
  end

  # QUALQUER CORPO VIVO, e o renascido é um deles. Magenta quer dizer que o bicho
  # não vem atrás dele, não que o bicho não está lá: o cliente não o põe na lista
  # de batalha e o olho o separa dos hostis, de modo que ele era invisível aqui —
  # e a bola voava num pokémon vivo. Pior: gastas as bolas, o ponto entrava em
  # `ignored` com o nome dele por 45 s, e o corpo de verdade daquele bicho, no
  # mesmo tile, era vetado depois.
  defp bodies(%{read?: true} = crowd) do
    vivos =
      crowd
      |> Map.get(:hostiles, [])
      |> Enum.map(& &1.point)
      |> Enum.concat(Map.get(crowd, :passive_points, []))

    case Map.get(crowd, :pet) do
      %{point: point} -> [point | vivos]
      _no_pet -> vivos
    end
  end

  defp bodies(_nil_or_unread), do: :unknown

  # O CORPO QUE ELE NÃO QUER. O veto por corpo já existia — desligar uma entrada
  # do acervo põe `aimed?: false` — mas só era lido na varredura por sprite, e
  # durante a caçada quem joga bola é ESTE caminho, que nunca consultou o acervo.
  # Um corpo cadastrado e desligado levava bola do mesmo jeito. A recusa vem
  # ANTES do teto de candidatos, senão ela só economiza bola em vez de abrir vaga
  # pro bicho.
  #
  # …EXCEPT THE CREATURE THE RULE IS FOR. Switching a corpse entry off is how he
  # takes its 65 px photos out of the sprite scan (the "Shiny Golem" ones fire
  # at 60 % on the Tracker HUD); it is not a way of saying he does not want the
  # Shiny Golem — the colour rule he proved under the same name says he does.
  # Measured on his pile photo of 11/09: those photos score 0.97 on the real
  # corpse, so switched off they would refuse the very ball the rule exists for.
  defp refused?(%{point: {fx, fy}}, rule, frame, lib, piso) do
    box = Settings.get(:corpse_sprite_box_px)
    meia = div(box, 2)

    case SpriteLibrary.best_in(lib, frame, {fx - meia, fy - meia, box, box}) do
      %{aimed?: false, name: name, score: score} ->
        score >= piso and not same_creature?(name, rule)

      _sem_veto ->
        false
    end
  end

  defp same_creature?(name, %{name: rule_name}), do: fold(name) == fold(rule_name)
  defp fold(name), do: name |> String.trim() |> String.downcase()

  # Um bicho ocupa da ordem de um tile; o corpo do Charizard preto dele "passa do
  # tile". Três tiles de lado é folga de sobra, e o chão da caverna inteiro não
  # cabe nisso.
  @max_creature_tiles_side 3

  defp creature_sized?({l, t, r, b}, tile_px, scale) do
    lado = round(tile_px * scale) * @max_creature_tiles_side
    r - l + 1 <= lado and b - t + 1 <= lado
  end

  defp within?({ax, ay}, {bx, by}, tolerance),
    do: abs(ax - bx) <= tolerance and abs(ay - by) <= tolerance

  # A BOLA VAI NO CENTRO DO CORPO, não no centro de massa dos pixels casados.
  # `point` da mancha é o centro de MASSA: se só parte da sprite casa a cor — a
  # sombra de um lado, a crista de cima — a massa puxa o alvo pra esse pedaço e a
  # bola cai fora do bicho. O centro da CAIXA é o meio da arte casada, que é o
  # mesmo critério que a varredura por sprite já usa (`SpotScan` mira no centro
  # da janela que casou). Eram dois critérios diferentes pro mesmo gesto.
  defp on_screen(%{point: {fx, fy}, px: px, box: {l, t, r, b}}, rule, region, scale) do
    meio = {div(l + r, 2), div(t + b, 2)}

    %{
      name: rule.name,
      px: px,
      point: Calibration.frame_to_screen(scale, region, meio),
      in_frame: meio,
      # o centro de massa fica pro diagnóstico: quando os dois discordam muito, a
      # cor está casando um pedaço só da sprite
      massa: {fx, fy}
    }
  end

  defp crowd(now) do
    case WorldState.get(:crowd, @crowd_max_age_ms, now) do
      {:ok, reading} -> reading
      _stale_or_missing -> nil
    end
  end
end
