/*
     File: RippleViewController.m
 Abstract: View controller that handles camera, drawing, and touch events.
  Version: 1.0
 
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
 
 Copyright (C) 2013 Apple Inc. All Rights Reserved.
 
 */

@import CoreVideo;
@import OpenGLES;
@import LLSimpleCamera;
#import "RippleOpenGLRenderer.h"
#import "RippleModel.h"

// Uniform index.
enum
{
    UNIFORM_Y,
    UNIFORM_UV,
    NUM_UNIFORMS
};
GLint uniforms[NUM_UNIFORMS];

// Attribute index.
enum
{
    ATTRIB_VERTEX,
    ATTRIB_TEXCOORD,
    NUM_ATTRIBUTES
};

@interface RippleOpenGLRenderer () {
    GLuint _program;

    GLuint _positionVBO;
    GLuint _texcoordVBO;
    GLuint _indexVBO;
    
    GLuint _offscreenBufferHandle;
    
    CGFloat _screenWidth;
    CGFloat _screenHeight;
    size_t _textureWidth;
    size_t _textureHeight;
    unsigned int _meshFactor;

    NSDictionary *_bufferPoolAuxAttributes;

    
    
    CVOpenGLESTextureRef _lumaTexture;
    CVOpenGLESTextureRef _chromaTexture;
    
    CMFormatDescriptionRef _outputFormatDescription;

    NSString *_sessionPreset;
    
//    AVCaptureSession *_session;
    CVPixelBufferPoolRef _bufferPool;
    
    CVOpenGLESTextureCacheRef _textureCache;
    CVOpenGLESTextureCacheRef _renderTextureCache;
}

- (void)cleanUpTextures;

- (void)setupBuffers;
- (void)tearDownGL;

- (BOOL)loadShaders;
- (BOOL)compileShader:(GLuint *)shader type:(GLenum)type file:(NSString *)file;
- (BOOL)linkProgram:(GLuint)prog;

@end

@implementation RippleOpenGLRenderer

- (instancetype)init {
    self = [super init];
    _screenWidth = [UIScreen mainScreen].bounds.size.width;
    _screenHeight = [UIScreen mainScreen].bounds.size.height;


    if (UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPad)
    {
        // meshFactor controls the ending ripple mesh size.
        // For example mesh width = screenWidth / meshFactor.
        // It's chosen based on both screen resolution and device size.
        _meshFactor = 8;
        
        // Choosing bigger preset for bigger screen.
        _sessionPreset = AVCaptureSessionPreset1280x720;
    }
    else
    {
        _meshFactor = 4;
        _sessionPreset = AVCaptureSessionPreset640x480;
    }

    return self;
}


- (void)dealloc {
    [self tearDownGL];
}


- (void)cleanUpTextures
{    
    if (_lumaTexture)
    {
        CFRelease(_lumaTexture);
        _lumaTexture = NULL;        
    }
    
    if (_chromaTexture)
    {
        CFRelease(_chromaTexture);
        _chromaTexture = NULL;
    }
    
    // Periodic texture cache flush every frame
    CVOpenGLESTextureCacheFlush(_textureCache, 0);
    CVOpenGLESTextureCacheFlush(_renderTextureCache, 0);
}


#pragma mark RosyWriterRenderer

- (BOOL)operatesInPlace
{
    return NO;
}

- (FourCharCode)inputPixelFormat
{
    return kCVPixelFormatType_420YpCbCr8BiPlanarFullRange;
//    return kCVPixelFormatType_32BGRA;
}

- (void)prepareForInputWithFormatDescription:(CMFormatDescriptionRef)inputFormatDescription outputRetainedBufferCountHint:(size_t)outputRetainedBufferCountHint
{
    // The input and output dimensions are the same. This renderer doesn't do any scaling.
    CMVideoDimensions dimensions = CMVideoFormatDescriptionGetDimensions( inputFormatDescription );
    
    [self deleteBuffers];
    
    if ( ! [self initializeBuffersWithOutputDimensions:dimensions retainedBufferCountHint:outputRetainedBufferCountHint] ) {
        @throw [NSException exceptionWithName:NSInternalInconsistencyException reason:@"Problem preparing renderer." userInfo:nil];
    }
}

- (void)reset
{
    [self tearDownGL];
}



- (CVPixelBufferRef)copyRenderedPixelBuffer:(CVPixelBufferRef)pixelBuffer {
    EAGLContext *oldContext = [EAGLContext currentContext];
    if ( oldContext != _oglContext ) {
        if ( ! [EAGLContext setCurrentContext:_oglContext] ) {
            @throw [NSException exceptionWithName:NSInternalInconsistencyException reason:@"Problem with OpenGL context" userInfo:nil];
            return NULL;
        }
    }
    

    
    CVReturn err;
    size_t width = CVPixelBufferGetWidth(pixelBuffer);
    size_t height = CVPixelBufferGetHeight(pixelBuffer);
    
    if (!_textureCache || !_renderTextureCache)
    {
        NSLog(@"No video texture cache");
        return NULL;
    }

    if (_ripple == nil ||
        width != _textureWidth ||
        height != _textureHeight)
    {
        _textureWidth = width;
        _textureHeight = height;
        
        NSLog(@"RippleModel init: \n\tscreenWidth %f \n\tscreenHeight %f \n\ttextureWidth %lu \n\ttextureHeight%lu", _screenWidth, _screenHeight, _textureWidth, _textureHeight);
        _ripple = [[RippleModel alloc] initWithScreenWidth:_screenWidth
                                              screenHeight:_screenHeight
                                                meshFactor:_meshFactor
                                               touchRadius:5
                                              textureWidth:_textureWidth
                                             textureHeight:_textureHeight];
        
        [self setupBuffers];
    }

    
    [self cleanUpTextures];
    
    [_ripple runSimulation];
    
//     CVOpenGLESTextureCacheCreateTextureFromImage will create GLES texture
//     optimally from CVImageBufferRef.
    
    err = CVOpenGLESTextureCacheCreateTextureFromImage(kCFAllocatorDefault,
                                                       _textureCache,
                                                       pixelBuffer,
                                                       NULL,
                                                       GL_TEXTURE_2D,
                                                       GL_RED_EXT,
                                                       _textureWidth,
                                                       _textureHeight,
                                                       GL_RED_EXT,
                                                       GL_UNSIGNED_BYTE,
                                                       0,
                                                       &_lumaTexture);
    if (err) {
        NSLog(@"Error at CVOpenGLESTextureCacheCreateTextureFromImage %d", err);
    }
    

    
    
    // UV-plane
    
    err = CVOpenGLESTextureCacheCreateTextureFromImage(kCFAllocatorDefault,
                                                       _textureCache,
                                                       pixelBuffer,
                                                       NULL,
                                                       GL_TEXTURE_2D,
                                                       GL_RG_EXT,
                                                       _textureWidth/2,
                                                       _textureHeight/2,
                                                       GL_RG_EXT,
                                                       GL_UNSIGNED_BYTE,
                                                       1,
                                                       &_chromaTexture);
    if (err)
    {
        NSLog(@"Error at CVOpenGLESTextureCacheCreateTextureFromImage %d", err);
    }
    
    void (^drawBlock)() = ^void() {

        glActiveTexture(GL_TEXTURE0);
        glBindTexture(CVOpenGLESTextureGetTarget(_lumaTexture), CVOpenGLESTextureGetName(_lumaTexture));
        glTexParameterf(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
        glTexParameterf(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);

        glActiveTexture(GL_TEXTURE1);
        glBindTexture(CVOpenGLESTextureGetTarget(_chromaTexture), CVOpenGLESTextureGetName(_chromaTexture));
        glTexParameterf(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
        glTexParameterf(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
        

        
        glBufferData(GL_ARRAY_BUFFER, [_ripple getVertexSize], [_ripple getTexCoords], GL_DYNAMIC_DRAW);
        glDrawElements(GL_TRIANGLE_STRIP, [_ripple getIndexCount], GL_UNSIGNED_SHORT, 0);
        
        
        glBindTexture( CVOpenGLESTextureGetTarget( _lumaTexture ), 0 );
        glBindTexture( CVOpenGLESTextureGetTarget( _chromaTexture ), 0 );
        
    };
    
    
    CVPixelBufferRef resultingPixelBuffer =  [self drawToPixelBuffer:drawBlock
                                              srcPixelBuffer:pixelBuffer];

    if ( oldContext != _oglContext ) {
        [EAGLContext setCurrentContext:oldContext];
    }
    
    return resultingPixelBuffer;
}


- (CVPixelBufferRef) drawToPixelBuffer:(void (^)())drawBlock
                        srcPixelBuffer:(CVPixelBufferRef)srcPixelBuffer
{
    CVOpenGLESTextureRef dstLumaTexture = NULL, dstChromaTexture = NULL;
    CVPixelBufferRef dstPixelBuffer = [self getPixelBufferFromPool];
    CVReturn err;
    
    const CMVideoDimensions srcDimensions = { (int32_t)CVPixelBufferGetWidth(srcPixelBuffer), (int32_t)CVPixelBufferGetHeight(srcPixelBuffer) };
    const CMVideoDimensions dstDimensions = CMVideoFormatDescriptionGetDimensions( _outputFormatDescription );
    
    
    
    err = CVOpenGLESTextureCacheCreateTextureFromImage( kCFAllocatorDefault,
                                                       _renderTextureCache,
                                                       dstPixelBuffer,
                                                       NULL,
                                                       GL_TEXTURE_2D,
                                                       GL_RGBA,
                                                       dstDimensions.width,
                                                       dstDimensions.height,
                                                       GL_BGRA,
                                                       GL_UNSIGNED_BYTE,
                                                       0,
                                                       &dstLumaTexture );

    if ( ! dstLumaTexture || err ) {
        NSLog( @"Error at CVOpenGLESTextureCacheCreateTextureFromImage %d", err );
        return NULL;
    }
    
    glBindFramebuffer( GL_FRAMEBUFFER, _offscreenBufferHandle );
    glViewport( 0, 0, srcDimensions.width, srcDimensions.height );
    glUseProgram( _program );
    
    
    //     Set up our destination pixel buffer as the framebuffer's render target.
    glActiveTexture( GL_TEXTURE0 );
    glBindTexture( CVOpenGLESTextureGetTarget( dstLumaTexture ), CVOpenGLESTextureGetName( dstLumaTexture ) );
    glTexParameteri( GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR );
    glTexParameteri( GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR );
    glTexParameteri( GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE );
    glTexParameteri( GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE );
    glFramebufferTexture2D( GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, CVOpenGLESTextureGetTarget( dstLumaTexture ), CVOpenGLESTextureGetName( dstLumaTexture ), 0 );
    
    GLenum glerr = glGetError();
    
    
    drawBlock();
    
    // Make sure that outstanding GL commands which render to the destination pixel buffer have been submitted.
    // AVAssetWriter, AVSampleBufferDisplayLayer, and GL will block until the rendering is complete when sourcing from this pixel buffer.
    glFlush();
    
    CFRelease(dstLumaTexture);
    
    return dstPixelBuffer;
}



- (void) createOffscreenFrameBuffer  {
    glGenFramebuffers( 1, &_offscreenBufferHandle );
    glBindFramebuffer( GL_FRAMEBUFFER, _offscreenBufferHandle );
}

- (BOOL) createTextureCaches {
    CVReturn err = CVOpenGLESTextureCacheCreate( kCFAllocatorDefault, NULL, _oglContext, NULL, &_textureCache );
    if ( err ) {
        NSLog( @"Error at CVOpenGLESTextureCacheCreate %d", err );
        return FALSE;
    }
    
    err = CVOpenGLESTextureCacheCreate( kCFAllocatorDefault, NULL, _oglContext, NULL, &_renderTextureCache );
    if ( err ) {
        NSLog( @"Error at CVOpenGLESTextureCacheCreate %d", err );
        return FALSE;
    }
    
    return TRUE;
}

- (BOOL)initializeBuffersWithOutputDimensions:(CMVideoDimensions)outputDimensions retainedBufferCountHint:(size_t)clientRetainedBufferCountHint
{
    if (_oglContext == nil) {
        _oglContext = [[EAGLContext alloc] initWithAPI:kEAGLRenderingAPIOpenGLES2];
        if ( ! _oglContext ) {
            NSLog( @"Problem with OpenGL context." );
            return FALSE;
        }
    }
    
    BOOL success = [self performWithLocalContext:^BOOL(){

        [self createOffscreenFrameBuffer];
        [self createTextureCaches];
        [self setupBufferPoolWithOutputDimensions:outputDimensions withCountHint:clientRetainedBufferCountHint];
    
        [self loadShaders];
        
        glUseProgram(_program);
        glUniform1i(uniforms[UNIFORM_Y], 0);
        glUniform1i(uniforms[UNIFORM_UV], 1);
        
        return TRUE;
        
    }];
    
    if ( ! success ) {
        [self deleteBuffers];
    }
    
    return success;
}

- (void)deleteBuffers
{
    if ( _offscreenBufferHandle ) {
        glDeleteFramebuffers( 1, &_offscreenBufferHandle );
        _offscreenBufferHandle = 0;
    }
    if ( _program ) {
        glDeleteProgram( _program );
        _program = 0;
    }
    if ( _textureCache ) {
        CFRelease( _textureCache );
        _textureCache = 0;
    }
    if ( _renderTextureCache ) {
        CFRelease( _renderTextureCache );
        _renderTextureCache = 0;
    }
    if ( _bufferPool ) {
        CFRelease( _bufferPool );
        _bufferPool = NULL;
    }
    if ( _bufferPoolAuxAttributes ) {
        _bufferPoolAuxAttributes = NULL;
    }
    if ( _outputFormatDescription ) {
        CFRelease( _outputFormatDescription );
        _outputFormatDescription = NULL;
    }
}




- (CVPixelBufferRef) getPixelBufferFromPool {
    CVPixelBufferRef pixelBuffer;
    CVReturn err;
    
    err = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes( kCFAllocatorDefault, _bufferPool, (__bridge CFDictionaryRef)_bufferPoolAuxAttributes, &pixelBuffer );
    if ( err == kCVReturnWouldExceedAllocationThreshold ) {
        // Flush the texture cache to potentially release the retained buffers and try again to create a pixel buffer
        CVOpenGLESTextureCacheFlush( _renderTextureCache, 0 );
        err = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes( kCFAllocatorDefault, _bufferPool, (__bridge CFDictionaryRef)_bufferPoolAuxAttributes, &pixelBuffer );
    }
    if ( err ) {
        if ( err == kCVReturnWouldExceedAllocationThreshold ) {
            NSLog( @"Pool is out of buffers, dropping frame" );
        }
        else {
            NSLog( @"Error at CVPixelBufferPoolCreatePixelBuffer %d", err );
        }
    }
    
    return pixelBuffer;
}




- (void)setupBuffers
{
    glGenBuffers(1, &_indexVBO);
    glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, _indexVBO);
    glBufferData(GL_ELEMENT_ARRAY_BUFFER, [_ripple getIndexSize], [_ripple getIndices], GL_STATIC_DRAW);
    
    glGenBuffers(1, &_positionVBO);
    glBindBuffer(GL_ARRAY_BUFFER, _positionVBO);
    glBufferData(GL_ARRAY_BUFFER, [_ripple getVertexSize], [_ripple getVertices], GL_STATIC_DRAW);
    
    glEnableVertexAttribArray(ATTRIB_VERTEX);
    glVertexAttribPointer(ATTRIB_VERTEX, 2, GL_FLOAT, GL_FALSE, 2*sizeof(GLfloat), 0);

    glGenBuffers(1, &_texcoordVBO);
    glBindBuffer(GL_ARRAY_BUFFER, _texcoordVBO);
    glBufferData(GL_ARRAY_BUFFER, [_ripple getVertexSize], [_ripple getTexCoords], GL_DYNAMIC_DRAW);
    
    glEnableVertexAttribArray(ATTRIB_TEXCOORD);
    glVertexAttribPointer(ATTRIB_TEXCOORD, 2, GL_FLOAT, GL_FALSE, 2*sizeof(GLfloat), 0);
    
    
}

- (BOOL) setupBufferPoolWithOutputDimensions:(CMVideoDimensions) outputDimensions
           withCountHint:(size_t)clientRetainedBufferCountHint {
    size_t maxRetainedBufferCount = clientRetainedBufferCountHint;
    _bufferPool = createPixelBufferPool( outputDimensions.width, outputDimensions.height, /*self.inputPixelFormat */ kCVPixelFormatType_32BGRA , (int32_t)maxRetainedBufferCount );
    if ( ! _bufferPool ) {
        NSLog( @"Problem initializing a buffer pool." );
        return FALSE;
    }
    
    _bufferPoolAuxAttributes = createPixelBufferPoolAuxAttributes( (int32_t)maxRetainedBufferCount );
    preallocatePixelBuffersInPool( _bufferPool, (__bridge CFDictionaryRef)_bufferPoolAuxAttributes );
    
    CMFormatDescriptionRef outputFormatDescription = NULL;
    CVPixelBufferRef testPixelBuffer = NULL;
    CVPixelBufferPoolCreatePixelBufferWithAuxAttributes( kCFAllocatorDefault, _bufferPool, (__bridge CFDictionaryRef)_bufferPoolAuxAttributes, &testPixelBuffer );
    if ( ! testPixelBuffer ) {
        NSLog( @"Problem creating a pixel buffer." );
        return FALSE;
    }
    CMVideoFormatDescriptionCreateForImageBuffer( kCFAllocatorDefault, testPixelBuffer, &outputFormatDescription );
    _outputFormatDescription = outputFormatDescription;
    CFRelease( testPixelBuffer );

    return TRUE;
}

- (void)tearDownGL
{
    if ([EAGLContext currentContext] != _oglContext) {
        [self performWithLocalContext:^BOOL{
            [self tearDownGL];
            return TRUE;
        }];
        return;
    }
    [self deleteBuffers];
    glDeleteBuffers(1, &_positionVBO);
    glDeleteBuffers(1, &_texcoordVBO);
    glDeleteBuffers(1, &_indexVBO);
    
    if (_program) {
        glDeleteProgram(_program);
        _program = 0;
    }
}


- (BOOL) performWithLocalContext:(BOOL(^)())performBlock {
    EAGLContext *oldContext = [EAGLContext currentContext];
    if ( oldContext != _oglContext ) {
        if ( ! [EAGLContext setCurrentContext:_oglContext] ) {
            @throw [NSException exceptionWithName:NSInternalInconsistencyException reason:@"Problem with OpenGL context" userInfo:nil];
            return FALSE;
        }
    }
    
    
    BOOL success = performBlock();

    
    if (_oglContext != oldContext) {
        [EAGLContext setCurrentContext:oldContext];
    }
    return success;
}


#pragma mark - GLKView and GLKViewController delegate methods

#pragma mark - Touch handling methods


- (void) initiateRippleAtLocation: (CGPoint) location {
    [_ripple initiateRippleAtLocation:location];
}


- (void) myTouch:(NSSet *)touches withEvent:(UIEvent *)event {
   for (UITouch *touch in touches) {
      CGPoint location = [touch locationInView:touch.view];
      [self initiateRippleAtLocation:location];
   }
}

- (void) touchesBegan:(nonnull NSSet *)touches withEvent:(nullable UIEvent *)event {
   [self myTouch:touches withEvent:event];
}

- (void) touchesMoved:(nonnull NSSet *)touches withEvent:(nullable UIEvent *)event {
   [self myTouch:touches withEvent:event];
}



#pragma mark - OpenGL ES 2 shader compilation

- (BOOL)loadShaders
{
    GLuint vertShader, fragShader;
    NSString *vertShaderPathname, *fragShaderPathname;
    
    // Create shader program.
    _program = glCreateProgram();
    
    // Create and compile vertex shader.
    vertShaderPathname = [[NSBundle mainBundle] pathForResource:@"RippleShader" ofType:@"vsh"];
    if (![self compileShader:&vertShader type:GL_VERTEX_SHADER file:vertShaderPathname]) {
        NSLog(@"Failed to compile vertex shader");
        return NO;
    }
    
    // Create and compile fragment shader.
    fragShaderPathname = [[NSBundle mainBundle] pathForResource:@"RippleShader" ofType:@"fsh"];
    if (![self compileShader:&fragShader type:GL_FRAGMENT_SHADER file:fragShaderPathname]) {
        NSLog(@"Failed to compile fragment shader");
        return NO;
    }
    
    // Attach vertex shader to program.
    glAttachShader(_program, vertShader);
    
    // Attach fragment shader to program.
    glAttachShader(_program, fragShader);
    
    // Bind attribute locations.
    // This needs to be done prior to linking.
    glBindAttribLocation(_program, ATTRIB_VERTEX, "position");
    glBindAttribLocation(_program, ATTRIB_TEXCOORD, "texCoord");
    
    // Link program.
    if (![self linkProgram:_program]) {
        NSLog(@"Failed to link program: %d", _program);
        
        if (vertShader) {
            glDeleteShader(vertShader);
            vertShader = 0;
        }
        if (fragShader) {
            glDeleteShader(fragShader);
            fragShader = 0;
        }
        if (_program) {
            glDeleteProgram(_program);
            _program = 0;
        }
        
        return NO;
    }
    
    // Get uniform locations.
    uniforms[UNIFORM_Y] = glGetUniformLocation(_program, "SamplerY");
    uniforms[UNIFORM_UV] = glGetUniformLocation(_program, "SamplerUV");
    
    // Release vertex and fragment shaders.  Why do I attach them if i'm only going to detach them?
    if (vertShader) {
        glDetachShader(_program, vertShader);
        glDeleteShader(vertShader);
    }
    if (fragShader) {
        glDetachShader(_program, fragShader);
        glDeleteShader(fragShader);
    }
    
    return YES;
}

- (BOOL)compileShader:(GLuint *)shader type:(GLenum)type file:(NSString *)file
{
    GLint status;
    const GLchar *source;
    
    source = (GLchar *)[[NSString stringWithContentsOfFile:file encoding:NSUTF8StringEncoding error:nil] UTF8String];
    if (!source) {
        NSLog(@"Failed to load vertex shader");
        return NO;
    }
    
    *shader = glCreateShader(type);
    glShaderSource(*shader, 1, &source, NULL);
    glCompileShader(*shader);
    
#if defined(DEBUG)
    GLint logLength;
    glGetShaderiv(*shader, GL_INFO_LOG_LENGTH, &logLength);
    if (logLength > 0) {
        GLchar *log = (GLchar *)malloc(logLength);
        glGetShaderInfoLog(*shader, logLength, &logLength, log);
        NSLog(@"Shader compile log:\n%s", log);
        free(log);
    }
#endif
    
    glGetShaderiv(*shader, GL_COMPILE_STATUS, &status);
    if (status == 0) {
        glDeleteShader(*shader);
        return NO;
    }
    
    return YES;
}

- (BOOL)linkProgram:(GLuint)prog
{
    GLint status;
    glLinkProgram(prog);
    
#if defined(DEBUG)
    GLint logLength;
    glGetProgramiv(prog, GL_INFO_LOG_LENGTH, &logLength);
    if (logLength > 0) {
        GLchar *log = (GLchar *)malloc(logLength);
        glGetProgramInfoLog(prog, logLength, &logLength, log);
        NSLog(@"Program link log:\n%s", log);
        free(log);
    }
#endif
    
    glGetProgramiv(prog, GL_LINK_STATUS, &status);
    if (status == 0) {
        return NO;
    }
    
    return YES;
}


static CVPixelBufferPoolRef createPixelBufferPool( int32_t width, int32_t height, FourCharCode pixelFormat, int32_t maxBufferCount )
{
    CVPixelBufferPoolRef outputPool = NULL;
    
    NSDictionary *sourcePixelBufferOptions = @{ (id)kCVPixelBufferPixelFormatTypeKey : @(pixelFormat),
                                                (id)kCVPixelBufferWidthKey : @(width),
                                                (id)kCVPixelBufferHeightKey : @(height),
                                                (id)kCVPixelFormatOpenGLESCompatibility : @(YES),
                                                (id)kCVPixelBufferIOSurfacePropertiesKey : @{ /*empty dictionary*/ } };
    
    NSDictionary *pixelBufferPoolOptions = @{ (id)kCVPixelBufferPoolMinimumBufferCountKey : @(maxBufferCount) };
    
    CVPixelBufferPoolCreate( kCFAllocatorDefault, (__bridge CFDictionaryRef)pixelBufferPoolOptions, (__bridge CFDictionaryRef)sourcePixelBufferOptions, &outputPool );
    
    return outputPool;
}

static NSDictionary *createPixelBufferPoolAuxAttributes( int32_t maxBufferCount )
{
    // CVPixelBufferPoolCreatePixelBufferWithAuxAttributes() will return kCVReturnWouldExceedAllocationThreshold if we have already vended the max number of buffers
    return @{ (id)kCVPixelBufferPoolAllocationThresholdKey : @(maxBufferCount) };
}

static void preallocatePixelBuffersInPool( CVPixelBufferPoolRef pool, CFDictionaryRef auxAttributes )
{
    // Preallocate buffers in the pool, since this is for real-time display/capture
    NSMutableArray *pixelBuffers = [NSMutableArray new];
    while ( 1 )
    {
        CVPixelBufferRef pixelBuffer = NULL;
        OSStatus err = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes( kCFAllocatorDefault, pool, auxAttributes, &pixelBuffer );
        
        if ( err == kCVReturnWouldExceedAllocationThreshold ) {
            break;
        }
        assert( err == noErr );
        
        [pixelBuffers addObject:CFBridgingRelease(pixelBuffer)];
    }
}


@end
