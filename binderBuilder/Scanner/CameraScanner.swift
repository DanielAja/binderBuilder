//
//  CameraScanner.swift
//  binderBuilder
//
//  Thin AVFoundation wrapper for the live single-card scanner: streams
//  throttled camera frames (portrait, BGRA → CGImage) to `onFrame` on the main
//  actor. Device-only — on the Simulator there's no camera, so callers fall
//  back to the photo path.
//
//  Threading: the type is explicitly `nonisolated` (the project defaults every
//  type to @MainActor) because it deliberately runs off the main thread —
//  configure/start/stop hop to `sessionQueue`, and `captureOutput` is delivered
//  on `frameQueue`. `configured` is only ever touched on `sessionQueue` and
//  `lastEmit` only on `frameQueue`, which is why `@unchecked Sendable` is safe.
//  `onFrame` is typed `@MainActor` so the single hop back to the UI is enforced
//  by the type system rather than by convention.
//

import AVFoundation
import CoreImage
import CoreGraphics
import Foundation

nonisolated final class CameraScanner: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let sessionQueue = DispatchQueue(label: "com.aja.binderBuilder.camera.session")
    private let frameQueue = DispatchQueue(label: "com.aja.binderBuilder.camera.frames")
    private let context = CIContext(options: [.priorityRequestLow: true])
    private var configured = false
    private var lastEmit = Date.distantPast

    /// Minimum seconds between delivered frames (throttles the match/price work).
    var throttle: TimeInterval = 0.18
    /// Called on the main actor with each throttled frame. Isolation is part of
    /// the type, so callers can touch @MainActor state without an extra hop.
    var onFrame: (@MainActor (CGImage) -> Void)?

    /// Whether this device actually has a back camera (false on the Simulator).
    static var hasCamera: Bool {
        AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) != nil
    }

    static var authorization: AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .video)
    }

    /// Requests camera permission if needed, then starts the session. Denied /
    /// no-camera cases are silently ignored (the view shows a fallback).
    func requestAccessAndStart() {
        switch Self.authorization {
        case .authorized:
            start()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                if granted { self?.start() }
            }
        default:
            break
        }
    }

    func start() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if !self.configured { self.configure() }
            guard self.configured, !self.session.isRunning else { return }
            self.session.startRunning()
        }
    }

    func stop() {
        sessionQueue.async { [weak self] in
            guard let self, self.session.isRunning else { return }
            self.session.stopRunning()
        }
    }

    private func configure() {
        session.beginConfiguration()
        session.sessionPreset = .hd1280x720
        defer { session.commitConfiguration() }
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else { return }
        session.addInput(input)
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: frameQueue)
        guard session.canAddOutput(output) else { return }
        session.addOutput(output)
        // Portrait orientation so the crop math matches a card held upright.
        if let connection = output.connection(with: .video),
           connection.isVideoRotationAngleSupported(90) {
            connection.videoRotationAngle = 90
        }
        configured = true
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        let now = Date()
        guard now.timeIntervalSince(lastEmit) >= throttle else { return }
        lastEmit = now
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else { return }
        // One ordered hop to the main queue — `assumeIsolated` (rather than a
        // Task) keeps frame delivery FIFO and preserves the throttle cadence.
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.onFrame?(cgImage) }
        }
    }
}
