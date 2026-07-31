defmodule Pokex.Bots.Logout.Logic do
  @moduledoc """
  The logout decision, nothing around it: no process, clock or screen. Takes
  each key result and each screen reading, returns the next action — which is
  what lets the whole protocol be tested without the game open.

  Ruling principle: **every ambiguity resolves to "did not log out"**. An
  unreadable reading confirms nothing, and an unconfirmed logout ends in
  FAILURE — which is loud. A false "logged out" is exactly the silent loss this
  feature exists to kill: going to sleep believing you left while stamina burns
  all night.

  Only a `:gone` reading TWICE IN A ROW confirms. A single misread glyph cannot
  forge a logout.

  ## The witness

  `:gone` alone proves nothing. The bottom bar also returns nil in all three
  fields when sub-regions are uncalibrated or the glyph atlas is missing a
  digit — the "9" missing until 2026-07-23 is a real, lived case. In that world
  the HUD was "absent" BEFORE any key, and confirming by it would invent a
  logout.

  So the measure is DIFFERENTIAL: the worker reads the bar before acting and
  passes the reading as `baseline`. Only when it was `:present` — the HUD was
  readable, we have a witness — does a later `:gone` mean anything. Without a
  witness the logout ends in failure (`:sem_testemunha`), loudly: the keys were
  sent all the same, it just cannot be ASSERTED they worked.
  """

  # How many reads an attempt gets before pressing the keys again. An internal
  # bound so the loop terminates, not a user choice — hence attribute, not setting.
  @reads_per_attempt 4

  defstruct state: :idle,
            reason: nil,
            attempt: 0,
            reads: 0,
            confirms: 0,
            config: %{},
            error: nil,
            # was the HUD readable BEFORE pressing? without it a :gone proves
            # nothing — see "The witness" in the moduledoc
            witness?: false

  @type reading :: :gone | :present | :unreadable
  @type action :: :press | :verify | {:finish, :out} | {:finish, {:failed, term()}}
  @type t :: %__MODULE__{}

  @doc "How many reads fit in one attempt."
  @spec reads_per_attempt() :: pos_integer()
  def reads_per_attempt, do: @reads_per_attempt

  @doc """
  Begins a logout. The first action is always pressing the keys.

  `baseline` is the bar reading BEFORE acting. Only `:present` grants a witness
  — anything else and no later `:gone` can confirm. Deliberately no default:
  the caller must decide, and an optimistic default here would be exactly the
  bug the witness exists to prevent.
  """
  @spec start(String.t(), %{attempts: pos_integer()}, reading()) :: {t(), action()}
  def start(reason, config, baseline) do
    logic = %__MODULE__{
      state: :pressing,
      reason: reason,
      attempt: 1,
      config: config,
      witness?: baseline == :present
    }

    {logic, :press}
  end

  @doc """
  The key sequence's result. A focus failure enters here too: for the decision,
  "couldn't front the game" and "the key didn't go out" are the same fact — the
  key never happened.
  """
  @spec after_press(t(), :ok | {:error, term()}) :: {t(), action()}
  def after_press(%__MODULE__{} = logic, :ok),
    do: {%{logic | state: :verifying, reads: 0, confirms: 0}, :verify}

  def after_press(%__MODULE__{} = logic, {:error, reason}), do: retry(logic, reason)

  @doc "One screen reading."
  @spec after_read(t(), reading()) :: {t(), action()}
  def after_read(%__MODULE__{} = logic, reading) do
    case {reading, logic.witness?} do
      {:gone, true} -> confirma(logic)
      {:gone, false} -> does_not_confirm(logic, :no_witness)
      {:present, _} -> does_not_confirm(logic, :still_logged_in)
      {:unreadable, _} -> does_not_confirm(logic, :unreadable)
    end
  end

  defp confirma(logic) do
    logic = %{logic | reads: logic.reads + 1, confirms: logic.confirms + 1}

    cond do
      logic.confirms >= 2 -> {%{logic | state: :out}, {:finish, :out}}
      logic.reads >= @reads_per_attempt -> retry(logic, :did_not_confirm)
      true -> {logic, :verify}
    end
  end

  defp does_not_confirm(logic, reason) do
    logic = %{logic | reads: logic.reads + 1, confirms: 0}

    if logic.reads >= @reads_per_attempt,
      do: retry(logic, reason),
      else: {logic, :verify}
  end

  defp retry(logic, reason) do
    if logic.attempt < Map.fetch!(logic.config, :attempts) do
      {%{logic | state: :pressing, attempt: logic.attempt + 1, reads: 0, confirms: 0}, :press}
    else
      {%{logic | state: :failed, error: reason}, {:finish, {:failed, reason}}}
    end
  end
end
