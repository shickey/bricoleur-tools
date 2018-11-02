//
//  AppDelegate.swift
//  Bricoleur Asset Tool
//
//  Created by Sean Hickey on 11/2/18.
//  Copyright © 2018 Massachusetts Institute of Technology. All rights reserved.
//

import Cocoa

@NSApplicationMain
class AppDelegate: NSObject, NSApplicationDelegate {



    func applicationDidFinishLaunching(_ aNotification: Notification) {
        // Insert code here to initialize your application
        
        let panel = NSOpenPanel()
        
        panel.begin { (result) in
            if result == .OK {
                let clipUrl = panel.urls[0]
                let clip = loadClip(from: clipUrl)
                
                let clipWC = NSStoryboard(name: NSStoryboard.Name("Main"), bundle: nil).instantiateController(withIdentifier: NSStoryboard.SceneIdentifier("ClipWindowController")) as! NSWindowController
                let clipVC = clipWC.contentViewController as! ViewController
                clipVC.clip = clip
                clipWC.showWindow(self)
            }
        }
        
    }

    func applicationWillTerminate(_ aNotification: Notification) {
        // Insert code here to tear down your application
    }


}

