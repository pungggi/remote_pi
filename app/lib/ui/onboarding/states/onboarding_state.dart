// Sealed state for OnboardingViewModel. Switch exhaustively in
// OnboardingPage.build().

enum OnboardingStep { welcome, relay, pair }

enum RelayChoice { fromQr, custom }

sealed class OnboardingState {
  const OnboardingState();
}

class OnboardingInProgress extends OnboardingState {
  final OnboardingStep step;
  final RelayChoice relayChoice;
  final String customRelayUrl;
  final String? customRelayError;

  const OnboardingInProgress({
    this.step = OnboardingStep.welcome,
    this.relayChoice = RelayChoice.fromQr,
    this.customRelayUrl = '',
    this.customRelayError,
  });

  OnboardingInProgress copyWith({
    OnboardingStep? step,
    RelayChoice? relayChoice,
    String? customRelayUrl,
    String? customRelayError,
    bool clearCustomError = false,
  }) =>
      OnboardingInProgress(
        step: step ?? this.step,
        relayChoice: relayChoice ?? this.relayChoice,
        customRelayUrl: customRelayUrl ?? this.customRelayUrl,
        customRelayError:
            clearCustomError ? null : (customRelayError ?? this.customRelayError),
      );

  @override
  bool operator ==(Object other) =>
      other is OnboardingInProgress &&
      other.step == step &&
      other.relayChoice == relayChoice &&
      other.customRelayUrl == customRelayUrl &&
      other.customRelayError == customRelayError;

  @override
  int get hashCode =>
      Object.hash(step, relayChoice, customRelayUrl, customRelayError);
}

class OnboardingComplete extends OnboardingState {
  const OnboardingComplete();
}
