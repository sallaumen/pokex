defmodule Pokex.Settings.LockedTest do
  @moduledoc """
  As constantes: existem, aparecem, e o arquivo não manda nelas.

  "Se for algo que não faz sentido ser configurável dá pra usar constante no
  código e mostrar a constante ali só pra eu saber que existe, mas sem deixar
  configurar" (Lucas, 02/09).
  """
  use ExUnit.Case, async: true

  alias Pokex.Settings
  alias Pokex.Settings.Locked

  test "toda chave travada existe no Settings — travar o que não existe é erro de digitação" do
    seeds = Settings.defaults()

    for key <- Locked.keys() do
      assert Map.has_key?(seeds, key), "#{key} está travada mas não existe no Settings"
    end
  end

  test "toda travada tem grupo e porquê, e o porquê não é vazio" do
    for {key, {group, why}} <- Locked.all() do
      assert is_binary(group) and group != "", "#{key} sem grupo"
      assert is_binary(why) and String.length(why) > 8, "#{key} sem porquê"
    end
  end

  # As chaves que ele mexe ficam editáveis, sem exceção — nenhuma delas pode
  # estar travada, senão o ajuste dele vira decoração.
  test "nenhuma chave do personagem ou de preset está travada" do
    for key <- Settings.character_keys() ++ Settings.preset_keys() do
      refute Locked.locked?(key), "#{key} é dele e está travada"
    end
  end

  test "groups/0 agrupa, ordena e deixa 'Vai sumir' por último" do
    groups = Locked.groups()

    assert Enum.map(groups, &elem(&1, 0)) |> Enum.uniq() |> length() == length(groups)
    assert {"Vai sumir", _rows} = List.last(groups)

    for {_group, rows} <- groups, {key, why} <- rows do
      assert Locked.locked?(key)
      assert is_binary(why)
    end
  end
end
