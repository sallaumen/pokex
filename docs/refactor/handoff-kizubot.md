# KizuBot -> Pokex: handoff não-prescritivo para Codex Sol

> Data: 20 de julho de 2026
> Repositório analisado: `sallaumen/pokex`
> Fora do escopo: CAPTCHA bypass, anti-detecção, evasão de GM/moderação e contorno de mecanismos de segurança.
>
> _Versionado no repo em 2026-07-20 (colado pelo Lucas no chat) para que qualquer sessão de IA — Codex Sol ou Claude — trabalhe do mesmo roteiro. A Fase 0 está executada em [fase-0-inventario.md](fase-0-inventario.md)._

## Objetivo

Usar as capacidades públicas do KizuBot como referência de produto para evoluir o Pokex, **sem impor uma nova arquitetura**.

O Codex deve tratar o repositório como fonte de verdade. Ele deve preservar nomes, processos e padrões atuais sempre que forem suficientes, e tomar decisões arquiteturais somente depois de rastrear o fluxo relacionado à feature.

## Fatos atuais que não devem ser ignorados

- `Pokex.Bots.Body` já serializa sequências compartilhadas de input com prioridades `:critical`, `:high` e `:normal`.
- `Pokex.Bots.InputGate` já bloqueia atuação quando foco/panic não permitem.
- `Pokex.Perception.WorldState` já é um blackboard ETS com controle de freshness.
- `Pokex.Perception` já possui feeds demand-driven e compartilhamento por PubSub/WorldState.
- Fishing, Catcher e Combat já usam módulos de lógica e workers, embora com decisões de atuação diferentes.
- O caminho direto de teclado do Combat é intencional no código atual; não deve ser removido sem analisar latência, atomicidade e segurança.
- A aplicação já tem `PanelLive`, `DiagnosticsLive`, `CalibrationLive`, `FishingLabLive` e `WorldLive`.

## Regras para o Codex

1. Leia o fluxo atual antes de propor mudanças.
2. Não crie uma arquitetura-alvo nem renomeie o projeto para combinar com este relatório.
3. Não crie `TaskArbiter`, `InputExecutor`, `EventBus` ou outro módulo genérico apenas porque o nome parece adequado.
4. Antes de adicionar um processo, explique por que a feature exige ciclo de vida independente.
5. Antes de extrair uma abstração, mostre a duplicação, conflito ou limitação concreta que ela resolve.
6. Prefira uma fatia funcional pequena e completa a uma refatoração horizontal.
7. Reutilize as proteções atuais de Body, Rig, InputGate, Guardian e Focus.
8. Reutilize WorldState, feeds e PubSub quando forem adequados, sem transformá-los em regra universal.
9. Atualize as LiveViews existentes antes de criar novas superfícies paralelas.
10. Não implemente funcionalidades futuras durante uma fase atual.

## Roadmap por capacidades

| Fase | Capacidade | Aceite mínimo |
|---|---|---|
| 0 | Inventário e baseline | Mapear os fluxos atuais e os testes relacionados, sem implementação ou arquitetura-alvo. |
| 1 | Painel e diagnóstico | Mostrar estado, motivo de pausa/bloqueio, última ação e erro nas telas atuais. |
| 2 | Presets por Pokémon | Salvar, aplicar e validar presets de skills, bolas e suporte usando a configuração existente. |
| 3 | Políticas pós-combate | Configurar ordem entre suporte, loot e captura, com dedupe e motivo observável. |
| 4 | Cavebot mínimo | Executar uma rota curta, interromper para combate/suporte e retomar previsivelmente. |
| 5 | Cavebot robusto | Recorder/editor básico, detecção de ausência de progresso e recovery limitado. |
| 6 | Combate evoluído | Adicionar uma capacidade por vez: filtros, stop conditions, alcance e posicionamento. |
| 7 | Estatísticas e alarmes | Sessão local com duração, kills, loot/captura, falhas e alertas deduplicados. |
| 8 | Actions & Rules | Regras para gatilhos reais já observáveis, com cooldown e simulação. |
| 9 | Opcionais | Party, multi-sessão, remoto ou assistente somente com necessidade concreta. |

## Prompt 0: leitura do repositório

```text
Leia o repositório inteiro o suficiente para entender os fluxos relacionados às funcionalidades deste relatório. Não implemente e não proponha uma arquitetura-alvo.

Produza um documento curto com:
1. os componentes atuais e suas responsabilidades;
2. o caminho de percepção → decisão → atuação para pesca, combate, captura, mini-game e suporte;
3. os mecanismos atuais de coordenação e segurança, incluindo Body, Rig, InputGate, Guardian, Focus, PubSub e WorldState;
4. as páginas LiveView e configurações que já podem ser reutilizadas;
5. para cada capacidade do roadmap, o ponto de extensão mais próximo;
6. riscos e testes que precisam ser preservados.

Quando encontrar um possível problema arquitetural, descreva a evidência. Não crie nomes ou abstrações novas para resolvê-lo nesta rodada.
```

## Prompt para implementar uma fase

```text
Implemente somente a fase selecionada do roadmap.

Antes de editar:
- rastreie o fluxo atual relacionado;
- liste os arquivos e componentes existentes que pretende reutilizar;
- defina um critério de aceite observável;
- apresente a opção mínima de implementação;
- mencione uma alternativa estrutural somente se a opção mínima não atender ao requisito.

Durante a implementação:
- preserve nomes e contratos existentes;
- não crie fundações genéricas para fases futuras;
- limite refatorações ao que for necessário para o aceite;
- mantenha as proteções atuais de foco, panic e atuação;
- atualize a UI existente em vez de criar uma aplicação paralela;
- adicione testes no nível em que a decisão já vive hoje.

Ao final, entregue: resumo do fluxo alterado, decisões tomadas, testes executados, riscos restantes e próximos passos que NÃO foram implementados.
```

## Prompt específico: Cavebot mínimo

```text
Investigue primeiro a árvore atual, os donos de movimento/input, as percepções disponíveis e a coordenação com combate, mini-game e PlayerSupport.

Proponha uma fatia mínima de Cavebot que execute uma rota curta e consiga pausar e retomar. Não use nomes de módulos, estados ou uma árvore OTP impostos por este documento. Escolha o desenho que melhor se encaixa no repositório e explique por que novos processos ou abstrações são necessários, caso sejam.

Implemente somente após apresentar o fluxo atual, o ponto de extensão escolhido, o critério de aceite e os testes de preservação.
```

## Prompt específico: Combate

```text
Preserve o Tab targeting e investigue o caminho direto de bursts de teclado antes de alterá-lo. Escolha apenas uma melhoria: lista de alvos/ignorados, stop condition, alcance ou posicionamento básico.

Implemente a menor mudança que encaixe em Combat.Logic, Combat.Worker, percepção e configuração atuais. Não unifique caminhos de input nem crie um scheduler genérico sem evidência de que a feature exige isso. Meça ou teste qualquer impacto em latência, atomicidade e segurança.
```

## Checklist de revisão

- O plano cita componentes reais do Pokex?
- A feature possui um critério de aceite pequeno e observável?
- Cada processo novo tem ciclo de vida independente justificado?
- Cada abstração nova resolve uma limitação comprovada agora?
- Body, Rig, InputGate, Guardian, Focus, WorldState e PubSub foram considerados?
- O caminho direto do Combat foi analisado em vez de simplesmente proibido?
- A UI reutiliza as LiveViews atuais?
- Os testes foram adicionados onde a decisão já vive?
- O diff evita funcionalidades futuras e refatorações adjacentes?

## Referências

- KizuBot docs: https://www.kizubot.com/docs
- Combat: https://www.kizubot.com/docs/combat
- Cavebot: https://www.kizubot.com/docs/cavebot
- Repositório: https://github.com/sallaumen/pokex
- GPT-5.6 Sol: https://developers.openai.com/api/docs/models/gpt-5.6-sol
