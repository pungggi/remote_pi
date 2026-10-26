/// Próximo id ao ciclar pela lista de workspaces do rail ([order], na ordem
/// visual: raiz seguida dos seus worktrees). [delta] = +1 avança, -1 volta;
/// dá a volta nas pontas. Se [current] não está na lista (nada selecionado,
/// ou o terminal de sistema "Cockpit", que fica fora do ciclo), avançar vai
/// pro primeiro e voltar vai pro último. `null` se a lista está vazia.
String? nextWorkspaceId(List<String> order, String? current, int delta) {
  if (order.isEmpty) return null;
  final index = current == null ? -1 : order.indexOf(current);
  if (index < 0) return delta >= 0 ? order.first : order.last;
  final n = order.length;
  return order[((index + delta) % n + n) % n];
}
