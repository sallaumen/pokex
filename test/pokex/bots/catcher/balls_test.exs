defmodule Pokex.Bots.Catcher.BallsTest do
  use ExUnit.Case, async: true

  alias Pokex.Bots.Catcher.Balls

  @types [
    %{"key" => "f1", "name" => "Poké Ball"},
    %{"key" => "f2", "name" => "Bola de aquáticos"}
  ]

  # A ESCOLHA VEM DO CORPO ENSINADO. Ela era uma lista de regras casadas por nome
  # de espécie, num overlay que ele não alcançava mais ("é coisa legada",
  # 11/09) — um segundo lugar guardando o mesmo dado que o acervo da Calibração
  # já guarda. Agora `key_for/3` recebe a escolha DAQUELA entrada, e o que
  # sobra aqui é só a pergunta "essa tecla existe no hotbar?".
  describe "choosing the ball for a recognised corpse" do
    test "the corpse's own choice is the ball that goes out" do
      assert Balls.key_for("Tentacool shiny", "f2", @types) == "f2"
    end

    test "a corpse that chose nothing gets the default ball" do
      assert Balls.key_for("Rattata", nil, @types) == Balls.default_key()
      assert Balls.key_for("Rattata", "", @types) == Balls.default_key()
    end

    test "an unrecognised corpse gets the default ball" do
      assert Balls.key_for(nil, "f2", @types) == Balls.default_key()
    end

    # Uma escolha apontando pra uma tecla que não está no hotbar jogaria NADA —
    # pior que a bola comum, porque parece que funcionou.
    test "a choice for a ball he does not have is ignored" do
      assert Balls.key_for("Tentacool", "f7", @types) == Balls.default_key()
      assert Balls.key_for("Tentacool", "f2", []) == Balls.default_key()
    end

    test "a malformed hotbar never takes the throw down" do
      assert Balls.key_for("Tentacool", "f2", nil) == Balls.default_key()
    end
  end

  # O SHINY NÃO TEM CORPO ENSINADO — ele é seguido pela barra até a queda, e o
  # que sobra é uma âncora. Não há foto onde pendurar a escolha, então a bola
  # dele é UMA chave só, e ela existe pra bola cara não ser gasta no que a
  # varredura acha no chão.
  describe "choosing the ball for the shiny's anchor" do
    test "the shiny's choice is the ball that goes out" do
      assert Balls.key_for("Shiny (brilho)", :anchor, nil, "f2", @types) == "f2"
    end

    test "no choice, or one for a ball he does not have, falls back to the default" do
      assert Balls.key_for("Shiny (brilho)", :anchor, nil, nil, @types) == Balls.default_key()
      assert Balls.key_for("Shiny (brilho)", :anchor, nil, "", @types) == Balls.default_key()
      assert Balls.key_for("Shiny (brilho)", :anchor, nil, "f9", @types) == Balls.default_key()
    end

    # A âncora não passa pelo acervo: o nome dela vem do que o cliente
    # desenhava em cima do bicho, e não há bola ensinada pra ele. Se a escolha
    # do corpo vazasse pra cá, um Tentacool ensinado mudaria a bola do shiny.
    test "the taught corpse's choice never reaches the anchor" do
      assert Balls.key_for("Tentacool", :anchor, "f2", nil, @types) == Balls.default_key()
    end

    # …e o contrário: a bola cara do shiny não pode sair no corpo comum.
    test "and the shiny's choice never reaches an ordinary corpse" do
      assert Balls.key_for("Rattata", :corpse, nil, "f2", @types) == Balls.default_key()
    end

    test "an unnamed anchor still gets a ball — the shiny's" do
      assert Balls.key_for(nil, :anchor, nil, "f2", @types) == "f2"
    end
  end

  describe "naming a ball for the feed" do
    test "a configured ball is named" do
      assert Balls.label("f2", @types) == "Bola de aquáticos"
    end

    test "an unconfigured key names itself rather than going blank" do
      assert Balls.label("f9", @types) == "f9"
      assert Balls.label("f2", [%{"key" => "f2", "name" => ""}]) == "f2"
    end
  end
end
