import 'dart:async';
import 'dart:convert';

import 'package:app/data/actions/actions_repository.dart';
import 'package:app/data/images/image_picker_service.dart';
import 'package:app/data/share/shared_image_inbox.dart';
import 'package:app/domain/session_state.dart';
import 'package:app/ui/chat/attachment/states/attachment_state.dart';
import 'package:app/ui/core/viewmodel/viewmodel.dart';

/// Plan/30 — drives image attachment for the composer.
///
/// Owns the picked-image preview state and tracks whether the active model
/// accepts images (`vision`). Vision is resolved from the model catalogue the
/// app already fetches for the quick-actions picker (plan 28): cached in
/// [IActionsRepository], re-resolved whenever the active model changes.
class AttachmentViewModel extends ViewModel<AttachmentState> {
  AttachmentViewModel(this._picker, this._actions, [SharedImageInbox? inbox])
    : _inbox = inbox ?? SharedImageInbox(),
      super(const AttachmentEmpty()) {
    _metaSub = _actions.activeRoomMetaStream.listen((_) => _refreshVision());
    // ignore: discarded_futures
    _refreshVision();
    // Plan/104 — attach a shared image if one is pending, and react to a share
    // arriving while the chat is already on screen.
    _inbox.addListener(_onSharedImage);
    _consumeSharedImage();
  }

  final IImagePickerService _picker;
  final IActionsRepository _actions;
  final SharedImageInbox _inbox;

  StreamSubscription<ActiveRoomMeta>? _metaSub;
  bool _resolvingVision = false;

  final StreamController<AttachHint> _hints =
      StreamController<AttachHint>.broadcast();

  /// One-shot hints (permission denied / pick failed) for the host page.
  Stream<AttachHint> get hints => _hints.stream;

  bool get hasImage => state is AttachmentAttached;

  // ---------------------------------------------------------------------------
  // Picking
  // ---------------------------------------------------------------------------

  Future<void> pickFromCamera() => _pick(_picker.pickFromCamera);
  Future<void> pickFromGallery() => _pick(_picker.pickFromGallery);

  /// Plan/30-followup — paste an image from the clipboard (no picker sheet).
  /// Distinct from [_pick]: a null result means "no image in the clipboard"
  /// (not "cancelled"), surfaced as a hint rather than a silent no-op.
  Future<void> pickFromClipboard() async {
    if (state is AttachmentPicking) return;
    final vision = state.visionSupported;
    emit(AttachmentPicking(visionSupported: vision));
    try {
      final img = await _picker.pickFromClipboard();
      if (img == null) {
        emit(AttachmentEmpty(visionSupported: vision));
        if (!_hints.isClosed) _hints.add(AttachHint.noImageInClipboard);
        return;
      }
      emit(AttachmentAttached(images: [img], visionSupported: vision));
    } catch (_) {
      emit(AttachmentEmpty(visionSupported: vision));
      if (!_hints.isClosed) _hints.add(AttachHint.pickFailed);
    }
  }

  Future<void> _pick(Future<PickedImage?> Function() pick) async {
    if (state is AttachmentPicking) return;
    final vision = state.visionSupported;
    emit(AttachmentPicking(visionSupported: vision));
    try {
      final img = await pick();
      if (img == null) {
        emit(AttachmentEmpty(visionSupported: vision)); // cancelled
        return;
      }
      emit(AttachmentAttached(images: [img], visionSupported: vision));
    } on ImagePermissionDeniedException {
      emit(AttachmentEmpty(visionSupported: vision));
      if (!_hints.isClosed) _hints.add(AttachHint.cameraPermissionDenied);
    } catch (_) {
      emit(AttachmentEmpty(visionSupported: vision));
      if (!_hints.isClosed) _hints.add(AttachHint.pickFailed);
    }
  }

  /// Discard all attached images (the preview's clear).
  void removeImage() {
    if (state is! AttachmentAttached) return;
    emit(AttachmentEmpty(visionSupported: state.visionSupported));
  }

  /// Plan/105 — remove a single image (per-thumbnail X). Clears the
  /// attachment when the last one is removed.
  void removeImageAt(int index) {
    final s = state;
    if (s is! AttachmentAttached) return;
    if (index < 0 || index >= s.images.length) return;
    final next = [...s.images]..removeAt(index);
    if (next.isEmpty) {
      emit(AttachmentEmpty(visionSupported: s.visionSupported));
    } else {
      emit(AttachmentAttached(images: next, visionSupported: s.visionSupported));
    }
  }

  // Plan/104 — shared-image inbound path.
  void _onSharedImage() => _consumeSharedImage();

  void _consumeSharedImage() {
    final imgs = _inbox.consume();
    if (imgs.isNotEmpty) attachAll(imgs);
  }

  /// Attach already-picked images (e.g. shared into the app — one image, or a
  /// PDF's pages), preserving the current vision flag.
  void attachAll(List<PickedImage> imgs) {
    if (imgs.isEmpty) return;
    emit(AttachmentAttached(images: imgs, visionSupported: state.visionSupported));
  }

  /// Hand all attached images to the send path as base64 [MessageImage]s and
  /// reset to empty. Returns an empty list when nothing is attached.
  List<MessageImage> takeImagesForSend() {
    final s = state;
    if (s is! AttachmentAttached) return const [];
    emit(AttachmentEmpty(visionSupported: s.visionSupported));
    return s.images
        .map((i) => MessageImage(data: base64Encode(i.bytes), mime: i.mime))
        .toList();
  }

  // ---------------------------------------------------------------------------
  // Vision tracking (#9)
  // ---------------------------------------------------------------------------

  Future<void> _refreshVision() async {
    if (_resolvingVision) return;
    _resolvingVision = true;
    try {
      // Cached per (peer, room) by the repo; only the round-trip after a real
      // model change actually hits the Pi.
      final catalogue = await _actions.listModels();
      _setVision(_resolveVision(catalogue));
    } catch (_) {
      // Offline / no catalogue yet → leave vision unknown (don't gate).
    } finally {
      _resolvingVision = false;
    }
  }

  bool? _resolveVision(ModelsCatalogue catalogue) {
    final current = catalogue.current;
    if (current != null) return current.vision;
    // No explicit current — match the active room's model name.
    final name = _actions.activeRoomMeta.model;
    if (name != null) {
      for (final m in catalogue.models) {
        if (m.name == name) return m.vision;
      }
    }
    return null;
  }

  void _setVision(bool? vision) {
    if (vision == state.visionSupported) return;
    emit(switch (state) {
      AttachmentEmpty() => AttachmentEmpty(visionSupported: vision),
      AttachmentPicking() => AttachmentPicking(visionSupported: vision),
      AttachmentAttached(:final images) => AttachmentAttached(
        images: images,
        visionSupported: vision,
      ),
    });
  }

  @override
  void dispose() {
    _inbox.removeListener(_onSharedImage);
    _metaSub?.cancel();
    _hints.close();
    super.dispose();
  }
}
