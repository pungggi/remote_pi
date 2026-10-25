import 'dart:convert';

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/services.dart';

/// Abre arquivos em **janelas de documento** próprias (plano 2.0): uma
/// janela leve, sem rail nem panes, que renderiza o viewer certo pro caminho
/// (markdown, `.kanban`, `.notebook`, código…). É o que substitui o "destacar
/// aba": a aba fica onde está, abre uma cópia solta — sem confundir com o
/// drag de abas entre panes.
///
/// Cada janela é um engine Flutter novo (`desktop_multi_window`): o `main`
/// detecta os argumentos e sobe [runDocumentWindow] em vez do app inteiro.
/// O estado compartilhado é só o caminho; edição concorrente é resolvida pelo
/// próprio arquivo (o viewer relê quando ele muda no disco).
class DocumentWindows {
  DocumentWindows._();

  /// Argumento que o engine da janela recebe (`main(args)` →
  /// `['multi_window', <id>, <este JSON>]`).
  static String argumentsFor(String path) =>
      jsonEncode({'type': 'document', 'path': path});

  /// `path` do JSON de argumentos, ou `null` se não é uma janela de documento.
  static String? pathFromArguments(List<String> args) {
    if (args.length < 3 || args[0] != 'multi_window') return null;
    try {
      final json = jsonDecode(args[2]);
      if (json is Map && json['type'] == 'document') {
        final path = json['path'];
        if (path is String && path.isNotEmpty) return path;
      }
    } on FormatException {
      // argumento de outro tipo de janela (ou vazio) → não é documento
    }
    return null;
  }

  /// Abre (e mostra) uma janela de documento para [path].
  static Future<void> open(String path) async {
    final controller = await WindowController.create(
      WindowConfiguration(arguments: argumentsFor(path)),
    );
    await controller.show();
  }
}

/// Canal com o lado nativo da **própria** janela de documento (registrado no
/// `setOnWindowCreatedCallback` do macOS): título e tamanho. Best-effort —
/// plataforma sem o canal só fica sem título.
class DocumentWindowChannel {
  DocumentWindowChannel._();

  static const _channel = MethodChannel('cockpit/document_window');

  /// Título + tamanho inicial + traz pra frente (ver DocumentWindows.swift).
  static Future<void> present(
    String title, {
    double width = 960,
    double height = 720,
  }) async {
    try {
      await _channel.invokeMethod<void>('present', {
        'title': title,
        'width': width,
        'height': height,
      });
    } on MissingPluginException {
      // Windows/Linux ainda sem o handler nativo: sem título, sem erro.
    } on PlatformException {
      // idem
    }
  }
}
