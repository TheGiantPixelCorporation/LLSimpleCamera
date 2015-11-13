
/*
File: LLCameraViewController.m
Abstract: View controller for camera interface
Version: 2.1

Disclaimer: IMPORTANT:  This Apple software is supplied to you by Apple
Inc. ("Apple") in consideration of your agreement to the following
terms, and your use, installation, modification or redistribution of
this Apple software constitutes acceptance of these terms.  If you do
not agree with these terms, please do not use, install, modify or
redistribute this Apple software.

In consideration of your agreement to abide by the following terms, and
subject to these terms, Apple grants you a personal, non-exclusive
license, under Apple's copyrights in this original Apple software (the
"Apple Software"), to use, reproduce, modify and redistribute the Apple
Software, with or without modifications, in source and/or binary forms;
provided that if you redistribute the Apple Software in its entirety and
without modifications, you must retain this notice and the following
text and disclaimers in all such redistributions of the Apple Software.
Neither the name, trademarks, service marks or logos of Apple Inc. may
be used to endorse or promote products derived from the Apple Software
without specific prior written permission from Apple.  Except as
expressly stated in this notice, no other rights or licenses, express or
implied, are granted by Apple herein, including but not limited to any
patent rights that may be infringed by your derivative works or by other
works in which the Apple Software may be incorporated.

The Apple Software is provided by Apple on an "AS IS" basis.  APPLE
MAKES NO WARRANTIES, EXPRESS OR IMPLIED, INCLUDING WITHOUT LIMITATION
THE IMPLIED WARRANTIES OF NON-INFRINGEMENT, MERCHANTABILITY AND FITNESS
FOR A PARTICULAR PURPOSE, REGARDING THE APPLE SOFTWARE OR ITS USE AND
OPERATION ALONE OR IN COMBINATION WITH YOUR PRODUCTS.

IN NO EVENT SHALL APPLE BE LIABLE FOR ANY SPECIAL, INDIRECT, INCIDENTAL
OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
INTERRUPTION) ARISING IN ANY WAY OUT OF THE USE, REPRODUCTION,
MODIFICATION AND/OR DISTRIBUTION OF THE APPLE SOFTWARE, HOWEVER CAUSED
AND WHETHER UNDER THEORY OF CONTRACT, TORT (INCLUDING NEGLIGENCE),
STRICT LIABILITY OR OTHERWISE, EVEN IF APPLE HAS BEEN ADVISED OF THE
POSSIBILITY OF SUCH DAMAGE.

Copyright (C) 2014 Apple Inc. All Rights Reserved.

*/

import UIKit
import QuartzCore
import GLKit



//public enum CameraFlash {
//    case Off
//    case On
//    case Auto
//}
//
//
public enum LLSimpleCameraError : ErrorType {
    case CameraPermission
    case MicrophonePermission
    case Session
    case VideoNotEnabled
}


public class LLCameraViewController : GLKViewController, LLCapturePipelineDelegate {
    private var _backgroundRecordingID = UIBackgroundTaskInvalid
    private var _allowedToUseGPU = false
    private var _ciContext: CIContext?
    public  var videoEnabled: Bool = true
//    public var cameraQuality: String?
    public var flash: CameraFlash {
        get {
            return capturePipeline.flash()
        }
    }

    public var cameraPosition: CameraPosition = CameraPositionBack {
        didSet {
            if let pipeline = capturePipeline {
                pipeline.cameraPosition = cameraPosition
            }
        }
    }
    
    public var recording: Bool = false
    public var fixOrientationAfterCapture: Bool = false

    /// Set YES if you your view controller does not allow autorotation,
    ///however you want to take the device rotation into account no matter what. Disabled by default.
    public var useDeviceOrientation: Bool = false
    
    public var didRecord: ((LLCameraViewController, NSURL, NSError?) -> Void)?


    public  var _renderer: LLRenderer? {
        didSet {
            self.capturePipeline?.renderer = _renderer
        }
    }
    
    
    private var _currentPixelBuffer: CVPixelBufferRef?
    
//    @IBOutlet private var previewView: GLKView!
    private var capturePipeline: LLCapturePipeline!
    
    

    // MARK - callbacks
    public var onDeviceChange: ((LLCameraViewController, AVCaptureDevice?) -> Void)?
    public var onSessionStarted: ((LLCameraViewController) -> Void)?
    public var onError: ((LLCameraViewController, ErrorType) -> Void)?


    override public func viewDidLoad() {
        super.viewDidLoad()
        
        let center = NSNotificationCenter.defaultCenter()
        center.addObserver(self, selector:Selector("applicationDidEnterBackground"), name:  UIApplicationDidEnterBackgroundNotification, object: nil)
        center.addObserver(self, selector:Selector("applicationWillEnterForeground"), name:  UIApplicationWillEnterForegroundNotification, object: nil)
        center.addObserver(self, selector:Selector("deviceOrientationDidChange"), name:  UIDeviceOrientationDidChangeNotification, object: UIDevice.currentDevice())
        UIDevice.currentDevice().beginGeneratingDeviceOrientationNotifications()
        
        let glkView = self.view as! GLKView
        glkView.context = EAGLContext(API: .OpenGLES2)
        _ciContext = CIContext(EAGLContext: glkView.context, options: [kCIContextWorkingColorSpace : NSNull()] )

        var transform = CGAffineTransformIdentity;
        transform = CGAffineTransformMakeRotation(CGFloat(M_PI_2))
        // apply the horizontal flip
//        let shouldMirror =  (AVCaptureDevicePositionFront == _videoDevice.position);
//        if (shouldMirror)
//            transform = CGAffineTransformConcat(transform, CGAffineTransformMakeScale(-1.0, 1.0));
//
        glkView.transform = transform

        
        if _renderer == nil {
            _renderer = DefaultRenderer()
        }
        
        capturePipeline = LLCapturePipeline(_renderer)
        capturePipeline.cameraPosition = self.cameraPosition
        capturePipeline.setDelegate(self, callbackQueue:dispatch_get_main_queue())
        

        _allowedToUseGPU = (UIApplication.sharedApplication().applicationState != .Background)
        capturePipeline.renderingEnabled = _allowedToUseGPU
    }
    
    deinit {
        let center = NSNotificationCenter.defaultCenter()
        center.removeObserver(self)
    }

    // MARK - View lifecycle
    public func applicationDidEnterBackground() {
        // Avoid using the GPU in the background
        _allowedToUseGPU = false
        capturePipeline.renderingEnabled = false
        capturePipeline.stopRecording()
        
        // TODO: Reenable or remove preview view?
        // We reset the OpenGLPixelBufferView to ensure all resources have been clear when going to the background.
//        [self.previewView reset];
    }
    
    public func applicationWillEnterForeground() {
        _allowedToUseGPU = true
        self.capturePipeline.renderingEnabled = true
    }
    
    override public func viewWillAppear(animated: Bool) {
        super.viewWillAppear(animated)
      
        self.capturePipeline.startRunning()
    }
    
    override public func viewDidDisappear(animated: Bool) {
        super.viewDidDisappear(animated)
        self.capturePipeline.stopRunning()
    }
   
   public override func touchesBegan(touches: Set<UITouch>, withEvent event: UIEvent?) {
      _renderer?.touchesBegan?(touches, withEvent: event)
   }
   
   public override func touchesMoved(touches: Set<UITouch>, withEvent event: UIEvent?) {
      _renderer?.touchesMoved?(touches, withEvent: event)
   }
   
    public func start() {
        LLCameraViewController.requestCameraPermission() { (granted) in
            if(granted) {
                // request microphone permission if video is enabled
                if(self.videoEnabled) {
                    LLCameraViewController.requestMicrophonePermission() { (granted) in
                        if(granted) {
                            self.capturePipeline.startRunning()
                        }
                        else {
                            self.onError?(self, LLSimpleCameraError.MicrophonePermission)
                        }
                    }
                }
                else {
                    self.capturePipeline.startRunning()
                }
            }
            else {
                self.onError?(self, LLSimpleCameraError.CameraPermission)
            }
        }
    }
   
   public func stop() {
      self.capturePipeline.stopRunning()
   }


    override public func supportedInterfaceOrientations() -> UIInterfaceOrientationMask {
        return .Portrait
    }
    
    override public func prefersStatusBarHidden() -> Bool {
        return true
    }
    
    func update() {
        
    }
    
    override public func glkView(view: GLKView, drawInRect rect: CGRect) {
        if let currentPixelBuffer = _currentPixelBuffer {
            glClearColor(0.5, 0.5, 0.5, 1.0)
            glClear(UInt32(GL_COLOR_BUFFER_BIT));
            let image = CIImage(CVPixelBuffer: currentPixelBuffer)
            
            let sourceExtent = image.extent
            let sourceAspect = sourceExtent.size.width / sourceExtent.size.height
            let previewAspect = CGFloat(view.drawableWidth) / CGFloat(view.drawableHeight)

            var drawRect = sourceExtent
            // we want to maintain the aspect radio of the screen size, so we clip the video image
            if sourceAspect > previewAspect {
                // use full height of the video image, and center crop the width
                drawRect.origin.x += (drawRect.size.width - drawRect.size.height * previewAspect) / 2.0;
                drawRect.size.width = drawRect.size.height * previewAspect;
            }
            else
            {
                // use full width of the video image, and center crop the height
                drawRect.origin.y += (drawRect.size.height - drawRect.size.width / previewAspect) / 2.0;
                drawRect.size.height = drawRect.size.width / previewAspect;
            }

            
            let inRect = CGRect(x: 0, y: 0, width: view.drawableWidth, height: view.drawableHeight)
            let fromRect = drawRect

            _ciContext?.drawImage(image, inRect: inRect, fromRect: fromRect)
            
        } else {
            //glClear(UInt32(GL_COLOR_BUFFER_BIT));
        }
    }

    
    //MARK - UI
    
    // TODO: Look into idleTimerDisabled
//    func toggleRecording(sender: AnyObject) -> Bool {
//        if _recording {
//            self.capturePipeline.stopRecording()
//            _recording = false
//            return false
//        } else {
//            // Make sure we have time to finish saving the movie if the app is backgrounded during recording
//            if UIDevice.currentDevice().multitaskingSupported {
//                _backgroundRecordingID = UIApplication.sharedApplication().beginBackgroundTaskWithExpirationHandler() { [weak self] () -> Void in
//                    if let taskId = self?._backgroundRecordingID {
//                        UIApplication.sharedApplication().endBackgroundTask(taskId)
//                    }
//                    self?._backgroundRecordingID = UIBackgroundTaskInvalid
//                }
//            }
//            UIApplication.sharedApplication().idleTimerDisabled = true
//            self.capturePipeline.startRecordingWithUrl(<#T##recordingURL: NSURL!##NSURL!#>)
//            self.capturePipeline.startRecording()
//            _recording = true
//            return true
//        }
//    }

    
    func recordingStopped() {
        recording = false
        UIApplication.sharedApplication().idleTimerDisabled = false
        UIApplication.sharedApplication().endBackgroundTask(self._backgroundRecordingID)
        _backgroundRecordingID = UIBackgroundTaskInvalid      
    }
    
    
    func deviceOrientationDidChange() {
        let orientation = UIDevice.currentDevice().orientation
        if orientation.isPortrait || orientation.isLandscape {
            self.capturePipeline.recordingOrientation = AVCaptureVideoOrientation(rawValue: orientation.rawValue)!
        }
    }
    
    
    
    // MARK - LLCapturePipelineDelegate
   
   
   public func capturePipelineDidStartRunning(capturePipeline: LLCapturePipeline) {
       self.onSessionStarted?(self)
   }
   
    public func capturePipeline(capturePipeline: LLCapturePipeline, didStopRunningWithError: NSError) {
    }

    public func capturePipeline(capturePipeline: LLCapturePipeline, previewPixelBufferReadyForDisplay: CVPixelBufferRef) {
        guard _allowedToUseGPU else {
            return
        }
        
        _currentPixelBuffer = previewPixelBufferReadyForDisplay
    }
    
    public func capturePipelineDidRunOutOfPreviewBuffers(capturePipeline: LLCapturePipeline) {
        if _allowedToUseGPU {
//            [self.previewView flushPixelBufferCache];
        }
    }

    
    public func capturePipelineRecordingDidStart(capturePipeline: LLCapturePipeline)  {
    }
    
    public func capturePipelineRecordingWillStop(capturePipeline: LLCapturePipeline) {
    }
   
   public func capturePipelineRecordingDidStop(capturePipeline: LLCapturePipeline, outputURL: NSURL) {
      self.recordingStopped()
      self.didRecord?(self, outputURL, nil)
   }
   
    public func capturePipeline(capturePipeline: LLCapturePipeline, recordingDidFailWithError: NSError) {
        self.recordingStopped()
//        [self showError:error];
    }

    // MARK - static methods
    
    public class func requestCameraPermission(completionBlock: (Bool -> Void)?) {
        if AVCaptureDevice.respondsToSelector(Selector("requestAccessForMediaType: completionHandler:")) {
            AVCaptureDevice.requestAccessForMediaType(AVMediaTypeVideo, completionHandler: { (granted) -> Void in
                dispatch_async(dispatch_get_main_queue()) { () -> Void in
                    completionBlock?(granted)
                }
            })
        } else {
            completionBlock?(true)
        }
    }
   
    public class func requestMicrophonePermission(completionBlock: (Bool -> Void)?) {
        if AVAudioSession.sharedInstance().respondsToSelector(Selector("requestRecordPermission:")) {
            AVAudioSession.sharedInstance().requestRecordPermission({ (granted) -> Void in
                dispatch_async(dispatch_get_main_queue()) { () -> Void in
                    completionBlock?(granted)
                }
            })
        }
    }
    
    
    
    
    
    /**
    * Camera flash mode.
    */
    
    
    
    public func startRecordingWithOutputUrl(url: NSURL) -> Bool {
        // check if video is enabled
        if !self.videoEnabled {
            self.onError?(self, LLSimpleCameraError.VideoNotEnabled)
            return false;
        }
        
        if self.flash == CameraFlashOn {
            self.enableTorch(true)
        }
        
        self.capturePipeline.startRecordingWithUrl(url)
         recording = true

        return true;
    }
    
    public func stopRecording(completionBlock: ((LLCameraViewController, NSURL, NSError?) -> Void)?) {
        if !self.videoEnabled {
            return;
        }
        
        self.didRecord = completionBlock
        self.capturePipeline.stopRecording()
    }
    
    public func toggleCamera() -> CameraPosition {
        return self.capturePipeline.toggleCamera()
    }
    
    
    public func enableTorch(enabled: Bool) {
        self.capturePipeline.enableTorch(enabled)
    }
    
    // TODO: Implement this later
//    func updateFlashMode(cameraFlash: CameraFlash) -> Bool {
//        
//    }
//    
    
    func isFlashAvailable() -> Bool {
        return self.capturePipeline.isFlashAvailable()
    }
    
    
    func isTorchAvailable() -> Bool {
        return self.capturePipeline.isTorchAvailable()
    }
    
}