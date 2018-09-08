//
//  ViewController.swift
//  AVPlayerDemo
//
//  Created by Zihai on 2018/9/5.
//  Copyright © 2018年 Zihai. All rights reserved.
//

import UIKit
import MobileCoreServices
import AVFoundation

let ONE_FRAME_DURATION = 0.03
let LUMA_SLIDER_TAG = 0
let CHROMA_SLIDER_TAG = 1

class CustomImagePickerController: UIImagePickerController {
    
    //MARK: - Property
    
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        return .landscape
    }
}

class ViewController: UIViewController {
    
    //MARK: - Property
    
    fileprivate var player: AVPlayer!
    
    let myVideoOutputQueue = DispatchQueue(label: "myVideoOutputQueue")
    
    fileprivate var notificationToken: NSObjectProtocol?
    
    fileprivate let timeObserver: Any? = nil
    
    @IBOutlet var playerView: EAGLView!
    
    @IBOutlet weak var chromaLevelSlider: UISlider!
    
    @IBOutlet weak var lumaLevelSlider: UISlider!
    
    @IBOutlet weak var currentTime: UILabel!
    
    @IBOutlet weak var timeView: UIView!
    
    @IBOutlet weak var customToolbar: UIToolbar!
    
    var videoOutput: AVPlayerItemVideoOutput!
    
    var displayLink: CADisplayLink!
    
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        return .landscape
    }
    
    let AVPlayerItemStatusContext = UnsafeMutableRawPointer(bitPattern: 0)
    
    //MARK: - Life Cycle
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        playerView.lumaThreshold = lumaLevelSlider.value
        playerView.chromaThreshold = chromaLevelSlider.value
        
        player = AVPlayer()
        addTimeObserverToPlayer()
        
        displayLink = CADisplayLink(target: self, selector: #selector(displayLinkCallback(sender:)))
        displayLink.add(to: RunLoop.current, forMode: .commonModes)
        displayLink.isPaused = true
        
        let pixBuffAttributes = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange] as [String : Any]
        videoOutput = AVPlayerItemVideoOutput(pixelBufferAttributes: pixBuffAttributes)
        videoOutput.setDelegate(self, queue: myVideoOutputQueue)
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        addObserver(self, forKeyPath: "player.currentItem.status", options: .new, context: AVPlayerItemStatusContext)
        addTimeObserverToPlayer()
    }
    
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        removeObserver(self, forKeyPath: "player.currentItem.status", context: AVPlayerItemStatusContext)
        removeTimeObserverFromPlayer()
        
        if notificationToken != nil {
            NotificationCenter.default.removeObserver(notificationToken as Any, name: NSNotification.Name.AVPlayerItemDidPlayToEndTime, object: player.currentItem)
            notificationToken = nil
            
            //            notificationToken = NotificationCenter.default.addObserver(forName: AVPlayerItemDidPlayToEndTimeNotification, object: item, queue: OperationQueue.main, using: { (note) in
            //                // Simple item playback rewind.
            //                player.currentItem?.seek(to: kCMTimeZero, completionHandler: nil)
            //            })
        }
    }
    
    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
        // Dispose of any resources that can be recreated.
    }
    
    //MARK: - Private
    
    @objc private func displayLinkCallback(sender: CADisplayLink) {
        
    }
    
    //MARK: - Utilities
    
    @IBAction func updateLevels(_ sender: UISlider) {
        let tag = sender.tag
        switch tag {
        case LUMA_SLIDER_TAG:
            playerView.lumaThreshold = lumaLevelSlider.value
        case CHROMA_SLIDER_TAG:
            playerView.chromaThreshold = chromaLevelSlider.value
        default:
            break
        }
    }
    
    @IBAction func loadMovieFromCameraRoll(_ sender: Any) {
        player.pause()
        displayLink.isPaused = true
        
        //        if ([[self popover] isPopoverVisible]) {
        //            [[self popover] dismissPopoverAnimated:YES];
        //        }
        let videoPicker = CustomImagePickerController()
        videoPicker.delegate = self
        videoPicker.modalPresentationStyle = .currentContext
        videoPicker.sourceType = .savedPhotosAlbum
        videoPicker.mediaTypes = [kUTTypeMovie] as [String]
        present(videoPicker, animated: true, completion: nil)
    }
    
    @IBAction func handleTapGesture(_ tapGestureRecognizer: UITapGestureRecognizer) {
        customToolbar.isHidden = !customToolbar.isHidden
    }
    
    //MARK: - Playback setup
    
    private func setupPlaybackForURL(_ url: URL) {
        
    }
    
    private func stopLoadingAnimationAndHandleError(_ error: Error?) {
        
    }
    
    //MARK: - observe
    
    override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey : Any]?, context: UnsafeMutableRawPointer?) {
        if context == AVPlayerItemStatusContext {
            let status = change![NSKeyValueChangeKey.newKey] as! AVPlayerItemStatus
            switch status {
            case .unknown:
                break
            case .readyToPlay:
                if let rect = player.currentItem?.presentationSize {
                    playerView.presentationRect = rect
                }
            case .failed:
                stopLoadingAnimationAndHandleError(player.currentItem?.error)
            }
        } else {
            super.observeValue(forKeyPath: keyPath, of: object, change: change, context: context)
        }
    }
    
    private func addTimeObserverToPlayer() {
        
    }
    
    private func removeTimeObserverFromPlayer() {
        
    }
    
    //MARK: - Play Control
    
    private func addDidPlayToEndTimeNotificationForPlayerItem(_ item: AVPlayerItem) {
        
    }
    
    private func syncTimeLabel() {
        
    }
    
    //MARK: - Public
    
}

extension ViewController: AVPlayerItemOutputPullDelegate {
    
    func outputMediaDataWillChange(_ sender: AVPlayerItemOutput) {
        displayLink.isPaused = false
    }
}

extension ViewController: UIImagePickerControllerDelegate {
    
    func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [String : Any]) {
        
    }
    
    func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
        
    }
}

extension ViewController: UINavigationControllerDelegate {
    
}

extension ViewController: UIGestureRecognizerDelegate {
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        if touch.view === self.view {
            return false
        }
        return true
    }
}

