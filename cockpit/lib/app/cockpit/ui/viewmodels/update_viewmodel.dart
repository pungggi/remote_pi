import 'dart:async';

import 'package:cockpit/app/cockpit/domain/contracts/dismissed_update_store.dart';
import 'package:cockpit/app/cockpit/domain/contracts/self_updater.dart';
import 'package:cockpit/app/cockpit/domain/contracts/update_checker.dart';
import 'package:cockpit/app/cockpit/domain/contracts/url_opener.dart';
import 'package:cockpit/app/cockpit/domain/entities/update_info.dart';
import 'package:cockpit/app/cockpit/domain/value_objects/semver.dart';
import 'package:cockpit/app/cockpit/domain/value_objects/update_target.dart';
import 'package:flutter/foundation.dart';

/// Dono do mini card de atualização do rail. Tem **três modos**, decididos pela
/// plataforma:
///
/// - **Windows (self-update, plano 47):** [check] liga o [SelfUpdater] nativo
///   (WinSparkle), que não baixa sozinho — o card para em "Update available" e
///   o toque é que dispara download+install. Ver [SelfUpdatePhase].
/// - **Linux (notify, plano 43):** [check] lê o `latest.json` via [UpdateChecker];
///   se houver versão **maior** e **não dispensada**, o card aparece e o toque
///   abre a URL do artefato no navegador (download manual).
/// - **macOS (nenhum):** o fork não publica build de macOS — sem appcast e sem
///   artefato no manifest. [UpdateTarget.hasUpdateChannel] é `false` e o card
///   nunca aparece; checar seria gastar rede pra oferecer um download
///   inexistente.
///
/// Tudo best-effort: falhas são silenciosas, nunca derrubam o boot.
class UpdateViewModel extends ChangeNotifier {
  UpdateViewModel(
    this._checker,
    this._dismissed,
    this._opener,
    this._target,
    this._selfUpdater, {
    this.fallbackUrl = _kFallbackUrl,
  });

  final UpdateChecker _checker;
  final DismissedUpdateStore _dismissed;
  final UrlOpener _opener;
  final UpdateTarget _target;
  final SelfUpdater _selfUpdater;

  /// Versão do app rodando (de package_info, resolvida no boot).
  String get currentVersion => _target.version;

  /// Plataforma/arch correntes pra escolher o artefato (caminho Linux/notify).
  String get platform => _target.platform;
  String get format => _target.format;
  String get arch => _target.arch;

  /// Fallback quando o manifest não traz artefato da plataforma.
  final String fallbackUrl;

  /// Página de releases do fork. O upstream manda pra página de download do
  /// site dele; o fork não tem site publicado, e a lista de releases do próprio
  /// repositório sempre existe e já mostra todos os artefatos.
  static const String _kFallbackUrl =
      'https://github.com/pungggi/remote_pi/releases';

  UpdateInfo? _available; // caminho Linux/notify
  StreamSubscription<SelfUpdateState>? _selfSub;
  bool _selfDismissed = false; // dispensa transiente no modo self-update
  bool _selfInitialized = false; // o motor de self-update só inicializa uma vez
  bool _disposed = false;

  /// Versão vinda do `latest.json`, usada só quando o motor nativo não informa a
  /// dele — o caso do Windows, onde o plugin não repassa o `AppcastItem` (ver
  /// [SelfUpdateState.version]). Appcast e `latest.json` saem do mesmo job de CI,
  /// então a versão é a mesma. Sem isso o card mostraria "v" vazio.
  String? _fallbackVersion;

  /// Re-checa de tempos em tempos enquanto o app está aberto (além do boot).
  Timer? _periodic;
  static const Duration _checkInterval = Duration(hours: 6);

  /// `true` no Windows (há motor de self-update); `false` no Linux e no macOS.
  bool get isSelfUpdate => _selfUpdater.isSupported;

  /// A plataforma publica releases? `false` no macOS — ver
  /// [UpdateTarget.hasUpdateChannel].
  bool get hasUpdateChannel => _target.hasUpdateChannel;

  // ---- Estado unificado consumido pelo card ----

  /// O card deve aparecer?
  bool get hasUpdate {
    if (!hasUpdateChannel) return false;
    if (isSelfUpdate) {
      return !_selfDismissed && _selfUpdater.state.hasPendingUpdate;
    }
    return _available != null;
  }

  /// Artefato baixado e pronto pra instalar. Governa o texto "restart to
  /// install" e o ícone, não o clique: quem habilita o clique é o card sempre
  /// chamar [primaryAction].
  ///
  /// Hoje **inalcançável**: era a fase do Sparkle (macOS), e o WinSparkle nunca
  /// reporta "baixou". Fica porque é contrato do motor, não do fork — ver
  /// [SelfUpdatePhase.downloaded].
  bool get isReadyToInstall =>
      isSelfUpdate && _selfUpdater.state.isReadyToInstall;

  /// Versão a anunciar no card (`null` se ainda desconhecida). No self-update cai
  /// pro [_fallbackVersion] quando o motor não informa a versão (Windows).
  String? get updateVersion => isSelfUpdate
      ? (_selfUpdater.state.version ?? _fallbackVersion)
      : _available?.version;

  /// Título do card.
  String get cardTitle =>
      isReadyToInstall ? 'Update ready' : 'Update available';

  /// Subtítulo do card (varia por modo/fase). Tolera versão desconhecida.
  String get cardSubtitle {
    final v = updateVersion;
    final prefix = v == null ? '' : 'v$v — ';
    if (!isSelfUpdate) return '${prefix}click to download';
    return switch (_selfUpdater.state.phase) {
      // Fases de auto-download do motor — o WinSparkle não as emite.
      SelfUpdatePhase.downloaded => '${prefix}restart to install',
      SelfUpdatePhase.downloading =>
        v == null ? 'Downloading…' : 'Downloading v$v…',
      // Windows: disponível, o clique é que baixa+instala.
      _ => '${prefix}click to install',
    };
  }

  // ---- Boot ----

  /// Checa updates no boot e arma uma re-checagem periódica (a cada
  /// [_checkInterval]) enquanto o app está aberto. Silencioso em falha.
  Future<void> check() async {
    // Sem canal de release (macOS) nem o timer é armado: nada a checar.
    if (!hasUpdateChannel) return;
    await _runCheck();
    _periodic ??= Timer.periodic(_checkInterval, (_) => _runCheck());
  }

  /// Checagem **pedida pelo usuário** (menu "Check for Updates…"). Diferente da
  /// de boot: roda em foreground, porque no Windows só a variante com UI
  /// (`win_sparkle_check_update_with_ui`) — segundo o header, *"intended for
  /// manual, user-initiated checks […] it ignores 'Skip this version'"* — mostra
  /// resposta e destrava quem já dispensou a versão no diálogo nativo. Com a
  /// checagem de background aqui, quem clicou "Skip" ficava sem saída pelo app.
  /// Também limpa a dispensa local, já que pedir explicitamente é o oposto de
  /// dispensar.
  Future<void> checkNow() async {
    if (_disposed || !hasUpdateChannel) return;
    _selfDismissed = false;
    if (isSelfUpdate) {
      _selfSub ??= _selfUpdater.changes.listen(_onSelfUpdateChange);
      if (!_selfInitialized) {
        await _selfUpdater.initialize();
        _selfInitialized = true;
      }
      await _selfUpdater.checkForUpdates(inBackground: false);
      return;
    }
    await _runCheck();
  }

  /// Uma passada de checagem (boot ou periódica).
  Future<void> _runCheck() async {
    if (_disposed || !hasUpdateChannel) return;
    if (isSelfUpdate) {
      _selfSub ??= _selfUpdater.changes.listen(_onSelfUpdateChange);
      if (!_selfInitialized) {
        await _selfUpdater.initialize();
        _selfInitialized = true;
      }
      await _selfUpdater.checkForUpdates(inBackground: true);
      return;
    }
    // Linux: notify + download manual.
    final latest = await _checker.fetchLatest();
    if (latest == null) return; // sem rede/manifest/inválido → nada.
    if (!isNewerVersion(latest.version, currentVersion)) return; // igual/menor.
    if (_dismissed.dismissedVersion() == latest.version) return; // dispensada.
    _available = latest;
    _safeNotify();
  }

  /// Reage a uma transição do motor nativo. Além de repintar, completa a versão
  /// pelo `latest.json` quando o motor não a informa (Windows) — só quando há
  /// update pendente, pra não gastar rede à toa no caminho feliz.
  void _onSelfUpdateChange(SelfUpdateState state) {
    if (state.hasPendingUpdate &&
        state.version == null &&
        _fallbackVersion == null) {
      unawaited(_fetchFallbackVersion());
    }
    _safeNotify();
  }

  Future<void> _fetchFallbackVersion() async {
    final latest = await _checker.fetchLatest(); // nunca lança; `null` em falha
    if (_disposed || latest == null) return;
    _fallbackVersion = latest.version;
    _safeNotify();
  }

  // ---- Ações do card ----

  /// Toque no card: self-update → aciona o update (macOS instala+relança o já
  /// baixado; Windows inicia download+install); Linux → baixa o artefato (abre a
  /// URL no navegador).
  Future<void> primaryAction() async {
    // Inalcançável pelo card (que só renderiza com [hasUpdate]), mas o menu e
    // futuros call-sites não têm essa garantia.
    if (!hasUpdateChannel) return;
    if (isSelfUpdate) {
      await _selfUpdater.applyUpdate();
      return;
    }
    await _download();
  }

  /// Fecha o card. Self-update → dispensa só pela sessão (reaparece se baixar
  /// outra versão). Linux → persiste a versão como dispensada (não reaparece).
  Future<void> dismiss() async {
    if (isSelfUpdate) {
      _selfDismissed = true;
      _safeNotify();
      return;
    }
    final v = _available?.version;
    _available = null;
    _safeNotify();
    if (v != null) await _dismissed.dismiss(v);
  }

  /// Abre a URL do artefato da plataforma corrente; sem artefato compatível →
  /// abre a página de download do site (caminho Linux/notify).
  Future<void> _download() async {
    final info = _available;
    if (info == null) return;
    final artifact = info.artifactFor(
      platform: platform,
      format: format,
      arch: arch,
    );
    await _opener.open(artifact?.url ?? fallbackUrl);
  }

  void _safeNotify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _periodic?.cancel();
    _selfSub?.cancel();
    super.dispose();
  }
}
