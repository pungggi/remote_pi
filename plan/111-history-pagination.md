# Plan 111: Pagination for Session History

## Context
By default, the Pi extension returns only the **latest 30 events** on `SessionSync` (env var `REMOTE_PI_SYNC_LIMIT` defaults to 30). Older messages are dropped, and the `truncated: true` flag indicates there's more history.

Users with long sessions cannot scroll back beyond the most recent 30 messages. This is a UX regression for long-running coding sessions.

## Protocol Constraints
- `SessionSync` accepts an optional `limit` parameter (int)
- No `since` parameter exists for incremental loading (would need upstream protocol change)
- Server clamps client limit to `REMOTE_PI_SYNC_LIMIT` env cap
- Server always returns the **latest N** events, not the N before a cursor

## Approach: Progressive Limit Increase

Since we can't paginate with a cursor, we'll use **progressive limit increases**:

1. **Initial sync**: Request `limit: 100` (instead of no limit)
   - Covers 95% of practical sessions
   - Still small bandwidth-wise
   - Server clamps to env cap if lower

2. **Track truncated state**: Store `_truncated = true` when `SessionHistory.truncated: true`

3. **Show "Load more" indicator**: At top of message list when `_truncated` is true

4. **Load more action**: On tap, request higher limit (e.g., 500, then 1000, etc.)

5. **Apply history**: The new `SessionHistory` contains all previous messages (since they're in the latest N) plus older ones. Apply normally via `_applyHistory`.

## Expected Structure

### 1. SyncService changes

```dart
class SyncService {
  // Track whether current session's history is truncated
  bool _truncated = false;
  final _truncatedController = StreamController<bool>.broadcast();
  Stream<bool> get truncatedStream => _truncatedController.stream;
  bool get truncated => _truncated;

  // Progressive limit: start at 100, then 500, 1000, etc.
  static const int _baseLimit = 100;
  int _currentLimit = _baseLimit;

  Future<void> requestSync({bool loadMore = false}) async {
    final ch = _conn.channel;
    if (ch == null || _activeEpk == null) {
      _pendingSyncRequest = true;
      return;
    }
    _pendingSyncRequest = false;

    final limit = loadMore ? _currentLimit * 5 : _currentLimit;
    if (!loadMore) _currentLimit = _baseLimit;  // Reset on normal sync
    else _currentLimit = limit;  // Remember for next "load more"

    ch.send(SessionSync(id: _newId(), limit: limit));
  }

  Future<void> _applyHistory(SessionHistory h) async {
    // ... existing logic ...

    // Track truncated state
    if (h.truncated != _truncated) {
      _truncated = h.truncated;
      _truncatedController.add(_truncated);
    }

    // ... rest of applyHistory ...
  }

  // Reset on session new/clear
  Future<void> clearActiveSession() async {
    _truncated = false;
    _truncatedController.add(false);
    _currentLimit = _baseLimit;
    // ... existing logic ...
  }
}
```

### 2. ChatViewModel changes

Expose `truncated` and `loadMore`:

```dart
class ChatViewModel extends ViewModel<ChatState> {
  final SyncService _sync;

  bool get truncated => _sync.truncated;

  Future<void> loadMoreHistory() async {
    await _sync.requestSync(loadMore: true);
  }
}
```

### 3. ChatPage changes

Add "Load more" indicator at top when truncated:

```dart
ListView.separated(
  itemCount: itemCount + (truncated ? 1 : 0),
  itemBuilder: (context, i) {
    // Load more button at the top (index = itemCount)
    if (truncated && i == itemCount) {
      return Center(
        child: TextButton.icon(
          icon: Icon(LucideIcons.refreshCw, size: 16),
          label: Text('Load more messages'),
          onPressed: () => vm.loadMoreHistory(),
        ),
      );
    }

    // Normal message rendering (adjust indices)
    // ...
  },
)
```

### 4. SessionInfo dialog (optional enhancement)

Show current limit + truncated status:

```dart
Text('History: ${vm.messages.length} messages${truncated ? ' (truncated)' : ''}')
```

## Steps with Acceptance Criteria

### Step 1: Add limit-based requestSync to SyncService
- Change `requestSync()` to accept `loadMore` parameter
- Calculate progressive limit (100 → 500 → 2500 → ...)
- Send `SessionSync(id: ..., limit: limit)`
- Reset limit to base on normal sync, keep it on loadMore

**Acceptance:**
- ✅ `requestSync()` sends `limit: 100` by default
- ✅ `requestSync(loadMore: true)` sends higher limit (500)
- ✅ Repeated loadMore increases limit progressively

### Step 2: Track truncated state in SyncService
- Add `_truncated` field and `_truncatedController` stream
- Update `_applyHistory()` to set `_truncated = h.truncated`
- Stream emits when truncated state changes
- Reset on `clearActiveSession()`

**Acceptance:**
- ✅ `_truncated` is `true` when `SessionHistory.truncated: true`
- ✅ Stream emits on state change
- ✅ Reset to `false` on session clear

### Step 3: Expose in ChatViewModel
- Add `truncated` getter
- Add `loadMoreHistory()` method

**Acceptance:**
- ✅ `ChatViewModel.truncated` reflects `SyncService.truncated`
- ✅ `loadMoreHistory()` calls `requestSync(loadMore: true)`

### Step 4: Show "Load more" button in chat
- Add button at top of message list when `truncated` is `true`
- Button calls `vm.loadMoreHistory()`
- Use `refreshCw` icon + "Load more messages" label

**Acceptance:**
- ✅ Button appears when history is truncated
- ✅ Button disappears when not truncated
- ✅ Tapping loads more history

### Step 5: Test with truncated session
- Set `REMOTE_PI_SYNC_LIMIT=30` on Mac Pi (low limit for testing)
- Generate 50+ messages in a session
- Open app → should see "Load more messages" button
- Tap button → older messages appear, button may persist (if still truncated)
- Repeat until all history loaded

**Acceptance:**
- ✅ Button appears for truncated sessions
- ✅ Tapping loads older messages
- ✅ Can load all history eventually

## Definition of Done
- `requestSync()` accepts `loadMore` parameter and sends progressive limits
- `SyncService` tracks and streams `truncated` state
- `ChatViewModel` exposes `truncated` and `loadMoreHistory()`
- Chat page shows "Load more messages" button at top when truncated
- `dart analyze lib test` clean
- `flutter test` passes
- APK installed and tested with a truncated session

## Next Plans
None — this completes the session history UX for long sessions.

## Notes
- The env cap `REMOTE_PI_SYNC_LIMIT` on the Pi side still applies. If it's 30, even sending `limit: 500` only returns 30. Users should set `REMOTE_PI_SYNC_LIMIT=500` or higher on the Mac for this to work well.
- Progressive limits: 100 → 500 → 2500 → 12500 (5× each time). This covers most cases without sending absurdly large payloads.
- Once the limit exceeds the total messages, `truncated` becomes `false` and the button disappears.
- This is a pragmatic workaround until upstream adds proper pagination (`since` parameter).

## Upstream Coordination (future)
To implement true incremental loading, upstream needs to add:
1. `since` parameter to `SessionSync` (timestamp cursor)
2. Pi extension to return events **older than** the cursor when `since` is set
3. App to store oldest local timestamp and request older chunks

This is a larger protocol change and should be proposed to upstream separately.