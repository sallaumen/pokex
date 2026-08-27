defmodule Pokex.Pokedex.SkillProfile do
  @moduledoc """
  What each of a pokémon's skills is FOR.

  A combo written as "press 4, then 1, then 3 and 5" only ever works for the
  pokémon whose bar it was written against — swap Vileplume for Vespiqueen and
  the same keys do something else entirely. So the plan stops naming keys and
  names JOBS instead. Each pokémon says which of ITS keys does what, and one
  written strategy drives all of them.

  ## A job is a MOMENT, not a slot in one sequence

  The first cut treated the profile as a single ordered list and printed every
  classified key joined left to right — "combo: 1 → 2 → 3 → 4 → 5 → 6". He
  rejected it on sight: "eu seleciono, mas o combo não é uma junção"
  (2026-08-11). The jobs do not queue up behind each other; they happen at
  different points of the hunt:

    * `:buffs` (aura) — DURING the gathering, halfway through the huddle. It
      is what he keeps up while walking the mob stretch, not something pressed
      at the kill.
    * `:aoe` (área) — opens the kill. Area damage needs no target, which is
      why it can fire the instant the fire is released.
    * `:single` (alvo único) — the kill's SECOND half, and only with something
      marked: "skill single target só funciona se eu estiver marcando um
      alvo". Before the target lock it presses into nothing.
    * `:heal` (cura) — when the pokémon's life asks for it. Reactive, never a
      step in an order: `Pokex.Bots.PlayerSupport` presses it a rung ABOVE the
      potion, because a skill is one press and a potion is a channel combat
      cancels — so it is the only one of the two that works mid-fight.
    * `:crowd` (controle) — RESERVED for the moment before an auto-revive, the
      stun that buys the recall its time, "praticamente exclusivamente antes
      do momento de ter que usar revive". Spending it in an ordinary fight is
      the failure, so it is barred from the combo by construction — the same
      rule `Pokex.Combos`'s `{:rescue_only}` trigger already enforces on the
      rescue prefix.

  So `combo/1` is area-then-target and NOTHING else, and the other three jobs
  are read by whoever owns their moment.

  The profile is stored the way it is EDITED — one job per key
  (`%{"3" => :aoe}`) — which makes a key belonging to two categories
  impossible by construction rather than by validation. `by_category/1` and
  `keys/2` give the engine the view it wants.

  Within a moment, hotbar order is the firing order, because that is how he
  described every one of his own combos ("as skills 3 e 5", "3, 4, 5").
  """

  # Ordered by MOMENT, so reading the editor top to bottom tells the story of
  # a hunt: raise the damage aura while gathering, open with area, finish on a
  # target, heal when asked, and keep the control for the revive.
  #
  # `:buffs` and `:shield` were ONE job until 2026-08-26, and being one is what
  # made the bot use them badly: "a aura 2 é uma aura para dar dano e a aura 3 é
  # uma hora que deixa ele indestrutível". A timer that fires "the auras" spends
  # the invulnerability every eight seconds of gathering, on nothing.
  @categories [:buffs, :shield, :aoe, :single, :heal, :crowd]

  # The two halves of the kill, in the order they fire. Area first because it
  # needs no target; single-target after, once something is marked.
  @combo_categories [:aoe, :single]

  # The hotbar as the game lays it out: 1..9 then 0 for the tenth slot, the
  # same mapping `Pokex.Bots.SkillBar` reads cooldowns from.
  @hotbar_keys ~w(1 2 3 4 5 6 7 8 9 0)

  @type category :: :heal | :buffs | :shield | :aoe | :single | :crowd
  @type t :: %{optional(String.t()) => category}

  @doc "Every job a skill can have, in the order the editor offers them."
  @spec categories() :: [category]
  def categories, do: @categories

  @doc "Every hotbar key, in firing order."
  @spec hotbar_keys() :: [String.t()]
  def hotbar_keys, do: @hotbar_keys

  @doc "The Portuguese label for a job — the only place these words are written."
  @spec label(category) :: String.t()
  def label(:heal), do: "cura"
  def label(:buffs), do: "aura de dano"
  def label(:shield), do: "aura de defesa"
  def label(:aoe), do: "área"
  def label(:single), do: "alvo único"
  def label(:crowd), do: "controle"

  @doc "When this job happens, in one phrase — the thing the first cut got wrong."
  @spec moment(category) :: String.t()
  def moment(:buffs), do: "na mobada, e ANTES das skills de dano"
  def moment(:shield), do: "guardada pro perigo — não sai na rajada"
  def moment(:aoe), do: "abre a matança — não precisa de alvo"
  def moment(:single), do: "fecha a matança, só com alvo marcado"
  def moment(:heal), do: "quando a vida do pokémon pede — antes da poção"
  def moment(:crowd), do: "reservada pro stun antes do revive"

  @doc "The icon each moment carries, so the row reads at a glance."
  @spec icon(category) :: String.t()
  def icon(:buffs), do: "✨"
  def icon(:shield), do: "🛡️"
  def icon(:aoe), do: "💥"
  def icon(:single), do: "🎯"
  def icon(:heal), do: "❤️"
  def icon(:crowd), do: "🌀"

  @doc """
  Whether this job is part of the kill combo at all.

  `:crowd` answers false and that is the whole point: it must not be spent in
  an ordinary fight, or it is not there when the revive needs it.
  """
  @spec in_combo?(category) :: boolean
  def in_combo?(category), do: category in @combo_categories

  @doc """
  Gives `key` the job `category`, or takes its job away with `:none`.

  A key nobody has and a job nobody knows both leave the profile untouched —
  the same rule the route's `set_action/3` follows: a control that cannot act
  is a no-op, never an error.
  """
  @spec put(t, String.t(), category | :none) :: t
  def put(profile, key, :none) when is_map(profile), do: Map.delete(profile, key)

  def put(profile, key, category)
      when is_map(profile) and category in @categories and key in @hotbar_keys,
      do: Map.put(profile, key, category)

  def put(profile, _key, _unknown) when is_map(profile), do: profile

  @doc "The engine's view: every category, with its keys in firing order."
  @spec by_category(t) :: %{category => [String.t()]}
  def by_category(profile), do: Map.new(@categories, &{&1, keys(profile, &1)})

  @doc """
  The kill combo: the area keys, then the single-target ones.

  "O combo na prática deveria ser só as skills de área. Depois, as skills
  single target" (2026-08-11). Not every classified key joined together —
  the aura belongs to the gathering, the heal to a moment nobody schedules,
  and the control is reserved for the revive.
  """
  @spec combo(t) :: [String.t()]
  def combo(profile), do: Enum.flat_map(@combo_categories, &keys(profile, &1))

  @doc """
  `keys` deduped and put in firing order; anything that is not a hotbar key
  drops out.

  Used to show his OWN keys — the ones his hands press in the recorded routes —
  in the same order the editor lists them.
  """
  @spec in_firing_order([String.t()]) :: [String.t()]
  def in_firing_order(keys) when is_list(keys), do: Enum.filter(@hotbar_keys, &(&1 in keys))

  @doc """
  The keys of one job, in firing order — `[]` when this pokémon has none.

  The empty list is not a failure: it is what makes one strategy fit every
  pokémon, however many skills it has in each category.
  """
  @spec keys(t, category) :: [String.t()]
  def keys(profile, category), do: Enum.filter(@hotbar_keys, &(profile[&1] == category))

  @doc """
  The profile as the hunt reads it: `[{category, keys}]` for the jobs this
  pokémon actually has, in moment order.

  Empty jobs are left out — a pokémon with no barrier at all simply has
  nothing at that moment, which is what lets one written plan drive every one
  of them.
  """
  @spec moments(t) :: [{category, [String.t()]}]
  def moments(profile) do
    for category <- @categories,
        keys = keys(profile, category),
        keys != [],
        do: {category, keys}
  end

  @doc """
  Builds a profile from the editor's form data: `%{"1" => "none", "3" => "aoe"}`.

  The WHOLE form comes back on every change — one select per key, each with its
  own name — so the profile is rebuilt rather than patched. That is what makes
  the editor stateless: no `_target` to interpret, no per-key event that a
  browser was never going to send (`phx-value-*` does not ride on form events;
  the first cut of this editor was silently unable to save anything).
  """
  @spec from_form(term) :: t
  def from_form(params) when is_map(params) do
    for {key, value} <- params,
        key in @hotbar_keys,
        category = decode_category(value),
        into: %{} do
      {key, category}
    end
  end

  def from_form(_absent), do: %{}

  @doc """
  Reads a profile off disk: keys and jobs are WHITELISTED, never
  `String.to_atom/1` — `team.json` is a file he can edit by hand, and a typo in
  it must not mint atoms.
  """
  @spec decode(term) :: t
  def decode(map) when is_map(map) do
    for {key, value} <- map, key in @hotbar_keys, category = decode_category(value), into: %{} do
      {key, category}
    end
  end

  def decode(_absent), do: %{}

  defp decode_category(value) when is_atom(value) and value in @categories, do: value

  defp decode_category(value) when is_binary(value),
    do: Enum.find(@categories, &(Atom.to_string(&1) == value))

  defp decode_category(_unknown), do: nil

  @doc "The JSON-safe shape: `%{\"3\" => \"aoe\"}`."
  @spec encode(t) :: %{optional(String.t()) => String.t()}
  def encode(profile), do: Map.new(profile, fn {key, cat} -> {key, Atom.to_string(cat)} end)

  @typedoc "Quanto cada tecla leva pra voltar, em ms."
  @type cooldowns :: %{optional(String.t()) => pos_integer}

  @doc """
  Os cooldowns vindos do formulário, em SEGUNDOS — que é como ele os lê no
  jogo ("essa volta em 40 segundos"), e a única unidade em que digitar o número
  errado é difícil.

  Campo vazio é ausência, não zero: apagar o número é como se diz "não sei".
  """
  @spec cooldowns_from_form(term) :: cooldowns
  def cooldowns_from_form(params) when is_map(params) do
    for {key, value} <- params,
        key in @hotbar_keys,
        ms = seconds_to_ms(value),
        into: %{},
        do: {key, ms}
  end

  def cooldowns_from_form(_absent), do: %{}

  defp seconds_to_ms(value) when is_binary(value) do
    case Float.parse(String.trim(value)) do
      {seconds, _rest} -> sane_ms(round(seconds * 1_000))
      :error -> nil
    end
  end

  defp seconds_to_ms(_absent), do: nil

  @doc "O cooldown de `key` em segundos, pro formulário. Vazio quando não há."
  @spec seconds(cooldowns, String.t()) :: String.t()
  def seconds(cooldowns, key) do
    case Map.get(cooldowns, key) do
      ms when is_integer(ms) -> ms |> div(100) |> Kernel./(10) |> trim_zero()
      nil -> ""
    end
  end

  defp trim_zero(seconds) do
    if seconds == trunc(seconds),
      do: Integer.to_string(trunc(seconds)),
      else: Float.to_string(seconds)
  end

  @doc """
  O cooldown de cada tecla, saneado.

  Mora junto do perfil porque é a mesma pergunta feita à mesma pessoa sobre a
  mesma tecla — "o que ela faz" e "de quanto em quanto tempo dá pra usar" — e
  porque quem troca de pokémon troca as duas respostas de uma vez.

  Fora de faixa é DESCARTADO e não corrigido: um cooldown de 0 (ou de meia
  hora) digitado por engano vira "não sei", que é o único valor que não faz o
  cérebro decidir errado com confiança. O teto de 10 minutos é generoso de
  propósito; o piso de 1 segundo separa o que ele mediu do que escapou.
  """
  @spec decode_cooldowns(term) :: cooldowns
  def decode_cooldowns(map) when is_map(map) do
    for {key, value} <- map, key in @hotbar_keys, ms = sane_ms(value), into: %{}, do: {key, ms}
  end

  def decode_cooldowns(_absent), do: %{}

  defp sane_ms(value) when is_integer(value) and value >= 1_000 and value <= 600_000, do: value
  defp sane_ms(value) when is_float(value), do: sane_ms(round(value))
  defp sane_ms(_out_of_range), do: nil
end
