/**
 * Plan/28 — ModelRegistry instance shared by the action handlers.
 *
 * pi-extension builds its **own** `ModelRegistry` alongside the one
 * `AgentSession` instantiates internally. Both read the same on-disk sources
 * (`~/.pi/auth/*`, `~/.pi/models.json`), so they stay in sync — we just call
 * `refresh()` before each `list_models` request to capture changes the user
 * makes via `/login` or `/scoped-models` in the TUI.
 *
 * Why a fresh instance instead of accessing Pi's: the `ExtensionAPI` surface
 * does not expose `AgentSession`'s registry. This disk-backed registry is the
 * FALLBACK for paths that have no extension ctx; prefer `ctx.modelRegistry`
 * (the LIVE session registry) wherever a ctx is available — it reflects
 * providers registered dynamically by other extensions via
 * `pi.registerProvider(...)`, which this fallback does not.
 *
 * pi 0.83 reworked construction: the old sync
 * `ModelRegistry.create(AuthStorage.create())` pair became an async
 * `ModelRuntime.create()` + `new ModelRegistry(runtime)` (`AuthStorage` was
 * removed; credentials now default to the file at the auth path). We cache the
 * PROMISE so concurrent callers share one build and the async cost is paid
 * exactly once for the process. Callers MUST `await` this.
 */

import { ModelRegistry, ModelRuntime } from "@earendil-works/pi-coding-agent";

let _registryPromise: Promise<ModelRegistry> | null = null;

/**
 * Lazily build + cache the shared `ModelRegistry`. Subsequent calls return the
 * same cached promise — the `ModelRuntime.create()` + models.json parse happen
 * exactly once and are amortized across every later `list_models`/`model_set`.
 */
export function ensureModelRegistry(): Promise<ModelRegistry> {
  if (!_registryPromise) {
    _registryPromise = ModelRuntime.create().then((runtime) => new ModelRegistry(runtime));
  }
  return _registryPromise;
}

/** Test seam — drop the cached promise so tests can rebuild with fakes. */
export function _resetModelRegistryForTests(): void {
  _registryPromise = null;
}
