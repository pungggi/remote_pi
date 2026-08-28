// Confirma se o native asset do anaki_postgres resolve num exe compilado do
// cockpit_engine (mesmo caminho do cockpit-server). Conecta num host bogus:
// se falhar com "connection refused" o native está OK; se "symbol not found"
// ou "No available native assets", o native NÃO foi empacotado.
import 'dart:io';

import 'package:cockpit_core/cockpit_core.dart';
import 'package:cockpit_engine/cockpit_engine.dart';

Future<void> main() async {
  const db = NativeDbService();
  try {
    await db.query(
      const RemoteDbConnDescriptor(
        engine: 'postgres',
        host: '127.0.0.1',
        port: 1, // ninguém escuta → connection refused se o native carregar
        user: 'x',
        database: 'x',
        password: 'x',
      ),
      'SELECT 1',
    );
    stdout.writeln('PG-CHECK: query retornou (inesperado)');
  } catch (e) {
    final s = '$e';
    if (s.contains('symbol not found') ||
        s.contains('No available native assets') ||
        s.contains("resolve native function")) {
      stdout.writeln('PG-CHECK FAIL (native ausente): $s');
      exit(1);
    }
    stdout.writeln('PG-CHECK OK (native carregou; erro esperado de conexão)');
  }
}
