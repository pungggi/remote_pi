# Plano 59 — Cockpit Windows: retomada sem backlog

**Objetivo**: eliminar a degradação percebida quando o Cockpit volta ao foco
depois de permanecer inativo no Windows, suspendendo trabalho visual/de
reconciliação que não precisa rodar em background e impedindo operações Git
sobrepostas.

## Contexto

O fix do plano 58 removeu o congelamento síncrono do `pty_write` no Windows e
está no `HEAD` atual (`1.26.1`). O sintoma residual é diferente: após a janela
ficar inativa, o retorno pode concentrar polling Git, watchers, reconciliação de
worktrees e atualizações visuais.

Evidências do código atual:

- `GitController` dispara refresh de todos os targets a cada 3 s com
  `unawaited`, sem single-flight.
- O watcher recursivo do projeto selecionado permanece ativo sem a janela estar
  visível.
- `WindowStateKeeper` trata resize/move/close, mas não blur/focus/minimize/
  restore.
- Indicadores de agentes mantêm listeners e tickers em abas montadas porém
  ocultas.

## Não-objetivos

- Não pausar PTYs ou processos de agentes: eles devem continuar trabalhando.
- Não alterar o protocolo RPC nem descartar output de terminal/agente.
- Não aplicar workaround de GPU sem evidência de gargalo no rasterizador.
- Não mexer nos arquivos gerados já modificados no checkout antes desta entrega.

## Passos com critério de aceite

### 1. Confirmar a linhagem do fix ConPTY

- Confirmar versão do Cockpit `>= 1.26.1` e que o build Windows inclui a
  implementação de `cockpit_pty` com writer thread e sem `FlushFileBuffers` no
  caminho de escrita.
- Registrar versão e evidência no resultado da execução.

**Aceite**: a entrega parte do fix do plano 58 e o build não reintroduz escrita
ConPTY síncrona na thread de UI.

### 2. Introduzir lifecycle global de atividade da janela

- Publicar estado app-scoped ativo/inativo a partir de focus/blur e
  minimize/restore.
- Quando inativo, pausar polling Git, watcher recursivo e tickers puramente
  visuais; PTY/RPC continuam vivos.
- Ao voltar, rearmar os observadores necessários.

**Aceite**: teste determinístico prova que, durante inatividade, nenhum novo
tick Git nem ticker visual é executado, sem matar processos ou streams.

### 3. Tornar reconciliações single-flight

- `GitController.refresh`: no máximo uma execução por projeto; chamadas durante
  uma execução geram no máximo um rerun pendente.
- Reconciliação de worktrees e carga periódica de Git History seguem a mesma
  regra, sem operações concorrentes.

**Aceite**: readers bloqueáveis em teste recebem concorrência máxima `1` e uma
rajada de chamadas produz no máximo a execução corrente + um rerun.

### 4. Retomar com uma única reconciliação coalescida

- Focus/restore repetidos no mesmo ciclo de retomada disparam uma única
  reconciliação de Git/worktrees.
- Eventos acumulados enquanto inativo não são reproduzidos um a um.

**Aceite**: teste de blur/minimize seguido por múltiplos focus/restore observa
uma única reconciliação e o polling periódico volta sem duplicação de timers.

## Validação

Executar no subprojeto `cockpit/`, registrando resultados antes e depois quando
o comando já falhar no baseline:

1. Testes direcionados de lifecycle, Git poll/single-flight, worktrees e Git
   History.
2. `flutter analyze`.
3. `flutter test` completo.
4. `flutter build windows`.
5. Harness Windows do plugin PTY do plano 58.

A melhoria é comprovada mecanicamente pelos testes de ausência de trabalho em
background, concorrência máxima e coalescência. A percepção de fluidez ainda
exige smoke manual: deixar a janela desfocada por pelo menos 10 minutos com
agentes ativos, restaurar e confirmar interação imediata sem rajada de
`git.exe`.

## Definition of Done

- [x] Linhagem `1.26.1+` e writer thread ConPTY confirmadas.
- [x] Lifecycle global pausa apenas trabalho não essencial.
- [x] Git, worktrees e Git History são single-flight.
- [x] Retomada executa uma única reconciliação coalescida.
- [x] Testes direcionados, analyze, suite completa, build Windows e harness PTY
      executados com resultados registrados.
- [x] Smoke manual residual explicitamente documentado.

## Resultado da execução — 2026-08-17

- Branch: `fix/windows-resume-performance`.
- Linhagem: Cockpit `1.26.1+61`, fix ConPTY `4fb9249`, writer thread ativa e
  nenhum `FlushFileBuffers` no caminho de escrita.
- Lifecycle: stream essencial simulado recebeu `3/3` eventos durante
  inatividade; subtree montada uma vez e não descartada.
- Git inativo: zero leituras e zero reconciliações.
- Retomada com focus/restore repetidos: uma leitura Git e uma reconciliação;
  após o intervalo, apenas um tick periódico adicional.
- Single-flight de worktrees: concorrência máxima `1`, duas execuções para uma
  rajada (corrente + um rerun).
- Testes direcionados: `19/19` verdes.
- `flutter analyze`: 38 infos preexistentes, nenhuma em arquivo tocado.
- `flutter test`: 893 passaram, 5 ignorados e as mesmas 12 falhas Windows
  preexistentes já documentadas no plano 58.
- `flutter build windows`: sucesso.
- Harness PTY Windows: 2 passaram, 0 falharam; 500 escritas de 4 KiB em 1,3 ms,
  pior chamada 0,15 ms.
- Verificação independente: `APROVADO`, sem findings.
- Residual: smoke manual de 10 minutos com agentes ativos ainda não executado;
  os testes comprovam coalescência e ausência de trabalho de fundo, não a
  percepção visual no hardware do usuário.
- Correção pós-build: `WindowActivityController` passou a ser registrado como
  a mesma instância root-owned no módulo core. Antes ele existia apenas em
  `ModularApp.provide`, que atende widgets mas não o `auto_injector` usado para
  construir `GitController`; isso causava `UnregisteredInstance` no boot
  release. Teste de composição modular reproduziu o erro antes da correção e
  passou depois; build release e smoke de inicialização também passaram.

## Benchmark sintético — 2026-08-17

Utilitário reproduzível:
`cockpit/tool/benchmarks/windows_resume_performance.dart`. Execução AOT, dois
warmups e 31 amostras; carga lenta de 1.000 triggers, 12 projetos/roots, poll de
3 s e 10 minutos virtuais de inatividade.

| Métrica | Política antiga | Política nova |
|---|---:|---:|
| Chamadas efetivas na rajada | 1.000 | 2 |
| Concorrência máxima | 1.000 | 1 |
| Drain mediano | 31,68 ms | 62,04 ms |
| Drain p95 indicativo | 32,52 ms | 63,41 ms |
| Callbacks de poll durante inatividade | 200 | 0 |
| Refreshes Git durante inatividade | 2.400 | 0 |
| Operações worktree por root durante inatividade | 2.400 | 0 |
| Ciclos imediatos numa tempestade de resume | 0 | 1 |
| Refreshes Git nesse ciclo de resume | 0 | 12 |
| Operações worktree por root nesse ciclo | 0 | 12 |
| Timers periódicos após resume | 1 | 1 |

O drain novo é aproximadamente 30 ms mais lento porque executa duas esperas
serializadas, enquanto o antigo sobrepõe artificialmente 1.000 operações. Isso
não representa regressão de UI: a melhoria relevante é reduzir chamadas em
99,8%, concorrência em 99,9% e eliminar totalmente trabalho de polling durante
inatividade. `INVARIANTS: PASS`; analyzer, compilação AOT e auditoria independente
verdes. O benchmark é sintético e não mede frame time, GPU nem fluidez percebida.

## Próximos planos

- Lifecycle nativo completo do PTY (`pty_close`) para liberar handles/threads.
- Limite/backpressure explícito da fila de escrita ConPTY.
- Orçamento de processamento para bursts RPC, somente se métricas ainda
  apontarem backlog após esta entrega.
