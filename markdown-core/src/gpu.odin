package mdcore

import "core:fmt"
import "core:mem"
import CF "core:sys/darwin/CoreFoundation"
import CG "core:sys/darwin/CoreGraphics"
import NS "core:sys/darwin/Foundation"
import MTL "vendor:darwin/Metal"
import CA "vendor:darwin/QuartzCore"

SHADERS := #load("shaders.metallib")

foreign import libobjc "system:objc"
foreign libobjc {
	objc_release :: proc "c" (object: rawptr) ---
}

Uniforms :: struct {
	viewport: [2]f32,
	scroll:   [2]f32,
}

// The device, the command queue and the pipeline are the same for every
// document, so all renderers of the process share them.
@(private = "file")
shared: struct {
	device:   ^MTL.Device,
	queue:    ^MTL.CommandQueue,
	pipeline: ^MTL.RenderPipelineState,
}

@(private = "file")
shared_init :: proc() {
	if shared.device != nil {
		return
	}
	shared.device = MTL.CreateSystemDefaultDevice()
	shared.queue = shared.device->newCommandQueue()

	data := CF.dispatch_data_create(raw_data(SHADERS), len(SHADERS), nil, nil)
	library, _ := shared.device->newLibraryWithData(data)
	objc_release(data)
	if library == nil {
		fmt.eprintln("mdcore: shader library failed")
		return
	}
	vertex := library->newFunctionWithName(NS.AT("vs_main"))
	fragment := library->newFunctionWithName(NS.AT("fs_main"))
	desc := MTL.RenderPipelineDescriptor.alloc()->init()
	desc->setVertexFunction(vertex)
	desc->setFragmentFunction(fragment)
	att := desc->colorAttachments()->objectAtIndexedSubscript(0)
	att->setPixelFormat(.BGRA8Unorm)
	// Premultiplied alpha.
	att->setBlendingEnabled(true)
	att->setSourceRGBBlendFactor(.One)
	att->setSourceAlphaBlendFactor(.One)
	att->setDestinationRGBBlendFactor(.OneMinusSourceAlpha)
	att->setDestinationAlphaBlendFactor(.OneMinusSourceAlpha)
	shared.pipeline, _ = shared.device->newRenderPipelineStateWithDescriptor(desc)
	if shared.pipeline == nil {
		fmt.eprintln("mdcore: pipeline failed")
	}
	objc_release(desc)
	objc_release(vertex)
	objc_release(fragment)
	objc_release(library)
}

// Quads on the GPU. The buffer keeps what it has and takes only the new
// quads, so a long document that is laid out in steps is not copied again
// at each step.
Gpu_Quads :: struct {
	buffer:   ^MTL.Buffer,
	capacity: int,
	count:    int,
}

@(private = "file")
quads_sync :: proc(q: ^Gpu_Quads, src: []Instance) {
	if len(src) < q.count {
		q.count = 0 // a new layout started
	}
	if len(src) > q.capacity {
		if q.buffer != nil {
			objc_release(q.buffer)
		}
		q.capacity = max(len(src) * 2, 1024)
		q.buffer = shared.device->newBufferWithLength(NS.UInteger(q.capacity * size_of(Instance)), {})
		q.count = 0
	}
	if len(src) > q.count {
		dst := cast([^]Instance)q.buffer->contents()
		mem.copy_non_overlapping(&dst[q.count], raw_data(src[q.count:]), (len(src) - q.count) * size_of(Instance))
	}
	q.count = len(src)
}

@(private = "file")
quads_destroy :: proc(q: ^Gpu_Quads) {
	if q.buffer != nil {
		objc_release(q.buffer)
	}
	q^ = {}
}

gpu_init :: proc(ctx: ^Ctx, layer: ^CA.MetalLayer) {
	shared_init()
	ctx.layer = layer
	layer->setDevice(shared.device)
	layer->setPixelFormat(.BGRA8Unorm)
	layer->setFramebufferOnly(true)
}

gpu_destroy :: proc(ctx: ^Ctx) {
	quads_destroy(&ctx.rect_quads)
	quads_destroy(&ctx.glyph_quads)
	quads_destroy(&ctx.selection_quads)
	if ctx.gray_tex != nil {
		objc_release(ctx.gray_tex)
	}
	if ctx.colr_tex != nil {
		objc_release(ctx.colr_tex)
	}
}

gpu_resize :: proc(ctx: ^Ctx) {
	ctx.layer->setContentsScale(f64(ctx.scale))
	ctx.layer->setDrawableSize(CG.Size{f64(ctx.width * ctx.scale), f64(ctx.height * ctx.scale)})
}

// Sends the atlas rows that changed since the last call.
@(private = "file")
upload_atlas :: proc(atlas: ^Atlas, tex: ^^MTL.Texture, format: MTL.PixelFormat) {
	if atlas.dirty_y1 <= atlas.dirty_y0 || atlas.pixels == nil {
		return
	}
	if tex^ == nil {
		desc := MTL.TextureDescriptor.texture2DDescriptorWithPixelFormat(format, NS.UInteger(atlas.w), NS.UInteger(atlas.h), false)
		tex^ = shared.device->newTextureWithDescriptor(desc)
	}
	y0, rows := atlas.dirty_y0, atlas.dirty_y1 - atlas.dirty_y0
	region := MTL.Region{{0, NS.UInteger(y0), 0}, {NS.UInteger(atlas.w), NS.UInteger(rows), 1}}
	tex^->replaceRegion(region, 0, &atlas.pixels[y0 * atlas.w * atlas.bpp], NS.UInteger(atlas.w * atlas.bpp))
	atlas.dirty_y0, atlas.dirty_y1 = atlas.h, 0
}

// Sends what the layout added: new atlas rows and new quads.
gpu_upload :: proc(ctx: ^Ctx) {
	upload_atlas(&ctx.gray, &ctx.gray_tex, .R8Unorm)
	upload_atlas(&ctx.colr, &ctx.colr_tex, .BGRA8Unorm)
	quads_sync(&ctx.rect_quads, ctx.rects[:])
	quads_sync(&ctx.glyph_quads, ctx.glyphs[:])
}

gpu_upload_selection :: proc(ctx: ^Ctx) {
	ctx.selection_quads.count = 0 // the selection is rebuilt as a whole
	quads_sync(&ctx.selection_quads, ctx.sel_rects[:])
}

@(private = "file")
draw_quads :: proc(enc: ^MTL.RenderCommandEncoder, q: ^Gpu_Quads) {
	if q.count == 0 {
		return
	}
	enc->setVertexBuffer(q.buffer, 0, 0)
	enc->drawPrimitives(.TriangleStrip, 0, 4, NS.UInteger(q.count))
}

gpu_draw :: proc(ctx: ^Ctx) {
	if shared.pipeline == nil || ctx.width <= 0 || ctx.height <= 0 {
		return
	}
	drawable := ctx.layer->nextDrawable()
	if drawable == nil {
		return
	}
	pass := MTL.RenderPassDescriptor.renderPassDescriptor()
	att := pass->colorAttachments()->objectAtIndexedSubscript(0)
	att->setTexture(drawable->texture())
	att->setLoadAction(.Clear)
	att->setStoreAction(.Store)
	att->setClearColor(MTL.ClearColor{1, 1, 1, 1})

	cb := shared.queue->commandBuffer()
	enc := cb->renderCommandEncoderWithDescriptor(pass)
	if ctx.gray_tex != nil {
		uniforms := Uniforms {
			viewport = {ctx.width * ctx.scale, ctx.height * ctx.scale},
			scroll   = {0, f32(int(ctx.scroll * ctx.scale))},
		}
		enc->setRenderPipelineState(shared.pipeline)
		enc->setVertexBytes(&uniforms, size_of(Uniforms), 1)
		enc->setFragmentTexture(ctx.gray_tex, 0)
		enc->setFragmentTexture(ctx.colr_tex != nil ? ctx.colr_tex : ctx.gray_tex, 1)
		// Order: backgrounds, selection, glyphs.
		draw_quads(enc, &ctx.rect_quads)
		draw_quads(enc, &ctx.selection_quads)
		draw_quads(enc, &ctx.glyph_quads)
	}
	enc->endEncoding()
	cb->presentDrawable(drawable)
	cb->commit()
}
