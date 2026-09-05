defmodule Pokex.Bots.StatusCure do
  @moduledoc """
  A STATUS POTION ANTES DO ATAQUE — quando vale gastar 100ms limpando.

  "Meu pokémon pode estar sob efeito de status negativo antes de usar o auto
  combo (…) a tecla `e` usa o Status potion, que cura qualquer status negativo"
  (Lucas, 05/09). Dormindo, silenciado ou congelado, a corrente vira tecla
  morta: as skills não saem, a barra não gasta, e o bot insiste de quatro em
  quatro segundos contra uma mobada que continua batendo.

  ## Por que a limpeza é cega, e pode ser

  Nenhum leitor de tela reconhece status hoje, então não há como perguntar
  antes. Mas ele confirmou que a poção **não é consumida quando não há status**:
  o uso vira no-op e o item fica na bag. Isso tira o dinheiro da conta e deixa
  só o tempo — aí a resposta certa é limpar por profilaxia, sempre que o custo
  couber.

  ## Este módulo não aperta nada

  Ele responde SE vale apertar; quem aperta é o `Combat.Worker`, dentro da
  mesma rajada e depois de soltar as setas. Duas mãos apertando em paralelo é
  a corrida que já custou uma noite inteira (#480).
  """

  alias Pokex.Settings

  @typedoc "Com que frequência um modo de caça limpa — ver `Combat.Plan.cure_policy/1`."
  @type policy :: :always | :opening

  @doc "A tecla da Status Potion. `\"\"` é 'ele não configurou nenhuma'."
  @spec key() :: String.t()
  def key, do: Settings.get(:status_cure_key) |> to_string() |> String.trim()

  @doc "A limpeza está ligada?"
  @spec enabled?() :: boolean
  def enabled?, do: Settings.get(:status_cure_enabled) == true

  @doc """
  Quanto o jogo ganha pra aplicar a poção antes de a rajada sair.

  Zero é uma resposta legítima ("não precisa de respiro"), e é também o que sai
  de uma configuração corrompida: um respiro que não dá pra entender nunca vira
  uma espera indefinida no meio de uma luta.
  """
  @spec settle_ms() :: non_neg_integer
  def settle_ms do
    case Settings.get(:status_cure_settle_ms) do
      ms when is_integer(ms) and ms > 0 -> ms
      _sem_respiro -> 0
    end
  end

  @doc """
  Esta rajada merece uma limpeza na frente?

  `cured?` é "esta luta já foi limpa" — o worker o zera a cada engajamento, e
  ele só importa na política `:opening`.
  """
  @spec due?(policy, [String.t()], boolean) :: boolean
  def due?(policy, keys, cured?) do
    enabled?() and key() != "" and attack?(keys) and worth?(policy, cured?)
  end

  defp worth?(:always, _cured?), do: true
  defp worth?(:opening, cured?), do: not cured?
  defp worth?(_sem_politica, _cured?), do: false

  # MIRAR E TROCAR DE POSTURA NÃO É ATACAR. Nem o Tab nem o `shift+N` põem o
  # pokémon pra conjurar coisa alguma, e as duas coisas saem em rajada PRÓPRIA:
  # sem esta cerca a primeira poção da luta era gasta na troca de postura, e o
  # ataque que vinha logo atrás saía sem limpeza nenhuma.
  defp attack?(keys), do: Enum.any?(keys, &(&1 not in bystanders()))

  defp bystanders do
    Enum.map([:tab_key, :attack_mode_key, :defense_mode_key], fn key ->
      Settings.get(key) |> to_string() |> String.trim()
    end)
  end
end
