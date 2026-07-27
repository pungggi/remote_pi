# Plan 110: Collapsible Tool Calls in Chat

## Context
Tool calls (`ToolEvent` messages) are currently rendered by `ToolRequestCard` as fully-expanded cards showing:
- Header with status icon + text
- Code block with the tool invocation
- Outcome (error/completion info)

The user wants tool calls to be **collapsed by default**, with the ability to click/tap to expand them and see full details. This reduces chat noise when the AI makes many tool calls.

## Expected Structure

### 1. Settings (`Preferences` + Settings UI)
Add a new setting to control the default collapsed state:

**Preferences (`lib/data/preferences/preferences.dart`)**
```dart
bool _collapseToolCalls = true;  // Default: collapsed
static const _kCollapseToolCallsKey = 'prefs.collapse_tool_calls';

bool get collapseToolCalls => _collapseToolCalls;

Future<void> setCollapseToolCalls(bool value) async {
  if (_collapseToolCalls == value) return;
  _collapseToolCalls = value;
  await _store.write(key: _kCollapseToolCallsKey, value: value.toString());
  notifyListeners();
}
```

Load in `load()` method.

**Settings UI (`lib/ui/settings/settings_page.dart`)**
Add a `SwitchListTile` below the existing "Hide tool calls in chat" toggle:

```dart
SwitchListTile(
  contentPadding: const EdgeInsets.symmetric(horizontal: 18),
  activeThumbColor: colors.accent,
  title: Text(
    'Collapse tool calls in chat',
    style: context.typo.sansBody.copyWith(color: colors.text),
  ),
  subtitle: Text(
    'Tap a collapsed tool call to expand it.',
    style: context.typo.sansBody.copyWith(
      color: colors.muted,
      fontSize: 12,
    ),
  ),
  value: prefs.collapseToolCalls,
  onChanged: (v) => prefs.setCollapseToolCalls(v),
),
```

### 2. Collapsible Tool Card (`ToolRequestCard`)
Convert `ToolRequestCard` from `StatelessWidget` to `StatefulWidget`:

- Add local state: `bool _expanded`
- Initial state: read from `Preferences.collapseToolCalls` (inverted: if `collapseToolCalls` is true, start collapsed; if false, start expanded)
- Build:
  - **Collapsed**: Minimal row showing tool name + status icon + chevron-right
  - **Expanded**: Current full card layout (header + code block + outcome)
- Toggle `_expanded` on tap

**Collapsed view design:**
```dart
Container(
  decoration: BoxDecoration(
    color: context.colors.surface,
    border: Border.all(color: color, width: 1),
    borderRadius: BorderRadius.circular(12),
  ),
  child: ListTile(
    contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
    leading: Icon(_statusIcon, color: color, size: 18),
    title: Text(
      tool.tool,
      style: context.typo.mono.copyWith(color: colors.text, fontSize: 13),
    ),
    trailing: Icon(LucideIcons.chevronRight, color: colors.muted, size: 16),
    onTap: () => setState(() => _expanded = true),
  ),
)
```

**Expanded view:** wrap the existing build content in a container with tap handler.

### 3. Preferences Watch in ToolRequestCard
`ToolRequestCard` needs access to `Preferences` to read the setting. Options:
- Pass `Preferences` as a required parameter to `ToolRequestCard`
- Use `context.watch<Preferences>()` inside the build (but this requires `ToolRequestCard` to have `context` access, which it does)

Simpler: use `context.watch<Preferences>()` in build to read the setting. But wait — the initial expansion state needs to be set when the widget is first built, not re-calculated on every rebuild from the setting.

Better approach: The setting controls the **initial** collapsed state. Once the user manually expands/collapses a specific tool card, that overrides the setting for that card. So:
- Initialize `_expanded = !prefs.collapseToolCalls` (if `collapseToolCalls` is true, start collapsed)
- On tap, toggle `_expanded`
- Don't react to pref changes after initialization (each card's state is independent)

### 4. Status Icon Helper
Add a helper to map `ToolEventStatus` to an icon:
```dart
IconData _statusIcon(BuildContext context) {
  return switch (tool.status) {
    ToolEventStatus.pending || ToolEventStatus.allowed => LucideIcons.loader2,
    ToolEventStatus.completed => LucideIcons.check,
    ToolEventStatus.failed => LucideIcons.x,
    ToolEventStatus.denied || ToolEventStatus.expired => LucideIcons.ban,
  };
}
```

### 5. Transition Animation
Optional: animate the expand/collapse with `AnimatedSize` for a smooth feel.

## Steps with Acceptance Criteria

### Step 1: Add `collapseToolCalls` setting to `Preferences`
- Add private field `_collapseToolCalls = true`
- Add storage key constant
- Add getter/setter
- Update `load()` to hydrate from storage
- Add test: default is `true` before load, persists correctly

**Acceptance:**
- ✅ `preferences.collapseToolCalls` defaults to `true` before `load()`
- ✅ `load()` reads from `prefs.collapse_tool_calls` and sets the value
- ✅ `setCollapseToolCalls()` writes to storage and notifies listeners

### Step 2: Add toggle in Settings UI
- Add `SwitchListTile` for "Collapse tool calls in chat" in `_DisplaySection`
- Wire to `prefs.collapseToolCalls` and `prefs.setCollapseToolCalls`

**Acceptance:**
- ✅ Toggle appears below "Hide tool calls in chat"
- ✅ Toggling persists the setting
- ✅ Setting persists across app restarts

### Step 3: Make `ToolRequestCard` a `StatefulWidget`
- Convert to `StatefulWidget` with `_ToolRequestCardState`
- Add `_expanded` state field (initialized from `Preferences`)
- Add `_statusIcon` helper
- Split build into `_buildCollapsed()` and `_buildExpanded()`

**Acceptance:**
- ✅ Card renders as collapsed row when setting is true
- ✅ Card renders as expanded full card when setting is false
- ✅ Tapping the collapsed row expands it
- ✅ Tapping the expanded card collapses it

### Step 4: Animate expand/collapse (optional but nice)
- Wrap the expanded content in `AnimatedSize`
- Add `duration: const Duration(milliseconds: 200)`
- Keep collapsed view unanimated (just a switch)

**Acceptance:**
- ✅ Expand/collapse animates smoothly
- ✅ Animation duration is reasonable (~200ms)

### Step 5: Test the UI
- Start a pi session
- Trigger a tool call (ask agent to run `bash ls`)
- Verify:
  - Tool call appears collapsed (if setting is on)
  - Tapping expands to show full details
  - Tapping again collapses
  - Changing the setting affects new cards

**Acceptance:**
- ✅ Tool calls collapse/expand as expected
- ✅ Setting persists and affects default state

## Definition of Done
- `collapseToolCalls` setting added to `Preferences` with default `true`
- Settings UI has toggle below "Hide tool calls in chat"
- `ToolRequestCard` is collapsible with a collapsed row view (tool name + icon + chevron)
- Tapping a collapsed card expands it to full details
- Tapping an expanded card collapses it back
- `dart analyze lib test` clean
- `flutter build apk --debug` succeeds
- APK installed on phone and tested with a live tool call

## Next Plans
None — this is a standalone UI improvement.

## Notes
- The `hideToolCalls` setting completely hides tool events from the message list. `collapseToolCalls` complements it: when hidden, no tool calls show; when shown, they're collapsed by default but expandable.
- If the user toggles `hideToolCalls` → `true`, the collapsed state is irrelevant (no tools render). Toggling back to `false` should use the `collapseToolCalls` setting for new cards.
- Each tool card's expansion state is local; no persistence of which cards were expanded across session changes (simplifies the implementation).