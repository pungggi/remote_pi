import 'package:cockpit/app/core/domain/entities/automation.dart';

abstract class AutomationGateway {
  Future<List<AutomationHarness>> discover();

  Future<GeneratedCommitMessage> generate({
    required AutomationSelection selection,
    required AutomationRequest request,
  });

  Future<void> cancel();

  Future<void> close();
}
