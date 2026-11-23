package renderer

import "../base"
import "../text"
import "core:fmt"
import "core:mem"
import CF "core:sys/darwin/CoreFoundation"
import CG "core:sys/darwin/CoreGraphics"
import NS "core:sys/darwin/Foundation"
import MTL "vendor:darwin/Metal"
import CA "vendor:darwin/QuartzCore"

// build.sh compiles shaders/quad.metal to this file, next to the source copy.
@(private)
SHADERS := #load("quad.metallib")

foreign import libobjc "system:objc"
foreign libobjc {
	objc_release :: proc "c" (object: rawptr) ---
	objc_retain :: proc "c" (object: rawptr) -> rawptr ---
}

@(private)
Uniforms :: struct {
	viewport: [2]f32,
	scroll:   [2]f32,
}

// The device, the command queue and the pipeline are the same for every
// document, so all renderers of the process share them.
@(private)
shared: struct {
	device:   ^MTL.Device,
	queue:    ^MTL.CommandQueue,
	pipeline: ^MTL.RenderPipelineState,
}

@(private)
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

// Quads on the GPU. Each new list gets a new buffer, so a frame that the
// GPU still draws keeps the buffer it was given.
@(private)
Quad_Buffer :: struct {
	buffer: ^MTL.Buffer,
	count:  int,
}

@(private)
Atlas_Texture :: struct {
	texture:    ^MTL.Texture,
	generation: int,
}

Renderer :: struct {
	layer:         ^CA.MetalLayer,
	width, height: f32, // points
	scale:         f32,
	rects:         Quad_Buffer,
	selection:     Quad_Buffer,
	glyphs:        Quad_Buffer,
	gray:          Atlas_Texture,
	color:         Atlas_Texture,
}

init :: proc(r: ^Renderer, surface: rawptr) {
	shared_init()
	r.layer = cast(^CA.MetalLayer)surface
	r.layer->setDevice(shared.device)
	r.layer->setPixelFormat(.BGRA8Unorm)
	r.layer->setFramebufferOnly(true)
}

destroy :: proc(r: ^Renderer) {
	release_objects(r)
	r^ = {}
}

resize :: proc(r: ^Renderer, width, height, scale: f32) {
	r.width, r.height, r.scale = width, height, scale
	r.layer->setContentsScale(f64(scale))
	r.layer->setDrawableSize(CG.Size{f64(width * scale), f64(height * scale)})
}

@(private)
replace_quads :: proc(q: ^Quad_Buffer, quads: []base.Quad) {
	fresh: ^MTL.Buffer
	if len(quads) > 0 {
		size := len(quads) * size_of(base.Quad)
		fresh = shared.device->newBufferWithLength(NS.UInteger(size), {})
		if fresh == nil {
			return // out of memory: keep what the GPU has
		}
		mem.copy_non_overlapping(fresh->contents(), raw_data(quads), size)
	}
	if q.buffer != nil {
		objc_release(q.buffer)
	}
	q.buffer, q.count = fresh, len(quads)
}

set_display :: proc(r: ^Renderer, rects, glyphs: []base.Quad) {
	replace_quads(&r.rects, rects)
	replace_quads(&r.glyphs, glyphs)
}

set_selection :: proc(r: ^Renderer, quads: []base.Quad) {
	replace_quads(&r.selection, quads)
}

// Sends the atlas rows that changed since the last call. `always` makes the
// texture also when the atlas is empty.
@(private)
sync_atlas :: proc(atlas: ^text.Atlas, t: ^Atlas_Texture, format: MTL.PixelFormat, always := false) {
	dirty := atlas.dirty_y1 > atlas.dirty_y0 && atlas.pixels != nil
	if t.texture != nil && t.generation != atlas.generation {
		// The atlas was emptied or grew. A new texture, so a frame that the
		// GPU still draws keeps the old pixels.
		objc_release(t.texture)
		t.texture = nil
		if atlas.pixels != nil && atlas.pen_y + atlas.row_h > 0 {
			atlas.dirty_y0, atlas.dirty_y1 = 0, atlas.pen_y + atlas.row_h
			dirty = true
		}
	}
	if !dirty && !(always && t.texture == nil) {
		return
	}
	if t.texture == nil {
		desc := MTL.TextureDescriptor.texture2DDescriptorWithPixelFormat(format, NS.UInteger(atlas.w), NS.UInteger(atlas.h), false)
		t.texture = shared.device->newTextureWithDescriptor(desc)
		t.generation = atlas.generation
	}
	if t.texture == nil || !dirty {
		return // no texture: the rows stay dirty for the next call
	}
	y0, rows := atlas.dirty_y0, atlas.dirty_y1 - atlas.dirty_y0
	region := MTL.Region{{0, NS.UInteger(y0), 0}, {NS.UInteger(atlas.w), NS.UInteger(rows), 1}}
	t.texture->replaceRegion(region, 0, &atlas.pixels[y0 * atlas.w * atlas.bpp], NS.UInteger(atlas.w * atlas.bpp))
	atlas.dirty_y0, atlas.dirty_y1 = atlas.h, 0
}

sync_atlases :: proc(r: ^Renderer, cache: ^text.Glyph_Cache) {
	if cache.gray.w == 0 {
		return // no scale yet
	}
	// The gray texture always exists, so a page with no text (a rule, only
	// emoji) still draws.
	sync_atlas(&cache.gray, &r.gray, .R8Unorm, true)
	sync_atlas(&cache.color, &r.color, .BGRA8Unorm)
}

@(private)
draw_quads :: proc(enc: ^MTL.RenderCommandEncoder, q: ^Quad_Buffer) {
	if q.count == 0 {
		return
	}
	enc->setVertexBuffer(q.buffer, 0, 0)
	enc->drawPrimitives(.TriangleStrip, 0, 4, NS.UInteger(q.count))
}

// All that one frame draws: a copy of the renderer's state with its own
// references to the buffers and the textures. It is taken while the caller
// holds the view's state and drawn after, so the wait for a drawable holds
// no other call.
Frame :: struct {
	using state: Renderer,
	scroll_px:   f32,
}

// The GPU objects that a renderer, or a frame, has a reference to.
@(private)
objects :: proc(r: ^Renderer) -> [5]rawptr {
	return {r.rects.buffer, r.selection.buffer, r.glyphs.buffer, r.gray.texture, r.color.texture}
}

@(private)
release_objects :: proc(r: ^Renderer) {
	for object in objects(r) {
		if object != nil {
			objc_release(object)
		}
	}
}

frame_begin :: proc(r: ^Renderer, scroll_px: f32) -> Frame {
	for object in objects(r) {
		if object != nil {
			objc_retain(object)
		}
	}
	return Frame{state = r^, scroll_px = scroll_px}
}

// Draws the frame and gives its references back.
frame_draw :: proc(f: ^Frame) {
	defer release_objects(&f.state)
	if shared.pipeline == nil || f.width <= 0 || f.height <= 0 {
		return
	}
	drawable := f.layer->nextDrawable()
	if drawable == nil {
		return
	}
	pass := MTL.RenderPassDescriptor.renderPassDescriptor()
	att := pass->colorAttachments()->objectAtIndexedSubscript(0)
	att->setTexture(drawable->texture())
	att->setLoadAction(.Clear)
	att->setStoreAction(.Store)
	// Transparent: the host view behind the layer paints the page color.
	att->setClearColor(MTL.ClearColor{0, 0, 0, 0})

	cb := shared.queue->commandBuffer()
	enc := cb->renderCommandEncoderWithDescriptor(pass)
	if f.gray.texture != nil {
		uniforms := Uniforms {
			viewport = {f.width * f.scale, f.height * f.scale},
			scroll   = {0, f.scroll_px},
		}
		enc->setRenderPipelineState(shared.pipeline)
		enc->setVertexBytes(&uniforms, size_of(Uniforms), 1)
		enc->setFragmentTexture(f.gray.texture, 0)
		enc->setFragmentTexture(f.color.texture != nil ? f.color.texture : f.gray.texture, 1)
		draw_quads(enc, &f.rects)
		draw_quads(enc, &f.selection)
		draw_quads(enc, &f.glyphs)
	}
	enc->endEncoding()
	cb->presentDrawable(drawable)
	cb->commit()
}
