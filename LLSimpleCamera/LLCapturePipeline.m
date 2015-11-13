
/*
     File: LLCapturePipeline.m
 Abstract: The class that creates and manages the AVCaptureSession
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

#import "LLCapturePipeline.h"
#import "LLMovieRecorder.h"
#import "LLRenderer.h"


@import UIKit;
@import CoreMedia;
@import AssetsLibrary;
@import ImageIO;


#import <CoreMedia/CMBufferQueue.h>
#import <CoreMedia/CMAudioClock.h>
#import <AssetsLibrary/AssetsLibrary.h>
#import <ImageIO/CGImageProperties.h>

#import <LLSimpleCamera/LLSimpleCamera-Swift.h>
#include <objc/runtime.h> // for objc_loadWeak() and objc_storeWeak()

/*
 RETAINED_BUFFER_COUNT is the number of pixel buffers we expect to hold on to from the renderer. This value informs the renderer how to size its buffer pool and how many pixel buffers to preallocate (done in the prepareWithOutputDimensions: method). Preallocation helps to lessen the chance of frame drops in our recording, in particular during recording startup. If we try to hold on to more buffers than RETAINED_BUFFER_COUNT then the renderer will fail to allocate new buffers from its pool and we will drop frames.

 A back of the envelope calculation to arrive at a RETAINED_BUFFER_COUNT of '6':
 - The preview path only has the most recent frame, so this makes the movie recording path the long pole.
 - The movie recorder internally does a dispatch_async to avoid blocking the caller when enqueuing to its internal asset writer.
 - Allow 2 frames of latency to cover the dispatch_async and the -[AVAssetWriterInput appendSampleBuffer:] call.
 - Then we allow for the encoder to retain up to 4 frames. Two frames are retained while being encoded/format converted, while the other two are to handle encoder format conversion pipelining and encoder startup latency.

 Really you need to test and measure the latency in your own application pipeline to come up with an appropriate number. 1080p BGRA buffers are quite large, so it's a good idea to keep this number as low as possible.
 */

#define RETAINED_BUFFER_COUNT 6

#define RECORD_AUDIO 0

#define LOG_STATUS_TRANSITIONS 0

typedef NS_ENUM( NSInteger, LLRecordingStatus )
{
	LLRecordingStatusIdle = 0,
	LLRecordingStatusStartingRecording,
	LLRecordingStatusRecording,
	LLRecordingStatusStoppingRecording,
}; // internal state machine

@interface LLCapturePipeline () <AVCaptureAudioDataOutputSampleBufferDelegate, AVCaptureVideoDataOutputSampleBufferDelegate, MovieRecorderDelegate>


@property (nonatomic, weak) id <LLCapturePipelineDelegate> _delegate;
@property (nonatomic) dispatch_queue_t _delegateCallbackQueue;

@property (nonatomic) NSMutableArray *_previousSecondTimestamps;

@property (nonatomic) AVCaptureSession *_captureSession;
@property (nonatomic) AVCaptureDevice *_videoDevice;
@property (nonatomic) AVCaptureConnection *_audioConnection;
@property (nonatomic) AVCaptureConnection *_videoConnection;
@property (nonatomic) BOOL _running;
@property (nonatomic) BOOL _startCaptureSessionOnEnteringForeground;
@property (nonatomic) id _applicationWillEnterForegroundNotificationObserver;
@property (nonatomic) NSDictionary *_videoCompressionSettings;
@property (nonatomic) NSDictionary *_audioCompressionSettings;

@property (nonatomic) dispatch_queue_t _sessionQueue;
@property (nonatomic) dispatch_queue_t _videoDataOutputQueue;

@property (nonatomic) BOOL _renderingEnabled;
@property (nonatomic) BOOL transitioningRenderer;

@property (nonatomic) NSURL *_recordingURL;
@property (nonatomic) LLRecordingStatus _recordingStatus;

@property (nonatomic) UIBackgroundTaskIdentifier _pipelineRunningTask;


@property(nonatomic, retain) __attribute__((NSObject)) CVPixelBufferRef currentPreviewPixelBuffer;

@property(readwrite) float videoFrameRate;
@property(readwrite) CMVideoDimensions videoDimensions;
@property(nonatomic, readwrite) AVCaptureVideoOrientation videoOrientation;

@property(nonatomic, retain) __attribute__((NSObject)) CMFormatDescriptionRef outputVideoFormatDescription;
@property(nonatomic, retain) __attribute__((NSObject)) CMFormatDescriptionRef outputAudioFormatDescription;
@property(nonatomic, retain) MovieRecorder *recorder;

@end

@implementation LLCapturePipeline


- (instancetype)init:(id<LLRenderer>)renderer
{
	self = [super init];
	if ( self )
	{
        _renderer = renderer;
        self._previousSecondTimestamps = @[].mutableCopy;
		self.recordingOrientation = (AVCaptureVideoOrientation)UIDeviceOrientationPortrait;
		
		self._sessionQueue = dispatch_queue_create( "com.apple.sample.capturepipeline.session", DISPATCH_QUEUE_SERIAL );
		
		// In a multi-threaded producer consumer system it's generally a good idea to make sure that producers do not get starved of CPU time by their consumers.
		// In this app we start with VideoDataOutput frames on a high priority queue, and downstream consumers use default priority queues.
		// Audio uses a default priority queue because we aren't monitoring it live and just want to get it into the movie.
		// AudioDataOutput can tolerate more latency than VideoDataOutput as its buffers aren't allocated out of a fixed size pool.
		self._videoDataOutputQueue = dispatch_queue_create( "com.apple.sample.capturepipeline.video", DISPATCH_QUEUE_SERIAL );
		dispatch_set_target_queue( self._videoDataOutputQueue, dispatch_get_global_queue( DISPATCH_QUEUE_PRIORITY_HIGH, 0 ) );
		
		self._pipelineRunningTask = UIBackgroundTaskInvalid;
	}
	return self;
}

- (void)dealloc
{
    self._delegate = nil;

	if ( _currentPreviewPixelBuffer ) {
		CFRelease( _currentPreviewPixelBuffer );
	}

	[self teardownCaptureSession];
	
	
	if ( _outputVideoFormatDescription ) {
		CFRelease( _outputVideoFormatDescription );
	}
	
	if ( _outputAudioFormatDescription ) {
		CFRelease( _outputAudioFormatDescription );
	}
}

#pragma mark Delegate

- (void)setDelegate:(id<LLCapturePipelineDelegate>)delegate callbackQueue:(dispatch_queue_t)delegateCallbackQueue // delegate is weak referenced
{
	if ( delegate && ( delegateCallbackQueue == NULL ) ) {
		@throw [NSException exceptionWithName:NSInvalidArgumentException reason:@"Caller must provide a delegateCallbackQueue" userInfo:nil];
	}
	
	@synchronized( self )
	{
        self._delegate = delegate;
        self._delegateCallbackQueue = delegateCallbackQueue;
	}
}

- (id<LLCapturePipelineDelegate>)delegate
{
    return self._delegate;
}

- (void)setRenderer:(id<LLRenderer>)renderer {
    if (renderer == _renderer) {
        return;
    }
    
    if (self._running) {
        _transitioningRenderer = true;
        
        if ([renderer inputPixelFormat] != [_renderer inputPixelFormat]) {
            [self stopRunning];
            _renderer = renderer;
            [self startRunning];
        } else {
            self.outputVideoFormatDescription = nil;
            _renderer = renderer;
        }
        
        
        _transitioningRenderer = false;
    } else {
       _renderer = renderer;
    }
    
    
}

#pragma mark Capture Session

- (void)startRunning
{
	dispatch_sync( self._sessionQueue, ^{
		[self setupCaptureSession];
		
		[self._captureSession startRunning];
		self._running = YES;
	} );
}

- (void)stopRunning
{
	dispatch_sync( self._sessionQueue, ^{
		self._running = NO;
		
		// the captureSessionDidStopRunning method will stop recording if necessary as well, but we do it here so that the last video and audio samples are better aligned
		[self stopRecording]; // does nothing if we aren't currently recording
		
		[self._captureSession stopRunning];
		
		[self captureSessionDidStopRunning];
		
		[self teardownCaptureSession];
	} );
}

- (void)setupCaptureSession
{
	if ( self._captureSession ) {
		return;
	}
	
	self._captureSession = [[AVCaptureSession alloc] init];

	[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(captureSessionNotification:) name:nil object:self._captureSession];
	self._applicationWillEnterForegroundNotificationObserver = [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationWillEnterForegroundNotification object:[UIApplication sharedApplication] queue:nil usingBlock:^(NSNotification *note) {
		// Retain self while the capture session is alive by referencing it in this observer block which is tied to the session lifetime
		// Client must stop us running before we can be deallocated
		[self applicationWillEnterForeground];
	}];
	
#if RECORD_AUDIO
	/* Audio */
	AVCaptureDevice *audioDevice = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeAudio];
	AVCaptureDeviceInput *audioIn = [[AVCaptureDeviceInput alloc] initWithDevice:audioDevice error:nil];
	if ( [_captureSession canAddInput:audioIn] ) {
		[_captureSession addInput:audioIn];
	}
	[audioIn release];
	
	AVCaptureAudioDataOutput *audioOut = [[AVCaptureAudioDataOutput alloc] init];
	// Put audio on its own queue to ensure that our video processing doesn't cause us to drop audio
	dispatch_queue_t audioCaptureQueue = dispatch_queue_create( "com.apple.sample.capturepipeline.audio", DISPATCH_QUEUE_SERIAL );
	[audioOut setSampleBufferDelegate:self queue:audioCaptureQueue];
	[audioCaptureQueue release];
	
	if ( [_captureSession canAddOutput:audioOut] ) {
		[_captureSession addOutput:audioOut];
	}
	_audioConnection = [audioOut connectionWithMediaType:AVMediaTypeAudio];
	[audioOut release];
#endif // RECORD_AUDIO
	
	/* Video */

    AVCaptureDevice *videoDevice = nil;
    if (self.cameraPosition == CameraPositionBack) {
        videoDevice = [self cameraWithPosition:AVCaptureDevicePositionBack];
    } else if (self.cameraPosition == CameraPositionFront) {
        videoDevice = [self cameraWithPosition:AVCaptureDevicePositionFront];
    }
    
    if (videoDevice == nil) {
        videoDevice = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo];
    }
    
	self._videoDevice = videoDevice;
	AVCaptureDeviceInput *videoIn = [[AVCaptureDeviceInput alloc] initWithDevice:videoDevice error:nil];
	if ( [self._captureSession canAddInput:videoIn] ) {
		[self._captureSession addInput:videoIn];
	}
	
	AVCaptureVideoDataOutput *videoOut = [[AVCaptureVideoDataOutput alloc] init];

    videoOut.videoSettings = @{ (id)kCVPixelBufferPixelFormatTypeKey : @(self.renderer.inputPixelFormat) };
	[videoOut setSampleBufferDelegate:self queue:self._videoDataOutputQueue];
	
	// LL records videos and we prefer not to have any dropped frames in the video recording.
	// By setting alwaysDiscardsLateVideoFrames to NO we ensure that minor fluctuations in system load or in our processing time for a given frame won't cause framedrops.
	// We do however need to ensure that on average we can process frames in realtime.
	// If we were doing preview only we would probably want to set alwaysDiscardsLateVideoFrames to YES.
	videoOut.alwaysDiscardsLateVideoFrames = NO;
	
	if ( [self._captureSession canAddOutput:videoOut] ) {
		[self._captureSession addOutput:videoOut];
	}
	self._videoConnection = [videoOut connectionWithMediaType:AVMediaTypeVideo];
		
	int frameRate;
	NSString *sessionPreset = AVCaptureSessionPresetHigh;
	CMTime frameDuration = kCMTimeInvalid;
	// For single core systems like iPhone 4 and iPod Touch 4th Generation we use a lower resolution and framerate to maintain real-time performance.
	if ( [NSProcessInfo processInfo].processorCount == 1 )
	{
		if ( [self._captureSession canSetSessionPreset:AVCaptureSessionPreset640x480] ) {
			sessionPreset = AVCaptureSessionPreset640x480;
		}
		frameRate = 15;
	}
	else
	{
#if ! USE_OPENGL_RENDERER
		// When using the CPU renderers or the CoreImage renderer we lower the resolution to 720p so that all devices can maintain real-time performance (this is primarily for A5 based devices like iPhone 4s and iPod Touch 5th Generation).
		if ( [self._captureSession canSetSessionPreset:AVCaptureSessionPreset1280x720] ) {
			sessionPreset = AVCaptureSessionPreset1280x720;
		}
#endif // ! USE_OPENGL_RENDERER

		frameRate = 30;
	}
	
	self._captureSession.sessionPreset = sessionPreset;
	
	frameDuration = CMTimeMake( 1, frameRate );

	NSError *error = nil;
	if ( [videoDevice lockForConfiguration:&error] ) {
		videoDevice.activeVideoMaxFrameDuration = frameDuration;
		videoDevice.activeVideoMinFrameDuration = frameDuration;
		[videoDevice unlockForConfiguration];
	}
	else {
		NSLog( @"videoDevice lockForConfiguration returned error %@", error );
	}

	// Get the recommended compression settings after configuring the session/device.
#if RECORD_AUDIO
	_audioCompressionSettings = [[audioOut recommendedAudioSettingsForAssetWriterWithOutputFileType:AVFileTypeQuickTimeMovie] copy];
#endif
	self._videoCompressionSettings = [[videoOut recommendedVideoSettingsForAssetWriterWithOutputFileType:AVFileTypeQuickTimeMovie] copy];
	
	self.videoOrientation = self._videoConnection.videoOrientation;
	
	return;
}


/// Find a camera with the specified AVCaptureDevicePosition, returning nil if one is not found
- (AVCaptureDevice *) cameraWithPosition:(AVCaptureDevicePosition) position
{
    NSArray *devices = [AVCaptureDevice devicesWithMediaType:AVMediaTypeVideo];
    for (AVCaptureDevice *device in devices) {
        if (device.position == position) return device;
    }
    return nil;
}

- (CameraPosition) toggleCamera {
    if (self.cameraPosition == CameraPositionBack) {
        self.cameraPosition = CameraPositionFront;
    }
    else {
        self.cameraPosition = CameraPositionBack;
    }
    
    return self.cameraPosition;
}


- (void)setCameraPosition:(CameraPosition)cameraPosition {
    if (self.cameraPosition == cameraPosition) {
        return;
    }
    
    if (self._running) {
        if ((self._videoDevice.position == AVCaptureDevicePositionBack &&
            cameraPosition == CameraPositionBack) ||
            (self._videoDevice.position == AVCaptureDevicePositionFront &&
             cameraPosition == CameraPositionFront)) {
                return;
            }
        [self stopRunning];
        _cameraPosition = cameraPosition;
        [self startRunning];
    } else {
        _cameraPosition = cameraPosition;
    }
}

- (CameraFlash) flash {

    if(self._videoDevice.flashMode == AVCaptureFlashModeAuto) {
        return CameraFlashAuto;
    }
    else if(self._videoDevice.flashMode == AVCaptureFlashModeOn) {
        return CameraFlashOn;
    }
    else if(self._videoDevice.flashMode == AVCaptureFlashModeOff) {
        return CameraFlashOff;
    }
    else {
        return CameraFlashOff;
    }

}

- (BOOL)isFlashAvailable {
    return self._videoDevice.hasFlash && self._videoDevice.isFlashAvailable;
}


- (BOOL)isTorchAvailable {
    return self._videoDevice.hasTorch && self._videoDevice.isTorchAvailable;
}


- (void)enableTorch:(BOOL)enabled {
    // check if the device has a toch, otherwise don't even bother to take any action.
    if([self isTorchAvailable]) {
        [self._captureSession beginConfiguration];
        [self._videoDevice lockForConfiguration:nil];
        if (enabled) {
            [self._videoDevice setTorchMode:AVCaptureTorchModeOn];
        } else {
            [self._videoDevice setTorchMode:AVCaptureTorchModeOff];
        }
        [self._videoDevice unlockForConfiguration];
        [self._captureSession commitConfiguration];
    }

}


- (void)teardownCaptureSession
{
	if ( self._captureSession )
	{
		[[NSNotificationCenter defaultCenter] removeObserver:self name:nil object:self._captureSession];
		
		[[NSNotificationCenter defaultCenter] removeObserver:self._applicationWillEnterForegroundNotificationObserver];
		self._applicationWillEnterForegroundNotificationObserver = nil;
		
		self._captureSession = nil;
		self._videoCompressionSettings = nil;
		self._audioCompressionSettings = nil;
	}
}

- (void)captureSessionNotification:(NSNotification *)notification
{
	dispatch_async( self._sessionQueue, ^{
		
		if ( [notification.name isEqualToString:AVCaptureSessionWasInterruptedNotification] )
		{
			NSLog( @"session interrupted" );
			
			[self captureSessionDidStopRunning];
		}
		else if ( [notification.name isEqualToString:AVCaptureSessionInterruptionEndedNotification] )
		{
			NSLog( @"session interruption ended" );
		}
		else if ( [notification.name isEqualToString:AVCaptureSessionRuntimeErrorNotification] )
		{
			[self captureSessionDidStopRunning];
			
			NSError *error = notification.userInfo[AVCaptureSessionErrorKey];
			if ( error.code == AVErrorDeviceIsNotAvailableInBackground )
			{
				NSLog( @"device not available in background" );

				// Since we can't resume running while in the background we need to remember this for next time we come to the foreground
				if ( self._running ) {
					self._startCaptureSessionOnEnteringForeground = YES;
				}
			}
			else if ( error.code == AVErrorMediaServicesWereReset )
			{
				NSLog( @"media services were reset" );
				[self handleRecoverableCaptureSessionRuntimeError:error];
			}
			else
			{
				[self handleNonRecoverableCaptureSessionRuntimeError:error];
			}
		}
		else if ( [notification.name isEqualToString:AVCaptureSessionDidStartRunningNotification] )
		{
			NSLog( @"session started running" );
            [self._delegate capturePipelineDidStartRunning:self];
		}
		else if ( [notification.name isEqualToString:AVCaptureSessionDidStopRunningNotification] )
		{
			NSLog( @"session stopped running" );
		}
	} );
}

- (void)handleRecoverableCaptureSessionRuntimeError:(NSError *)error
{
	if ( self._running ) {
		[self._captureSession startRunning];
	}
}

- (void)handleNonRecoverableCaptureSessionRuntimeError:(NSError *)error
{
	NSLog( @"fatal runtime error %@, code %i", error, (int)error.code );
	
	self._running = NO;
	[self teardownCaptureSession];
	
	@synchronized( self ) 
	{
		if ( self.delegate ) {
			dispatch_async( self._delegateCallbackQueue, ^{
				@autoreleasepool {
					[self.delegate capturePipeline:self didStopRunningWithError:error];
				}
			});
		}
	}
}

- (void)captureSessionDidStopRunning
{
	[self stopRecording]; // does nothing if we aren't currently recording
	[self teardownVideoPipeline];
}

- (void)applicationWillEnterForeground
{
	NSLog( @"-[%@ %@] called", NSStringFromClass([self class]), NSStringFromSelector(_cmd) );
	
	dispatch_sync( self._sessionQueue, ^{
		if ( self._startCaptureSessionOnEnteringForeground ) {
			NSLog( @"-[%@ %@] manually restarting session", NSStringFromClass([self class]), NSStringFromSelector(_cmd) );
			
			self._startCaptureSessionOnEnteringForeground = NO;
			if ( self._running ) {
				[self._captureSession startRunning];
			}
		}
	} );
}

#pragma mark Capture Pipeline

- (void)setupVideoPipelineWithInputFormatDescription:(CMFormatDescriptionRef)inputFormatDescription
{
	NSLog( @"-[%@ %@] called", NSStringFromClass([self class]), NSStringFromSelector(_cmd) );
    [self videoPipelineWillStartRunning];
	
	self.videoDimensions = CMVideoFormatDescriptionGetDimensions( inputFormatDescription );
	[self.renderer prepareForInputWithFormatDescription:inputFormatDescription outputRetainedBufferCountHint:RETAINED_BUFFER_COUNT];
	
	if ( ! self.renderer.operatesInPlace && [self.renderer respondsToSelector:@selector(outputFormatDescription)] ) {
		self.outputVideoFormatDescription = self.renderer.outputFormatDescription;
	}
	else {
		self.outputVideoFormatDescription = inputFormatDescription;
	}
}

// synchronous, blocks until the pipeline is drained, don't call from within the pipeline
- (void)teardownVideoPipeline
{
	// The session is stopped so we are guaranteed that no new buffers are coming through the video data output.
	// There may be inflight buffers on _videoDataOutputQueue however.
	// Synchronize with that queue to guarantee no more buffers are in flight.
	// Once the pipeline is drained we can tear it down safely.

	NSLog( @"-[%@ %@] called", NSStringFromClass([self class]), NSStringFromSelector(_cmd) );
	
	dispatch_sync( self._videoDataOutputQueue, ^{
		if ( ! self.outputVideoFormatDescription ) {
			return;
		}
		
		[self.renderer reset];
        [self videoPipelineDidFinishRunning];
        self.outputVideoFormatDescription = nil;
		self.currentPreviewPixelBuffer = NULL;
		
		NSLog( @"-[%@ %@] finished teardown", NSStringFromClass([self class]), NSStringFromSelector(_cmd) );
		
	} );
}

- (void)videoPipelineWillStartRunning
{
	NSLog( @"-[%@ %@] called", NSStringFromClass([self class]), NSStringFromSelector(_cmd) );
	
    if (self._pipelineRunningTask != UIBackgroundTaskInvalid) {
        return;
    }
	NSAssert( self._pipelineRunningTask == UIBackgroundTaskInvalid, @"should not have a background task active before the video pipeline starts running" );
	
	self._pipelineRunningTask = [[UIApplication sharedApplication] beginBackgroundTaskWithExpirationHandler:^{
		NSLog( @"video capture pipeline background task expired" );
	}];
}

- (void)videoPipelineDidFinishRunning
{
	NSLog( @"-[%@ %@] called", NSStringFromClass([self class]), NSStringFromSelector(_cmd) );
	
	NSAssert( self._pipelineRunningTask != UIBackgroundTaskInvalid, @"should have a background task active when the video pipeline finishes running" );
	
	[[UIApplication sharedApplication] endBackgroundTask:self._pipelineRunningTask];
	self._pipelineRunningTask = UIBackgroundTaskInvalid;
}

// call under @synchronized( self )
- (void)videoPipelineDidRunOutOfBuffers
{
	// We have run out of buffers.
	// Tell the delegate so that it can flush any cached buffers.
	if ( self.delegate ) {
		dispatch_async( self._delegateCallbackQueue, ^{
			@autoreleasepool {
				[self.delegate capturePipelineDidRunOutOfPreviewBuffers:self];
			}
		} );
	}
}

- (void)setRenderingEnabled:(BOOL)renderingEnabled
{
	@synchronized( self.renderer ) {
		self._renderingEnabled = renderingEnabled;
	}
}

- (BOOL)renderingEnabled
{
	@synchronized( self.renderer ) {
		return self._renderingEnabled;
	}
}

// call under @synchronized( self )
- (void)outputPreviewPixelBuffer:(CVPixelBufferRef)previewPixelBuffer
{
	if ( self.delegate )
	{
		// Keep preview latency low by dropping stale frames that have not been picked up by the delegate yet
		self.currentPreviewPixelBuffer = previewPixelBuffer;
		
		dispatch_async( self._delegateCallbackQueue, ^{
			@autoreleasepool
			{
				CVPixelBufferRef currentPreviewPixelBuffer = NULL;
				@synchronized( self )
				{
					currentPreviewPixelBuffer = self.currentPreviewPixelBuffer;
					if ( currentPreviewPixelBuffer ) {
						CFRetain( currentPreviewPixelBuffer );
						self.currentPreviewPixelBuffer = NULL;
					}
				}
				
				if ( currentPreviewPixelBuffer ) {
					[self.delegate capturePipeline:self previewPixelBufferReadyForDisplay:currentPreviewPixelBuffer];
					CFRelease( currentPreviewPixelBuffer );
				}
			}
		} );
	}
}

- (void)captureOutput:(AVCaptureOutput *)captureOutput didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer fromConnection:(AVCaptureConnection *)connection
{
    if (_transitioningRenderer) {
        return;
    }
    
	CMFormatDescriptionRef formatDescription = CMSampleBufferGetFormatDescription( sampleBuffer );
	
	if ( connection == self._videoConnection )
	{
		if ( self.outputVideoFormatDescription == nil ) {
			// Don't render the first sample buffer.
			// This gives us one frame interval (33ms at 30fps) for setupVideoPipelineWithInputFormatDescription: to complete.
			// Ideally this would be done asynchronously to ensure frames don't back up on slower devices.
			[self setupVideoPipelineWithInputFormatDescription:formatDescription];
		}
		else {
			[self renderVideoSampleBuffer:sampleBuffer];
		}
	}
	else if ( connection == self._audioConnection )
	{
		self.outputAudioFormatDescription = formatDescription;
		
		@synchronized( self ) {
			if ( self._recordingStatus == LLRecordingStatusRecording ) {
				[self.recorder appendAudioSampleBuffer:sampleBuffer];
			}
		}
	}
}

- (void)renderVideoSampleBuffer:(CMSampleBufferRef)sampleBuffer
{
    CVPixelBufferRef renderedPixelBuffer = NULL, sourcePixelBuffer;
	CMTime timestamp = CMSampleBufferGetPresentationTimeStamp( sampleBuffer );
	
	[self calculateFramerateAtTimestamp:timestamp];

    // We must not use the GPU while running in the background.
	// setRenderingEnabled: takes the same lock so the caller can guarantee no GPU usage once the setter returns.
	@synchronized( self.renderer )
	{
		if ( self._renderingEnabled ) {
			sourcePixelBuffer = CMSampleBufferGetImageBuffer( sampleBuffer );
			renderedPixelBuffer = [self.renderer copyRenderedPixelBuffer:sourcePixelBuffer];
		}
		else {
			return;
		}
	}
	
	@synchronized( self )
	{
		if ( renderedPixelBuffer )
		{
			[self outputPreviewPixelBuffer:renderedPixelBuffer];
//			[self outputPreviewPixelBuffer:sourcePixelBuffer];
			if ( self._recordingStatus == LLRecordingStatusRecording ) {
				[self.recorder appendVideoPixelBuffer:renderedPixelBuffer withPresentationTime:timestamp];
			}
			
			CFRelease( renderedPixelBuffer );
		}
		else
		{
			[self videoPipelineDidRunOutOfBuffers];
		}
	}
}

#pragma mark Recording

- (void)startRecordingWithUrl:(NSURL *)recordingURL {
    
    self._recordingURL = recordingURL;
	@synchronized( self )
	{
		if ( self._recordingStatus != LLRecordingStatusIdle ) {
			@throw [NSException exceptionWithName:NSInternalInconsistencyException reason:@"Already recording" userInfo:nil];
			return;
		}
		
		[self transitionToRecordingStatus:LLRecordingStatusStartingRecording error:nil];
	}
	
    MovieRecorder *recorder = [[MovieRecorder alloc] initWithURL:self._recordingURL];
	
#if RECORD_AUDIO
	[recorder addAudioTrackWithSourceFormatDescription:self.outputAudioFormatDescription settings:_audioCompressionSettings];
#endif // RECORD_AUDIO
    
	CGAffineTransform videoTransform = [self transformFromVideoBufferOrientationToOrientation:self.recordingOrientation withAutoMirroring:NO]; // Front camera recording shouldn't be mirrored

	[recorder addVideoTrackWithSourceFormatDescription:self.outputVideoFormatDescription transform:videoTransform settings:self._videoCompressionSettings];
	
	dispatch_queue_t callbackQueue = dispatch_queue_create( "com.apple.sample.capturepipeline.recordercallback", DISPATCH_QUEUE_SERIAL ); // guarantee ordering of callbacks with a serial queue
	[recorder setDelegate:self callbackQueue:callbackQueue];
	self.recorder = recorder;
	
	[recorder prepareToRecord]; // asynchronous, will call us back with recorderDidFinishPreparing: or recorder:didFailWithError: when done
}

- (void)stopRecording
{
	@synchronized( self )
	{
		if ( self._recordingStatus != LLRecordingStatusRecording ) {
			return;
		}
		
		[self transitionToRecordingStatus:LLRecordingStatusStoppingRecording error:nil];
	}
	
	[self.recorder finishRecording]; // asynchronous, will call us back with recorderDidFinishRecording: or recorder:didFailWithError: when done
}

#pragma mark MovieRecorder Delegate

- (void)movieRecorderDidFinishPreparing:(MovieRecorder *)recorder
{
	@synchronized( self )
	{
		if ( self._recordingStatus != LLRecordingStatusStartingRecording ) {
			@throw [NSException exceptionWithName:NSInternalInconsistencyException reason:@"Expected to be in StartingRecording state" userInfo:nil];
			return;
		}
		
		[self transitionToRecordingStatus:LLRecordingStatusRecording error:nil];
	}
}

- (void)movieRecorder:(MovieRecorder *)recorder didFailWithError:(NSError *)error
{
	@synchronized( self ) {
		self.recorder = nil;
		[self transitionToRecordingStatus:LLRecordingStatusIdle error:error];
	}
}

- (void)movieRecorderDidFinishRecording:(MovieRecorder *)recorder
{
	@synchronized( self )
	{
		if ( self._recordingStatus != LLRecordingStatusStoppingRecording ) {
			@throw [NSException exceptionWithName:NSInternalInconsistencyException reason:@"Expected to be in StoppingRecording state" userInfo:nil];
			return;
		}
		
		// No state transition, we are still in the process of stopping.
		// We will be stopped once we save to the assets library.
	}
	
	self.recorder = nil;
    [self transitionToRecordingStatus:LLRecordingStatusIdle error:nil];
//
//	ALAssetsLibrary *library = [[ALAssetsLibrary alloc] init];
//	[library writeVideoAtPathToSavedPhotosAlbum:self._recordingURL completionBlock:^(NSURL *assetURL, NSError *error) {
//		
//		[[NSFileManager defaultManager] removeItemAtURL:self._recordingURL error:NULL];
//		
// 		@synchronized( self ) {
//			if ( self._recordingStatus != LLRecordingStatusStoppingRecording ) {
//				@throw [NSException exceptionWithName:NSInternalInconsistencyException reason:@"Expected to be in StoppingRecording state" userInfo:nil];
//				return;
//			}
//			[self transitionToRecordingStatus:LLRecordingStatusIdle error:error];
//		}
//	}];
}

#pragma mark Recording State Machine

// call under @synchonized( self )
- (void)transitionToRecordingStatus:(LLRecordingStatus)newStatus error:(NSError *)error
{
	SEL delegateSelector = NULL;
	LLRecordingStatus oldStatus = self._recordingStatus;
	self._recordingStatus = newStatus;
	
#if LOG_STATUS_TRANSITIONS
	NSLog( @"LLCapturePipeline recording state transition: %@->%@", [self stringForRecordingStatus:oldStatus], [self stringForRecordingStatus:newStatus] );
#endif
	
	if ( newStatus != oldStatus )
	{
		if ( error && ( newStatus == LLRecordingStatusIdle ) )
		{
			delegateSelector = @selector(capturePipeline:recordingDidFailWithError:);
		}
		else
		{
			error = nil; // only the above delegate method takes an error
			if ( ( oldStatus == LLRecordingStatusStartingRecording ) && ( newStatus == LLRecordingStatusRecording ) ) {
				delegateSelector = @selector(capturePipelineRecordingDidStart:);
			}
			else if ( ( oldStatus == LLRecordingStatusRecording ) && ( newStatus == LLRecordingStatusStoppingRecording ) ) {
				delegateSelector = @selector(capturePipelineRecordingWillStop:);
			}
			else if ( ( oldStatus == LLRecordingStatusStoppingRecording ) && ( newStatus == LLRecordingStatusIdle ) ) {
               delegateSelector = @selector(capturePipelineRecordingDidStop:outputURL:);
			}
		}
	}
	
	if ( delegateSelector && self.delegate )
	{
		dispatch_async( self._delegateCallbackQueue, ^{
			@autoreleasepool
			{
				if ( error ) {
					[self.delegate performSelector:delegateSelector withObject:self withObject:error];
				}
				else {
                   [self.delegate performSelector:delegateSelector withObject:self withObject:self._recordingURL];
//					[self.delegate performSelector:delegateSelector withObject:self];
				}
			}
		} );
	}
}

#if LOG_STATUS_TRANSITIONS

- (NSString *)stringForRecordingStatus:(LLRecordingStatus)status
{
	NSString *statusString = nil;
	
	switch ( status )
	{
		case LLRecordingStatusIdle:
			statusString = @"Idle";
			break;
		case LLRecordingStatusStartingRecording:
			statusString = @"StartingRecording";
			break;
		case LLRecordingStatusRecording:
			statusString = @"Recording";
			break;
		case LLRecordingStatusStoppingRecording:
			statusString = @"StoppingRecording";
			break;
		default:
			statusString = @"Unknown";
			break;
	}
	return statusString;
}

#endif // LOG_STATUS_TRANSITIONS

#pragma mark Utilities

// Auto mirroring: Front camera is mirrored; back camera isn't 
- (CGAffineTransform)transformFromVideoBufferOrientationToOrientation:(AVCaptureVideoOrientation)orientation withAutoMirroring:(BOOL)mirror
{
	CGAffineTransform transform = CGAffineTransformIdentity;
		
	// Calculate offsets from an arbitrary reference orientation (portrait)
	CGFloat orientationAngleOffset = angleOffsetFromPortraitOrientationToOrientation( orientation );
	CGFloat videoOrientationAngleOffset = angleOffsetFromPortraitOrientationToOrientation( self.videoOrientation );
	
	// Find the difference in angle between the desired orientation and the video orientation
	CGFloat angleOffset = orientationAngleOffset - videoOrientationAngleOffset;
	transform = CGAffineTransformMakeRotation( angleOffset );

	if ( self._videoDevice.position == AVCaptureDevicePositionFront )
	{
		if ( mirror ) {
			transform = CGAffineTransformScale( transform, -1, 1 );
		}
		else {
			if ( UIInterfaceOrientationIsPortrait( orientation ) ) {
				transform = CGAffineTransformRotate( transform, M_PI );
			}
		}
	}
	
	return transform;
}

static CGFloat angleOffsetFromPortraitOrientationToOrientation(AVCaptureVideoOrientation orientation)
{
	CGFloat angle = 0.0;
	
	switch ( orientation )
	{
		case AVCaptureVideoOrientationPortrait:
			angle = 0.0;
			break;
		case AVCaptureVideoOrientationPortraitUpsideDown:
			angle = M_PI;
			break;
		case AVCaptureVideoOrientationLandscapeRight:
			angle = -M_PI_2;
			break;
		case AVCaptureVideoOrientationLandscapeLeft:
			angle = M_PI_2;
			break;
		default:
			break;
	}
	
	return angle;
}

- (void)calculateFramerateAtTimestamp:(CMTime)timestamp
{
	[self._previousSecondTimestamps addObject:[NSValue valueWithCMTime:timestamp]];
	
	CMTime oneSecond = CMTimeMake( 1, 1 );
	CMTime oneSecondAgo = CMTimeSubtract( timestamp, oneSecond );
	
	while( CMTIME_COMPARE_INLINE( [self._previousSecondTimestamps[0] CMTimeValue], <, oneSecondAgo ) ) {
		[self._previousSecondTimestamps removeObjectAtIndex:0];
	}
	
	if ( [self._previousSecondTimestamps count] > 1 ) {
		const Float64 duration = CMTimeGetSeconds( CMTimeSubtract( [[self._previousSecondTimestamps lastObject] CMTimeValue], [self._previousSecondTimestamps[0] CMTimeValue] ) );
		const float newRate = (float)( [self._previousSecondTimestamps count] - 1 ) / duration;
		self.videoFrameRate = newRate;
	}
}

@end
