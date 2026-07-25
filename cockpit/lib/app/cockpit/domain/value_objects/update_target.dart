/// Alvo de atualização resolvido no boot: versão atual do app + plataforma /
/// formato / arch correntes (pra escolher o artefato certo do manifest). É um
/// value object injetável (registrado no `cockpit_module`) para que o
/// `UpdateViewModel` possa ser auto-injetado via `.new`, em vez de receber 4
/// `String` soltas que o `auto_injector` não consegue desambiguar.
class UpdateTarget {
  const UpdateTarget({
    required this.version,
    required this.platform,
    required this.format,
    required this.arch,
    this.selfUpdateFeedUrl,
    this.hasUpdateChannel = true,
  });

  /// Versão do app rodando (de `package_info`).
  final String version;

  /// Windows → exe/x64; Linux → deb/(arm64|x64). macOS descreve o que *seria*
  /// publicado, mas não tem canal — ver [hasUpdateChannel].
  final String platform;
  final String format;
  final String arch;

  /// Plano 47 — URL do appcast do self-update nativo (WinSparkle):
  /// `appcast-windows.xml` no Windows. `null` onde não há self-update (Linux →
  /// notify + download manual; macOS → nada, ver [hasUpdateChannel]).
  final String? selfUpdateFeedUrl;

  /// A plataforma tem canal de release neste fork?
  ///
  /// `false` só no macOS: sem identidade de assinatura Apple o job de macOS saiu
  /// do `cockpit-release.yml`, então não existe nem `appcast-macos.xml` (self-
  /// update) nem artefato macOS no `latest.json` (notify). Sem esta flag o macOS
  /// cairia no caminho de notify e ofereceria um download que não existe.
  final bool hasUpdateChannel;
}
