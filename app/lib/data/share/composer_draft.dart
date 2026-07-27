import 'package:app/data/images/image_picker_service.dart';
import 'package:flutter/foundation.dart';

/// Plan/106 — the follow-me composer draft: the single unsent message
/// (text + attached images) that follows the user across session switches
/// until sent or discarded.
///
/// Why it exists: `InputBar`'s `TextEditingController` and the
/// route-scoped `AttachmentViewModel` are recreated on every session switch
/// (Phone: pop/push `/chat`; Tablet: detail pane keyed per session), so an
/// unsent draft would be lost. This holder survives those recreations: the
/// old composer writes to it on every change, the fresh one reads it on mount.
///
/// In-memory only — survives switches + backgrounding (the FG service keeps
/// the process alive), lost on app kill/restart.
class ComposerDraft extends ChangeNotifier {
  String _text = '';
  List<PickedImage> _images = const [];

  String get text => _text;
  List<PickedImage> get images => _images;

  bool get hasContent => _text.isNotEmpty || _images.isNotEmpty;

  void setText(String value) {
    if (_text == value) return;
    _text = value;
    notifyListeners();
  }

  void setImages(List<PickedImage> images) {
    final next = List<PickedImage>.unmodifiable(images);
    if (_sameImages(next)) return;
    _images = next;
    notifyListeners();
  }

  /// Clear both halves (called after a successful send).
  void clear() {
    if (_text.isEmpty && _images.isEmpty) return;
    _text = '';
    _images = const [];
    notifyListeners();
  }

  bool _sameImages(List<PickedImage> other) {
    if (_images.length != other.length) return false;
    for (var i = 0; i < _images.length; i++) {
      if (!identical(_images[i], other[i])) return false;
    }
    return true;
  }
}
