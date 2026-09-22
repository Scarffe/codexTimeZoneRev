import Cocoa
import FlutterMacOS
import macos_window_utils

class MainFlutterWindow: NSWindow {
  private var networkBridge: SystemNetworkBridge?
  override func awakeFromNib() {
    let windowFrame = self.frame
    let materialController = MacOSWindowUtilsViewController()
    self.contentViewController = materialController
    self.setFrame(windowFrame, display: true)
    MainFlutterWindowManipulator.start(mainFlutterWindow: self)
    let flutterViewController = materialController.flutterViewController

    RegisterGeneratedPlugins(registry: flutterViewController)
    networkBridge = SystemNetworkBridge(messenger: flutterViewController.engine.binaryMessenger)

    super.awakeFromNib()
  }
}

// Keep URLSession's default system proxy/PAC configuration. Dart's socket HTTP
// client does not automatically use those settings on macOS.
private class SystemNetworkBridge {
  private let channel: FlutterMethodChannel
  private let session: URLSession
  private var tasks: [Int: URLSessionDataTask] = [:]

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "codex_timezone/network", binaryMessenger: messenger)
    let config = URLSessionConfiguration.ephemeral
    config.requestCachePolicy = .reloadIgnoringLocalCacheData
    config.httpShouldSetCookies = false
    config.timeoutIntervalForRequest = 9
    config.timeoutIntervalForResource = 9
    session = URLSession(configuration: config)
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { return }
      guard let args = call.arguments as? [String: Any], let id = args["id"] as? Int else {
        result(FlutterError(code: "invalid_request", message: "无效网络请求", details: nil))
        return
      }
      if call.method == "cancel" {
        self.tasks[id]?.cancel()
        result(nil)
        return
      }
      guard call.method == "get" else { result(FlutterMethodNotImplemented); return }
      guard let raw = args["url"] as? String, let url = URL(string: raw),
            ["http", "https"].contains(url.scheme ?? ""), url.host != nil,
            url.user == nil, url.password == nil, self.tasks[id] == nil else {
        result(FlutterError(code: "invalid_url", message: "无效 HTTP(S) 请求", details: nil))
        return
      }
      var request = URLRequest(url: url)
      request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
      let task = self.session.dataTask(with: request) { [weak self] data, response, error in
        DispatchQueue.main.async {
          guard let self = self else { return }
          self.tasks.removeValue(forKey: id)
          if let error = error {
            result(FlutterError(code: "network_error", message: error.localizedDescription, details: nil))
          } else if let response = response as? HTTPURLResponse, response.statusCode != 200 {
            result(FlutterError(code: "http_error", message: "HTTP \(response.statusCode)", details: nil))
          } else if let data = data, data.count <= 1024 * 1024,
                    let text = String(data: data, encoding: .utf8) {
            result(text)
          } else {
            result(FlutterError(code: "invalid_response", message: "网络响应过大或编码无效", details: nil))
          }
        }
      }
      self.tasks[id] = task
      task.resume()
    }
  }

  deinit {
    channel.setMethodCallHandler(nil)
    session.invalidateAndCancel()
  }
}
