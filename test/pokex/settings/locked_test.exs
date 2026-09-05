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

  test "every locked key exists in Settings: locking what does not exist is a typo" do
    seeds = Settings.defaults()

    for key <- Locked.keys() do
      assert Map.has_key?(seeds, key), "#{key} está travada mas não existe no Settings"
    end
  end

  test "every locked key has a group and a why, and the why is not empty" do
    for {key, {group, why}} <- Locked.all() do
      assert is_binary(group) and group != "", "#{key} sem grupo"
      assert is_binary(why) and String.length(why) > 8, "#{key} sem porquê"
    end
  end

  # As chaves que ele mexe ficam editáveis, sem exceção — nenhuma delas pode
  # estar travada, senão o ajuste dele vira decoração.
  test "no character or preset key is locked" do
    for key <- Settings.character_keys() ++ Settings.preset_keys() do
      refute Locked.locked?(key), "#{key} é dele e está travada"
    end
  end

  test "groups/0 agrupa e ordena" do
    groups = Locked.groups()

    assert Enum.map(groups, &elem(&1, 0)) |> Enum.uniq() |> length() == length(groups)
    assert Enum.map(groups, &elem(&1, 0)) == Enum.sort(Enum.map(groups, &elem(&1, 0)))

    for {_group, rows} <- groups, {key, why} <- rows do
      assert Locked.locked?(key)
      assert is_binary(why)
    end
  end
end
