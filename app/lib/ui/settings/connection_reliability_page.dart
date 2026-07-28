import 'package:app/data/device/reliability_service.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

/// Plan 116 — brings the phone settings that keep Piper alive across network
/// changes (battery exemption + Tailscale always-on/battery) within 1–2 taps.
/// Piper can exempt *itself* with a one-tap system dialog; it can only
/// *deep-link* to Tailscale's settings (it cannot configure another app).
class ConnectionReliabilityPage extends StatefulWidget {
  const ConnectionReliabilityPage({super.key});

  @override
  State<ConnectionReliabilityPage> createState() =>
      _ConnectionReliabilityPageState();
}

class _ConnectionReliabilityPageState extends State<ConnectionReliabilityPage> {
  late final ReliabilityService _svc;
  // null = loading, true = currently optimized (needs exemption),
  // false = already exempt.
  bool? _optimized;
  late final bool _tailscaleRelay;

  @override
  void initState() {
    super.initState();
    // Provided by the route via Provider<ReliabilityService>.value (review
    // #4) — keeps the UI decoupled from config/ and widget-testable.
    _svc = context.read<ReliabilityService>();
    _tailscaleRelay = _svc.isTailscaleRelay;
    _refresh();
  }

  Future<void> _refresh() async {
    final opt = await _svc.isBatteryOptimized();
    if (!mounted) return;
    setState(() => _optimized = opt);
  }

  Future<void> _grantExemption() async {
    await _svc.requestBatteryExemption();
    // The system dialog is async; give it a beat, then re-check.
    await Future<void>.delayed(const Duration(milliseconds: 400));
    await _refresh();
  }

  Future<void> _openTailscale() async {
    final ok = await _svc.openTailscaleBatterySettings();
    if (!mounted) return;
    if (!ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Tailscale is not installed on this device.'),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Scaffold(
      backgroundColor: colors.bg,
      appBar: AppBar(
        backgroundColor: colors.bg,
        title: const Text('Connection reliability'),
        leading: IconButton(
          icon: Icon(LucideIcons.chevronLeft, size: 18, color: colors.text),
          tooltip: 'Back',
          onPressed: () =>
              context.canPop() ? context.pop() : context.go('/settings'),
        ),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Divider(color: colors.border, height: 1),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          // --- Battery exemption (Piper itself) ---
          _SectionLabel('BACKGROUND'),
          ListTile(
            leading: Icon(
              _optimized == false
                  ? LucideIcons.shieldCheck
                  : LucideIcons.shieldAlert,
              size: 20,
              color: _optimized == false ? colors.success : colors.warning,
            ),
            title: Text(
              'Battery optimization',
              style: const TextStyle(fontFamily: kMonoFamily, fontSize: 14),
            ),
            subtitle: Text(
              _optimized == null
                  ? 'Checking…'
                  : _optimized!
                  ? 'Piper may be paused in the background'
                  : 'Exempt — Piper runs in the background',
              style: TextStyle(
                fontFamily: kMonoFamily,
                fontSize: 12,
                color: colors.muted,
              ),
            ),
            trailing: _optimized == null
                ? SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: colors.accent,
                    ),
                  )
                : _optimized!
                ? FilledButton.tonal(
                    onPressed: _grantExemption,
                    child: const Text('Allow'),
                  )
                : Icon(LucideIcons.check, size: 18, color: colors.success),
          ),
          if (_tailscaleRelay) ...[
            Divider(color: colors.border, height: 1),
            _SectionLabel('TAILSCALE'),
            // Piper can't flip these — we deep-link to the exact screen.
            ListTile(
              leading: Icon(
                LucideIcons.batteryCharging,
                size: 20,
                color: colors.text,
              ),
              title: Text(
                'Tailscale battery',
                style: const TextStyle(fontFamily: kMonoFamily, fontSize: 14),
              ),
              subtitle: Text(
                'Tap Battery → Unrestricted',
                style: TextStyle(
                  fontFamily: kMonoFamily,
                  fontSize: 12,
                  color: colors.muted,
                ),
              ),
              trailing: Icon(
                LucideIcons.chevronRight,
                size: 18,
                color: colors.muted2,
              ),
              onTap: _openTailscale,
            ),
            ListTile(
              leading: Icon(LucideIcons.globe, size: 20, color: colors.text),
              title: Text(
                'Always-on VPN',
                style: const TextStyle(fontFamily: kMonoFamily, fontSize: 14),
              ),
              subtitle: Text(
                'Enable Always-on for Tailscale',
                style: TextStyle(
                  fontFamily: kMonoFamily,
                  fontSize: 12,
                  color: colors.muted,
                ),
              ),
              trailing: Icon(
                LucideIcons.chevronRight,
                size: 18,
                color: colors.muted2,
              ),
              onTap: () => _svc.openVpnSettings(),
            ),
          ],
          Divider(color: colors.border, height: 1),
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 14, 18, 24),
            child: Text(
              _tailscaleRelay
                  ? 'If Piper goes offline when you switch networks, these '
                      'keep Tailscale alive in the background so the '
                      'connection recovers on its own.'
                  : 'Allowing Piper to run in the background keeps its '
                      'connection to the relay alive across network changes.',
              style: TextStyle(
                fontFamily: kMonoFamily,
                fontSize: 12,
                color: colors.muted,
                height: 1.5,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);
  final String text;
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 14, 18, 4),
      child: Text(
        text,
        style: TextStyle(
          fontFamily: kMonoFamily,
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: context.colors.muted,
          letterSpacing: 0.8,
        ),
      ),
    );
  }
}
