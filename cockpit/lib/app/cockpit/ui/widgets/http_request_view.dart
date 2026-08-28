import 'package:cockpit/app/cockpit/domain/entities/file_view.dart';
import 'package:cockpit/app/cockpit/domain/entities/http_document.dart';
import 'package:cockpit/app/cockpit/domain/entities/http_response_result.dart';
import 'package:cockpit/app/cockpit/domain/exceptions/http_request_error.dart';
import 'package:cockpit/app/cockpit/ui/session/file_viewer_session.dart';
import 'package:cockpit/app/cockpit/ui/viewmodels/cockpit_viewmodel.dart';
import 'package:cockpit/app/cockpit/ui/viewmodels/http_viewmodel.dart';
import 'package:cockpit/app/cockpit/ui/widgets/code_editor.dart';
import 'package:cockpit/app/core/domain/result.dart';
import 'package:cockpit/app/core/ui/file_operation_error_message.dart';
import 'package:cockpit/app/core/ui/http_request_error_message.dart';
import 'package:cockpit/app/core/ui/menu/editor_menu_bridge.dart';
import 'package:cockpit/app/core/ui/themes/themes.dart';
import 'package:cockpit/app/core/ui/widgets/app_menu.dart';
import 'package:cockpit/app/core/ui/widgets/code_editing_controller.dart';
import 'package:cockpit/app/core/ui/widgets/code_highlight.dart';
import 'package:cockpit/app/core/ui/widgets/hover_tap.dart';
import 'package:cockpit/i18n/strings.g.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_modular/flutter_modular.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';

/// Tab de um arquivo `.http`: editor em cima, resposta embaixo, split
/// arrastável — a mesma anatomia da tab `.dbq`, e pelo mesmo motivo reusa a
/// [FileViewerSession] (preview/dirty/watch/persistência de graça); só o
/// render diverge.
///
/// O arquivo **é** a fonte de verdade: nada de estado escondido em
/// frontmatter, ao contrário do `.dbq`. O request executado é o que estiver
/// sob o cursor (ou o escolhido no seletor da top bar).
class HttpRequestView extends StatefulWidget {
  const HttpRequestView({
    super.key,
    required this.session,
    required this.active,
    required this.focused,
    required this.onSave,
  });

  final FileViewerSession session;
  final bool active;
  final bool focused;

  /// Grava o conteúdo do editor no disco.
  final Future<bool> Function(String content) onSave;

  @override
  State<HttpRequestView> createState() => _HttpRequestViewState();
}

class _HttpRequestViewState extends State<HttpRequestView> {
  late final CodeEditingController _text;
  final FocusNode _focus = FocusNode();
  EditorMenuBridge? _menuBridge;

  /// Conteúdo do disco como o conhecemos (baseline de dirty/discard).
  late String _baseline;
  bool _running = false;

  /// Estado de view (resposta, split, aba) — mora no [HttpViewModel] para
  /// sobreviver ao re-mount quando a tab muda de pane.
  late final HttpTabState _view;

  @override
  void initState() {
    super.initState();
    _view = context.read<HttpViewModel>().tabStateFor(widget.session.id);
    _baseline = _diskText();
    _text = CodeEditingController(text: _baseline, language: 'http');
    _text.addListener(_onEdited);
    widget.session.addListener(_onSession);
    widget.session.saveDraft = _save;
    if (widget.session.scratch) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) widget.session.setDirty(true);
      });
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _menuBridge = context.read<EditorMenuBridge>();
  }

  @override
  void dispose() {
    _menuBridge?.clear(this);
    widget.session.removeListener(_onSession);
    if (widget.session.saveDraft == _save) widget.session.saveDraft = null;
    _text.removeListener(_onEdited);
    _text.dispose();
    _focus.dispose();
    super.dispose();
  }

  String _diskText() => switch (widget.session.view) {
    FileViewText(:final text) => text,
    FileViewMarkdown(:final text) => text,
    _ => '',
  };

  HttpDocument get _doc => HttpDocument.parse(_text.text);

  bool get _dirty => widget.session.scratch || _text.text != _baseline;

  void _onEdited() {
    // Editar pode mudar quantos requests existem — o seletor da top bar
    // acompanha, então repinta.
    if (mounted) setState(() {});
    widget.session.setDirty(_dirty);
  }

  /// Mudança vinda do disco (watcher / agente salvou): adota o conteúdo novo
  /// se o buffer local não está sujo. **Não** re-executa sozinho, ao contrário
  /// do `.dbq`: request tem efeito colateral no servidor: quem dispara é o
  /// humano.
  void _onSession() {
    if (widget.session.scratch) return;
    final text = _diskText();
    if (text == _baseline || widget.session.dirty) return;
    setState(() {
      _baseline = text;
      if (_text.text != text) _text.text = text;
    });
  }

  Future<bool> _save() async {
    if (!_dirty) return true;
    final content = _text.text;
    if (widget.session.scratch) {
      final name = await _promptName();
      if (name == null || !mounted) return false;
      final result = await context.read<CockpitViewModel>().saveScratchAs(
        widget.session.id,
        name,
        content,
      );
      if (!mounted) return false;
      final error = result.fold((_) => null, (f) => f);
      if (error != null) {
        _showError(
          context.t.cockpit.httpView.couldNotSave,
          fileOperationErrorMessage(context, error),
        );
        return false;
      }
      setState(() => _baseline = content);
      widget.session.setDirty(_dirty);
      return true;
    }
    final ok = await widget.onSave(content);
    if (!mounted) return ok;
    if (ok) {
      setState(() => _baseline = content);
      widget.session.setDirty(_dirty);
    }
    return ok;
  }

  Future<String?> _promptName() {
    final ctrl = TextEditingController(text: 'requests.http');
    return showDialog<String>(
      context: context,
      builder: (context) {
        final colors = context.colors;
        return AlertDialog(
          title: Text(
            context.t.cockpit.httpView.saveRequestAs,
            style: context.typo.title.copyWith(
              fontSize: 15,
              color: colors.text,
            ),
          ),
          content: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 360),
            child: TextField(
              controller: ctrl,
              autofocus: true,
              style: context.typo.mono.copyWith(
                fontSize: 12.5,
                color: colors.text,
              ),
              border: Border.all(color: colors.border),
              borderRadius: BorderRadius.circular(6),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
              onSubmitted: (v) => Navigator.of(context).pop(v),
            ),
          ),
          actions: [
            GhostButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text(context.t.common.cancel),
            ),
            PrimaryButton(
              onPressed: () => Navigator.of(context).pop(ctrl.text),
              child: Text(context.t.common.save),
            ),
          ],
        );
      },
    );
  }

  void _showError(String title, String message) {
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          title,
          style: context.typo.title.copyWith(
            fontSize: 15,
            color: context.colors.text,
          ),
        ),
        content: Text(
          message,
          style: context.typo.body.copyWith(
            fontSize: 13,
            color: context.colors.text2,
          ),
        ),
        actions: [
          PrimaryButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(context.t.common.ok),
          ),
        ],
      ),
    );
  }

  void _discard() {
    setState(() => _text.text = _baseline);
    widget.session.setDirty(_dirty);
  }

  /// Linha (base 0) onde está o cursor — casa com o request corrente.
  int get _cursorLine {
    final sel = _text.selection;
    final offset = sel.isValid ? sel.baseOffset : 0;
    final upto = _text.text.substring(0, offset.clamp(0, _text.text.length));
    return '\n'.allMatches(upto).length;
  }

  /// Índice do request a executar: o escolhido explicitamente no seletor, ou
  /// o que estiver sob o cursor.
  int _targetIndex(HttpDocument doc) {
    if (_view.selected < doc.requests.length && _view.selected > 0) {
      return _view.selected;
    }
    final at = doc.requestIndexAtLine(_cursorLine);
    return at < 0 ? 0 : at;
  }

  Future<void> _run() async {
    if (_running) return;
    final doc = _doc;
    if (doc.requests.isEmpty) {
      setState(() {
        _view.result = null;
        _view.error = const HttpRequestError(HttpRequestErrorKind.noRequest);
      });
      return;
    }
    // Arquivo real: Run salva antes (o arquivo é o que o agente e a CLI leem).
    if (!widget.session.scratch && _dirty) {
      if (!await _save() || !mounted) return;
    }

    final index = _targetIndex(doc);
    final spec = doc.resolveRequest(doc.requests[index]);
    final baseDir = widget.session.scratch
        ? ''
        : widget.session.workingDirectory;

    setState(() {
      _running = true;
      _view.error = null;
      _view.selected = index;
    });
    final result = await context.read<HttpViewModel>().runner.send(
      spec,
      baseDir: baseDir,
    );
    if (!mounted) return;
    setState(() {
      _running = false;
      switch (result) {
        case Success(:final value):
          _view.result = value;
          _view.error = null;
        case Failure(:final error):
          _view.error = error;
      }
    });
  }

  Future<void> _pickRequest(BuildContext anchor) async {
    final doc = _doc;
    final picked = await showAppMenu<int>(
      anchor,
      items: [
        for (var i = 0; i < doc.requests.length; i++)
          AppMenuItem(
            value: i,
            label: doc.requests[i].label,
            selected: i == _targetIndex(doc),
          ),
        if (doc.requests.isEmpty)
          AppMenuItem(
            value: -1,
            label: context.t.cockpit.httpView.noRequests,
            enabled: false,
          ),
      ],
    );
    if (picked == null || picked < 0 || !mounted) return;
    setState(() => _view.selected = picked);
    await _run();
  }

  void _syncMenuBridge() {
    final bridge = _menuBridge;
    if (bridge == null) return;
    if (widget.focused) {
      bridge.publish(
        owner: this,
        canSave: _dirty,
        canDiscard: _dirty,
        canFormat: false,
        onSave: _save,
        onDiscard: _discard,
        onFormat: () {},
      );
    } else {
      bridge.clear(this);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _syncMenuBridge();
    });
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyS, meta: true): _save,
        const SingleActivator(LogicalKeyboardKey.keyS, control: true): _save,
        const SingleActivator(LogicalKeyboardKey.enter, meta: true): _run,
        const SingleActivator(LogicalKeyboardKey.enter, control: true): _run,
      },
      child: ColoredBox(
        color: colors.panel,
        child: Column(
          children: [
            _topBar(context),
            Expanded(
              child: LayoutBuilder(
                builder: (context, box) {
                  final editorH = (box.maxHeight * _view.split).clamp(
                    90.0,
                    box.maxHeight - 110,
                  );
                  return Column(
                    children: [
                      SizedBox(
                        height: editorH,
                        child: CodeEditor(controller: _text, focusNode: _focus),
                      ),
                      MouseRegion(
                        cursor: SystemMouseCursors.resizeUpDown,
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onVerticalDragUpdate: (d) => setState(() {
                            _view.split =
                                ((editorH + d.delta.dy) / box.maxHeight).clamp(
                                  0.12,
                                  0.85,
                                );
                          }),
                          child: SizedBox(
                            height: 7,
                            child: Center(
                              child: Container(
                                height: 1,
                                color: colors.border2,
                              ),
                            ),
                          ),
                        ),
                      ),
                      Expanded(child: _responseArea(context)),
                    ],
                  );
                },
              ),
            ),
            _footer(context),
          ],
        ),
      ),
    );
  }

  Widget _topBar(BuildContext context) {
    final colors = context.colors;
    final typo = context.typo;
    final tr = context.t.cockpit.httpView;
    final doc = _doc;
    final empty = doc.requests.isEmpty;
    final runBg = empty ? colors.panel3 : colors.accent;
    final runFg = onColor(runBg);
    final target = empty ? null : doc.requests[_targetIndex(doc)];
    return Container(
      height: 36,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: colors.border)),
      ),
      child: Row(
        children: [
          Icon(Icons.swap_horiz, size: 14, color: colors.accent),
          const SizedBox(width: 8),
          Expanded(
            child: Builder(
              builder: (anchor) => Align(
                alignment: Alignment.centerLeft,
                child: HoverTap(
                  onTap: empty ? null : () => _pickRequest(anchor),
                  color: colors.panel3,
                  borderRadius: const BorderRadius.all(Radius.circular(4)),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 7,
                    vertical: 3,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (target != null) ...[
                        Text(
                          target.method,
                          style: typo.label.copyWith(
                            fontSize: 11,
                            color: colors.accent,
                          ),
                        ),
                        const SizedBox(width: 6),
                      ],
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 420),
                        child: Text(
                          target?.label ?? tr.selectRequest,
                          overflow: TextOverflow.ellipsis,
                          style: typo.label.copyWith(
                            fontSize: 11,
                            color: empty ? colors.warn : colors.text2,
                          ),
                        ),
                      ),
                      const SizedBox(width: 4),
                      Icon(
                        Icons.keyboard_arrow_down,
                        size: 12,
                        color: colors.text3,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          HoverTap(
            onTap: _running || empty ? null : _run,
            color: runBg,
            hoverColor: colors.accent.withValues(alpha: 0.85),
            borderRadius: const BorderRadius.all(Radius.circular(5)),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  _running ? Icons.hourglass_top : Icons.play_arrow,
                  size: 13,
                  color: runFg,
                ),
                const SizedBox(width: 4),
                Text(
                  _running ? tr.running : tr.run,
                  style: typo.label.copyWith(fontSize: 11.5, color: runFg),
                ),
                const SizedBox(width: 6),
                Text(
                  '⌘↵',
                  style: typo.label.copyWith(
                    fontSize: 9.5,
                    color: runFg.withValues(alpha: 0.7),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _responseArea(BuildContext context) {
    final colors = context.colors;
    final typo = context.typo;
    final tr = context.t.cockpit.httpView;

    final error = _view.error;
    if (error != null) {
      return Container(
        alignment: Alignment.topLeft,
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.error_outline, size: 14, color: colors.error),
                const SizedBox(width: 6),
                Text(
                  tr.error.title,
                  style: typo.label.copyWith(
                    fontSize: 11.5,
                    color: colors.error,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            SelectableText(
              httpRequestErrorMessage(context, error),
              style: typo.mono.copyWith(fontSize: 12, color: colors.text2),
            ),
          ],
        ),
      );
    }

    final result = _view.result;
    if (result == null) {
      return Center(
        child: Text(
          tr.runHint,
          style: typo.label.copyWith(fontSize: 12, color: colors.text3),
        ),
      );
    }

    final text = _paneText(result);
    if (text.isEmpty) {
      return Center(
        child: Text(
          tr.emptyBody,
          style: typo.label.copyWith(fontSize: 12, color: colors.text3),
        ),
      );
    }

    final baseStyle = typo.mono.copyWith(fontSize: 12, color: colors.text2);
    // Realce da resposta: JSON no Body (quando parseia), gramática do `.http`
    // nos Headers (`Nome: valor`). Raw fica cru de propósito — é o modo "me
    // mostra exatamente o que veio". `buildCodeSpan` devolve null quando não
    // há o que pintar; aí cai no texto simples.
    final language = switch (_view.pane) {
      HttpResponsePane.body => result.prettyJson != null ? 'json' : null,
      HttpResponsePane.headers => 'http',
      HttpResponsePane.raw => null,
    };
    final span = language == null
        ? null
        : buildCodeSpan(
            context,
            source: text,
            language: language,
            baseStyle: baseStyle,
          );

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
      // O viewport dá ao filho a largura da pane, mas sem isto o texto de uma
      // linha só encolhe e o `SingleChildScrollView` o centraliza — era o que
      // deixava a resposta boiando no meio. Largura cheia + alinhamento
      // explícito prendem tudo à esquerda.
      child: SizedBox(
        width: double.infinity,
        child: span == null
            ? SelectableText(text, textAlign: TextAlign.start, style: baseStyle)
            : SelectableText.rich(span, textAlign: TextAlign.start),
      ),
    );
  }

  /// Texto da aba corrente (Body/Headers/Raw) — mesma fonte para o render e
  /// para o Copy, para nunca copiarem coisas diferentes.
  String _paneText(HttpResponseResult result) => switch (_view.pane) {
    HttpResponsePane.headers => [
      for (final h in result.headers) '${h.name}: ${h.value}',
    ].join('\n'),
    HttpResponsePane.raw => result.bodyText,
    HttpResponsePane.body => result.prettyJson ?? result.bodyText,
  };

  Widget _footer(BuildContext context) {
    final colors = context.colors;
    final typo = context.typo;
    final tr = context.t.cockpit.httpView;
    final result = _view.result;
    final info = StringBuffer();
    if (result != null) {
      info.write('${result.statusCode} ${result.reasonPhrase}'.trim());
      info.write(' · ${result.elapsed.inMilliseconds} ms');
      info.write(' · ${_humanBytes(result.sizeBytes)}');
      if (result.truncated) info.write(tr.truncatedSuffix);
    }
    return Container(
      height: 26,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: colors.border)),
      ),
      child: Row(
        children: [
          if (result != null) ...[
            Container(
              width: 7,
              height: 7,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: _statusColor(context, result.statusCode),
              ),
            ),
            const SizedBox(width: 6),
          ],
          Text(
            info.toString(),
            style: typo.label.copyWith(fontSize: 10.5, color: colors.text3),
          ),
          const Spacer(),
          // Seletor da view da resposta — mesmo lugar e mesmo estilo do
          // toggle Table/JSON da tab `.dbq`.
          if (result != null) ...[
            _PaneToggle(
              label: tr.body,
              active: _view.pane == HttpResponsePane.body,
              onTap: () => setState(() => _view.pane = HttpResponsePane.body),
            ),
            _PaneToggle(
              label: tr.headers,
              active: _view.pane == HttpResponsePane.headers,
              onTap: () =>
                  setState(() => _view.pane = HttpResponsePane.headers),
            ),
            _PaneToggle(
              label: tr.raw,
              active: _view.pane == HttpResponsePane.raw,
              onTap: () => setState(() => _view.pane = HttpResponsePane.raw),
            ),
          ],
        ],
      ),
    );
  }

  Color _statusColor(BuildContext context, int status) {
    final colors = context.colors;
    if (status >= 500) return colors.error;
    if (status >= 400) return colors.warn;
    if (status >= 200 && status < 300) return colors.ok;
    return colors.text3;
  }

  static String _humanBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)} kB';
    }
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}

/// Botão compacto do seletor Body/Headers/Raw no rodapé.
class _PaneToggle extends StatelessWidget {
  const _PaneToggle({
    required this.label,
    required this.active,
    required this.onTap,
  });

  final String label;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return HoverTap(
      onTap: onTap,
      color: active ? colors.panel3 : null,
      borderRadius: const BorderRadius.all(Radius.circular(4)),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      child: Text(
        label,
        style: context.typo.label.copyWith(
          fontSize: 10.5,
          color: active ? colors.text : colors.text4,
        ),
      ),
    );
  }
}
