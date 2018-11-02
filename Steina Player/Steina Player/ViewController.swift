//
//  ViewController.swift
//  Steina Player
//
//  Created by Sean Hickey on 6/7/18.
//  Copyright © 2018 Massachusetts Institute of Technology. All rights reserved.
//

import Cocoa
import Metal
import WebKit
import simd

class ViewController: NSViewController, WebFrameLoadDelegate, MetalViewDelegate {
    
    var project : Project! = nil
    
    var metalLayer : CAMetalLayer! = nil
    var webView : WebView! = nil
    var displayLink : CVDisplayLink! = nil
    var ready = false
    var nextRenderTimestamp = 0.0
    var lastTargetTimestamp = 0.0
    var draggingVideoId : ClipId! = nil
    var dragStartTimestamp : CFTimeInterval! = nil 
    var previousRenderedIds : [ClipId] = []
    var renderedIds : [ClipId] = []
    var renderingQueue : DispatchQueue = DispatchQueue(label: "edu.mit.media.llk.SteinaPlayer.Render", qos: .default, attributes: .concurrent, autoreleaseFrequency: DispatchQueue.AutoreleaseFrequency.workItem, target: nil)
    let renderDispatchGroup = DispatchGroup()
    let mixingBuffer = Data(count: MemoryLayout<Float>.size * 4800) // We allocate enough for 3 frames of audio and hard cap it there
    let unproject = orthographicUnprojection(left: -320.0, right: 320.0, top: 240.0, bottom: -240.0, near: 1.0, far: -1.0)

    @IBOutlet weak var metalContainerView: MetalView!
    @IBOutlet weak var webViewContainer: NSView!
    
    override func viewWillAppear() {
        super.viewWillAppear()
        
        changeAudioOutputSource(.project)
        
        loadProjectAssets(project)
        
        metalLayer = CAMetalLayer()
        metalLayer.drawableSize = CGSize(width: 640, height: 480)
        metalContainerView.layer = metalLayer;
        metalContainerView.wantsLayer = true;
        metalContainerView.delegate = self
        
        initMetal(metalLayer)
        
        // Init webview and load editor
        webView = WebView(frame: self.webViewContainer.bounds)
        webView.autoresizingMask = [.width, .height]
        webView.frameLoadDelegate = self
        
        // Add subview
        self.webViewContainer!.addSubview(webView)
        
        // Load blocks editor
        let indexPage = Bundle.main.url(forResource: "web/index", withExtension: "html")!
        webView.mainFrame.load(URLRequest(url: indexPage))
    }
    
    @IBAction func greenFlagPressed(_ sender: Any) {
        runJavascript("vm.greenFlag();")
    }
    
    @IBAction func stopPressed(_ sender: Any) {
        runJavascript("vm.stopAll();")
    }
    
    func startDisplayLink() {
        CVDisplayLinkCreateWithActiveCGDisplays(&displayLink)
        CVDisplayLinkSetOutputCallback(displayLink, displayLinkFired, UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()))
        CVDisplayLinkStart(displayLink)
    }
    
    func stopDisplayLink() {
        CVDisplayLinkStop(displayLink)
    }
    
    func webView(_ sender: WebView!, didFinishLoadFor frame: WebFrame!) {
        onScratchLoaded()
    }
    
    func onScratchLoaded() {
        let projectJson = loadProjectJson(project)
        let js = "Steina.loadProject('\(projectJson)')"
        runJavascript(js)
        self.ready = true
        self.onReady()
//        UIView.animate(withDuration: 0.5, animations: { 
//            self.loadingView.alpha = 0.0
//        }, completion: { (_) in
//            self.loadingView.isHidden = true
//        })
    }
    
    func onReady() {
        startDisplayLink()
    }
    
    @inline(__always) @discardableResult
    func runJavascript(_ js: String) -> String? {
        return webView!.stringByEvaluatingJavaScript(from: js)
    }
    
    func tick(_ targetTimestamp: Double) {
        
        let dt = targetTimestamp - lastTargetTimestamp
        
        // @TODO This probably isn't the best way to deal with dropped video frames in the audio stream
        //       but it's an (arguably) reasonable first approximation
        if dt > 0.1 {
            print("frame too long. dt: \(dt * 1000.0)")
            nextRenderTimestamp = targetTimestamp
        }
        lastTargetTimestamp = targetTimestamp
        previousRenderedIds = renderedIds
        renderedIds = []
        
        self.renderDispatchGroup.wait()
        
        let renderingStateJson = runJavascript("Steina.tick(\(dt * 1000.0)); Steina.getRenderingState()")!
        
        
        if renderingStateJson != "" {
            
            let renderingState = try! JSONSerialization.jsonObject(with: renderingStateJson.data(using: .utf8)!, options: [])
            
            if let json = renderingState as? Dictionary<String, Any> {
                let videoTargets = json["videoTargets"] as! Array<Dictionary<String, Any>>
                let audioTargets = json["audioTargets"] as! Dictionary<String, Dictionary<String, Any>>
                let playingSounds = json["playingSounds"] as! Dictionary<String, Dictionary<String, Any>>
                
                /*****************
                 * Render Audio
                 *****************/
                
                
                memset(mixingBuffer.bytes, 0, MemoryLayout<Float>.size * 4800)
                let rawMixingBuffer = mixingBuffer.bytes.bindMemory(to: Float.self, capacity: 4800)
                
                
                for (_, sound) in playingSounds {
                    // Get properties
                    let soundAssetId   = (sound["audioTargetId"] as! String)
                    let start          = Int(floor((sound["prevPlayhead"] as! NSNumber).floatValue))
                    let end            = Int(ceil((sound["playhead"] as! NSNumber).floatValue))
                    
                    // Get samples
                    let totalSamples = min(end - start, 4800);
                    let asset = self.project.sounds[soundAssetId]!
                    let samples = fetchSamples(asset, start, end)
                    
                    let target = audioTargets[soundAssetId]!
                    let volume = (target["volume"] as! NSNumber).floatValue / Float(100.0)
                    
                    // Mix into buffer
                    let rawSamples = samples.bytes.bindMemory(to: Int16.self, capacity: totalSamples)
                    for i in 0..<totalSamples {
                        rawMixingBuffer[i] += Float(rawSamples[i]) * volume
                    }
                }
                
                // Copy samples to audio output buffer
                writeFloatSamples(mixingBuffer, forHostTime: hostTimeForTimestamp(self.nextRenderTimestamp))
                
                self.nextRenderTimestamp += dt
                
                /*****************
                 * Render Video
                 *****************/
                var numEntitiesToRender = 0
                var draggingRenderFrame : RenderFrame? = nil
                for target in videoTargets {
                    // Check for visibility, bail early if nothing to render
                    let visible = target["visible"] as! Bool
                    if !visible { continue; } // Don't render anything if the video isn't visible
                    
                    // Get target properties
                    let clipId    = (target["id"] as! String)
                    let frame     = (target["currentFrame"] as! NSNumber).floatValue
                    let x         = (target["x"] as! NSNumber).floatValue
                    let y         = (target["y"] as! NSNumber).floatValue
                    let size      = (target["size"] as! NSNumber).floatValue
                    let direction = (target["direction"] as! NSNumber).floatValue
                    let effects   = (target["effects"] as! Dictionary<String, NSNumber>) // We implicitly cast effects values to floats here
                    
                    // Get video clip
                    let videoClip = self.project.clips[clipId]!
                    
                    // Figure out which frame to render
                    var frameNumber = Int(round(frame))
                    if frameNumber >= videoClip.frames {
                        frameNumber = Int(videoClip.frames) - 1;
                    }
                    
                    // Compute the proper model transform
                    let scale = (size / 100.0)
                    let theta = (direction - 90.0) * (.pi / 180.0)
                    let transform = entityTransform(scale: scale, rotate: theta, translateX: x, translateY: y)
                    
                    // Create the effects structure
                    let colorEffect      = effects["color"]!.floatValue / 360.0
                    let whirlEffect      = effects["whirl"]!.floatValue / 360.0
                    let brightnessEffect = effects["brightness"]!.floatValue / 100.0
                    let ghostEffect      = 1.0 - (effects["ghost"]!.floatValue / 100.0)
                    let renderingEffects = VideoEffects(color: colorEffect, whirl: whirlEffect, brightness: brightnessEffect, ghost: ghostEffect)
                    
                    // Create the render frame structure
                    let renderFrame = RenderFrame(clip: videoClip, frameNumber: frameNumber, transform: transform, effects: renderingEffects)
                    
                    // If a target is being dragged, we defer drawing it until the end so that it draws on top of everything else
                    if self.draggingVideoId == clipId {
                        draggingRenderFrame = renderFrame
                        continue
                    }
                    
                    // Push the render frame into the rendering queue
                    self.renderedIds.append(clipId)
                    self.renderDispatchGroup.enter()
                    let entityIndex = numEntitiesToRender
                    self.renderingQueue.async {                        
                        pushRenderFrame(renderFrame, at: entityIndex)
                        self.renderDispatchGroup.leave()
                    }
                    numEntitiesToRender += 1
                }
                
                // Push the dragging target into the rendering queue, if it exists
                if let draggingFrame = draggingRenderFrame {
                    self.renderedIds.append(draggingFrame.clip.id.uuidString)
                    self.renderDispatchGroup.enter()
                    let entityIndex = numEntitiesToRender
                    self.renderingQueue.async {                        
                        pushRenderFrame(draggingFrame, at: entityIndex)
                        self.renderDispatchGroup.leave()
                    }
                    numEntitiesToRender += 1
                }
                
                self.renderDispatchGroup.wait()
                
                render(numEntitiesToRender)
            }
            
        }

    }
    
    /**********************************************************************
     *
     * MetalViewDelegate
     *
     **********************************************************************/
    
    func metalViewBeganTouch(_ metalView: MetalView, location: CGPoint) {
        
        let drawableSize = metalLayer.drawableSize
        let x = (location.x / metalView.bounds.size.width) * (drawableSize.width)
        let y = (location.y / metalView.bounds.size.height) * (drawableSize.height)
        
        if let draggingId = videoTargetAtLocation(CGPoint(x: x, y: y)) {
            
            let projectedX = (2.0 * (location.x / metalView.bounds.size.width)) - 1.0
            let projectedY = ((2.0 * (location.y / metalView.bounds.size.height)) - 1.0) * -1.0 // Invert y
            let unprojected = unproject * float4(Float(projectedX), Float(projectedY), 1.0, 1.0)
            
            dragStartTimestamp = CACurrentMediaTime()
            draggingVideoId = draggingId        
            runJavascript("Steina.beginDraggingVideo('\(draggingVideoId!)', \(unprojected.x), \(unprojected.y))")
        }
    }
    
    func metalViewMovedTouch(_ metalView: MetalView, location: CGPoint) {
        guard draggingVideoId != nil else { return }
        
        let x = (2.0 * (location.x / metalView.bounds.size.width)) - 1.0
        let y = ((2.0 * (location.y / metalView.bounds.size.height)) - 1.0) * -1.0 // Invert y
        let unprojected = unproject * float4(Float(x), Float(y), 1.0, 1.0)
        runJavascript("Steina.updateDraggingVideo('\(draggingVideoId!)', \(unprojected.x), \(unprojected.y))")
    }
    
    func metalViewEndedTouch(_ metalView: MetalView, location: CGPoint) {
        guard draggingVideoId != nil else { return }
        
        var shouldUpdateDragTarget = true
        if CACurrentMediaTime() - dragStartTimestamp < 0.25 {
            runJavascript("Steina.tapVideo('\(draggingVideoId!)')")
            shouldUpdateDragTarget = false;
        }
        
        runJavascript("Steina.endDraggingVideo('\(draggingVideoId!)', \(shouldUpdateDragTarget ? "true" : "false"))")
        if shouldUpdateDragTarget {
            
        }
        
        dragStartTimestamp = nil
        draggingVideoId = nil
    }
    
    func videoTargetAtLocation(_ location: CGPoint) -> ClipId? {
//        let pixels : RawPtr = RawPtr.allocate(byteCount: 1, alignment: MemoryLayout<Float>.alignment)
        let pixels = publicDepthBuffer.contents()
//        depthTex.getBytes(pixels, bytesPerRow: 1024, from: MTLRegionMake2D(Int(location.x), Int(location.y), 1, 1), mipmapLevel: 0)
        let val = pixels.bindMemory(to: Float.self, capacity: 640 * 640)[(Int(location.y) * 640) + Int(location.x)]
        if (val == 1.0) {
            return nil
        }
        let idx = indexForZValue(val)
        if idx >= previousRenderedIds.count {
            return nil
        }
        let id = previousRenderedIds[idx]
        return id
    }

}



func displayLinkFired(_ displayLink: CVDisplayLink, _ inNow: UnsafePointer<CVTimeStamp>, _ inOutputTime: UnsafePointer<CVTimeStamp>, _ flagsIn: CVOptionFlags, _ flagsOut: UnsafeMutablePointer<CVOptionFlags>, _ context: UnsafeMutableRawPointer?) -> CVReturn {
    
    let targetTimestamp = Double(inOutputTime.pointee.videoTime) / Double(inOutputTime.pointee.videoTimeScale)
    
    let vc = unsafeBitCast(context, to: ViewController.self)
    
    DispatchQueue.main.sync {
        vc.tick(targetTimestamp)
    }
    
    return kCVReturnSuccess
}
