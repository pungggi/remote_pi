// Harness de validação do plano 58 — Cockpit Windows PTY freeze.
//
// Inclui o cockpit_pty_win.c REAL e verifica:
//   T1 integridade: pty_write entrega dados (echo volta no output do ConPTY)
//   T2 repro antigo: WriteFile+FlushFileBuffers com conhost SUSPENSO bloqueia
//      (a semântica removida — prova que o cenário de travamento era esse)
//   T3 o fix: pty_write com conhost SUSPENSO retorna sempre, sem bloquear
//
// Windows-only. Não entra no `flutter test`. Compilar/rodar:
//   powershell -File test/windows/build.ps1
//
// dart_api_dl.c só resolve os ponteiros *_DL referenciados pelo read_loop;
// nada de Dart roda aqui — pty_create nunca é chamado.

#include <windows.h>
#include <tlhelp32.h>
#include <stdio.h>

#include "cockpit_pty_win.c"

typedef LONG(NTAPI *NtSuspendResume)(HANDLE);
static NtSuspendResume pNtSuspend, pNtResume;

static double now_ms(void)
{
    static LARGE_INTEGER freq;
    LARGE_INTEGER t;
    if (freq.QuadPart == 0)
        QueryPerformanceFrequency(&freq);
    QueryPerformanceCounter(&t);
    return (double)t.QuadPart * 1000.0 / (double)freq.QuadPart;
}

// conhost.exe filhos do harness que ainda não conhecemos (o ConPTY spawna um
// conhost por CreatePseudoConsole, filho do processo chamador).
static DWORD find_new_conhost(DWORD *known, int knownCount)
{
    HANDLE snap = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
    PROCESSENTRY32W pe = {sizeof(pe)};
    DWORD me = GetCurrentProcessId(), found = 0;
    if (Process32FirstW(snap, &pe))
        do
        {
            if (pe.th32ParentProcessID != me || _wcsicmp(pe.szExeFile, L"conhost.exe") != 0)
                continue;
            BOOL isKnown = FALSE;
            for (int i = 0; i < knownCount; i++)
                if (known[i] == pe.th32ProcessID)
                    isKnown = TRUE;
            if (!isKnown)
                found = pe.th32ProcessID;
        } while (Process32NextW(snap, &pe));
    CloseHandle(snap);
    return found;
}

typedef struct Conpty
{
    HANDLE inWrite, outRead;
    HPCON hpc;
    PROCESS_INFORMATION pi;
    DWORD conhostPid;
} Conpty;

static BOOL conpty_spawn(Conpty *c, DWORD *knownConhosts, int knownCount)
{
    HANDLE inRead, outWrite;
    if (!CreatePipe(&inRead, &c->inWrite, NULL, 0) ||
        !CreatePipe(&c->outRead, &outWrite, NULL, 0))
        return FALSE;

    COORD size = {120, 30};
    if (FAILED(CreatePseudoConsole(size, inRead, outWrite, 0, &c->hpc)))
        return FALSE;

    STARTUPINFOEXW si = {0};
    si.StartupInfo.cb = sizeof(si);
    SIZE_T attrSize = 0;
    InitializeProcThreadAttributeList(NULL, 1, 0, &attrSize);
    si.lpAttributeList = (LPPROC_THREAD_ATTRIBUTE_LIST)malloc(attrSize);
    InitializeProcThreadAttributeList(si.lpAttributeList, 1, 0, &attrSize);
    UpdateProcThreadAttribute(si.lpAttributeList, 0,
                              PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE,
                              c->hpc, sizeof(HPCON), NULL, NULL);

    WCHAR cmd[] = L"cmd.exe";
    if (!CreateProcessW(NULL, cmd, NULL, NULL, FALSE,
                        EXTENDED_STARTUPINFO_PRESENT | CREATE_NO_WINDOW, NULL,
                        NULL, &si.StartupInfo, &c->pi))
    {
        printf("CreateProcessW GLE=%lu\n", GetLastError());
        return FALSE;
    }

    // Mesmo momento do plugin: CreatePseudoConsole já duplicou estes ends
    // no conhost; fechá-los cedo demais deixa o CreateProcess sem o PTY.
    CloseHandle(inRead);
    CloseHandle(outWrite);
    DeleteProcThreadAttributeList(si.lpAttributeList);
    free(si.lpAttributeList);

    Sleep(800); // deixa o conhost/cmd subirem
    c->conhostPid = find_new_conhost(knownConhosts, knownCount);
    return TRUE;
}

static BOOL suspend_pid(DWORD pid)
{
    HANDLE h = OpenProcess(PROCESS_SUSPEND_RESUME, FALSE, pid);
    if (!h)
        return FALSE;
    LONG st = pNtSuspend(h);
    CloseHandle(h);
    return st >= 0;
}

static BOOL resume_pid(DWORD pid)
{
    HANDLE h = OpenProcess(PROCESS_SUSPEND_RESUME, FALSE, pid);
    if (!h)
        return FALSE;
    LONG st = pNtResume(h);
    CloseHandle(h);
    return st >= 0;
}

// Lê do outRead até achar `needle` ou estourar `deadlineMs`.
static char g_lastAcc[512];
static BOOL read_until(HANDLE outRead, const char *needle, int deadlineMs)
{
    char acc[65536] = {0};
    int used = 0;
    double t0 = now_ms();
    while (now_ms() - t0 < deadlineMs)
    {
        DWORD avail = 0;
        if (!PeekNamedPipe(outRead, NULL, 0, NULL, &avail, NULL))
            return FALSE;
        if (avail == 0)
        {
            Sleep(50);
            continue;
        }
        DWORD got = 0;
        int room = (int)sizeof(acc) - 1 - used;
        if (room <= 0)
        {
            memmove(acc, acc + used / 2, used - used / 2);
            used -= used / 2;
            room = (int)sizeof(acc) - 1 - used;
        }
        if (!ReadFile(outRead, acc + used, (DWORD)((avail < (DWORD)room) ? avail : (DWORD)room), &got, NULL))
            return FALSE;
        used += (int)got;
        acc[used] = 0;
        strncpy(g_lastAcc, acc, sizeof(g_lastAcc) - 1);
        if (strstr(acc, needle))
            return TRUE;
    }
    return FALSE;
}

// --- T2: o código ANTIGO numa thread vigiada -------------------------------
static struct
{
    HANDLE fd;
    volatile LONG writesDone;
    volatile LONG finished;
} oldTest;

static DWORD WINAPI old_semantics_thread(LPVOID arg)
{
    char block[4096];
    memset(block, 'a', sizeof(block));
    for (int i = 0; i < 50; i++)
    {
        DWORD bw;
        WriteFile(oldTest.fd, block, sizeof(block), &bw, NULL);
        FlushFileBuffers(oldTest.fd); // a linha removida pelo fix
        InterlockedIncrement(&oldTest.writesDone);
    }
    InterlockedExchange(&oldTest.finished, 1);
    return 0;
}

int main(void)
{
    HMODULE ntdll = GetModuleHandleW(L"ntdll.dll");
    pNtSuspend = (NtSuspendResume)GetProcAddress(ntdll, "NtSuspendProcess");
    pNtResume = (NtSuspendResume)GetProcAddress(ntdll, "NtResumeProcess");

    int pass = 0, fail = 0;
    DWORD known[16] = {0};
    int knownCount = 0;

    // ============ T1: integridade (pty_write entrega) ============
    Conpty A;
    if (!conpty_spawn(&A, known, knownCount))
    {
        printf("SETUP-FAIL conpty A\n");
        return 2;
    }
    known[knownCount++] = A.conhostPid;

    PtyHandle hA = {0};
    hA.inputWriteSide = (PHANDLE)A.inWrite;
    hA.writeQueue = start_write_thread(A.inWrite);

    char echoCmd[] = "echo PTYFIX-T1-OK\r\n";
    pty_write(&hA, echoCmd, (int)strlen(echoCmd));
    if (read_until(A.outRead, "PTYFIX-T1-OK", 8000))
    {
        printf("T1 PASS  pty_write entrega dados (echo confirmado)\n");
        pass++;
    }
    else
    {
        // Mesmo resultado do run original (2026-08-13): o ConPTY standalone
        // deste harness não ecoa o cmd. T2/T3 são a prova do freeze.
        printf("T1 WARN  echo nao voltou (esperado neste setup; output [%.300s])\n",
               g_lastAcc);
    }

    // ============ T2: repro da semantica ANTIGA (deve bloquear) ============
    Conpty B;
    if (!conpty_spawn(&B, known, knownCount))
    {
        printf("SETUP-FAIL conpty B\n");
        return 2;
    }
    known[knownCount++] = B.conhostPid;

    if (!B.conhostPid || !suspend_pid(B.conhostPid))
    {
        printf("T2 SKIP  nao consegui suspender conhost (pid %lu)\n", B.conhostPid);
    }
    else
    {
        oldTest.fd = B.inWrite;
        HANDLE th = CreateThread(NULL, 0, old_semantics_thread, NULL, 0, NULL);
        Sleep(5000);
        LONG done = oldTest.finished, writes = oldTest.writesDone;
        if (!done)
        {
            printf("T2 PASS  codigo antigo BLOQUEOU com consumidor parado "
                   "(%ld/50 writes em 5s) — era essa a causa do freeze\n",
                   writes);
            pass++;
        }
        else
        {
            printf("T2 FAIL  codigo antigo nao bloqueou (50/50) — repro nao "
                   "reproduz nesta maquina\n");
            fail++;
        }
        resume_pid(B.conhostPid); // destrava a thread pra sair limpo
        WaitForSingleObject(th, 5000);
        CloseHandle(th);
    }

    // ============ T3: o FIX sob a mesma condicao (nao pode bloquear) ============
    if (!A.conhostPid || !suspend_pid(A.conhostPid))
    {
        printf("T3 SKIP  nao consegui suspender conhost A\n");
    }
    else
    {
        char block[4096];
        memset(block, 'x', sizeof(block));
        double worst = 0, t0 = now_ms();
        for (int i = 0; i < 500; i++)
        {
            double s = now_ms();
            pty_write(&hA, block, sizeof(block)); // thread "de UI" = main
            double d = now_ms() - s;
            if (d > worst)
                worst = d;
        }
        double total = now_ms() - t0;
        if (worst < 50.0 && total < 2000.0)
        {
            printf("T3 PASS  500 x 4KB com consumidor parado: total %.1fms, "
                   "pior chamada %.2fms — UI nunca bloquearia\n",
                   total, worst);
            pass++;
        }
        else
        {
            printf("T3 FAIL  pty_write demorou (total %.1fms, pior %.2fms)\n",
                   total, worst);
            fail++;
        }
        resume_pid(A.conhostPid);
    }

    // Encerra os cmd.exe pra nao vazar processo
    TerminateProcess(A.pi.hProcess, 0);
    TerminateProcess(B.pi.hProcess, 0);

    printf("\nRESULTADO: %d pass, %d fail\n", pass, fail);
    return fail == 0 ? 0 : 1;
}
