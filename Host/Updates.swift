import Foundation
import Sparkle

@MainActor final class Updates {
  static let shared = Updates()
  private var controller: SPUStandardUpdaterController?
  var configured: Bool {
    guard let feed = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String,
      let url = URL(string: feed), url.scheme == "https", url.host != nil,
      let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
      Data(base64Encoded: key)?.count == 32
    else { return false }
    return true
  }
  func check() {
    guard configured else { return }
    if controller == nil {
      controller = SPUStandardUpdaterController(
        startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    }
    controller?.checkForUpdates(nil)
  }
}
