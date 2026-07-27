import 'package:app/data/images/image_picker_service.dart';

/// Plan/30 — composer attachment state.
///
/// Models the one-image pick lifecycle (empty → picking → attached) and
/// carries [visionSupported] so the attach button can grey out for a
/// text-only model (#9). `visionSupported` is tri-state: `true`/`false` once
/// the model catalogue is known, `null` while unknown (don't gate yet).
sealed class AttachmentState {
  const AttachmentState({required this.visionSupported});

  /// Whether the active model accepts images. `null` = not yet known.
  final bool? visionSupported;

  /// Convenience: gate the attach affordance only when we *know* it's false.
  bool get attachBlockedByVision => visionSupported == false;
}

/// No image attached; composer behaves as text/voice.
final class AttachmentEmpty extends AttachmentState {
  const AttachmentEmpty({super.visionSupported});

  @override
  bool operator ==(Object other) =>
      other is AttachmentEmpty && other.visionSupported == visionSupported;

  @override
  int get hashCode => visionSupported.hashCode;
}

/// A pick is in flight (camera/gallery sheet → compression).
final class AttachmentPicking extends AttachmentState {
  const AttachmentPicking({super.visionSupported});

  @override
  bool operator ==(Object other) =>
      other is AttachmentPicking && other.visionSupported == visionSupported;

  @override
  int get hashCode => visionSupported.hashCode;
}

/// An image (or, plan/105, several — a PDF's pages) is attached and previewed
/// in the composer. [images] is always non-empty in this state.
final class AttachmentAttached extends AttachmentState {
  const AttachmentAttached({required this.images, super.visionSupported});

  /// The attached images: one for camera/gallery/clipboard/image-share, N
  /// pages for a shared PDF.
  final List<PickedImage> images;

  /// The first image — e.g. for the optimistic DB row / preview focus.
  PickedImage get first => images.first;

  @override
  bool operator ==(Object other) =>
      other is AttachmentAttached &&
      other.images.length == images.length &&
      _identicalList(other.images, images) &&
      other.visionSupported == visionSupported;

  @override
  int get hashCode => Object.hash(Object.hashAll(images), visionSupported);

  // PickedImage has no `==` override, so identity is the right comparison.
  static bool _identicalList(List<PickedImage> a, List<PickedImage> b) {
    for (var i = 0; i < a.length; i++) {
      if (!identical(a[i], b[i])) return false;
    }
    return true;
  }
}

/// One-shot hints the composer asks the host page to surface (snackbar /
/// settings deep-link), mirroring the voice [VoiceHint] pattern.
enum AttachHint {
  /// Camera permission denied — guide to system Settings (#10).
  cameraPermissionDenied,

  /// Pick/compress failed for some other reason.
  pickFailed,

  /// Clipboard had no image when the user hit "Paste image".
  noImageInClipboard,
}
