// PREVIEW ESTÁTICO — workspace multi-root (multirepo). Não faz parte do app:
// é um target separado só pra visualizar o desenho da feature antes do plano.
//
//   flutter run -d macos -t lib/main_multiroot_preview.dart
//
// Mostra: lista de projetos (mono e multi lado a lado, worktree-filho),
// árvore de arquivos com N roots + badge git por root, escolha de root no "+",
// e os dois dialogs (detecção na criação e "Manage roots…").
// Nada aqui tem lógica: dados fake, callbacks abrem só os dialogs mock.
import 'package:cockpit/app/core/ui/themes/app_colors.dart';
import 'package:flutter/material.dart';

const AppColors _c = AppColors.dark;

void main() => runApp(const _PreviewApp());

class _PreviewApp extends StatelessWidget {
  const _PreviewApp();

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: _c.bg,
        fontFamily: '.AppleSystemUIFont',
      ),
      home: const _PreviewShell(),
    );
  }
}

// ---------------------------------------------------------------------------
// Dados fake
// ---------------------------------------------------------------------------

class _MockRoot {
  const _MockRoot(this.name, this.branch, this.dirty, this.children);
  final String name;
  final String branch;
  final int dirty; // arquivos alterados
  final List<_MockNode> children;
}

class _MockNode {
  const _MockNode(this.name, {this.isDir = false, this.git});
  final String name;
  final bool isDir;
  final Color? git; // cor de status git do arquivo (null = limpo)
}

const List<_MockRoot> _roots = [
  _MockRoot('app', 'main', 0, [
    _MockNode('lib', isDir: true),
    _MockNode('pubspec.yaml'),
  ]),
  _MockRoot('backend', 'feat/auth', 2, [
    _MockNode('src', isDir: true),
    _MockNode('auth_service.ts', git: Color(0xFFE0A33A)), // modificado
    _MockNode('session.ts', git: Color(0xFF4F9DF0)), // novo
  ]),
  _MockRoot('infra', 'main', 0, [_MockNode('terraform', isDir: true)]),
  _MockRoot('shared-libs', 'develop', 1, [
    _MockNode('ui-kit', isDir: true),
    _MockNode('tokens.css', git: Color(0xFFE0A33A)),
  ]),
];

// ---------------------------------------------------------------------------
// Shell: lista de projetos | centro (placeholder) | árvore multi-root
// ---------------------------------------------------------------------------

class _PreviewShell extends StatelessWidget {
  const _PreviewShell();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const _ProjectsColumn(),
          Container(width: 1, color: _c.border),
          const Expanded(child: _CenterPlaceholder()),
          Container(width: 1, color: _c.border),
          const _FileTreeColumn(),
        ],
      ),
    );
  }
}

/// Coluna esquerda — lista de projetos: monorepo e multirepo indistinguíveis
/// por fora; worktree segue sendo filho aninhado (agora "de uma root").
class _ProjectsColumn extends StatelessWidget {
  const _ProjectsColumn();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 210,
      color: _c.panel,
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _SectionLabel('WORKSPACES'),
          _projectRow(
            'Cockpit',
            const Color(0xFF6B7280),
            icon: Icons.terminal,
            showMenu: false,
          ),
          // Monorepo: chip de branch único, como hoje (âmbar quando sujo).
          _projectRow(
            'Remote Pi',
            const Color(0xFF8B5CF6),
            badge: _branchChip('feat/testunique', dirty: 2),
          ),
          _worktreeRow('✳ testunique'),
          // Multi-root: chip agregado — N roots + total de sujeira. As branches
          // individuais moram na árvore (não cabem/não fazem sentido aqui).
          _projectRow(
            'Projeto X',
            const Color(0xFF0EA5E9),
            selected: true,
            badge: _multiRootChip(roots: 4, dirtyRoots: 2),
            multiRoot: true,
          ),
          _worktreeRow('✳ feat-auth (backend)'),
          _projectRow(
            'Outro Projeto',
            const Color(0xFFF59E0B),
            badge: _branchChip('main'),
          ),
          const Spacer(),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Text(
              'Preview estático — multi-root.\nNada aqui é funcional.',
              style: TextStyle(color: _c.text4, fontSize: 11, height: 1.4),
            ),
          ),
        ],
      ),
    );
  }

  /// Chip de branch de workspace single-root — igual ao app real: cinza limpo,
  /// âmbar com contador quando há mudanças.
  static Widget _branchChip(String branch, {int dirty = 0}) {
    final color = dirty > 0 ? _c.warn : _c.text3;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: dirty > 0
            ? _c.warn.withValues(alpha: .15)
            : _c.panel3.withValues(alpha: .8),
        borderRadius: BorderRadius.circular(5),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.call_split, size: 10, color: color),
          const SizedBox(width: 3),
          Flexible(
            child: Text(
              dirty > 0 ? '$branch $dirty' : branch,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: color,
                fontSize: 10,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Chip agregado do multi-root: quantas roots e quantas estão sujas.
  static Widget _multiRootChip({required int roots, required int dirtyRoots}) {
    final dirty = dirtyRoots > 0;
    final color = dirty ? _c.warn : _c.text3;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: dirty
            ? _c.warn.withValues(alpha: .15)
            : _c.panel3.withValues(alpha: .8),
        borderRadius: BorderRadius.circular(5),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.account_tree_outlined, size: 10, color: color),
          const SizedBox(width: 3),
          Text(
            dirty ? '$roots roots · $dirtyRoots●' : '$roots roots',
            style: TextStyle(
              color: color,
              fontSize: 10,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  Widget _projectRow(
    String name,
    Color color, {
    bool selected = false,
    Widget? badge,
    IconData? icon,
    bool multiRoot = false,
    bool showMenu = true,
  }) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: selected ? _c.panel3 : null,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        children: [
          Container(
            width: 22,
            height: 22,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: color.withValues(alpha: .25),
              borderRadius: BorderRadius.circular(5),
            ),
            child: icon != null
                ? Icon(icon, size: 13, color: color)
                : Text(
                    name[0],
                    style: TextStyle(
                      color: color,
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name,
                  style: TextStyle(
                    color: selected ? _c.text : _c.text2,
                    fontSize: 12.5,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                  ),
                ),
                if (badge != null) ...[
                  const SizedBox(height: 3),
                  Align(alignment: Alignment.centerLeft, child: badge),
                ],
              ],
            ),
          ),
          if (showMenu)
            Builder(
              builder: (context) => InkWell(
                onTap: () => _showWorkspaceMenu(context, name, multiRoot),
                child: Icon(Icons.more_vert, size: 14, color: _c.text4),
              ),
            ),
        ],
      ),
    );
  }

  Widget _worktreeRow(String name) {
    return Padding(
      padding: const EdgeInsets.only(left: 34, right: 8, top: 1, bottom: 1),
      child: Row(
        children: [
          Icon(Icons.subdirectory_arrow_right, size: 12, color: _c.text4),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              name,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: _c.text3, fontSize: 11.5),
            ),
          ),
        ],
      ),
    );
  }
}

/// Centro — só marca onde ficam os panes; o foco do preview é a árvore.
class _CenterPlaceholder extends StatelessWidget {
  const _CenterPlaceholder();

  @override
  Widget build(BuildContext context) {
    return Container(
      color: _c.bg,
      alignment: Alignment.center,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.grid_view_rounded, size: 40, color: _c.text4),
          const SizedBox(height: 12),
          Text(
            'panes / agentes / terminal\n(inalterados nesta feature)',
            textAlign: TextAlign.center,
            style: TextStyle(color: _c.text3, fontSize: 12, height: 1.5),
          ),
          const SizedBox(height: 28),
          Wrap(
            spacing: 10,
            children: [
              _DialogButton(
                label: 'Dialog: detecção na criação',
                onTap: (ctx) => _showDetectionDialog(ctx),
              ),
              _DialogButton(
                label: 'Dialog: Manage roots…',
                onTap: (ctx) => _showManageRootsDialog(ctx),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.label);
  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 0, 14, 8),
      child: Text(
        label,
        style: TextStyle(
          color: _c.text3,
          fontSize: 10.5,
          fontWeight: FontWeight.w700,
          letterSpacing: .8,
        ),
      ),
    );
  }
}

class _DialogButton extends StatelessWidget {
  const _DialogButton({required this.label, required this.onTap});
  final String label;
  final void Function(BuildContext) onTap;

  @override
  Widget build(BuildContext context) {
    return OutlinedButton(
      style: OutlinedButton.styleFrom(
        foregroundColor: _c.accentText,
        side: BorderSide(color: _c.border2),
        textStyle: const TextStyle(fontSize: 12),
      ),
      onPressed: () => onTap(context),
      child: Text(label),
    );
  }
}

// ---------------------------------------------------------------------------
// Coluna direita — árvore de arquivos multi-root
// ---------------------------------------------------------------------------

class _FileTreeColumn extends StatefulWidget {
  const _FileTreeColumn();

  @override
  State<_FileTreeColumn> createState() => _FileTreeColumnState();
}

class _FileTreeColumnState extends State<_FileTreeColumn> {
  bool _sourceControl = false;
  bool _scTree = false; // toggle lista ↔ hierarquia (veio da main)

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 300,
      color: _c.panel,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _header(context),
          Container(height: 1, color: _c.border),
          Expanded(
            child: _sourceControl
                ? _SourceControlView(asTree: _scTree)
                : ListView(
                    padding: const EdgeInsets.only(top: 4, bottom: 12),
                    children: [
                      for (final root in _roots) ..._rootSection(context, root),
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  Widget _header(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
      child: Row(
        children: [
          _tabIcon(Icons.description_outlined, 'Files', !_sourceControl, () {
            setState(() => _sourceControl = false);
          }),
          const SizedBox(width: 4),
          _tabIcon(
            Icons.account_tree_outlined,
            'Source Control',
            _sourceControl,
            () => setState(() => _sourceControl = true),
          ),
          const Spacer(),
          if (_sourceControl)
            _tabIcon(
              _scTree ? Icons.view_list_outlined : Icons.account_tree_outlined,
              _scTree ? 'View as List' : 'View as Tree',
              false,
              () => setState(() => _scTree = !_scTree),
            )
          else ...[
            // "+" de nova aba: no multi-root, ganha o dropdown de root alvo.
            _NewTabRootButton(),
            Icon(Icons.refresh, size: 15, color: _c.text4),
          ],
        ],
      ),
    );
  }

  Widget _tabIcon(
    IconData icon,
    String tooltip,
    bool selected,
    VoidCallback onTap,
  ) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(5),
        child: Container(
          padding: const EdgeInsets.all(4),
          decoration: BoxDecoration(
            color: selected ? _c.panel3 : null,
            borderRadius: BorderRadius.circular(5),
          ),
          child: Icon(icon, size: 15, color: selected ? _c.text : _c.text4),
        ),
      ),
    );
  }

  List<Widget> _rootSection(BuildContext context, _MockRoot root) {
    return [
      // Cabeçalho da root: nome + branch + sujeira, com menu de contexto.
      InkWell(
        onSecondaryTap: () => _showRootContextMenu(context, root),
        onLongPress: () => _showRootContextMenu(context, root),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(10, 8, 10, 4),
          child: Row(
            children: [
              Icon(Icons.expand_more, size: 14, color: _c.text3),
              const SizedBox(width: 4),
              Text(
                root.name,
                style: TextStyle(
                  color: _c.text,
                  fontSize: 12.5,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(width: 8),
              _branchBadge(root.branch),
              const Spacer(),
              if (root.dirty > 0)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 5,
                    vertical: 1,
                  ),
                  decoration: BoxDecoration(
                    color: _c.warn.withValues(alpha: .18),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    '●${root.dirty}',
                    style: TextStyle(color: _c.warn, fontSize: 10),
                  ),
                ),
            ],
          ),
        ),
      ),
      for (final node in root.children)
        Padding(
          padding: const EdgeInsets.only(left: 28, right: 10),
          child: SizedBox(
            height: 24,
            child: Row(
              children: [
                Icon(
                  node.isDir ? Icons.chevron_right : Icons.insert_drive_file,
                  size: node.isDir ? 14 : 12,
                  color: _c.text4,
                ),
                const SizedBox(width: 6),
                Text(
                  node.name,
                  style: TextStyle(color: node.git ?? _c.text2, fontSize: 12.5),
                ),
              ],
            ),
          ),
        ),
      const SizedBox(height: 4),
    ];
  }

  Widget _branchBadge(String branch) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.call_split, size: 11, color: _c.warn),
        const SizedBox(width: 3),
        Text(branch, style: TextStyle(color: _c.warn, fontSize: 10.5)),
      ],
    );
  }
}

/// Source Control multi-root: **agregado, seccionado por root**. Só roots
/// sujas aparecem (limpa = sem seção). Cada seção tem o cabeçalho da root
/// (nome + branch + contagem) e dentro dele a MESMA visualização da main:
/// lista compacta ou hierarquia de pastas, conforme o toggle do header.
/// Single-root = uma seção só → o cabeçalho é omitido = tela de hoje.
class _SourceControlView extends StatelessWidget {
  const _SourceControlView({required this.asTree});
  final bool asTree;

  @override
  Widget build(BuildContext context) {
    final dirty = _roots.where((r) => r.dirty > 0).toList();
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 6),
      children: [
        for (final root in dirty) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 6, 4, 4),
            child: Row(
              children: [
                Icon(Icons.expand_more, size: 14, color: _c.text3),
                const SizedBox(width: 4),
                Text(
                  root.name,
                  style: TextStyle(
                    color: _c.text,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(width: 8),
                Icon(Icons.call_split, size: 11, color: _c.warn),
                const SizedBox(width: 3),
                Text(
                  root.branch,
                  style: TextStyle(color: _c.warn, fontSize: 10.5),
                ),
                const Spacer(),
                Text(
                  '${root.dirty}',
                  style: TextStyle(color: _c.text3, fontSize: 10.5),
                ),
              ],
            ),
          ),
          if (asTree) ..._treeRows(root) else ..._listRows(root),
          const SizedBox(height: 6),
        ],
      ],
    );
  }

  /// Modo lista compacta: arquivo + caminho relativo à ROOT (não ao workspace).
  List<Widget> _listRows(_MockRoot root) {
    return [
      for (final f in root.children.where((n) => n.git != null))
        Padding(
          padding: const EdgeInsets.only(left: 22, right: 6),
          child: SizedBox(
            height: 24,
            child: Row(
              children: [
                Icon(Icons.insert_drive_file, size: 12, color: _c.text4),
                const SizedBox(width: 6),
                Text(f.name, style: TextStyle(color: f.git, fontSize: 12.5)),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'src',
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: _c.text4, fontSize: 10.5),
                  ),
                ),
                Text(
                  f.git == const Color(0xFF4F9DF0) ? 'U' : 'M',
                  style: TextStyle(color: f.git, fontSize: 10.5),
                ),
              ],
            ),
          ),
        ),
    ];
  }

  /// Modo hierarquia (da main): pastas expansíveis dentro da seção da root.
  List<Widget> _treeRows(_MockRoot root) {
    return [
      Padding(
        padding: const EdgeInsets.only(left: 22, right: 6),
        child: SizedBox(
          height: 24,
          child: Row(
            children: [
              Icon(Icons.keyboard_arrow_down, size: 14, color: _c.text3),
              Icon(Icons.folder_open_outlined, size: 14, color: _c.text3),
              const SizedBox(width: 6),
              Text('src', style: TextStyle(color: _c.text2, fontSize: 12.5)),
            ],
          ),
        ),
      ),
      for (final f in root.children.where((n) => n.git != null))
        Padding(
          padding: const EdgeInsets.only(left: 42, right: 6),
          child: SizedBox(
            height: 24,
            child: Row(
              children: [
                Icon(Icons.insert_drive_file, size: 12, color: _c.text4),
                const SizedBox(width: 6),
                Text(f.name, style: TextStyle(color: f.git, fontSize: 12.5)),
              ],
            ),
          ),
        ),
    ];
  }
}

/// "+" do header da árvore: em multi-root, abrir terminal/agente exige alvo.
class _NewTabRootButton extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<String>(
      tooltip: 'Nova aba em…',
      color: _c.panel2,
      icon: Icon(Icons.add, size: 16, color: _c.text4),
      itemBuilder: (_) => [
        for (final r in _roots)
          PopupMenuItem(
            value: r.name,
            height: 32,
            child: Row(
              children: [
                Icon(Icons.folder, size: 13, color: _c.text3),
                const SizedBox(width: 8),
                Text(r.name, style: TextStyle(color: _c.text, fontSize: 12.5)),
                const Spacer(),
                Text(
                  r.branch,
                  style: TextStyle(color: _c.text3, fontSize: 10.5),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Menu de contexto da root + dialogs mock
// ---------------------------------------------------------------------------

/// Menu kebab do workspace (⋮). No single-root é o menu de hoje, intacto —
/// a ação executa direto (N=1 resolve sozinho). No multi-root, as operações
/// git têm seta `▸`: clicar abre o **passo 2** (escolher a root alvo);
/// só então a ação executa. Copy id / Settings / Close são do workspace.
void _showWorkspaceMenu(BuildContext context, String name, bool multiRoot) {
  showDialog<void>(
    context: context,
    builder: (dialogCtx) => SimpleDialog(
      backgroundColor: _c.panel2,
      title: Text(
        multiRoot ? '$name  (multi-root)' : name,
        style: TextStyle(color: _c.text, fontSize: 13),
      ),
      children: [
        for (final (icon, label) in [
          (Icons.sync, 'Sync'),
          (Icons.arrow_downward, 'Pull'),
          (Icons.arrow_upward, 'Push'),
          (Icons.call_split, 'Create worktree'),
        ])
          multiRoot
              ? _menuItemIcon(
                  icon,
                  label,
                  hasSubmenu: true,
                  onTap: () {
                    Navigator.of(dialogCtx).pop();
                    _showRootPicker(context, label);
                  },
                )
              : _menuItemIcon(icon, label),
        _divider(),
        _menuItemIcon(Icons.copy, 'Copy workspace id'),
        _menuItemIcon(Icons.settings, 'Settings'),
        _divider(),
        _menuItemIcon(Icons.close, 'Close', color: _c.error),
      ],
    ),
  );
}

/// Passo 2 do multi-root: "Pull ▸" abriu — em qual root? (No app real isso é
/// um submenu que desliza do item; aqui, um popup separado pra visualizar.)
void _showRootPicker(BuildContext context, String action) {
  showDialog<void>(
    context: context,
    builder: (dialogCtx) => SimpleDialog(
      backgroundColor: _c.panel2,
      title: Text(
        '$action — em qual root?',
        style: TextStyle(color: _c.text, fontSize: 13),
      ),
      children: [
        for (final r in _roots)
          SimpleDialogOption(
            onPressed: () => Navigator.of(dialogCtx).pop(),
            child: Row(
              children: [
                Icon(Icons.folder, size: 13, color: _c.text3),
                const SizedBox(width: 8),
                Text(r.name, style: TextStyle(color: _c.text, fontSize: 12.5)),
                const SizedBox(width: 10),
                Icon(Icons.call_split, size: 11, color: _c.warn),
                const SizedBox(width: 3),
                Text(
                  r.branch,
                  style: TextStyle(color: _c.warn, fontSize: 10.5),
                ),
                if (r.dirty > 0) ...[
                  const Spacer(),
                  Text(
                    '●${r.dirty}',
                    style: TextStyle(color: _c.warn, fontSize: 10.5),
                  ),
                ],
              ],
            ),
          ),
      ],
    ),
  );
}

Widget _divider() => Padding(
  padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 12),
  child: Container(height: 1, color: _c.border),
);

Widget _menuItemIcon(
  IconData icon,
  String label, {
  bool hasSubmenu = false,
  Color? color,
  VoidCallback? onTap,
}) {
  return SimpleDialogOption(
    onPressed: onTap,
    child: Row(
      children: [
        Icon(icon, size: 14, color: color ?? _c.text3),
        const SizedBox(width: 10),
        Text(label, style: TextStyle(color: color ?? _c.text, fontSize: 12.5)),
        if (hasSubmenu) ...[
          const Spacer(),
          Icon(Icons.chevron_right, size: 14, color: _c.text4),
        ],
      ],
    ),
  );
}

void _showRootContextMenu(BuildContext context, _MockRoot root) {
  showDialog<void>(
    context: context,
    builder: (_) => SimpleDialog(
      backgroundColor: _c.panel2,
      title: Row(
        children: [
          Text(root.name, style: TextStyle(color: _c.text, fontSize: 13)),
          const SizedBox(width: 10),
          Icon(Icons.call_split, size: 12, color: _c.warn),
          const SizedBox(width: 3),
          Text(root.branch, style: TextStyle(color: _c.warn, fontSize: 11)),
        ],
      ),
      children: [
        // Git direto, SEM perguntar root: o alvo é o cabeçalho clicado.
        _menuItemIcon(Icons.sync, 'Sync'),
        _menuItemIcon(Icons.arrow_downward, 'Pull'),
        _menuItemIcon(Icons.arrow_upward, 'Push'),
        _menuItemIcon(Icons.call_split, 'Create worktree'),
        _divider(),
        _menuItemIcon(Icons.terminal, 'New terminal here'),
        _menuItemIcon(Icons.smart_toy_outlined, 'New agent here'),
        _menuItemIcon(Icons.folder_open, 'Reveal in Finder'),
      ],
    ),
  );
}

/// Porta 2 — detecção na criação: pasta-mãe sem `.git` com N repos dentro.
void _showDetectionDialog(BuildContext context) {
  showDialog<void>(
    context: context,
    builder: (_) => _MockDialog(
      title: '"projeto-x" contém 5 repositórios git',
      subtitle: 'Adicionar como workspace multi-root?',
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _checkRow(true, 'app', 'main'),
          _checkRow(true, 'backend', 'develop'),
          _checkRow(true, 'infra', 'main'),
          _checkRow(true, 'shared-libs', 'main'),
          _checkRow(false, 'playground', 'main'),
          const SizedBox(height: 12),
          _checkRow(true, 'Salvar .cockpit/workspace.json na pasta', null),
        ],
      ),
      actions: const ['Só a pasta, sem roots', 'Criar workspace'],
    ),
  );
}

/// "Manage roots…" — gestão pós-criação (mesma cara da detecção).
void _showManageRootsDialog(BuildContext context) {
  showDialog<void>(
    context: context,
    builder: (_) => _MockDialog(
      title: 'Roots de "Projeto X"',
      subtitle: 'Remover uma root não deleta a pasta.',
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final r in _roots) _manageRow(r.name, r.branch),
          const SizedBox(height: 6),
          Row(
            children: [
              Icon(Icons.add, size: 14, color: _c.accentText),
              const SizedBox(width: 6),
              Text(
                'Add root…',
                style: TextStyle(color: _c.accentText, fontSize: 12.5),
              ),
            ],
          ),
          const SizedBox(height: 12),
          _checkRow(true, 'Sincronizar com .cockpit/workspace.json', null),
        ],
      ),
      actions: const ['Cancelar', 'Salvar'],
    ),
  );
}

Widget _checkRow(bool checked, String label, String? branch) {
  return Padding(
    padding: const EdgeInsets.symmetric(vertical: 3),
    child: Row(
      children: [
        Icon(
          checked ? Icons.check_box : Icons.check_box_outline_blank,
          size: 16,
          color: checked ? _c.accent : _c.text4,
        ),
        const SizedBox(width: 8),
        Text(label, style: TextStyle(color: _c.text, fontSize: 12.5)),
        if (branch != null) ...[
          const SizedBox(width: 10),
          Icon(Icons.call_split, size: 11, color: _c.warn),
          const SizedBox(width: 3),
          Text(branch, style: TextStyle(color: _c.warn, fontSize: 10.5)),
        ],
      ],
    ),
  );
}

Widget _manageRow(String name, String branch) {
  return Padding(
    padding: const EdgeInsets.symmetric(vertical: 3),
    child: Row(
      children: [
        Icon(Icons.folder, size: 14, color: _c.text3),
        const SizedBox(width: 8),
        Text(name, style: TextStyle(color: _c.text, fontSize: 12.5)),
        const SizedBox(width: 10),
        Icon(Icons.call_split, size: 11, color: _c.warn),
        const SizedBox(width: 3),
        Text(branch, style: TextStyle(color: _c.warn, fontSize: 10.5)),
        const Spacer(),
        Icon(Icons.remove_circle_outline, size: 14, color: _c.error),
      ],
    ),
  );
}

class _MockDialog extends StatelessWidget {
  const _MockDialog({
    required this.title,
    required this.subtitle,
    required this.body,
    required this.actions,
  });

  final String title;
  final String subtitle;
  final Widget body;
  final List<String> actions;

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: _c.panel2,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(color: _c.border2),
      ),
      child: Container(
        width: 420,
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: TextStyle(
                color: _c.text,
                fontSize: 14,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 4),
            Text(subtitle, style: TextStyle(color: _c.text3, fontSize: 12)),
            const SizedBox(height: 16),
            body,
            const SizedBox(height: 20),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                for (var i = 0; i < actions.length; i++) ...[
                  if (i > 0) const SizedBox(width: 8),
                  i == actions.length - 1
                      ? FilledButton(
                          style: FilledButton.styleFrom(
                            backgroundColor: _c.accent,
                            textStyle: const TextStyle(fontSize: 12),
                          ),
                          onPressed: () => Navigator.of(context).pop(),
                          child: Text(actions[i]),
                        )
                      : TextButton(
                          style: TextButton.styleFrom(
                            foregroundColor: _c.text2,
                            textStyle: const TextStyle(fontSize: 12),
                          ),
                          onPressed: () => Navigator.of(context).pop(),
                          child: Text(actions[i]),
                        ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}
