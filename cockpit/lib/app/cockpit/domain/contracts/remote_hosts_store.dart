import 'package:cockpit/app/cockpit/domain/entities/remote_host.dart';
import 'package:cockpit/app/cockpit/domain/entities/remote_workspace_pin.dart';

/// Registro de hosts remotos do cliente (plano 58, decisão C): a ÚNICA coisa
/// que o cliente persiste sobre remoto — id, nome, endpoint SSH, + os pins de
/// workspace (pastas do host fixadas).
abstract class RemoteHostsStore {
  List<RemoteHost> hosts();
  Future<void> save(RemoteHost host);
  Future<void> remove(String id);

  /// Pins de workspace remoto (pastas fixadas de um host).
  List<RemoteWorkspacePin> pins();
  Future<void> savePin(RemoteWorkspacePin pin);
  Future<void> removePin(String id);
}
