// Entidades da **orquestração de layout** (`*.ckp`): um arquivo YAML
// versionável descreve os panes/terminais a abrir num workspace — e cada pane
// pode disparar um comando (ex.: `claude`). Imutáveis, sem IO/UI.

/// Onde o pane nasce em relação ao **anterior criado** nesta aplicação do
/// layout (semântica tmuxinator): [tab] anexa como aba na mesma pane,
/// [right] divide lado a lado, [down] empilha.
enum LayoutSplit { tab, right, down }

/// Um pane declarado no `.ckp`.
class LayoutPane {
  const LayoutPane({
    required this.name,
    this.cwd = '.',
    this.split = LayoutSplit.tab,
    this.command,
    this.platforms = const [],
  });

  /// Nome do pane — vira o rótulo estável (manual) da tab e é a chave do
  /// merge idempotente: se já existe tab com esse rótulo no workspace, o pane
  /// é pulado ao aplicar.
  final String name;

  /// Caminho **relativo à pasta do arquivo `.ckp`**, sempre com `/` (o loader
  /// rejeita `\` e absolutos — o mesmo arquivo roda em macOS/Linux/Windows).
  final String cwd;

  final LayoutSplit split;

  /// Comando digitado no terminal após abrir (executado pelo shell da tab).
  /// `null` = só abre o terminal.
  final String? command;

  /// SOs onde o pane é criado (`macos`/`windows`/`linux`, nomes do
  /// `Platform.operatingSystem`). Vazio = todos. Mesma semântica do
  /// `platforms` do tasks.json.
  final List<String> platforms;
}

/// Um layout completo (um arquivo `.ckp` = um layout; o nome vem do arquivo).
class LayoutSpec {
  const LayoutSpec({
    required this.name,
    required this.panes,
    this.autorunWorktree = false,
  });

  /// Nome do layout — basename do arquivo sem a extensão.
  final String name;

  /// `autorun: worktree` no YAML: aplica automaticamente ao criar uma
  /// worktree do workspace que contém o arquivo.
  final bool autorunWorktree;

  final List<LayoutPane> panes;
}

/// Resultado de aplicar um layout: tabs criadas e panes pulados (merge).
class LayoutApplyReport {
  const LayoutApplyReport({this.created = const [], this.skipped = const []});

  /// Nomes dos panes efetivamente criados.
  final List<String> created;

  /// Nomes pulados (tab de mesmo nome já existia, ou SO não bate).
  final List<String> skipped;
}
