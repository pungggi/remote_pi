# Plan 161 — Provider-grouped Home (usage once per provider)

## Context

Plan/156 put the provider subscription usage (`5h 3% · wk 4%` + hairline bar)
on every MODEL group header. But plan usage is **account-scoped**: all models
of one provider (z.ai's GLM 4.7 and GLM 4.6, …) share one quota. With several
model groups per provider the Home list repeats identical numbers in header
after header — a wall of numbers that hides rather than informs.

User decision (2026-11-07): group **by provider first, then by model**. The
subscription usage renders **once**, on the provider header. Model groups nest
under it as compact sub-headers. This makes each provider's aggregate headroom
readable at a glance and stops the repeated-number noise.

Three sub-deisions (2026-11-07):

- **Replace, don't add**: the `Model` segment becomes the nested
  `Provider ▸ Model` view. Two segments stay: `Provider | Repo`. The flat
  model view shows nothing the nested view doesn't.
- **Fallback section**: rooms that report no provider (offline caches from
  older extensions, keeper mirrors) land in one `Unknown provider` section at
  the end, model sub-groups inside. Same pattern as `Unknown model` /
  `No git repository`.
- **Pretty names**: display-name map for known slugs (`zai → z.ai`,
  `anthropic → Anthropic`, …) with the raw slug as fallback.

### Why a wire change

The app cannot group by provider today because the provider never reaches it:

- **pi-extension** tracks `ext.currentProvider` but publishes only `model`
  and `plan_usage` in `room_meta`.
- **relay** has a typed `RoomMeta` struct; unknown fields are dropped.
- **app** `RoomInfo` has `model` but no `provider`.

So the provider rides `room_meta.provider` end-to-end (string slug, same
semantics as `model`: absent = preserve, value = set).

## Expected structure

### pi-extension

- `_setCurrentModel(name, provider)` — also cache + publish `provider`:
  - `ext.myRoomMeta` gains `provider` whenever a non-empty provider is known.
  - The `room_meta_update` meta carries `provider` alongside `model`
    (deduped: only when it changed, like `context_usage: null` riding
    model changes).
  - No explicit-null clear: a provider switch is always a new value; an
    unknown provider simply omits the key (relay preserves).
- Audit every `_setCurrentModel` call site to pass the provider when the
  source knows it:
  - `model_select` handler (already passes it),
  - turn-start hydration (already passes it),
  - startup seed from the SDK's resolved model (~line 4015),
  - per-turn `user_message` model override (~line 4885, `chosen` carries
    provider).
- Hello path needs nothing new: `room_announced` builds from `myRoomMeta`,
  so the cached `provider` rides the announce automatically.

### relay

- `RoomMeta` struct: `provider: Option<String>`.
- Announce parse (`handlers/peer.rs`): `meta.provider` as string, same shape
  as `model`.
- Patch parse: `provider` with toggle semantics (`Some(Some(v))` set,
  absent = preserve) — identical to `model_patch`/`thinking_patch`.
- `registry.rs`: apply patch to stored meta; include `provider` in the
  broadcast meta object and the hello reconstruction next to `model`.

### app

- `protocol.dart`:
  - `RoomInfo.provider` (`String?`), parsed from announce and
    `RoomMetaUpdated` (nullable-as-absent preserve, like `model`),
    serialized in the room cache, `copyWith` support.
- `preferences.dart`:
  - `enum HomeGroupBy { provider, repository }`.
  - Read migration: stored `'model'` maps to `HomeGroupBy.provider`
    (persisted by `.name`, so the default-literal and `orElse` change too).
- `connection_manager.dart`: merge `provider` on announce / patch /
  rooms-snapshot paths with the same preserve rules as `model`; room-cache
  round-trip carries it.
- `home_state.dart`:
  - New `HomeProviderSection { label, slug, isFallback, models:
    List<HomeGroup> }` projection for provider mode (repo mode keeps the
    flat `groupHomeItems`).
  - Provider label via the pretty-name map (new tiny helper, e.g. in
    `session_grouping.dart`), fallback to the raw slug.
  - Sorting: providers alphabetical, `Unknown provider` last; models
    alphabetical inside, `Unknown model` last; items within models keep
    today's order (live first, keeper last, by display name).
  - `firstOnlinePlanUsage` operates over the whole section's items
    (any online session publishing usage, not per model group).
- `session_grouping.dart`:
  - `SessionGroupHeader` stays the provider header: label, TOTAL session
    count, usage line + bar + 🔄×N reset chip (all account-scoped → exactly
    once per provider).
  - New compact `ModelGroupLabel` sub-header: model name + count, indented,
    no usage, no bar. Visually lighter than the provider header.
- `home_page.dart`: provider mode renders
  `[ProviderHeader, ModelLabel, tile, tile, ModelLabel, tile, …]`; repo mode
  unchanged.
- `home_viewmodel.dart`: `visibleProviderSections` (provider mode) beside
  `visibleGroups` (repo mode); `planUsageForSection` replaces
  `planUsageForGroup`; reset-card confirm dialog now takes the section's
  usage.
- `session_tile.dart`: `HomeGroupBy.model` references become the provider
  value — under provider nesting the sub-header still owns the model name,
  so the prompt-replaces-model subtitle behavior is unchanged.

## Steps

1. **Extension**: publish `provider` (cache, update, all `_setCurrentModel`
   call sites). Vitest: hello carries provider; `model_select` update
   carries provider; per-turn override carries provider.
2. **Relay**: struct + announce + patch + registry passthrough. Rust tests:
   provider in announce broadcast, patch set, absent-preserve.
3. **App protocol + merge + prefs migration**: parse/serialize/patch
   `provider`; enum rename + `'model'` read migration. Tests for each.
4. **App grouping + UI**: `HomeProviderSection` projection, provider header,
   `ModelGroupLabel`, nested list build, chip relocation. Widget tests:
   - provider header renders usage exactly once for two same-provider model
     groups; model sub-headers render none;
   - all-offline provider section shows no usage (online gating);
   - no-provider rooms land in `Unknown provider` fallback;
   - reset chip renders + confirms at provider level;
   - stored `'model'` pref boots into provider mode.
5. Suites green: `pnpm typecheck` + `vitest` (pi-extension), `cargo test`
   (relay), `flutter analyze` + `flutter test` (app); changelog entries
   (root + app asset).

## Acceptance criteria

- Home in Provider mode: two z.ai model groups render under one `z.ai`
  header whose usage line/bar/reset chip appear once; the sub-headers show
  only model + count.
- A room that switches provider re-groups live (provider patch merges).
- Repo mode is byte-for-byte the old behavior.
- Upgrading over a stored `model` grouping preference opens Provider mode.
- No key material or provider credentials anywhere new (slug only).

## DoD

- [x] Extension provider publish + tests
- [x] Relay passthrough + tests
- [x] App protocol/prefs/merge + tests
- [x] Provider-grouped UI + widget tests
- [x] All suites + analyze/typecheck green
- [x] Changelog entries (root + app asset)
- [ ] User review on device

## Next plans

- Optional: provider ordering by tightest constraint once more than two
  providers carry probes (alphabetical for now — reordering as quotas move
  would make the list unstable).
- Probe registry growth (kimi-coding) benefits automatically: new providers
  slot into their own section with zero UI work.
