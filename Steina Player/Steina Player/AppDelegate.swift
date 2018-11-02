//
//  AppDelegate.swift
//  Steina Player
//
//  Created by Sean Hickey on 6/7/18.
//  Copyright © 2018 Massachusetts Institute of Technology. All rights reserved.
//

import Cocoa

@NSApplicationMain
class AppDelegate: NSObject, NSApplicationDelegate {
    
    func applicationDidFinishLaunching(_ aNotification: Notification) {
        
        initAudioSystem()
        startAudio()
        
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        
        panel.begin { (result) in
            if result == .OK {
                let projectUrl = panel.urls[0]
                if FileManager.default.fileExists(atPath: projectUrl.appendingPathComponent("project.json").path) {
                    let uuidString = projectUrl.lastPathComponent
                    let projectId = UUID(uuidString: uuidString)!
                    let project = Project(id: projectId)
                    
                    let projectWC = NSStoryboard(name: NSStoryboard.Name("Main"), bundle: nil).instantiateController(withIdentifier: NSStoryboard.SceneIdentifier("ProjectWindow")) as! NSWindowController
                    let projectVC = projectWC.contentViewController as! ViewController
                    projectVC.project = project
                    projectWC.showWindow(self)
                    
                }
            }
        }
        
    }
    
    func applicationWillTerminate(_ aNotification: Notification) {
        // Insert code here to tear down your application
    }
    
    
}

