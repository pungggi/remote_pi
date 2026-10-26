/** True only for an explicitly marked Pi subagent child process. */
export function isPiSubagentChildProcess(
  env: NodeJS.ProcessEnv = process.env,
): boolean {
  // PI_SUBAGENT_PARENT_SESSION is metadata found on parents too, so it must
  // never suppress startup by itself. The other markers are child-only.
  return env["PI_SUBAGENT_CHILD"] === "1"
    || Boolean(env["PI_SUBAGENT_RUN_ID"] || env["PI_SUBAGENT_CHILD_AGENT"]);
}
