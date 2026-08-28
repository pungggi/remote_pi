import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;

/// Dispara cedo o diálogo de **rede local** do iOS ("Cockpit gostaria de
/// encontrar dispositivos na sua rede local").
///
/// Por que existe: o iOS só pede essa permissão quando o app **tenta** falar
/// com um endereço da LAN, e a tentativa que provocou o diálogo **falha** —
/// ela acontece antes de o usuário responder. Na prática isso aparecia assim:
/// cadastrar um host da rede local mostrava o pedido de permissão E um erro
/// junto; só depois de fechar e reabrir o app a conexão funcionava. Tocar a
/// rede local no boot move o diálogo para um momento em que nada depende dele.
///
/// Como dispara: uma conexão TCP curta para o provável gateway de cada
/// interface IPv4 privada (`x.y.z.1`). Basta a tentativa; a conexão pode ser
/// recusada, e normalmente é. Não usamos multicast/mDNS de propósito: enviar
/// multicast no iOS exige o entitlement `com.apple.developer.networking
/// .multicast`, que precisa de aprovação da Apple — uma conexão TCP comum não
/// exige nada.
///
/// Sem efeito fora do iOS: no Android e no desktop não existe essa permissão.
class LocalNetworkPermission {
  const LocalNetworkPermission._();

  static bool _primed = false;

  /// Porta do gateway a tocar: 80 responde ou recusa rápido em praticamente
  /// todo roteador doméstico, e o que importa é a tentativa.
  static const int _probePort = 80;

  static const Duration _timeout = Duration(seconds: 2);

  /// Toca a rede local uma vez por processo. Nunca lança e nunca bloqueia o
  /// boot por muito tempo — todo erro aqui é esperado (sem Wi-Fi, gateway
  /// mudo, permissão negada).
  static Future<void> prime() async {
    if (!Platform.isIOS || _primed) return;
    _primed = true;
    try {
      final targets = await _gatewayCandidates();
      if (targets.isEmpty) return;
      await Future.wait([for (final host in targets) _touch(host)]);
    } on Object catch (e) {
      // Rede indisponível no boot não é problema: o pedido reaparece na
      // primeira conexão real.
      debugPrint('[local-network] prime falhou: $e');
    }
  }

  static Future<void> _touch(String host) async {
    try {
      final socket = await Socket.connect(host, _probePort, timeout: _timeout);
      socket.destroy();
    } on Object {
      // Recusa/timeout é o caso normal — o diálogo já foi provocado.
    }
  }

  /// Prováveis gateways: para cada IPv4 **privado** das interfaces ativas,
  /// troca o último octeto por 1 (`192.168.0.42` → `192.168.0.1`). Cobre a
  /// esmagadora maioria das redes domésticas; onde não cobre, a tentativa
  /// falha sem custo e o diálogo aparece do mesmo jeito, porque o endereço
  /// ainda pertence à LAN.
  static Future<List<String>> _gatewayCandidates() async {
    final interfaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
      includeLoopback: false,
      includeLinkLocal: false,
    );
    final hosts = <String>{};
    for (final iface in interfaces) {
      for (final address in iface.addresses) {
        if (!_isPrivateV4(address.address)) continue;
        final octets = address.address.split('.');
        if (octets.length != 4) continue;
        hosts.add('${octets[0]}.${octets[1]}.${octets[2]}.1');
      }
    }
    return hosts.toList();
  }

  /// RFC 1918 (`10/8`, `172.16/12`, `192.168/16`) mais o CGNAT `100.64/10`,
  /// que operadoras usam e que o iOS trata como rede local.
  static bool _isPrivateV4(String ip) {
    final parts = ip.split('.');
    if (parts.length != 4) return false;
    final a = int.tryParse(parts[0]);
    final b = int.tryParse(parts[1]);
    if (a == null || b == null) return false;
    if (a == 10) return true;
    if (a == 192 && b == 168) return true;
    if (a == 172 && b >= 16 && b <= 31) return true;
    if (a == 100 && b >= 64 && b <= 127) return true;
    return false;
  }
}
