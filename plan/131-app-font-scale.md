# Plan 131 — App: adjustable font size (upstream #114)

> Worktree `remote_pi_font`, branch `font`. Implements upstream issue
> [jacobaraujo7/remote_pi#114](https://github.com/jacobaraujo7/remote_pi/issues/114)
> as a fork feature.

## Context

The mobile app hardcodes every text size: `AppTypography` fixes
`mono` 12.5pt / `monoSmall` 11pt / `sansBody` 14pt, and Settings → Display
only offers Theme + chat toggles. On phones — especially iPhone — the 12.5pt
monospace chat text is genuinely hard to read, and iOS exposes no per-app
text size for Flutter (the engine reads the *global* Dynamic Type only).
The issue asks for a **Font size control in Settings → Display**, with
3–5 presets, applied to chat text and the rest of the UI, persisted in
`Preferences`.

## Scope

Mobile app only (`app/`). No protocol, relay, pi-extension or cockpit change
(cockpit already has interface-size zoom + code-size settings of its own).

## Design decisions

- **Mechanism = compose the system `TextScaler`, not scale `AppTypography`.**
  The issue proposes multiplying `AppTypography` base sizes, but plenty of
  one-off sizes bypass that SSOT via `.copyWith(fontSize: …)` (settings
  subtitles 12, section headers 11, app-bar 17, input hints 13, framework
  widget text). Scaling only the SSOT would leave the Settings page itself
  unscaled. A `TextScaler` applied through `MaterialApp.builder` scales
  **every** `Text` in the app — typography styles, one-offs and framework
  widgets alike — with zero per-widget edits, which is the issue's actual
  goal ("no per-widget edits needed").
- **Composes with OS accessibility, doesn't replace it.** A tiny
  `ScaledTextScaler` subclass multiplies the ambient scaler
  (`scale(fs) = base.scale(fs) * factor`), preserving iOS's *non-linear*
  accessibility curve instead of flattening it with `TextScaler.linear`.
  User picks 1.15× on top of a 1.3× system setting → 1.5× effective.
- **Presets, not a slider.** Four segments (issue's primary suggestion and
  exact factors): **Small 0.9× / Default 1.0× / Large 1.15× / XL 1.3×**.
  `SegmentedButton` mirrors the existing Theme row's visual language.
  `XL` label (not "Extra Large") keeps 4 segments overflow-safe at 1.3×.
- **Storage** = stable enum name under `prefs.ui_font_scale` in
  `Preferences` (same convention as `theme_mode` / `keep_alive`), garbage →
  `normal`. Enum `UiFontScale` lives in `preferences.dart` next to
  `KeepAliveMode` (data layer owns it; the UI only labels it).

## Expected structure

### `Preferences` (`app/lib/data/preferences/preferences.dart`)

- `enum UiFontScale { small(0.9), normal(1.0), large(1.15), extraLarge(1.3) }`
  with a `double factor` getter.
- Field `_uiFontScale` (default `normal`), key `prefs.ui_font_scale`,
  hydrate in `load()` (`firstWhere(name == raw, orElse: normal)`),
  `uiFontScale` getter + `setUiFontScale` (no-op guard, persist, notify).

### Scaler (`app/lib/ui/core/themes/font_scale.dart`, new)

- `ScaledTextScaler extends TextScaler` — multiplies any base scaler by a
  constant factor (preserves non-linear curves).
- `TextScaler applyFontScale(TextScaler base, double factor)` — returns
  `base` untouched when `factor == 1.0` (identity, zero churn at default).
- Exported via the `themes.dart` barrel.

### App root (`app/lib/main.dart`)

- `MaterialApp.router` gains `builder:` that copies the ambient
  `MediaQuery` with `textScaler: applyFontScale(current, prefs.factor)`.
  Reactive through the existing `Consumer<Preferences>` — changing the
  preset repaints without restart, like Theme mode.

### Settings UI (`app/lib/ui/settings/`)

- New public `FontScalePicker` widget (`widgets/font_scale_picker.dart`,
  barrel-exported) — label + `SegmentedButton<UiFontScale>` + muted caption
  ("Scales all app text on top of the system accessibility size.").
  Public so it's widget-testable without pumping the whole SettingsPage
  (heavy VM deps).
- `_DisplaySection` places it between the Theme row and the chat toggles.

## Steps

1. **Preferences** — enum + field/key/hydrate/getter/setter. ✅
2. **Scaler** — `font_scale.dart` + barrel export. ✅
3. **App root** — `builder` wiring in `MaterialApp.router`. ✅
4. **Settings UI** — `FontScalePicker` + `_DisplaySection` insertion. ✅
5. **Tests**:
   - `preferences_test.dart` — group `uiFontScale`: default `normal`
     (absent key), hydrate, garbage → `normal`, set-notify count,
     cold-start round-trip.
   - `ui/core/themes/font_scale_test.dart` — identity at 1.0×, linear math
     (0.9×/1.15×/1.3×), non-linear base curve preserved through compose.
   - `ui/settings/widgets/font_scale_picker_test.dart` — renders 4 presets,
     tap persists to `Preferences`, current selection marked.
6. **Changelog** — `Unreleased → Added` entry.
7. **Verify** — CI `app-debug` (`flutter test` on PR touching `app/`); no
   local Flutter SDK on this machine.

### Acceptance criteria

- [ ] Settings → Display → Font size: 4 presets, default `Default`,
      selection persists across cold start.
- [ ] Picking a preset rescales **all** app text live (chat, settings,
      dialogs) — no restart.
- [ ] Preset composes multiplicatively with the OS text-size setting and
      preserves non-linear (accessibility) scaling.
- [ ] `flutter test` green in CI; garbage stored value never blocks boot.

## DoD

Merged to `main` via PR from `font`; feature is live in the next app
release; changelog updated.

## Next

- **131b** — optional per-UI-surface scale (e.g. chat-only zoom) if users
  ask for finer control.
- **131c** — upstream PR (jacobaraujo7/remote_pi#114) if the fork wants to
  contribute the change back.
