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
enum Uniform: Int {
    
    /// Y位置
    case y = 0
    
    /// UV位置
    case uv = 1
    
    /// 亮度位置
    case lumaThreshold = 2
    
    /// 强度位置
    case chromaThreshold = 3
    
    /// 角度位置
    case rotationAngle = 4
    
    /// 颜色变换矩阵位置
    case colorConversionMatrix = 5
    
    /// 枚举数量
    static func nums() -> Int {
        return 6
    }
}

/// Uniform值
var uniforms: [GLint] = Array(repeating: 0, count: Uniform.nums())

// Attribute index.
enum Attrib: GLuint {
    
    /// 顶点
    case vertex = 0
    
    /// 坐标
    case texcoord = 1
    
    /// 枚举数量
    static func nums() -> Int {
        return 2
    }
}

class EAGLView: UIView {
    // MARK: - Property
    
    /// The pixel dimensions of the CAEAGLLayer.
    /// 像素宽度
    fileprivate var backingWidth: GLint = 0
    
    /// 像素高度
    fileprivate var backingHeight: GLint = 0
    
    /// EAGL上下文
    fileprivate var context: EAGLContext?
    
    /// 亮度纹理
    fileprivate var lumaTexture: CVOpenGLESTexture?
    
    /// 强度纹理
    fileprivate var chromaTexture: CVOpenGLESTexture?
    
    /// 视频纹理缓冲
    fileprivate var videoTextureCache: CVOpenGLESTextureCache?
    
    /// 帧缓冲区
    fileprivate var frameBufferHandle: GLuint = 0
    
    /// 颜色缓冲区
    fileprivate var colorBufferHandle: GLuint = 0
    
    /// 首选YUV-RGB转换
    fileprivate var preferredConversion: UnsafePointer<GLfloat>?
    
    /// 渲染程序
    fileprivate var program: GLuint = 0
    
    // MARK: display
    
    /// 旋转
    public var preferredRotation: GLfloat = 0
    
    /// 展示比例
    public var presentationRect: CGSize = CGSize.zero
    
    /// 强度值
    public var chromaThreshold: GLfloat = 0
    
    /// 亮度值
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
        eaglLayer.drawableProperties = [kEAGLDrawablePropertyRetainedBacking : NSNumber(value: false),
                                        kEAGLDrawablePropertyColorFormat : kEAGLColorFormatRGBA8]
        
        /// Set the context into which the frames will be drawn.
        context = EAGLContext(api: .openGLES2)
        if context == nil || !EAGLContext.setCurrent(context) || !loadShaders() {
            return
        }
        
        /// Set the default conversion to BT.709, which is the standard for HDTV.
        preferredConversion = colorConversionPointer709
    }
    
    deinit {
        preferredConversion?.deallocate()
        cleanUpTextures()
    }
    
    // MARK: - Public
    
    // MARK: OpenGL setup
    
    public func setupGL() {
        guard EAGLContext.setCurrent(context) else {
            return
        }
        setupBuffers()
        loadShaders()
        
        glUseProgram(program)
        
        /// 0 and 1 are the texture IDs of _lumaTexture and _chromaTexture respectively.
        glUniform1i(uniforms[Uniform.y.rawValue], 0)
        glUniform1i(uniforms[Uniform.uv.rawValue], 1)
        glUniform1f(uniforms[Uniform.lumaThreshold.rawValue], lumaThreshold)
        glUniform1f(uniforms[Uniform.chromaThreshold.rawValue], chromaThreshold)
        glUniform1f(uniforms[Uniform.rotationAngle.rawValue], preferredRotation)
        glUniformMatrix3fv(uniforms[Uniform.colorConversionMatrix.rawValue], 1, GLboolean(GL_FALSE), preferredConversion)
        
        /// Create CVOpenGLESTextureCacheRef for optimal CVPixelBufferRef to GLES texture conversion.
        guard let context = context else {
            return
        }
        let err = CVOpenGLESTextureCacheCreate(kCFAllocatorDefault, nil, context, nil, &videoTextureCache)
        if err != noErr {
            print("Error at CVOpenGLESTextureCacheCreate \(err)")
            return
        }
    }
    
    // MARK: OpenGLES drawing
    
    public func displayPixelBuffer(pixelBuffer: CVPixelBuffer?) {
        guard let pixelBuffer = pixelBuffer else {
            print("pixelBuffer is nil")
            return
        }
        
        let frameWidth = CVPixelBufferGetWidth(pixelBuffer)
        let frameHeight = CVPixelBufferGetHeight(pixelBuffer)
        
        guard let videoTextureCache = videoTextureCache else {
            print("No video texture cache")
            return
        }
        
        cleanUpTextures()
        
        /*
         Use the color attachment of the pixel buffer to determine the appropriate color conversion matrix.
         */
        let unmanagedAttachments = CVBufferGetAttachment(pixelBuffer, kCVImageBufferYCbCrMatrixKey, nil)
        let colorAttachments = unmanagedAttachments?.takeUnretainedValue() as! CFString
        if colorAttachments == kCVImageBufferYCbCrMatrix_ITU_R_601_4 {
            preferredConversion = colorConversionPointer601
        } else {
            preferredConversion = colorConversionPointer709
        }
//        unmanagedAttachments?.release()
        
        /*
         CVOpenGLESTextureCacheCreateTextureFromImage will create GLES texture optimally from CVPixelBufferRef.
         */
        
        /*
         Create Y and UV textures from the pixel buffer. These textures will be drawn on the frame buffer Y-plane.
         */
        var cvReturn: CVReturn
        glActiveTexture(GLenum(GL_TEXTURE0))
        cvReturn = CVOpenGLESTextureCacheCreateTextureFromImage(kCFAllocatorDefault,
                                                                videoTextureCache,
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
        if cvReturn != 0 {
            print("CVReturn at CVOpenGLESTextureCacheCreateTextureFromImage \(cvReturn)")
        }
        
        guard let lumaTexture = lumaTexture else {
            print("No lumaTexture")
            return
        }
        glBindTexture(CVOpenGLESTextureGetTarget(lumaTexture), CVOpenGLESTextureGetName(lumaTexture))
        glTexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_MIN_FILTER), GL_LINEAR)
        glTexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_MAG_FILTER), GL_LINEAR)
        glTexParameterf(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_WRAP_S), GLfloat(GL_CLAMP_TO_EDGE))
        glTexParameterf(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_WRAP_T), GLfloat(GL_CLAMP_TO_EDGE))
        
        /// UV-plane.
        glActiveTexture(GLenum(GL_TEXTURE1))
        cvReturn = CVOpenGLESTextureCacheCreateTextureFromImage(kCFAllocatorDefault,
                                                                videoTextureCache,
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
        if cvReturn != 0 {
            print("Error at CVOpenGLESTextureCacheCreateTextureFromImage \(cvReturn)")
        }
        
        guard let chromaTexture = chromaTexture else {
            print("No chromaTexture")
            return
        }
        glBindTexture(CVOpenGLESTextureGetTarget(chromaTexture), CVOpenGLESTextureGetName(chromaTexture))
        print("id \(CVOpenGLESTextureGetName(chromaTexture))")
        glTexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_MIN_FILTER), GL_LINEAR)
        glTexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_MAG_FILTER), GL_LINEAR)
        glTexParameterf(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_WRAP_S), GLfloat(GL_CLAMP_TO_EDGE))
        glTexParameterf(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_WRAP_T), GLfloat(GL_CLAMP_TO_EDGE))
        
        glBindFramebuffer(GLenum(GL_FRAMEBUFFER), frameBufferHandle)
        
        /// Set the view port to the entire view.
        glViewport(0, 0, backingWidth, backingHeight)
        
        glClearColor(0.0, 0.0, 0.0, 1.0)
        glClear(GLbitfield(GL_COLOR_BUFFER_BIT))
        
        /// Use shader program.
        glUseProgram(program)
        glUniform1f(uniforms[Uniform.lumaThreshold.rawValue], lumaThreshold)
        glUniform1f(uniforms[Uniform.chromaThreshold.rawValue], chromaThreshold)
        glUniform1f(uniforms[Uniform.rotationAngle.rawValue], preferredRotation)
        glUniformMatrix3fv(uniforms[Uniform.colorConversionMatrix.rawValue], 1, GLboolean(GL_FALSE), preferredConversion)
        
        /// Set up the quad vertices with respect to the orientation and aspect ratio of the video.
        let vertexSamplingRect = AVMakeRect(aspectRatio: presentationRect, insideRect: layer.bounds)
        
        /// Compute normalized quad coordinates to draw the frame into.
        var normalizedSamplingSize = CGSize(width: 0.0, height: 0.0)
        let cropScaleAmount = CGSize(width: vertexSamplingRect.size.width / layer.bounds.size.width, height: vertexSamplingRect.size.height / layer.bounds.size.height)
        
        /// Normalize the quad vertices.
        if cropScaleAmount.width > cropScaleAmount.height {
            normalizedSamplingSize.width = 1.0
            normalizedSamplingSize.height = cropScaleAmount.height / cropScaleAmount.width
        } else {
            normalizedSamplingSize.width = 1.0
            normalizedSamplingSize.height = cropScaleAmount.width / cropScaleAmount.height
        }
        
        /*
         The quad vertex data defines the region of 2D plane onto which we draw our pixel buffers.
         Vertex data formed using (-1,-1) and (1,1) as the bottom left and top right coordinates respectively, covers the entire screen.
         */
        let quadVertexData: [GLfloat] = [
            GLfloat(-1.0 * normalizedSamplingSize.width), GLfloat(-1.0 * normalizedSamplingSize.height),
            GLfloat(normalizedSamplingSize.width), GLfloat(-1.0 * normalizedSamplingSize.height),
            GLfloat(-1.0 * normalizedSamplingSize.width), GLfloat(normalizedSamplingSize.height),
            GLfloat(normalizedSamplingSize.width), GLfloat(normalizedSamplingSize.height),
            ]
        
        /// Update attribute values.
        glVertexAttribPointer(Attrib.vertex.rawValue, 2, GLenum(GL_FLOAT), 0, 0, quadVertexData)
        glEnableVertexAttribArray(Attrib.vertex.rawValue)
        
        /*
         The texture vertices are set up such that we flip the texture vertically. This is so that our top left origin buffers match OpenGL's bottom left texture coordinate system.
         */
        let textureSamplingRect = CGRect(x: 0, y: 0, width: 1, height: 1)
        let quadTextureData: [GLfloat] = [
            GLfloat(textureSamplingRect.minX), GLfloat(textureSamplingRect.maxY),
            GLfloat(textureSamplingRect.maxX), GLfloat(textureSamplingRect.maxY),
            GLfloat(textureSamplingRect.minX), GLfloat(textureSamplingRect.minY),
            GLfloat(textureSamplingRect.maxX), GLfloat(textureSamplingRect.minY)
        ]
        
        glVertexAttribPointer(Attrib.texcoord.rawValue, 2, GLenum(GL_FLOAT), 0, 0, quadTextureData)
        glEnableVertexAttribArray(Attrib.texcoord.rawValue)
        
        glDrawArrays(GLenum(GL_TRIANGLE_STRIP), 0, 4)
        
        glBindRenderbuffer(GLenum(GL_RENDERBUFFER), colorBufferHandle)
        context?.presentRenderbuffer(Int(GL_RENDERBUFFER))
    }
    
    // MARK: - Private
    
    // MARK: Utilities
    
    private func setupBuffers() {
        glDisable(GLenum(GL_DEPTH_TEST))
        
        glEnableVertexAttribArray(Attrib.vertex.rawValue)
        glVertexAttribPointer(Attrib.vertex.rawValue, 2, GLenum(GL_FLOAT), GLboolean(GL_FALSE), GLsizei(2 * MemoryLayout<GLfloat>.size), UnsafeRawPointer(bitPattern: 0))
        
        glEnableVertexAttribArray(Attrib.texcoord.rawValue)
        glVertexAttribPointer(Attrib.texcoord.rawValue, 2, GLenum(GL_FLOAT), GLboolean(GL_FALSE), GLsizei(2 * MemoryLayout<GLfloat>.size), UnsafeRawPointer(bitPattern: 0))
        
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
        guard let videoTextureCache = videoTextureCache else {
            return
        }
        CVOpenGLESTextureCacheFlush(videoTextureCache, 0)
    }
    
    // MARK: - OpenGL ES 2 shader compilation
    @discardableResult
    
    private func loadShaders() -> Bool {
        var vertShader = UnsafeMutablePointer<GLuint>.allocate(capacity: 1)
        vertShader.initialize(to: 0)
        var fragShader = UnsafeMutablePointer<GLuint>.allocate(capacity: 1)
        fragShader.initialize(to: 0)
        defer {
            vertShader.deallocate()
            fragShader.deallocate()
        }
        
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
        glBindAttribLocation(self.program, Attrib.vertex.rawValue, "position")
        glBindAttribLocation(self.program, Attrib.texcoord.rawValue, "texCoord")
        
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
        uniforms[Uniform.y.rawValue] = glGetUniformLocation(self.program, "SamplerY")
        uniforms[Uniform.uv.rawValue] = glGetUniformLocation(self.program, "SamplerUV")
        uniforms[Uniform.lumaThreshold.rawValue] = glGetUniformLocation(self.program, "lumaThreshold")
        uniforms[Uniform.chromaThreshold.rawValue] = glGetUniformLocation(self.program, "chromaThreshold")
        uniforms[Uniform.rotationAngle.rawValue] = glGetUniformLocation(self.program, "preferredRotation")
        uniforms[Uniform.colorConversionMatrix.rawValue] = glGetUniformLocation(self.program, "colorConversionMatrix")
        
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
        guard let sourceString = try? String(contentsOf: url, encoding: .utf8) else {
            print("Failed to load vertex shader")
            return false
        }
        
        let status: UnsafeMutablePointer<GLint> = UnsafeMutablePointer<GLint>.allocate(capacity: 1)
        status.initialize(to: 0)
        var source: UnsafePointer<GLchar>?
       
        let ccharSource = sourceString.cString(using: .utf8)
        let capacity = (ccharSource?.count)!
        let mutableSource = UnsafeMutablePointer<GLchar>.allocate(capacity: capacity)
        mutableSource.initialize(from: (ccharSource)!, count: (ccharSource?.count)!)
        source = UnsafePointer<GLchar>.init(mutableSource)
        defer {
            status.deallocate()
            source?.deallocate()
        }
        shader.pointee = glCreateShader(type)
        glShaderSource(shader.pointee, 1, &source, nil)
        glCompileShader(shader.pointee)
        
        #if DEBUG
        let logLength = UnsafeMutablePointer<GLint>.allocate(capacity: 1)
        logLength.initialize(to: 0)
        glGetShaderiv(shader.pointee, GLenum(GL_INFO_LOG_LENGTH), logLength)
        if logLength.pointee > 0 {
            let log = UnsafeMutablePointer<GLchar>.allocate(capacity: 1024 * 1024)
            glGetShaderInfoLog(shader.pointee, logLength.pointee, logLength, log)
            print("Shader compile log:\n \(log)")
            log.deallocate()
        }
        logLength.deallocate()
        #endif
        
        glGetShaderiv(shader.pointee, GLenum(GL_COMPILE_STATUS), status)
        if status.pointee == 0 {
            glDeleteShader(shader.pointee)
            return false
        }
        
        return true
    }
    
    private func linkProgram(_ program: GLuint) -> Bool {
        let status = UnsafeMutablePointer<GLint>.allocate(capacity: 1)
        status.initialize(to: 0)
        glLinkProgram(program)
        defer {
            status.deallocate()
        }
        
        #if DEBUG
        let logLength = UnsafeMutablePointer<GLint>.allocate(capacity: 1)
        logLength.initialize(to: 0)
        glGetProgramiv(program, GLenum(GL_INFO_LOG_LENGTH), logLength)
        if logLength.pointee > 0 {
            let log = UnsafeMutablePointer<GLchar>.allocate(capacity: Int(logLength.pointee))
            glGetProgramInfoLog(program, logLength.pointee, logLength, log)
            print("Program link log:\n \(log)")
            log.deallocate()
        }
        defer {
            logLength.deallocate()
        }
        #endif
        
        glGetProgramiv(program, GLenum(GL_LINK_STATUS), status)
        if status.pointee == 0 {
            return false
        }
        
        return true
    }
    
    private func validateProgram(_ program: GLuint) -> Bool {
        let status = UnsafeMutablePointer<GLint>.allocate(capacity: 1)
        status.deallocate()
        let logLength = UnsafeMutablePointer<GLint>.allocate(capacity: 1)
        logLength.initialize(to: 0)
        defer {
            status.deallocate()
            logLength.deallocate()
        }
        
        glValidateProgram(program)
        glGetProgramiv(program, GLenum(GL_INFO_LOG_LENGTH), logLength)
        if logLength.pointee > 0 {
            let log = UnsafeMutablePointer<GLchar>.allocate(capacity: Int(logLength.pointee))
            glGetProgramInfoLog(program, logLength.pointee, logLength, log)
            print("Program validate log:\n \(log)")
            log.deallocate()
        }
        
        glGetProgramiv(program, GLenum(GL_VALIDATE_STATUS), status)
        if status.pointee == 0 {
            return false
        }
        
        return true
    }
}

// MARK: Conversion

extension EAGLView {
    
    /// Color Conversion Constants (YUV to RGB) including adjustment from 16-235/16-240 (video range)
    /// BT.601, which is the standard for SDTV.
    private var colorConversionPointer601: UnsafePointer<GLfloat>? {
        var colorConversion601: [GLfloat] = [
            1.164, 1.164, 1.164,
            0.0, -0.392, 2.017,
            1.596, -0.813, 0.0,
            ]
        
        /// 这里使用Array的withUnsafeMutableBufferPointer方法将数组元素内容转为
        /// 指向一个连续存储空间的首地址。
        let pointer601 = colorConversion601.withUnsafeMutableBufferPointer() {
            (buffer: inout UnsafeMutableBufferPointer<GLfloat>) -> UnsafeMutablePointer<GLfloat>? in
            return buffer.baseAddress
        }
        return UnsafePointer(pointer601)
    }
    
    /// BT.709, which is the standard for HDTV.
    private var colorConversionPointer709: UnsafePointer<GLfloat>? {
        var colorConversion709: [GLfloat] = [
            1.164, 1.164, 1.164,
            0.0, -0.213, 2.112,
            1.793, -0.533, 0.0,
            ]
        let pointer709 = colorConversion709.withUnsafeMutableBufferPointer() {
            (buffer: inout UnsafeMutableBufferPointer<GLfloat>) -> UnsafeMutablePointer<GLfloat>? in
            return buffer.baseAddress
        }
        return UnsafePointer(pointer709)
    }
    
}
