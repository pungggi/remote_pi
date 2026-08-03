/// Database escolhido por conexão Mongo, quando a URL não traz um.
///
/// URL de Atlas (`mongodb+srv://…mongodb.net/?retryWrites=…`) normalmente vem
/// **sem** path de database — e, em SRV, nem o `authSource` está na URL (viaja
/// no TXT do DNS). Sem essa escolha o runner só tem o fallback `admin`, que faz
/// o browser listar `system.*` em vez dos dados. O seletor do painel Database
/// grava aqui; a leitura é compartilhada por GUI e CLI, então agente e humano
/// enxergam o mesmo database.
///
/// Escopo é (workspace, conexão): o mesmo `databases.json` pode ser aberto em
/// workspaces diferentes, e a escolha é preferência local — nunca vai pro
/// arquivo versionado.
abstract interface class MongoDatabaseStore {
  /// Database escolhido, ou `null` se nunca escolhido.
  String? selected(String workspaceId, String connName);

  /// Fixa a escolha.
  Future<void> select(String workspaceId, String connName, String database);
}
