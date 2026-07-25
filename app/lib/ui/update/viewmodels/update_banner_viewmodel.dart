import 'package:app/domain/contracts/dismissed_update_store.dart';
import 'package:app/domain/contracts/update_checker.dart';
import 'package:app/domain/contracts/url_opener.dart';
import 'package:app/domain/value_objects/semver.dart';
import 'package:app/ui/core/viewmodel/viewmodel.dart';
import 'package:app/ui/update/states/update_banner_state.dart';

/// Aviso de atualização in-app, **Android-only** (plano 44, passo 3 — espelho
/// do passo 7 do plano 43 do Cockpit). No [check] (disparado no mount da Home,
/// = startup) consulta o manifest; se houver versão **maior** que a atual e que
/// **não foi dispensada**, emite [UpdateBannerVisible]. Tudo best-effort:
/// falhas são silenciosas.
///
/// O gate de plataforma vive aqui via [enabled] (injetado como
/// `Platform.isAndroid` no boot) — isso mantém a regra "nada no iOS"
/// testável sem depender do host onde o `flutter test` roda.
class UpdateBannerViewModel extends ViewModel<UpdateBannerState> {
  UpdateBannerViewModel(
    this._checker,
    this._dismissed,
    this._opener, {
    required this.currentVersion,
    required this.enabled,
    this.platform = 'android',
    this.format = 'apk',
    this.arch = 'universal',
    this.fallbackUrl = _kFallbackUrl,
  }) : super(const UpdateBannerHidden());

  final UpdateChecker _checker;
  final DismissedUpdateStore _dismissed;
  final UrlOpener _opener;

  /// Versão do app rodando (de `package_info`, injetada no boot).
  final String currentVersion;

  /// `true` só no Android — em iOS o app atualiza pela App Store, então o
  /// aviso nunca aparece.
  final bool enabled;

  /// Coordenadas do artefato a baixar (Android = apk universal).
  final String platform;
  final String format;
  final String arch;

  /// Fallback quando o manifest não traz artefato compatível.
  final String fallbackUrl;

  /// Página de releases do fork. O upstream manda pra página de download do
  /// site dele; o fork não tem site publicado, e a lista de releases do próprio
  /// repositório sempre existe e já mostra todos os artefatos.
  static const String _kFallbackUrl =
      'https://github.com/pungggi/remote_pi/releases';

  bool _checked = false;
  bool _disposed = false;

  /// Consulta o manifest e decide se o card deve aparecer. Silencioso em
  /// falha. Idempotente por instância (re-mount cria nova instância e
  /// re-consulta; uma mesma instância só consulta uma vez).
  Future<void> check() async {
    if (!enabled) return; // iOS / não-Android → nunca mostra.
    if (_checked) return;
    _checked = true;

    final latest = await _checker.fetchLatest();
    if (_disposed) return;
    if (latest == null) return; // sem rede/manifest/inválido → nada.
    if (!isNewerVersion(latest.version, currentVersion)) {
      return; // igual/menor → nada.
    }

    final dismissed = await _dismissed.dismissedVersion();
    if (_disposed) return;
    if (dismissed == latest.version) return; // dispensada → nada.

    emit(UpdateBannerVisible(latest));
  }

  /// Fecha o card e persiste a versão como dispensada — não reaparece pra ela
  /// (volta numa versão maior).
  Future<void> dismiss() async {
    final current = state;
    if (current is! UpdateBannerVisible) return;
    final version = current.info.version;
    emit(const UpdateBannerHidden());
    await _dismissed.dismiss(version);
  }

  /// Baixa o APK do Android (abre a URL no navegador → download direto). Sem
  /// artefato compatível no manifest → abre a página de download do site.
  Future<void> download() async {
    final current = state;
    if (current is! UpdateBannerVisible) return;
    final artifact = current.info.artifactFor(
      platform: platform,
      format: format,
      arch: arch,
    );
    await _opener.open(artifact?.url ?? fallbackUrl);
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
