defmodule Pokex.Bots.Logout.LogicTest do
  use ExUnit.Case, async: true

  alias Pokex.Bots.Logout.Logic

  @config %{attempts: 3}

  # The normal case: the HUD was readable before the press, so there is a witness.
  defp start, do: Logic.start("manual", @config, :present)

  defp read_all(logic, readings) do
    Enum.reduce(readings, {logic, :verify}, fn reading, {logic, _acao} ->
      Logic.after_read(logic, reading)
    end)
  end

  test "start requests the first key press, on attempt 1" do
    {logic, action} = start()

    assert action == :press
    assert logic.state == :pressing
    assert logic.attempt == 1
    assert logic.reason == "manual"
  end

  test "a key that went out asks to verify the screen" do
    {logic, _} = start()
    {logic, action} = Logic.after_press(logic, :ok)

    assert action == :verify
    assert logic.state == :verifying
    assert logic.reads == 0
    assert logic.confirms == 0
  end

  test "two consecutive :gone reads confirm the logout" do
    {logic, _} = start()
    {logic, _} = Logic.after_press(logic, :ok)

    {logic, :verify} = Logic.after_read(logic, :gone)
    {logic, action} = Logic.after_read(logic, :gone)

    assert action == {:finish, :out}
    assert logic.state == :out
  end

  test "a :present between two :gone resets the count — no confirmation" do
    {logic, _} = start()
    {logic, _} = Logic.after_press(logic, :ok)

    {logic, _} = Logic.after_read(logic, :gone)
    {logic, _} = Logic.after_read(logic, :present)
    {logic, action} = Logic.after_read(logic, :gone)

    assert action == :verify
    assert logic.confirms == 1
    assert logic.state == :verifying
  end

  test ":unreadable never confirms, however often it repeats" do
    {logic, _} = start()
    {logic, _} = Logic.after_press(logic, :ok)

    {logic, action} = read_all(logic, List.duplicate(:unreadable, Logic.reads_per_attempt()))

    assert action == :press
    assert logic.attempt == 2
    assert logic.confirms == 0
  end

  test "exhausting the attempt's reads starts a new attempt" do
    {logic, _} = start()
    {logic, _} = Logic.after_press(logic, :ok)

    {logic, action} = read_all(logic, List.duplicate(:present, Logic.reads_per_attempt()))

    assert action == :press
    assert logic.state == :pressing
    assert logic.attempt == 2
    assert logic.reads == 0
  end

  test "exhausting the attempts ends in failure, with the reason" do
    logic =
      Enum.reduce(1..3, elem(start(), 0), fn _tentativa, logic ->
        {logic, _} = Logic.after_press(logic, :ok)
        {logic, _} = read_all(logic, List.duplicate(:present, Logic.reads_per_attempt()))
        logic
      end)

    assert logic.state == :failed
    assert logic.error == :ainda_logado
  end

  test "a key that did not go out burns the attempt and retries" do
    {logic, _} = start()
    {logic, action} = Logic.after_press(logic, {:error, :panic_corner})

    assert action == :press
    assert logic.attempt == 2
  end

  test "with a single attempt, a key that did not go out is already a failure" do
    {logic, _} = Logic.start("manual", %{attempts: 1}, :present)
    {logic, action} = Logic.after_press(logic, {:error, :panic_corner})

    assert action == {:finish, {:failed, :panic_corner}}
    assert logic.state == :failed
  end

  describe "the witness" do
    # The HUD returns nil in all three fields both for "logged out" and for "miscalibrated
    # sub-region" / "atlas missing a digit". If it was already absent BEFORE the press, a
    # later :gone cannot distinguish the two — confirming on it would invent a logout.
    test "without a readable HUD beforehand, no :gone confirms — however often it repeats" do
      {logic, _} = Logic.start("manual", %{attempts: 2}, :gone)
      refute logic.witness?

      logic =
        Enum.reduce(1..2, logic, fn _tentativa, logic ->
          {logic, _} = Logic.after_press(logic, :ok)
          {logic, _} = read_all(logic, List.duplicate(:gone, Logic.reads_per_attempt()))
          logic
        end)

      assert logic.state == :failed
      assert logic.error == :sem_testemunha
    end

    test "an unreadable baseline gives no witness either" do
      {logic, _} = Logic.start("manual", @config, :unreadable)

      refute logic.witness?
    end

    test "with a witness, the same pair of :gone confirms" do
      {logic, _} = Logic.start("manual", @config, :present)
      assert logic.witness?

      {logic, _} = Logic.after_press(logic, :ok)
      {logic, _} = Logic.after_read(logic, :gone)
      {logic, action} = Logic.after_read(logic, :gone)

      assert action == {:finish, :out}
      assert logic.state == :out
    end
  end
end
