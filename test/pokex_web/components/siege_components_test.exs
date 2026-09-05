defmodule PokexWeb.SiegeComponentsTest do
  use ExUnit.Case, async: true
  import Phoenix.LiveViewTest

  import PokexWeb.SiegeComponents

  @now 100_000

  defp reading(opts \\ []) do
    %{
      read?: true,
      at: @now - Keyword.get(opts, :age_ms, 200),
      took_ms: 27,
      me: {906, 720},
      box: {0, 0, 1812, 1440},
      pet: Keyword.get(opts, :pet, %{point: {906, 1022}, dx: 0, dy: 2, tiles: 2, hp_pct: 96}),
      hostiles:
        Keyword.get(opts, :hostiles, [
          %{
            point: {1057, 1022},
            dx: 1,
            dy: 2,
            from_me: 2,
            from_pet: 1,
            hp_pct: 100,
            skull?: true
          },
          %{point: {1661, 268}, dx: 5, dy: -3, from_me: 5, from_pet: 5, hp_pct: 40, skull?: true}
        ]),
      listed: Keyword.get(opts, :listed, 3)
    }
  end

  defp card(assigns) do
    assigns =
      Map.merge(%{reading: nil, photo: nil, radius: 8, max_age_ms: 600, now_ms: @now}, assigns)

    render_component(&siege_card/1, assigns)
  end

  test "with a reading it draws him, the pet and every hostile in tiles" do
    html = card(%{reading: reading()})

    assert html =~ ~s(id="siege-card")
    assert html =~ ~s(data-me)
    assert html =~ ~s(data-pet)
    assert html =~ ~s(data-dx="1")
    assert html =~ ~s(data-dy="2")
    assert html =~ ~s(data-from-me="2")
    assert html =~ ~s(data-dx="5")
    assert html =~ ~s(data-dy="-3")
    assert html =~ "vi 2 · lista 3 · 1 sem ver"
    assert html =~ "pokémon a 2 tiles"
    assert html =~ "área com caveira"
    assert html =~ "lido há 200 ms"
  end

  test "an old reading is no eye, and it says so" do
    html = card(%{reading: reading(age_ms: 900)})

    assert html =~ "sem olho (foto de 900 ms)"
    refute html =~ ~s(data-hostile)
  end

  test "no reading yet is an empty field with words" do
    html = card(%{reading: nil})

    assert html =~ "sem olho — nenhuma leitura ainda"
    assert html =~ ~s(phx-click="crowd_scan")
  end

  test "an unreadable screen shows the reason" do
    html = card(%{reading: %{read?: false, reason: :not_calibrated}})
    assert html =~ "não deu pra olhar: o /calibrar nunca rodou nesta tela"
  end

  test "without the pet it says so and draws no pet" do
    html = card(%{reading: reading(pet: nil)})

    assert html =~ "pokémon não visto"
    refute html =~ ~s(data-pet)
  end

  test "the photo goes behind the tiles when there is one" do
    html = card(%{reading: reading(), photo: "data:image/bmp;base64,QUJD"})
    assert html =~ ~s(href="data:image/bmp;base64,QUJD")
  end

  test "a skull-less area says so" do
    hostiles = [
      %{point: {1057, 1022}, dx: 1, dy: 2, from_me: 2, from_pet: 1, hp_pct: 100, skull?: false}
    ]

    html = card(%{reading: reading(hostiles: hostiles, listed: 1)})
    assert html =~ "sem caveira"
  end
end
