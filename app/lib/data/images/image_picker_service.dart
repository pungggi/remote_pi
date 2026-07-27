import 'dart:typed_data';

import 'package:flutter/services.dart' show MethodChannel, PlatformException;
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:image_picker/image_picker.dart';

/// Plan/30 — pick one image from the camera or the gallery and compress it
/// (JPEG, longest side ≤1568px, q80) entirely on-device before it travels
/// inline on a `user_message`. No file is uploaded out-of-band.
///
/// The plugin calls go through the [ImagePickerBackend] seam so the
/// pick + iterative size-ceiling logic is unit-testable without a device.
abstract class IImagePickerService {
  /// Capture a photo. Returns null if the user cancelled. Throws
  /// [ImagePermissionDeniedException] when camera permission is denied (#10).
  Future<PickedImage?> pickFromCamera();

  /// Pick from the gallery (system PHPicker / Photo Picker — no permission).
  /// Returns null if the user cancelled.
  Future<PickedImage?> pickFromGallery();

  /// Plan/30-followup — read an image from the system clipboard (e.g. an
  /// Android screenshot). Returns null when the clipboard holds no image.
  /// Default returns null so test fakes / unsupported platforms are unaffected.
  Future<PickedImage?> pickFromClipboard() async => null;

  /// Plan/104 — consume an image shared into the app via Android's Share
  /// sheet (ACTION_SEND). Returns null when there's no pending share.
  /// Default returns null so test fakes / unsupported platforms are unaffected.
  Future<PickedImage?> consumeSharedImage() async => null;

  /// Plan/104 — text shared via the Share sheet (ACTION_SEND text/plain).
  /// Returns null when there's no pending text share. Default returns null so
  /// test fakes / unsupported platforms are unaffected.
  Future<String?> consumeSharedText() async => null;
}

/// A picked + compressed image ready for preview and sending. Bytes are raw
/// (not base64) so the composer preview renders them directly; the send path
/// base64-encodes into a `MessageImage`.
class PickedImage {
  final Uint8List bytes;
  final String mime;
  const PickedImage({required this.bytes, required this.mime});
}

/// Thrown when the camera permission was denied — the UI guides the user to
/// system Settings (reuses the plan-29 `app_settings` affordance).
class ImagePermissionDeniedException implements Exception {
  const ImagePermissionDeniedException();
  @override
  String toString() => 'ImagePermissionDeniedException';
}

class ImagePickerService implements IImagePickerService {
  ImagePickerService([ImagePickerBackend? backend])
    : _backend = backend ?? PlatformImagePickerBackend();

  final ImagePickerBackend _backend;

  /// Longest side of the compressed image (decision #5).
  static const int _maxSide = 1568;

  /// Initial JPEG quality (decision #5).
  static const int _quality = 80;

  /// Safety ceiling — re-compress harder if we somehow blow past this
  /// (rare; the defaults land ~150–400 KB).
  static const int _ceilingBytes = 1500 * 1024;

  /// Max extra passes before we accept whatever we have.
  static const int _maxExtraPasses = 3;

  @override
  Future<PickedImage?> pickFromCamera() =>
      _pickAndCompress(ImageSourceKind.camera);

  @override
  Future<PickedImage?> pickFromGallery() =>
      _pickAndCompress(ImageSourceKind.gallery);

  @override
  Future<PickedImage?> pickFromClipboard() async {
    // Dedicated channel (MainActivity) reads the Android clipboard's image
    // URI → bytes. Returns null when there's no image (text-only / empty).
    const channel = MethodChannel('ch.pungitore.piper/clipboard');
    try {
      final res = await channel.invokeMethod<Map>('readImage');
      if (res == null) return null;
      final raw = res['data'];
      if (raw is! Uint8List) return null;
      // Compress like the other pickers — a screenshot PNG can be several MB.
      final bytes = await FlutterImageCompress.compressWithList(
        raw,
        minWidth: _maxSide,
        minHeight: _maxSide,
        quality: _quality,
      );
      return PickedImage(bytes: bytes, mime: 'image/jpeg');
    } on Exception {
      return null;
    }
  }

  @override
  Future<PickedImage?> consumeSharedImage() async {
    // Dedicated channel (MainActivity) returns the image shared via the
    // Android Share sheet (ACTION_SEND), then clears its stash. Null = none.
    const channel = MethodChannel('ch.pungitore.piper/share');
    try {
      final res = await channel.invokeMethod<Map>('consumeImage');
      if (res == null) return null;
      final raw = res['data'];
      if (raw is! Uint8List) return null;
      // Compress like the other pickers — a shared screenshot can be large.
      final bytes = await FlutterImageCompress.compressWithList(
        raw,
        minWidth: _maxSide,
        minHeight: _maxSide,
        quality: _quality,
      );
      return PickedImage(bytes: bytes, mime: 'image/jpeg');
    } on Exception {
      return null;
    }
  }

  @override
  Future<String?> consumeSharedText() async {
    const channel = MethodChannel('ch.pungitore.piper/share');
    try {
      return await channel.invokeMethod<String>('consumeText');
    } on Exception {
      return null;
    }
  }

  Future<PickedImage?> _pickAndCompress(ImageSourceKind source) async {
    final path = await _backend.pick(source);
    if (path == null) return null; // user cancelled

    var side = _maxSide;
    var quality = _quality;
    var bytes = await _backend.compress(path, maxSide: side, quality: quality);

    // Iterative ceiling: shrink dimension + quality until under the cap (or
    // we run out of passes). Practically never fires.
    var pass = 0;
    while (bytes.length > _ceilingBytes && pass < _maxExtraPasses) {
      pass++;
      quality = (quality - 15).clamp(35, 100);
      side = (side * 0.85).round();
      bytes = await _backend.compress(path, maxSide: side, quality: quality);
    }

    return PickedImage(bytes: bytes, mime: 'image/jpeg');
  }
}

// ---------------------------------------------------------------------------
// Backend seam
// ---------------------------------------------------------------------------

enum ImageSourceKind { camera, gallery }

/// Thin seam over `image_picker` + `flutter_image_compress`.
abstract class ImagePickerBackend {
  /// Pick a file; returns its path, or null if cancelled. Throws
  /// [ImagePermissionDeniedException] on a denied camera permission.
  Future<String?> pick(ImageSourceKind source);

  /// Compress [path] to JPEG bounded by [maxSide]px at [quality].
  Future<Uint8List> compress(
    String path, {
    required int maxSide,
    required int quality,
  });
}

class PlatformImagePickerBackend implements ImagePickerBackend {
  PlatformImagePickerBackend([ImagePicker? picker])
    : _picker = picker ?? ImagePicker();

  final ImagePicker _picker;

  @override
  Future<String?> pick(ImageSourceKind source) async {
    try {
      final file = await _picker.pickImage(
        source: source == ImageSourceKind.camera
            ? ImageSource.camera
            : ImageSource.gallery,
      );
      return file?.path;
    } on PlatformException catch (e) {
      // image_picker surfaces a denied camera/photo permission as a
      // PlatformException with an `*_access_denied` code.
      if (e.code.contains('access_denied') || e.code.contains('denied')) {
        throw const ImagePermissionDeniedException();
      }
      rethrow;
    }
  }

  @override
  Future<Uint8List> compress(
    String path, {
    required int maxSide,
    required int quality,
  }) async {
    final out = await FlutterImageCompress.compressWithFile(
      path,
      minWidth: maxSide,
      minHeight: maxSide,
      quality: quality,
      format: CompressFormat.jpeg,
    );
    // Fallback: if the platform compressor returns null (unsupported source
    // format), surface an empty result so the caller can no-op gracefully.
    return out ?? Uint8List(0);
  }
}
