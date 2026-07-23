defmodule PokexWeb.PositionReadout do
  @moduledoc """
  A posição do personagem contada honestamente — a MESMA leitura no painel, na
  /world e no /cavebot.

  Um "?" mudo escondia a única pergunta que importa quando o bot não anda: eu
  não estou lendo o minimapa, ou estou lendo e você está mesmo aí? As duas
  causas ficavam idênticas na tela e têm consertos opostos (janela do navegador
  cobrindo o minimapa × HUD perdido × glifo duvidoso numa leitura só).

  A idade vem do carimbo do fato `:minimap` no `WorldState`, e NÃO do
  `pos_age_ms` do snapshot do cavebot, de propósito: o fato existe com a caçada
  desligada (e a /world nem conhece o cavebot), então uma fonte só responde
  igual nas três páginas. O `pos_age_ms` do cavebot continua sendo dele — lá
  ele responde "há quanto tempo a LOGIC não vê posição", que é outra coisa.
  """

  alias Pokex.World

  @doc """
  Em que pé está a leitura da coordenada:

    * `:ok` — lida (fato fresco, com posição)
    * `:illegible` — o minimapa ESTÁ sendo lido agora, mas a coordenada saiu
      ilegível: `Glyphs.read_coord/2` é tudo-ou-nada, então um glifo duvidoso
      derruba a coordenada inteira
    * `:stale` — parou de chegar leitura (feed parado, ou ninguém atachado)
    * `:never` — nada foi publicado ainda
  """
  @spec status({integer, integer, integer} | nil, non_neg_integer | nil) ::
          :ok | :illegible | :stale | :never
  def status(pos, age_ms)
  def status({_x, _y, _z}, _age_ms), do: :ok

  def status(nil, age_ms) when is_integer(age_ms) do
    if age_ms <= World.max_age_ms(), do: :illegible, else: :stale
  end

  def status(nil, _never), do: :never

  @doc "A coordenada em si — travessão, nunca \"?\", quando não há o que mostrar."
  @spec coords({integer, integer, integer} | nil) :: String.t()
  def coords(nil), do: "—"
  def coords({x, y, z}), do: "#{x}, #{y} · andar #{z}"

  @doc """
  A frase que acompanha a coordenada. É ela que distingue "não estou lendo" de
  "estou lendo, você está aí" — o resto da tela só mostra o número.
  """
  @spec note({integer, integer, integer} | nil, non_neg_integer | nil) :: String.t()
  def note(pos, age_ms) do
    case status(pos, age_ms) do
      :ok ->
        "lendo tua posição · #{age_text(age_ms)}"

      :illegible ->
        "estou lendo o minimapa, mas a coordenada saiu ilegível"

      :stale ->
        "NÃO estou lendo tua posição — última leitura #{age_text(age_ms)}"

      :never ->
        "ainda não li tua posição"
    end
  end

  @doc "Cor do estado da leitura, nos tokens do painel."
  @spec note_class({integer, integer, integer} | nil, non_neg_integer | nil) :: String.t()
  def note_class(pos, age_ms) do
    case status(pos, age_ms) do
      :ok -> "text-pk-text-3"
      :illegible -> "text-pk-warn"
      :stale -> "text-pk-danger"
      :never -> "text-pk-text-3"
    end
  end

  @doc "Idade em palavras. Ages vêm de relógio monotônico, então nunca são datas."
  @spec age_text(integer | nil) :: String.t()
  def age_text(nil), do: "—"
  def age_text(ms) when ms < 1_000, do: "agora"
  def age_text(ms) when ms < 60_000, do: "há #{div(ms, 1000)}s"
  def age_text(ms) when ms < 3_600_000, do: "há #{div(ms, 60_000)}min"
  def age_text(_ms), do: "há 1h+"

  @doc """
  Quanto da coordenada está saindo legível. A leitura é tudo-ou-nada, então uma
  falha aqui e ali é normal; o que importa é a PROPORÇÃO — se quase tudo falha,
  o bot anda às cegas (e o /cavebot grava uma rota cheia de buracos).
  """
  @spec read_health(non_neg_integer, non_neg_integer) :: String.t()
  def read_health(0, 0), do: "aguardando a primeira leitura…"

  def read_health(reads, misses) do
    pct = round(reads * 100 / (reads + misses))

    cond do
      pct >= 80 -> "leitura boa — #{pct}% (#{reads} ok, #{misses} falhas)"
      pct >= 40 -> "leitura instável — #{pct}% (#{reads} ok, #{misses} falhas)"
      true -> "leitura ruim — #{pct}% (#{reads} ok, #{misses} falhas)"
    end
  end
end
