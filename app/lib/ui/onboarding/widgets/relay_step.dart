import 'package:app/data/transport/relay_config.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:app/ui/onboarding/states/onboarding_state.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// Onboarding step 2 — relay choice.
///
/// Plan/102 — the default is [RelayChoice.fromQr]: the Pi runs a relay on the
/// local network and advertises its address in the pairing QR, which
/// PairingViewModel adopts on scan. That is the only workable default, since a
/// LAN address comes from DHCP and cannot be known before pairing.
///
/// Picking it saves `null` in Preferences, so until the first scan
/// [resolveRelayUrl] falls back to [kDefaultRelayUrl] — the relay adoption then
/// overwrites it. The manual card stays for relays that are NOT discovered this
/// way: one reachable from outside the WLAN, or a host the QR cannot name.
/// Leaving its field empty is the same as choosing the QR option.
class RelayStep extends StatelessWidget {
  final OnboardingInProgress state;
  final ValueChanged<RelayChoice> onChoice;
  final ValueChanged<String> onCustomUrl;
  final VoidCallback onBack;
  final VoidCallback onNext;

  const RelayStep({
    super.key,
    required this.state,
    required this.onChoice,
    required this.onCustomUrl,
    required this.onBack,
    required this.onNext,
  });

  bool get _canContinue {
    if (state.relayChoice == RelayChoice.fromQr) return true;
    // Empty custom URL is allowed — same outcome as RelayChoice.fromQr.
    if (state.customRelayUrl.isEmpty) return true;
    return isValidRelayUrl(state.customRelayUrl);
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 24),
          Text(
            'Choose a relay',
            style: TextStyle(
              fontFamily: kMonoFamily,
              fontSize: 16,
              color: colors.text,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'Where the app and your PC meet.',
            style: TextStyle(
                fontFamily: kMonoFamily, fontSize: 11, color: colors.muted),
          ),
          const SizedBox(height: 24),
          _RelayCard(
            title: 'From the pairing QR',
            badge: 'recommended',
            description:
                'Your PC runs the relay on your Wi-Fi and puts its address in '
                'the QR code. The app picks it up when you scan — nothing to '
                'type, and nothing leaves your network.',
            selected: state.relayChoice == RelayChoice.fromQr,
            onTap: () => onChoice(RelayChoice.fromQr),
          ),
          const SizedBox(height: 12),
          _CustomRelayCard(
            description:
                'For a relay the QR cannot name — one you reach from outside '
                'your Wi-Fi, for example.',
            selected: state.relayChoice == RelayChoice.custom,
            customUrl: state.customRelayUrl,
            error: state.customRelayError,
            onTap: () => onChoice(RelayChoice.custom),
            onUrlChanged: onCustomUrl,
          ),
          const Spacer(),
          Row(
            children: [
              OutlinedButton(
                onPressed: onBack,
                style: OutlinedButton.styleFrom(
                  foregroundColor: colors.muted,
                  side: BorderSide(color: colors.border),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
                  shape: const RoundedRectangleBorder(
                    borderRadius: BorderRadius.all(Radius.circular(6)),
                  ),
                ),
                child: Text(
                  'Back',
                  style: TextStyle(fontFamily: kMonoFamily, fontSize: 13),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton(
                  onPressed: _canContinue ? onNext : null,
                  style: FilledButton.styleFrom(
                    backgroundColor: colors.accent,
                    foregroundColor: colors.onAccent,
                    disabledBackgroundColor: colors.border,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: const RoundedRectangleBorder(
                      borderRadius: BorderRadius.all(Radius.circular(6)),
                    ),
                  ),
                  child: const Text(
                    'Continue',
                    style: TextStyle(
                      fontFamily: kMonoFamily,
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}

class _RelayCard extends StatelessWidget {
  final String title;
  final String description;
  final String? badge;
  final bool selected;
  final VoidCallback onTap;
  const _RelayCard({
    required this.title,
    required this.description,
    required this.selected,
    required this.onTap,
    this.badge,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: colors.bg,
          border: Border.all(
            color: selected ? colors.accent : colors.border,
            width: selected ? 1.5 : 1,
          ),
          borderRadius: const BorderRadius.all(Radius.circular(8)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  selected ? LucideIcons.circleDot : LucideIcons.circle,
                  size: 16,
                  color: selected ? colors.accent : colors.muted,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    title,
                    style: TextStyle(
                      fontFamily: kMonoFamily,
                      fontSize: 13,
                      color: colors.text,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                if (badge != null)
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: colors.accent.withValues(alpha: 0.15),
                      borderRadius:
                          const BorderRadius.all(Radius.circular(4)),
                    ),
                    child: Text(
                      badge!,
                      style: TextStyle(
                        fontFamily: kMonoFamily,
                        fontSize: 9,
                        color: colors.accent,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.only(left: 26),
              child: Text(
                description,
                style: TextStyle(
                  fontFamily: kMonoFamily,
                  fontSize: 11,
                  color: colors.muted,
                  height: 1.4,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CustomRelayCard extends StatelessWidget {
  final bool selected;
  final String customUrl;
  final String? error;
  final String? badge;
  final String? description;
  final VoidCallback onTap;
  final ValueChanged<String> onUrlChanged;
  const _CustomRelayCard({
    required this.selected,
    required this.customUrl,
    required this.error,
    required this.onTap,
    required this.onUrlChanged,
    this.badge,
    this.description,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: colors.bg,
          border: Border.all(
            color: selected ? colors.accent : colors.border,
            width: selected ? 1.5 : 1,
          ),
          borderRadius: const BorderRadius.all(Radius.circular(8)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  selected ? LucideIcons.circleDot : LucideIcons.circle,
                  size: 16,
                  color: selected ? colors.accent : colors.muted,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Enter it manually',
                    style: TextStyle(
                      fontFamily: kMonoFamily,
                      fontSize: 13,
                      color: colors.text,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                if (badge != null)
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: colors.accent.withValues(alpha: 0.15),
                      borderRadius:
                          const BorderRadius.all(Radius.circular(4)),
                    ),
                    child: Text(
                      badge!,
                      style: TextStyle(
                        fontFamily: kMonoFamily,
                        fontSize: 9,
                        color: colors.accent,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
              ],
            ),
            if (description != null) ...[
              const SizedBox(height: 8),
              Padding(
                padding: const EdgeInsets.only(left: 26),
                child: Text(
                  description!,
                  style: TextStyle(
                    fontFamily: kMonoFamily,
                    fontSize: 11,
                    color: colors.muted,
                    height: 1.4,
                  ),
                ),
              ),
            ],
            if (selected) ...[
              const SizedBox(height: 12),
              Padding(
                padding: const EdgeInsets.only(left: 26),
                child: TextField(
                  controller: TextEditingController(text: customUrl)
                    ..selection = TextSelection.fromPosition(
                      TextPosition(offset: customUrl.length),
                    ),
                  onChanged: onUrlChanged,
                  style: TextStyle(
                    fontFamily: kMonoFamily,
                    fontSize: 12,
                    color: colors.text,
                  ),
                  decoration: InputDecoration(
                    isDense: true,
                    hintText: 'http://192.168.1.10:3000',
                    hintStyle:
                        TextStyle(fontFamily: kMonoFamily, color: colors.muted),
                    errorText: error,
                    errorStyle: TextStyle(
                      fontFamily: kMonoFamily,
                      fontSize: 10,
                      color: colors.error,
                    ),
                    contentPadding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                    enabledBorder: OutlineInputBorder(
                      borderSide: BorderSide(color: colors.border),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderSide: BorderSide(color: colors.accent),
                    ),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

