import AVFoundation
import CoreImage
import Flutter
import ImageIO
import Network
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "GlimCameraPlugin") {
      GlimCameraPlugin.register(with: registrar)
    }
  }
}

// MARK: - Glim camera streamer
//
// Captures the iPhone camera (+ microphone), shows a live preview in Flutter
// through a texture and streams JPEG frames + PCM audio to the desktop app
// over TCP. When the phone is plugged in with a USB cable the desktop side
// reaches this server through usbmuxd (`iproxy`), so no Wi-Fi is required.
//
// Packet format: [type u8][length u32 BE][payload]  (see lib/protocol.dart)

final class GlimCameraPlugin: NSObject, FlutterPlugin, FlutterTexture,
  AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate
{
  private static let kVideo: UInt8 = 1
  private static let kAudio: UInt8 = 2
  private static let kInfo: UInt8 = 3
  private static let kCommand: UInt8 = 4

  private let channel: FlutterMethodChannel
  private let textures: FlutterTextureRegistry
  private var textureId: Int64 = -1

  private let session = AVCaptureSession()
  private let sessionQueue = DispatchQueue(label: "glim.session")
  private let videoQueue = DispatchQueue(label: "glim.video", qos: .userInteractive)
  private let audioQueue = DispatchQueue(label: "glim.audio", qos: .userInteractive)
  private let encodeQueue = DispatchQueue(label: "glim.encode", qos: .userInteractive)
  private let netQueue = DispatchQueue(label: "glim.net", qos: .userInteractive)

  private var videoInput: AVCaptureDeviceInput?
  private var audioInput: AVCaptureDeviceInput?
  private let videoOutput = AVCaptureVideoDataOutput()
  private let audioOutput = AVCaptureAudioDataOutput()

  private let ciContext = CIContext(options: [.cacheIntermediates: false])
  private let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

  // Shared state guarded by `lock`.
  private let lock = NSLock()
  private var latestPixelBuffer: CVPixelBuffer?
  private var encoding = false
  private var jpegQuality: CGFloat = 0.7
  private var client: NWConnection?
  private var clientReady = false
  private var clientAddress = ""
  private var videoInflight = 0
  private var frameWidth = 0
  private var frameHeight = 0

  // Session settings (sessionQueue).
  private var preset = "1080p"
  private var targetFps = 30
  private var portrait = true
  private var audioEnabled = true
  private var running = false

  private var listener: NWListener?
  private var listening = false
  private var lastError = ""

  // Stats (videoQueue).
  private var statsStart = CACurrentMediaTime()
  private var capturedFrames = 0
  private var sentFrames = 0
  private var captureFps = 0
  private var sendFps = 0

  init(channel: FlutterMethodChannel, textures: FlutterTextureRegistry) {
    self.channel = channel
    self.textures = textures
    super.init()
  }

  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "glim/camera", binaryMessenger: registrar.messenger())
    let instance = GlimCameraPlugin(channel: channel, textures: registrar.textures())
    registrar.addMethodCallDelegate(instance, channel: channel)
  }

  // MARK: Flutter method channel

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    switch call.method {
    case "initialize":
      requestPermissions { granted in
        if self.textureId < 0 {
          self.textureId = self.textures.register(self)
        }
        result([
          "textureId": self.textureId,
          "cameraGranted": granted.0,
          "micGranted": granted.1,
          "cameras": self.cameraList(),
        ])
      }
    case "start":
      let cameraId = args["camera"] as? String
      preset = args["preset"] as? String ?? "1080p"
      targetFps = args["fps"] as? Int ?? 30
      portrait = (args["orientation"] as? String ?? "portrait") == "portrait"
      audioEnabled = args["audio"] as? Bool ?? true
      setQuality(args["quality"] as? Double ?? 0.7)
      let port = UInt16(args["port"] as? Int ?? 8686)
      sessionQueue.async {
        self.configureSession(cameraId: cameraId)
        if !self.session.isRunning { self.session.startRunning() }
        self.running = true
        self.startServer(port: port)
        DispatchQueue.main.async {
          UIApplication.shared.isIdleTimerDisabled = true
          result(nil)
        }
      }
    case "stop":
      sessionQueue.async {
        self.running = false
        self.stopServer()
        if self.session.isRunning { self.session.stopRunning() }
        DispatchQueue.main.async {
          UIApplication.shared.isIdleTimerDisabled = false
          result(nil)
        }
      }
    case "selectCamera":
      let id = args["id"] as? String
      sessionQueue.async {
        self.configureSession(cameraId: id)
        self.sendInfo()
        DispatchQueue.main.async { result(nil) }
      }
    case "setZoom":
      setZoom(CGFloat(args["value"] as? Double ?? 1.0))
      result(nil)
    case "setTorch":
      setTorch(args["on"] as? Bool ?? false)
      result(nil)
    case "setQuality":
      setQuality(args["value"] as? Double ?? 0.7)
      result(nil)
    case "dispose":
      sessionQueue.async {
        self.stopServer()
        if self.session.isRunning { self.session.stopRunning() }
      }
      if textureId >= 0 {
        textures.unregisterTexture(textureId)
        textureId = -1
      }
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func requestPermissions(_ done: @escaping ((Bool, Bool)) -> Void) {
    AVCaptureDevice.requestAccess(for: .video) { video in
      AVCaptureDevice.requestAccess(for: .audio) { audio in
        DispatchQueue.main.async { done((video, audio)) }
      }
    }
  }

  // MARK: Camera

  private func discoverCameras() -> [AVCaptureDevice] {
    var types: [AVCaptureDevice.DeviceType] = [.builtInWideAngleCamera, .builtInTelephotoCamera]
    types.append(.builtInUltraWideCamera)
    return AVCaptureDevice.DiscoverySession(
      deviceTypes: types, mediaType: .video, position: .unspecified
    ).devices
  }

  private func cameraList() -> [[String: Any]] {
    return discoverCameras().map { d in
      [
        "id": d.uniqueID,
        "name": d.localizedName,
        "front": d.position == .front,
      ]
    }
  }

  private func sessionPreset() -> AVCaptureSession.Preset {
    switch preset {
    case "720p": return .hd1280x720
    case "4k": return .hd4K3840x2160
    default: return .hd1920x1080
    }
  }

  private func presetSize() -> (Int32, Int32) {
    switch preset {
    case "720p": return (1280, 720)
    case "4k": return (3840, 2160)
    default: return (1920, 1080)
    }
  }

  /// Must be called on `sessionQueue`.
  private func configureSession(cameraId: String?) {
    let cameras = discoverCameras()
    let device =
      cameras.first(where: { $0.uniqueID == cameraId })
      ?? videoInput?.device
      ?? cameras.first(where: { $0.position == .back })
      ?? cameras.first
    guard let device = device else {
      reportError("Kamera topilmadi")
      return
    }

    session.beginConfiguration()
    defer {
      session.commitConfiguration()
      applyConnectionSettings()
      applyFrameRate(device)
    }

    let p = sessionPreset()
    session.sessionPreset = session.canSetSessionPreset(p) ? p : .high

    if videoInput?.device != device {
      if let old = videoInput { session.removeInput(old) }
      videoInput = nil
      do {
        let input = try AVCaptureDeviceInput(device: device)
        if session.canAddInput(input) {
          session.addInput(input)
          videoInput = input
        }
      } catch {
        reportError("Kamerani ochib bo'lmadi: \(error.localizedDescription)")
      }
    }

    if !session.outputs.contains(videoOutput) {
      videoOutput.videoSettings = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
      ]
      videoOutput.alwaysDiscardsLateVideoFrames = true
      videoOutput.setSampleBufferDelegate(self, queue: videoQueue)
      if session.canAddOutput(videoOutput) { session.addOutput(videoOutput) }
    }

    if audioEnabled {
      if audioInput == nil, let mic = AVCaptureDevice.default(for: .audio),
        let input = try? AVCaptureDeviceInput(device: mic), session.canAddInput(input)
      {
        session.addInput(input)
        audioInput = input
      }
      if !session.outputs.contains(audioOutput) {
        audioOutput.setSampleBufferDelegate(self, queue: audioQueue)
        if session.canAddOutput(audioOutput) { session.addOutput(audioOutput) }
      }
    } else {
      if let a = audioInput {
        session.removeInput(a)
        audioInput = nil
      }
      if session.outputs.contains(audioOutput) { session.removeOutput(audioOutput) }
    }
  }

  private func applyConnectionSettings() {
    guard let conn = videoOutput.connection(with: .video) else { return }
    if #available(iOS 17.0, *) {
      let angle: CGFloat = portrait ? 90 : 0
      if conn.isVideoRotationAngleSupported(angle) { conn.videoRotationAngle = angle }
    } else if conn.isVideoOrientationSupported {
      conn.videoOrientation = portrait ? .portrait : .landscapeRight
    }
    if conn.isVideoMirroringSupported {
      conn.automaticallyAdjustsVideoMirroring = false
      conn.isVideoMirrored = false
    }
    if conn.isVideoStabilizationSupported {
      conn.preferredVideoStabilizationMode = .standard
    }
  }

  /// 60 fps needs an explicit format on most iPhones (session presets are 30 fps).
  private func applyFrameRate(_ device: AVCaptureDevice) {
    let fps = Double(targetFps)
    do {
      try device.lockForConfiguration()
      defer { device.unlockForConfiguration() }

      let supports: (AVCaptureDevice.Format) -> Bool = { f in
        f.videoSupportedFrameRateRanges.contains { $0.maxFrameRate >= fps && $0.minFrameRate <= fps }
      }
      if !supports(device.activeFormat) {
        let (w, h) = presetSize()
        let candidate = device.formats.first { f in
          let dims = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
          return dims.width == w && dims.height == h && supports(f)
            && CMFormatDescriptionGetMediaSubType(f.formatDescription)
              == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        }
        if let candidate = candidate { device.activeFormat = candidate }
      }
      if supports(device.activeFormat) {
        let duration = CMTime(value: 1, timescale: CMTimeScale(targetFps))
        device.activeVideoMinFrameDuration = duration
        device.activeVideoMaxFrameDuration = duration
      }
      if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
      if device.isExposureModeSupported(.continuousAutoExposure) {
        device.exposureMode = .continuousAutoExposure
      }
    } catch {
      reportError("FPS sozlanmadi: \(error.localizedDescription)")
    }
  }

  private func setZoom(_ value: CGFloat) {
    sessionQueue.async {
      guard let device = self.videoInput?.device else { return }
      let maxZoom = min(device.activeFormat.videoMaxZoomFactor, 10)
      let z = max(device.minAvailableVideoZoomFactor, min(value, maxZoom))
      if (try? device.lockForConfiguration()) != nil {
        device.videoZoomFactor = z
        device.unlockForConfiguration()
      }
      self.sendInfo()
    }
  }

  private func setTorch(_ on: Bool) {
    sessionQueue.async {
      guard let device = self.videoInput?.device, device.hasTorch else { return }
      if (try? device.lockForConfiguration()) != nil {
        device.torchMode = on ? .on : .off
        device.unlockForConfiguration()
      }
      self.sendInfo()
    }
  }

  private func setQuality(_ q: Double) {
    lock.lock()
    jpegQuality = CGFloat(max(0.2, min(q, 1.0)))
    lock.unlock()
  }

  // MARK: Capture callbacks

  func captureOutput(
    _ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
    from connection: AVCaptureConnection
  ) {
    if output === audioOutput {
      handleAudio(sampleBuffer)
      return
    }
    guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

    lock.lock()
    latestPixelBuffer = pixelBuffer
    frameWidth = CVPixelBufferGetWidth(pixelBuffer)
    frameHeight = CVPixelBufferGetHeight(pixelBuffer)
    let canEncode = clientReady && !encoding && videoInflight < 2
    if canEncode { encoding = true }
    let quality = jpegQuality
    lock.unlock()

    if textureId >= 0 { textures.textureFrameAvailable(textureId) }

    capturedFrames += 1
    updateStats()

    guard canEncode else { return }
    sentFrames += 1
    encodeQueue.async {
      let image = CIImage(cvPixelBuffer: pixelBuffer)
      let options: [CIImageRepresentationOption: Any] = [
        CIImageRepresentationOption(
          rawValue: kCGImageDestinationLossyCompressionQuality as String): quality
      ]
      let jpeg = self.ciContext.jpegRepresentation(
        of: image, colorSpace: self.srgb, options: options)
      self.lock.lock()
      self.encoding = false
      self.lock.unlock()
      if let jpeg = jpeg { self.send(GlimCameraPlugin.kVideo, jpeg, isVideo: true) }
    }
  }

  private func updateStats() {
    let now = CACurrentMediaTime()
    if now - statsStart >= 1.0 {
      captureFps = Int(Double(capturedFrames) / (now - statsStart) + 0.5)
      sendFps = Int(Double(sentFrames) / (now - statsStart) + 0.5)
      capturedFrames = 0
      sentFrames = 0
      statsStart = now
      reportStatus()
    }
  }

  private func handleAudio(_ sampleBuffer: CMSampleBuffer) {
    lock.lock()
    let ready = clientReady
    lock.unlock()
    guard ready,
      let fmt = CMSampleBufferGetFormatDescription(sampleBuffer),
      let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(fmt)
    else { return }
    let asbd = asbdPtr.pointee

    var blockBuffer: CMBlockBuffer?
    var abl = AudioBufferList()
    let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
      sampleBuffer,
      bufferListSizeNeededOut: nil,
      bufferListOut: &abl,
      bufferListSize: MemoryLayout<AudioBufferList>.size,
      blockBufferAllocator: nil,
      blockBufferMemoryAllocator: nil,
      flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
      blockBufferOut: &blockBuffer)
    guard status == noErr, let mData = abl.mBuffers.mData else { return }

    let byteSize = Int(abl.mBuffers.mDataByteSize)
    let isFloat = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0
    let nonInterleaved = (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
    let channels = nonInterleaved ? 1 : Int(max(asbd.mChannelsPerFrame, 1))

    var pcm: Data
    if !isFloat && asbd.mBitsPerChannel == 16 {
      pcm = Data(bytes: mData, count: byteSize)
    } else if isFloat && asbd.mBitsPerChannel == 32 {
      let count = byteSize / 4
      let src = mData.bindMemory(to: Float32.self, capacity: count)
      var out = [Int16](repeating: 0, count: count)
      for i in 0..<count {
        let s = max(-1.0, min(1.0, src[i]))
        out[i] = Int16(s * 32767.0)
      }
      pcm = out.withUnsafeBufferPointer { Data(buffer: $0) }
    } else {
      return
    }

    var payload = Data(capacity: 5 + pcm.count)
    var rate = UInt32(asbd.mSampleRate).bigEndian
    withUnsafeBytes(of: &rate) { payload.append(contentsOf: $0) }
    payload.append(UInt8(channels))
    payload.append(pcm)
    send(GlimCameraPlugin.kAudio, payload, isVideo: false)
  }

  // MARK: Flutter texture

  func copyPixelBuffer() -> Unmanaged<CVPixelBuffer>? {
    lock.lock()
    defer { lock.unlock() }
    guard let pb = latestPixelBuffer else { return nil }
    return Unmanaged.passRetained(pb)
  }

  // MARK: Network server

  /// Must be called on `sessionQueue`.
  private func startServer(port: UInt16) {
    stopServer()
    let tcp = NWProtocolTCP.Options()
    tcp.noDelay = true
    let params = NWParameters(tls: nil, tcp: tcp)
    params.allowLocalEndpointReuse = true
    guard let nwPort = NWEndpoint.Port(rawValue: port) else { return }
    do {
      let l = try NWListener(using: params, on: nwPort)
      l.stateUpdateHandler = { [weak self] state in
        guard let self = self else { return }
        switch state {
        case .ready:
          self.listening = true
          self.lastError = ""
        case .failed(let err):
          self.listening = false
          self.lastError = "Server xatosi: \(err)"
        case .cancelled:
          self.listening = false
        default: break
        }
        self.reportStatus()
      }
      l.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
      l.start(queue: netQueue)
      listener = l
    } catch {
      reportError("Serverni ishga tushirib bo'lmadi: \(error.localizedDescription)")
    }
  }

  private func stopServer() {
    listener?.cancel()
    listener = nil
    listening = false
    lock.lock()
    let c = client
    client = nil
    clientReady = false
    videoInflight = 0
    lock.unlock()
    c?.cancel()
    reportStatus()
  }

  private func accept(_ conn: NWConnection) {
    lock.lock()
    let old = client
    client = conn
    clientReady = false
    videoInflight = 0
    clientAddress = "\(conn.endpoint)"
    lock.unlock()
    old?.cancel()

    conn.stateUpdateHandler = { [weak self, weak conn] state in
      guard let self = self, let conn = conn else { return }
      switch state {
      case .ready:
        self.lock.lock()
        if self.client === conn { self.clientReady = true }
        self.lock.unlock()
        self.sessionQueue.async { self.sendInfo() }
        self.reportStatus()
      case .failed, .cancelled:
        self.lock.lock()
        if self.client === conn {
          self.client = nil
          self.clientReady = false
          self.videoInflight = 0
        }
        self.lock.unlock()
        self.reportStatus()
      default: break
      }
    }
    conn.start(queue: netQueue)
    receiveHeader(conn)
  }

  private func receiveHeader(_ conn: NWConnection) {
    conn.receive(minimumIncompleteLength: 5, maximumLength: 5) {
      [weak self] data, _, isComplete, error in
      guard let self = self else { return }
      guard error == nil, let data = data, data.count == 5 else {
        if isComplete || error != nil { conn.cancel() }
        return
      }
      let b = [UInt8](data)
      let type = b[0]
      let len = Int(UInt32(b[1]) << 24 | UInt32(b[2]) << 16 | UInt32(b[3]) << 8 | UInt32(b[4]))
      if len == 0 {
        self.receiveHeader(conn)
        return
      }
      if len > 1_000_000 {
        conn.cancel()
        return
      }
      conn.receive(minimumIncompleteLength: len, maximumLength: len) { body, _, _, err in
        guard err == nil, let body = body else {
          conn.cancel()
          return
        }
        if type == GlimCameraPlugin.kCommand { self.handleCommand(body) }
        self.receiveHeader(conn)
      }
    }
  }

  private func handleCommand(_ body: Data) {
    guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
      let cmd = json["cmd"] as? String
    else { return }
    switch cmd {
    case "camera":
      let id = json["id"] as? String
      sessionQueue.async {
        self.configureSession(cameraId: id)
        self.sendInfo()
      }
    case "zoom":
      setZoom(CGFloat((json["value"] as? NSNumber)?.doubleValue ?? 1.0))
    case "torch":
      setTorch(json["on"] as? Bool ?? false)
    case "quality":
      setQuality((json["value"] as? NSNumber)?.doubleValue ?? 0.7)
    default:
      break
    }
    DispatchQueue.main.async {
      self.channel.invokeMethod("remoteCommand", arguments: json)
    }
  }

  private func send(_ type: UInt8, _ payload: Data, isVideo: Bool) {
    lock.lock()
    guard let conn = client, clientReady else {
      lock.unlock()
      return
    }
    if isVideo { videoInflight += 1 }
    lock.unlock()

    var packet = Data(capacity: 5 + payload.count)
    packet.append(type)
    var len = UInt32(payload.count).bigEndian
    withUnsafeBytes(of: &len) { packet.append(contentsOf: $0) }
    packet.append(payload)

    conn.send(
      content: packet,
      completion: .contentProcessed { [weak self] _ in
        guard isVideo, let self = self else { return }
        self.lock.lock()
        if self.client === conn && self.videoInflight > 0 { self.videoInflight -= 1 }
        self.lock.unlock()
      })
  }

  /// Sends the current phone state to the desktop. Call on `sessionQueue`.
  private func sendInfo() {
    let device = videoInput?.device
    lock.lock()
    let w = frameWidth
    let h = frameHeight
    lock.unlock()
    let info: [String: Any] = [
      "device": UIDevice.current.name,
      "cameras": cameraList(),
      "camera": device?.uniqueID ?? "",
      "width": w,
      "height": h,
      "fps": targetFps,
      "zoom": Double(device?.videoZoomFactor ?? 1),
      "maxZoom": Double(min(device?.activeFormat.videoMaxZoomFactor ?? 1, 10)),
      "hasTorch": device?.hasTorch ?? false,
      "torch": device?.torchMode == .on,
      "audio": audioEnabled,
    ]
    if let data = try? JSONSerialization.data(withJSONObject: info) {
      send(GlimCameraPlugin.kInfo, data, isVideo: false)
    }
    DispatchQueue.main.async { self.channel.invokeMethod("info", arguments: info) }
  }

  // MARK: Reporting to Dart

  private func reportStatus() {
    lock.lock()
    let status: [String: Any] = [
      "listening": listening,
      "client": clientReady,
      "clientAddress": clientAddress,
      "captureFps": captureFps,
      "sendFps": sendFps,
      "width": frameWidth,
      "height": frameHeight,
      "error": lastError,
    ]
    lock.unlock()
    DispatchQueue.main.async { self.channel.invokeMethod("status", arguments: status) }
  }

  private func reportError(_ message: String) {
    lastError = message
    reportStatus()
  }
}
