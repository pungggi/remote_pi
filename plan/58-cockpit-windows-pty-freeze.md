# Plano 58 — Fix: Cockpit Windows congela ao escrever no PTY

**Objetivo**: eliminar o congelamento total da UI do Cockpit no Windows
("Não está respondendo") causado por `pty_write` bloqueando a thread de
plataforma. Duas ocorrências em produção na v1.26.0+60 (2026-08-13, ~11:05
e ~11:50, máquina do Fabio).

## Contexto

Diagnóstico feito por análise de minidump do processo travado (PID 149976,
dump preservado — ver Evidência abaixo). Stack da thread 0 (UI/platform):

```
cockpit.exe (message loop)
→ user32!DispatchMessageWorker
→ flutter_windows (platform message dispatch)
→ código Dart (AOT)
→ cockpit_pty!pty_write            (FFI síncrono)
→ KERNELBASE!FlushFileBuffers
→ ntdll!NtFlushBuffersFile         ← bloqueada indefinidamente
```

CPU do processo ~0 (deadlock de espera, não busy-loop). 71 threads vivas.

O código em `plugins/cockpit_pty/src/cockpit_pty_win.c:507-516`:

```c
FFI_PLUGIN_EXPORT void pty_write(PtyHandle *handle, char *buffer, int length)
{
    DWORD bytesWritten;
    WriteFile(handle->inputWriteSide, buffer, length, &bytesWritten, NULL);
    FlushFileBuffers(handle->inputWriteSide);   // ← linha 513, o vilão
    return;
}
```

**Por que trava**: `FlushFileBuffers` em pipe não descarrega buffer local —
bloqueia até a outra ponta (ConPTY/conhost) **consumir** tudo que foi
escrito. Se o shell filho para de drenar input (processo parado, buffer
cheio, filho que não lê stdin), a chamada nunca retorna. Como `pty_write` é
FFI síncrono na thread de plataforma (= thread de UI no Flutter Windows
atual), a janela inteira congela.

**Origem**: bug herdado do `kyroon_pty` v1.0.6 (plugin absorvido, ver
`cockpit/CLAUDE.md`). Os backends POSIX (`forkpty`) não têm flush — só
Windows trava.

### Evidência

- Minidump com stacks: `C:\Users\fabio\.cockpit\dumps\cockpit-hang-149976.dmp`
  (19,7 MB)
- Event Log Application 1002 às 11:05 (primeira ocorrência, mesma versão)
- Última gravação de estado às 11:50:49; congelamento entre 11:50 e 11:53
- Terminal ativo no momento: PowerShell (tab t25)

## Decisão

Fix em duas camadas, no plugin `cockpit_pty` (Windows):

1. **Remover o `FlushFileBuffers`** (linha 513) — desnecessário em pipe
   (`WriteFile` já entrega ao pipe) e semanticamente errado. Fix mínimo que
   elimina o deadlock observado.
2. **Endurecer contra a variante rara**: o próprio `WriteFile` pode
   bloquear se o buffer do pipe encher (mesma classe de bug). Avaliar
   mover a escrita pra fora do caminho síncrono da UI — writer thread com
   fila, ou pipe em modo overlapped. Se o custo for alto, registrar a
   decisão e fazer em plano seguinte; a remoção do flush já resolve os
   travamentos observados.

## Não-objetivos

- Não tocar nos backends POSIX (`forkpty` em macOS/Linux) — não têm o bug.
- Não redesenhar a API do plugin nem o protocolo Dart↔FFI.
- Não tratar aqui watchdog/auto-restart do app (se quisermos, é plano
  futuro).

## Estrutura esperada

```text
cockpit/plugins/cockpit_pty/
└── src/
    └── cockpit_pty_win.c    # pty_write sem FlushFileBuffers (+ writer
                             # thread/overlapped se decidido no passo 2)
```

## Passos com critério de aceite

### 1. Remover o flush do pty_write Windows

- Remover `FlushFileBuffers(handle->inputWriteSide)` de `pty_write`.
- Verificar se há outros call sites de `FlushFileBuffers` no plugin
  (grep) e avaliar cada um com a mesma lente.

**Aceite**: build Windows do plugin passa; terminal embutido continua
funcionando (echo de digitação, comandos interativos, paste grande).

### 2. Decidir e (se barato) implementar escrita não-bloqueante

- Medir/raciocinar sobre o risco do `WriteFile` bloqueante com buffer
  cheio (paste de KBs num shell parado).
- Implementar writer thread com fila OU documentar decisão de adiar
  (com justificativa) no result file.

**Aceite**: decisão registrada; se implementado, paste grande (>64KB) num
shell suspenso não congela a UI.

### 3. Reproduzir e validar

- Repro manual do cenário original: abrir terminal, parar o consumidor
  (ex.: processo filho suspenso / `pause` sem ler stdin), digitar no
  terminal — a UI **não** pode congelar.
- Smoke geral dos terminais (abrir, digitar, fechar, redimensionar).

**Aceite**: repro documentado no result file; UI permanece responsiva no
cenário que antes travava.

### 4. Verificação

- `flutter analyze` / testes existentes do cockpit verdes.
- Bump de versão do cockpit + entrada no CHANGELOG descrevendo o fix.

## Definition of Done

- [x] `FlushFileBuffers` removido do `pty_write` (cockpit_pty_win.c).
- [x] Decisão sobre escrita não-bloqueante registrada (implementada:
      writer thread com fila; pipes anônimos não suportam overlapped I/O).
- [x] Repro do congelamento validado como corrigido no Windows. Evidência
      (2026-08-13, harness em C incluindo o `cockpit_pty_win.c` real, com
      conhost suspenso via NtSuspendProcess): semântica antiga
      (`WriteFile`+`FlushFileBuffers`) **bloqueou** no 1º write; `pty_write`
      novo fez 500×4KB em 1,5ms (pior chamada 0,13ms). Benchmark no app real
      (1.26.1): throughput de output a +14% do Windows Terminal (1,97s vs
      1,72s em 20k linhas) — paridade prática. Harness versionado em
      `cockpit/plugins/cockpit_pty/test/windows/` (`build.ps1`).
- [x] Build + analyze + testes verdes **no que o fix toca**. Build Windows
      release OK (exigiu instalar Zig 0.16 e o componente ATL do VS Build
      Tools); `flutter analyze` sem issues novos; `flutter test`: 881 pass /
      12 fail — todas as falhas em Dart **não tocado pelo fix** (o diff só
      altera C nativo + changelogs/versões) e características de suite
      nunca rodada em Windows (ex.: `terminal_view_test` textScaler,
      `codex_hook_installer_test`, teste "no macOS não desenha nada").
      Follow-up separado abaixo.
- [x] CHANGELOG do cockpit atualizado (1.26.1+61; plugin 1.0.7).

## Próximos planos

- **Suite verde no Windows**: 12 testes falham por suposições de
  macOS/POSIX (primeira execução da suite em Windows, 2026-08-13). Triagem
  e fix ou `skip` condicional por plataforma.
- CLI `cockpit` sem descoberta de socket fora das tabs no Windows
  (`~/.cockpit` sem socket) — impede orquestração externa nesta plataforma.
- Watchdog opcional no Windows (detectar janela não-responsiva e coletar
  dump automaticamente) — só se voltar a travar por outra causa.
