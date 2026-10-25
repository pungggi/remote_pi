import Cocoa
import FlutterMacOS
import desktop_multi_window

/// Lado nativo das **janelas de documento** (ver `DocumentWindows` no Dart).
///
/// `desktop_multi_window` cria a `NSWindow` e o engine, mas não registra os
/// plugins nem sabe de título: aqui registramos os plugins gerados em cada
/// janela nova (senão `media_kit`, `flutter_inappwebview` etc. não existem lá)
/// e um canal mínimo pra janela definir o próprio título (nome do arquivo).
enum DocumentWindowChannel {
  static func register(_ controller: FlutterViewController) {
    let channel = FlutterMethodChannel(
      name: "cockpit/document_window",
      binaryMessenger: controller.engine.binaryMessenger
    )
    channel.setMethodCallHandler { [weak controller] call, result in
      guard call.method == "present",
        let args = call.arguments as? [String: Any],
        let title = args["title"] as? String
      else {
        result(FlutterMethodNotImplemented)
        return
      }
      let width = args["width"] as? Double ?? 960
      let height = args["height"] as? Double ?? 720
      // A NSWindow pode ainda não estar ligada à view no instante do register;
      // no main queue do próximo turno ela está. O plugin cria a janela com
      // contentRect 800x600, mas a view chegava com 0x0 na tela (o
      // window_manager registrado no engine da janela mexe no tamanho ao
      // subir) — então o tamanho é imposto aqui, junto do título.
      DispatchQueue.main.async {
        guard let window = controller?.view.window else { return }
        window.title = title
        window.setContentSize(NSSize(width: width, height: height))
        window.minSize = NSSize(width: 480, height: 360)
        window.center()
        window.makeKeyAndOrderFront(nil)
      }
      result(nil)
    }
  }
}

/// Arquivos abertos **pelo sistema** (duplo clique no Finder, "Abrir com",
/// `open -a Cockpit x.kanban`): o AppDelegate recebe `openFiles` e repassa ao
/// Dart, que abre cada um numa janela de documento. Antes de o Dart estar
/// pronto (launch a frio por duplo clique), os caminhos ficam em buffer e o
/// Dart os puxa com `pull` assim que registra o handler.
final class OpenFilesChannel {
  static let shared = OpenFilesChannel()

  private var channel: FlutterMethodChannel?
  private var pending: [String] = []
  private var dartReady = false

  func register(_ controller: FlutterViewController) {
    let channel = FlutterMethodChannel(
      name: "cockpit/open_files",
      binaryMessenger: controller.engine.binaryMessenger
    )
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { return }
      switch call.method {
      case "pull":
        self.dartReady = true
        let paths = self.pending
        self.pending = []
        result(paths)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    self.channel = channel
  }

  func open(_ paths: [String]) {
    guard dartReady, let channel = channel else {
      pending.append(contentsOf: paths)
      return
    }
    channel.invokeMethod("open", arguments: paths)
  }
}
