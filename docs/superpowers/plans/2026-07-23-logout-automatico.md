# Logout automático — plano de implementação

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Encerrar a sessão do jogo (Ctrl+Q + Enter, com confirmação pela tela) quando o bot fica ocioso ou bate uma meta, parando absolutamente tudo — porque parar o bot não economiza estamina, só deslogar economiza.

**Architecture:** Um GenServer `Pokex.Bots.Logout` (irmão do `Guardian`, filho direto da aplicação) dono do protocolo *travar latch → parar frota → trazer o jogo à frente → apertar → conferir a tela → tentar de novo*, com toda a decisão numa `Pokex.Bots.Logout.Logic` pura. O `Guardian` ganha o gatilho e um sinal de vida honesto (minigame vencido, não fisgada); o `ShinyGuard` para de arrastar o personagem quando o latch está travado.

**Tech Stack:** Elixir 1.19 / OTP, Phoenix LiveView, Phoenix.PubSub, ExUnit.

## Global Constraints

Estas regras valem para TODAS as tarefas. Violá-las é motivo de rejeição na revisão.

- **NUNCA suba um servidor de desenvolvimento.** Nada de `mix phx.server` ou `iex -S mix phx.server`. O Lucas tem uma instância rodando que compartilha `~/.pokex` e dirige o mouse real dele. Verificação é teste + render estático, só.
- **Nenhum teste toca a rede nem captura a tela de verdade.** Todo I/O externo entra por função injetada ou flag de ambiente.
- **Toda atuação (tecla/clique) passa pelo `Pokex.Bots.Body`**, atrás do `InputGate` + guarda de foco + canto do pânico. Nenhum módulo novo fala com o `Rig` direto.
- **Ajustes têm uma fonte única:** `@seed_settings` em `lib/pokex/settings.ex`. Nenhum padrão espalhado pelo código; leitura sempre por `Settings.get/1`.
- **Texto de interface e comentários de domínio em português; nomes de código em inglês.** É o padrão do repositório.
- **Toda instância global nova precisa de flag de ambiente para o teste**, no padrão de `:shiny_guard_active` / `:player_support_auto_monitor`: a instância do app não pode agir durante a suíte.
- **`Rig.Mac.gated/1` devolve `:ok` para chamadas suprimidas** — de propósito, e isso NÃO muda. Nenhum código novo pode tratar `:ok` do `Body` como prova de que a tecla chegou no jogo.
- **Mensagens de commit terminam com:** `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`
- Rode a suíte com `mix test`. O comando de lint do projeto é `mix lint`.

---

## Estrutura de arquivos

| arquivo | responsabilidade |
|---|---|
| `lib/pokex/bots/logout/logic.ex` **(criar)** | A decisão pura: tentar de novo, conferir de novo, terminar. Sem processo, relógio ou tela. |
| `lib/pokex/bots/logout.ex` **(criar)** | O GenServer: linha do tempo, efeitos (latch, parar frota, teclas, leitura), snapshot e broadcast. |
| `lib/pokex/bots/focus.ex` **(modificar)** | Ganha `ensure_front/0` público, extraído do `PlayerSupport`. |
| `lib/pokex/bots/player_support/worker.ex` **(modificar)** | Perde a privada `ensure_game_front/0`; passa a chamar `Focus.ensure_front/0`. |
| `lib/pokex/bots/shiny_guard.ex` **(modificar)** | Com o latch travado: nunca foge, sempre alarma. |
| `lib/pokex/bots/guardian.ex` **(modificar)** | Sinal de vida = kill + minigame vencido; ação `"deslogar"` nas duas regras. |
| `lib/pokex/settings.ex` **(modificar)** | Sete ajustes novos. |
| `lib/pokex/application.ex` **(modificar)** | `Pokex.Bots.Logout` na árvore. |
| `config/test.exs` **(modificar)** | `:logout_active` desligado no teste. |
| `lib/pokex_web/live/panel_live.ex` **(modificar)** | Botão manual, seletores de ação, resultado do último logout, `handle_info` pega-tudo. |

O `Logout` fica em `bots/logout.ex` com o diretório `bots/logout/` ao lado — o mesmo arranjo que `bots/capture.ex` + `bots/capture/` já usa.

---

## Task 1: `Logout.Logic` — a decisão, pura

**Files:**
- Create: `lib/pokex/bots/logout/logic.ex`
- Test: `test/pokex/bots/logout/logic_test.exs`

**Interfaces:**
- Consumes: nada de tarefas anteriores.
- Produces: `Pokex.Bots.Logout.Logic` com o struct `%Logic{state, reason, attempt, reads, confirms, config, error}` e três funções que a Task 3 chama:
  - `start(reason :: String.t(), config :: %{attempts: pos_integer()}) :: {t(), action()}`
  - `after_press(t(), :ok | {:error, term()}) :: {t(), action()}`
  - `after_read(t(), :gone | :present | :unreadable) :: {t(), action()}`
  - `reads_per_attempt() :: pos_integer()`
  - `action()` é `:press | :verify | {:finish, :out} | {:finish, {:failed, term()}}`
  - `state` percorre `:idle | :pressing | :verifying | :out | :failed`

- [ ] **Passo 1: escrever os testes que falham**

Crie `test/pokex/bots/logout/logic_test.exs`:

```elixir
defmodule Pokex.Bots.Logout.LogicTest do
  use ExUnit.Case, async: true

  alias Pokex.Bots.Logout.Logic

  @config %{attempts: 3}

  defp start, do: Logic.start("manual", @config)

  # Alimenta uma sequência de leituras, devolvendo {logic, ultima_acao}.
  defp read_all(logic, readings) do
    Enum.reduce(readings, {logic, :verify}, fn reading, {logic, _acao} ->
      Logic.after_read(logic, reading)
    end)
  end

  test "start pede a primeira tecla, na tentativa 1" do
    {logic, action} = start()

    assert action == :press
    assert logic.state == :pressing
    assert logic.attempt == 1
    assert logic.reason == "manual"
  end

  test "uma tecla que saiu manda conferir a tela" do
    {logic, _} = start()
    {logic, action} = Logic.after_press(logic, :ok)

    assert action == :verify
    assert logic.state == :verifying
    assert logic.reads == 0
    assert logic.confirms == 0
  end

  test "duas leituras :gone seguidas confirmam o logout" do
    {logic, _} = start()
    {logic, _} = Logic.after_press(logic, :ok)

    {logic, :verify} = Logic.after_read(logic, :gone)
    {logic, action} = Logic.after_read(logic, :gone)

    assert action == {:finish, :out}
    assert logic.state == :out
  end

  test "um :present entre dois :gone zera a contagem — não confirma" do
    {logic, _} = start()
    {logic, _} = Logic.after_press(logic, :ok)

    {logic, _} = Logic.after_read(logic, :gone)
    {logic, _} = Logic.after_read(logic, :present)
    {logic, action} = Logic.after_read(logic, :gone)

    assert action == :verify
    assert logic.confirms == 1
    assert logic.state == :verifying
  end

  test ":unreadable nunca confirma, por mais que se repita" do
    {logic, _} = start()
    {logic, _} = Logic.after_press(logic, :ok)

    {logic, action} = read_all(logic, List.duplicate(:unreadable, Logic.reads_per_attempt()))

    # esgotou as leituras da tentativa 1 e foi para a tentativa 2 — nunca :out
    assert action == :press
    assert logic.attempt == 2
    assert logic.confirms == 0
  end

  test "esgotar as leituras da tentativa começa uma tentativa nova" do
    {logic, _} = start()
    {logic, _} = Logic.after_press(logic, :ok)

    {logic, action} = read_all(logic, List.duplicate(:present, Logic.reads_per_attempt()))

    assert action == :press
    assert logic.state == :pressing
    assert logic.attempt == 2
    assert logic.reads == 0
  end

  test "esgotar as tentativas termina em falha, com o motivo" do
    logic =
      Enum.reduce(1..3, elem(start(), 0), fn _tentativa, logic ->
        {logic, _} = Logic.after_press(logic, :ok)
        {logic, _} = read_all(logic, List.duplicate(:present, Logic.reads_per_attempt()))
        logic
      end)

    assert logic.state == :failed
    assert logic.error == :ainda_logado
  end

  test "uma tecla que não saiu queima a tentativa e tenta de novo" do
    {logic, _} = start()
    {logic, action} = Logic.after_press(logic, {:error, :panic_corner})

    assert action == :press
    assert logic.attempt == 2
  end

  test "com uma tentativa só, uma tecla que não saiu já é falha" do
    {logic, _} = Logic.start("manual", %{attempts: 1})
    {logic, action} = Logic.after_press(logic, {:error, :panic_corner})

    assert action == {:finish, {:failed, :panic_corner}}
    assert logic.state == :failed
  end
end
```

- [ ] **Passo 2: rodar e ver falhar**

```bash
cd /Users/tavano/projects/pokex-logout && mix test test/pokex/bots/logout/logic_test.exs
```

Esperado: falha de compilação, `Pokex.Bots.Logout.Logic.start/2 is undefined (module Pokex.Bots.Logout.Logic is not available)`.

- [ ] **Passo 3: escrever a Logic**

Crie `lib/pokex/bots/logout/logic.ex`:

```elixir
defmodule Pokex.Bots.Logout.Logic do
  @moduledoc """
  A decisão do logout, sem nada em volta: sem processo, sem relógio, sem tela.
  Recebe o resultado de cada tecla e cada leitura da tela e devolve a próxima
  ação. Isso é o que permite testar o protocolo inteiro sem o jogo aberto.

  A regra que dá o tom: **toda ambiguidade resolve para "não deslogou"**. Uma
  leitura ilegível não confirma nada, e um logout que não confirmou termina em
  FALHA — que grita. Um "deslogado" falso é exatamente o prejuízo silencioso
  que essa feature existe para matar: o Lucas vai dormir achando que saiu, e a
  estamina queima a noite toda.

  Só uma leitura `:gone` DUAS VEZES SEGUIDAS confirma. Um glifo lido errado
  sozinho não consegue forjar um logout.
  """

  # Quantas leituras uma tentativa ganha antes de apertar as teclas de novo.
  # É um limite interno para o laço terminar, não uma escolha que o Lucas
  # queira fazer — por isso é atributo, não ajuste.
  @reads_per_attempt 4

  defstruct state: :idle,
            reason: nil,
            attempt: 0,
            reads: 0,
            confirms: 0,
            config: %{},
            error: nil

  @type reading :: :gone | :present | :unreadable
  @type action :: :press | :verify | {:finish, :out} | {:finish, {:failed, term()}}
  @type t :: %__MODULE__{}

  @doc "Quantas leituras cabem numa tentativa."
  @spec reads_per_attempt() :: pos_integer()
  def reads_per_attempt, do: @reads_per_attempt

  @doc "Começa um logout. A primeira ação é sempre apertar as teclas."
  @spec start(String.t(), %{attempts: pos_integer()}) :: {t(), action()}
  def start(reason, config) do
    {%__MODULE__{state: :pressing, reason: reason, attempt: 1, config: config}, :press}
  end

  @doc """
  O resultado da sequência de teclas. Uma falha de foco entra por aqui também:
  do ponto de vista da decisão, "não trouxe o jogo para a frente" e "a tecla não
  saiu" são o mesmo fato — a tecla não aconteceu.
  """
  @spec after_press(t(), :ok | {:error, term()}) :: {t(), action()}
  def after_press(%__MODULE__{} = logic, :ok),
    do: {%{logic | state: :verifying, reads: 0, confirms: 0}, :verify}

  def after_press(%__MODULE__{} = logic, {:error, reason}), do: retry(logic, reason)

  @doc "Uma leitura da tela."
  @spec after_read(t(), reading()) :: {t(), action()}
  def after_read(%__MODULE__{} = logic, :gone) do
    logic = %{logic | reads: logic.reads + 1, confirms: logic.confirms + 1}

    cond do
      logic.confirms >= 2 -> {%{logic | state: :out}, {:finish, :out}}
      logic.reads >= @reads_per_attempt -> retry(logic, :nao_confirmou)
      true -> {logic, :verify}
    end
  end

  def after_read(%__MODULE__{} = logic, reading) when reading in [:present, :unreadable] do
    logic = %{logic | reads: logic.reads + 1, confirms: 0}
    motivo = if reading == :present, do: :ainda_logado, else: :ilegivel

    if logic.reads >= @reads_per_attempt,
      do: retry(logic, motivo),
      else: {logic, :verify}
  end

  defp retry(logic, motivo) do
    if logic.attempt < Map.fetch!(logic.config, :attempts) do
      {%{logic | state: :pressing, attempt: logic.attempt + 1, reads: 0, confirms: 0}, :press}
    else
      {%{logic | state: :failed, error: motivo}, {:finish, {:failed, motivo}}}
    end
  end
end
```

- [ ] **Passo 4: rodar e ver passar**

```bash
cd /Users/tavano/projects/pokex-logout && mix test test/pokex/bots/logout/logic_test.exs
```

Esperado: `9 tests, 0 failures`.

- [ ] **Passo 5: commitar**

```bash
cd /Users/tavano/projects/pokex-logout && git add lib/pokex/bots/logout/logic.ex test/pokex/bots/logout/logic_test.exs && git commit -m "logout: a decisão pura — e ela sempre resolve pro 'não deslogou'

Duas leituras :gone seguidas confirmam; qualquer outra coisa zera a contagem.
Ilegível nunca confirma. Um 'deslogado' falso é o prejuízo silencioso que isso
existe pra matar, então a dúvida termina em falha, que grita.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 2: `Focus.ensure_front/0` — extração

**Files:**
- Modify: `lib/pokex/bots/focus.ex` (adiciona `ensure_front/0` público, logo depois de `front_game/0`)
- Modify: `lib/pokex/bots/player_support/worker.ex` (remove a privada `ensure_game_front/0`, linhas 143-168; troca a chamada na linha 126)
- Test: `test/pokex/bots/focus_test.exs` (acrescenta dois testes)

**Interfaces:**
- Consumes: nada de tarefas anteriores.
- Produces: `Pokex.Bots.Focus.ensure_front() :: :ok | {:error, :panic_corner}` — a Task 3 usa como `front_fun` padrão.

- [ ] **Passo 1: escrever os testes que falham**

Acrescente ao fim de `test/pokex/bots/focus_test.exs`, dentro do `describe` de nível superior ou como bloco novo:

```elixir
  describe "ensure_front/0" do
    setup do
      on_exit(fn ->
        Pokex.Bots.InputGate.set_corner_ok(true)
        Pokex.Bots.InputGate.set_focus_ok(true)
      end)

      :ok
    end

    test "recusa enquanto o cursor está no canto do pânico" do
      Pokex.Bots.InputGate.set_corner_ok(false)

      assert Pokex.Bots.Focus.ensure_front() == {:error, :panic_corner}
    end

    test "não faz nada quando o jogo já está na frente" do
      Pokex.Bots.InputGate.set_corner_ok(true)
      Pokex.Bots.InputGate.set_focus_ok(true)

      assert Pokex.Bots.Focus.ensure_front() == :ok
    end
  end
```

- [ ] **Passo 2: rodar e ver falhar**

```bash
cd /Users/tavano/projects/pokex-logout && mix test test/pokex/bots/focus_test.exs
```

Esperado: falha com `Pokex.Bots.Focus.ensure_front/0 is undefined or private`.

- [ ] **Passo 3: adicionar `ensure_front/0` ao `Focus`**

Em `lib/pokex/bots/focus.ex`, confirme que `alias Pokex.Bots.InputGate` está entre os aliases do módulo (adicione se não estiver) e insira, logo depois do `def front_game do ... end`:

```elixir
  @doc """
  Garante que o jogo pode receber uma sequência DELIBERADA de teclas: recusa se
  o canto do pânico está acionado (a ordem humana vence tudo), passa direto se o
  jogo já está na frente, e senão traz o jogo para a frente e abre a porteira
  na hora.

  Abrir a porteira aqui, em vez de esperar o poller notar, é o ponto: o poller
  levaria um tick, e nesse meio-tempo o Rig engoliria a tecla EM SILÊNCIO. Se o
  fronting falhar de verdade, o poller fecha a porteira de volta no tick
  seguinte e o Rig volta a engolir — a rede de segurança continua valendo.
  """
  @spec ensure_front() :: :ok | {:error, :panic_corner}
  def ensure_front do
    cond do
      not InputGate.state().corner_ok ->
        {:error, :panic_corner}

      InputGate.state().focus_ok ->
        :ok

      true ->
        front_game()
        Process.sleep(Settings.get(:calibration_front_delay_ms))
        InputGate.set_focus_ok(true)
        :ok
    end
  end
```

- [ ] **Passo 4: fazer o `PlayerSupport` usar a nova função**

Em `lib/pokex/bots/player_support/worker.ex`, apague o bloco de comentário e a função privada `ensure_game_front/0` inteira (o comentário que começa em "beat, and reflect reality on the gate NOW" até o `end` da função) e troque a chamada da linha 126:

```elixir
         :ok <- Pokex.Bots.Focus.ensure_front() do
```

- [ ] **Passo 5: rodar os testes de foco e de suporte**

```bash
cd /Users/tavano/projects/pokex-logout && mix test test/pokex/bots/focus_test.exs test/pokex/bots/player_support/
```

Esperado: tudo passando. Os testes existentes do `PlayerSupport` são a rede da extração — se algum quebrar, o comportamento mudou e a extração está errada.

- [ ] **Passo 6: commitar**

```bash
cd /Users/tavano/projects/pokex-logout && git add lib/pokex/bots/focus.ex lib/pokex/bots/player_support/worker.ex test/pokex/bots/focus_test.exs && git commit -m "focus: ensure_front sobe pro dono do foco

Estava privada no PlayerSupport e o logout precisa exatamente dela. Focus é
quem sabe de foco; é lá que ela mora. Comportamento idêntico — os testes do
PlayerSupport são a rede.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 3: O `Logout` — o protocolo

**Files:**
- Create: `lib/pokex/bots/logout.ex`
- Modify: `lib/pokex/settings.ex` (cinco ajustes novos, logo depois do bloco `escape_direction` / `escape_steps`)
- Modify: `lib/pokex/application.ex` (filho novo, logo depois de `Pokex.Bots.ShinyGuard`)
- Modify: `config/test.exs` (flag `:logout_active`)
- Test: `test/pokex/bots/logout_test.exs`

**Interfaces:**
- Consumes: `Logic.start/2`, `Logic.after_press/2`, `Logic.after_read/2`, `Logic.reads_per_attempt/0` (Task 1); `Focus.ensure_front/0` (Task 2).
- Produces:
  - `Pokex.Bots.Logout.request(reason :: String.t(), server \\ __MODULE__) :: :ok` — a Task 5 chama.
  - `Pokex.Bots.Logout.status(server \\ __MODULE__) :: map()` — a Task 6 chama.
  - `Pokex.Bots.Logout.topic() :: "logout"` — a Task 6 assina.
  - Broadcast `{:logout, snapshot}` no tópico `"logout"`, onde `snapshot` é
    `%{state: :idle | :pressing | :verifying | :out | :failed, reason: String.t() | nil, attempt: non_neg_integer(), attempts: pos_integer(), error: term() | nil, finished_at: integer() | nil, duplicates: non_neg_integer()}`.
  - Ajustes: `logout_key`, `logout_confirm_key`, `logout_confirm_delay_ms`, `logout_verify_delay_ms`, `logout_attempts`.

- [ ] **Passo 1: acrescentar os ajustes**

Em `lib/pokex/settings.ex`, dentro de `@seed_settings`, logo depois da linha `escape_steps: 2,`:

```elixir
    # Logout automático: encerrar a sessão de verdade, porque PARAR o bot não
    # economiza estamina — estamina queima enquanto o personagem está online.
    # A tecla é ajuste (e não constante) pelo mesmo motivo que defense_mode_key
    # é: o Lucas remapeia teclas no jogo. O padrão NUNCA é cmd+q, que no macOS
    # fecharia o cliente inteiro.
    logout_key: "ctrl+q",
    logout_confirm_key: "enter",
    logout_confirm_delay_ms: 300,
    # Tempo dado à tela para trocar antes da primeira conferência. Se a tela do
    # Lucas demorar mais, ele gasta uma tentativa à toa — ainda converge.
    logout_verify_delay_ms: 1_500,
    logout_attempts: 3,
```

- [ ] **Passo 2: escrever os testes que falham**

Crie `test/pokex/bots/logout_test.exs`:

```elixir
defmodule Pokex.Bots.LogoutTest do
  # async: false — mexe no latch global do InputGate, que outras suítes leem.
  use ExUnit.Case, async: false

  alias Pokex.Bots.{InputGate, Logout}

  setup do
    test = self()
    on_exit(fn -> InputGate.set_panic_latch(false) end)
    Phoenix.PubSub.subscribe(Pokex.PubSub, Logout.topic())
    Phoenix.PubSub.subscribe(Pokex.PubSub, "combat")

    {:ok, body} = start_supervised({Agent, fn -> %{reply: :ok, calls: []} end})

    perform = fn actions, priority ->
      Agent.get_and_update(body, fn s ->
        {s.reply, %{s | calls: s.calls ++ [{actions, priority}]}}
      end)
    end

    %{test: test, body: body, perform: perform}
  end

  defp calls(body), do: Agent.get(body, & &1.calls)

  # Sobe um Logout isolado (sem nome registrado) com tudo injetado.
  defp start_logout(ctx, opts) do
    test = ctx.test

    defaults = [
      name: nil,
      active: true,
      perform_fun: ctx.perform,
      stop_fun: fn -> send(test, :stopped) end,
      front_fun: fn -> :ok end
    ]

    {:ok, pid} = Logout.start_link(Keyword.merge(defaults, opts))
    pid
  end

  # Espera o processo chegar num estado terminal, sem depender de sleep fixo.
  defp await_state(pid, wanted, timeout \\ 2_000) do
    deadline = System.monotonic_time(:millisecond) + timeout

    poll = fn poll ->
      snap = Logout.status(pid)

      cond do
        snap.state == wanted -> snap
        System.monotonic_time(:millisecond) > deadline -> flunk("ficou em #{snap.state}, esperava #{wanted}")
        true -> Process.sleep(10) && poll.(poll)
      end
    end

    poll.(poll)
  end

  test "caminho feliz: trava o latch, para a frota, aperta na ordem e confirma", ctx do
    pid = start_logout(ctx, read_fun: fn -> :gone end)

    Logout.request("manual", pid)

    snap = await_state(pid, :out)
    assert snap.reason == "manual"
    assert_received :stopped
    assert InputGate.panic_latched?()

    assert [{actions, :critical}] = calls(ctx.body)
    assert [{:press, "ctrl+q"}, {:wait, 300}, {:press, "enter"}] = actions

    assert_receive {:logout, %{state: :out}}, 1_000
  end

  test "HUD que continua legível vira falha ruidosa depois das tentativas", ctx do
    pid = start_logout(ctx, read_fun: fn -> :present end, attempts_override: 2)

    Logout.request("estagnação", pid)

    snap = await_state(pid, :failed)
    assert snap.error == :ainda_logado
    assert snap.attempt == 2

    assert_receive {:rule_alarm, texto}, 1_000
    assert texto =~ "logout"
  end

  test "leitura sempre ilegível NUNCA reporta deslogado", ctx do
    pid = start_logout(ctx, read_fun: fn -> :unreadable end, attempts_override: 2)

    Logout.request("estagnação", pid)

    snap = await_state(pid, :failed)
    assert snap.error == :ilegivel
    refute snap.state == :out
  end

  test "um pedido durante um logout em voo é ignorado e contado", ctx do
    pid = start_logout(ctx, read_fun: fn -> :present end, attempts_override: 3)

    Logout.request("primeiro", pid)
    Logout.request("segundo", pid)
    Logout.request("terceiro", pid)

    snap = await_state(pid, :failed)
    assert snap.reason == "primeiro"
    assert snap.duplicates == 2
  end

  test "canto do pânico acionado: falha sem NUNCA tocar no Body", ctx do
    pid =
      start_logout(ctx,
        read_fun: fn -> :gone end,
        front_fun: fn -> {:error, :panic_corner} end,
        attempts_override: 2
      )

    Logout.request("manual", pid)

    snap = await_state(pid, :failed)
    assert snap.error == :panic_corner
    assert calls(ctx.body) == []
  end

  test "o latch continua travado depois de um logout bem-sucedido", ctx do
    pid = start_logout(ctx, read_fun: fn -> :gone end)

    Logout.request("manual", pid)
    await_state(pid, :out)

    assert InputGate.panic_latched?()
  end
end
```

- [ ] **Passo 3: rodar e ver falhar**

```bash
cd /Users/tavano/projects/pokex-logout && mix test test/pokex/bots/logout_test.exs
```

Esperado: falha de compilação, `Pokex.Bots.Logout.start_link/1 is undefined`.

- [ ] **Passo 4: escrever o `Logout`**

Crie `lib/pokex/bots/logout.ex`:

```elixir
defmodule Pokex.Bots.Logout do
  @moduledoc """
  Encerra a sessão do jogo de verdade: Ctrl+Q, Enter, e então CONFERE A TELA.

  Existe porque parar o bot não economiza estamina — estamina queima enquanto o
  personagem está online. Uma madrugada inteira da conta principal do Lucas foi
  embora com o minigame travado: o bot continuou fisgando, produziu zero peixe,
  e nada tinha autoridade para encerrar a sessão.

  ## Por que um processo próprio

  O ciclo apertar → esperar → conferir → tentar de novo leva segundos. Quem
  dispara é o `Guardian`, que precisa continuar checando o canto do pânico a
  cada 100ms. Bloquear o `Guardian` por cinco segundos deixaria o canto do
  pânico surdo por cinco segundos.

  ## Por que conferir a tela não é luxo

  Com o `InputGate` fechado, `Rig.Mac.gated/1` engole a tecla e devolve `:ok` —
  de propósito, para nenhum worker confundir "segurei por segurança" com
  "falhou". Foi exatamente assim que o cavebot morreu achando que tinha andado.
  Um logout que confia no `:ok` do `Body` tem o mesmo destino: reporta
  deslogado, o Lucas vai dormir, e a estamina queima a noite toda. A tela é a
  única testemunha honesta.

  A leitura sai do fato `:hud` do `WorldState`: deslogado é nível, comida E
  pesca pararem de dar número ao mesmo tempo. Um fato VELHO devolve
  `:unreadable`, nunca `:gone` — ler `World.snapshot()` seria errado aqui,
  porque ele devolve `nil` nos três campos tanto para "tela vazia" quanto para
  "o feed parou", e essa confusão inventaria um logout que não aconteceu.

  Quando a tela de seleção de personagem virar região calibrada, `read_fun`
  troca de uma checagem NEGATIVA ("a HUD sumiu") para uma POSITIVA ("vejo a
  lista de personagens"). O contrato `:gone | :present | :unreadable` não muda.
  """
  use GenServer
  require Logger

  alias Pokex.Bots.{Body, BotSupervisor, Focus, InputGate}
  alias Pokex.Bots.Logout.Logic
  alias Pokex.Perception
  alias Pokex.Perception.WorldState
  alias Pokex.Settings

  @topic "logout"
  @combat_topic "combat"
  # O feed :hud publica a cada 250-500ms; dois segundos já é "parou de chegar".
  @hud_max_age_ms 2_000
  # Intervalo entre as leituras DEPOIS da primeira (a primeira espera
  # logout_verify_delay_ms, que é o tempo da tela trocar).
  @read_gap_ms 400

  def topic, do: @topic

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)

    state = %{
      # Mesmo padrão de :shiny_guard_active — a instância do app não age durante
      # a suíte; instâncias de teste optam por entrar.
      active?: Keyword.get(opts, :active, Application.get_env(:pokex, :logout_active, true)),
      perform_fun: Keyword.get(opts, :perform_fun, &Body.perform(&1, &2)),
      stop_fun: Keyword.get(opts, :stop_fun, &BotSupervisor.stop_all/0),
      front_fun: Keyword.get(opts, :front_fun, &Focus.ensure_front/0),
      read_fun: Keyword.get(opts, :read_fun, &__MODULE__.read_hud/0),
      # sobrescreve logout_attempts — só os testes usam, para não esperar 3 ciclos
      attempts_override: Keyword.get(opts, :attempts_override),
      logic: nil,
      finished_at: nil,
      duplicates: 0
    }

    case name do
      nil -> GenServer.start_link(__MODULE__, state)
      name -> GenServer.start_link(__MODULE__, state, name: name)
    end
  end

  @doc """
  Pede um logout. Assíncrono de propósito: quem chama (o `Guardian`) não pode
  bloquear. Idempotente — um pedido com outro em voo é ignorado e contado em
  `duplicates`, o que importa porque o `Guardian` reavalia a condição a cada
  100ms.
  """
  @spec request(String.t(), GenServer.server()) :: :ok
  def request(reason, server \\ __MODULE__), do: GenServer.cast(server, {:request, reason})

  @doc "O snapshot que o painel desenha."
  @spec status(GenServer.server()) :: map()
  def status(server \\ __MODULE__), do: GenServer.call(server, :status)

  @doc false
  # A leitura padrão da tela. Pública para servir de `read_fun` padrão.
  @spec read_hud() :: Logic.reading()
  def read_hud do
    case WorldState.get(:hud, @hud_max_age_ms, System.monotonic_time(:millisecond)) do
      {:ok, %{level: nil, food: nil, fishing: nil}} -> :gone
      {:ok, _algum_numero} -> :present
      _sem_fato_fresco -> :unreadable
    end
  end

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call(:status, _from, state), do: {:reply, snapshot(state), state}

  @impl true
  def handle_cast({:request, _reason}, %{active?: false} = state), do: {:noreply, state}

  def handle_cast({:request, reason}, state) do
    if state.logic != nil and in_flight?(state.logic) do
      Logger.info("Logout: pedido '#{reason}' ignorado — já tem um em voo")
      {:noreply, %{state | duplicates: state.duplicates + 1}}
    else
      begin(state, reason)
    end
  end

  @impl true
  def handle_info(:press, state) do
    result =
      case state.front_fun.() do
        :ok -> press_keys(state)
        {:error, _reason} = error -> error
      end

    advance(Logic.after_press(state.logic, result), state)
  end

  def handle_info(:read, state), do: advance(Logic.after_read(state.logic, state.read_fun.()), state)

  def handle_info(_msg, state), do: {:noreply, state}

  # -- o protocolo -------------------------------------------------------------

  # LATCH PRIMEIRO, parar depois: o latch é o que proíbe todo caminho de
  # auto-retomada (a retomada do Focus ao reganhar foco) de religar workers por
  # cima desta ordem. Ele CONTINUA travado depois de um logout bem-sucedido —
  # só o Iniciar bot limpa.
  defp begin(state, reason) do
    InputGate.set_panic_latch(true)
    state.stop_fun.()
    attach_hud()

    Logic.start(reason, %{attempts: attempts(state)})
    |> advance(%{state | finished_at: nil})
  end

  # Guarda a decisão nova e só ENTÃO despacha o efeito. O broadcast sai daqui,
  # e só quando muda algo que a tela mostra — não a cada leitura. Uma tentativa
  # faz até quatro leituras; sem essa comparação o painel receberia quatro
  # mensagens idênticas por tentativa.
  defp advance({logic, action}, state), do: do_action(action, %{state | logic: logic})

  defp do_action(:press, state) do
    broadcast(state)
    # via mensagem, não direto: deixa o cast retornar antes de bloquear no Body
    send(self(), :press)
    {:noreply, state}
  end

  defp do_action(:verify, state) do
    # Primeira leitura da tentativa espera a tela trocar; as seguintes vão no
    # ritmo curto. Só a primeira muda o estado visível, então só ela publica.
    if state.logic.reads == 0 do
      broadcast(state)
      Process.send_after(self(), :read, Settings.get(:logout_verify_delay_ms))
    else
      Process.send_after(self(), :read, @read_gap_ms)
    end

    {:noreply, state}
  end

  defp do_action({:finish, :out}, state) do
    Logger.info("Logout: deslogado — #{state.logic.reason}")
    {:noreply, finish(state)}
  end

  defp do_action({:finish, {:failed, motivo}}, state) do
    texto = "logout FALHOU (#{motivo}) — #{state.logic.reason}"
    Logger.warning("Logout: #{texto}")
    Phoenix.PubSub.broadcast(Pokex.PubSub, @combat_topic, {:rule_alarm, "🚪 " <> texto})
    {:noreply, finish(state)}
  end

  defp finish(state) do
    detach_hud()
    state = %{state | finished_at: System.monotonic_time(:millisecond)}
    broadcast(state)
    state
  end

  # UMA sequência atômica em :critical — nada se intercala entre o Ctrl+Q e o
  # Enter. O :ok daqui NÃO prova que a tecla chegou no jogo; quem prova é a tela.
  defp press_keys(state) do
    state.perform_fun.(
      [
        {:press, Settings.get(:logout_key)},
        {:wait, Settings.get(:logout_confirm_delay_ms)},
        {:press, Settings.get(:logout_confirm_key)}
      ],
      :critical
    )
  end

  defp in_flight?(%Logic{state: state}), do: state in [:pressing, :verifying]

  defp attempts(state), do: state.attempts_override || Settings.get(:logout_attempts)

  # O feed :hud já tem consumidor permanente (os alertas de estoque), mas pedir
  # a própria demanda deixa este módulo independente desse detalhe.
  defp attach_hud do
    Perception.attach(:hud)
  catch
    _kind, _reason -> :ok
  end

  defp detach_hud do
    Perception.detach(:hud)
  catch
    _kind, _reason -> :ok
  end

  defp snapshot(state) do
    logic = state.logic || %Logic{}

    %{
      state: logic.state,
      reason: logic.reason,
      attempt: logic.attempt,
      attempts: attempts(state),
      error: logic.error,
      finished_at: state.finished_at,
      duplicates: state.duplicates
    }
  end

  defp broadcast(state),
    do: Phoenix.PubSub.broadcast(Pokex.PubSub, @topic, {:logout, snapshot(state)})
end
```

- [ ] **Passo 5: ligar na árvore da aplicação**

Em `lib/pokex/application.ex`, logo depois da linha `Pokex.Bots.ShinyGuard,`:

```elixir
      # Encerra a sessão de verdade quando uma regra manda (ociosidade, meta) ou
      # quando o Lucas aperta o botão. Depois do BotSupervisor porque para a frota.
      Pokex.Bots.Logout,
```

Em `config/test.exs`, junto das outras flags:

```elixir
config :pokex, :logout_active, false
```

- [ ] **Passo 6: rodar e ver passar**

```bash
cd /Users/tavano/projects/pokex-logout && mix test test/pokex/bots/logout_test.exs
```

Esperado: `6 tests, 0 failures`.

- [ ] **Passo 7: rodar a suíte inteira**

```bash
cd /Users/tavano/projects/pokex-logout && mix test
```

Esperado: zero falhas. Um filho novo na árvore da aplicação pode quebrar testes que contam filhos ou que sobem o app — se quebrar, conserte antes de commitar.

- [ ] **Passo 8: commitar**

```bash
cd /Users/tavano/projects/pokex-logout && git add lib/pokex/bots/logout.ex lib/pokex/settings.ex lib/pokex/application.ex config/test.exs test/pokex/bots/logout_test.exs && git commit -m "logout: o protocolo — e ele não acredita no :ok do Body

Latch primeiro, frota parada, jogo pra frente, Ctrl+Q + Enter numa sequência
atômica em :critical. E então confere a TELA, porque com o portão fechado o Rig
engole a tecla e responde :ok — foi assim que o cavebot morreu achando que
tinha andado.

Fato :hud velho responde :unreadable, nunca :gone. World.snapshot() daria nil
nos três campos tanto pra tela vazia quanto pra feed parado, e essa confusão
inventaria um logout que não aconteceu.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 4: `ShinyGuard` — com o latch travado, não foge

**Files:**
- Modify: `lib/pokex/bots/shiny_guard.ex` (a função privada `fire/2`, linhas 227-252)
- Test: `test/pokex/bots/shiny_guard_test.exs` (três testes novos)

**Interfaces:**
- Consumes: `InputGate.panic_latched?/0` (já existe).
- Produces: nada que outras tarefas consumam.

O buraco: o `ShinyGuard` é filho direto da aplicação, então `stop_all/0` não o alcança. Ele não aperta tecla — ele chama `emergency_escape/1`, que traz o jogo para a frente de propósito e anda o personagem até a escada. O canto do pânico só o veta enquanto o mouse está lá.

- [ ] **Passo 1: escrever os testes que falham**

Acrescente ao fim de `test/pokex/bots/shiny_guard_test.exs`, **antes** do `end` do módulo. O arquivo já tem tudo o que estes testes usam: o `setup` sobe um guarda isolado com `escape_fun` que manda `{:escaped, reason}` para o teste, `shiny_obs/1` monta a observação, e `world_broadcast/1` entrega pelo PubSub exatamente como o Feed faz — **nunca** mande a mensagem direto para o processo, porque um guarda não-inscrito passaria no teste e ficaria surdo em produção (foi um bug real).

```elixir
  describe "parada em vigor (latch travado)" do
    setup do
      on_exit(fn -> Pokex.Bots.InputGate.set_panic_latch(false) end)
      :ok
    end

    @tag :tmp_dir
    test "com o latch travado e ação fugir, NÃO foge" do
      SettingsStash.stash!(shiny_action: "fugir")
      Pokex.Bots.InputGate.set_panic_latch(true)

      world_broadcast(shiny_obs())

      refute_receive {:escaped, _}, 500
    end

    @tag :tmp_dir
    test "com o latch travado, o alarme SAI mesmo assim" do
      Phoenix.PubSub.subscribe(Pokex.PubSub, "combat")
      SettingsStash.stash!(shiny_action: "fugir")
      Pokex.Bots.InputGate.set_panic_latch(true)

      world_broadcast(shiny_obs())

      assert_receive {:rule_alarm, reason}, 1_000
      assert reason =~ "SHINY na lista de batalha"
      assert reason =~ "decida você"
    end

    @tag :tmp_dir
    test "com o latch LIVRE e ação fugir, foge — sem regressão" do
      SettingsStash.stash!(shiny_action: "fugir")
      Pokex.Bots.InputGate.set_panic_latch(false)

      world_broadcast(shiny_obs())

      assert_receive {:escaped, reason}, 1_000
      assert reason =~ "SHINY na lista de batalha"
    end
  end
```

- [ ] **Passo 2: rodar e ver falhar**

```bash
cd /Users/tavano/projects/pokex-logout && mix test test/pokex/bots/shiny_guard_test.exs
```

Esperado: o primeiro teste falha — `escape_fun` é chamado mesmo com o latch travado.

- [ ] **Passo 3: implementar a regra**

Em `lib/pokex/bots/shiny_guard.ex`, adicione `alias Pokex.Bots.InputGate` aos aliases e troque a cláusula `"fugir"` de `fire/2` por:

```elixir
      "fugir" ->
        # O latch é a ordem de parada (canto do pânico, logout, meta batida).
        # Com ele travado o guarda NÃO atua — mas continua gritando: quando o
        # Lucas vai pro canto pra jogar na mão, ele QUER saber que apareceu uma
        # shiny; o que ele não quer é o bot arrastando o personagem pra escada
        # enquanto ele joga. Sem isso, uma shiny avistada move o personagem com
        # tudo "parado", porque o ShinyGuard é filho da aplicação e stop_all/0
        # não o alcança.
        if InputGate.panic_latched?() do
          Logger.warning("ShinyGuard: #{reason} — parada em vigor, NÃO foge; só avisa")

          Phoenix.PubSub.broadcast(
            Pokex.PubSub,
            @combat_topic,
            {:rule_alarm, reason <> " — bot parado, decida você"}
          )
        else
          Logger.warning("ShinyGuard: #{reason} — fugindo pela escada")
          state.escape_fun.(reason)
          ShinyLog.resolve_last("fugiu")
        end
```

O registro no `ShinyLog` fica com o desfecho `"visto"` que `record/1` já gravou — não houve fuga para resolver.

- [ ] **Passo 4: rodar e ver passar**

```bash
cd /Users/tavano/projects/pokex-logout && mix test test/pokex/bots/shiny_guard_test.exs
```

Esperado: todos passando, incluindo os que já existiam.

- [ ] **Passo 5: commitar**

```bash
cd /Users/tavano/projects/pokex-logout && git add lib/pokex/bots/shiny_guard.ex test/pokex/bots/shiny_guard_test.exs && git commit -m "shiny: com parada em vigor ele avisa, mas não arrasta o personagem

O ShinyGuard é filho da aplicação — stop_all não o alcança. Ele não aperta
tecla: chama a fuga, que traz o jogo pra frente de propósito e anda até a
escada. O canto do pânico só o vetava enquanto o mouse estava lá, então bastava
tirar o mouse pra uma shiny mover o personagem com tudo 'parado'.

O alarme continua saindo de propósito: no canto o Lucas quer saber da shiny, só
não quer o bot decidindo por ele.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 5: `Guardian` — sinal de vida honesto e a ação de deslogar

**Files:**
- Modify: `lib/pokex/bots/guardian.ex`
- Modify: `lib/pokex/settings.ex` (`stop_after_action` novo; comentário de `stagnation_action` atualizado)
- Test: `test/pokex/bots/guardian_test.exs`

**Interfaces:**
- Consumes: `Pokex.Bots.Logout.request/2` (Task 3).
- Produces: opção `:logout_fun` em `Guardian.start_link/1`, com padrão `&Pokex.Bots.Logout.request/1`.

O ponto central: hoje o `Guardian` conta `hooked` — o puxão da vara, não o peixe. Com o minigame travado o contador sobe a noite inteira e a regra nunca dispara. Foi exatamente assim que a madrugada foi embora.

- [ ] **Passo 1: acrescentar o ajuste**

Em `lib/pokex/settings.ex`, logo depois de `stop_after_kills: 0,`:

```elixir
    # O que fazer ao bater uma meta de sessão: "parar" trava tudo como o Stop;
    # "deslogar" encerra a conta, que é o que de fato economiza estamina.
    stop_after_action: "parar",
```

E troque o comentário de `stagnation_minutes` / `stagnation_action` por:

```elixir
    # Anti-estagnação (Ações & Regras): uma sessão ATIVA sem nenhum sinal de
    # vida por esta janela é um bot travado. Sinal de vida é kill + MINIGAME
    # VENCIDO — não fisgada: com o minigame travado a vara fisga a noite toda
    # sem pegar peixe nenhum, e foi assim que uma madrugada de estamina foi
    # embora. A fisgada só volta a valer com o vigia do minigame desligado.
    # 0 = desligado. "alarme" re-toca a cada janela de silêncio; "parar" trava
    # tudo; "deslogar" encerra a conta.
    stagnation_minutes: 0,
    stagnation_action: "alarme",
```

- [ ] **Passo 2: escrever os testes que falham**

Acrescente ao fim de `test/pokex/bots/guardian_test.exs`, **antes** do `end` do módulo. O arquivo já define `active_session!/1` (planta o fato `:session` com a idade pedida em ms) e `FakeBody.start_link/1`; o `setup` de nível superior entrega `%{on_panic: on_panic}`, que manda `:panicked` para o teste. O helper local abaixo é `start_guardian!/1` mais o `logout_fun` injetado — dê a ele um nome próprio para não colidir com o que já existe no arquivo.

```elixir
  describe "sinal de vida e ação de deslogar" do
    setup do
      on_exit(fn ->
        Pokex.Perception.WorldState.forget(:session)
        Pokex.Settings.put(:stagnation_minutes, 0)
        Pokex.Settings.put(:stagnation_action, "alarme")
        Pokex.Settings.put(:stop_after_action, "parar")
        Pokex.Settings.put(:stop_after_minutes, 0)
        Pokex.Settings.put(:stop_after_kills, 0)
        Pokex.Bots.InputGate.set_panic_latch(false)
      end)

      :ok
    end

    defp start_guardian_com_logout!(on_panic, logout_fun) do
      {:ok, body} = FakeBody.start_link({:ok, {500, 500}})

      {:ok, guardian} =
        Guardian.start_link(
          name: nil,
          body: body,
          on_panic: on_panic,
          poll_ms: 5,
          session_rules: true,
          logout_fun: logout_fun
        )

      guardian
    end

    test "estagnação com ação deslogar chama o logout, com o motivo", %{on_panic: on_panic} do
      test = self()
      active_session!(61_000)
      Pokex.Settings.put(:stagnation_minutes, 1)
      Pokex.Settings.put(:stagnation_action, "deslogar")

      start_guardian_com_logout!(on_panic, fn motivo -> send(test, {:deslogou, motivo}) end)

      assert_receive {:deslogou, motivo}, 1_000
      assert motivo =~ "estagnação"
      # o Logout trava o latch e para a frota por conta própria — o Guardian não duplica
      refute_receive :panicked, 100
    end

    test "meta de kills com ação deslogar chama o logout", %{on_panic: on_panic} do
      test = self()
      active_session!(0)
      Pokex.Settings.put(:stop_after_kills, 2)
      Pokex.Settings.put(:stop_after_action, "deslogar")

      guardian = start_guardian_com_logout!(on_panic, fn motivo -> send(test, {:deslogou, motivo}) end)
      send(guardian, {:combat, %{state: :hunting, counters: %{fights: 2}, error: nil}})

      assert_receive {:deslogou, motivo}, 1_000
      assert motivo =~ "meta de kills atingida"
    end

    test "meta de kills com ação parar continua parando como sempre", %{on_panic: on_panic} do
      active_session!(0)
      Pokex.Settings.put(:stop_after_kills, 2)
      Pokex.Settings.put(:stop_after_action, "parar")

      guardian = start_guardian_com_logout!(on_panic, fn _motivo -> flunk("não devia deslogar") end)
      send(guardian, {:combat, %{state: :hunting, counters: %{fights: 2}, error: nil}})

      assert_receive :panicked, 1_000
    end

    test "um minigame VENCIDO zera o relógio da estagnação", %{on_panic: on_panic} do
      active_session!(61_000)
      Pokex.Settings.put(:stagnation_minutes, 1)
      Pokex.Settings.put(:stagnation_action, "parar")

      guardian = start_guardian_com_logout!(on_panic, fn _motivo -> :ok end)
      send(guardian, {:mini_game, %{state: :watching, counters: %{clears: 1}}})

      refute_receive :panicked, 400
    end

    test "com o vigia do minigame PARADO, uma fisgada zera o relógio", %{on_panic: on_panic} do
      active_session!(61_000)
      Pokex.Settings.put(:stagnation_minutes, 1)
      Pokex.Settings.put(:stagnation_action, "parar")

      guardian = start_guardian_com_logout!(on_panic, fn _motivo -> :ok end)
      send(guardian, {:mini_game, %{state: :off, counters: %{clears: 0}}})
      send(guardian, {:fishing, %{counters: %{hooked: 1}}})

      refute_receive :panicked, 400
    end

    test "com o vigia do minigame RODANDO, uma fisgada NÃO zera o relógio", %{on_panic: on_panic} do
      active_session!(61_000)
      Pokex.Settings.put(:stagnation_minutes, 1)
      Pokex.Settings.put(:stagnation_action, "parar")

      guardian = start_guardian_com_logout!(on_panic, fn _motivo -> :ok end)
      send(guardian, {:mini_game, %{state: :watching, counters: %{clears: 0}}})
      send(guardian, {:fishing, %{counters: %{hooked: 1}}})

      # este é O teste da madrugada perdida: a vara fisgando sem o minigame
      # vencer NÃO é sinal de vida, e a regra tem que disparar mesmo assim
      assert_receive :panicked, 1_000
    end
  end
```

- [ ] **Passo 3: rodar e ver falhar**

```bash
cd /Users/tavano/projects/pokex-logout && mix test test/pokex/bots/guardian_test.exs
```

Esperado: falha com `unknown key :logout_fun` ou equivalente — a opção ainda não existe.

- [ ] **Passo 4: implementar no `Guardian`**

Em `lib/pokex/bots/guardian.ex`:

**(a)** No `start_link/1`, acrescente ao mapa `state`:

```elixir
      logout_fun: Keyword.get(opts, :logout_fun, &Pokex.Bots.Logout.request/1),
      clears: 0,
      # o vigia do minigame está rodando? Enquanto nunca ouvimos falar dele,
      # assumimos que NÃO — o padrão seguro, porque é ele que faz a fisgada
      # voltar a contar como sinal de vida.
      mini_game_running?: false,
```

**(b)** No `init/1`, assine o tópico do minigame junto dos outros:

```elixir
    Phoenix.PubSub.subscribe(Pokex.PubSub, Pokex.Bots.MiniGame.Worker.topic())
```

**(c)** Troque a cláusula de pesca e acrescente a do minigame:

```elixir
  # Uma FISGADA é o puxão da vara, não o peixe. Com o vigia do minigame rodando,
  # o peixe de verdade é o `clears`: um minigame travado fisga a noite inteira e
  # pega nada — foi exatamente assim que uma madrugada de estamina foi embora.
  # Com o vigia desligado (o Lucas jogando o minigame na mão) a fisgada volta a
  # ser o melhor sinal que temos; sem esse recuo, a regra deslogaria ele no meio
  # de uma pescaria que ia bem.
  def handle_info({:fishing, snapshot}, state) do
    hooked = get_in(snapshot, [:counters, :hooked])

    if state.mini_game_running?,
      do: {:noreply, store_counter(state, :hooked, hooked)},
      else: {:noreply, track_counter(state, :hooked, hooked)}
  end

  def handle_info({:mini_game, snapshot}, state) do
    state = %{state | mini_game_running?: Map.get(snapshot, :state) != :off}
    {:noreply, track_counter(state, :clears, get_in(snapshot, [:counters, :clears]))}
  end
```

**(d)** Acrescente o `store_counter/3` ao lado do `track_counter/3` existente:

```elixir
  # Guarda o contador SEM marcar atividade. Existe para que desligar o vigia do
  # minigame no meio de uma sessão não faça o salto acumulado de fisgadas passar
  # por um sinal de vida que nunca houve.
  defp store_counter(state, key, value) when is_integer(value), do: Map.put(state, key, value)
  defp store_counter(state, _key, _value), do: state
```

**(e)** Em `check_session_limits/1`, troque as duas chamadas `session_stop(state, ...)` das metas por `session_end(state, ...)` e acrescente:

```elixir
  # Uma meta batida encerra a sessão. "parar" trava tudo como sempre;
  # "deslogar" encerra a conta, que é o que de fato economiza estamina.
  defp session_end(state, reason) do
    case Settings.get(:stop_after_action) do
      "deslogar" -> state.logout_fun.(reason)
      _parar -> session_stop(state, reason)
    end
  end
```

**(f)** Em `check_stagnation/3`, acrescente a cláusula `"deslogar"` ao `case`:

```elixir
      case Settings.get(:stagnation_action) do
        "parar" ->
          session_stop(state, reason)
          state

        "deslogar" ->
          Logger.info("Guardian: #{reason} — deslogando")
          state.logout_fun.(reason)
          state

        _alarme ->
          Logger.info("Guardian: #{reason}")
          Phoenix.PubSub.broadcast(Pokex.PubSub, @combat_topic, {:rule_alarm, reason})
          %{state | last_activity_at: now}
      end
```

O `Logout` trava o latch e para a frota por conta própria — o `Guardian` não duplica nenhum dos dois.

**(g)** Atualize o `@moduledoc` para dizer que o sinal de vida é kill + minigame vencido e que a ação pode ser deslogar.

- [ ] **Passo 5: rodar e ver passar**

```bash
cd /Users/tavano/projects/pokex-logout && mix test test/pokex/bots/guardian_test.exs
```

Esperado: todos passando, incluindo os que já existiam.

- [ ] **Passo 6: rodar a suíte inteira**

```bash
cd /Users/tavano/projects/pokex-logout && mix test
```

Esperado: zero falhas.

- [ ] **Passo 7: commitar**

```bash
cd /Users/tavano/projects/pokex-logout && git add lib/pokex/bots/guardian.ex lib/pokex/settings.ex test/pokex/bots/guardian_test.exs && git commit -m "guardian: o sinal de vida era mentira — fisgada não é peixe

A regra anti-estagnação media 'hooked', que é o puxão da vara. Com o minigame
travado o contador sobe a noite inteira e a regra nunca dispara: o bot tinha
sinal de vida de sobra e resultado zero. Foi exatamente esse o prejuízo.

Agora o peixe é o minigame VENCIDO. A fisgada só volta a valer com o vigia do
minigame desligado — senão a regra deslogaria ele no meio de uma pescaria na
mão que ia bem. E as duas regras ganham a ação de deslogar.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 6: Painel — o botão, as ações e o resultado

**Files:**
- Modify: `lib/pokex_web/live/panel_live.ex`
- Test: `test/pokex_web/live/panel_live_test.exs`

**Interfaces:**
- Consumes: `Logout.request/2`, `Logout.status/1`, `Logout.topic/0`, e o broadcast `{:logout, snapshot}` (Task 3); o ajuste `stop_after_action` (Task 5).
- Produces: nada que outras tarefas consumam.

**LEIA ISTO ANTES DE COMEÇAR — o alvo mudou depois que o plano foi escrito.**

O PR #86 foi mergeado no `main` durante a execução deste plano. Ele mexeu **+191 linhas** em `panel_live.ex` e, entre outras coisas, **já adicionou o `handle_info` pega-tudo** que este plano mandava criar. Duas consequências, as duas obrigatórias:

1. **Sua PRIMEIRA ação é trazer o `main` para a branch** (Passo 0 abaixo). As tarefas 1 a 5 não tocam em `panel_live.ex`, então a fusão deve ser limpa; se houver conflito, resolva mantendo AS DUAS mudanças.
2. **NÃO crie um segundo pega-tudo.** Ele já existe (`def handle_info(_msg, socket), do: {:noreply, socket}`). Uma segunda cláusula genérica seria inalcançável, o compilador avisa, e `mix lint` reprova. Sua cláusula `{:logout, snapshot}` tem que ficar **ANTES** dele.

Os números de linha citados nos passos abaixo são da versão ANTIGA do arquivo e não valem mais. Localize os pontos pelo nome da função e pelo `id` do elemento, nunca pela linha.

- [ ] **Passo 0: trazer o main para a branch**

```bash
cd /Users/tavano/projects/pokex-logout && git status --short && git fetch origin && git merge origin/main
```

Esperado: árvore limpa antes da fusão, e uma fusão sem conflito. Depois:

```bash
cd /Users/tavano/projects/pokex-logout && mix test
```

Esperado: zero falhas. Se algum teste das tarefas 1-5 quebrar com a fusão, conserte antes de seguir — é uma interação real entre as duas linhas de trabalho, não ruído.

- [ ] **Passo 1: escrever os testes que falham**

Acrescente a `test/pokex_web/live/panel_live_test.exs`:

```elixir
  describe "logout" do
    test "o botão 'Deslogar agora' existe e é clicável", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, ~s(button[phx-click="logout_now"]))

      # não deve derrubar a LiveView, mesmo com o Logout global inerte no teste
      render_click(view, "logout_now")
      assert render(view) =~ "Deslogar"
    end

    test "uma mensagem de logout inesperada não derruba a página", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      send(view.pid, {:logout, %{state: :out, reason: "manual", attempt: 1, attempts: 3, error: nil, finished_at: 1, duplicates: 0}})
      assert render(view) =~ "deslogado"

      # e qualquer coisa desconhecida no mesmo tópico também não
      send(view.pid, {:mensagem_que_ninguem_espera, 42})
      assert render(view)
    end

    test "o seletor da estagnação oferece deslogar", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, ~s(select#stagnation-action option[value="deslogar"]))
    end

    test "o seletor das metas de sessão oferece deslogar", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, ~s(select#stop-after-action option[value="deslogar"]))
    end
  end
```

- [ ] **Passo 2: rodar e ver falhar**

```bash
cd /Users/tavano/projects/pokex-logout && mix test test/pokex_web/live/panel_live_test.exs
```

Esperado: falhas nos quatro — o botão e os seletores não existem.

- [ ] **Passo 3: assinar o tópico e acrescentar o pega-tudo**

Em `lib/pokex_web/live/panel_live.ex`, no `mount/3`, junto das outras assinaturas:

```elixir
      Phoenix.PubSub.subscribe(Pokex.PubSub, Pokex.Bots.Logout.topic())
```

Nos assigns do `mount/3`, junto de `stagnation_action`:

```elixir
       stop_after_action: Settings.get(:stop_after_action),
       logout: safe_logout_status(),
```

E a leitura defensiva, junto dos outros helpers privados (o `Logout` global fica inerte no teste, e um `GenServer.call` para um processo ausente não pode derrubar o mount):

```elixir
  defp safe_logout_status do
    Pokex.Bots.Logout.status()
  catch
    :exit, _reason ->
      %{state: :idle, reason: nil, attempt: 0, attempts: 0, error: nil, finished_at: nil, duplicates: 0}
  end
```

Acrescente a cláusula do logout junto das outras `handle_info`, **imediatamente antes** da cláusula pega-tudo que já existe:

```elixir
  def handle_info({:logout, snapshot}, socket), do: {:noreply, assign(socket, logout: snapshot)}
```

Confirme que o pega-tudo continua sendo a ÚLTIMA cláusula de `handle_info` do módulo:

```bash
cd /Users/tavano/projects/pokex-logout && grep -n "def handle_info(_" lib/pokex_web/live/panel_live.ex
```

Esperado: **exatamente uma** linha. Se aparecerem duas, você criou uma duplicata — apague a sua. Se a cláusula genérica não for a última do módulo, mova-a para o fim: qualquer `handle_info` depois dela é código morto que o compilador vai denunciar.

- [ ] **Passo 4: o botão e o evento**

Junto dos outros `handle_event` do módulo:

```elixir
  def handle_event("logout_now", _params, socket) do
    safe_logout_request()
    {:noreply, socket}
  end
```

E o helper, junto de `safe_logout_status/0`:

```elixir
  defp safe_logout_request do
    Pokex.Bots.Logout.request("manual (painel)")
  catch
    :exit, _reason -> :ok
  end
```

- [ ] **Passo 5: a marcação**

Em `lib/pokex_web/live/panel_live.ex`, dentro da seção de Ações & Regras:

**(a)** No `form#stop-conditions-form`, depois do `<span>kills (0 = nunca)</span>`:

```heex
              <span>→</span>
              <select
                id="stop-after-action"
                name="stop_after_action"
                class="h-6 rounded border border-pk-line-strong bg-pk-bg px-1 font-mono text-pk-meta text-pk-text focus:border-pk-ok focus:outline-none"
              >
                <option value="parar" selected={@stop_after_action == "parar"}>parar tudo</option>
                <option value="deslogar" selected={@stop_after_action == "deslogar"}>deslogar</option>
              </select>
```

**(b)** No `select#stagnation-action`, depois da opção `parar`:

```heex
                <option value="deslogar" selected={@stagnation_action == "deslogar"}>deslogar</option>
```

**(c)** Depois do `form#stagnation-form`, o botão e o resultado:

```heex
            <div class="mt-1 flex items-center gap-2 px-0.5">
              <button
                type="button"
                phx-click="logout_now"
                title="Encerra a sessão no jogo (Ctrl+Q + Enter), para tudo e confere na tela se saiu mesmo. Parar o bot não economiza estamina; deslogar economiza."
                class="h-6 rounded border border-pk-line-strong px-2 font-mono text-pk-meta text-pk-text-2 hover:border-pk-warn hover:text-pk-warn focus:outline-none focus-visible:outline focus-visible:outline-2 focus-visible:outline-pk-warn"
              >
                🚪 Deslogar agora
              </button>
              <span class="truncate font-mono text-pk-meta text-pk-text-3">
                {logout_label(@logout)}
              </span>
            </div>
```

**(d)** O rótulo, junto das outras funções de rótulo privadas:

```elixir
  # O painel nunca diz "deslogado" por omissão: cada estado tem seu texto, e a
  # falha diz POR QUE falhou.
  defp logout_label(%{state: :idle}), do: "nenhum logout ainda"
  defp logout_label(%{state: :pressing, attempt: n, attempts: total}),
    do: "apertando… tentativa #{n}/#{total}"

  defp logout_label(%{state: :verifying, attempt: n, attempts: total}),
    do: "conferindo a tela… tentativa #{n}/#{total}"

  defp logout_label(%{state: :out, reason: motivo}), do: "deslogado — #{motivo}"

  defp logout_label(%{state: :failed, error: erro, reason: motivo}),
    do: "FALHOU (#{erro}) — #{motivo}"

  defp logout_label(_desconhecido), do: "—"
```

**(e)** No `handle_event("save_stop_conditions", ...)`, guarde a ação nova junto dos dois inteiros:

```elixir
    socket =
      case params["stop_after_action"] do
        action when action in ["parar", "deslogar"] ->
          Settings.put(:stop_after_action, action)
          assign(socket, stop_after_action: action)

        _ ->
          socket
      end
```

**(f)** No `handle_event("save_stagnation", ...)` (linha 527), o `case` hoje aceita só duas ações e descarta em silêncio qualquer outra — a opção nova do `<select>` nunca seria salva. Troque a linha do guard:

```elixir
        action when action in ["alarme", "parar"] ->
```

por:

```elixir
        action when action in ["alarme", "parar", "deslogar"] ->
```

- [ ] **Passo 6: rodar e ver passar**

```bash
cd /Users/tavano/projects/pokex-logout && mix test test/pokex_web/live/panel_live_test.exs
```

Esperado: `0 failures`.

- [ ] **Passo 7: rodar a suíte inteira e o lint**

```bash
cd /Users/tavano/projects/pokex-logout && mix test && mix lint
```

Esperado: zero falhas e lint limpo. **Não** rode `mix phx.server`.

- [ ] **Passo 8: commitar**

```bash
cd /Users/tavano/projects/pokex-logout && git add lib/pokex_web/live/panel_live.ex test/pokex_web/live/panel_live_test.exs && git commit -m "painel: botão de deslogar, as duas ações novas, e um pega-tudo que faltava

O painel assinava dez tópicos sem nenhuma cláusula genérica de handle_info: a
primeira mensagem {:logout, _} derrubaria a página. Justo no momento do logout,
que é quando ele mais precisa ver o que aconteceu.

O botão manual existe pra provar o mecanismo ao vivo sem esperar cinco minutos
de ociosidade.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Verificação final

- [ ] `mix test` — zero falhas
- [ ] `mix lint` — limpo
- [ ] `git log --oneline origin/main..HEAD` — seis commits, um por tarefa
- [ ] Confira que **nenhum** teste novo chama `mix phx.server`, abre socket de rede ou captura a tela de verdade
- [ ] Confira que `Rig.Mac.gated/1` continua intocado

## O que fica pendente de propósito

- **Validação ao vivo.** Nada disso foi visto funcionando no jogo real. O botão "Deslogar agora" existe exatamente para essa primeira prova, e ela é do Lucas.
- **A tela de seleção de personagem como região calibrada.** Viraria uma confirmação POSITIVA ("vejo a lista de personagens") no lugar da negativa atual ("a HUD sumiu"). Só a implementação de `read_fun` muda.
- **`logout_verify_delay_ms: 1500` é estimativa.** Se a tela do Lucas demorar mais, ele gasta uma tentativa à toa — ainda converge, e o número é ajuste no painel.
