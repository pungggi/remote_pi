import 'package:flutter/foundation.dart';

/// Plan/104 — holds text shared into the app from Android's Share sheet
/// (ACTION_SEND with type `text/plain`, e.g. a URL or snippet) until a chat
/// consumes it.
///
/// Mirrors [SharedImageInbox]. The chat's InputBar is route-scoped (rebuilt
/// per `/chat` mount), so the pending text must live in an app-global holder
/// that survives across the boot → home → chat transition and across warm
/// shares.
///
/// - [deposit] stores + notifies; the live chat's InputBar reacts.
/// - [consume] reads + clears (single-shot) — called by InputBar when it
///   mounts or when a deposit arrives while it's already on screen.
/// - [hasPending] is a non-consuming observer (e.g. to decide whether to
///   route to the chat).
class SharedTextInbox extends ChangeNotifier {
  String? _pending;

  bool get hasPending => _pending != null;

  /// Store shared text and notify listeners (the chat fills the input; the
  /// router listener may navigate to `/chat`).
  void deposit(String text) {
    _pending = text;
    notifyListeners();
  }

  /// Take the pending text (clears it). Returns null when there's nothing.
  String? consume() {
    final t = _pending;
    _pending = null;
    return t;
  }
}
