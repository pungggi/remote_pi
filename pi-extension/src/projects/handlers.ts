/**
 * Plan/121 — device-daemon handler for `list_projects_request`.
 *
 * Replies with the git projects discovered under the configured roots
 * (`~/.pi/piper/config.json` `projects.roots`, default `~/source`; env
 * override `REMOTE_PI_PROJECTS_ROOTS`). The phone renders these as a
 * always-visible Projects list (independent of live `pi` sessions) and spawns
 * a worktree terminal from the chosen one via `open_terminal_request`.
 *
 * Always replies — `ok:false` (with an empty list + message) only if discovery
 * itself threw, which it shouldn't (it's best-effort). An empty list is a valid
 * answer (no repos under the roots), not an error.
 */
import type { ClientMessage, ServerMessage } from "../protocol/types.js";
import type { ActionReplySender } from "../actions/handlers.js";
import { discoverProjects } from "./discover.js";
import { projectsRoots } from "../config.js";

type ListProjectsRequestMsg = Extract<
  ClientMessage,
  { type: "list_projects_request" }
>;

export function handleListProjects(
  sender: ActionReplySender,
  msg: ListProjectsRequestMsg,
): void {
  let projects;
  try {
    projects = discoverProjects(projectsRoots());
  } catch (e) {
    sender.send({
      type: "list_projects_result",
      in_reply_to: msg.id,
      ok: false,
      projects: [],
      message: `discovery failed: ${(e as Error).message}`,
    });
    return;
  }
  sender.send({
    type: "list_projects_result",
    in_reply_to: msg.id,
    ok: true,
    projects,
  });
}
