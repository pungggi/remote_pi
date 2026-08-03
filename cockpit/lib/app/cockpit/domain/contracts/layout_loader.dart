import 'package:cockpit/app/core/domain/result.dart';

import '../entities/layout_spec.dart';

/// Lê um arquivo de layout `.ckp` (YAML) e o traduz em [LayoutSpec].
/// Falha com mensagem legível (mostrada na UI/CLI) — nunca silenciosa, ao
/// contrário do tasks.json: o layout é acionado explicitamente pelo usuário.
abstract class LayoutLoader {
  Future<Result<LayoutSpec, String>> load(String ckpPath);
}
