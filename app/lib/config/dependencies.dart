import 'dart:async';
import 'dart:io' show Platform;

import 'package:app/config/utils/injector.dart';
import 'package:app/data/actions/actions_repository.dart';
import 'package:app/data/mesh/mesh_client.dart';
import 'package:app/data/mesh/mesh_sync_service.dart';
import 'package:app/data/local/boxes.dart';
import 'package:app/data/preferences/preferences.dart';
import 'package:app/data/repositories/home_read_repository.dart';
import 'package:app/data/repositories/session_read_repository.dart';
import 'package:app/data/share/shared_image_inbox.dart';
import 'package:app/data/share/shared_text_inbox.dart';
import 'package:app/data/share/composer_draft.dart';
import 'package:app/data/sync/sync_service.dart';
import 'package:app/data/transport/channel.dart'; // IChannel
import 'package:app/data/transport/connection_manager.dart';
import 'package:app/data/transport/keep_alive_controller.dart';
import 'package:app/data/device/reliability_service.dart';
import 'package:app/data/transport/network_monitor.dart';
import 'package:app/data/transport/peer_channel.dart';
import 'package:app/data/images/image_picker_service.dart';
import 'package:app/data/transport/relay_config.dart';
import 'package:app/data/transport/relay_endpoint.dart';
import 'package:app/data/transport/ws_transport.dart';
import 'package:app/data/update/secure_dismissed_update_store.dart';
import 'package:app/data/update/update_checker_impl.dart';
import 'package:app/data/update/url_launcher_opener.dart';
import 'package:app/data/voice/speech_service.dart';
import 'package:app/domain/contracts/dismissed_update_store.dart';
import 'package:app/domain/contracts/update_checker.dart';
import 'package:app/domain/contracts/url_opener.dart';
import 'package:app/pairing/owner_identity_bridge.dart';
import 'package:app/pairing/pair_request_flow.dart';
import 'package:app/pairing/qr_scanner.dart';
import 'package:app/pairing/storage.dart';
import 'package:app/routing/adaptive.dart';
import 'package:app/ui/chat/attachment/viewmodels/attachment_viewmodel.dart';
import 'package:app/ui/chat/quick_actions/viewmodels/quick_actions_viewmodel.dart';
import 'package:app/ui/chat/viewmodels/chat_viewmodel.dart';
import 'package:app/ui/chat/voice/viewmodels/voice_input_viewmodel.dart';
import 'package:app/ui/core/viewmodel/viewmodel.dart';
import 'package:app/ui/home/viewmodels/home_viewmodel.dart';
import 'package:app/ui/projects/projects_viewmodel.dart';
import 'package:app/ui/onboarding/viewmodels/onboarding_viewmodel.dart';
import 'package:app/ui/pairing/viewmodels/pairing_viewmodel.dart';
import 'package:app/ui/settings/viewmodels/settings_viewmodel.dart';
import 'package:app/ui/update/viewmodels/update_banner_viewmodel.dart';
import 'package:cryptography/cryptography.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';
import 'package:remote_pi_identity/remote_pi_identity.dart';

// Plan/128 step 6 — optional on-device history retention cap (rows/session).
// Default OFF (null): the box grows without bound (history is durable +
// append-only). Override at build time:
//   flutter build apk --debug --dart-define=REMOTE_PI_LOCAL_HISTORY_MAX=2000
final int? _localHistoryMax = () {
  const raw = String.fromEnvironment('REMOTE_PI_LOCAL_HISTORY_MAX');
  final n = int.tryParse(raw);
  return (n != null && n > 0) ? n : null;
}();

final _injector = CustomInjector();

/// Direct injector access — only for bootstrap, tests, and deep-link handlers.
CustomInjector get injector => _injector;

Future<void> setupDependencies() async {
  // Infrastructure singletons
  _injector.addInstance<PairingStorage>(PairingStorage());

  final prefs = Preferences();
  await prefs.load();
  _injector.addInstance<Preferences>(prefs);
  // Plan/104 — global inbox for images shared into the app (consumed by the chat).
  _injector.addInstance<SharedImageInbox>(SharedImageInbox());
  _injector.addInstance<SharedTextInbox>(SharedTextInbox());
  // Plan/106 — the follow-me composer draft (text + attachments), in-memory.
  _injector.addInstance<ComposerDraft>(ComposerDraft());

  // Plan 31 — local SSOT box facade (boxes already opened + runtime wiped in
  // bootstrap before this runs).
  _injector.addInstance<LocalBoxes>(LocalBoxes());

  // Plan 23 — Owner-key sync. The store talks to the native plugin
  // (iCloud Keychain on iOS, Block Store on Android); the bridge sits
  // between it and the rest of the app, owning boot + watch-for-reset.
  final OwnerIdentityStore ownerStore = MethodChannelOwnerIdentityStore();
  _injector.addInstance<OwnerIdentityStore>(ownerStore);
  final ownerBridge = OwnerIdentityBridge(
    ownerStore,
    _injector.get<PairingStorage>(),
  );
  _injector.addInstance<OwnerIdentityBridge>(ownerBridge);

  // Plan 24 — mesh_versions HTTP client + sync service. Base URL follows
  // the WS connection's winning endpoint when one is known (plan 115), so
  // mesh polling at home also bypasses Tailscale instead of always hitting
  // the (possibly flaky) primary. Falls back to the primary relay URL
  // before the first successful connect. The relay's `/mesh` endpoint
  // shares host + port with the WebSocket.
  final meshClient = MeshClient(
    baseUrlProvider: () => prefs.lastGoodRelayUrl ?? resolveRelayUrl(prefs),
  );
  _injector.addInstance<MeshClient>(meshClient);
  final meshSync = MeshSyncService(
    meshClient,
    ownerBridge,
    _injector.get<PairingStorage>(),
  );
  _injector.addInstance<MeshSyncService>(meshSync);
  _injector.get<PairingStorage>().attachPeerMutationHook(() {
    // ignore: unawaited_futures
    meshSync.publish();
  });

  // ConnectionManager — factory function injected manually (function typedefs
  // cannot be resolved by auto_injector via Type.new).
  _injector.addService<ConnectionManager>(
    () => ConnectionManager(
      factory: _productionConnectionFactory,
      storage: _injector.get<PairingStorage>(),
    ),
  );

  // Plan 103 — foreground-service controller (Android only; no-op elsewhere).
  // Attached to ConnectionManager in main() once both are resolvable.
  // addService so its dispose() (stops the service) runs on teardown.
  _injector.addService<KeepAliveController>(
    () => KeepAliveController(_injector.get<Preferences>()),
  );

  // Plan 114 — network-change detection. Attached to ConnectionManager in
  // main() (mirrors KeepAliveController); addService so its dispose() cancels
  // the connectivity subscription at app teardown.
  _injector.addService<NetworkMonitor>(() => NetworkMonitor());

  // Plan 116 — connection reliability: one-tap battery exemption + Tailscale
  // deep-links. Read by the reliability page + the proactive Home banner.
  // Constructor ref (auto-resolves Preferences) — same form as
  // OnboardingViewModel above.
  _injector.addService<ReliabilityService>(ReliabilityService.new);

  // Plan 29 — on-device speech-to-text. Singleton: it owns a broadcast
  // sound-level stream that must survive across chat navigations; the
  // injector disposes it at app teardown. VoiceInputViewModel never
  // disposes it (it only stops/cancels sessions).
  _injector.addService<SpeechService>(() => SpeechToTextService());

  // Plan 30 — image picker + on-device JPEG compression. Stateless, no
  // dispose hook needed.
  _injector.addOther<IImagePickerService>(() => ImagePickerService());

  // Plan 31 — SSOT writer + read-only repos. SyncService is the SINGLE
  // mutator of the message/index/runtime boxes; the read repos only watch.
  _injector.addService<SyncService>(
    () => SyncService(
      _injector.get<ConnectionManager>(),
      _injector.get<LocalBoxes>(),
      // Plan/128 step 6 — optional on-device retention cap (default off).
      localHistoryMax: _localHistoryMax,
    ),
  );
  _injector.addRepository<SessionReadRepository>(
    () => SessionReadRepository(_injector.get<LocalBoxes>()),
  );
  _injector.addRepository<HomeReadRepository>(
    () => HomeReadRepository(_injector.get<LocalBoxes>()),
  );

  // Repositories
  _injector.addRepository<IActionsRepository>(
    () => ActionsRepository(_injector.get<ConnectionManager>()),
  );

  // ViewModels
  _injector.addViewModel<ChatViewModel>(
    () => ChatViewModel(
      _injector.get<SessionReadRepository>(),
      _injector.get<SyncService>(),
      _injector.get<ConnectionManager>(),
      _injector.get<Preferences>(),
      _injector.get<PairingStorage>(),
    ),
  );
  _injector.addViewModel<HomeViewModel>(
    () => HomeViewModel(
      _injector.get<PairingStorage>(),
      _injector.get<Preferences>(),
      _injector.get<ConnectionManager>(),
      _injector.get<IActionsRepository>(),
    ),
  );
  // Plan/121 — lightweight VM for the Projects screen (no stream
  // subscriptions; routes to the device room on demand).
  _injector.addViewModel<ProjectsViewModel>(
    () => ProjectsViewModel(
      _injector.get<PairingStorage>(),
      _injector.get<ConnectionManager>(),
      _injector.get<IActionsRepository>(),
      _injector.get<Preferences>(),
    ),
  );
  _injector.addViewModel<SettingsViewModel>(
    () => SettingsViewModel(
      _injector.get<PairingStorage>(),
      _injector.get<Preferences>(),
      _injector.get<ConnectionManager>(),
      _injector.get<MeshSyncService>(),
    ),
  );
  _injector.addViewModel<PairingViewModel>(
    () => PairingViewModel(
      _injector.get<PairingStorage>(),
      _productionPairingTransportFactory,
      _injector.get<ConnectionManager>(),
      _injector.get<Preferences>(),
      _injector.get<OwnerIdentityBridge>(),
    ),
  );
  _injector.addViewModel<OnboardingViewModel>(OnboardingViewModel.new);
  _injector.addViewModel<QuickActionsViewModel>(
    () => QuickActionsViewModel(_injector.get<IActionsRepository>()),
  );
  // Plan 29 — voice input. New instance per chat mount; reuses the shared
  // SpeechService singleton (which it stops/cancels but never disposes).
  _injector.addViewModel<VoiceInputViewModel>(
    () => VoiceInputViewModel(_injector.get<SpeechService>()),
  );
  // Plan 30 — image attachment. New instance per chat mount; resolves model
  // vision via the shared ActionsRepository catalogue cache.
  _injector.addViewModel<AttachmentViewModel>(
    () => AttachmentViewModel(
      _injector.get<IImagePickerService>(),
      _injector.get<IActionsRepository>(),
      _injector.get<SharedImageInbox>(),
      _injector.get<ComposerDraft>(),
    ),
  );

  // Plan/tablet — app-global UI selection (which session the tablet's
  // detail pane shows + which list tile is highlighted). Starts null so
  // the app opens with no chat pre-selected.
  _injector.addInstance<SessionSelection>(SessionSelection());

  // Plan/tablet — shell layout state (zero-state collapse). Set by Home so
  // the adaptive shell drops the split when there's nothing to list.
  _injector.addInstance<ShellLayout>(ShellLayout());

  // Plan 44 — Android-only in-app update notice. The running version comes
  // from package_info; the manifest fetch + gating live in the ViewModel
  // (silent on iOS via `enabled` and on any fetch failure). Stateless
  // collaborators → addOther (lazy singleton, no dispose hook).
  final packageInfo = await PackageInfo.fromPlatform();
  final appVersion = packageInfo.version;
  _injector.addOther<UpdateChecker>(() => UpdateCheckerImpl());
  _injector.addOther<DismissedUpdateStore>(() => SecureDismissedUpdateStore());
  _injector.addOther<UrlOpener>(() => const UrlLauncherOpener());
  _injector.addViewModel<UpdateBannerViewModel>(
    () => UpdateBannerViewModel(
      _injector.get<UpdateChecker>(),
      _injector.get<DismissedUpdateStore>(),
      _injector.get<UrlOpener>(),
      currentVersion: appVersion,
      enabled: Platform.isAndroid,
    ),
  );

  _injector.commit();
}

// ---------------------------------------------------------------------------
// Production ConnectionFactory — used by ConnectionManager for reconnection.
// Post-rollback: just open transport + wrap in PlainPeerChannel; Pi recognizes
// the peer via peers.json (no per-reconnect handshake).
// Plan 23: Owner-sk (synced via iCloud Keychain / Block Store) is the
// challenge-response key. OwnerIdentityBridge.boot() is the router's
// responsibility; by the time this factory runs, the identity is loaded.
//
// Plan 115 — dual relay addressing. Instead of dialling a single relay URL,
// the factory resolves an ORDERED candidate list (LAN candidates first, then
// the user's primary/overlay URL), optionally skips LAN on a pure-cellular
// link, and tries each endpoint in turn with a per-endpoint connect budget.
// First endpoint to complete the WS + Ed25519 handshake wins; the relay's
// advertised LAN addresses are persisted and the winner remembered as
// last-good so the next connect starts from it. All-fail throws so
// ConnectionManager enters its retry/backoff path.
// ---------------------------------------------------------------------------

/// Per-endpoint connect budget. LAN gets a short window so an unroutable
/// home address (cellular, or relay moved networks) fails fast and we move
/// on to the overlay; the primary gets the full defensive timeout.
const _kLanConnectTimeout = Duration(milliseconds: 1500);
const _kPrimaryConnectTimeout = Duration(seconds: 10);

Future<IChannel> _productionConnectionFactory(
  PeerRecord peer,
  CancelToken cancel,
) async {
  final bridge = injector.get<OwnerIdentityBridge>();
  final ownerKey = await bridge.requireKeyPair();
  if (cancel.isCancelled) throw _CancelledError();

  final prefs = injector.get<Preferences>();
  final endpoints = resolveRelayEndpoints(prefs);
  if (endpoints.isEmpty) {
    // Nothing configured yet — pair first. Surface as a failure so the
    // manager enters retry/offline instead of hanging in Connecting.
    throw TimeoutException('No relay endpoint configured');
  }

  // Plan 115 (cellular-skip) — on a pure cellular link the home-LAN
  // address is unroutable; skip the LAN race entirely and go straight to
  // the overlay. Wi-Fi/Ethernet present (even alongside mobile) keeps LAN,
  // since the home address can still route. A missing/unavailable probe
  // (desktop test harness) defaults to "keep LAN" — the short LAN timeout
  // handles the unroutable case anyway.
  final skipLan = await _shouldSkipLanEndpoints();
  final ordered = selectEndpointOrder(
    endpoints,
    lastGood: prefs.lastGoodRelayUrl,
    skipLan: skipLan,
  );

  // Sequential happy-eyeballs: try each endpoint with its own budget. A
  // timed-out attempt's underlying socket lingers until the OS/relay
  // closes it (same behaviour as the previous single-endpoint timeout);
  // only one _connect is ever in flight per ConnectionManager, so this
  // never piles up across reconnects.
  Object? lastError;
  for (final ep in ordered) {
    if (cancel.isCancelled) throw _CancelledError();
    final timeout = ep.kind == EndpointKind.lan
        ? _kLanConnectTimeout
        : _kPrimaryConnectTimeout;
    try {
      final transport = await WsTransport.connect(
        relayUrl: ep.url,
        peerPubkey: peer.remoteEpk,
        ed25519Key: ownerKey,
      ).timeout(
        timeout,
        onTimeout: () => throw TimeoutException(
          'WS connect to ${ep.url} timed out '
          'after ${timeout.inMilliseconds}ms',
        ),
      );
      if (cancel.isCancelled) {
        await transport.close();
        throw _CancelledError();
      }
      // Winner. Persist the relay's advertised LAN candidates (we learn
      // them even when we came in over the overlay) and remember this
      // endpoint as last-good. Awaited: last-good directly shapes the next
      // connect's ordering, so we don't want a read-before-write race.
      final lan = transport.advertisedLanUrls;
      if (lan.isNotEmpty) {
        await prefs.mergeLanEndpoints(lan);
      }
      await prefs.setLastGoodRelayUrl(ep.url);
      return PlainPeerChannel(transport: transport);
    } catch (e) {
      if (e is _CancelledError) rethrow;
      lastError = e;
      // fall through → next endpoint
    }
  }
  throw lastError ?? TimeoutException('All relay endpoints failed');
}

/// Plan 115 — returns `true` when LAN candidates should be skipped: a link
/// with no Wi-Fi/Ethernet path (i.e. pure cellular, where the home address
/// cannot route). Best-effort — any probe failure defaults to `false`.
Future<bool> _shouldSkipLanEndpoints() async {
  try {
    final results = await Connectivity().checkConnectivity();
    final hasNonCellular = results.any(
      (r) => r == ConnectivityResult.wifi ||
          r == ConnectivityResult.ethernet,
    );
    return !hasNonCellular;
  } catch (_) {
    return false;
  }
}


// ---------------------------------------------------------------------------
// Production PairingTransportFactory — used by PairingViewModel for first pair.
// ---------------------------------------------------------------------------

Future<PeerTransport> _productionPairingTransportFactory(
  QrPairPayload qr,
  SimpleKeyPair deviceEd25519,
) async {
  // Plan 14: pairing connects via the GLOBAL relay URL (Preferences), not
  // whatever was embedded in the QR.
  //
  // Plan/102 keeps that rule and feeds it instead: PairingViewModel adopts
  // `qr.relayUrl` into Preferences BEFORE calling this factory, so a QR that
  // advertises the Pi's LAN relay ends up here as the resolved URL. The
  // `relay_mismatch` guard in `pair_request_flow.dart` stays behind it as a
  // safety net for the cases adoption skips (invalid or absent `r`).
  final relayUrl = resolveRelayUrl(_injector.get<Preferences>());
  return WsTransport.connect(
    relayUrl: relayUrl,
    peerPubkey: qr.epk,
    ed25519Key: deviceEd25519,
  );
}

// ---------------------------------------------------------------------------

class _CancelledError implements Exception {
  const _CancelledError();
}

void disposeDependencies() => _injector.dispose();

/// Bridges auto_injector and provider: creates a `ChangeNotifierProvider` that
/// asks the injector for a fresh `ViewModel<T>` instance on each route mount.
class ViewmodelProvider<T extends ViewModel> extends ChangeNotifierProvider<T> {
  ViewmodelProvider({super.key, super.child})
    : super(create: (_) => _injector.get<T>());

  ViewmodelProvider.value({super.key, required super.value, super.child})
    : super.value();
}
