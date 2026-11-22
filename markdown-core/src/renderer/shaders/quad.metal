#include <metal_stdlib>
using namespace metal;

// One instance = one quad: `base.Quad` in src/base. All positions are device
// pixels, relative to the origin of the display list.
struct Instance {
    packed_float2 pos;
    packed_float2 size;
    packed_float2 uv;      // glyphs: atlas origin in px. rects: x = corner radius in px
    packed_float2 uvsize;
    uint color;            // r,g,b,a bytes
    uint kind;             // 0 solid rect, 1 gray glyph, 2 color glyph
};

struct Uniforms {
    float2 viewport;       // px
    float2 scroll;         // px, from the origin of the display list
};

struct VOut {
    float4 position [[position]];
    float2 uv;
    float2 local;          // px inside the quad
    float2 size [[flat]];
    float4 color [[flat]];
    float radius [[flat]];
    uint kind [[flat]];
};

vertex VOut vs_main(uint vid [[vertex_id]], uint iid [[instance_id]],
                    const device Instance *inst [[buffer(0)]],
                    constant Uniforms &u [[buffer(1)]]) {
    Instance i = inst[iid];
    float2 corner = float2(vid & 1, vid >> 1);
    float2 size = float2(i.size);
    float2 p = float2(i.pos) + corner * size - u.scroll;
    VOut o;
    o.position = float4(p.x / u.viewport.x * 2.0 - 1.0, 1.0 - p.y / u.viewport.y * 2.0, 0.0, 1.0);
    o.uv = float2(i.uv) + corner * float2(i.uvsize);
    o.local = corner * size;
    o.size = size;
    o.color = float4(float(i.color & 0xff), float((i.color >> 8) & 0xff),
                     float((i.color >> 16) & 0xff), float(i.color >> 24)) / 255.0;
    o.radius = i.kind == 0 ? i.uv.x : 0.0;
    o.kind = i.kind;
    return o;
}

fragment float4 fs_main(VOut in [[stage_in]],
                        texture2d<float> gray [[texture(0)]],
                        texture2d<float> color [[texture(1)]]) {
    if (in.kind == 1) {
        float a = gray.read(uint2(in.uv)).r * in.color.a;
        return float4(in.color.rgb * a, a);
    }
    if (in.kind == 2) {
        return color.read(uint2(in.uv));
    }
    float a = in.color.a;
    if (in.radius > 0.0) {
        float2 half_size = in.size * 0.5;
        float2 q = abs(in.local - half_size) - (half_size - in.radius);
        float d = length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - in.radius;
        a *= clamp(0.5 - d, 0.0, 1.0);
    }
    return float4(in.color.rgb * a, a);
}
