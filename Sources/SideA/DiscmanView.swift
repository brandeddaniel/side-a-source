import AppKit
import SceneKit
import SwiftUI

private struct MeshObject: Decodable {
    let name: String
    let vertices: [Float]
    let normals: [Float]
    let indices: [Int32]
    let color: [CGFloat]
    let metallic: CGFloat
    let roughness: CGFloat
    let lid: Bool
    let action: String?
}

@MainActor
// AppKit can invoke these callbacks outside the main actor. Every callback
// explicitly hops to main before accessing this element or the scene.
private final class DeviceControl: NSAccessibilityElement, @unchecked Sendable {
    var press: (() -> Void)?
    nonisolated override func accessibilityPerformPress() -> Bool {
        if Thread.isMainThread { return MainActor.assumeIsolated { press?(); return true } }
        DispatchQueue.main.async { self.press?() }
        return true
    }

}

@MainActor
final class DiscSceneView: SCNView {
    var perform: ((String) -> Void)?
    var reducedMotion = false
    private var housingMouseDown: NSEvent?
    private var housingClick: String?
    private var deviceControls: [String: DeviceControl] = [:]
    override var isOpaque: Bool { false }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func control(at point: NSPoint) -> SCNNode? {
        hitTest(point).map(\.node).first { $0.name?.hasPrefix("action:") == true }
    }
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        guard !hitTest(point).isEmpty else { return }
        let node = control(at: point)
        let action = node?.name.map { String($0.dropFirst(7)) }
        // The shell can be clicked to open or dragged to reposition the object.
        // Transport buttons activate on press, just like the physical controls.
        if action == nil || action == "open" {
            housingMouseDown = event
            housingClick = action
            return
        }
        if !reducedMotion, let node {
            let down = SCNAction.moveBy(x: 0, y: -0.035, z: 0, duration: 0.065)
            node.runAction(.sequence([down, down.reversed()]))
        }
        if let action { perform?(action) }
    }
    override func mouseDragged(with event: NSEvent) {
        guard let down = housingMouseDown else { return }
        let delta = hypot(event.locationInWindow.x - down.locationInWindow.x,
                          event.locationInWindow.y - down.locationInWindow.y)
        guard delta > 4 else { return }
        housingMouseDown = nil
        housingClick = nil
        window?.performDrag(with: down)
        updateControlFrames()
    }
    override func mouseUp(with event: NSEvent) {
        if let action = housingClick { perform?(action) }
        housingClick = nil
        housingMouseDown = nil
    }
    override func keyDown(with event: NSEvent) {
        guard !event.modifierFlags.contains(.command) else { super.keyDown(with: event); return }
        switch event.keyCode {
        case 123: perform?("previous")
        case 124: perform?("next")
        case 36, 49: perform?("play")
        default: super.keyDown(with: event)
        }
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.activeInKeyWindow, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect], owner: self))
    }
    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let help = ["previous": "Previous account", "next": "Next account", "play": "Use this account on this Mac",
                    "stop": "Refresh usage", "open": "Click to open accounts. Drag the housing to move.",
                    "hold": "Lock or unlock controls", "mode": "Toggle Autopilot", "project": "Refresh usage"]
        toolTip = control(at: point)?.name.flatMap { help[String($0.dropFirst(7))] }
        if let node = control(at: point), node.name != "action:open" { NSCursor.pointingHand.set() }
        else if !hitTest(point).isEmpty { NSCursor.openHand.set() }
        else { NSCursor.arrow.set() }
    }
    override func mouseExited(with event: NSEvent) { NSCursor.arrow.set() }

    func updateAccessibility(held: Bool, smart: Bool, status: String) {
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Side A account player")
        setAccessibilityValue(status)
        let controls = [("previous", "Previous account"), ("stop", "Refresh usage"),
                        ("play", "Use this account on this Mac"), ("next", "Next account"),
                        ("open", "Open account library"), ("hold", held ? "Unlock controls" : "Lock controls"),
                        ("mode", smart ? "Disable Autopilot" : "Enable Autopilot"), ("project", "Refresh usage")]
        let children: [DeviceControl] = controls.compactMap { action, label in
            guard scene?.rootNode.childNode(withName: "action:" + action, recursively: true) != nil else { return nil }
            let element = deviceControls[action] ?? DeviceControl()
            deviceControls[action] = element
            element.setAccessibilityRole(.button)
            element.setAccessibilityLabel(label)
            element.setAccessibilityParent(self)
            element.setAccessibilityEnabled(!held || action == "hold" || action == "open")
            element.press = { [weak self] in self?.perform?(action) }
            return element
        }
        setAccessibilityChildren(children)
        updateControlFrames()
    }
    override func layout() {
        super.layout()
        updateControlFrames()
    }
    private func updateControlFrames() {
        guard let window else { return }
        for (action, element) in deviceControls {
            guard let node = scene?.rootNode.childNode(withName: "action:" + action, recursively: true) else { continue }
            let (low, high) = node.boundingBox
            let points = [low.x, high.x].flatMap { x in [low.y, high.y].flatMap { y in
                [low.z, high.z].map { z in projectPoint(node.convertPosition(SCNVector3(x, y, z), to: nil)) }
            }}
            guard let minX = points.map(\.x).min(), let maxX = points.map(\.x).max(),
                  let minY = points.map(\.y).min(), let maxY = points.map(\.y).max() else { continue }
            let rect = NSRect(x: CGFloat(minX), y: CGFloat(minY), width: CGFloat(maxX-minX), height: CGFloat(maxY-minY))
            element.setAccessibilityFrame(window.convertToScreen(convert(rect, to: nil)))
        }
    }
}

struct DiscmanView: NSViewRepresentable {
    let provider: String
    let account: String
    let track: Int
    let count: Int
    let smart: Bool
    let held: Bool
    let lidOpen: Bool
    let reducedMotion: Bool
    let status: String
    let guideControl: String?
    let activeAccount: String?
    let perform: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> DiscSceneView {
        let view = DiscSceneView()
        view.scene = context.coordinator.scene
        view.backgroundColor = .clear
        view.antialiasingMode = .multisampling4X
        view.autoenablesDefaultLighting = false
        view.allowsCameraControl = false
        view.rendersContinuously = false
        view.preferredFramesPerSecond = 60
        view.perform = perform
        view.reducedMotion = reducedMotion
        return view
    }
    func updateNSView(_ view: DiscSceneView, context: Context) {
        view.perform = perform
        view.reducedMotion = reducedMotion
        view.updateAccessibility(held: held, smart: smart, status: "On deck: \(account). \(status)")
        context.coordinator.update(provider: provider, account: account, track: track, count: count, smart: smart, held: held,
                                   open: lidOpen, reducedMotion: reducedMotion, status: status, guideControl: guideControl, activeAccount: activeAccount)
    }

    @MainActor final class Coordinator {
        let scene = SCNScene()
        let hinge = SCNNode()
        private var lcd: SCNNode?
        private var signature = ""
        private var open = false
        private var guideMaterials: [String: SCNMaterial] = [:]
        private var guideSignature = ""

        static func studioEnvironment() -> NSImage {
            NSImage(size: NSSize(width: 512, height: 256), flipped: false) { rect in
                NSGradient(colors: [NSColor(white: 0.18, alpha: 1), NSColor(white: 0.55, alpha: 1), NSColor(white: 0.98, alpha: 1)])?
                    .draw(in: rect, angle: 90)
                return true
            }
        }

        init() {
            scene.background.contents = NSColor.clear
            // Metals need something to reflect; without it the disc and chassis render as flat grey.
            scene.lightingEnvironment.contents = Self.studioEnvironment()
            scene.lightingEnvironment.intensity = 1.1
            hinge.position = SCNVector3(0, 0.45, -2.05)
            scene.rootNode.addChildNode(hinge)
            do {
                guard let url = AppResources.bundle.url(forResource: "discman", withExtension: "json") else {
                    throw CocoaError(.fileNoSuchFile)
                }
                let meshes = try JSONDecoder().decode([MeshObject].self, from: Data(contentsOf: url))
                for mesh in meshes {
                    let vertices = stride(from: 0, to: mesh.vertices.count, by: 3).map {
                        SCNVector3(mesh.vertices[$0], mesh.vertices[$0+1], mesh.vertices[$0+2])
                    }
                    let normals = stride(from: 0, to: mesh.normals.count, by: 3).map {
                        SCNVector3(mesh.normals[$0], mesh.normals[$0+1], mesh.normals[$0+2])
                    }
                    let source = SCNGeometrySource(vertices: vertices)
                    let normal = SCNGeometrySource(normals: normals)
                    let element = SCNGeometryElement(indices: mesh.indices, primitiveType: .triangles)
                    let geometry = SCNGeometry(sources: [source, normal], elements: [element])
                    let material = SCNMaterial()
                    material.lightingModel = .physicallyBased
                    material.diffuse.contents = NSColor(red: mesh.color[0], green: mesh.color[1], blue: mesh.color[2], alpha: 1)
                    material.metalness.contents = mesh.metallic
                    material.roughness.contents = mesh.roughness
                    geometry.materials = [material]
                    if mesh.name == "button_open" { guideMaterials["open"] = material }
                    if mesh.name == "button_play" { guideMaterials["play"] = material }
                    let node = SCNNode(geometry: geometry)
                    node.name = mesh.name
                    if let action = mesh.action { node.name = "action:" + action }
                    if mesh.lid {
                        node.position = SCNVector3(0, -0.45, 2.05)
                        hinge.addChildNode(node)
                    } else { scene.rootNode.addChildNode(node) }
                }
            } catch {
                let label = SCNText(string: "Model unavailable", extrusionDepth: 0)
                label.font = NSFont.systemFont(ofSize: 0.2)
                let node = SCNNode(geometry: label)
                node.position = SCNVector3(-1, 0, 0)
                scene.rootNode.addChildNode(node)
            }
            let screen = SCNPlane(width: 1.64, height: 0.59)
            screen.firstMaterial?.lightingModel = .constant
            let display = SCNNode(geometry: screen)
            display.name = "action:project"
            display.eulerAngles.x = -.pi/2
            display.position = SCNVector3(0, 0.298, 2.71)
            hinge.addChildNode(display)
            lcd = display

            let camera = SCNNode()
            camera.camera = SCNCamera()
            camera.camera?.usesOrthographicProjection = true
            camera.camera?.orthographicScale = 2.8
            camera.camera?.zNear = 0.1
            camera.camera?.zFar = 100
            camera.position = SCNVector3(0.25, 8.8, 4.8)
            camera.look(at: SCNVector3(0, 0.2, 0))
            camera.camera?.wantsHDR = true
            camera.camera?.exposureOffset = -0.35
            camera.camera?.wantsExposureAdaptation = false
            scene.rootNode.addChildNode(camera)

            for (position, intensity, color) in [
                (SCNVector3(-3, 6, 5), CGFloat(700), NSColor.white),
                (SCNVector3(4, 5, -3), CGFloat(650), NSColor(calibratedRed: 0.82, green: 0.89, blue: 1, alpha: 1)),
                (SCNVector3(-4, 2, -2), CGFloat(350), NSColor.white)
            ] {
                let light = SCNNode()
                light.light = SCNLight()
                light.light?.type = .omni
                light.light?.intensity = intensity
                light.light?.color = color
                light.position = position
                scene.rootNode.addChildNode(light)
            }
            let ambient = SCNNode()
            ambient.light = SCNLight(); ambient.light?.type = .ambient
            ambient.light?.intensity = 170
            ambient.light?.color = NSColor.white
            scene.rootNode.addChildNode(ambient)
            // A neutral studio environment gives the aluminum actual reflections.
            let environment = NSImage(size: NSSize(width: 512, height: 256), flipped: false) { rect in
                NSGradient(colors: [NSColor(white: 0.32, alpha: 1), .white, NSColor(white: 0.6, alpha: 1)])!.draw(in: rect, angle: 90)
                return true
            }
            scene.lightingEnvironment.contents = environment
            scene.lightingEnvironment.intensity = 0.55
        }

        func update(provider: String, account: String, track: Int, count: Int, smart: Bool, held: Bool, open: Bool, reducedMotion: Bool, status: String, guideControl: String?, activeAccount: String?) {
            let guideKey = "\(guideControl ?? "")|\(reducedMotion)"
            if guideKey != guideSignature {
                guideSignature = guideKey
                for (control, material) in guideMaterials {
                    material.removeAnimation(forKey: "setup-guide")
                    material.emission.contents = control == guideControl ? NSColor.systemOrange : NSColor.black
                    material.emission.intensity = control == guideControl ? 0.35 : 0
                    if control == guideControl && !reducedMotion {
                        let pulse = CABasicAnimation(keyPath: "emission.intensity")
                        pulse.fromValue = 0.08; pulse.toValue = 0.55
                        pulse.duration = 1.2; pulse.autoreverses = true; pulse.repeatCount = .infinity
                        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                        material.addAnimation(pulse, forKey: "setup-guide")
                    }
                }
            }
            let key = "\(provider)|\(account)|\(track)|\(count)|\(smart)|\(held)|\(status)|\(activeAccount ?? "")"
            if key != signature {
                signature = key
                let image = NSImage(size: NSSize(width: 820, height: 295), flipped: false) { rect in
                    NSColor(calibratedRed: 0.65, green: 0.72, blue: 0.52, alpha: 1).setFill()
                    rect.fill()
                    let color = NSColor(calibratedRed: 0.13, green: 0.19, blue: 0.10, alpha: 1)
                    func draw(_ text: String, _ x: CGFloat, _ y: CGFloat, _ size: CGFloat, _ weight: NSFont.Weight = .medium) {
                        (text as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: size, weight: weight), .foregroundColor: color])
                    }
                    draw("\(provider.uppercased()) / ON DECK", 34, 235, 26)
                    draw(held ? "HOLD" : smart ? "AUTO" : "MANUAL", 652, 235, 24)
                    draw(String(format: "%02d", count == 0 ? 0 : track), 30, 93, 108, .regular)
                    draw(String(account.prefix(15)).uppercased(), 202, 125, 39, .semibold)
                    draw(activeAccount.map { "PLAYING: " + String($0.prefix(17)).uppercased() } ?? "ACCOUNT \(count == 0 ? 0 : track) OF \(count)", 205, 80, 22)
                    draw(status, 35, 25, 22)
                    return true
                }
                lcd?.geometry?.firstMaterial?.diffuse.contents = image
            }
            if self.open != open {
                self.open = open
                SCNTransaction.begin()
                SCNTransaction.animationDuration = reducedMotion ? 0 : 0.42
                SCNTransaction.animationTimingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                hinge.eulerAngles.x = open ? -1.12 : 0
                SCNTransaction.commit()
            }
        }
    }
}
