import 'dart:io';

import 'package:cockpit/app/core/utils/user_home.dart';
import 'package:file_picker/file_picker.dart';

/// Pasta onde as chaves SSH do usuário moram nesta máquina, ou a home quando
/// ela ainda não existe.
///
/// É o mesmo caminho nas três plataformas desktop (`%USERPROFILE%\.ssh` no
/// Windows é a pasta do OpenSSH nativo, a mesma que o `ssh.exe` lê). Abrir o
/// picker já lá poupa o usuário de navegar até uma pasta oculta — e `.ssh` é
/// oculta em todas elas.
String? sshKeyDirectory() {
  final home = userHome();
  if (home == null) return null;
  final ssh = Directory('$home/.ssh');
  return ssh.existsSync() ? ssh.path : home;
}

/// Abre o seletor de arquivo na pasta de chaves e devolve o caminho escolhido
/// (`null` se o usuário cancelar).
///
/// Sem filtro de extensão: chave privada não tem extensão nenhuma
/// (`id_ed25519`), e as que têm (`.pem`, `.key`) não seguem padrão. Filtrar
/// esconderia justamente o caso comum.
/// O arquivo escolhido é utilizável como chave PRIVADA?
///
/// `null` = serve. Caso contrário, a razão (a UI traduz pelo enum).
SshKeyProblem? inspectSshPrivateKey(String path) {
  final file = File(path);
  if (!file.existsSync()) return SshKeyProblem.missing;
  // `.pub` aqui só sobra quando NÃO existe a privada ao lado (o
  // [normalizeSshKeyChoice] já teria trocado). Não é erro certo: `ssh -i` com
  // a pública é válido quando a privada está no agente ou num dispositivo —
  // por isso vira aviso, não bloqueio.
  if (path.endsWith('.pub')) return SshKeyProblem.isPublicKey;
  String head;
  try {
    // Chave privada é texto e pequena; ler o começo basta e evita carregar
    // qualquer coisa que o usuário tenha apontado por engano.
    head = file.openSync().readSync(120).map(String.fromCharCode).join();
  } on FileSystemException {
    return SshKeyProblem.unreadable;
  }
  if (!head.contains('PRIVATE KEY')) return SshKeyProblem.notAPrivateKey;
  return null;
}

/// Por que o arquivo escolhido não serve como chave privada.
enum SshKeyProblem { missing, unreadable, isPublicKey, notAPrivateKey }

/// Normaliza a escolha: apontar `id_ed25519.pub` quase sempre significa
/// `id_ed25519`, que está ao lado. As duas têm nomes quase idênticos, e o
/// `ssh` recusa a pública reclamando de PERMISSÕES — mensagem que manda o
/// usuário investigar a coisa errada.
String normalizeSshKeyChoice(String path) {
  if (!path.endsWith('.pub')) return path;
  final private = path.substring(0, path.length - 4);
  return File(private).existsSync() ? private : path;
}

Future<String?> pickSshPrivateKey({String? dialogTitle}) async {
  final result = await FilePicker.platform.pickFiles(
    dialogTitle: dialogTitle,
    initialDirectory: sshKeyDirectory(),
    // A pasta tem `id_*.pub` ao lado das privadas; o usuário escolhe qual, e a
    // validação de "isso é mesmo uma chave" fica com o ssh, na conexão.
    type: FileType.any,
  );
  final path = result?.files.singleOrNull?.path;
  if (path == null || path.isEmpty) return null;
  return normalizeSshKeyChoice(path);
}
