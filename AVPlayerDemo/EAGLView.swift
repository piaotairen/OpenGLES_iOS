//
//  EAGLView.swift
//  AVPlayerDemo
//
//  Created by Zihai on 2018/9/5.
//  Copyright © 2018年 Zihai. All rights reserved.
//

import UIKit
import OpenGLES
import QuartzCore
import AVFoundation
import MachO

// Uniform index.
enum uniform: Int {
    case y = 0
    case uv = 1
    case luma_threshold = 2
    case chroma_threshold = 3
    case rotation_angle = 4
    case color_conversion_matrix = 5
    case num_uniforms = 6
}

var uniforms: [GLint] = Array(repeating: 0, count: uniform.num_uniforms.rawValue)

// Attribute index.
enum attrib: GLuint {
    case vertex = 0
    case texcoord = 1
    case num_attributes = 2
}

// Color Conversion Constants (YUV to RGB) including adjustment from 16-235/16-240 (video range)

// BT.601, which is the standard for SDTV.
let kColorConversion601: [GLfloat] = [
    1.164,  1.164, 1.164,
    0.0, -0.392, 2.017,
    1.596, -0.813,   0.0,
]

// BT.709, which is the standard for HDTV.
let kColorConversion709: [GLfloat] = [
    1.164,  1.164, 1.164,
    0.0, -0.213, 2.112,
    1.793, -0.533,   0.0,
]

class EAGLView: UIView {
    
    // The pixel dimensions of the CAEAGLLayer.
    fileprivate var backingWidth: GLint = 0
    
    fileprivate var backingHeight: GLint = 0
    
    fileprivate var context: EAGLContext?
    
    fileprivate var lumaTexture: CVOpenGLESTexture?
    
    fileprivate var chromaTexture: CVOpenGLESTexture?
    
    fileprivate var videoTextureCache: CVOpenGLESTextureCache?
    
    fileprivate var frameBufferHandle: GLuint = 0
    
    fileprivate var colorBufferHandle: GLuint = 0
    
    fileprivate var preferredConversion: UnsafePointer<GLfloat>?
    
    fileprivate var program: GLuint = 0
    
    public var preferredRotation: GLfloat = 0
    
    public var presentationRect: CGSize = CGSize.zero
    
    public var chromaThreshold: GLfloat = 0
    
    public var lumaThreshold: GLfloat = 0
    
    // MARK: - override
    
    override class var layerClass: Swift.AnyClass {
        return CAEAGLLayer.self
    }
    
    // MARK: - Life Cycle
    
    required init?(coder aDecoder: NSCoder) {
        super.init(coder: aDecoder)
        
        /// Use 2x scale factor on Retina displays.
        contentScaleFactor = UIScreen.main.scale
        
        /// Get and configure the layer.
        let eaglLayer = self.layer as! CAEAGLLayer
        eaglLayer.isOpaque = true
        
        eaglLayer.drawableProperties = [kEAGLDrawablePropertyRetainedBacking : NSNumber(booleanLiteral: false),
                                        kEAGLDrawablePropertyColorFormat : kEAGLColorFormatRGBA8]
        
        /// Set the context into which the frames will be drawn.
        context = EAGLContext(api: .openGLES2)
        
        if context == nil || !EAGLContext.setCurrent(context) || !loadShaders() {
            return nil;
        }
        
        /// Set the default conversion to BT.709, which is the standard for HDTV.
        preferredConversion = UnsafePointer<GLfloat>(kColorConversion709)
    }
    
    deinit {
        cleanUpTextures()
    }
    
    // MARK: - Public
    
    // MARK: OpenGL setup
    
    public func setupGL() {
        EAGLContext.setCurrent(context)
        setupBuffers()
        loadShaders()
        
        glUseProgram(program)
        
        /// 0 and 1 are the texture IDs of _lumaTexture and _chromaTexture respectively.
        glUniform1i(uniforms[uniform.y.rawValue], 0)
        glUniform1i(uniforms[uniform.uv.rawValue], 1)
        glUniform1f(uniforms[uniform.luma_threshold.rawValue], self.lumaThreshold)
        glUniform1f(uniforms[uniform.chroma_threshold.rawValue], self.chromaThreshold)
        glUniform1f(uniforms[uniform.rotation_angle.rawValue], self.preferredRotation)
        glUniformMatrix3fv(uniforms[uniform.color_conversion_matrix.rawValue], 1, GLboolean(GL_FALSE), preferredConversion)
        
        /// Create CVOpenGLESTextureCacheRef for optimal CVPixelBufferRef to GLES texture conversion.
        if let context = context {
            let err = CVOpenGLESTextureCacheCreate(kCFAllocatorDefault, nil, context, nil, &videoTextureCache)
            if err != noErr {
                print("Error at CVOpenGLESTextureCacheCreate \(err)")
                return
            }
        }
    }
    
    // MARK: OpenGLES drawing
    
    public func displayPixelBuffer(pixelBuffer: CVPixelBuffer?) {
        var err: CVReturn
        if let pixelBuffer = pixelBuffer {
            let frameWidth = CVPixelBufferGetWidth(pixelBuffer)
            let frameHeight = CVPixelBufferGetHeight(pixelBuffer)
            
            if videoTextureCache == nil {
                print("No video texture cache")
                return
            }
            
            cleanUpTextures()
            
            /*
             Use the color attachment of the pixel buffer to determine the appropriate color conversion matrix.
             */
            let colorAttachments = CVBufferGetAttachment(pixelBuffer, kCVImageBufferYCbCrMatrixKey, nil) as! CFString
            
            if colorAttachments == kCVImageBufferYCbCrMatrix_ITU_R_601_4 {
                preferredConversion = UnsafePointer<GLfloat>(kColorConversion601)
            } else {
                preferredConversion = UnsafePointer<GLfloat>(kColorConversion709)
            }
            
            /*
             CVOpenGLESTextureCacheCreateTextureFromImage will create GLES texture optimally from CVPixelBufferRef.
             */
            
            /*
             Create Y and UV textures from the pixel buffer. These textures will be drawn on the frame buffer Y-plane.
             */
            glActiveTexture(GLenum(GL_TEXTURE0))
            err = CVOpenGLESTextureCacheCreateTextureFromImage(kCFAllocatorDefault,
                                                               videoTextureCache!,
                                                               pixelBuffer,
                                                               nil,
                                                               GLenum(GL_TEXTURE_2D),
                                                               GL_RED_EXT,
                                                               GLsizei(frameWidth),
                                                               GLsizei(frameHeight),
                                                               GLenum(GL_RED_EXT),
                                                               GLenum(GL_UNSIGNED_BYTE),
                                                               0,
                                                               &lumaTexture)
            if err != 0 {
                print("Error at CVOpenGLESTextureCacheCreateTextureFromImage \(err)")
            }
            
            glBindTexture(CVOpenGLESTextureGetTarget(lumaTexture!), CVOpenGLESTextureGetName(lumaTexture!))
            glTexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_MIN_FILTER), GL_LINEAR)
            glTexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_MAG_FILTER), GL_LINEAR)
            glTexParameterf(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_WRAP_S), GLfloat(GL_CLAMP_TO_EDGE))
            glTexParameterf(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_WRAP_T), GLfloat(GL_CLAMP_TO_EDGE))
            
            // UV-plane.
            glActiveTexture(GLenum(GL_TEXTURE1))
            err = CVOpenGLESTextureCacheCreateTextureFromImage(kCFAllocatorDefault,
                                                               videoTextureCache!,
                                                               pixelBuffer,
                                                               nil,
                                                               GLenum(GL_TEXTURE_2D),
                                                               GL_RG_EXT,
                                                               GLsizei(frameWidth / 2),
                                                               GLsizei(frameHeight / 2),
                                                               GLenum(GL_RG_EXT),
                                                               GLenum(GL_UNSIGNED_BYTE),
                                                               1,
                                                               &chromaTexture)
            if err != 0 {
                print("Error at CVOpenGLESTextureCacheCreateTextureFromImage \(err)")
            }
            
            glBindTexture(CVOpenGLESTextureGetTarget(chromaTexture!), CVOpenGLESTextureGetName(chromaTexture!))
            print("id \(CVOpenGLESTextureGetName(chromaTexture!))")
            glTexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_MIN_FILTER), GL_LINEAR)
            glTexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_MAG_FILTER), GL_LINEAR)
            glTexParameterf(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_WRAP_S), GLfloat(GL_CLAMP_TO_EDGE))
            glTexParameterf(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_WRAP_T), GLfloat(GL_CLAMP_TO_EDGE))
            
            glBindFramebuffer(GLenum(GL_FRAMEBUFFER), frameBufferHandle)
            
            // Set the view port to the entire view.
            glViewport(0, 0, backingWidth, backingHeight)
        }
        
        glClearColor(0.0, 0.0, 0.0, 1.0)
        glClear(GLbitfield(GL_COLOR_BUFFER_BIT))
        
        // Use shader program.
        glUseProgram(self.program)
        glUniform1f(uniforms[uniform.luma_threshold.rawValue], self.lumaThreshold)
        glUniform1f(uniforms[uniform.chroma_threshold.rawValue], self.chromaThreshold)
        glUniform1f(uniforms[uniform.rotation_angle.rawValue], self.preferredRotation)
        glUniformMatrix3fv(uniforms[uniform.color_conversion_matrix.rawValue], 1, GLboolean(GL_FALSE), preferredConversion)
        
        // Set up the quad vertices with respect to the orientation and aspect ratio of the video.
        let vertexSamplingRect = AVMakeRect(aspectRatio: self.presentationRect, insideRect: self.layer.bounds)
        
        // Compute normalized quad coordinates to draw the frame into.
        var normalizedSamplingSize = CGSize(width: 0.0, height: 0.0)
        let cropScaleAmount = CGSize(width: vertexSamplingRect.size.width/self.layer.bounds.size.width, height: vertexSamplingRect.size.height/self.layer.bounds.size.height)
        
        // Normalize the quad vertices.
        if cropScaleAmount.width > cropScaleAmount.height {
            normalizedSamplingSize.width = 1.0
            normalizedSamplingSize.height = cropScaleAmount.height/cropScaleAmount.width
        } else {
            normalizedSamplingSize.width = 1.0
            normalizedSamplingSize.height = cropScaleAmount.width/cropScaleAmount.height
        }
        
        /*
         The quad vertex data defines the region of 2D plane onto which we draw our pixel buffers.
         Vertex data formed using (-1,-1) and (1,1) as the bottom left and top right coordinates respectively, covers the entire screen.
         */
        let quadVertexData: [GLfloat] = [
            Float(-1.0 * normalizedSamplingSize.width), Float(-1.0 * normalizedSamplingSize.height),
            Float(normalizedSamplingSize.width), Float(-1.0 * normalizedSamplingSize.height),
            Float(-1.0 * normalizedSamplingSize.width), Float(normalizedSamplingSize.height),
            Float(normalizedSamplingSize.width), Float(normalizedSamplingSize.height),
            ]
        
        // Update attribute values.
        glVertexAttribPointer(attrib.vertex.rawValue, 2, GLenum(GL_FLOAT), 0, 0, quadVertexData)
        glEnableVertexAttribArray(attrib.vertex.rawValue)
        
        /*
         The texture vertices are set up such that we flip the texture vertically. This is so that our top left origin buffers match OpenGL's bottom left texture coordinate system.
         */
        let textureSamplingRect = CGRect(x: 0, y: 0, width: 1, height: 1)
        let quadTextureData: [GLfloat] = [
            Float(textureSamplingRect.minX), Float(textureSamplingRect.maxY),
            Float(textureSamplingRect.maxX), Float(textureSamplingRect.maxY),
            Float(textureSamplingRect.minX), Float(textureSamplingRect.minY),
            Float(textureSamplingRect.maxX), Float(textureSamplingRect.minY)
        ]
        
        glVertexAttribPointer(attrib.texcoord.rawValue, 2, GLenum(GL_FLOAT), 0, 0, quadTextureData)
        glEnableVertexAttribArray(attrib.texcoord.rawValue)
        
        glDrawArrays(GLenum(GL_TRIANGLE_STRIP), 0, 4)
        
        glBindRenderbuffer(GLenum(GL_RENDERBUFFER), colorBufferHandle)
        context?.presentRenderbuffer(Int(GL_RENDERBUFFER))
    }
    
    // MARK: - Private
    
    // MARK: Utilities
    
    private func setupBuffers() {
        glDisable(GLenum(GL_DEPTH_TEST))
        
        glEnableVertexAttribArray(attrib.vertex.rawValue)
        glVertexAttribPointer(attrib.vertex.rawValue, 2, GLenum(GL_FLOAT), GLboolean(GL_FALSE), GLsizei(2 * MemoryLayout<GLfloat>.size), UnsafeRawPointer(bitPattern: 0))
        
        glEnableVertexAttribArray(attrib.texcoord.rawValue)
        glVertexAttribPointer(attrib.texcoord.rawValue, 2, GLenum(GL_FLOAT), GLboolean(GL_FALSE), GLsizei(2 * MemoryLayout<GLfloat>.size), UnsafeRawPointer(bitPattern: 0))
        
        glGenFramebuffers(1, &frameBufferHandle)
        glBindFramebuffer(GLenum(GL_FRAMEBUFFER), frameBufferHandle)
        
        glGenRenderbuffers(1, &colorBufferHandle)
        glBindRenderbuffer(GLenum(GL_RENDERBUFFER), colorBufferHandle)
        
        context?.renderbufferStorage(Int(GL_RENDERBUFFER), from: self.layer as! CAEAGLLayer)
        glGetRenderbufferParameteriv(GLenum(GL_RENDERBUFFER), GLenum(GL_RENDERBUFFER_WIDTH), &backingWidth)
        glGetRenderbufferParameteriv(GLenum(GL_RENDERBUFFER), GLenum(GL_RENDERBUFFER_HEIGHT), &backingHeight)
        
        glFramebufferRenderbuffer(GLenum(GL_FRAMEBUFFER), GLenum(GL_COLOR_ATTACHMENT0), GLenum(GL_RENDERBUFFER), colorBufferHandle)
        if glCheckFramebufferStatus(GLenum(GL_FRAMEBUFFER)) != GL_FRAMEBUFFER_COMPLETE {
            print("Failed to make complete framebuffer object \(glCheckFramebufferStatus(GLenum(GL_FRAMEBUFFER)))")
        }
    }
    
    private func cleanUpTextures() {
        lumaTexture = nil
        chromaTexture = nil
        
        // Periodic texture cache flush every frame
        if videoTextureCache != nil {
            CVOpenGLESTextureCacheFlush(videoTextureCache as! CVOpenGLESTextureCache, 0)
        }
    }
    
    // MARK: - OpenGL ES 2 shader compilation
    @discardableResult
    
    private func loadShaders() -> Bool {
        var vertShader = UnsafeMutablePointer<GLuint>.allocate(capacity: 0)
        vertShader.initialize(to: 0)
        var fragShader = UnsafeMutablePointer<GLuint>.allocate(capacity: 0)
        fragShader.initialize(to: 0)
        
        let vertShaderURL: URL, fragShaderURL: URL
        
        // Create the shader program.
        self.program = glCreateProgram()
        
        // Create and compile the vertex shader.
        vertShaderURL = Bundle.main.url(forResource: "Shader", withExtension: "vsh")!
        if !compileShader(shader: &vertShader, type: GLenum(GL_VERTEX_SHADER), url: vertShaderURL) {
            print("Failed to compile vertex shader")
            return false
        }
        
        // Create and compile fragment shader.
        fragShaderURL = Bundle.main.url(forResource: "Shader", withExtension: "fsh")!
        if !compileShader(shader: &fragShader, type: GLenum(GL_FRAGMENT_SHADER), url: fragShaderURL) {
            print("Failed to compile fragment shader")
            return false
        }
        
        // Attach vertex shader to program.
        glAttachShader(self.program, vertShader.pointee)
        
        // Attach fragment shader to program.
        glAttachShader(self.program, fragShader.pointee)
        
        // Bind attribute locations. This needs to be done prior to linking.
        glBindAttribLocation(self.program, attrib.vertex.rawValue, "position")
        glBindAttribLocation(self.program, attrib.texcoord.rawValue, "texCoord")
        
        // Link the program.
        if !linkProgram(program) {
            print("Failed to link program: \(program)")
            
            if vertShader.pointee != 0 {
                glDeleteShader(vertShader.pointee)
                vertShader.pointee = 0
            }
            if fragShader.pointee != 0 {
                glDeleteShader(fragShader.pointee)
                fragShader.pointee = 0
            }
            if self.program != 0 {
                glDeleteProgram(self.program)
                self.program = 0
            }
            
            return false
        }
        
        // Get uniform locations.
        uniforms[uniform.y.rawValue] = glGetUniformLocation(self.program, "SamplerY")
        uniforms[uniform.uv.rawValue] = glGetUniformLocation(self.program, "SamplerUV")
        uniforms[uniform.luma_threshold.rawValue] = glGetUniformLocation(self.program, "lumaThreshold")
        uniforms[uniform.chroma_threshold.rawValue] = glGetUniformLocation(self.program, "chromaThreshold")
        uniforms[uniform.rotation_angle.rawValue] = glGetUniformLocation(self.program, "preferredRotation")
        uniforms[uniform.color_conversion_matrix.rawValue] = glGetUniformLocation(self.program, "colorConversionMatrix")
        
        // Release vertex and fragment shaders.
        if vertShader.pointee != 0 {
            glDetachShader(self.program, vertShader.pointee)
            glDeleteShader(vertShader.pointee)
        }
        if fragShader.pointee != 0 {
            glDetachShader(self.program, fragShader.pointee)
            glDeleteShader(fragShader.pointee)
        }
        
        return true
    }
    
    private func compileShader(shader: inout UnsafeMutablePointer<GLuint>, type: GLenum, url: URL) -> Bool {
        let sourceString = try? String(contentsOf: url, encoding: .utf8)
        if sourceString == nil {
            print("Failed to load vertex shader")
            return false
        }
        
        let status: UnsafeMutablePointer<GLint> = UnsafeMutablePointer<GLint>.allocate(capacity: 0)
        var source: UnsafePointer<GLchar>?
        
        let ccharSource = sourceString?.cString(using: .utf8)
        let mutableSource = UnsafeMutablePointer<GLchar>.allocate(capacity: (ccharSource?.count)!)
        mutableSource.initialize(from: (ccharSource)!, count: (ccharSource?.count)!)
        source = UnsafePointer<GLchar>.init(mutableSource)
        
        shader.pointee = glCreateShader(type)
        glShaderSource(shader.pointee, 1, &source, nil)
        glCompileShader(shader.pointee)
        
        #if DEBUG
        let logLength = UnsafeMutablePointer<GLint>.allocate(capacity: 1024 * 1024)
        logLength.initialize(to: 0)
        glGetShaderiv(shader.pointee, GLenum(GL_INFO_LOG_LENGTH), logLength)
        if logLength.pointee > 0 {
            let log = UnsafeMutablePointer<GLchar>.allocate(capacity: 1024 * 1024)
            glGetShaderInfoLog(shader.pointee, logLength.pointee, logLength, log)
            print("Shader compile log:\n \(log)")
            free(log)
        }
        #endif
        
        glGetShaderiv(shader.pointee, GLenum(GL_COMPILE_STATUS), status)
        if status.pointee == 0 {
            glDeleteShader(shader.pointee)
            return false
        }
        
        return true
    }
    
    private func linkProgram(_ program: GLuint) -> Bool {
        let status: UnsafeMutablePointer<GLint> = UnsafeMutablePointer<GLint>.allocate(capacity: 0)
        glLinkProgram(program)
        
        #if DEBUG
       let logLength = UnsafeMutablePointer<GLint>.allocate(capacity: 0)
        glGetProgramiv(program, GLenum(GL_INFO_LOG_LENGTH), logLength)
        if logLength.pointee > 0 {
            let log = UnsafeMutablePointer<GLchar>.allocate(capacity: Int(logLength.pointee))
            glGetProgramInfoLog(program, logLength.pointee, logLength, log)
            print("Program link log:\n \(log)")
            free(log)
        }
        #endif
        
        glGetProgramiv(program, GLenum(GL_LINK_STATUS), status)
        if status.pointee == 0 {
            return false
        }
        
        return true
    }
    
    private func validateProgram(_ program: GLuint) -> Bool {
        let status: UnsafeMutablePointer<GLint> = UnsafeMutablePointer<GLint>.allocate(capacity: 0)
        let logLength = UnsafeMutablePointer<GLint>.allocate(capacity: 1024 * 1024)
        
        glValidateProgram(program)
        glGetProgramiv(program, GLenum(GL_INFO_LOG_LENGTH), logLength)
        if logLength.pointee > 0 {
            let log = UnsafeMutablePointer<GLchar>.allocate(capacity: Int(logLength.pointee))
            glGetProgramInfoLog(program, logLength.pointee, logLength, log)
            print("Program validate log:\n \(log)")
            free(log)
        }
        
        glGetProgramiv(program, GLenum(GL_VALIDATE_STATUS), status)
        if status.pointee == 0 {
            return false
        }
        
        return true
    }
    
    
    
}
