# Plan 122 — Mobile Projects: pin to top

## Context

Plan 121 shipped the **Projects** screen on the mobile app: a flat list of git
repos discovered on the paired PC, tap → spawn a worktree terminal. As the list
grows, the most-used repos sink below rarely-touched ones, so reaching them
takes scrolling every time.

The cockpit already has "pin to top" for workspaces (PR 9,
`cockpit/.../projects_rail.dart`). This plan brings the same idea to the
**mobile app's** Projects screen: pin your go-to repos so they float to the
top and stay there.

## Scope

Mobile app only (`app/`). No protocol change, no relay change, no pi-extension
change — the pin is a **client-side preference** keyed by the project's
absolute repo path. (This is deliberately *not* plan 113's PC-side
always-on daemon; it is purely list ordering for fast access.)

## Design decisions (confirmed with user)

- **Identity = absolute repo `path`** (stable; `name` can change). Pinned
  paths that no longer exist on the paired PC are inert — they match nothing
  and render no tile.
- **Storage = app-global**, not per-peer. The app pairs with one PC in
  practice; cross-PC pins are harmless because matching is by path. Lives in
  `Preferences` (`FlutterSecureStorage`) as a JSON string array, mirroring the
  LAN-endpoints precedent (plan 115).
- **Ordering = stable partition**: pinned first (preserving discovery order),
  then the rest (preserving discovery order). No pin-order field — the device
  daemon's order is the tiebreaker, deterministic and predictable.

## Expected structure

### `Preferences` (`app/lib/data/preferences/preferences.dart`)

- New field `_pinnedProjects` + key `prefs.pinned_projects` (JSON array).
- Hydrate in `load()` (reuse a shared `_decodeJsonStringList` helper; refactor
  `_decodeLanEndpoints` onto it — DRY, behaviour-preserving).
- `pinnedProjects` getter, `isProjectPinned(path)`, `togglePinnedProject(path)`
  (append on pin, remove-by-value on unpin, persist, `notifyListeners`).

### `ProjectsViewModel` (`app/lib/ui/projects/projects_viewmodel.dart`)

- New `Preferences _prefs` dependency.
- `ProjectsReady` gains `Set<String> pinnedPaths`.
- `_sortedReady(projects)` — stable partition (pinned first).
- `togglePin(path)` — `prefs.togglePinnedProject` then re-emit the sorted list
  (optimistic; persistence failures swallowed — pinning never crashes).

### `ProjectsPage` (`app/lib/ui/projects/projects_page.dart`)

- Each tile's trailing = `Row[ IconButton(pin/pinOff) , chevron ]`. Pinned →
  accent `LucideIcons.pin`; unpinned → muted `LucideIcons.pinOff`. Pinned
  title is `FontWeight.w600`.
- `separatorBuilder` renders an `ALL PROJECTS` section label at the
  pinned→unpinned boundary (no label when nothing is pinned).

### DI (`app/lib/config/dependencies.dart`)

Pass `_injector.get<Preferences>()` to `ProjectsViewModel`.

## Steps

1. **Preferences** — field/key/hydrate/getters/toggle + shared decoder. ✅
2. **ViewModel** — dependency, `pinnedPaths`, `_sortedReady`, `togglePin`. ✅
3. **Page UI** — pin toggle button + section break. ✅
4. **DI wiring.** ✅
5. **Verify:** `dart analyze` clean on the 4 files; existing tests unchanged
   (the 4 pre-existing failures — voice/speech macOS, chat appbar, quick
   actions loading — fail identically on clean `main`). Build → install to
   device → tap a project's pin → confirm it floats to top and survives a
   reload.

### Acceptance criteria

- [ ] Tapping a project's pin icon moves it to the top of the list; tapping
      again moves it back.
- [ ] Pinned projects persist across app restarts (secure storage).
- [ ] A stale pin (path absent on the PC) renders nothing and never crashes.
- [ ] `dart analyze` clean on touched files; no new test regressions.

## DoD

Pin-to-top works on the phone's Projects screen, persisted, no protocol/relay
changes. Committed + pushed; build installed to the test device.

## Next

- **122b** — per-peer pins if multi-PC pairing becomes common.
- **122c** — drag-to-reorder within the pinned group (explicit pin order).
- **122d** — long-press a Home session tile to jump straight to its pinned
  project's chat.
