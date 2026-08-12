import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    let openPathChannel = FlutterMethodChannel(
      name: "dev.zizai/open_path",
      binaryMessenger: flutterViewController.engine.binaryMessenger)
    openPathChannel.setMethodCallHandler { call, result in
      guard call.method == "openPath" else {
        result(FlutterMethodNotImplemented)
        return
      }
      guard
        let arguments = call.arguments as? [String: Any],
        let path = arguments["path"] as? String
      else {
        result(FlutterError(code: "bad_argument", message: "path 缺失", details: nil))
        return
      }
      let opened = NSWorkspace.shared.open(URL(fileURLWithPath: path, isDirectory: true))
      if opened {
        result(true)
      } else {
        result(FlutterError(code: "open_failed", message: "无法打开目录", details: path))
      }
    }

    super.awakeFromNib()
  }
}
