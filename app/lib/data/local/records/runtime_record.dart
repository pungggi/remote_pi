/// Plan/31 — VOLATILE runtime state (#3). Lives in the `runtime` box that is
/// wiped on every boot, so it never reports stale online/presence across
/// restarts. Reduced enums (not the rich sealed `ConnectionStatus`, which
/// carries a live channel and can't be serialized).
enum RuntimeConnection { connecting, online, offline, retrying, sleeping }

enum RuntimePresence { alive, stale, unknown }

class RuntimeRecord {
  final RuntimeConnection connection;
  final RuntimePresence presence;

  const RuntimeRecord({
    this.connection = RuntimeConnection.connecting,
    this.presence = RuntimePresence.unknown,
  });

  RuntimeRecord copyWith({
    RuntimeConnection? connection,
    RuntimePresence? presence,
  }) => RuntimeRecord(
    connection: connection ?? this.connection,
    presence: presence ?? this.presence,
  );

  Map<String, dynamic> toJson() => {
    'connection': connection.name,
    'presence': presence.name,
  };

  factory RuntimeRecord.fromJson(Map<String, dynamic> j) => RuntimeRecord(
    connection: RuntimeConnection.values.firstWhere(
      (c) => c.name == j['connection'],
      orElse: () => RuntimeConnection.connecting,
    ),
    presence: RuntimePresence.values.firstWhere(
      (p) => p.name == j['presence'],
      orElse: () => RuntimePresence.unknown,
    ),
  );

  @override
  bool operator ==(Object other) =>
      other is RuntimeRecord &&
      other.connection == connection &&
      other.presence == presence;

  @override
  int get hashCode => Object.hash(connection, presence);
}
