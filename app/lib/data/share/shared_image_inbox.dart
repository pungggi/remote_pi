import 'package:app/data/images/image_picker_service.dart';
import 'package:flutter/foundation.dart';

/// Plan/104 — holds an image shared into the app from Android's Share sheet
/// (or, in future, other inbound paths) until a chat consumes it.
///
/// The chat's [AttachmentViewModel] is route-scoped (rebuilt per `/chat`
/// mount), so the pending image must live in an app-global holder that
/// survives across the boot → home → chat transition and across warm shares.
///
/// - [deposit] stores + notifies; the live chat's AttachmentViewModel reacts.
/// - [consume] reads + clears (single-shot) — called by AttachmentViewModel
///   when it mounts or when a deposit arrives while it's already on screen.
/// - [hasPending] / [peek] are non-consuming observers (e.g. to decide whether
///   to route to the chat).
class SharedImageInbox extends ChangeNotifier {
  PickedImage? _pending;

  bool get hasPending => _pending != null;

  /// Non-consuming look (e.g. for routing decisions).
  PickedImage? get peek => _pending;

  /// Store a shared image and notify listeners (the chat attaches; the router
  /// listener may navigate to `/chat`).
  void deposit(PickedImage image) {
    _pending = image;
    notifyListeners();
  }

  /// Take the pending image (clears it). Returns null when there's nothing.
  PickedImage? consume() {
    final img = _pending;
    _pending = null;
    return img;
  }
}
