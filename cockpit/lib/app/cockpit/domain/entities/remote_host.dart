import 'dart:io';

/// Modo de autenticação SSH escolhido para o host (plano 60, Wave C).
enum RemoteHostAuth {
  /// Chave do dispositivo (default): desktop usa `~/.ssh`/agent; mobile usa a
  /// chave ed25519 do Keychain.
  key,

  /// Senha, guardada no Keychain (nunca no JSON). Mobile passa direto ao
  /// dartssh2; desktop injeta via `SSH_ASKPASS`.
  password,
}

/// Host remoto registrado no cliente (plano 58, decisão C): o cliente
/// persiste APENAS isto — id, nome de exibição e endpoint SSH. Realms,
/// workspaces e estado de sessão vivem no host dono. A senha (quando
/// [auth] == password) mora no Keychain, não aqui.
class RemoteHost {
  const RemoteHost({
    required this.id,
    required this.name,
    required this.sshTarget,
    this.port = 22,
    this.auth = RemoteHostAuth.key,
    this.identityFile,
  });

  /// UUID estável do registro (não muda se o endpoint mudar).
  final String id;

  /// Nome de exibição (badge no rail; a cor do host deriva dele por enquanto).
  final String name;

  /// Destino SSH como `user@host` (sem porta — a porta vive em [port]). O
  /// cadastro coleta usuário e host separados e combina aqui.
  final String sshTarget;

  /// Porta SSH (default 22). Desktop passa `-p`; mobile usa no endpoint.
  final int port;

  /// Modo de autenticação. Ver [RemoteHostAuth].
  final RemoteHostAuth auth;

  /// Chave PRIVADA a usar na autenticação (auth por chave, desktop): vira
  /// `-i <caminho> -o IdentitiesOnly=yes` no ssh.
  ///
  /// Não é a mesma coisa que a host key do `known_hosts`: esta é a identidade
  /// do CLIENTE. Escolher explicitamente evita o ssh desfilar uma chave por vez
  /// numa máquina com muitas e estourar o `MaxAuthTries` do servidor antes de
  /// chegar na certa ("too many authentication failures").
  ///
  /// `null` em registros antigos e no mobile (lá as identidades vêm do
  /// Keychain, não de `~/.ssh`) — nesse caso o ssh decide como sempre decidiu,
  /// respeitando o `~/.ssh/config`.
  final String? identityFile;

  /// `user` do `user@host` (vazio se não houver `@`).
  String get user {
    final at = sshTarget.indexOf('@');
    return at <= 0 ? '' : sshTarget.substring(0, at);
  }

  /// `host` do `user@host` (o todo se não houver `@`).
  String get host {
    final at = sshTarget.indexOf('@');
    return at < 0 ? sshTarget : sshTarget.substring(at + 1);
  }

  /// A chave a passar pro `ssh -i`, corrigindo o engano mais comum do
  /// cadastro: escolher o `.pub` em vez da privada.
  ///
  /// As duas moram lado a lado em `~/.ssh` com nomes quase idênticos, e o
  /// `ssh` recusa a pública com uma mensagem sobre PERMISSÕES ("0644 are too
  /// open"), que manda o usuário investigar a coisa errada. Quando existe a
  /// privada correspondente, a intenção é inequívoca — usamos ela.
  ///
  /// Corrige também registros já salvos, sem exigir reedição.
  String? get effectiveIdentityFile {
    final path = identityFile;
    if (path == null || !path.endsWith('.pub')) return path;
    final private = path.substring(0, path.length - 4);
    return File(private).existsSync() ? private : path;
  }

  RemoteHost copyWith({
    String? name,
    String? sshTarget,
    int? port,
    RemoteHostAuth? auth,
    String? identityFile,
  }) => RemoteHost(
    id: id,
    name: name ?? this.name,
    sshTarget: sshTarget ?? this.sshTarget,
    port: port ?? this.port,
    auth: auth ?? this.auth,
    identityFile: identityFile ?? this.identityFile,
  );

  factory RemoteHost.fromJson(Map<String, Object?> json) {
    // Retrocompatível: registros antigos só têm `ssh` (user@host[:porta]).
    // Extrai a porta embutida no legado, se houver.
    final raw = json['ssh'] as String? ?? '';
    var target = raw;
    var port = (json['port'] as num?)?.toInt() ?? 22;
    final at = raw.lastIndexOf('@');
    final colon = raw.lastIndexOf(':');
    if (json['port'] == null && colon > at) {
      final parsed = int.tryParse(raw.substring(colon + 1));
      if (parsed != null) {
        port = parsed;
        target = raw.substring(0, colon);
      }
    }
    return RemoteHost(
      id: json['id'] as String,
      name: json['name'] as String,
      sshTarget: target,
      port: port,
      auth: (json['auth'] as String?) == 'password'
          ? RemoteHostAuth.password
          : RemoteHostAuth.key,
      identityFile: (json['identity'] as String?)?.trim().isEmpty ?? true
          ? null
          : (json['identity'] as String).trim(),
    );
  }

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'ssh': sshTarget,
    'port': port,
    'auth': auth == RemoteHostAuth.password ? 'password' : 'key',
    if (identityFile != null) 'identity': identityFile,
  };
}
