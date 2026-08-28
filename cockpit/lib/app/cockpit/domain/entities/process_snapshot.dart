class ProcessSnapshot {
  final int pid;
  final int ppid;
  final String executable;
  final List<String> argv;
  final bool isForeground;
  final String? tty;
  final String? state;
  final Map<String, String> env;

  const ProcessSnapshot({
    required this.pid,
    required this.ppid,
    required this.executable,
    required this.argv,
    this.isForeground = true,
    this.tty,
    this.state,
    this.env = const {},
  });
}
