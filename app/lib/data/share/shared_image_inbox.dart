import 'package:app/data/images/image_picker_service.dart';
import 'package:flutter/foundation.dart';

/// Plan/104 — holds image(s) shared into the app from Android's Share sheet
/// (a single image, or N pages rendered from a shared PDF) until a chat
/// consumes them.
///
/// The chat's [AttachmentViewModel] is route-scoped (rebuilt per `/chat`
/// mount), so the pending images must live in an app-global holder that
/// survives across the boot → home → chat transition and across warm shares.
///
/// - [deposit] stores + notifies; the live chat's AttachmentViewModel reacts.
/// - [consume] reads + clears (single-shot) — called by AttachmentViewModel
///   when it mounts or when a deposit arrives while it's already on screen.
/// - [hasPending] / [peek] are non-consuming observers (e.g. to decide whether
///   to route to the chat).
class SharedImageInbox extends ChangeNotifier {
  List<PickedImage> _pending = const [];

  bool get hasPending => _pending.isNotEmpty;

  /// Non-consuming look (e.g. for routing decisions).
  List<PickedImage> get peek => _pending;

  /// Store shared images (one for an image share, N for a PDF) and notify
  /// listeners (the chat attaches; the router listener may navigate `/chat`).
  void deposit(List<PickedImage> images) {
    _pending = List<PickedImage>.unmodifiable(images);
    notifyListeners();
  }

  /// Take the pending images (clears). Returns an empty list when empty.
  List<PickedImage> consume() {
    final p = _pending;
    _pending = const [];
    return p;
  }
}
