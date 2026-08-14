defmodule Pokex.RigDouble do
  @moduledoc """
  Defaults for a test-local `Pokex.Rig` double.

  `Pokex.Rig` has 15 callbacks. A double that only cares about `press/1` still
  declared the whole behaviour, and the seven callbacks it never drove printed
  one warning each — 35 warnings across five doubles, 245 lines of every
  `mix test` (measured 2026-08-14). The doubles were not wrong; they had nowhere
  to inherit a no-op from.

  Every callback here is `defoverridable`, so a double `use`s this and defines
  only what its test actually exercises. The defaults answer as if nothing
  happened: no keys seen, no clicks counted, a screenshot path that exists only
  as a name.
  """

  defmacro __using__(_opts) do
    quote do
      @behaviour Pokex.Rig

      @impl true
      def press(_combo), do: :ok

      @impl true
      def press_many(_combos, _opts), do: :ok

      @impl true
      def key_down(_key), do: :ok

      @impl true
      def key_up(_key), do: :ok

      @impl true
      def hold_latency_ms, do: 0

      @impl true
      def click(_button, _point), do: :ok

      @impl true
      def move(_point), do: :ok

      @impl true
      def tap(_combo), do: :ok

      @impl true
      def focus_click(_point), do: :ok

      @impl true
      def capture_sequence(_point), do: :ok

      @impl true
      def capture(_region, filename), do: {:ok, filename}

      @impl true
      def capture_screen, do: {:ok, "screen.png"}

      @impl true
      def cursor_position, do: {:ok, {500, 500}}

      @impl true
      def middle_watch, do: {:ok, %{count: 0, point: {0, 0}, at: 0}}

      @impl true
      def key_watch(_codes), do: {:ok, []}

      defoverridable press: 1,
                     press_many: 2,
                     key_down: 1,
                     key_up: 1,
                     hold_latency_ms: 0,
                     click: 2,
                     move: 1,
                     tap: 1,
                     focus_click: 1,
                     capture_sequence: 1,
                     capture: 2,
                     capture_screen: 0,
                     cursor_position: 0,
                     middle_watch: 0,
                     key_watch: 1
    end
  end
end
