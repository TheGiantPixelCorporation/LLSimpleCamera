//
//  DefaultRenderer.swift
//  LLSimpleCamera
//
//  Created by Brett Trimble on 11/10/15.
//  Copyright © 2015 Ömer Faruk Gül. All rights reserved.
//

import UIKit

public class DefaultRenderer : NSObject, LLRenderer {

    // MARK - LLRenderer
    
    public var operatesInPlace = true;
    
    public var inputPixelFormat = kCVPixelFormatType_32BGRA;
    
    public func prepareForInputWithFormatDescription(inputFormatDescription: CMFormatDescription!, outputRetainedBufferCountHint: Int) {
        
    }
    
    public func reset() {
        
    }
    
    public func copyRenderedPixelBuffer(pixelBuffer: CVPixelBuffer!) -> Unmanaged<CVPixelBuffer>! {

       return Unmanaged.passRetained(pixelBuffer)

    }
}
