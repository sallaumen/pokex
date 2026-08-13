defmodule PokexWeb.OtherPokexStripTest do
  @moduledoc """
  The strip that says another Pokex is running on this Mac.

  It has to be honest about what it is: a WARNING, not a guard. Nothing is blocked, so the text
  must not imply that one of the windows is safe — both obey the mouse.
  """
  use PokexWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias PokexWeb.Layouts

  defp strip(assigns), do: render_component(&Layouts.other_pokex_strip/1, assigns)

  test "the only Pokex on the machine sees no strip at all" do
    assert strip(others: [], first?: true) =~ ~r/\A\s*\z/
  end

  test "a second window is told it also acts, and which one was already running" do
    html = strip(others: [%{os_pid: 431, port: 4004, started_at: 1}], first?: false)

    assert html =~ "Tem outro Pokex rodando"
    assert html =~ "431"
    assert html =~ "4004"
    # the danger is the shared mouse, so the corner has to be named
    assert html =~ "canto de comando"
    # and it must NOT promise any protection
    refute html =~ "só leitura"
    refute html =~ "bloquead"
  end

  test "the window that was running FIRST is warned too — neither is protected" do
    html = strip(others: [%{os_pid: 999, port: 4013, started_at: 9}], first?: true)

    assert html =~ "Tem outro Pokex rodando"
    assert html =~ "4013"
  end

  test "more than one neighbour is named, not counted" do
    html =
      strip(
        others: [
          %{os_pid: 1, port: 4004, started_at: 1},
          %{os_pid: 2, port: 4013, started_at: 2}
        ],
        first?: true
      )

    assert html =~ "4004"
    assert html =~ "4013"
  end
end
