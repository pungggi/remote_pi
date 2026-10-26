import 'package:cockpit/app/cockpit/domain/entities/notebook_document.dart';
import 'package:cockpit/app/cockpit/ui/session/pane_item.dart';

/// Aba de um **caderno** `nome.notebook/` (plano 62, passo 4). O alvo é uma
/// pasta, não um arquivo — por isso não é uma `FileViewerSession`. O estado
/// de leitura (notas, filtro, nota ativa) vive no widget; aqui só a identidade.
class NotebookSession extends PaneItem {
  NotebookSession({
    required this.id,
    required this.projectId,
    required this.path,
  });

  @override
  final String id;
  @override
  final String projectId;

  /// Caminho absoluto da pasta `.notebook`.
  final String path;

  @override
  String get title {
    final name = path.split('/').where((p) => p.isNotEmpty).last;
    return isNotebookFolder(name)
        ? name.substring(0, name.length - kNotebookSuffix.length)
        : name;
  }

  @override
  String get workingDirectory => path;

  /// Pedido de recarga vindo de fora (arquivo criado pela galeria/CLI).
  int reloadTick = 0;
  void requestReload() {
    reloadTick++;
    notifyListeners();
  }
}
