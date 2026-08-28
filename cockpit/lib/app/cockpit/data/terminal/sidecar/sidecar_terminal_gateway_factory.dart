import 'package:cockpit/app/cockpit/data/terminal/sidecar/sidecar_terminal_connector.dart';
import 'package:cockpit/app/cockpit/data/terminal/sidecar/sidecar_terminal_gateway.dart';
import 'package:cockpit/app/cockpit/domain/contracts/terminal_gateway.dart';
import 'package:cockpit/app/cockpit/domain/contracts/terminal_gateway_factory.dart';

/// Cria um [SidecarTerminalGateway] por terminal, todos compartilhando o
/// mesmo conector (uma conexão loopback pro sidecar por app).
class SidecarTerminalGatewayFactory implements TerminalGatewayFactory {
  SidecarTerminalGatewayFactory(this._connector);

  final SidecarTerminalConnector _connector;

  @override
  TerminalGateway create() => SidecarTerminalGateway(_connector);
}
