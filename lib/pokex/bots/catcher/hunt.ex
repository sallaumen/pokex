defmodule Pokex.Bots.Catcher.Hunt do
  @moduledoc """
  A caçada do shiny, do lado de fora do GenServer: quem é o bicho, onde ele
  caiu, e em quais âncoras a bola CABE agora.

  A IDENTIDADE VIAJA COM A BARRA (`Catcher.Trail`). O olho lê as barras a cada
  olhada; o vigia diz em cima de qual está o brilho do shiny; o rastro segue
  essa barra em tiles do MUNDO até ela sumir — e aí o lugar dela é a âncora do
  corpo, com ou sem cor. "Lembra que o pokémon anda por aí, temos que ter essa
  posição atualizada e bem certinha" (11/09).

  Este módulo NÃO joga e NÃO fala: devolve fatos — o rastro novo, as barras que
  caíram nesta olhada, e os alvos que sobraram depois das cercas. O worker é o
  dono das mãos (a bola, o corpo, o portão) e da voz (o diário).
  """

  alias Pokex.Bots.Catcher.Logic
  alias Pokex.Bots.Catcher.Trail
  alias Pokex.Bots.CrowdScan
  alias Pokex.Bots.ShinyGuard
  alias Pokex.Calibration
  alias Pokex.Perception.WorldState
  alias Pokex.Settings

  # Quanto tempo o lugar onde um bicho estava de pé continua valendo como lugar
  # de corpo. Eram 20 s, e a rodada é mais longa que isso: em 11/09 o Shiny
  # Golem morreu às 08:30:47 e a chamada que achou o corpo dele veio às
  # 08:32:51 — "nenhuma onde o olho viu um bicho de pé", porque a memória já
  # tinha esquecido a pilha. O lugar só deixa de valer quando ELE anda (a
  # memória guarda a posição do minimapa e só serve pontos vistos da mesma);
  # o tempo aqui é só pra não carregar o chão de uma caverna inteira.
  @standing_memory_ms 120_000

  @type candidate :: %{
          name: String.t(),
          px: non_neg_integer,
          point: {integer, integer},
          in_frame: {integer, integer},
          fallen_at: integer
        }

  @doc """
  Uma olhada do olho: o rastro anda, e a resposta traz as barras que caíram.

  O brilho ainda na tela diz que o shiny está VIVO: o rastro não pode virar a
  barra dele, perdida na pilha, em corpo pra jogar bola (18:34 de 11/09). A
  lista de batalha vazia (`pile_dead?`, medida pelo worker) diz o contrário —
  aí uma barra caçada que sumiu É o corpo (19:16:48).
  """
  @spec follow(map, map, boolean, integer) :: {map, [map]}
  def follow(state, reading, pile_dead?, now) do
    ref = ref(reading)
    seen = ShinyGuard.seen()

    marked =
      reading
      |> CrowdScan.mark_special(seen, ref.tile)
      |> Map.merge(%{shiny_on?: seen != [], pile_dead?: pile_dead?})

    trail = Trail.observe(state.trail, marked, ref, now)
    {%{state | trail: trail}, falls(state.trail, trail, ref, now)}
  end

  @doc """
  O brilho do vigia marca a barra embaixo dele como caçada.

  MEIO TILE, DE PROPÓSITO: o vigia aponta o CENTRO DA ARTE (a barra mais meio
  tile); o rastro guarda cada bicho pelo ponto do corpo do olho (a barra mais
  UM tile). Sem o ajuste, um brilho entre dois bichos empilhados ficava a 75 px
  do bicho de cima e a 76 px do bicho certo — e às 17:25:59 de 11/09 dois
  rastros caíram "caçados" de uma vez, um deles o vizinho.
  """
  @spec hunt(map, [map], integer) :: map
  def hunt(state, vistos, now) do
    ref = ref(%{})
    half = div(ref.tile, 2)

    trail =
      Enum.reduce(vistos, state.trail, fn %{point: {x, y}, name: name} = visto, trail ->
        Trail.hunt_at(trail, {x, y + half}, name, Map.get(visto, :px), ref, now)
      end)

    %{state | trail: trail}
  end

  @doc """
  As âncoras em que a bola cabe agora, com os candidatos que a lógica entende.

  Duas cercas, as duas medidas em campo:

    * **dentro da tela** — uma âncora é um ponto do MUNDO, e depois de uns
      passos ela projeta pra fora do monitor;
    * **nunca em cima de um bicho de pé** — a hora da bola pode chegar com um
      sobrevivente na tela, e o tile do corpo pode estar ocupado por ele.
  """
  @spec anchor_targets(map, integer) :: {[candidate], [map]}
  def anchor_targets(state, at) do
    ref = ref(%{})
    standing = Trail.standing(state.trail, ref)
    tile = ref.tile

    free? = fn %{screen: {ax, ay}} ->
      not Enum.any?(standing, fn {sx, sy} -> abs(sx - ax) <= tile and abs(sy - ay) <= tile end)
    end

    anchors =
      Enum.filter(Trail.anchors(state.trail, ref, at), &(on_screen?(&1.screen) and free?.(&1)))

    {Enum.map(anchors, &candidate/1), anchors}
  end

  @doc """
  A bola voou nestas âncoras: elas estão gastas.

  GASTA SÓ O QUE A BOLA LEVOU. Às 17:26:00 de 11/09 as duas âncoras foram
  gastas numa chamada que não virou bola, e o corpo do shiny ficou no chão.
  """
  @spec spend(map, [map]) :: map
  def spend(state, anchors),
    do: %{state | trail: Enum.reduce(anchors, state.trail, &Trail.spend(&2, &1.world))}

  @doc """
  A hora da observação da âncora, sempre MAIS NOVA que a última foto que a
  lógica julgou.

  A OBSERVAÇÃO DA ÂNCORA NÃO É UMA FOTO. A varredura da hora da bola carimba a
  foto dela no fim do trabalho, no MESMO milissegundo em que a chamada da
  âncora nasce, e o portão de frescor da lógica (`captured_at <= last_obs_at`)
  engolia a âncora em silêncio: 19:51:19 de 11/09, o corpo em 1268,768, ele
  parado do lado, "a lógica recusou 1 âncora(s)".
  """
  @spec fresher_than(Logic.t() | nil, integer) :: integer
  def fresher_than(%Logic{last_obs_at: last}, now) when is_integer(last), do: max(now, last + 1)
  def fresher_than(_logic, now), do: now

  @doc "O quadro de referência desta foto: onde ele está na tela, o tile, e o lugar no mapa."
  @spec ref(map) :: map
  def ref(reading) do
    me =
      Map.get(reading, :me) ||
        case Calibration.load() do
          {:ok, calib} -> Calibration.player_point(calib)
          _no_calibration -> nil
        end

    %{me: me || {0, 0}, tile: Calibration.tile_px(), pos: pos()}
  end

  @doc """
  ONDE ELE ESTAVA quando esta foto foi tirada.

  O juiz da captura (`Catcher.Logic.confirm/3`) pergunta se o corpo continua no
  mesmo ponto de TELA, e um passo do personagem desloca a tela inteira — sem
  esta âncora, uma caçada andando dá toda bola por capturada. Ausente (minimapa
  ilegível) o juiz simplesmente não usa: não saber onde ele está nunca vira
  "andou".
  """
  @spec pos() :: {integer, integer, integer} | nil
  def pos do
    case WorldState.get(:minimap, Settings.get(:cavebot_minimap_fact_max_age_ms), now()) do
      {:ok, %{pos: {_, _, _} = pos}} -> pos
      _sem_leitura -> nil
    end
  end

  @doc """
  ONDE OS BICHOS ESTAVAM DE PÉ, na tela desta foto.

  A varredura do acervo só admite mancha onde o olho viu um bicho — e o lugar
  só deixa de valer quando ELE anda: a memória guarda a posição do minimapa
  junto com o ponto, e serve apenas os pontos vistos da mesma posição.
  """
  @spec remember_standing(map, [map], integer) :: map
  def remember_standing(state, hostiles, now) do
    pos = pos()
    seen = Map.new(for %{point: {_, _} = point} <- hostiles, do: {{pos, point}, now})

    standing =
      state.standing
      |> Map.reject(fn {_where, seen_at} -> now - seen_at > @standing_memory_ms end)
      |> Map.merge(seen)

    %{state | standing: standing}
  end

  @doc "Os pontos dessa memória que ainda valem pra ESTA posição no mapa."
  @spec spots(map, tuple | nil, integer) :: [{integer, integer}]
  def spots(standing, pos, now) do
    for {{seen_pos, point}, seen_at} <- standing,
        now - seen_at <= @standing_memory_ms,
        seen_pos == nil or pos == nil or seen_pos == pos,
        uniq: true,
        do: point
  end

  @doc "O rastro pro painel: o shiny de pé, onde ele caiu, e quantos estão de pé."
  @spec snapshot(map, map, integer) :: map
  def snapshot(state, ref, at) do
    %{
      hunted: Trail.hunted(state.trail, ref),
      anchors: Trail.anchors(state.trail, ref, at),
      standing: length(Trail.standing(state.trail, ref))
    }
  end

  # As âncoras que nasceram NESTA olhada: as que o rastro não conhecia antes.
  defp falls(before, after_look, ref, at) do
    known = Enum.map(Trail.anchors(before, ref, at), & &1.world)

    for %{world: world} = anchor <- Trail.anchors(after_look, ref, at),
        world not in known,
        do: anchor
  end

  defp candidate(anchor) do
    %{
      name: anchor.name,
      px: anchor.px || 0,
      point: anchor.screen,
      in_frame: anchor.screen,
      fallen_at: anchor.fallen_at
    }
  end

  defp on_screen?({x, y}) do
    case Calibration.load() do
      {:ok, %{screen_w: w, screen_h: h}} when is_integer(w) and is_integer(h) ->
        x >= 0 and y >= 0 and x < w and y < h

      _unknown_screen ->
        x >= 0 and y >= 0
    end
  end

  defp now, do: System.monotonic_time(:millisecond)
end
