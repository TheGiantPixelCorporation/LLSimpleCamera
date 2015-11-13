
/*
     File: MovieRecorder.m
 Abstract: Real-time movie recorder which is totally non-blocking
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

#import "LLMovieRecorder.h"
@import AVFoundation;


#define LOG_STATUS_TRANSITIONS 0

typedef NS_ENUM( NSInteger, MovieRecorderStatus ) {
	MovieRecorderStatusIdle = 0,
	MovieRecorderStatusPreparingToRecord,
	MovieRecorderStatusRecording,
	MovieRecorderStatusFinishingRecordingPart1, // waiting for inflight buffers to be appended
	MovieRecorderStatusFinishingRecordingPart2, // calling finish writing on the asset writer
	MovieRecorderStatusFinished,	// terminal state
	MovieRecorderStatusFailed		// terminal state
}; // internal state machine


@interface MovieRecorder ()
{
}

@property (nonatomic, weak) id<MovieRecorderDelegate> _delegate;
@property (nonatomic)   NSURL *_URL;
@property (nonatomic)   dispatch_queue_t _delegateCallbackQueue;

@property (nonatomic)   MovieRecorderStatus _status;


@property (nonatomic)   dispatch_queue_t _writingQueue;

@property (nonatomic)   AVAssetWriter *_assetWriter;
@property (nonatomic)   BOOL _haveStartedSession;

@property (nonatomic)   CMFormatDescriptionRef _audioTrackSourceFormatDescription;
@property (nonatomic)   NSDictionary *_audioTrackSettings;
@property (nonatomic)   AVAssetWriterInput *_audioInput;

@property (nonatomic)   CMFormatDescriptionRef _videoTrackSourceFormatDescription;
@property (nonatomic)   CGAffineTransform _videoTrackTransform;
@property (nonatomic)   NSDictionary *_videoTrackSettings;
@property (nonatomic)   AVAssetWriterInput *_videoInput;

@end

@implementation MovieRecorder

#pragma mark -
#pragma mark API

- (instancetype)initWithURL:(NSURL *)URL
{
	if ( ! URL ) {
		return nil;
	}
	
	self = [super init];
	if ( self ) {
		self._writingQueue = dispatch_queue_create( "com.apple.sample.movierecorder.writing", DISPATCH_QUEUE_SERIAL );
		self._videoTrackTransform = CGAffineTransformIdentity;
        self._URL = URL;
	}
	return self;
}

- (void)addVideoTrackWithSourceFormatDescription:(CMFormatDescriptionRef)formatDescription transform:(CGAffineTransform)transform settings:(NSDictionary *)videoSettings
{
	if ( formatDescription == NULL ) {
		@throw [NSException exceptionWithName:NSInvalidArgumentException reason:@"NULL format description" userInfo:nil];
		return;			
	}
	
	@synchronized( self )
	{
		if ( self._status != MovieRecorderStatusIdle ) {
			@throw [NSException exceptionWithName:NSInternalInconsistencyException reason:@"Cannot add tracks while not idle" userInfo:nil];
			return;
		}
		
		if ( self._videoTrackSourceFormatDescription ) {
			@throw [NSException exceptionWithName:NSInternalInconsistencyException reason:@"Cannot add more than one video track" userInfo:nil];
			return;
		}
		
		self._videoTrackSourceFormatDescription = (CMFormatDescriptionRef)CFRetain( formatDescription );
		self._videoTrackTransform = transform;
		self._videoTrackSettings = [videoSettings copy];
	}
}

- (void)addAudioTrackWithSourceFormatDescription:(CMFormatDescriptionRef)formatDescription settings:(NSDictionary *)audioSettings
{
	if ( formatDescription == NULL ) {
		@throw [NSException exceptionWithName:NSInvalidArgumentException reason:@"NULL format description" userInfo:nil];
		return;			
	}
	
	@synchronized( self )
	{
		if ( self._status != MovieRecorderStatusIdle ) {
			@throw [NSException exceptionWithName:NSInternalInconsistencyException reason:@"Cannot add tracks while not idle" userInfo:nil];
			return;
		}
		
		if ( self._audioTrackSourceFormatDescription ) {
			@throw [NSException exceptionWithName:NSInternalInconsistencyException reason:@"Cannot add more than one audio track" userInfo:nil];
			return;
		}
		
		self._audioTrackSourceFormatDescription = (CMFormatDescriptionRef)CFRetain( formatDescription );
		self._audioTrackSettings = [audioSettings copy];
	}
}

- (id<MovieRecorderDelegate>)delegate {
    return self._delegate;
}

- (void)setDelegate:(id<MovieRecorderDelegate>)delegate callbackQueue:(dispatch_queue_t)delegateCallbackQueue; {
	if ( delegate && ( delegateCallbackQueue == NULL ) ) {
		@throw [NSException exceptionWithName:NSInvalidArgumentException reason:@"Caller must provide a delegateCallbackQueue" userInfo:nil];
	}
	
	@synchronized( self )
	{
        self._delegate = delegate;
        self._delegateCallbackQueue = delegateCallbackQueue;
	}
}

- (void)prepareToRecord
{
	@synchronized( self )
	{
		if ( self._status != MovieRecorderStatusIdle ) {
			@throw [NSException exceptionWithName:NSInternalInconsistencyException reason:@"Already prepared, cannot prepare again" userInfo:nil];
			return;
		}
		
		[self transitionToStatus:MovieRecorderStatusPreparingToRecord error:nil];
	}
	
	dispatch_async( dispatch_get_global_queue( DISPATCH_QUEUE_PRIORITY_LOW, 0 ), ^{
		
		@autoreleasepool
		{
			NSError *error = nil;
			// AVAssetWriter will not write over an existing file.
			[[NSFileManager defaultManager] removeItemAtURL:self._URL error:NULL];
			
			self._assetWriter = [[AVAssetWriter alloc] initWithURL:self._URL fileType:AVFileTypeQuickTimeMovie error:&error];
			
			// Create and add inputs
			if ( ! error && self._videoTrackSourceFormatDescription ) {
				[self setupAssetWriterVideoInputWithSourceFormatDescription:self._videoTrackSourceFormatDescription transform:self._videoTrackTransform settings:self._videoTrackSettings error:&error];
			}
			
			if ( ! error && self._audioTrackSourceFormatDescription ) {
				[self setupAssetWriterAudioInputWithSourceFormatDescription:self._audioTrackSourceFormatDescription settings:self._audioTrackSettings error:&error];
			}
			
			if ( ! error ) {
				BOOL success = [self._assetWriter startWriting];
				if ( ! success ) {
					error = self._assetWriter.error;
				}
			}
			
			@synchronized( self )
			{
				if ( error ) {
					[self transitionToStatus:MovieRecorderStatusFailed error:error];
				}
				else {
					[self transitionToStatus:MovieRecorderStatusRecording error:nil];
				}
			}
		}
	} );
}

- (void)appendVideoSampleBuffer:(CMSampleBufferRef)sampleBuffer
{
	[self appendSampleBuffer:sampleBuffer ofMediaType:AVMediaTypeVideo];
}

- (void)appendVideoPixelBuffer:(CVPixelBufferRef)pixelBuffer withPresentationTime:(CMTime)presentationTime
{
	CMSampleBufferRef sampleBuffer = NULL;
	
	CMSampleTimingInfo timingInfo = {0,};
	timingInfo.duration = kCMTimeInvalid;
	timingInfo.decodeTimeStamp = kCMTimeInvalid;
	timingInfo.presentationTimeStamp = presentationTime;
	
	OSStatus err = CMSampleBufferCreateForImageBuffer( kCFAllocatorDefault, pixelBuffer, true, NULL, NULL, self._videoTrackSourceFormatDescription, &timingInfo, &sampleBuffer );
	if ( sampleBuffer ) {
		[self appendSampleBuffer:sampleBuffer ofMediaType:AVMediaTypeVideo];
		CFRelease( sampleBuffer );
	}
	else {
		NSString *exceptionReason = [NSString stringWithFormat:@"sample buffer create failed (%i)", (int)err];
		@throw [NSException exceptionWithName:NSInvalidArgumentException reason:exceptionReason userInfo:nil];
		return;
	}
}

- (void)appendAudioSampleBuffer:(CMSampleBufferRef)sampleBuffer
{
	[self appendSampleBuffer:sampleBuffer ofMediaType:AVMediaTypeAudio];
}

- (void)finishRecording
{
	@synchronized( self )
	{
		BOOL shouldFinishRecording = NO;
		switch ( self._status )
		{
			case MovieRecorderStatusIdle:
			case MovieRecorderStatusPreparingToRecord:
			case MovieRecorderStatusFinishingRecordingPart1:
			case MovieRecorderStatusFinishingRecordingPart2:
			case MovieRecorderStatusFinished:
				@throw [NSException exceptionWithName:NSInternalInconsistencyException reason:@"Not recording" userInfo:nil];
				break;
			case MovieRecorderStatusFailed:
				// From the client's perspective the movie recorder can asynchronously transition to an error state as the result of an append.
				// Because of this we are lenient when finishRecording is called and we are in an error state.
				NSLog( @"Recording has failed, nothing to do" );
				break;
			case MovieRecorderStatusRecording:
				shouldFinishRecording = YES;
				break;
		}
		
		if ( shouldFinishRecording ) {
			[self transitionToStatus:MovieRecorderStatusFinishingRecordingPart1 error:nil];
		}
		else {
			return;
		}
	}
	
	dispatch_async( self._writingQueue, ^{
		
		@autoreleasepool
		{
			@synchronized( self )
			{
				// We may have transitioned to an error state as we appended inflight buffers. In that case there is nothing to do now.
				if ( self._status != MovieRecorderStatusFinishingRecordingPart1 ) {
					return;
				}
				
				// It is not safe to call -[AVAssetWriter finishWriting*] concurrently with -[AVAssetWriterInput appendSampleBuffer:]
				// We transition to MovieRecorderStatusFinishingRecordingPart2 while on _writingQueue, which guarantees that no more buffers will be appended.
				[self transitionToStatus:MovieRecorderStatusFinishingRecordingPart2 error:nil];
			}

			[self._assetWriter finishWritingWithCompletionHandler:^{
				@synchronized( self )
				{
					NSError *error = self._assetWriter.error;
					if ( error ) {
						[self transitionToStatus:MovieRecorderStatusFailed error:error];
					}
					else {
						[self transitionToStatus:MovieRecorderStatusFinished error:nil];
					}
				}
			}];
		}
	} );
}

- (void)dealloc {
	
	[self teardownAssetWriterAndInputs];

	if ( self._audioTrackSourceFormatDescription ) {
		CFRelease( self._audioTrackSourceFormatDescription );
	}
	
	if ( self._videoTrackSourceFormatDescription ) {
		CFRelease( self._videoTrackSourceFormatDescription );
	}
}


#pragma mark -
#pragma mark Internal

- (void)appendSampleBuffer:(CMSampleBufferRef)sampleBuffer ofMediaType:(NSString *)mediaType
{
	if ( sampleBuffer == NULL ) {
		@throw [NSException exceptionWithName:NSInvalidArgumentException reason:@"NULL sample buffer" userInfo:nil];
		return;			
	}
	
	@synchronized( self ) {
		if ( self._status < MovieRecorderStatusRecording ) {
			@throw [NSException exceptionWithName:NSInternalInconsistencyException reason:@"Not ready to record yet" userInfo:nil];
			return;	
		}
	}
	
	CFRetain( sampleBuffer );
	dispatch_async( self._writingQueue, ^{
		
		@autoreleasepool
		{
			@synchronized( self )
			{
				// From the client's perspective the movie recorder can asynchronously transition to an error state as the result of an append.
				// Because of this we are lenient when samples are appended and we are no longer recording.
				// Instead of throwing an exception we just release the sample buffers and return.
				if ( self._status > MovieRecorderStatusFinishingRecordingPart1 ) {
					CFRelease( sampleBuffer );
					return;
				}
			}
			
			if ( ! self._haveStartedSession ) {
				[self._assetWriter startSessionAtSourceTime:CMSampleBufferGetPresentationTimeStamp(sampleBuffer)];
				self._haveStartedSession = YES;
			}
			
			AVAssetWriterInput *input = ( mediaType == AVMediaTypeVideo ) ? self._videoInput : self._audioInput;
			
			if ( input.readyForMoreMediaData )
			{
				BOOL success = [input appendSampleBuffer:sampleBuffer];
				if ( ! success ) {
					NSError *error = self._assetWriter.error;
					@synchronized( self ) {
						[self transitionToStatus:MovieRecorderStatusFailed error:error];
					}
				}
			}
			else
			{
				NSLog( @"%@ input not ready for more media data, dropping buffer", mediaType );
			}
			CFRelease( sampleBuffer );
		}
	} );
}

// call under @synchonized( self )
- (void)transitionToStatus:(MovieRecorderStatus)newStatus error:(NSError *)error
{
	BOOL shouldNotifyDelegate = NO;
	
#if LOG_STATUS_TRANSITIONS
	NSLog( @"MovieRecorder state transition: %@->%@", [self stringForStatus:_status], [self stringForStatus:newStatus] );
#endif
	
	if ( newStatus != self._status )
	{
		// terminal states
		if ( ( newStatus == MovieRecorderStatusFinished ) || ( newStatus == MovieRecorderStatusFailed ) )
		{
			shouldNotifyDelegate = YES;
			// make sure there are no more sample buffers in flight before we tear down the asset writer and inputs
            
			dispatch_async( self._writingQueue, ^{
				[self teardownAssetWriterAndInputs];
				if ( newStatus == MovieRecorderStatusFailed ) {
					[[NSFileManager defaultManager] removeItemAtURL:self._URL error:NULL];
				}
			} );

#if LOG_STATUS_TRANSITIONS
			if ( error ) {
				NSLog( @"MovieRecorder error: %@, code: %i", error, (int)error.code );
			}
#endif
		}
		else if ( newStatus == MovieRecorderStatusRecording )
		{
			shouldNotifyDelegate = YES;
		}
		
		self._status = newStatus;
	}

	if ( shouldNotifyDelegate && self.delegate )
	{
		dispatch_async( self._delegateCallbackQueue, ^{
			
			@autoreleasepool
			{
				switch ( newStatus )
				{
					case MovieRecorderStatusRecording:
						[self.delegate movieRecorderDidFinishPreparing:self];
						break;
					case MovieRecorderStatusFinished:
						[self.delegate movieRecorderDidFinishRecording:self];
						break;
					case MovieRecorderStatusFailed:
						[self.delegate movieRecorder:self didFailWithError:error];
						break;
					default:
						break;
				}
			}
		} );
	}
}

#if LOG_STATUS_TRANSITIONS

- (NSString *)stringForStatus:(MovieRecorderStatus)status
{
	NSString *statusString = nil;
	
	switch ( status )
	{
		case MovieRecorderStatusIdle:
			statusString = @"Idle";
			break;
		case MovieRecorderStatusPreparingToRecord:
			statusString = @"PreparingToRecord";
			break;
		case MovieRecorderStatusRecording:
			statusString = @"Recording";
			break;
		case MovieRecorderStatusFinishingRecordingPart1:
			statusString = @"FinishingRecordingPart1";
			break;
		case MovieRecorderStatusFinishingRecordingPart2:
			statusString = @"FinishingRecordingPart2";
			break;
		case MovieRecorderStatusFinished:
			statusString = @"Finished";
			break;
		case MovieRecorderStatusFailed:
			statusString = @"Failed";
			break;
		default:
			statusString = @"Unknown";
			break;
	}
	return statusString;
	
}

#endif // LOG_STATUS_TRANSITIONS

- (BOOL)setupAssetWriterAudioInputWithSourceFormatDescription:(CMFormatDescriptionRef)audioFormatDescription settings:(NSDictionary *)audioSettings error:(NSError **)errorOut
{
	if ( ! audioSettings ) {
		NSLog( @"No audio settings provided, using default settings" );
		audioSettings = @{ AVFormatIDKey : @(kAudioFormatMPEG4AAC) };
	}
	
	if ( [self._assetWriter canApplyOutputSettings:audioSettings forMediaType:AVMediaTypeAudio] )
	{
		self._audioInput = [[AVAssetWriterInput alloc] initWithMediaType:AVMediaTypeAudio outputSettings:audioSettings sourceFormatHint:audioFormatDescription];
		self._audioInput.expectsMediaDataInRealTime = YES;
		
		if ( [self._assetWriter canAddInput:self._audioInput] )
		{
			[self._assetWriter addInput:self._audioInput];
		}
		else
		{
			if ( errorOut ) {
				*errorOut = [[self class] cannotSetupInputError];
			}
            return NO;
		}
	}
	else
	{
		if ( errorOut ) {
			*errorOut = [[self class] cannotSetupInputError];
		}
        return NO;
	}
    
    return YES;
}

- (BOOL)setupAssetWriterVideoInputWithSourceFormatDescription:(CMFormatDescriptionRef)videoFormatDescription transform:(CGAffineTransform)transform settings:(NSDictionary *)videoSettings error:(NSError **)errorOut
{
	if ( ! videoSettings )
	{
		float bitsPerPixel;
		CMVideoDimensions dimensions = CMVideoFormatDescriptionGetDimensions( videoFormatDescription );
		int numPixels = dimensions.width * dimensions.height;
		int bitsPerSecond;
	
		NSLog( @"No video settings provided, using default settings" );
		
		// Assume that lower-than-SD resolutions are intended for streaming, and use a lower bitrate
		if ( numPixels < ( 640 * 480 ) ) {
			bitsPerPixel = 4.05; // This bitrate approximately matches the quality produced by AVCaptureSessionPresetMedium or Low.
		}
		else {
			bitsPerPixel = 10.1; // This bitrate approximately matches the quality produced by AVCaptureSessionPresetHigh.
		}
		
		bitsPerSecond = numPixels * bitsPerPixel;
		
		NSDictionary *compressionProperties = @{ AVVideoAverageBitRateKey : @(bitsPerSecond), 
												 AVVideoExpectedSourceFrameRateKey : @(30),
												 AVVideoMaxKeyFrameIntervalKey : @(30) };
		
		videoSettings = @{ AVVideoCodecKey : AVVideoCodecH264,
						   AVVideoWidthKey : @(dimensions.width),
						   AVVideoHeightKey : @(dimensions.height),
						   AVVideoCompressionPropertiesKey : compressionProperties };
	}
	
	if ( [self._assetWriter canApplyOutputSettings:videoSettings forMediaType:AVMediaTypeVideo] )
	{
		self._videoInput = [[AVAssetWriterInput alloc] initWithMediaType:AVMediaTypeVideo outputSettings:videoSettings sourceFormatHint:videoFormatDescription];
		self._videoInput.expectsMediaDataInRealTime = YES;
		self._videoInput.transform = transform;
		
		if ( [self._assetWriter canAddInput:self._videoInput] )
		{
			[self._assetWriter addInput:self._videoInput];
		}
		else
		{
			if ( errorOut ) {
				*errorOut = [[self class] cannotSetupInputError];
			}
            return NO;
		}
	}
	else
	{
		if ( errorOut ) {
			*errorOut = [[self class] cannotSetupInputError];
		}
        return NO;
	}
    
    return YES;
}

+ (NSError *)cannotSetupInputError
{
	NSString *localizedDescription = NSLocalizedString( @"Recording cannot be started", nil );
	NSString *localizedFailureReason = NSLocalizedString( @"Cannot setup asset writer input.", nil );
	NSDictionary *errorDict = @{ NSLocalizedDescriptionKey : localizedDescription,
								 NSLocalizedFailureReasonErrorKey : localizedFailureReason };
	return [NSError errorWithDomain:@"com.apple.dts.samplecode" code:0 userInfo:errorDict];
}

- (void)teardownAssetWriterAndInputs
{
    self._videoInput = nil;
    self._audioInput = nil;
    self._assetWriter = nil;
}

@end
