defmodule PokexWeb.ReadOnlyStripTest do
  @moduledoc """
  The strip that says "esta janela não manda na máquina".

  A second server looks completely normal — its pages render, its sensing works, its header
  even shows the fleet's state. That is how the 2026-08-12 incident stayed invisible while two
  bots fought over the same mouse. The warning has to be on EVERY page, like the screen
  mismatch one, because the read-only VM is exactly the one being browsed.
  """
  use PokexWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias PokexWeb.Layouts

  defp strip(assigns), do: render_component(&Layouts.read_only_strip/1, assigns)

  test "the owner of the machine sees no strip at all" do
    assert strip(owner?: true, holder: nil) =~ ~r/\A\s*\z/
  end

  test "an observer is told it cannot act, and who to close to take over" do
    html = strip(owner?: false, holder: %{os_pid: 431, port: 4004})

    assert html =~ "Outro Pokex está no comando"
    assert html =~ "só leitura"
    assert html =~ "431"
    assert html =~ "4004"
  end

  test "an unknown holder still warns — the ban does not depend on naming who holds it" do
    html = strip(owner?: false, holder: nil)

    assert html =~ "Outro Pokex está no comando"
    assert html =~ "outro processo"
  end
end
