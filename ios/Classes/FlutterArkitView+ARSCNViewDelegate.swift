import ARKit
import Foundation
import simd

extension FlutterArkitView: ARSCNViewDelegate {
    private static let imageAnchorTranslationDeadband: Float = 0.002
    private static let imageAnchorRotationDeadband: Float = 0.5 * .pi / 180

    func session(_: ARSession, didFailWithError error: Error) {
        logPluginError("sessionDidFailWithError: \(error.localizedDescription)", toChannel: channel)
    }

    func session(_: ARSession, cameraDidChangeTrackingState camera: ARCamera) {
        var params = [String: NSNumber]()

        switch camera.trackingState {
        case .notAvailable:
            params["trackingState"] = 0
        case let .limited(reason):
            params["trackingState"] = 1
            switch reason {
            case .initializing:
                params["reason"] = 1
            case .relocalizing:
                params["reason"] = 2
            case .excessiveMotion:
                params["reason"] = 3
            case .insufficientFeatures:
                params["reason"] = 4
            default:
                params["reason"] = 0
            }
        case .normal:
            params["trackingState"] = 2
        }

        sendToFlutter("onCameraDidChangeTrackingState", arguments: params)
    }

    func sessionWasInterrupted(_: ARSession) {
        cancelCameraVideoRecording()
        disableTorchForCleanup()
        sendToFlutter("onSessionWasInterrupted", arguments: nil)
    }

    func sessionInterruptionEnded(_: ARSession) {
        sendToFlutter("onSessionInterruptionEnded", arguments: nil)
    }

    func renderer(_: SCNSceneRenderer, didAdd node: SCNNode, for anchor: ARAnchor) {
        if node.name == nil {
            node.name = NSUUID().uuidString
        }
        if let imageAnchor = anchor as? ARImageAnchor {
            heldImageAnchorTransforms[anchor.identifier] = node.simdTransform
            if let imageName = imageAnchor.referenceImage.name {
                reclaimOrphanedImageAnchorChildren(onto: node, imageName: imageName)
            }
        }
        let params = prepareParamsForAnchorEvent(node, anchor)
        sendToFlutter("didAddNodeForAnchor", arguments: params)
    }

    func renderer(_: SCNSceneRenderer, didUpdate node: SCNNode, for anchor: ARAnchor) {
        if let imageAnchor = anchor as? ARImageAnchor, !imageAnchor.isTracked {
            node.isHidden = false
        }
        stabilizeImageAnchorNode(node, for: anchor)
        let params = prepareParamsForAnchorEvent(node, anchor)
        sendToFlutter("didUpdateNodeForAnchor", arguments: params)
    }

    func renderer(_: SCNSceneRenderer, didRemove node: SCNNode, for anchor: ARAnchor) {
        heldImageAnchorTransforms.removeValue(forKey: anchor.identifier)
        if let imageAnchor = anchor as? ARImageAnchor,
           let imageName = imageAnchor.referenceImage.name
        {
            orphanImageAnchorChildren(node, imageName: imageName)
        }
        let params = prepareParamsForAnchorEvent(node, anchor)
        sendToFlutter("didRemoveNodeForAnchor", arguments: params)
    }

    func renderer(_: SCNSceneRenderer, updateAtTime time: TimeInterval) {
        if let frame = sceneView.session.currentFrame {
            appendCameraFrame(frame)
        }
        let params = ["time": NSNumber(floatLiteral: time)]
        sendToFlutter("updateAtTime", arguments: params)
    }

    fileprivate func prepareParamsForAnchorEvent(_ node: SCNNode, _ anchor: ARAnchor) -> [String: Any] {
        var serializedAnchor = serializeAnchor(anchor)
        serializedAnchor["nodeName"] = node.name
        return serializedAnchor
    }

    fileprivate func stabilizeImageAnchorNode(_ node: SCNNode, for anchor: ARAnchor) {
        guard anchor is ARImageAnchor else {
            return
        }

        let proposed = node.simdTransform
        guard let held = heldImageAnchorTransforms[anchor.identifier] else {
            heldImageAnchorTransforms[anchor.identifier] = proposed
            return
        }

        let translationDelta = simd_length(
            simd_make_float3(proposed.columns.3) - simd_make_float3(held.columns.3)
        )
        var relativeRotation = simd_quatf(proposed) * simd_quatf(held).inverse
        if relativeRotation.real < 0 {
            relativeRotation = -relativeRotation
        }
        let rotationDelta = relativeRotation.angle

        if translationDelta < Self.imageAnchorTranslationDeadband,
           rotationDelta < Self.imageAnchorRotationDeadband
        {
            node.simdTransform = held
            return
        }

        heldImageAnchorTransforms[anchor.identifier] = proposed
    }

    fileprivate func orphanImageAnchorChildren(_ node: SCNNode, imageName: String) {
        var names = orphanedImageAnchorNodeNames[imageName] ?? []
        for child in node.childNodes {
            let world = child.simdWorldTransform
            child.removeFromParentNode()
            sceneView.scene.rootNode.addChildNode(child)
            child.simdWorldTransform = world
            if let name = child.name, !names.contains(name) {
                names.append(name)
            }
        }
        if !names.isEmpty {
            orphanedImageAnchorNodeNames[imageName] = names
        }
    }

    fileprivate func reclaimOrphanedImageAnchorChildren(
        onto parent: SCNNode,
        imageName: String
    ) {
        guard let names = orphanedImageAnchorNodeNames[imageName] else {
            return
        }
        for name in names {
            guard let child = sceneView.scene.rootNode.childNode(
                withName: name,
                recursively: true
            ) else {
                continue
            }
            if child.parent === parent {
                continue
            }
            let world = child.simdWorldTransform
            child.removeFromParentNode()
            parent.addChildNode(child)
            child.simdWorldTransform = world
        }
        orphanedImageAnchorNodeNames.removeValue(forKey: imageName)
    }
}
