@preconcurrency import AVFoundation
import AVKit
import AgentOSCore
import AgentOSRuntime
import AppKit
import UniformTypeIdentifiers

@MainActor final class MediaService: NSObject, NSWindowDelegate {
  let kernel: Kernel
  private var file: AuthorizedFile?
  private var folder = ""
  private var context = RequestContext(.user)
  private var player: AVPlayer?
  private var window: NSWindow?
  private var path = ""
  private var source: MediaResource?
  private var positionObserver: Any?
  init(kernel: Kernel) { self.kernel = kernel }
  func play(_ args: Value, context: RequestContext) async throws -> Value {
    try await kernel.authorize(context, capability: "service", scope: "media.play")
    let file = try await kernel.openAuthorizedFile(args, context: context)
    close()
    self.file = file
    folder = try args.requiredString("folder")
    // A playback instance retains the app identity, while the originating chat may finish.
    let origin = try await kernel.initiator(of: context)
    let instance = "media:" + UUID().uuidString
    try await kernel.bindInstance(instance, principal: origin)
    self.context = RequestContext(origin, instanceID: instance)
    try await kernel.propagate(kernel.labels(for: context), to: self.context)
    let asset = AVURLAsset(url: URL(string: "agentos-media://local/" + UUID().uuidString)!)
    let source = MediaResource(file: file, folder: folder, context: self.context, kernel: kernel)
    self.source = source
    path = try args.requiredString("path")
    asset.resourceLoader.setDelegate(source, queue: .main)
    let player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
    self.player = player
    let view = AVPlayerView()
    view.player = player
    view.controlsStyle = .floating
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 960, height: 600),
      styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false
    )
    window.title = file.filename
    window.contentView = view
    window.delegate = self
    window.isReleasedWhenClosed = false
    self.window = window
    window.center()
    window.makeKeyAndOrderFront(nil)
    if let seconds = args["position"]?.number, seconds >= 0 {
      await player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600))
    }
    positionObserver = player.addPeriodicTimeObserver(
      forInterval: CMTime(seconds: 10, preferredTimescale: 600), queue: .main
    ) { [weak self] time in
      Task { @MainActor in await self?.saveProgress(time.seconds) }
    }
    player.play()
    return [
      "playing": true, "title": .string(file.filename), "bytes": .number(Double(file.length)),
    ]
  }
  private func saveProgress(_ seconds: Double) async {
    try? await kernel.saveMediaProgress(
      folder: folder, path: path, seconds: seconds, context: context)
  }
  func scan(_ args: Value, context: RequestContext) async throws -> Value {
    try await kernel.authorize(context, capability: "service", scope: "media.scan")
    let folder = try args.requiredString("folder")
    let recursive = args["recursive"]?.bool ?? false
    var pending = [args["path"]?.string ?? ""]
    var examined = 0
    var items: [Value] = []
    let music: Set<String> = ["mp3", "m4a", "aac", "wav", "aif", "aiff", "flac", "ogg"]
    let movies: Set<String> = ["mp4", "m4v", "mov", "mkv", "webm", "avi"]
    while let directory = pending.popLast() {
      examined += 1
      guard examined <= 200 else { throw HostError("too_large", "扫描最多 200 个目录，请选择较小的文件夹") }
      let entries =
        try await kernel.listFiles(
          ["folder": .string(folder), "path": .string(directory)], context: context
        ).array ?? []
      for entry in entries where entry["symlink"] != true {
        let name = try entry.requiredString("name")
        let path = directory.isEmpty ? name : directory + "/" + name
        if entry["directory"] == true {
          if recursive && path.split(separator: "/").count < 16 { pending.append(path) }
          continue
        }
        let ext = URL(fileURLWithPath: name).pathExtension.lowercased()
        guard music.contains(ext) || movies.contains(ext) else { continue }
        guard items.count < 1000 else { throw HostError("too_large", "扫描最多 1000 个媒体文件，请选择较小的文件夹") }
        let item = try await kernel.indexMedia(
          folder: folder, path: path,
          title: URL(fileURLWithPath: name).deletingPathExtension().lastPathComponent,
          kind: music.contains(ext) ? "music" : "movie", bytes: entry["bytes"]?.int ?? 0,
          context: context)
        items.append(item.value)
      }
    }
    return ["count": .number(Double(items.count)), "items": .array(items)]
  }
  func metadata(_ args: Value, context: RequestContext) async throws -> Value {
    try await kernel.authorize(context, capability: "service", scope: "media.metadata")
    let file = try await kernel.openAuthorizedFile(args, context: context)
    let source = MediaResource(
      file: file, folder: try args.requiredString("folder"), context: context, kernel: kernel,
      capability: "media.metadata")
    let asset = AVURLAsset(url: URL(string: "agentos-media://local/" + UUID().uuidString)!)
    asset.resourceLoader.setDelegate(source, queue: .main)
    return try await bounded(seconds: 10) {
      defer { withExtendedLifetime(source) {} }
      let duration = try await asset.load(.duration).seconds
      let metadata = try await asset.load(.commonMetadata)
      var result: [String: Value] = [
        "title": .string(file.filename), "bytes": .number(Double(file.length)),
        "duration": duration.isFinite && duration >= 0 ? .number(duration) : .null,
      ]
      for entry in metadata.prefix(100) {
        guard let key = entry.commonKey, key == .commonKeyTitle || key == .commonKeyArtist,
          let value = try await entry.load(.stringValue)
        else { continue }
        result[key == .commonKeyTitle ? "title" : "artist"] = .string(String(value.prefix(2000)))
      }
      try await self.kernel.validateContext(context)
      return .object(result)
    }
  }
  func control(_ name: String, args: Value, context: RequestContext) async throws -> Value {
    try await kernel.authorize(context, capability: "service", scope: name)
    let origin = try await kernel.initiator(of: context)
    guard origin == .user || origin == .service("cli") || origin == self.context.principal else {
      throw HostError("denied", "Player belongs to another application")
    }
    guard let player else { throw HostError("unavailable", "当前没有播放内容") }
    switch name {
    case "media.pause":
      player.pause()
      await saveProgress(player.currentTime().seconds)
    case "media.resume": player.play()
    case "media.seek":
      guard let seconds = args["position"]?.number, seconds.isFinite, seconds >= 0 else {
        throw HostError("invalid_args", "Invalid playback position")
      }
      await player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600))
      await saveProgress(seconds)
    case "media.stop":
      await saveProgress(player.currentTime().seconds)
      close()
    default: break
    }
    let seconds = player.currentTime().seconds
    return ["playing": .bool(player.rate > 0), "position": .number(seconds.isFinite ? seconds : 0)]
  }
  func close() {
    if let player, let positionObserver { player.removeTimeObserver(positionObserver) }
    positionObserver = nil
    player?.pause()
    player = nil
    window?.delegate = nil
    window?.close()
    window = nil
    file = nil
    source = nil
  }
  func windowWillClose(_ notification: Notification) {
    let seconds = player?.currentTime().seconds ?? 0
    let folder = folder
    let path = path
    let context = context
    Task {
      try? await kernel.saveMediaProgress(
        folder: folder, path: path, seconds: seconds, context: context)
    }
    close()
  }
}

@MainActor private final class MediaResource: NSObject, AVAssetResourceLoaderDelegate {
  let file: AuthorizedFile, folder: String, context: RequestContext, kernel: Kernel,
    capability: String
  init(
    file: AuthorizedFile, folder: String, context: RequestContext, kernel: Kernel,
    capability: String = "media.play"
  ) {
    self.file = file
    self.folder = folder
    self.context = context
    self.kernel = kernel
    self.capability = capability
  }
  func resourceLoader(
    _ resourceLoader: AVAssetResourceLoader,
    shouldWaitForLoadingOfRequestedResource request: AVAssetResourceLoadingRequest
  ) -> Bool {
    Task { @MainActor in
      do {
        try await kernel.checkFolder(folder, context: context)
        try await kernel.authorize(context, capability: "service", scope: capability)
        request.contentInformationRequest?.contentLength = file.length
        request.contentInformationRequest?.isByteRangeAccessSupported = true
        request.contentInformationRequest?.contentType =
          UTType(filenameExtension: URL(fileURLWithPath: file.filename).pathExtension)?.identifier
          ?? UTType.data.identifier
        if let data = request.dataRequest {
          var offset = max(data.currentOffset, data.requestedOffset)
          let end =
            data.requestsAllDataToEndOfResource
            ? file.length : min(file.length, data.requestedOffset + Int64(data.requestedLength))
          while offset < end, !request.isCancelled {
            try await kernel.checkFolder(folder, context: context)
            try await kernel.authorize(context, capability: "service", scope: capability)
            let start = offset
            let count = Int(min(1024 * 1024, end - offset))
            let file = file
            let bytes = try await Task.detached { try file.read(offset: start, count: count) }.value
            guard !bytes.isEmpty else {
              throw HostError("io_error", "Media file changed during playback")
            }
            if request.isCancelled { return }
            data.respond(with: bytes)
            offset += Int64(bytes.count)
          }
        }
        if !request.isCancelled { request.finishLoading() }
      } catch { if !request.isCancelled { request.finishLoading(with: error) } }
    }
    return true
  }
}
