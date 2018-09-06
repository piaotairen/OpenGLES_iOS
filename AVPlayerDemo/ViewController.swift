//
//  ViewController.swift
//  AVPlayerDemo
//
//  Created by Zihai on 2018/9/5.
//  Copyright © 2018年 Zihai. All rights reserved.
//

import UIKit
import MobileCoreServices

let ONE_FRAME_DURATION = 0.03
let LUMA_SLIDER_TAG = 0
let CHROMA_SLIDER_TAG = 1

let AVPlayerItemStatusContext = 0

class ViewController: UIImagePickerController {

    override func viewDidLoad() {
        super.viewDidLoad()
        // Do any additional setup after loading the view, typically from a nib.
    }

    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
        // Dispose of any resources that can be recreated.
    }


}

extension ViewController: AVPlayerItemOutputPullDelegate {
    
}

extension ViewController: UIImagePickerControllerDelegate {
    
}

extension ViewController: UINavigationControllerDelegate {
    
}

extension ViewController: UIPopoverControllerDelegate {
    
}

extension ViewController: UIGestureRecognizerDelegate {
    
}

extension ViewController: AVPlayerItemOutputPullDelegate {
    
}
