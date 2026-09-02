defmodule Pokex.Bots.Combat.Strategy do
  @moduledoc """
  Which keys the fight presses, and in what order — decided from what the keys
  DO, not from a hand-written list.

  The bot used to press `skill_keys`, one global priority list that knows
  nothing about the pokémon holding the bar or about how many things are on
  screen. Two consequences he named on 2026-08-11: a swap makes the list wrong,
  and "quando você fica tentando matar de um em um, ele é extremamente mais
  lento" cannot be avoided by a list that cannot tell area from single-target.

  So the order is computed, per burst, from three things:

    * the **loadout** — this pokémon's keys by job (`Pokex.Bots.Combat.Loadout`)
    * **how many enemies** are on the battle list right now
    * whether this is the **opening** of a gathered pile

  The rules, in his words:

    * opening after a gathering → **area first**, always. The pile only exists
      because the hunt spent a whole stretch building it.
    * a crowd (`aoe_from` or more) → area first: the same reason, without the
      gathering.
    * one or two → **single-target first**. "se fossemos inteligentes,
      poderíamos contar a quantidade de inimigos, e ir usando as skills single
      target primeiro com poucos inimigos e guardar para mobar em inimigos
      maiores".
    * **control never**. It is the stun the auto-revive borrows; spending it
      here is why it is not there when the recall needs it.
    * **aura and heal never** either — not because they are useless, but
      because they answer to moments this function does not own (the middle of
      the huddle, and a health bar). A rotation that presses them "sometime" is
      exactly the mistake of gluing separate moments into one sequence.

  Nothing here reads the world or the clock: given the same three inputs it
  always answers the same order, which is what makes the rules arguable.
  """

  alias Pokex.Bots.Combat.Loadout

  @type opts :: [
          enemies: non_neg_integer,
          opening?: boolean,
          aoe_from: pos_integer,
          aura_ready?: boolean,
          shield_ready?: boolean,
          single_target?: boolean,
          ready_keys: [String.t()] | nil
        ]

  @doc """
  The keys to press, best first — `[]` when this pokémon has nothing to attack
  with, which the caller must read as "fall back to the configured list".

  `:enemies` defaults to 1 (the pessimistic read: a lone target is the case
  where firing area first wastes the most).
  """
  @spec skill_order(Loadout.t() | nil, opts) :: [String.t()]
  def skill_order(nil, _opts), do: []

  def skill_order(%Loadout{} = loadout, opts) do
    damage = loadout |> damage_keys(opts) |> only_ready(opts)

    # A REGRA DELE, com a condição que ele pôs: "usar a aura 2 QUANDO DISPONÍVEL
    # e se for usar outras skills usar elas depois" (26/08). Uma aura de dano que
    # sai depois do dano não multiplicou nada.
    #
    # O "quando disponível" não é decoração. A aura tinha o momento dela — o
    # relógio da mobada, que a levanta oito segundos depois de começar a juntar —
    # e enfiá-la em toda rajada seria apertá-la em cooldown na maioria das vezes.
    # Com o intervalo dele em 500ms, cada tecla que não sai custa meio segundo de
    # dano. Então quem chama diz se ela está pronta; sem ninguém dizendo, a
    # rajada continua exatamente como era.
    #
    # A ORDEM DAS DUAS AURAS: escudo, dano, e só então as teclas de dano. O
    # escudo primeiro porque ele é sobre SOBREVIVER à salva que vem; a aura de
    # dano depois porque ela multiplica o que sai atrás dela.
    #
    # `shield` era proibido aqui, com pronta ou sem — "uma invulnerabilidade
    # gasta a cada abertura é uma invulnerabilidade que não existe quando ele
    # precisa". Ele desmentiu isso em 27/08, olhando a caçada: "a de defesa vale
    # sempre que tem já uns 2 pokémons atacando ele pelo menos (…) ou no pior
    # dos casos, que nem a aura de ataque: quando entrar em luta, sempre
    # garantir usar se estiver disponível". Quem decide o "2" é quem chama —
    # aqui ela entra quando mandarem, e nunca por conta própria.
    escudo = if Keyword.get(opts, :shield_ready?, false), do: loadout.shield, else: []
    aura = if Keyword.get(opts, :aura_ready?, false), do: loadout.buffs, else: []

    escudo ++ aura ++ damage
  end

  # A MESMA REGRA DAS AURAS, ESTENDIDA AO DANO — e ela já estava escrita aqui em
  # cima, só que valendo só pras auras: "com o intervalo dele em 500ms, cada
  # tecla que não sai custa meio segundo de dano".
  #
  # A noite de 29/08 mediu o que isso custava: 81% dos apertos de dano foram em
  # tecla que JÁ ESTAVA esfriando, e 74% das rajadas eram inteiramente assim —
  # três teclas frias, um segundo e meio de teclado, zero dano. Onze minutos de
  # uma caçada de 82.
  #
  # `ready_keys` ausente ou nil é a leitura INDISPONÍVEL, e aí vai tudo às
  # cegas: é a mesma regra que o resgate já usa ("nil quando a leitura está
  # indisponível, e aí TODAS entram cegas"), porque segurar dano por causa de
  # uma barra que ninguém conseguiu ler é o pior lado de errar. Uma leitura que
  # existe e não traz NENHUMA das teclas é resposta legítima: não há o que
  # apertar, e a rajada vazia devolve o tique pro cérebro decidir de novo em
  # 200ms.
  defp only_ready(damage, opts) do
    case Keyword.get(opts, :ready_keys) do
      nil -> damage
      ready -> Enum.filter(damage, &(&1 in ready))
    end
  end

  # O QUE DÁ DANO NESTA CAÇADA, na régua dele (27/08): "o que dá dano é a skill
  # em área, praticamente exclusivamente (…) a gente nem precisa usar as de
  # alvo único".
  #
  # Ele viu o defeito de dentro: entrou numa luta com DOIS bichos, o
  # `combat_aoe_from_enemies: 3` pôs alvo único na frente, e a luta virou uma
  # sequência de teclas que não matam. A ordem entre área e alvo único era uma
  # pergunta legítima quando as duas machucavam; nesta hunt uma delas não
  # machuca, e a resposta certa é não gastar o tempo dela.
  #
  # E O RECUO DE QUEM NÃO TEM ÁREA MORREU (29/08). Ele dizia: "o alvo único
  # volta sozinho pra quem não tem área, porque ficar mudo é pior que bater
  # fraco". A premissa era essa — bater fraco. Ela caiu: "skills de alvo único
  # não funcionam mais, de propósito". Uma tecla que o jogo ignora não bate
  # fraco, não bate nada, e ainda queima o cooldown dela e a vez da rajada.
  #
  # Com a regra desligada, um pokémon sem área classificada agora não tem o que
  # apertar — e isso é a verdade, não uma falha: `Loadout.attacks?/1` e a fase
  # "sem teclas de ataque" existem exatamente pra dizer isso em voz alta.
  defp damage_keys(loadout, opts) do
    single? = Keyword.get(opts, :single_target?, false)
    single = Loadout.single_keys(loadout, single?)

    cond do
      not single? -> loadout.aoe
      loadout.aoe == [] -> single
      area_first?(loadout, opts) -> loadout.aoe ++ single
      true -> single ++ loadout.aoe
    end
  end

  @doc """
  The opening burst for a pile that has just finished gathering: the area keys,
  then the single-target ones.

  This is what replaces the raw recorded combo once the pokémon's keys are
  classified — the recorded one presses whatever his hands pressed at that
  waypoint, which stops being true the moment he swaps pokémon, and can even
  spend a control skill that was supposed to survive for the revive.
  """
  @spec opening(Loadout.t() | nil, opts) :: [String.t()]
  def opening(loadout, opts \\ []), do: skill_order(loadout, [opening?: true] ++ opts)

  @doc """
  The keys that must never be pressed by an ordinary fight, whatever the
  situation: this pokémon's control skills, and its defensive aura.

  Both are the same kind of thing — a button whose whole value is being unspent
  when the trouble arrives. "A aura 3 é uma hora que deixa ele indestrutível"
  (2026-08-26), and one spent on every opening is one he does not have.

  Exposed so the caller can PROVE the exclusion rather than trust it.
  """
  @spec reserved(Loadout.t() | nil) :: [String.t()]
  def reserved(nil), do: []
  def reserved(%Loadout{} = loadout), do: loadout.crowd ++ loadout.shield

  # A gathered pile is a crowd by definition — its size is the whole point of
  # having gathered it, and the battle list at that instant may still be
  # catching up with what is walking in.
  defp area_first?(_loadout, opts) do
    if Keyword.get(opts, :opening?, false) do
      true
    else
      Keyword.get(opts, :enemies, 1) >= Keyword.get(opts, :aoe_from, 3)
    end
  end
end
