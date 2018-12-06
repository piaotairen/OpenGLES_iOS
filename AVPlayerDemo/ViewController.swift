//
//  ViewController.swift
//  AVPlayerDemo
//
//  Created by Zihai on 2018/9/5.
//  Copyright © 2018年 Zihai. All rights reserved.
//

import UIKit
import Photos
import AVFoundation
import MobileCoreServices

class CustomImagePickerController: UIImagePickerController {
    
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        return .landscape
    }
}

class ViewController: UIViewController {
    
    //MARK: - Property
    
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        return .landscape
    }
    
    /// 播放器 @objc dynamic支持监听
    @objc dynamic fileprivate var player: AVPlayer!
    
    /// 视频输出线程
    private let videoOutputQueue = DispatchQueue(label: "videoOutputQueue")
    
    /// 播放结果监听
    fileprivate var playToEndTimeObserver: NSObjectProtocol?
    
    /// 周期时间监听
    fileprivate var periodicTimeObserver: Any? = nil
    
    /// EAGLView
    @IBOutlet var playerView: EAGLView!
    
    /// 强度Slider
    @IBOutlet weak var chromaLevelSlider: UISlider!
    
    /// 亮度Slider
    @IBOutlet weak var lumaLevelSlider: UISlider!
    
    @IBOutlet weak var currentTime: UILabel!
    
    @IBOutlet weak var timeView: UIView!
    
    @IBOutlet weak var customToolbar: UIToolbar!
    
    /// 帧率
    private let frameDuration = 0.03
    
    private let lumaSliderTag = 0
    
    private let chromaSliderTag = 1
    
    /// 视频输出
    private var videoOutput: AVPlayerItemVideoOutput!
    
    private var displayLink: CADisplayLink!
    
    /// 播放状态监听上下文
    let playerItemStatusContext = UnsafeMutableRawPointer.allocate(byteCount: 0, alignment: 0)
    
    //MARK: - Life Cycle
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        prepareForPlay()
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        
        checkPermission()
        addPlayerObservers()
    }
    
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        
        removePlayerObservers()
        removePlayToEndTimeObserver()
    }
    
    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
        // Dispose of any resources that can be recreated.
    }
    
    deinit {
        playerItemStatusContext.deallocate()
    }
    
    //MARK: - Private
    
    /// 相册鉴权
    private func checkPermission() {
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
    
    /// 播放准备
    private func prepareForPlay() {
        player = AVPlayer()
        playerView.lumaThreshold = lumaLevelSlider.value
        playerView.chromaThreshold = chromaLevelSlider.value
        
        displayLink = CADisplayLink(target: self, selector: #selector(displayLinkCallback(sender:)))
        displayLink.add(to: RunLoop.current, forMode: RunLoop.Mode.common)
        displayLink.isPaused = true
        
        let pixBuffAttributes = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange] as [String : Any]
        videoOutput = AVPlayerItemVideoOutput(pixelBufferAttributes: pixBuffAttributes)
        videoOutput.setDelegate(self, queue: videoOutputQueue)
    }
    
    /// 播放渲染
    @objc private func displayLinkCallback(sender: CADisplayLink) {
        /*
         The callback gets called once every Vsync.
         Using the display link's timestamp and duration we can compute the next time the screen will be refreshed, and copy the pixel buffer for that time
         This pixel buffer can then be processed and later rendered on screen.
         */
        var outputItemTime = CMTime.invalid
        
        // Calculate the nextVsync time which is when the screen will be refreshed next.
        let nextVSync = sender.timestamp + sender.duration
        
        outputItemTime = videoOutput.itemTime(forHostTime: nextVSync)
        
        if videoOutput.hasNewPixelBuffer(forItemTime: outputItemTime) {
            var pixelBuffer: CVPixelBuffer?
            pixelBuffer = videoOutput.copyPixelBuffer(forItemTime: outputItemTime, itemTimeForDisplay: nil)
            playerView.displayPixelBuffer(pixelBuffer: pixelBuffer)
        }
    }
    
    //MARK: - Utilities
    
    /// 参数设置
    @IBAction func updateLevels(_ sender: UISlider) {
        let tag = sender.tag
        switch tag {
        case lumaSliderTag:
            playerView.lumaThreshold = lumaLevelSlider.value
        case chromaSliderTag:
            playerView.chromaThreshold = chromaLevelSlider.value
        default:
            break
        }
    }
    
    /// 选择视频
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
    
    /// 获取播放资源
    private func setupPlaybackForAsset(_ asset: PHAsset) {
        /*
         Sets up player item and adds video output to it.
         The tracks property of an asset is loaded via asynchronous key value loading, to access the preferred transform of a video track used to orientate the video while rendering.
         After adding the video output, we request a notification of media change in order to restart the CADisplayLink.
         */
        
        // Remove video output from old item, if any.
        player.currentItem?.remove(videoOutput)
        
        PHImageManager.default().requestPlayerItem(forVideo: asset, options: nil) { (item, _) in
            if let item = item {
                self.preparePlayFor(item: item)
            }
        }
    }
    
    /// 准备播放
    private func preparePlayFor(item: AVPlayerItem) {
        let asset = item.asset
        asset.loadValuesAsynchronously(forKeys: ["tracks"]) {
            var error: NSError?
            if asset.statusOfValue(forKey: "tracks", error: &error) as AVKeyValueStatus == .loaded {
                let tracks = asset.tracks(withMediaType: .video)
                guard tracks.count > 0 else {
                    return
                }
                // Choose the first video track.
                let videoTrack = tracks.first
                videoTrack?.loadValuesAsynchronously(forKeys: ["preferredTransform"], completionHandler: { [weak self] in
                    var preferredError: NSError?
                    guard let status = videoTrack?.statusOfValue(forKey: "preferredTransform", error: &preferredError) as AVKeyValueStatus?, status == .loaded else {
                        return
                    }
                    if let preferredTransform = videoTrack?.preferredTransform {
                        /*
                         The orientation of the camera while recording affects the orientation of the images received from an AVPlayerItemVideoOutput. Here we compute a rotation that is used to correctly orientate the video.
                         */
                        self?.playerView.preferredRotation = GLfloat(-1 * atan2(preferredTransform.b, preferredTransform.a))
                    }
                    self?.addPlayToEndTimeObserver(item)
                    
                    DispatchQueue.main.async {
                        if let videoOutput = self?.videoOutput {
                            item.add(videoOutput)
                        }
                        self?.player.replaceCurrentItem(with: item)
                        if let duration = self?.frameDuration {
                            self?.videoOutput.requestNotificationOfMediaDataChange(withAdvanceInterval: duration)
                        }
                        self?.player.play()
                    }
                })
            }
        }
    }
    
    /// 播放失败处理
    private func stopLoadingAnimationAndHandleError(_ error: Error?) {
        if let error = error {
            print(error)
        }
    }
    
    //MARK: - observe
    
    /// 监听Player播放状态变更
    override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey : Any]?, context: UnsafeMutableRawPointer?) {
        guard context == playerItemStatusContext,
            let change = change,
            let value = change[NSKeyValueChangeKey.newKey] else {
                return
        }
        guard let status = value as? Int else {
            return
        }
        switch status {
        case AVPlayerItem.Status.readyToPlay.rawValue:
            if let rect = player.currentItem?.presentationSize {
                playerView.presentationRect = rect
            }
        case AVPlayerItem.Status.failed.rawValue:
            stopLoadingAnimationAndHandleError(player.currentItem?.error)
        default:
            break
        }
    }
    
    //MARK: - Observer
    
    /// 添加播放状态监听
    private func addPlayerObservers() {
        self.addObserver(self, forKeyPath: "player.currentItem.status", options: .new, context: playerItemStatusContext)
        
        /*
         Adds a time observer to the player to periodically refresh the time label to reflect current time.
         */
        guard periodicTimeObserver == nil else {
            return
        }
        /*
         Use weak reference to self to ensure that a strong reference cycle is not formed between the view controller, player and notification block.
         */
        periodicTimeObserver = player.addPeriodicTimeObserver(forInterval: CMTimeMake(value: 1, timescale: 2), queue: DispatchQueue.main, using: { [weak self] (time) in
            print("\(time.value) \(time.timescale)")
            self?.syncTimeLabel()
        })
    }
    
    /// 删除播放状态监听
    private func removePlayerObservers() {
        removeObserver(self, forKeyPath: "player.currentItem.status", context: playerItemStatusContext)
        
        if periodicTimeObserver != nil {
            player.removeTimeObserver(periodicTimeObserver!)
            periodicTimeObserver = nil
        }
    }
    
    /// 添加播放结束监听
    private func addPlayToEndTimeObserver(_ item: AVPlayerItem) {
        if playToEndTimeObserver != nil {
            playToEndTimeObserver = nil
        }
        
        /*
         Setting actionAtItemEnd to None prevents the movie from getting paused at item end. A very simplistic, and not gapless, looped playback.
         */
        player.actionAtItemEnd = .none
        playToEndTimeObserver = NotificationCenter.default.addObserver(forName: NSNotification.Name.AVPlayerItemDidPlayToEndTime, object: item, queue: OperationQueue.main, using: { [weak self] (note) in
            // Simple item playback rewind.
            self?.player.currentItem?.seek(to: CMTime.zero, completionHandler: nil)
        })
    }
    
    /// 删除播放结束监听
    private func removePlayToEndTimeObserver() {
        if playToEndTimeObserver != nil {
            NotificationCenter.default.removeObserver(playToEndTimeObserver as Any, name: NSNotification.Name.AVPlayerItemDidPlayToEndTime, object: player.currentItem)
            playToEndTimeObserver = nil
        }
    }
    
    //MARK: - Play Control
    
    /// 设置播放时间
    private func syncTimeLabel() {
        var seconds = CMTimeGetSeconds(player.currentTime())
        if (__inline_isfinited(seconds) == 0) {
            seconds = 0
        }
        
        var secondsInt = Int(round(seconds))
        let minutes: Int = secondsInt / 60
        secondsInt -= minutes * 60
        
        currentTime.textColor = UIColor.white
        currentTime.textAlignment = .center
        currentTime.text = String.init(format: "%.2i:%.2i", minutes, secondsInt)
    }
    
    //MARK: - Public
    
}

extension ViewController: AVPlayerItemOutputPullDelegate {
    
    /// AVPlayerItemOutput回调
    func outputMediaDataWillChange(_ sender: AVPlayerItemOutput) {
        // Restart display link.
        displayLink.isPaused = false
    }
}

extension ViewController: UIImagePickerControllerDelegate, UINavigationControllerDelegate {
    
    /// 选择视频源
    func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey : Any]) {
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
        
        setupPlaybackForAsset(info[UIImagePickerController.InfoKey.phAsset] as! PHAsset)
        picker.delegate = self
    }
    
    /// 取消选择
    func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
        dismiss(animated: true, completion: nil)
        
        // Make sure our playback is resumed from any interruption.
        if let item = player.currentItem {
            addPlayToEndTimeObserver(item)
        }
        
        videoOutput.requestNotificationOfMediaDataChange(withAdvanceInterval: frameDuration)
        player.play()
        
        picker.delegate = nil
    }
}

extension ViewController: UIGestureRecognizerDelegate {
    
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        if touch.view === self.view {
            return false
        }
        return true
    }
}
