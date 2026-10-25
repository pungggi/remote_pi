import 'dart:typed_data';

import 'package:cockpit/app/cockpit/domain/entities/file_node.dart';
import 'package:cockpit/app/cockpit/ui/session/file_viewer_session.dart';
import 'package:cockpit/app/cockpit/ui/viewmodels/cockpit_viewmodel.dart';
import 'package:cockpit/app/core/data/lsp/lsp_text_edit.dart';
import 'package:cockpit/app/core/domain/entities/lsp_diagnostic.dart';
import 'package:cockpit/app/core/domain/entities/lsp_semantic_tokens.dart';
import 'package:cockpit/app/core/domain/exceptions/file_operation_error.dart';
import 'package:cockpit/app/core/domain/result.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_modular/flutter_modular.dart';

/// O que um viewer de documento ([FileViewer], `NotebookView`) precisa do
/// **ambiente** em que está montado: caminho de exibição, filesystem, LSP e
/// SCM. No app é o [CockpitViewModel]; na **janela de documento** (arquivo
/// aberto solto, fora do workspace) é um host standalone sem LSP nem git.
///
/// Extrair isto foi o que permitiu a janela de documento sem subir o módulo
/// inteiro do Cockpit num segundo engine (socket do status hook, LSP pool,
/// projetos… tudo colidiria com a janela principal).
abstract class DocumentHost {
  String? projectRootOf(String projectId);
  String displayPath(String projectId, String absolutePath);

  void ensureScmCoordinator(FileViewerSession session);

  Future<void> lspOpenDocument(String path, String text, String projectId);
  Future<void> lspChangeDocument(String path, String text);
  Future<void> lspCloseDocument(String path);
  Stream<LspDiagnosticsBatch> get lspDiagnostics;
  Future<List<LspTextEdit>> lspFormat(String path, String text);
  Future<SemanticTokens> lspSemanticTokensFull(String path);
  Future<void> goToDefinition(String path, int line, int character);

  Future<List<FileNode>> listChildren(String path);
  Future<String?> readTextAt(String path);
  Stream<void> watchFolder(String path);
  Future<bool> writeTextAt(String path, String content);
  Future<bool> writeBytesAt(String path, Uint8List bytes);
  Future<Result<void, FileOperationError>> deletePath(String path);
}

/// Instala um [DocumentHost] explícito na subárvore (janela de documento).
/// Sem o scope, [documentHostOf] cai no [CockpitViewModel] da rota, que é o
/// caso do app normal — nenhum call-site existente mudou de comportamento.
class DocumentHostScope extends InheritedWidget {
  const DocumentHostScope({
    super.key,
    required this.host,
    required super.child,
  });

  final DocumentHost host;

  @override
  bool updateShouldNotify(DocumentHostScope oldWidget) =>
      host != oldWidget.host;
}

/// Host do documento no [context]: o do [DocumentHostScope] mais próximo, ou
/// o [CockpitViewModel] (app). Leitura sem dependência de rebuild.
DocumentHost documentHostOf(BuildContext context) =>
    context.getInheritedWidgetOfExactType<DocumentHostScope>()?.host ??
    context.read<CockpitViewModel>();
