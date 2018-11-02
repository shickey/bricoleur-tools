//
//  ViewController.swift
//  Bricoleur Asset Tool
//
//  Created by Sean Hickey on 11/2/18.
//  Copyright © 2018 Massachusetts Institute of Technology. All rights reserved.
//

import Cocoa

class ViewController: NSViewController {
    
    var clip : Clip! = nil {
        didSet {
            if slider != nil {
                slider.minValue = 0
                slider.maxValue = Double(clip.frames - 1)
                slider.doubleValue = 0
                slider.isContinuous = false
            }
            if imageView != nil {
                imageView.image = clipImage(clip: clip, atFrame: 0)
            }
        }
    }

    @IBOutlet weak var imageView: NSImageView!
    @IBOutlet weak var slider: NSSlider!
    
    override func viewDidLoad() {
        super.viewDidLoad()

        // Do any additional setup after loading the view.
    }

    override var representedObject: Any? {
        didSet {
        // Update the view, if already loaded.
        }
    }

    @IBAction func sliderChanged(_ sender: Any) {
        let slider = sender as! NSSlider
        imageView.image = clipImage(clip: clip, atFrame: Int(slider.intValue))
    }
    
}

