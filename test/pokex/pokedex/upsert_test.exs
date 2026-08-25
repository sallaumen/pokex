defmodule Pokex.Pokedex.UpsertTest do
  use ExUnit.Case, async: true

  alias Pokex.Pokedex.Upsert

  defp entry(name, extra \\ %{}) do
    Map.merge(
      %{
        name: name,
        number: 1,
        level: 10,
        elements: ["Water"],
        scraped_at: "2026-08-25T10:00:00Z"
      },
      extra
    )
  end

  describe "merge/2 — the bookkeeping stamps" do
    test "a brand-new entry gets first_seen_at and changed_at from the current sync" do
      [seadra] = Upsert.merge([], [entry("Seadra")])

      assert seadra.first_seen_at == "2026-08-25T10:00:00Z"
      assert seadra.changed_at == "2026-08-25T10:00:00Z"
    end

    test "a re-sync with no content change preserves both dates" do
      [old] = Upsert.merge([], [entry("Seadra")])
      old_json = old |> JSON.encode!() |> JSON.decode!()

      [again] =
        Upsert.merge([old_json], [entry("Seadra", %{scraped_at: "2026-08-26T10:00:00Z"})])

      assert again.first_seen_at == "2026-08-25T10:00:00Z"
      assert again.changed_at == "2026-08-25T10:00:00Z"
    end

    test "a changed field moves changed_at forward but not first_seen_at" do
      [old] = Upsert.merge([], [entry("Seadra")])
      old_json = old |> JSON.encode!() |> JSON.decode!()

      [again] =
        Upsert.merge([old_json], [
          entry("Seadra", %{level: 55, scraped_at: "2026-08-26T10:00:00Z"})
        ])

      assert again.first_seen_at == "2026-08-25T10:00:00Z"
      assert again.changed_at == "2026-08-26T10:00:00Z"
    end
  end

  describe "merge/2 — what survives a partial run" do
    test "an entry this run did not fetch stays in the base untouched" do
      existing = [%{"name" => "Horsea", "level" => 20}]

      merged = Upsert.merge(existing, [entry("Seadra")])

      assert length(merged) == 2
      assert Enum.any?(merged, &(Map.get(&1, "name") == "Horsea"))
    end

    test "a freshly fetched entry replaces its own older version, never duplicates it" do
      existing = [%{"name" => "Seadra", "level" => 20, "scraped_at" => "2026-08-01T10:00:00Z"}]

      merged = Upsert.merge(existing, [entry("Seadra", %{level: 50})])

      assert [%{name: "Seadra", level: 50}] = merged
    end
  end
end
