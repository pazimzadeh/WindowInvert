import CoreVideo
import Metal
import QuartzCore

enum ColorMode: Int32 {
    /// Classic RGB inversion (white -> black).
    case invert = 0
    /// Inverts brightness but keeps hues (red stays reddish), like a "smart invert".
    case huePreserving = 1
}

/// Draws a captured window frame, color-inverted, into a CAMetalLayer.
final class InvertRenderer {
    static let shared = InvertRenderer()

    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private var textureCache: CVMetalTextureCache?

    static let maxHoles = 8

    private struct Params {
        var crop: SIMD4<Float>  // x, y, width, height in normalized texture coordinates
        var mode: Int32
        var holeCount: Int32 = 0
        var holeRadius: Float = 0
        var padding: Float = 0
        /// Rects (x, y, width, height in drawable pixels) left transparent so windows below show through.
        var holes: (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>,
                    SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>) =
            (.zero, .zero, .zero, .zero, .zero, .zero, .zero, .zero)
    }

    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct VOut { float4 position [[position]]; float2 uv; };
    struct Params { float4 crop; int mode; int holeCount; float holeRadius; float padding; float4 holes[8]; };

    vertex VOut invert_vertex(uint vid [[vertex_id]], constant Params &p [[buffer(0)]]) {
        const float2 pos[4] = { float2(-1, -1), float2(1, -1), float2(-1, 1), float2(1, 1) };
        const float2 uv[4]  = { float2(0, 1),   float2(1, 1),  float2(0, 0),  float2(1, 0) };
        VOut o;
        o.position = float4(pos[vid], 0, 1);
        o.uv = p.crop.xy + uv[vid] * p.crop.zw;
        return o;
    }

    fragment float4 invert_fragment(VOut in [[stage_in]],
                                    texture2d<float> tex [[texture(0)]],
                                    constant Params &p [[buffer(0)]]) {
        constexpr sampler s(filter::linear, address::clamp_to_edge);
        float4 c = tex.sample(s, in.uv);
        float a = c.a;
        for (int i = 0; i < p.holeCount; i++) {
            float4 h = p.holes[i];
            float r = min(p.holeRadius, 0.5 * min(h.z, h.w));
            float2 q = abs(in.position.xy - (h.xy + 0.5 * h.zw)) - (0.5 * h.zw - r);
            float d = length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
            a *= saturate(d + 0.5);
            c *= saturate(d + 0.5);
        }
        if (a <= 0.0) { return float4(0.0); }
        float3 rgb = clamp(c.rgb / a, 0.0, 1.0);
        float3 o;
        if (p.mode == 1) {
            float y = dot(rgb, float3(0.299, 0.587, 0.114));
            o = clamp(rgb + (1.0 - 2.0 * y), 0.0, 1.0);
        } else {
            o = 1.0 - rgb;
        }
        return float4(o * a, a);
    }
    """

    private init() {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            fatalError("WindowInvert requires Metal")
        }
        self.device = device
        self.queue = queue
        do {
            let library = try device.makeLibrary(source: Self.shaderSource, options: nil)
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: "invert_vertex")
            descriptor.fragmentFunction = library.makeFunction(name: "invert_fragment")
            descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            fatalError("WindowInvert: failed to build Metal pipeline: \(error)")
        }
        CVMetalTextureCacheCreate(nil, nil, device, nil, &textureCache)
    }

    func configure(_ layer: CAMetalLayer) {
        layer.device = device
        layer.pixelFormat = .bgra8Unorm
        layer.framebufferOnly = true
        layer.isOpaque = false
        layer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        layer.presentsWithTransaction = true
        layer.maximumDrawableCount = 3
    }

    /// Renders `pixelBuffer` cropped to `crop` (normalized, top-left origin). Must be called inside a
    /// CATransaction on the main thread so the new contents appear atomically with any window resize.
    func draw(pixelBuffer: CVPixelBuffer, crop: CGRect, mode: ColorMode,
              holes: [CGRect] = [], holeRadius: CGFloat = 0, into layer: CAMetalLayer) {
        guard let textureCache else { return }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        var cvTexture: CVMetalTexture?
        CVMetalTextureCacheCreateTextureFromImage(nil, textureCache, pixelBuffer, nil, .bgra8Unorm,
                                                  width, height, 0, &cvTexture)
        guard let cvTexture, let texture = CVMetalTextureGetTexture(cvTexture),
              let drawable = layer.nextDrawable(),
              let commandBuffer = queue.makeCommandBuffer() else { return }

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.colorAttachments[0].storeAction = .store

        var params = Params(crop: SIMD4(Float(crop.minX), Float(crop.minY), Float(crop.width), Float(crop.height)),
                            mode: mode.rawValue)
        params.holeCount = Int32(min(holes.count, Self.maxHoles))
        params.holeRadius = Float(holeRadius)
        withUnsafeMutableBytes(of: &params.holes) { raw in
            let slots = raw.bindMemory(to: SIMD4<Float>.self)
            for (i, hole) in holes.prefix(Self.maxHoles).enumerated() {
                slots[i] = SIMD4(Float(hole.minX), Float(hole.minY), Float(hole.width), Float(hole.height))
            }
        }
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBytes(&params, length: MemoryLayout<Params>.stride, index: 0)
        encoder.setFragmentBytes(&params, length: MemoryLayout<Params>.stride, index: 0)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()

        commandBuffer.addCompletedHandler { _ in _ = cvTexture }
        commandBuffer.commit()
        commandBuffer.waitUntilScheduled()
        drawable.present()
    }
}
