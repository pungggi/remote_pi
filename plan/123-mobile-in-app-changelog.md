# Plan 123 — Mobile: in-app changelog (What's new)

## Context

The repo maintains a `CHANGELOG.md` (Keep-a-Changelog format) at the root, but
none of it is visible from the phone. After an update the user has no in-app
way to see what changed. This plan surfaces the **last entries** of the
changelog inside Settings, alongside the running app version.

Mirrors what the cockpit could do later; mobile-first here.

## Scope

Mobile app only (`app/`). No protocol / relay / extension change. The
changelog is a **client-side read-only view** — source of truth stays the
repo-root `CHANGELOG.md`.

## Design decisions

- **Source = bundled asset, not fetched.** The repo `CHANGELOG.md` is copied
  to `app/assets/CHANGELOG.md` and declared in `pubspec.yaml`. Reasons: works
  offline; always reflects the *installed* build (no unreleased entries leak
  from a live `main`); no new network dependency. The copy is refreshed at
  release (`cp CHANGELOG.md app/assets/CHANGELOG.md`) — documented in
  `pubspec.yaml`.
- **"Entry" = a `## [...]` header + its body.** The Keep-a-Changelog level-2
  headers are the version entries; deeper `### Added` subsections stay inside
  the body they belong to. Preamble (before the first `## `) is dropped.
- **Cap = 5** entries, newest first (file order) — scannable on a phone.
- **Render with the existing `AgentMarkdown`** (wraps `GptMarkdown`): same
  theming, links, and code blocks the chat uses. No new markdown dependency.

## Expected structure

- `app/lib/domain/entities/changelog_entry.dart` — `ChangelogEntry` model +
  `parseChangelog(md, {limit = 5})` (split on `## `, take 5).
- `app/lib/ui/settings/changelog_page.dart` — `ChangelogPage`: loads
  `assets/CHANGELOG.md` via `rootBundle`, parses, renders each entry (accent
  header + `AgentMarkdown` body). States: loading / empty / list / error.
- `app/lib/ui/settings/settings_page.dart` — new **About** section at the
  bottom: app **Version** (from `package_info_plus`) + **What's new** row →
  `/settings/changelog`.
- `app/lib/routing/app_router.dart` — `GoRoute('/settings/changelog',
  ChangelogPage())`.
- `app/pubspec.yaml` — `flutter.assets: [assets/CHANGELOG.md]`.
- `app/assets/CHANGELOG.md` — copy of repo root `CHANGELOG.md`.

## Steps

1. Parser + model. ✅
2. ChangelogPage (asset load → parse → markdown render). ✅
3. Settings About section (version + What's new entry). ✅
4. Route + pubspec asset + copy. ✅
5. Verify: `dart analyze` clean; APK contains
   `assets/flutter_assets/assets/CHANGELOG.md`; build + install to device;
   Settings → About → What's new shows the last entries.

### Acceptance criteria

- [ ] Settings has an About section showing the app version.
- [ ] "What's new" opens a page listing the last 5 changelog entries, rendered
      as markdown (headers, bullets, code).
- [ ] Works offline (bundled asset).
- [ ] `dart analyze` clean on touched files; no new test regressions.

## DoD

Last changelog entries are viewable in-app at Settings → About → What's new,
offline, matching the installed build. Committed + pushed; build installed to
the test device.

## Next

- **123b** — keep the copy fresh automatically: a pre-build sync step
  (`scripts/sync-changelog.mjs` mirroring `site`'s install-sh sync) so a
  release can't ship a stale asset.
- **123c** — fetch a richer manifest from the release host (multi-version
  `changelog.json`) so the view can show post-install releases too.
- **123d** — surface a "new since you last opened" badge on the Settings entry.
