import 'package:app/config/dependencies.dart';
import 'package:app/data/actions/actions_repository.dart';
import 'package:app/data/images/image_picker_service.dart';
import 'package:app/data/local/boxes.dart';
import 'package:app/data/mesh/mesh_sync_service.dart';
import 'package:app/data/preferences/preferences.dart';
import 'package:app/data/share/shared_image_inbox.dart';
import 'package:app/data/share/shared_text_inbox.dart';
import 'package:app/data/share/composer_draft.dart';
import 'package:app/data/sync/sync_service.dart';
import 'package:app/data/transport/connection_manager.dart';
import 'package:app/data/transport/keep_alive_controller.dart';
import 'package:app/data/transport/network_monitor.dart';
import 'package:app/pairing/owner_identity_bridge.dart';
import 'package:app/pairing/storage.dart';
import 'package:app/routing/adaptive.dart';
import 'package:app/routing/app_router.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Plan 31 — open the v2 SSOT boxes + WIPE the volatile runtime box BEFORE
  // anything subscribes (#3 / Risk 2).
  await LocalBoxes.init();
  await setupDependencies();
  // Eagerly construct the SSOT writer so it's consuming the channel from boot
  // (messages can arrive before the chat screen mounts).
  injector.get<SyncService>();
  // Plan 103 — mirror connection status into the Android foreground service so
  // the relay WS survives backgrounding. attach() also reflects the current
  // status (Online at boot → starts the notification).
  injector.get<KeepAliveController>().attach(injector.get<ConnectionManager>());
  // Plan 114 — react to network changes (Wi-Fi ↔ cellular) and force an
  // immediate reconnect so recovery starts within ~1s instead of the 30s
  // backoff ceiling. attach() subscribes to connectivity events.
  injector.get<NetworkMonitor>().attach(injector.get<ConnectionManager>());
  // Plan/104 — if launched via a Share (ACTION_SEND image), pull it now so it
  // waits in the inbox; the router listener routes to the chat once booted.
  final shared = await injector.get<IImagePickerService>().consumeSharedImage();
  if (shared != null) injector.get<SharedImageInbox>().deposit([shared]);
  final sharedPdf = await injector
      .get<IImagePickerService>()
      .consumeSharedPdf();
  if (sharedPdf != null) injector.get<SharedImageInbox>().deposit(sharedPdf);
  final sharedText = await injector
      .get<IImagePickerService>()
      .consumeSharedText();
  if (sharedText != null) injector.get<SharedTextInbox>().deposit(sharedText);
  runApp(const PiperApp());
}

class PiperApp extends StatefulWidget {
  const PiperApp({super.key});

  @override
  State<PiperApp> createState() => _PiperAppState();
}

class _PiperAppState extends State<PiperApp> with WidgetsBindingObserver {
  late final _router = buildRouter(
    injector.get<PairingStorage>(),
    injector.get<ConnectionManager>(),
    injector.get<Preferences>(),
    injector.get<OwnerIdentityBridge>(),
    injector.get<MeshSyncService>(),
  );

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Plan/104 — when boot lands past /boot with a pending shared image, route
    // to the chat (cold-start share). Warm shares are handled on resume.
    _router.routerDelegate.addListener(_onRouteChanged);
  }

  @override
  void dispose() {
    _router.routerDelegate.removeListener(_onRouteChanged);
    WidgetsBinding.instance.removeObserver(this);
    disposeDependencies();
    super.dispose();
  }

  /// Plan 24 — keep the mesh poll timer aligned with the app's
  /// foreground lifecycle. Polling runs ONLY while resumed; in
  /// inactive/paused/hidden/detached we cancel so we don't drain the
  /// battery (and we'll resync via `pullOnDemand` on the next resume +
  /// boot path).
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Plan 125 — the foreground service only earns its keep while backgrounded.
    // Foregrounded, the process is already foreground-priority, so running it
    // would waste the Android-15 `dataSync` 6 h budget for nothing.
    injector.get<KeepAliveController>().setBackgrounded(
      state != AppLifecycleState.resumed,
    );
    // Plan 125 (Layer 2) — lean keep-alive cadence while backgrounded, active
    // on resume. Slows the protocol Ping (25 → 90 s) and the watchdog (30 → 60 s)
    // while the app is in the background, halving outbound + CPU wakeups.
    injector.get<ConnectionManager>().setPowerMode(
      state == AppLifecycleState.resumed ? PowerMode.active : PowerMode.lean,
    );
    final meshSync = injector.get<MeshSyncService>();
    switch (state) {
      case AppLifecycleState.resumed:
        meshSync.startPolling();
        // Strategy fix (2026-08-21): re-sync the transcript on resume — a
        // session_sync reply lost to a PC reconnect would otherwise leave
        // the chat on a stale cache until the next chat open. Idempotent
        // (durable merge dedups) and cheap when nothing was missed.
        injector.get<SyncService>().requestSync();
        // ignore: unawaited_futures
        meshSync.pullOnDemand();
        // Fix (2026-08-16): also reconcile a missing blob on resume — a
        // fresh install whose first publish failed transiently recovers
        // on the very next app-open instead of waiting for the poll tick.
        // ignore: unawaited_futures
        meshSync.reconcileMissingBlobIfMissing();
        // Plan/104 — a warm share (app was backgrounded) is stashed in
        // onNewIntent; pull it (image or text) and route to the chat.
        _consumeShares();
      case AppLifecycleState.inactive:
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
      case AppLifecycleState.detached:
        meshSync.stopPolling();
    }
  }

  // Plan/104 — Share-to-attach routing.
  void _onRouteChanged() => _maybeRouteToChat();

  Future<void> _consumeShares() async {
    final img = await injector.get<IImagePickerService>().consumeSharedImage();
    if (img != null) injector.get<SharedImageInbox>().deposit([img]);
    final pdf = await injector.get<IImagePickerService>().consumeSharedPdf();
    if (pdf != null) injector.get<SharedImageInbox>().deposit(pdf);
    final txt = await injector.get<IImagePickerService>().consumeSharedText();
    if (txt != null) injector.get<SharedTextInbox>().deposit(txt);
    if (img != null || pdf != null || txt != null) await _maybeRouteToChat();
  }

  Future<void> _maybeRouteToChat() async {
    final imgInbox = injector.get<SharedImageInbox>();
    final txtInbox = injector.get<SharedTextInbox>();
    if (!imgInbox.hasPending && !txtInbox.hasPending) return;
    final loc =
        _router.routerDelegate.currentConfiguration.last.matchedLocation;
    // Skip while still booting, or if a chat is already open (it consumes live).
    if (loc == '/chat' ||
        loc == '/boot' ||
        loc.startsWith('/onboarding') ||
        loc == '/sync-required') {
      return;
    }
    final peers = await injector.get<PairingStorage>().listPeers();
    final stillPending = imgInbox.hasPending || txtInbox.hasPending;
    if (peers.isEmpty || !stillPending) return;
    _router.push('/chat');
  }

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider<Preferences>.value(
          value: injector.get<Preferences>(),
        ),
        ChangeNotifierProvider<SharedTextInbox>.value(
          value: injector.get<SharedTextInbox>(),
        ),
        ChangeNotifierProvider<ComposerDraft>.value(
          value: injector.get<ComposerDraft>(),
        ),
        ChangeNotifierProvider<SessionSelection>.value(
          value: injector.get<SessionSelection>(),
        ),
        // Shell layout state — lets the adaptive shell collapse the split
        // into a single centered pane on zero-state Home (no Pi / empty).
        ChangeNotifierProvider<ShellLayout>.value(
          value: injector.get<ShellLayout>(),
        ),
        // Plan/107 — exposes the actions repo to the chat session-info
        // dialog (one-off read for gitStatus()). Not a ChangeNotifier.
        Provider<IActionsRepository>.value(
          value: injector.get<IActionsRepository>(),
        ),
      ],
      // Theme + font scale are reactive: toggling the mode or picking a
      // size preset in Settings notifies [Preferences] → this Consumer
      // rebuilds → MaterialApp swaps theme / re-applies the text scaler.
      child: Consumer<Preferences>(
        builder: (context, prefs, _) => MaterialApp.router(
          title: 'Piper',
          theme: buildLightTheme(),
          darkTheme: buildDarkTheme(),
          themeMode: prefs.themeMode,
          routerConfig: _router,
          debugShowCheckedModeBanner: false,
          // Plan 131 (upstream #114) — compose the user's font-size preset
          // onto the OS text scale. Multiplied (not replaced) so the system
          // accessibility setting keeps working; identity at the default
          // preset (see applyFontScale).
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              textScaler: applyFontScale(
                MediaQuery.textScalerOf(context),
                prefs.uiFontScale.factor,
              ),
            ),
            child: child ?? const SizedBox.shrink(),
          ),
        ),
      ),
    );
  }
}
