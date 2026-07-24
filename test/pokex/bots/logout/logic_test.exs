defmodule Pokex.Bots.Logout.LogicTest do
  use ExUnit.Case, async: true

  alias Pokex.Bots.Logout.Logic

  @config %{attempts: 3}

  # O caso normal: a HUD estava legível antes de apertar, então temos testemunha.
  defp start, do: Logic.start("manual", @config, :present)

  # Alimenta uma sequência de leituras, devolvendo {logic, ultima_acao}.
  defp read_all(logic, readings) do
    Enum.reduce(readings, {logic, :verify}, fn reading, {logic, _acao} ->
      Logic.after_read(logic, reading)
    end)
  end

  test "start pede a primeira tecla, na tentativa 1" do
    {logic, action} = start()

    assert action == :press
    assert logic.state == :pressing
    assert logic.attempt == 1
    assert logic.reason == "manual"
  end

  test "uma tecla que saiu manda conferir a tela" do
    {logic, _} = start()
    {logic, action} = Logic.after_press(logic, :ok)

    assert action == :verify
    assert logic.state == :verifying
    assert logic.reads == 0
    assert logic.confirms == 0
  end

  test "duas leituras :gone seguidas confirmam o logout" do
    {logic, _} = start()
    {logic, _} = Logic.after_press(logic, :ok)

    {logic, :verify} = Logic.after_read(logic, :gone)
    {logic, action} = Logic.after_read(logic, :gone)

    assert action == {:finish, :out}
    assert logic.state == :out
  end

  test "um :present entre dois :gone zera a contagem — não confirma" do
    {logic, _} = start()
    {logic, _} = Logic.after_press(logic, :ok)

    {logic, _} = Logic.after_read(logic, :gone)
    {logic, _} = Logic.after_read(logic, :present)
    {logic, action} = Logic.after_read(logic, :gone)

    assert action == :verify
    assert logic.confirms == 1
    assert logic.state == :verifying
  end

  test ":unreadable nunca confirma, por mais que se repita" do
    {logic, _} = start()
    {logic, _} = Logic.after_press(logic, :ok)

    {logic, action} = read_all(logic, List.duplicate(:unreadable, Logic.reads_per_attempt()))

    # esgotou as leituras da tentativa 1 e foi para a tentativa 2 — nunca :out
    assert action == :press
    assert logic.attempt == 2
    assert logic.confirms == 0
  end

  test "esgotar as leituras da tentativa começa uma tentativa nova" do
    {logic, _} = start()
    {logic, _} = Logic.after_press(logic, :ok)

    {logic, action} = read_all(logic, List.duplicate(:present, Logic.reads_per_attempt()))

    assert action == :press
    assert logic.state == :pressing
    assert logic.attempt == 2
    assert logic.reads == 0
  end

  test "esgotar as tentativas termina em falha, com o motivo" do
    logic =
      Enum.reduce(1..3, elem(start(), 0), fn _tentativa, logic ->
        {logic, _} = Logic.after_press(logic, :ok)
        {logic, _} = read_all(logic, List.duplicate(:present, Logic.reads_per_attempt()))
        logic
      end)

    assert logic.state == :failed
    assert logic.error == :ainda_logado
  end

  test "uma tecla que não saiu queima a tentativa e tenta de novo" do
    {logic, _} = start()
    {logic, action} = Logic.after_press(logic, {:error, :panic_corner})

    assert action == :press
    assert logic.attempt == 2
  end

  test "com uma tentativa só, uma tecla que não saiu já é falha" do
    {logic, _} = Logic.start("manual", %{attempts: 1}, :present)
    {logic, action} = Logic.after_press(logic, {:error, :panic_corner})

    assert action == {:finish, {:failed, :panic_corner}}
    assert logic.state == :failed
  end

  describe "a testemunha" do
    # A HUD devolve nil nos três campos tanto para "deslogado" quanto para
    # "sub-região descalibrada" / "atlas sem o dígito". Se ela já estava
    # ausente ANTES de apertar, um :gone depois não distingue as duas coisas —
    # e confirmar por ele seria inventar um logout que nunca aconteceu.
    test "sem HUD legível antes, NENHUM :gone confirma — por mais que se repita" do
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

    test "baseline ilegível também não dá testemunha" do
      {logic, _} = Logic.start("manual", @config, :unreadable)

      refute logic.witness?
    end

    test "com testemunha, o mesmo par de :gone confirma" do
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
