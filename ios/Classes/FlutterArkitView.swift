import ARKit
import AVFoundation
import CoreImage
import Foundation
import ImageIO

class FlutterArkitView: NSObject, FlutterPlatformView {
    let sceneView: ARSCNView
    let channel: FlutterMethodChannel

    var forceTapOnCenter: Bool = false
    var configuration: ARConfiguration? = nil
    var heldImageAnchorTransforms: [UUID: simd_float4x4] = [:]

    let cameraRecordingQueue = DispatchQueue(label: "arkit.cameraRecording")
    var cameraAssetWriter: AVAssetWriter?
    var cameraVideoInput: AVAssetWriterInput?
    var cameraPixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    var cameraRecordingURL: URL?
    var cameraRecordingStartTimestamp: TimeInterval?
    var cameraRecordingLastTimestamp: TimeInterval?
    var cameraRecordingImageOrientation: CGImagePropertyOrientation?
    var cameraRecordingCropRect: CGRect?
    var cameraRecordingOutputSize: CGSize?
    var cameraRecordingIsFinishing = false
    var cameraRecordingFailureMessage: String?
    let cameraImageContext = CIContext(options: [.cacheIntermediates: false])
    let cameraColorSpace = CGColorSpaceCreateDeviceRGB()
    let cameraFrameQueueLock = NSLock()
    var cameraFrameIsQueued = false
    var cameraTorchIsEnabled = false

    init(withFrame frame: CGRect, viewIdentifier viewId: Int64, messenger msg: FlutterBinaryMessenger) {
        sceneView = ARSCNView(frame: frame)
        channel = FlutterMethodChannel(name: "arkit_\(viewId)", binaryMessenger: msg)

        super.init()

        sceneView.delegate = self
        channel.setMethodCallHandler(onMethodCalled)
    }

    func view() -> UIView { return sceneView }

    func onMethodCalled(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
        let arguments = call.arguments as? [String: Any]

        if configuration == nil && call.method != "init" {
            logPluginError("plugin is not initialized properly", toChannel: channel)
            let cameraMethods = [
                "getAvailableCameraLenses",
                "getCurrentCameraLens",
                "setCameraLens",
                "takePicture",
                "startVideoRecording",
                "stopVideoRecording",
                "cancelVideoRecording",
                "isTorchAvailable",
                "setTorchEnabled",
            ]
            if cameraMethods.contains(call.method) {
                result(FlutterError(
                    code: "cameraError",
                    message: "The ARKit camera is not initialized.",
                    details: nil
                ))
            } else {
                result(nil)
            }
            return
        }

        switch call.method {
        case "init":
            initalize(arguments!, result)
            result(nil)
        case "addARKitNode":
            onAddNode(arguments!)
            result(nil)
        case "onUpdateNode":
            onUpdateNode(arguments!)
            result(nil)
        case "removeARKitNode":
            onRemoveNode(arguments!)
            result(nil)
        case "removeARKitAnchor":
            onRemoveAnchor(arguments!)
            result(nil)
        case "addCoachingOverlay":
            if #available(iOS 13.0, *) {
                addCoachingOverlay(arguments!)
            }
            result(nil)
        case "removeCoachingOverlay":
            if #available(iOS 13.0, *) {
                removeCoachingOverlay()
            }
            result(nil)
        case "getNodeBoundingBox":
            onGetNodeBoundingBox(arguments!, result)
        case "transformationChanged":
            onTransformChanged(arguments!)
            result(nil)
        case "isHiddenChanged":
            onIsHiddenChanged(arguments!)
            result(nil)
        case "updateSingleProperty":
            onUpdateSingleProperty(arguments!)
            result(nil)
        case "updateMaterials":
            onUpdateMaterials(arguments!)
            result(nil)
        case "performHitTest":
            onPerformHitTest(arguments!, result)
        case "updateFaceGeometry":
            onUpdateFaceGeometry(arguments!)
            result(nil)
        case "getLightEstimate":
            onGetLightEstimate(result)
            result(nil)
        case "projectPoint":
            onProjectPoint(arguments!, result)
        case "cameraProjectionMatrix":
            onCameraProjectionMatrix(result)
        case "pointOfViewTransform":
            onPointOfViewTransform(result)
        case "playAnimation":
            onPlayAnimation(arguments!)
            result(nil)
        case "stopAnimation":
            onStopAnimation(arguments!)
            result(nil)
        case "dispose":
            onDispose(result)
        case "cameraEulerAngles":
            onCameraEulerAngles(result)
            result(nil)
        case "cameraIntrinsics":
            onCameraIntrinsics(result)
        case "cameraImageResolution":
            onCameraImageResolution(result)
        case "snapshot":
            onGetSnapshot(result)
        case "capturedImage":
            onCameraCapturedImage(result)
        case "snapshotWithDepthData":
            onGetSnapshotWithDepthData(result)
        case "cameraPosition":
            onGetCameraPosition(result)
        case "getAvailableCameraLenses":
            onGetAvailableCameraLenses(result)
        case "getCurrentCameraLens":
            onGetCurrentCameraLens(result)
        case "setCameraLens":
            onSetCameraLens(arguments, result)
        case "takePicture":
            onTakePicture(result)
        case "startVideoRecording":
            onStartVideoRecording(result)
        case "stopVideoRecording":
            onStopVideoRecording(result)
        case "cancelVideoRecording":
            onCancelVideoRecording(result)
        case "isTorchAvailable":
            onIsTorchAvailable(result)
        case "setTorchEnabled":
            onSetTorchEnabled(arguments, result)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    func sendToFlutter(_ method: String, arguments: Any?) {
        DispatchQueue.main.async {
            self.channel.invokeMethod(method, arguments: arguments)
        }
    }

    func onDispose(_ result: FlutterResult) {
        cancelCameraVideoRecording()
        disableTorchForCleanup()
        heldImageAnchorTransforms.removeAll()
        sceneView.session.pause()
        channel.setMethodCallHandler(nil)
        result(nil)
    }

    deinit {
        cameraAssetWriter?.cancelWriting()
        if let outputURL = cameraRecordingURL {
            try? FileManager.default.removeItem(at: outputURL)
        }
    }
}
