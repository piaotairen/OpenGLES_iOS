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
import Photos

class CustomImagePickerController: UIImagePickerController {
    
    //MARK: - Property
    
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        return .landscape
    }
}

class ViewController: UIViewController {
    
    //MARK: - Property
    
    fileprivate var player: AVPlayer!
    
    private let myVideoOutputQueue = DispatchQueue(label: "myVideoOutputQueue")
    
    fileprivate var notificationToken: NSObjectProtocol?
    
    fileprivate var timeObserver: Any? = nil
    
    @IBOutlet var playerView: EAGLView!
    
    @IBOutlet weak var chromaLevelSlider: UISlider!
    
    @IBOutlet weak var lumaLevelSlider: UISlider!
    
    @IBOutlet weak var currentTime: UILabel!
    
    @IBOutlet weak var timeView: UIView!
    
    @IBOutlet weak var customToolbar: UIToolbar!
    
    private let ONE_FRAME_DURATION = 0.03
    
    private let LUMA_SLIDER_TAG = 0
    
    private let CHROMA_SLIDER_TAG = 1
    
    private var videoOutput: AVPlayerItemVideoOutput!
    
    private var displayLink: CADisplayLink!
    
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        return .landscape
    }
    
    let AVPlayerItemStatusContext = UnsafeMutableRawPointer.allocate(byteCount: 0, alignment: 0)
    
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
        
        if player.currentItem != nil {
            addObserver(player.currentItem!, forKeyPath: "status", options: .new, context: AVPlayerItemStatusContext)
            addTimeObserverToPlayer()
        }
        
        checkPermission()
    }
    
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        
        if player.currentItem != nil {
            removeObserver(player.currentItem!, forKeyPath: "status", context: AVPlayerItemStatusContext)
            removeTimeObserverFromPlayer()
        }
        
        if notificationToken != nil {
            NotificationCenter.default.removeObserver(notificationToken as Any, name: NSNotification.Name.AVPlayerItemDidPlayToEndTime, object: player.currentItem)
            notificationToken = nil
        }
    }
    
    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
        // Dispose of any resources that can be recreated.
    }
    
    //MARK: - Private
    
    func checkPermission() {
        let photoAuthorizationStatus = PHPhotoLibrary.authorizationStatus()
        switch photoAuthorizationStatus {
        case .authorized:
            print("Access is granted by user")
        case .notDetermined:
            PHPhotoLibrary.requestAuthorization({
                (newStatus) in
                print("status is \(newStatus)")
                if newStatus ==  PHAuthorizationStatus.authorized {
                    /* do stuff here */
                    print("success")
                }
            })
            print("It is not determined until now")
        case .restricted:
            // same same
            print("User do not have access to photo album.")
        case .denied:
            // same same
            print("User has denied the permission.")
        }
    }
    
    @objc private func displayLinkCallback(sender: CADisplayLink) {
        /*
         The callback gets called once every Vsync.
         Using the display link's timestamp and duration we can compute the next time the screen will be refreshed, and copy the pixel buffer for that time
         This pixel buffer can then be processed and later rendered on screen.
         */
        var outputItemTime = kCMTimeInvalid
        
        // Calculate the nextVsync time which is when the screen will be refreshed next.
        let nextVSync = sender.timestamp + sender.duration
        
        outputItemTime = videoOutput.itemTime(forHostTime: nextVSync)
        
        if videoOutput.hasNewPixelBuffer(forItemTime: outputItemTime) {
            let pixelBuffer: CVPixelBuffer?
            pixelBuffer = videoOutput.copyPixelBuffer(forItemTime: outputItemTime, itemTimeForDisplay: nil)
            playerView.displayPixelBuffer(pixelBuffer: pixelBuffer)
        }
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
        /*
         Sets up player item and adds video output to it.
         The tracks property of an asset is loaded via asynchronous key value loading, to access the preferred transform of a video track used to orientate the video while rendering.
         After adding the video output, we request a notification of media change in order to restart the CADisplayLink.
         */
        
        // Remove video output from old item, if any.
        player.currentItem?.remove(videoOutput)
        
        let item = AVPlayerItem(url: url)
        let asset = item.asset
        asset.loadValuesAsynchronously(forKeys: ["tracks"]) {
            var error: NSError?
            if asset.statusOfValue(forKey: "tracks", error: &error) as AVKeyValueStatus == .loaded {
                let tracks = asset.tracks(withMediaType: .video)
                if tracks.count > 0 {
                    // Choose the first video track.
                    let videoTrack = tracks.first
                    videoTrack?.loadValuesAsynchronously(forKeys: ["preferredTransform"], completionHandler: { [weak self] in
                        var preferredError: NSError?
                        if let status = videoTrack?.statusOfValue(forKey: "preferredTransform", error: &preferredError) as AVKeyValueStatus?, status == .loaded {
                            if let preferredTransform = videoTrack?.preferredTransform {
                                
                                /*
                                 The orientation of the camera while recording affects the orientation of the images received from an AVPlayerItemVideoOutput. Here we compute a rotation that is used to correctly orientate the video.
                                 */
                                self?.playerView.preferredRotation = GLfloat(-1 * atan2(preferredTransform.b, preferredTransform.a))
                            }
                            self?.addDidPlayToEndTimeNotificationForPlayerItem(item)
                            
                            DispatchQueue.main.async {
                                if let videoOutput = self?.videoOutput {
                                    item.add(videoOutput)
                                }
                                self?.player.replaceCurrentItem(with: item)
                                if let duration = self?.ONE_FRAME_DURATION {
                                    self?.videoOutput.requestNotificationOfMediaDataChange(withAdvanceInterval: duration)
                                }
                                self?.player.play()
                            }
                        }
                    })
                }
            }
        }
    }
    
    private func stopLoadingAnimationAndHandleError(_ error: Error?) {
        if let error = error {
            print(error)
        }
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
        /*
         Adds a time observer to the player to periodically refresh the time label to reflect current time.
         */
        guard timeObserver == nil else {
            return
        }
        /*
         Use weak reference to self to ensure that a strong reference cycle is not formed between the view controller, player and notification block.
         */
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTimeMake(1, 2), queue: DispatchQueue.main, using: { [weak self] (time) in
            print("\(time.value) \(time.timescale)")
            self?.syncTimeLabel()
        })
    }
    
    private func removeTimeObserverFromPlayer() {
        if timeObserver != nil {
            player.removeTimeObserver(timeObserver!)
            timeObserver = nil
        }
    }
    
    //MARK: - Play Control
    
    private func addDidPlayToEndTimeNotificationForPlayerItem(_ item: AVPlayerItem) {
        if notificationToken != nil {
            notificationToken = nil
        }
        
        /*
         Setting actionAtItemEnd to None prevents the movie from getting paused at item end. A very simplistic, and not gapless, looped playback.
         */
        player.actionAtItemEnd = .none
        notificationToken = NotificationCenter.default.addObserver(forName: NSNotification.Name.AVPlayerItemDidPlayToEndTime, object: item, queue: OperationQueue.main, using: { [weak self] (note) in
            // Simple item playback rewind.
            self?.player.currentItem?.seek(to: kCMTimeZero, completionHandler: nil)
        })
    }
    
    private func syncTimeLabel() {
        var seconds = CMTimeGetSeconds(player.currentTime())
        if (__inline_isfinited(seconds) == 0) {
            seconds = 0
        }
        
        var secondsInt = round(seconds)
        let minutes = secondsInt / 60
        secondsInt -= minutes * 60
        
        currentTime.textColor = UIColor.white
        currentTime.textAlignment = .center
        currentTime.text = String.init(format: "%.2i:%.2i", minutes, secondsInt)
    }
    
    //MARK: - Public
    
}

extension ViewController: AVPlayerItemOutputPullDelegate {
    
    func outputMediaDataWillChange(_ sender: AVPlayerItemOutput) {
        // Restart display link.
        displayLink.isPaused = false
    }
}

extension ViewController: UIImagePickerControllerDelegate {
    
    func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [String : Any]) {
        dismiss(animated: true, completion: nil)
        
        if player.currentItem == nil {
            lumaLevelSlider.isEnabled = true
            chromaLevelSlider.isEnabled = true
            playerView.setupGL()
        }
        
        // Time label shows the current time of the item.
        if timeView.isHidden {
            timeView.layer.backgroundColor = UIColor(white: 0, alpha: 0.3).cgColor
            timeView.layer.cornerRadius = 5.0
            timeView.layer.borderColor = UIColor(white: 1, alpha: 0.15).cgColor
            timeView.layer.borderWidth = 1.0
            timeView.isHidden = false
            currentTime.isHidden = false
        }
        
        setupPlaybackForURL(info[UIImagePickerControllerReferenceURL] as! URL)
        picker.delegate = self
    }
    
    func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
        dismiss(animated: true, completion: nil)
        
        // Make sure our playback is resumed from any interruption.
        if let item = player.currentItem {
            addDidPlayToEndTimeNotificationForPlayerItem(item)
        }
        
        videoOutput.requestNotificationOfMediaDataChange(withAdvanceInterval: ONE_FRAME_DURATION)
        player.play()
        
        picker.delegate = nil
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

