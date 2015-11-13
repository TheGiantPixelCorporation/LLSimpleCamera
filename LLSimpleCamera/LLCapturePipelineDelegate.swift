//
//  LLCapturePipelineDelegate.swift
//  LLSimpleCameraExample
//
//  Created by Brett Trimble on 11/6/15.
//  Copyright © 2015 Ömer Faruk Gül. All rights reserved.
//

import Foundation
import CoreVideo

@objc public protocol LLCapturePipelineDelegate : NSObjectProtocol {

    func capturePipelineDidStartRunning(capturePipeline: LLCapturePipeline)
    func capturePipeline(capturePipeline: LLCapturePipeline, didStopRunningWithError:NSError)
    func capturePipeline(capturePipeline: LLCapturePipeline, previewPixelBufferReadyForDisplay:CVPixelBufferRef)
    
    func capturePipelineDidRunOutOfPreviewBuffers(capturePipeline: LLCapturePipeline)
    
    // Recording
    func capturePipelineRecordingDidStart(capturePipeline: LLCapturePipeline)
    // Can happen at any point after a startRecording call, for example: startRecording->didFail (without a didStart), willStop->didFail (without a didStop)
    func capturePipeline(capturePipeline: LLCapturePipeline, recordingDidFailWithError: NSError)
    
    func capturePipelineRecordingWillStop(capturePipeline: LLCapturePipeline)
    func capturePipelineRecordingDidStop(capturePipeline: LLCapturePipeline, outputURL: NSURL)

}
