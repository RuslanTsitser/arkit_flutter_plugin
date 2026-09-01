import ARKit
import AVFoundation
import CoreImage
import ImageIO
import UIKit

extension FlutterArkitView {
    func onAddNode(_ arguments: [String: Any]) {
        let geometryArguments = arguments["geometry"] as? [String: Any]
        let geometry = createGeometry(geometryArguments, withDevice: sceneView.device)
        let node = createNode(geometry, fromDict: arguments, forDevice: sceneView.device, channel: channel)
        if let parentNodeName = arguments["parentNodeName"] as? String {
            let parentNode = sceneView.scene.rootNode.childNode(withName: parentNodeName, recursively: true)
            parentNode?.addChildNode(node)
        } else {
            sceneView.scene.rootNode.addChildNode(node)
        }
    }

    func onUpdateNode(_ arguments: [String: Any]) {
        guard let nodeName = arguments["nodeName"] as? String else {
            logPluginError("nodeName deserialization failed", toChannel: channel)
            return
        }
        guard let node = sceneView.scene.rootNode.childNode(withName: nodeName, recursively: true) else {
            logPluginError("node not found", toChannel: channel)
            return
        }
        if let geometryArguments = arguments["geometry"] as? [String: Any],
           let geometry = createGeometry(geometryArguments, withDevice: sceneView.device)
        {
            node.geometry = geometry
        }
        if let materials = arguments["materials"] as? [[String: Any]] {
            node.geometry?.materials = parseMaterials(materials)
        }
        updateNode(node, fromDict: arguments, forDevice: sceneView.device)
    }

    func onRemoveNode(_ arguments: [String: Any]) {
        guard let nodeName = arguments["nodeName"] as? String else {
            logPluginError("nodeName deserialization failed", toChannel: channel)
            return
        }
        let node = sceneView.scene.rootNode.childNode(withName: nodeName, recursively: true)
        node?.removeFromParentNode()
    }

    func onRemoveAnchor(_ arguments: [String: Any]) {
        guard let anchorIdentifier = arguments["anchorIdentifier"] as? String else {
            logPluginError("anchorIdentifier deserialization failed", toChannel: channel)
            return
        }
        if let anchor = sceneView.session.currentFrame?.anchors.first(where: { $0.identifier.uuidString == anchorIdentifier }) {
            sceneView.session.remove(anchor: anchor)
        }
    }

    func onGetNodeBoundingBox(_ arguments: [String: Any], _ result: FlutterResult) {
        guard let name = arguments["name"] as? String
        else {
            logPluginError("name not found: failed", toChannel: channel)
            return
        }
        if let node = sceneView.scene.rootNode.childNode(withName: name, recursively: true) {
            let resArray = [serializeVector(node.boundingBox.min), serializeVector(node.boundingBox.max)]
            result(resArray)
        } else {
            logPluginError("node \(name) not found", toChannel: channel)
        }
    }

    func onTransformChanged(_ arguments: [String: Any]) {
        guard let name = arguments["name"] as? String,
              let params = arguments["transformation"] as? [NSNumber]
        else {
            logPluginError("deserialization failed", toChannel: channel)
            return
        }
        if let node = sceneView.scene.rootNode.childNode(withName: name, recursively: true) {
            node.transform = deserializeMatrix4(params)
        } else {
            logPluginError("node \(name) not found", toChannel: channel)
        }
    }

    func onIsHiddenChanged(_ arguments: [String: Any]) {
        guard let name = arguments["name"] as? String,
              let params = arguments["isHidden"] as? Bool
        else {
            logPluginError("deserialization failed", toChannel: channel)
            return
        }
        if let node = sceneView.scene.rootNode.childNode(withName: name, recursively: true) {
            node.isHidden = params
        } else {
            logPluginError("node not found", toChannel: channel)
        }
    }

    func onUpdateSingleProperty(_ arguments: [String: Any]) {
        guard let name = arguments["name"] as? String,
              let args = arguments["property"] as? [String: Any],
              let propertyName = args["propertyName"] as? String,
              let propertyValue = args["propertyValue"],
              let keyProperty = args["keyProperty"] as? String
        else {
            logPluginError("deserialization failed", toChannel: channel)
            return
        }

        if let node = sceneView.scene.rootNode.childNode(withName: name, recursively: true) {
            if let obj = node.value(forKey: keyProperty) as? NSObject {
                obj.setValue(propertyValue, forKey: propertyName)
            } else {
                logPluginError("value is not a NSObject", toChannel: channel)
            }
        } else {
            logPluginError("node not found", toChannel: channel)
        }
    }

    func onUpdateMaterials(_ arguments: [String: Any]) {
        guard let name = arguments["name"] as? String,
              let rawMaterials = arguments["materials"] as? [[String: Any]]
        else {
            logPluginError("deserialization failed", toChannel: channel)
            return
        }
        if let node = sceneView.scene.rootNode.childNode(withName: name, recursively: true) {
            let materials = parseMaterials(rawMaterials)
            node.geometry?.materials = materials
        } else {
            logPluginError("node not found", toChannel: channel)
        }
    }

    func onUpdateFaceGeometry(_ arguments: [String: Any]) {
        #if !DISABLE_TRUEDEPTH_API
            guard let name = arguments["name"] as? String,
                  let param = arguments["geometry"] as? [String: Any],
                  let fromAnchorId = param["fromAnchorId"] as? String
            else {
                logPluginError("deserialization failed", toChannel: channel)
                return
            }
            if let node = sceneView.scene.rootNode.childNode(withName: name, recursively: true),
               let geometry = node.geometry as? ARSCNFaceGeometry,
               let anchor = sceneView.session.currentFrame?.anchors.first(where: { $0.identifier.uuidString == fromAnchorId }) as? ARFaceAnchor
            {
                geometry.update(from: anchor.geometry)
            } else {
                logPluginError("node not found, geometry was empty, or anchor not found", toChannel: channel)
            }
        #else
            logPluginError("TRUEDEPTH_API disabled", toChannel: channel)
        #endif
    }

    func onPerformHitTest(_ arguments: [String: Any], _ result: FlutterResult) {
        guard let x = arguments["x"] as? Double,
              let y = arguments["y"] as? Double
        else {
            logPluginError("deserialization failed", toChannel: channel)
            result(nil)
            return
        }
        let viewWidth = sceneView.bounds.size.width
        let viewHeight = sceneView.bounds.size.height
        let location = CGPoint(x: viewWidth * CGFloat(x), y: viewHeight * CGFloat(y))
        let arHitResults = getARHitResultsArray(sceneView, atLocation: location)
        result(arHitResults)
    }

    func onGetLightEstimate(_ result: FlutterResult) {
        let frame = sceneView.session.currentFrame
        if let lightEstimate = frame?.lightEstimate {
            let res = ["ambientIntensity": lightEstimate.ambientIntensity, "ambientColorTemperature": lightEstimate.ambientColorTemperature]
            result(res)
        } else {
            result(nil)
        }
    }

    func onProjectPoint(_ arguments: [String: Any], _ result: FlutterResult) {
        guard let rawPoint = arguments["point"] as? [Double] else {
            logPluginError("deserialization failed", toChannel: channel)
            result(nil)
            return
        }
        let point = deserizlieVector3(rawPoint)
        let projectedPoint = sceneView.projectPoint(point)
        let res = serializeVector(projectedPoint)
        result(res)
    }

    func onCameraProjectionMatrix(_ result: FlutterResult) {
        if let frame = sceneView.session.currentFrame {
            let matrix = serializeMatrix(frame.camera.projectionMatrix)
            result(matrix)
        } else {
            result(nil)
        }
    }

    func onPointOfViewTransform(_ result: FlutterResult) {
        if let pointOfView = sceneView.pointOfView {
            let matrix = serializeMatrix(pointOfView.simdWorldTransform)
            result(matrix)
        } else {
            result(nil)
        }
    }

    func onPlayAnimation(_ arguments: [String: Any]) {
        guard let key = arguments["key"] as? String,
              let sceneName = arguments["sceneName"] as? String,
              let animationIdentifier = arguments["animationIdentifier"] as? String
        else {
            logPluginError("deserialization failed", toChannel: channel)
            return
        }

        if let sceneUrl = Bundle.main.url(forResource: sceneName, withExtension: "dae"),
           let sceneSource = SCNSceneSource(url: sceneUrl, options: nil),
           let animation = sceneSource.entryWithIdentifier(animationIdentifier, withClass: CAAnimation.self)
        {
            animation.repeatCount = 1
            animation.fadeInDuration = 1
            animation.fadeOutDuration = 0.5
            sceneView.scene.rootNode.addAnimation(animation, forKey: key)
        } else {
            logPluginError("animation failed", toChannel: channel)
        }
    }

    func onStopAnimation(_ arguments: [String: Any]) {
        guard let key = arguments["key"] as? String else {
            logPluginError("deserialization failed", toChannel: channel)
            return
        }
        sceneView.scene.rootNode.removeAnimation(forKey: key)
    }

    func onCameraEulerAngles(_ result: FlutterResult) {
        if let frame = sceneView.session.currentFrame {
            let res = serializeArray(frame.camera.eulerAngles)
            result(res)
        } else {
            result(nil)
        }
    }

    func onCameraIntrinsics(_ result: FlutterResult) {
        if let frame = sceneView.session.currentFrame {
            let res = serializeMatrix3x3(frame.camera.intrinsics)
            result(res)
        } else {
            result(nil)
        }
    }

    func onCameraImageResolution(_ result: FlutterResult) {
        if let frame = sceneView.session.currentFrame {
            let res = serializeSize(frame.camera.imageResolution)
            result(res)
        } else {
            result(nil)
        }
    }

    func onCameraCapturedImage(_ result: FlutterResult) {
        if let frame = sceneView.session.currentFrame {
            if let bytes = UIImage(ciImage: CIImage(cvPixelBuffer: frame.capturedImage)).pngData() {
                let res = FlutterStandardTypedData(bytes: bytes)
                result(res)
            } else {
                result(nil)
            }
        } else {
            result(nil)
        }
    }

    func onGetSnapshot(_ result: FlutterResult) {
        let snapshotImage = sceneView.snapshot()
        if let bytes = snapshotImage.pngData() {
            let data = FlutterStandardTypedData(bytes: bytes)
            result(data)
        } else {
            result(nil)
        }
    }

    func onGetSnapshotWithDepthData(_ result: FlutterResult) {
        if #available(iOS 14.0, *) {
            if let currentFrame = sceneView.session.currentFrame, let depthData = currentFrame.sceneDepth {
                let originalImage = currentFrame.capturedImage
                let ciImage = CIImage(cvPixelBuffer: originalImage)
                let ciContext = CIContext()
                let cgImage = ciContext.createCGImage(ciImage, from: ciImage.extent)!
                let image = UIImage(cgImage: cgImage)
                let convertedImage = image.jpegData(compressionQuality: 1)!
                let imageData = FlutterStandardTypedData(bytes: convertedImage)

                let depthDataMap = depthData.depthMap

                CVPixelBufferLockBaseAddress(depthDataMap, CVPixelBufferLockFlags(rawValue: 0))

                let depthWidth = CVPixelBufferGetWidth(depthDataMap)
                let depthHeight = CVPixelBufferGetHeight(depthDataMap)

                let floatBuffer = unsafeBitCast(CVPixelBufferGetBaseAddress(depthDataMap), to: UnsafeMutablePointer<Float32>.self)

                CVPixelBufferUnlockBaseAddress(depthDataMap, CVPixelBufferLockFlags(rawValue: 0))

                let intrinsics = currentFrame.camera.intrinsics
                let intrinsicsString = String(
                    format: "%f,%f,%f-%f,%f,%f-%f,%f,%f",
                    intrinsics.columns.0.x, intrinsics.columns.0.y, intrinsics.columns.0.z,
                    intrinsics.columns.1.x, intrinsics.columns.1.y, intrinsics.columns.1.z,
                    intrinsics.columns.2.x, intrinsics.columns.2.y, intrinsics.columns.2.z
                )

                let depthArray = Array(UnsafeBufferPointer(start: floatBuffer, count: depthWidth * depthHeight)).map { $0.isNaN ? -1 : $0 }

                let data: [String: Any] = [
                    "image": imageData,
                    "intrinsics": intrinsicsString,
                    "depthWidth": depthWidth,
                    "depthHeight": depthHeight,
                    "depthMap": depthArray,
                ]

                result(data)
            } else {
                result(nil)
            }
        } else {
            result(nil)
        }
    }

    func onGetCameraPosition(_ result: FlutterResult) {
        if let frame: ARFrame = sceneView.session.currentFrame {
            let cameraPosition = frame.camera.transform.columns.3
            let res = serializeArray(cameraPosition)
            result(res)
        } else {
            result(nil)
        }
    }

    func onGetAvailableCameraLenses(_ result: FlutterResult) {
        guard configuration is ARImageTrackingConfiguration else {
            result([])
            return
        }
        guard #available(iOS 14.5, *) else {
            result([])
            return
        }

        var lensNames = [String]()
        for format in ARImageTrackingConfiguration.supportedVideoFormats where format.captureDevicePosition == .back {
            guard let lensName = cameraLensName(for: format), !lensNames.contains(lensName) else {
                continue
            }
            lensNames.append(lensName)
        }
        debugPrint("ARKit camera lenses: \(lensNames)")
        debugDumpCameraCapabilities()
        result(lensNames)
    }

    /// Dumps everything that decides whether another lens can be selected in AR:
    /// the video formats each back-camera configuration vends, the capture device ARKit is
    /// willing to expose per configuration, and the lenses AVFoundation sees on the device.
    /// A nil capture device means that configuration does not permit camera configuration -
    /// it does NOT mean the hardware is missing, which is why both are probed separately.
    @available(iOS 14.5, *)
    private func debugDumpCameraCapabilities() {
        func describeFormats(_ name: String, _ formats: [ARConfiguration.VideoFormat]) {
            var lensTypes = [String]()
            for format in formats where format.captureDevicePosition == .back {
                let lens = cameraLensName(for: format) ?? "device(\(format.captureDeviceType.rawValue))"
                if !lensTypes.contains(lens) {
                    lensTypes.append(lens)
                }
            }
            debugPrint("ARKit lens types [\(name)]: \(lensTypes) of \(formats.count) formats")
        }
        describeFormats("imageTracking", ARImageTrackingConfiguration.supportedVideoFormats)
        if ARWorldTrackingConfiguration.isSupported {
            describeFormats("worldTracking", ARWorldTrackingConfiguration.supportedVideoFormats)
        }

        if #available(iOS 16.0, *) {
            func describeDevice(_ name: String, _ configurationType: ARConfiguration.Type) {
                guard let device = configurationType.configurableCaptureDeviceForPrimaryCamera else {
                    debugPrint("ARKit capture device [\(name)]: nil (configuration does not allow it)")
                    return
                }
                debugPrint(
                    "ARKit capture device [\(name)]: type=\(device.deviceType.rawValue), " +
                        "zoom=\(device.videoZoomFactor), " +
                        "minZoom=\(device.minAvailableVideoZoomFactor), " +
                        "maxZoom=\(device.maxAvailableVideoZoomFactor), " +
                        "switchOverFactors=\(device.virtualDeviceSwitchOverVideoZoomFactors)"
                )
            }
            describeDevice("imageTracking", ARImageTrackingConfiguration.self)
            if ARWorldTrackingConfiguration.isSupported {
                describeDevice("worldTracking", ARWorldTrackingConfiguration.self)
            }
        }

        let backLenses = AVCaptureDevice.DiscoverySession(
            deviceTypes: [
                .builtInUltraWideCamera,
                .builtInWideAngleCamera,
                .builtInTelephotoCamera,
                .builtInDualWideCamera,
                .builtInTripleCamera,
            ],
            mediaType: .video,
            position: .back
        ).devices.map(\.deviceType.rawValue)
        debugPrint("AVFoundation back cameras: \(backLenses)")
    }

    func onGetCurrentCameraLens(_ result: FlutterResult) {
        guard #available(iOS 14.5, *),
              let activeConfiguration = configuration as? ARImageTrackingConfiguration,
              activeConfiguration.videoFormat.captureDevicePosition == .back
        else {
            result(nil)
            return
        }
        result(cameraLensName(for: activeConfiguration.videoFormat))
    }

    func onSetCameraLens(_ arguments: [String: Any]?, _ result: @escaping FlutterResult) {
        guard let lensName = arguments?["lens"] as? String else {
            cameraError(result, "A camera lens is required.")
            return
        }
        guard #available(iOS 14.5, *) else {
            cameraError(result, "Selecting a physical camera lens requires iOS 14.5 or newer.")
            return
        }
        guard let activeConfiguration = configuration as? ARImageTrackingConfiguration,
              let updatedConfiguration = activeConfiguration.copy() as? ARImageTrackingConfiguration
        else {
            cameraError(result, "Camera lens selection requires an active image-tracking configuration.")
            return
        }

        let candidates = ARImageTrackingConfiguration.supportedVideoFormats.enumerated().filter { _, format in
            format.captureDevicePosition == .back && cameraLensName(for: format) == lensName
        }
        guard !candidates.isEmpty else {
            cameraError(result, "The requested camera lens is not supported by this image-tracking session.")
            return
        }

        let currentFormat = activeConfiguration.videoFormat
        let currentPixels = Double(currentFormat.imageResolution.width * currentFormat.imageResolution.height)
        let selectedFormat = candidates.min { left, right in
            let leftFPSDifference = abs(left.element.framesPerSecond - currentFormat.framesPerSecond)
            let rightFPSDifference = abs(right.element.framesPerSecond - currentFormat.framesPerSecond)
            if leftFPSDifference != rightFPSDifference {
                return leftFPSDifference < rightFPSDifference
            }

            let leftPixels = Double(left.element.imageResolution.width * left.element.imageResolution.height)
            let rightPixels = Double(right.element.imageResolution.width * right.element.imageResolution.height)
            let leftPixelDifference = abs(leftPixels - currentPixels)
            let rightPixelDifference = abs(rightPixels - currentPixels)
            if leftPixelDifference != rightPixelDifference {
                return leftPixelDifference < rightPixelDifference
            }
            return left.offset < right.offset
        }?.element

        guard let selectedFormat else {
            cameraError(result, "The requested camera lens has no compatible video format.")
            return
        }

        cameraRecordingQueue.async { [weak self] in
            guard let self else { return }
            let recordingIsActive = cameraAssetWriter != nil || cameraRecordingIsFinishing
            DispatchQueue.main.async {
                if recordingIsActive {
                    self.cameraError(result, "The camera lens cannot be changed while video recording is active.")
                    return
                }
                if !self.disableTorchBeforeCameraSwitch(result) {
                    return
                }
                updatedConfiguration.videoFormat = selectedFormat
                self.configuration = updatedConfiguration
                self.sceneView.session.run(updatedConfiguration, options: [])
                result(nil)
            }
        }
    }

    func onTakePicture(_ result: @escaping FlutterResult) {
        guard let frame = sceneView.session.currentFrame else {
            cameraError(result, "No camera frame is available to capture.")
            return
        }
        let orientation = currentCameraInterfaceOrientation()
        let viewportSize = sceneView.bounds.size
        guard viewportSize.width > 0, viewportSize.height > 0 else {
            cameraError(result, "The camera preview has no visible viewport to capture.")
            return
        }

        DispatchQueue.global(qos: .userInitiated).async {
            guard let cropRect = self.cameraImageCropRect(
                for: frame,
                orientation: orientation,
                viewportSize: viewportSize,
                requiresEvenDimensions: false
            ),
                  let image = self.cameraPreviewImage(
                    from: frame.capturedImage,
                    orientation: self.cameraImageOrientation(for: orientation),
                    cropRect: cropRect
                  ),
                  let cgImage = self.cameraImageContext.createCGImage(image, from: image.extent),
                  let data = UIImage(cgImage: cgImage).jpegData(compressionQuality: 0.95)
            else {
                DispatchQueue.main.async {
                    self.cameraError(result, "The camera frame could not be encoded as JPEG.")
                }
                return
            }

            let outputURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension("jpg")
            do {
                try data.write(to: outputURL, options: .atomic)
                DispatchQueue.main.async {
                    result(outputURL.path)
                }
            } catch {
                DispatchQueue.main.async {
                    self.cameraError(result, "The camera photo could not be written: \(error.localizedDescription)")
                }
            }
        }
    }

    func onStartVideoRecording(_ result: @escaping FlutterResult) {
        guard let frame = sceneView.session.currentFrame else {
            cameraError(result, "No camera frame is available to start recording.")
            return
        }
        let orientation = currentCameraInterfaceOrientation()
        let viewportSize = sceneView.bounds.size
        guard viewportSize.width > 0, viewportSize.height > 0 else {
            cameraError(result, "The camera preview has no visible viewport to record.")
            return
        }
        let imageOrientation = cameraImageOrientation(for: orientation)
        guard let cropRect = cameraImageCropRect(
            for: frame,
            orientation: orientation,
            viewportSize: viewportSize,
            requiresEvenDimensions: true
        ),
              let previewImage = cameraPreviewImage(
                from: frame.capturedImage,
                orientation: imageOrientation,
                cropRect: cropRect
              )
        else {
            cameraError(result, "The visible camera preview could not be prepared for recording.")
            return
        }
        let outputSize = previewImage.extent.size
        guard outputSize.width >= 2,
              outputSize.height >= 2,
              outputSize.width.rounded(.towardZero) == outputSize.width,
              outputSize.height.rounded(.towardZero) == outputSize.height
        else {
            cameraError(result, "The visible camera preview could not be prepared for recording.")
            return
        }
        let width = Int(outputSize.width)
        let height = Int(outputSize.height)

        cameraRecordingQueue.async { [weak self] in
            guard let self else { return }
            guard cameraAssetWriter == nil, !cameraRecordingIsFinishing else {
                DispatchQueue.main.async {
                    self.cameraError(result, "Video recording is already active.")
                }
                return
            }

            let outputURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension("mp4")
            do {
                let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
                let videoInput = AVAssetWriterInput(
                    mediaType: .video,
                    outputSettings: [
                        AVVideoCodecKey: AVVideoCodecType.h264,
                        AVVideoWidthKey: width,
                        AVVideoHeightKey: height,
                    ]
                )
                videoInput.expectsMediaDataInRealTime = true
                guard writer.canAdd(videoInput) else {
                    throw NSError(
                        domain: "arkit.camera",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "The video writer cannot accept camera frames."]
                    )
                }
                writer.add(videoInput)
                let adaptor = AVAssetWriterInputPixelBufferAdaptor(
                    assetWriterInput: videoInput,
                    sourcePixelBufferAttributes: [
                        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                        kCVPixelBufferWidthKey as String: width,
                        kCVPixelBufferHeightKey as String: height,
                        kCVPixelBufferIOSurfacePropertiesKey as String: [:],
                    ]
                )
                guard writer.startWriting() else {
                    throw writer.error ?? NSError(
                        domain: "arkit.camera",
                        code: 2,
                        userInfo: [NSLocalizedDescriptionKey: "The video writer could not start."]
                    )
                }

                cameraAssetWriter = writer
                cameraVideoInput = videoInput
                cameraPixelBufferAdaptor = adaptor
                cameraRecordingURL = outputURL
                cameraRecordingStartTimestamp = nil
                cameraRecordingLastTimestamp = nil
                cameraRecordingImageOrientation = imageOrientation
                cameraRecordingCropRect = cropRect
                cameraRecordingOutputSize = outputSize
                cameraRecordingIsFinishing = false
                cameraRecordingFailureMessage = nil
                DispatchQueue.main.async {
                    result(nil)
                }
            } catch {
                try? FileManager.default.removeItem(at: outputURL)
                DispatchQueue.main.async {
                    self.cameraError(result, "Video recording could not start: \(error.localizedDescription)")
                }
            }
        }
    }

    func onStopVideoRecording(_ result: @escaping FlutterResult) {
        cameraRecordingQueue.async { [weak self] in
            guard let self else { return }
            guard let writer = cameraAssetWriter,
                  let videoInput = cameraVideoInput,
                  let outputURL = cameraRecordingURL
            else {
                let message = cameraRecordingFailureMessage ?? "No video recording is active."
                cameraRecordingFailureMessage = nil
                DispatchQueue.main.async {
                    self.cameraError(result, message)
                }
                return
            }
            guard !cameraRecordingIsFinishing else {
                DispatchQueue.main.async {
                    self.cameraError(result, "Video recording is already stopping.")
                }
                return
            }
            guard cameraRecordingStartTimestamp != nil else {
                writer.cancelWriting()
                resetCameraRecordingState(deleteOutput: true)
                DispatchQueue.main.async {
                    self.cameraError(result, "Video recording did not receive any camera frames.")
                }
                return
            }

            cameraRecordingIsFinishing = true
            videoInput.markAsFinished()
            writer.finishWriting {
                self.cameraRecordingQueue.async {
                    let completed = writer.status == .completed
                    let message = writer.error?.localizedDescription ?? "The video writer could not finish the recording."
                    self.resetCameraRecordingState(deleteOutput: !completed)
                    DispatchQueue.main.async {
                        if completed {
                            result(outputURL.path)
                        } else {
                            self.cameraError(result, message)
                        }
                    }
                }
            }
        }
    }

    func onCancelVideoRecording(_ result: @escaping FlutterResult) {
        cameraRecordingQueue.async { [weak self] in
            guard let self else { return }
            cameraAssetWriter?.cancelWriting()
            resetCameraRecordingState(deleteOutput: true)
            cameraRecordingFailureMessage = nil
            DispatchQueue.main.async {
                result(nil)
            }
        }
    }

    func onIsTorchAvailable(_ result: FlutterResult) {
        guard let device = torchCaptureDevice() else {
            debugPrint("ARKit torch unavailable: no capture device with a torch")
            result(false)
            return
        }
        let available = device.hasTorch && device.isTorchModeSupported(.on)
        debugPrint(
            "ARKit torch capability: type=\(device.deviceType.rawValue), " +
                "hasTorch=\(device.hasTorch), available=\(device.isTorchAvailable), " +
                "supportsOn=\(device.isTorchModeSupported(.on))"
        )
        result(available)
    }

    func onSetTorchEnabled(_ arguments: [String: Any]?, _ result: FlutterResult) {
        guard let enabled = arguments?["enabled"] as? Bool else {
            cameraError(result, "A torch enabled value is required.")
            return
        }

        do {
            try setTorchEnabledOnActiveCamera(enabled)
            cameraTorchIsEnabled = enabled
            result(nil)
        } catch {
            cameraError(result, "The torch could not be changed: \(error.localizedDescription)")
        }
    }

    func appendCameraFrame(_ frame: ARFrame) {
        cameraFrameQueueLock.lock()
        guard !cameraFrameIsQueued else {
            cameraFrameQueueLock.unlock()
            return
        }
        cameraFrameIsQueued = true
        cameraFrameQueueLock.unlock()

        cameraRecordingQueue.async { [weak self] in
            guard let self else { return }
            defer {
                cameraFrameQueueLock.lock()
                cameraFrameIsQueued = false
                cameraFrameQueueLock.unlock()
            }
            guard let writer = cameraAssetWriter,
                  let videoInput = cameraVideoInput,
                  let adaptor = cameraPixelBufferAdaptor,
                  let imageOrientation = cameraRecordingImageOrientation,
                  let cropRect = cameraRecordingCropRect,
                  let outputSize = cameraRecordingOutputSize,
                  !cameraRecordingIsFinishing
            else {
                return
            }
            guard writer.status == .writing else {
                failCameraVideoRecording(writer.error?.localizedDescription ?? "The video writer stopped unexpectedly.")
                return
            }
            guard cameraRecordingLastTimestamp == nil || frame.timestamp > cameraRecordingLastTimestamp! else {
                return
            }
            cameraRecordingLastTimestamp = frame.timestamp
            guard videoInput.isReadyForMoreMediaData else {
                return
            }

            let presentationTime = CMTime(seconds: frame.timestamp, preferredTimescale: 1_000_000_000)
            if cameraRecordingStartTimestamp == nil {
                writer.startSession(atSourceTime: presentationTime)
                cameraRecordingStartTimestamp = frame.timestamp
            }
            guard let pixelBufferPool = adaptor.pixelBufferPool else {
                failCameraVideoRecording("The video writer did not create a pixel buffer pool.")
                return
            }
            var outputPixelBuffer: CVPixelBuffer?
            let bufferStatus = CVPixelBufferPoolCreatePixelBuffer(
                nil,
                pixelBufferPool,
                &outputPixelBuffer
            )
            guard bufferStatus == kCVReturnSuccess, let outputPixelBuffer else {
                failCameraVideoRecording("A video output buffer could not be allocated.")
                return
            }

            guard let outputImage = cameraPreviewImage(
                from: frame.capturedImage,
                orientation: imageOrientation,
                cropRect: cropRect
            ), outputImage.extent.size == outputSize else {
                failCameraVideoRecording("The camera frame dimensions changed while recording.")
                return
            }
            let outputBounds = CGRect(origin: .zero, size: outputSize)
            cameraImageContext.render(
                outputImage,
                to: outputPixelBuffer,
                bounds: outputBounds,
                colorSpace: cameraColorSpace
            )
            if !adaptor.append(outputPixelBuffer, withPresentationTime: presentationTime) {
                failCameraVideoRecording(writer.error?.localizedDescription ?? "A camera frame could not be written.")
            }
        }
    }

    func cancelCameraVideoRecording() {
        cameraRecordingQueue.async { [weak self] in
            guard let self else { return }
            cameraAssetWriter?.cancelWriting()
            resetCameraRecordingState(deleteOutput: true)
            cameraRecordingFailureMessage = nil
        }
    }

    func disableTorchForCleanup() {
        cameraTorchIsEnabled = false
        guard let device = torchCaptureDevice(),
              device.hasTorch,
              device.torchMode != .off,
              device.isTorchModeSupported(.off)
        else {
            return
        }
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            device.torchMode = .off
        } catch {
            logPluginError("failed to disable torch during cleanup: \(error.localizedDescription)", toChannel: channel)
        }
    }

    private func cameraError(_ result: FlutterResult, _ message: String) {
        result(FlutterError(code: "cameraError", message: message, details: nil))
    }

    @available(iOS 14.5, *)
    private func cameraLensName(for format: ARConfiguration.VideoFormat) -> String? {
        switch format.captureDeviceType {
        case .builtInUltraWideCamera:
            return "ultraWide"
        case .builtInWideAngleCamera:
            return "wide"
        case .builtInTelephotoCamera:
            return "telephoto"
        default:
            return nil
        }
    }

    private func currentCameraInterfaceOrientation() -> UIInterfaceOrientation {
        if #available(iOS 13.0, *), let orientation = sceneView.window?.windowScene?.interfaceOrientation {
            return orientation
        }
        return UIApplication.shared.statusBarOrientation
    }

    private func cameraImageOrientation(for orientation: UIInterfaceOrientation) -> CGImagePropertyOrientation {
        switch orientation {
        case .portrait:
            return .right
        case .portraitUpsideDown:
            return .left
        case .landscapeLeft:
            return .down
        case .landscapeRight:
            return .up
        default:
            return .right
        }
    }

    private func resetCameraRecordingState(deleteOutput: Bool) {
        let outputURL = cameraRecordingURL
        cameraAssetWriter = nil
        cameraVideoInput = nil
        cameraPixelBufferAdaptor = nil
        cameraRecordingURL = nil
        cameraRecordingStartTimestamp = nil
        cameraRecordingLastTimestamp = nil
        cameraRecordingImageOrientation = nil
        cameraRecordingCropRect = nil
        cameraRecordingOutputSize = nil
        cameraRecordingIsFinishing = false
        if deleteOutput, let outputURL {
            try? FileManager.default.removeItem(at: outputURL)
        }
    }

    private func failCameraVideoRecording(_ message: String) {
        cameraAssetWriter?.cancelWriting()
        resetCameraRecordingState(deleteOutput: true)
        cameraRecordingFailureMessage = message
    }

    private func cameraImageCropRect(
        for frame: ARFrame,
        orientation: UIInterfaceOrientation,
        viewportSize: CGSize,
        requiresEvenDimensions: Bool
    ) -> CGRect? {
        let imageExtent = CIImage(cvPixelBuffer: frame.capturedImage).extent
        guard imageExtent.width > 0,
              imageExtent.height > 0,
              viewportSize.width > 0,
              viewportSize.height > 0
        else {
            return nil
        }

        let imageToView = frame.displayTransform(
            for: orientation,
            viewportSize: viewportSize
        )
        let viewToImage = imageToView.inverted()
        let viewCorners = [
            CGPoint(x: 0, y: 0),
            CGPoint(x: 1, y: 0),
            CGPoint(x: 0, y: 1),
            CGPoint(x: 1, y: 1),
        ]
        let imageCorners = viewCorners.map { $0.applying(viewToImage) }
        let minimumX = max(0, imageCorners.map(\.x).min() ?? 0)
        let maximumX = min(1, imageCorners.map(\.x).max() ?? 1)
        let minimumY = max(0, imageCorners.map(\.y).min() ?? 0)
        let maximumY = min(1, imageCorners.map(\.y).max() ?? 1)
        guard maximumX > minimumX, maximumY > minimumY else {
            return nil
        }

        var cropWidth = (maximumX - minimumX) * imageExtent.width
        var cropHeight = (maximumY - minimumY) * imageExtent.height

        if requiresEvenDimensions {
            cropWidth = floor(cropWidth / 2) * 2
            cropHeight = floor(cropHeight / 2) * 2
        }
        guard cropWidth >= 2, cropHeight >= 2 else {
            return nil
        }

        let centerX = imageExtent.minX + ((minimumX + maximumX) / 2) * imageExtent.width
        let centerYFromTop = ((minimumY + maximumY) / 2) * imageExtent.height
        let centerY = imageExtent.maxY - centerYFromTop
        return CGRect(
            x: centerX - cropWidth / 2,
            y: centerY - cropHeight / 2,
            width: cropWidth,
            height: cropHeight
        )
    }

    private func cameraPreviewImage(
        from pixelBuffer: CVPixelBuffer,
        orientation: CGImagePropertyOrientation,
        cropRect: CGRect
    ) -> CIImage? {
        let cameraImage = CIImage(cvPixelBuffer: pixelBuffer)
        guard cameraImage.extent.contains(cropRect) else {
            return nil
        }
        let previewImage = cameraImage.cropped(to: cropRect).oriented(orientation)
        return previewImage.transformed(
            by: CGAffineTransform(
                translationX: -previewImage.extent.minX,
                y: -previewImage.extent.minY
            )
        )
    }

    private func disableTorchBeforeCameraSwitch(_ result: FlutterResult) -> Bool {
        cameraTorchIsEnabled = false
        guard let device = torchCaptureDevice(),
              device.hasTorch,
              device.torchMode != .off
        else {
            return true
        }
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            guard device.isTorchModeSupported(.off) else {
                cameraError(result, "The active torch cannot be disabled before changing lenses.")
                return false
            }
            device.torchMode = .off
            return true
        } catch {
            cameraError(result, "The torch could not be disabled before changing lenses: \(error.localizedDescription)")
            return false
        }
    }

    private func setTorchEnabledOnActiveCamera(_ enabled: Bool) throws {
        guard let device = torchCaptureDevice(), device.hasTorch else {
            throw NSError(
                domain: "arkit.camera",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "The active ARKit camera does not expose a torch."]
            )
        }
        let mode: AVCaptureDevice.TorchMode = enabled ? .on : .off
        guard device.isTorchModeSupported(mode) else {
            throw NSError(
                domain: "arkit.camera",
                code: 4,
                userInfo: [NSLocalizedDescriptionKey: "The requested torch mode is not supported."]
            )
        }
        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }
        device.torchMode = mode
    }

    /// The capture device whose torch can be driven while an AR session owns the camera.
    /// `configurableCaptureDeviceForPrimaryCamera` is only available on iOS 16+ and is nil
    /// for configurations ARKit does not allow configuring, so fall back to the built-in
    /// wide angle back camera, which is the device ARKit runs the session on.
    private func torchCaptureDevice() -> AVCaptureDevice? {
        if #available(iOS 16.0, *),
           let configuration,
           let configurable = type(of: configuration).configurableCaptureDeviceForPrimaryCamera,
           configurable.hasTorch {
            return configurable
        }
        if let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
           device.hasTorch {
            return device
        }
        let device = AVCaptureDevice.default(for: .video)
        return device?.hasTorch == true ? device : nil
    }
}
