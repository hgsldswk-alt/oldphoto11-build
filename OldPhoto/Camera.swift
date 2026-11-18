import AVFoundation
import CoreImage
import SwiftUI

struct ViewfinderFrame {
    var boxes: [Corners]
    var aspect: CGFloat
    var reflection: Bool
    var signature: [Double]
}

protocol CaptureSource: AnyObject {
    func shutter(flash: Bool, completion: @escaping (Result<Data, Error>) -> Void)
}

final class Camera: NSObject, CaptureSource, AVCaptureVideoDataOutputSampleBufferDelegate, AVCapturePhotoCaptureDelegate {
    let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "oldphoto.capture")
    private let frameQueue = DispatchQueue(label: "oldphoto.finder", qos: .userInitiated)
    private let photos = AVCapturePhotoOutput()
    private var device: AVCaptureDevice?
    private var configured = false
    private var wanted = false
    private var single = false
    private var lastFrame: CFTimeInterval = 0
    private var completion: ((Result<Data, Error>) -> Void)?
    var onFrame: ((ViewfinderFrame) -> Void)?
    var onAvailability: ((Bool, Bool) -> Void)?

    func start() {
        if Launch.has("-camera-denied") {
            onAvailability?(false, false)
            return
        }
        sessionQueue.async {
            self.wanted = true
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .authorized: self.runIfWanted()
            case .notDetermined:
                AVCaptureDevice.requestAccess(for: .video) { granted in
                    self.sessionQueue.async {
                        if granted { self.runIfWanted() }
                        else { self.availability(false) }
                    }
                }
            default: self.availability(false)
            }
        }
    }

    private func availability(_ available: Bool) {
        let flash = available && device?.hasFlash == true
        DispatchQueue.main.async { [weak self] in self?.onAvailability?(available, flash) }
    }

    func stop() {
        sessionQueue.async { self.stopSession() }
    }

    func stopForAnalysis() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            sessionQueue.async {
                self.stopSession()
                continuation.resume()
            }
        }
    }

    private func stopSession() {
        wanted = false
        if session.isRunning { session.stopRunning() }
        EnhancementQueue.shared.camera(ObjectIdentifier(self), active: false)
    }

    func setSingle(_ value: Bool) { frameQueue.async { self.single = value } }

    private func runIfWanted() {
        guard wanted else { return }
        if !configured { configured = configure() }
        guard configured else { availability(false); return }
        if !session.isRunning {
            EnhancementQueue.shared.camera(ObjectIdentifier(self), active: true)
            session.startRunning()
            if !session.isRunning { EnhancementQueue.shared.camera(ObjectIdentifier(self), active: false) }
        }
        availability(session.isRunning)
    }

    private func configure() -> Bool {
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: device) else { return false }
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        let video = AVCaptureVideoDataOutput()
        video.alwaysDiscardsLateVideoFrames = true
        video.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        if session.canSetSessionPreset(.photo) { session.sessionPreset = .photo }
        guard session.canAddInput(input) else { return false }
        session.addInput(input)
        guard session.canAddOutput(photos) else {
            session.removeInput(input)
            return false
        }
        session.addOutput(photos)
        guard session.canAddOutput(video) else {
            session.removeOutput(photos)
            session.removeInput(input)
            return false
        }
        session.addOutput(video)
        let stillFormats = device.formats.filter { format in
            let size = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            return size.width > 0 && abs(Double(size.height) / Double(size.width) - 0.75) < 0.03
                && format.videoSupportedFrameRateRanges.contains { $0.maxFrameRate >= 24 }
        }
        if let best = stillFormats.max(by: { Self.area(Self.maximum($0)) < Self.area(Self.maximum($1)) }),
           Self.area(Self.maximum(best)) > Self.area(Self.maximum(device.activeFormat)),
           session.canSetSessionPreset(.inputPriority) {
            do {
                try device.lockForConfiguration()
                session.sessionPreset = .inputPriority
                device.activeFormat = best
                device.unlockForConfiguration()
            } catch { /* The photo preset remains usable. */ }
        }
        photos.maxPhotoQualityPrioritization = .quality
        if let maximum = Self.maximum(device.activeFormat) { photos.maxPhotoDimensions = maximum }
        if let connection = photos.connection(with: .video), connection.isVideoRotationAngleSupported(90) {
            connection.videoRotationAngle = 90
        }
        video.setSampleBufferDelegate(self, queue: frameQueue)
        self.device = device
        return true
    }

    private static func area(_ size: CMVideoDimensions?) -> Int64 {
        guard let size else { return 0 }
        return Int64(size.width) * Int64(size.height)
    }

    private static func maximum(_ format: AVCaptureDevice.Format) -> CMVideoDimensions? {
        format.supportedMaxPhotoDimensions.max { area($0) < area($1) }
    }

    func shutter(flash: Bool, completion: @escaping (Result<Data, Error>) -> Void) {
        sessionQueue.async {
            guard self.session.isRunning, self.completion == nil else {
                DispatchQueue.main.async { completion(.failure(ScanError.noCamera)) }
                return
            }
            let settings = self.photos.availablePhotoCodecTypes.contains(.hevc)
                ? AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.hevc])
                : AVCapturePhotoSettings()
            settings.photoQualityPrioritization = .quality
            if self.photos.maxPhotoDimensions.width > 0 && self.photos.maxPhotoDimensions.height > 0 {
                settings.maxPhotoDimensions = self.photos.maxPhotoDimensions
            }
            if flash, self.photos.supportedFlashModes.contains(.on) { settings.flashMode = .on }
            self.completion = completion
            self.photos.capturePhoto(with: settings, delegate: self)
        }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        if let error { finish(.failure(error)) }
        else if let data = photo.fileDataRepresentation() { finish(.success(data)) }
        else { finish(.failure(ScanError.image)) }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?) {
        if let error { finish(.failure(error)) }
    }

    private func finish(_ result: Result<Data, Error>) {
        sessionQueue.async {
            let completion = self.completion
            self.completion = nil
            DispatchQueue.main.async { completion?(result) }
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let now = CACurrentMediaTime()
        guard now - lastFrame >= 0.13, let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lastFrame = now
        autoreleasepool {
            let image = Imaging.zero(CIImage(cvPixelBuffer: buffer).oriented(.right))
            let boxes = Imaging.rectangles(image, single: single, contours: false)
            let sample = Imaging.samples(image, limit: 96)
            let frame = ViewfinderFrame(boxes: boxes, aspect: image.extent.width / image.extent.height,
                                        reflection: boxes.contains { Imaging.reflection(sample, in: $0) },
                                        signature: sample.signature)
            DispatchQueue.main.async { [weak self] in self?.onFrame?(frame) }
        }
    }
}

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    func makeUIView(context: Context) -> Preview {
        let view = Preview()
        view.preview.session = session
        view.preview.videoGravity = .resizeAspect
        return view
    }
    func updateUIView(_ view: Preview, context: Context) { view.rotate() }

    final class Preview: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var preview: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
        override func layoutSubviews() { super.layoutSubviews(); rotate() }
        func rotate() {
            if let connection = preview.connection, connection.isVideoRotationAngleSupported(90), connection.videoRotationAngle != 90 {
                connection.videoRotationAngle = 90
            }
        }
    }
}
