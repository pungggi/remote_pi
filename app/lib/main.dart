import 'package:app/config/dependencies.dart';
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
  injector
      .get<KeepAliveController>()
      .attach(injector.get<ConnectionManager>());
  // Plan/104 — if launched via a Share (ACTION_SEND image), pull it now so it
  // waits in the inbox; the router listener routes to the chat once booted.
  final shared = await injector.get<IImagePickerService>().consumeSharedImage();
  if (shared != null) injector.get<SharedImageInbox>().deposit([shared]);
  final sharedPdf =
      await injector.get<IImagePickerService>().consumeSharedPdf();
  if (sharedPdf != null) injector.get<SharedImageInbox>().deposit(sharedPdf);
  final sharedText =
      await injector.get<IImagePickerService>().consumeSharedText();
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
    final meshSync = injector.get<MeshSyncService>();
    switch (state) {
      case AppLifecycleState.resumed:
        meshSync.startPolling();
        // ignore: unawaited_futures
        meshSync.pullOnDemand();
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
      ],
      // Theme is reactive: toggling the mode in Settings notifies
      // [Preferences] → this Consumer rebuilds → MaterialApp swaps theme.
      child: Consumer<Preferences>(
        builder: (context, prefs, _) => MaterialApp.router(
          title: 'Piper',
          theme: buildLightTheme(),
          darkTheme: buildDarkTheme(),
          themeMode: prefs.themeMode,
          routerConfig: _router,
          debugShowCheckedModeBanner: false,
        ),
      ),
    );
  }
}
