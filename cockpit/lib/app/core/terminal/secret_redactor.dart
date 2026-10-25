import 'dart:math' as math;

/// Filtro de saída do terminal que troca os **valores** injetados pelo
/// `.env.cockpit` por [mask] antes de o texto chegar ao emulador. Como entra
/// antes do coalescer, cobre de uma vez a tela, o scrollback gravado pra
/// restore e o `cockpit read-tab` que um agente usa pra ler a aba.
///
/// O alvo é o **vazamento acidental** (`env`, `echo $TOKEN`, `curl -v`, erro
/// de ferramenta ecoando a variável), não um agente determinado: valor
/// codificado (base64) ou com escape ANSI intercalado passa. Decisão
/// registrada no card do roadmap 2.0.
///
/// Fronteira entre chunks: o PTY entrega bytes em pedaços arbitrários, então
/// um segredo pode vir partido. Em vez de atrasar tudo, o filtro só **segura
/// a menor cauda que ainda pode ser o começo de um segredo** (prefixo próprio
/// de algum valor) e libera o resto na hora; a cauda sai no próximo chunk ou
/// no [flush]. Saída normal quase nunca termina em prefixo de segredo, então
/// a latência extra é zero na prática.
///
/// Segredos curtos (< [minLength]) ficam de fora: redigir `1` ou `dev` picaria
/// a tela inteira.
class SecretRedactor {
  SecretRedactor(
    Iterable<String> secrets, {
    this.mask = '***',
    this.minLength = 8,
  }) {
    update(secrets);
  }

  final String mask;

  /// Segredos mais curtos que isto não entram no filtro.
  final int minLength;
  List<String> _secrets = const []; // do maior pro menor: o maior casa 1º.
  int _maxLength = 0;
  String _carry = '';

  /// Troca o conjunto de segredos (ex.: workspace remoto, cujo `.env.cockpit`
  /// chega do host depois do spawn). A cauda segurada continua válida: é
  /// reavaliada contra a lista nova no próximo [feed].
  void update(Iterable<String> secrets) {
    _secrets = secrets.where((s) => s.length >= minLength).toSet().toList()
      ..sort((a, b) => b.length.compareTo(a.length));
    _maxLength = _secrets.isEmpty ? 0 : _secrets.first.length;
  }

  /// Nada a redigir: a sessão pode pular o filtro por completo.
  bool get isEmpty => _secrets.isEmpty;

  /// Processa [chunk] (com a cauda segurada do anterior) e devolve o texto
  /// liberado, já redigido.
  String feed(String chunk) {
    if (_secrets.isEmpty) return chunk;
    var text = _carry + chunk;
    for (final secret in _secrets) {
      if (text.contains(secret)) text = text.replaceAll(secret, mask);
    }
    final hold = _prefixHold(text);
    _carry = text.substring(text.length - hold);
    return text.substring(0, text.length - hold);
  }

  /// Libera a cauda segurada (fim do stream / kill do processo).
  String flush() {
    final out = _carry;
    _carry = '';
    return out;
  }

  /// Tamanho da maior cauda de [text] que é prefixo PRÓPRIO de algum segredo.
  /// Limitada a `maxLength - 1`: uma cauda do tamanho do segredo já teria sido
  /// substituída acima.
  int _prefixHold(String text) {
    final limit = math.min(_maxLength - 1, text.length);
    for (var k = limit; k >= 1; k--) {
      final suffix = text.substring(text.length - k);
      for (final secret in _secrets) {
        if (secret.length > k && secret.startsWith(suffix)) return k;
      }
    }
    return 0;
  }
}
