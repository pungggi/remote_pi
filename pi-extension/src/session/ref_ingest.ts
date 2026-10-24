/**
 * Plan/149 — GitHub-ref ingest for the session slot.
 *
 * Three ingest paths feed one stored `room_meta.gh_ref`:
 *
 *  - **manual** (`set_session_ref_request` from the app's long-press sheet):
 *    the user pasted a URL or `owner/repo#123`. Always wins.
 *  - **gh** (`gh pr view` on the git-refresh cadence): authoritative PR
 *    number/url/state for the session's worktree branch. Never replaces a
 *    MANUAL ref with a different number; refreshes state/url of the same PR.
 *  - **chat scan** (message text): full `github.com/<o>/<r>/issues|pull/<n>`
 *    URLs and `owner/repo#123` produce a SUGGESTION (`gh_suggestion`,
 *    source "chat") — never a silent write. The app renders it as a one-tap
 *    link; applying it goes through the manual path.
 *
 * A bare `#123` is never enough on its own: plan text is full of issue
 * numbers that belong to other repos.
 */

import { execFile } from "node:child_process";
import type { WireGhRef, WireGhRefSlot } from "../protocol/types.js";

/** `PR45` / `#12` display helpers and slot equality live here so the app
 *  mirror (Dart) can stay a pure projection of the wire shape. */

const GH_URL = /https?:\/\/(?:www\.)?github\.com\/([A-Za-z0-9_.-]+)\/([A-Za-z0-9_.-]+)\/(pull|issues)\/(\d+)/g;
const OWNER_REPO_N = /\b([A-Za-z0-9_.-]+)\/([A-Za-z0-9_.-]+)#(\d+)\b/g;

/** Parses a user-entered link (URL or `owner/repo#123`) into a manual ref.
 *  Returns null for anything else (bare `#123`, plain text, empty). */
export function parseManualRefInput(text: string): WireGhRef | null {
  const trimmed = text.trim();
  if (!trimmed) return null;

  for (const m of trimmed.matchAll(GH_URL)) {
    const [, owner, repo, kind, n] = m;
    const slot = slotOf(kind === "pull" ? "pr" : "issue", n!, urlFor(owner!, repo!, kind!, n!));
    return { ...slot, source: "manual" } as WireGhRef;
  }
  for (const m of trimmed.matchAll(OWNER_REPO_N)) {
    const [, owner, repo, n] = m;
    // owner/repo#N: GitHub renders this as an issue ref by default; PRs can
    // only be distinguished by URL. Keep it an issue slot — the gh path
    // upgrades to a PR once `gh pr view` confirms one exists.
    const slot = slotOf("issue", n!, urlFor(owner!, repo!, "issues", n!));
    return { ...slot, source: "manual" } as WireGhRef;
  }
  return null;
}

/** Scans ONE message's text for a ref suggestion (source "chat"). The LAST
 *  match wins (the most recent mention is the relevant one); URLs beat
 *  `owner/repo#123` at the same tail position because they carry the
 *  pull/issues distinction. Returns null when nothing credible is found. */
export function scanTextForRefSuggestion(text: string): WireGhRef | null {
  type Hit = { at: number; ref: WireGhRef };
  const hits: Hit[] = [];
  for (const m of text.matchAll(GH_URL)) {
    const [, owner, repo, kind, n] = m;
    hits.push({
      at: m.index ?? 0,
      ref: { ...slotOf(kind === "pull" ? "pr" : "issue", n!, urlFor(owner!, repo!, kind!, n!)), source: "chat" } as WireGhRef,
    });
  }
  for (const m of text.matchAll(OWNER_REPO_N)) {
    const [, owner, repo, n] = m;
    hits.push({
      at: m.index ?? 0,
      ref: { ...slotOf("issue", n!, urlFor(owner!, repo!, "issues", n!)), source: "chat" } as WireGhRef,
    });
  }
  if (hits.length === 0) return null;
  hits.sort((a, b) => a.at - b.at);
  const last = hits[hits.length - 1]!;
  // PR mention at the same position as an issue mention (rare) — PR wins.
  for (let i = hits.length - 2; i >= 0; i--) {
    const h = hits[i]!;
    if (h.at !== last.at) break;
    if (h.ref.pr && !last.ref.pr) return h.ref;
  }
  return last.ref;
}

/** Precedence-aware merge of a manual/gh ingest into the stored ref.
 *  Chat suggestions never reach this function (they go to gh_suggestion).
 *  Returns the next ref and whether it differs (caller pushes only then). */
export function applyRefWithPrecedence(
  current: WireGhRef | null | undefined,
  incoming: WireGhRef,
): { next: WireGhRef; changed: boolean } {
  if (!current || (!current.pr && !current.issue)) {
    return { next: incoming, changed: !sameRef(current ?? null, incoming) };
  }
  const curSource = current.source ?? null;
  const incSource = incoming.source ?? null;
  if (incSource === "manual") {
    // Manual always wins — but a no-op re-set of the identical ref should
    // not churn the wire (sameRef covers url/state refreshes).
    return { next: incoming, changed: !sameRef(current, incoming) };
  }
  if (incSource === "gh") {
    if (curSource === "manual") {
      // Manual stays manual; gh may only REFRESH the same PR (url/state) or
      // ADD a PR slot next to a manual issue link ("both are kept" — the
      // plan's storage rule). A different PR number never replaces it.
      if (current.pr) {
        if (incoming.pr && incoming.pr.number === current.pr.number) {
          // PR #N alone is NOT identity: a manual `other/repo/pull/45`
          // must not be "refreshed" with the cwd repo's unrelated PR #45
          // (PR #71 review). Both URLs present and different
          // `github.com/<owner>/<repo>/` prefixes → different repository →
          // keep the manual ref untouched. A missing URL cannot
          // disambiguate, so it keeps the legacy refresh behavior.
          if (!sameRepo(current.pr.url, incoming.pr.url)) {
            return { next: current, changed: false };
          }
          const merged: WireGhRef = {
            ...current,
            pr: { ...current.pr, url: incoming.pr.url ?? current.pr.url, state: incoming.pr.state ?? current.pr.state },
          };
          return { next: merged, changed: !sameRef(current, merged) };
        }
        return { next: current, changed: false };
      }
      // No PR slot yet — gh may add one beside the manual issue (or when the
      // manual ref was issue-only, this is the common "linked issue, PR
      // opened later" flow).
      if (incoming.pr) {
        const merged: WireGhRef = { ...current, pr: incoming.pr };
        return { next: merged, changed: !sameRef(current, merged) };
      }
      return { next: current, changed: false };
    }
    // gh over gh / gh over chat → apply.
    return { next: incoming, changed: !sameRef(current, incoming) };
  }
  // Unknown/other source → treat as lowest precedence; apply only over
  // nothing (handled above) — otherwise keep current.
  return { next: current, changed: false };
}

function slotOf(kind: "pr" | "issue", n: string, url: string): { pr: WireGhRefSlot | null; issue: WireGhRefSlot | null } {
  const slot: WireGhRefSlot = { number: parseInt(n, 10), url, state: null };
  return kind === "pr" ? { pr: slot, issue: null } : { pr: null, issue: slot };
}

function urlFor(owner: string, repo: string, kind: string, n: string): string {
  return `https://github.com/${owner}/${repo}/${kind}/${n}`;
}

/** Repository identity of a slot URL: the `github.com/<owner>/<repo>/`
 *  prefix, lowercased. Returns null for missing/unparseable URLs. */
function repoOf(url: string | null | undefined): string | null {
  if (!url) return null;
  const m = /^https?:\/\/(?:www\.)?github\.com\/([A-Za-z0-9_.-]+)\/([A-Za-z0-9_.-]+)\//.exec(url);
  if (!m) return null;
  return `${m[1]!.toLowerCase()}/${m[2]!.toLowerCase()}`;
}

/** `true` when both slots plausibly belong to the SAME repository. A null
 *  side (no URL to parse) cannot disambiguate → true (legacy behavior). */
function sameRepo(a: string | null | undefined, b: string | null | undefined): boolean {
  const ra = repoOf(a);
  const rb = repoOf(b);
  if (!ra || !rb) return true;
  return ra === rb;
}

/** Structural equality of two refs (slot fields compared one by one so an
 *  undefined slot equals a null slot). */
export function sameRef(a: WireGhRef | null | undefined, b: WireGhRef | null | undefined): boolean {
  if (!a && !b) return true;
  if (!a || !b) return false;
  return sameSlot(a.pr, b.pr) && sameSlot(a.issue, b.issue) && (a.source ?? null) === (b.source ?? null);
}

/** Merges a single-slot manual ref over the stored ref: the populated
 *  slot replaces ONLY its own kind; the OTHER slot is retained (the plan's
 *  two-slot rule — "PR wins display, both stay"). A null/empty input stays
 *  a clear; an input with BOTH slots replaces wholesale (explicit intent).
 *  PR #71 review: without this, accepting a PR after linking an issue
 *  silently deleted the issue. */
export function mergeManualRef(
  current: WireGhRef | null | undefined,
  incoming: WireGhRef | null,
): WireGhRef | null {
  if (!incoming) return null;
  const hasPr = incoming.pr != null;
  const hasIssue = incoming.issue != null;
  if (!hasPr && !hasIssue) return null;
  if (hasPr && hasIssue) return incoming;
  if (hasPr && current?.issue) return { ...incoming, issue: current.issue };
  if (hasIssue && current?.pr) return { ...incoming, pr: current.pr };
  return incoming;
}

function sameSlot(a: WireGhRefSlot | null | undefined, b: WireGhRefSlot | null | undefined): boolean {
  if (!a && !b) return true;
  if (!a || !b) return false;
  return a.number === b.number && (a.url ?? null) === (b.url ?? null) && (a.state ?? null) === (b.state ?? null);
}

/** Runner signature for `gh pr view` (injectable in tests). */
export type GhRunner = (cwd: string, args: string[]) => Promise<string | null>;

/** Default runner: `gh` via execFile, 10 s timeout, null on ANY failure
 *  (missing binary, no auth, not a repo, no PR for the branch). */
const defaultGhRunner: GhRunner = (cwd, args) =>
  new Promise((resolve) => {
    execFile(
      "gh",
      args,
      { cwd, timeout: 10_000, maxBuffer: 256 * 1024, windowsHide: true },
      (err, stdout) => {
        if (err) resolve(null);
        else resolve(stdout);
      },
    );
  });

/**
 * Best-effort `gh pr view` for the session's cwd: the authoritative PR
 * (number/url/state) for the checked-out branch. `null` = no gh / no auth /
 * not a repo / no PR — the caller changes nothing and surfaces no error
 * (acceptance: a missing gh binary is not a failure state).
 */
export async function ghPrViewRef(
  cwd: string,
  run: GhRunner = defaultGhRunner,
): Promise<WireGhRef | null> {
  const out = await run(cwd, ["pr", "view", "--json", "number,url,state"]);
  if (!out) return null;
  try {
    const j = JSON.parse(out) as { number?: unknown; url?: unknown; state?: unknown };
    if (typeof j.number !== "number" || !Number.isFinite(j.number)) return null;
    return {
      pr: {
        number: j.number,
        url: typeof j.url === "string" ? j.url : null,
        state: typeof j.state === "string" ? j.state : null,
      },
      issue: null,
      source: "gh",
    };
  } catch {
    return null;
  }
}
