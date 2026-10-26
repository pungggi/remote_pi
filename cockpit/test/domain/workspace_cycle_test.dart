import 'package:cockpit/app/cockpit/domain/services/workspace_cycle.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const order = ['a', 'a::wt1', 'b', 'c'];

  test('avança e volta na ordem do rail, incluindo worktrees', () {
    expect(nextWorkspaceId(order, 'a', 1), 'a::wt1');
    expect(nextWorkspaceId(order, 'a::wt1', 1), 'b');
    expect(nextWorkspaceId(order, 'b', -1), 'a::wt1');
  });

  test('dá a volta nas pontas', () {
    expect(nextWorkspaceId(order, 'c', 1), 'a');
    expect(nextWorkspaceId(order, 'a', -1), 'c');
  });

  test('fora da lista: avançar vai pro primeiro, voltar pro último', () {
    expect(nextWorkspaceId(order, null, 1), 'a');
    expect(nextWorkspaceId(order, '__cockpit__', -1), 'c');
  });

  test('lista vazia devolve null', () {
    expect(nextWorkspaceId(const [], 'a', 1), isNull);
  });
}
