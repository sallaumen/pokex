defmodule Pokex.Bots.StatusCureTest do
  @moduledoc """
  A STATUS POTION ANTES DO ATAQUE.

  O pokémon dormindo, silenciado ou congelado transforma a corrente em tecla
  morta: as skills não saem, a barra não gasta, e o bot insiste contra uma
  mobada que continua batendo. A poção do slot E cura tudo isso e é no-op
  quando não há status, então o prefixo custa só tempo — e por isso a regra
  aqui é generosa por padrão.

  Quem APERTA é o `Combat.Worker` (cobrado no `worker_test.exs`); este módulo
  só responde se vale apertar.
  """
  use ExUnit.Case, async: false

  alias Pokex.Bots.StatusCure
  alias Pokex.Rig.Fake
  alias Pokex.SettingsStash

  setup do
    SettingsStash.stash!(
      status_cure_enabled: true,
      status_cure_key: "e",
      status_cure_settle_ms: 100,
      tab_key: "tab",
      attack_mode_key: "shift+1",
      defense_mode_key: "shift+3"
    )

    :ok
  end

  describe "o que ela é" do
    test "a tecla e o respiro saem da configuração" do
      assert StatusCure.key() == "e"
      assert StatusCure.settle_ms() == 100
      assert StatusCure.enabled?()
    end

    test "espaço em volta da tecla não conta" do
      SettingsStash.stash!(status_cure_key: "  e  ")
      assert StatusCure.key() == "e"
    end
  end

  describe "quando vale limpar" do
    # No Auto Combo a janela de 4s já limita o prefixo a ~15 por minuto, e o
    # status que mata é o que chega no MEIO da mobada — entre a primeira
    # corrente e a terceira.
    test "a corrente limpa sempre, mesmo já tendo limpado nesta luta" do
      assert StatusCure.due?(:always, ["r"], true)
    end

    test "nos outros modos a primeira rajada ofensiva da luta limpa" do
      assert StatusCure.due?(:opening, ["3", "4"], false)
    end

    test "…e a segunda não" do
      refute StatusCure.due?(:opening, ["3", "4"], true)
    end

    # Mirar não é atacar: uma rajada que só troca de alvo não merece poção.
    test "o Tab sozinho não é abertura" do
      refute StatusCure.due?(:opening, ["tab"], false)
    end

    test "o Tab acompanhado de skill é" do
      assert StatusCure.due?(:opening, ["tab", "3"], false)
    end

    # Trocar de postura também não é conjurar, e a rajada da postura sai sozinha:
    # sem esta cerca, a primeira poção da luta era gasta no `shift+3` e o ataque
    # que vinha depois saía sem limpeza nenhuma (medido no worker, 05/09).
    test "trocar de postura não é atacar" do
      refute StatusCure.due?(:opening, ["shift+3"], false)
      refute StatusCure.due?(:always, ["shift+1"], false)
    end
  end

  describe "o aperto" do
    setup do
      {:ok, _} = Fake.start_link(%{})
      :ok
    end

    test "aperta a tecla configurada" do
      assert StatusCure.press() == :ok
      assert Fake.calls() == [press: "e"]
    end

    # Sem tecla não há o que apertar, e um `press("")` chegaria ao rig como uma
    # combinação vazia — um aperto que o jogo não entende e que o vigia de
    # teclado ainda teria que explicar.
    test "sem tecla configurada, não toca no teclado" do
      SettingsStash.stash!(status_cure_key: "  ")
      assert StatusCure.press() == :ok
      assert Fake.calls() == []
    end

    test "desligada, não toca no teclado" do
      SettingsStash.stash!(status_cure_enabled: false)
      assert StatusCure.press() == :ok
      assert Fake.calls() == []
    end
  end

  describe "quando não vale" do
    test "desligada, nem a corrente limpa" do
      SettingsStash.stash!(status_cure_enabled: false)
      refute StatusCure.due?(:always, ["r"], false)
      refute StatusCure.due?(:opening, ["3"], false)
    end

    test "sem tecla configurada não há o que apertar" do
      SettingsStash.stash!(status_cure_key: "   ")
      refute StatusCure.due?(:always, ["r"], false)
    end

    test "rajada vazia não limpa" do
      refute StatusCure.due?(:always, [], false)
      refute StatusCure.due?(:opening, [], false)
    end
  end
end
