import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:cockpit/app/core/utils/path_utils.dart';
import 'package:flutter/services.dart';

/// Seletor de **pasta** nativo, unificado por plataforma.
///
/// No **macOS** usa um canal próprio (`cockpit/native_dialogs`, implementado no
/// Runner Swift) que abre o `NSOpenPanel` com o botão "New Folder"
/// (`canCreateDirectories`) ligado — coisa que o `file_picker` **não** faz em
/// nenhuma versão. Nas demais plataformas cai no `file_picker` (FFI Win32 no
/// Windows, `zenity`/`kdialog` no Linux), que já resolve o suficiente lá.
///
/// [initialDirectory] abre o diálogo na pasta indicada (em vez de sempre na raiz
/// do sistema) — passe a última pasta usada / a atual do contexto.
class NativeFolderPicker {
  const NativeFolderPicker._();

  static const MethodChannel _channel = MethodChannel('cockpit/native_dialogs');

  /// Retorna o caminho absoluto da pasta escolhida, ou `null` se cancelado.
  ///
  /// Sempre na forma canônica (`/`) — é a fronteira onde a raiz de um workspace
  /// nasce, e no Windows o diálogo nativo devolve `C:\...`. Ver [normalizePath].
  static Future<String?> pick({
    String? initialDirectory,
    String? dialogTitle,
  }) async {
    final picked = await _pickNative(
      initialDirectory: initialDirectory,
      dialogTitle: dialogTitle,
    );
    return picked == null ? null : normalizePath(picked);
  }

  static Future<String?> _pickNative({
    String? initialDirectory,
    String? dialogTitle,
  }) async {
    if (Platform.isMacOS) {
      try {
        return await _channel.invokeMethod<String>('pickDirectory', {
          'initialDirectory': initialDirectory,
        });
      } on MissingPluginException {
        // Canal ausente (ex.: teste de widget sem o Runner) → fallback.
      } on PlatformException {
        // Falha nativa inesperada → fallback pro file_picker.
      }
    }
    return FilePicker.platform.getDirectoryPath(
      dialogTitle: dialogTitle,
      initialDirectory: initialDirectory,
    );
  }
}
