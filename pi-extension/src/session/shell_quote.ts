/**
 * Quoting helpers for launching `.cmd`/`.bat` shims through `shell: true`.
 *
 * Node joins `shell: true` argument arrays with plain spaces and hands the
 * result to `cmd.exe /d /s /c`, so an already-tokenized argument such as
 * `explain A & B` would be re-split at `&` (and the remainder executed as a
 * separate command). Re-quoting each argument before the spawn keeps the
 * original argv boundaries intact.
 */

const SHELL_SAFE_ARG = /^[A-Za-z0-9_.\-:/\\@+]+$/;

/**
 * Quotes one argument for `cmd.exe` command-line parsing.
 *
 * - Arguments without shell metacharacters stay bare.
 * - Everything else is wrapped in double quotes (shields `& | < > ^ ( )`,
 *   whitespace, `; , =` from `cmd.exe`).
 * - Embedded `"` becomes `""` so `cmd.exe` stays inside the quoted region and
 *   the child's argv parser still sees one literal quote.
 * - Trailing backslashes are doubled so they cannot escape the closing quote
 *   when the child re-parses its command line.
 *
 * Known limitation (inherent to `cmd.exe`): `%VAR%` inside an argument is
 * still expanded by the shell; no quoting scheme can prevent that.
 */
export function quoteWindowsShellArg(arg: string): string {
  if (arg.length > 0 && SHELL_SAFE_ARG.test(arg)) return arg;

  let out = '"';
  let backslashes = 0;
  for (const ch of arg) {
    if (ch === "\\") {
      backslashes++;
      continue;
    }
    if (ch === '"') {
      out += "\\".repeat(backslashes * 2) + '""';
      backslashes = 0;
      continue;
    }
    out += "\\".repeat(backslashes) + ch;
    backslashes = 0;
  }
  out += "\\".repeat(backslashes * 2) + '"';
  return out;
}

/**
 * Quotes a whole passthrough argv for a Windows `shell: true` spawn.
 */
export function quoteWindowsShellArgs(args: readonly string[]): string[] {
  return args.map(quoteWindowsShellArg);
}
