defmodule Pokex.Bots.SkillTruth do
  @moduledoc """
  A tela corrigindo o relógio das teclas, um frame por vez.

  O carimbo do `Pokex.Bots.SkillClock` é uma PREVISÃO: "apertei, então esfria
  por Xs". Ele erra de três jeitos que a caçada dele já pagou (28/08, a hunt
  com o Gyarados: "a IA acha que usou uma skill e marca o cooldown, mas na
  verdade ela não saiu"):

    * o aperto foi ENGOLIDO — o portão de foco suprime o input e responde `:ok`,
      e o carimbo nasce sem tecla nenhuma ter saído;
    * o cooldown ESCRITO é maior que o real — o relógio segura uma tecla que o
      jogo já devolveu;
    * um revive que o bot não despachou (o F4 da mão dele) zerou a barra
      inteira, e o relógio não estava lá pra ver.

  Nos três casos a assinatura é a mesma: **a tela mostra a tecla PRONTA e o
  relógio tem um carimbo dizendo que não**. Este módulo olha cada frame fresco
  da barra (o feed `:skill_bar`, ~400ms) e, quando a discordância persiste,
  apaga o carimbo — `SkillClock.release/1`. A direção contrária não existe
  aqui de propósito: quem carimba aperto que o bot não deu é o
  `Pokex.Bots.HandWatch`, lendo o teclado de verdade, não um pixel.

  ## As três guardas antes de soltar

    * **Carência** (`@grace_ms`): o efeito de uma skill leva ~800ms-1s pra
      aparecer ("sempre que usa uma skill, ele leva uns 800ms, um segundo pra
      fazer o efeito" — ele, 28/08). Um carimbo mais novo que isso ainda não
      teve tempo de virar contagem na tela; soltá-lo seria desfazer um aperto
      legítimo.
    * **Dois frames seguidos** (`@frames_to_free`): um frame só é uma foto, e
      foto tem ruído. A mesma discordância em dois frames é o jogo insistindo.
    * **Tecla surda fica fora** (`deaf_ms`): quando o jogo já provou que a
      barra MENTE sobre uma tecla (`SkillClock.denied/2`), "pronta na tela" é
      exatamente o estado mentiroso — não desmente nada.

  Soltar é sempre seguro: no pior caso o combate oferece uma tecla que o jogo
  recusa, o recibo (`SkillReceipt`) pega o `missed`, e a cadeia se corrige.
  Segurar tecla boa é o erro caro — foi ele que travou a rotação por 19s em
  27/08.

  A narração só sai quando o carimbo ainda era jovem o bastante pra estar
  MUTANDO a tecla (menos que o cooldown assumido): carimbo velho expirado é
  faxina silenciosa, não notícia.
  """

  alias Pokex.Bots.SkillClock

  @table :pokex_skill_truth

  # A skill's effect takes ~800ms-1s to show; the slack covers that and the age the frame
  # already had when the press left.
  @grace_ms 2_500
  @frames_to_free 2

  @doc false
  def table, do: @table

  @doc "Garante a tabela dos streaks. Idempotente — mesmo molde do SkillClock."
  @spec ensure_table() :: :ok
  def ensure_table do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:set, :public, :named_table, write_concurrency: true])
    end

    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc """
  Olha um frame FRESCO da barra (a observação que `Interpret.skills/3` acabou
  de montar) e corrige o relógio. Devolve as teclas que soltou.

  `ready_keys: nil` (barra ilegível) não corrige nada — a tela que não fala
  não desmente ninguém.
  """
  @spec observe(map, integer) :: [String.t()]
  def observe(obs, now \\ System.monotonic_time(:millisecond))

  def observe(%{ready_keys: ready}, now) when is_list(ready) do
    ensure_table()

    # `judge` condemns, `free` executes, and free RE-CHECKS the stamp, because between the
    # two the Body may have pressed the same key again.
    freed = Enum.filter(ready, fn key -> judge(key, now) and free(key, now) end)

    # A key the screen shows COOLING agrees with any stamp: its disagreement died, and the
    # streak dies with it.
    Enum.each(known_streaks() -- ready, &:ets.delete(@table, &1))

    freed
  end

  def observe(_sem_leitura, _now), do: []

  # The key is ready ON SCREEN. Does it deserve to be freed?
  defp judge(key, now) do
    with at when is_integer(at) <- SkillClock.last_press(key),
         true <- now - at > @grace_ms,
         0 <- SkillClock.deaf_ms(key, %{}, now) do
      bump(key) >= @frames_to_free
    else
      _sem_carimbo_carencia_ou_surda ->
        :ets.delete(@table, key)
        false
    end
  end

  # Frees for real, and says whether it did. The age is RE-READ here: between the judgement
  # and this erase the Body may have stamped a NEW press on the same key, and freeing it would
  # erase a legitimate shot. A stamp younger than the grace = changed hands; the streak resets
  # and the judgement restarts from the first frame.
  defp free(key, now) do
    :ets.delete(@table, key)
    age = now - (SkillClock.last_press(key) || now)

    if age > @grace_ms do
      SkillClock.release(key)

      # A stamp that would still hold the key is news; an expired stamp is housekeeping,
      # and housekeeping narrated in a loop would bury the feed.
      if age < SkillClock.assumed_ms(), do: narrate(key, age)
      true
    else
      false
    end
  end

  defp narrate(key, age) do
    Phoenix.PubSub.broadcast(
      Pokex.PubSub,
      Pokex.Bots.Combat.Worker.topic(),
      {:combat_log, :macro,
       "combate: 🧭 o jogo mostra a #{key} pronta e o relógio a segurava " <>
         "(aperto de #{div(age, 1_000)}s atrás que não deve ter chegado) — soltei"}
    )
  end

  defp bump(key) do
    ensure_table()
    :ets.update_counter(@table, key, {2, 1}, {key, 0})
  end

  defp known_streaks do
    ensure_table()
    :ets.select(@table, [{{:"$1", :_}, [], [:"$1"]}])
  end
end
