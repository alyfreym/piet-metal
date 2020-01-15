//  Copyright 2019 The xi-editor authors.

#include <metal_stdlib>
using namespace metal;

#include "GenTypes.h"

struct RenderData {
    float4 clipSpacePosition [[position]];
    float2 textureCoordinate;
    float pointSize [[point_size]];
    half4 solidColor;
};

vertex RenderData
vertexShader(uint vertexID [[ vertex_id ]],
             constant RenderVertex *vertexArray [[ buffer(RenderVertexInputIndexVertices) ]],
             texture2d<half> loTexture [[texture(0)]])
{
    RenderData out;
    float2 clipSpacePosition = vertexArray[vertexID].position;
    out.clipSpacePosition.xy = clipSpacePosition;
    out.clipSpacePosition.z = 0.0;
    out.clipSpacePosition.w = 1.0;
    float2 xy = vertexArray[vertexID].textureCoordinate;
    out.textureCoordinate = xy;
    out.pointSize = 16;
    uint2 tileXY = uint2(xy.x / tileWidth, xy.y / tileHeight);
    out.solidColor = loTexture.read(tileXY);
    return out;
}

fragment half4 fragmentShader(RenderData in [[stage_in]],
                               texture2d<half> texture [[texture(0)]]) {
    const half4 loSample = in.solidColor;
    if (loSample.a == 0.0) {
        uint2 coords = uint2(in.clipSpacePosition.xy);
        const half4 sample = texture.read(coords);
        return sample;
    } else {
        return loSample;
    }
}

// Distance field rendering of strokes

// Accumulate distance field.
void stroke(thread float &df, float2 pos, float2 start, float2 end) {
    float2 lineVec = end - start;
    float2 dPos = pos - start;
    float t = saturate(dot(lineVec, dPos) / dot(lineVec, lineVec));
    float field = length(lineVec * t - dPos);
    df = min(df, field);
}

// TODO: figure out precision so we can move more stuff to half
half renderDf(float df, float halfWidth) {
    return saturate(halfWidth + 0.5 - df);
}

/*
// TODO: this should be in the autogenerated output
void Cmd_write_tag(device char *buf, CmdRef ref, uint tag) {
    ((device Cmd *)(buf + ref))->tag = tag;
}
 */

struct TileEncoder {
public:
    TileEncoder(device char *dst) {
        this->dst = dst;
        this->tileBegin = dst;
        this->solidColor = 0xffffffff;
    }
    void encodeCircle(ushort4 bbox) {
        CmdCirclePacked cmd;
        cmd.tag = Cmd_Circle;
        cmd.bbox = bbox;
        CmdCircle_write(dst, 0, cmd);
        solidColor = 0;
        dst += sizeof(Cmd);
    }
    void encodeLine(float2 start, float2 end) {
        CmdLinePacked cmd;
        cmd.tag = Cmd_Line;
        cmd.start = start;
        cmd.end = end;
        CmdLine_write(dst, 0, cmd);
        solidColor = 0;
        dst += sizeof(Cmd);
    }
    void encodeStroke(uint rgbaColor, float width) {
        CmdStrokePacked cmd;
        cmd.tag = Cmd_Stroke;
        cmd.rgba_color = rgbaColor;
        cmd.halfWidth = 0.5 * width;
        CmdStroke_write(dst, 0, cmd);
        solidColor = 0;
        dst += sizeof(Cmd);
    }
    void encodeFill(float2 start, float2 end) {
        CmdFillPacked cmd;
        cmd.tag = Cmd_Fill;
        cmd.start = start;
        cmd.end = end;
        CmdFill_write(dst, 0, cmd);
        dst += sizeof(Cmd);
    }
    void encodeFillEdge(float sign, float y) {
        CmdFillEdgePacked cmd;
        cmd.tag = Cmd_FillEdge;
        cmd.sign = sign;
        cmd.y = y;
        CmdFillEdge_write(dst, 0, cmd);
        dst += sizeof(Cmd);
    }
    void encodeDrawFill(const thread PietFillPacked &fill, int backdrop) {
        CmdDrawFillPacked cmd;
        cmd.tag = Cmd_DrawFill;
        cmd.backdrop = backdrop;
        cmd.rgba_color = fill.rgba_color;
        CmdDrawFill_write(dst, 0, cmd);
        solidColor = 0;
        dst += sizeof(Cmd);
    }
    void encodeSolid(uint rgba) {
        // A fun optimization would be to alpha-composite semi-opaque
        // solid blocks.
        
        // Another optimization is to skip encoding the default bg color.
        if ((rgba & 0xff000000) == 0xff000000) {
            solidColor = rgba;
            dst = tileBegin;
        }
        CmdSolidPacked cmd;
        // Note: could defer writing, not sure how much of a win that is
        cmd.tag = Cmd_Solid;
        cmd.rgba_color = rgba;
        CmdSolid_write(dst, 0, cmd);
        dst += sizeof(Cmd);
    }
    // return solid color
    uint end() {
        if (solidColor) {
            Cmd_write_tag(tileBegin, 0, Cmd_Bail);
        } else {
            Cmd_write_tag(dst, 0, Cmd_End);
        }
        return solidColor;
    }
private:
    // Pointer to command buffer for tile.
    device char *dst;
    device char *tileBegin;
    uint solidColor;
};

// Traverse the scene graph and produce a command list for a tile.
kernel void
tileKernel(device const char *scene [[buffer(0)]],
           device char *tiles [[buffer(1)]],
           texture2d<half, access::write> outTexture [[texture(0)]],
           uint2 gid [[thread_position_in_grid]],
           uint tix [[thread_index_in_threadgroup]])
{
    uint tileIx = gid.y * maxTilesWidth + gid.x;
    ushort x0 = gid.x * tileWidth;
    ushort y0 = gid.y * tileHeight;
    device char *dst = tiles + tileIx * tileBufSize;
    TileEncoder encoder(dst);
    // TODO: correct calculation of size
    const ushort tgs = tilerGroupWidth * tilerGroupHeight;
    const ushort nBitmap = tgs / 32;
    threadgroup atomic_uint bitmap;
    threadgroup uint rd;
    const memory_order relaxed = memory_order::memory_order_relaxed;

    // Size of the region covered by one SIMD group. TODO, don't hardcode.
    const ushort stw = tilerGroupWidth * tileWidth;
    const ushort sth = tilerGroupHeight * tileHeight;
    ushort sx0 = x0 & ~(stw - 1);
    ushort sy0 = y0 & ~(sth - 1);
    
    SimpleGroupRef group_ref = 0;
    // TODO: write accessor functions for variable-sized array here
    device const SimpleGroupPacked *group = (device const SimpleGroupPacked *)scene;
    device const ushort4 *bboxes = (device const ushort4 *)&group->bbox;
    uint n = SimpleGroup_n_items(scene, group_ref);
    PietItemRef items_ref = SimpleGroup_items_ix(scene, group_ref);
    for (uint i = 0; i < n; i += tgs) {
        if (tix < nBitmap) {
            atomic_store_explicit(&bitmap, 0, relaxed);
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);
        if (i + tix < n) {
            ushort4 bbox = bboxes[i + tix];
            if (bbox.z >= sx0 && bbox.x < sx0 + stw && bbox.w >= sy0 && bbox.y < sy0 + sth) {
                uint mask = 1 << (tix & 31);
                atomic_fetch_or_explicit(&bitmap, mask, relaxed);
            }
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);
        if (tix == 0) {
            rd = atomic_load_explicit(&bitmap, relaxed);
            atomic_store_explicit(&bitmap, 0, relaxed);
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);
        //for (ushort bitmapIx = 0; bitmapIx <= bitmapCount; bitmapIx++) {
            uint v = rd;
            while (v) {
                uint ix = i + ctz(v);
                ushort4 bbox = bboxes[ix];
                bool hit = bbox.z >= x0 && bbox.x < x0 + tileWidth && bbox.w >= y0 && bbox.y < y0 + tileHeight;
                PietItemRef item_ref = items_ref + ix * sizeof(PietItem);
                ushort itemType = PietItem_tag(scene, item_ref);
                switch (itemType) {
                    case PIET_ITEM_CIRCLE:
                        if (hit) {
                            encoder.encodeCircle(bbox);
                        }
                        break;
                    case PIET_ITEM_LINE: {
                        // set up line equation, ax + by + c = 0
                        if (hit) {
                            PietStrokeLinePacked line = PietStrokeLine_read(scene, item_ref);
                            float a = line.end.y - line.start.y;
                            float b = line.start.x - line.end.x;
                            float c = -(a * line.start.x + b * line.start.y);
                            // TODO: is this bound as tight as it can be?
                            float hw = 0.5 * line.width + 0.5;
                            float left = a * (x0 - hw);
                            float right = a * (x0 + tileWidth + hw);
                            float top = b * (y0 - hw);
                            float bot = b * (y0 + tileHeight + hw);
                            // If all four corners are on same side of line, cull
                            float s00 = sign(top + left + c);
                            float s01 = sign(top + right + c);
                            float s10 = sign(bot + left + c);
                            float s11 = sign(bot + right + c);
                            if (s00 * s01 + s00 * s10 + s00 * s11 < 3.0) {
                                encoder.encodeLine(line.start, line.end);
                                encoder.encodeStroke(line.rgba_color, line.width);
                            }
                        }
                        break;
                    }
                    case PIET_ITEM_FILL: {
                        PietFillPacked fill = PietFill_read(scene, item_ref);
                        device const float2 *pts = (device const float2 *)(scene + fill.points_ix);
                        uint nPoints = fill.n_points;
                        float backdrop = 0;
                        bool anyFill = false;
                        // use simd ballot to quick-reject segments with no contribution
                        // Note: we just do 16 at a time for now, there's the option of doing
                        // a 16x2 strip of tiles, with more complexity in the left-ray test.
                        for (uint j = 0; j < nPoints; j += 16) {
                            bool fillHit = false;
                            uint fillIx = j + (tix & 15);
                            if (fillIx < nPoints) {
                                float2 start = pts[fillIx];
                                float2 end = pts[fillIx + 1 == nPoints ? 0 : fillIx + 1];
                                float2 xymin = min(start, end);
                                float2 xymax = max(start, end);
                                if (xymax.y >= y0 && xymin.y < y0 + tileHeight && xymin.x < sx0 + stw) {
                                    // set up line equation, ax + by + c = 0
                                    float a = end.y - start.y;
                                    float b = start.x - end.x;
                                    float c = -(a * start.x + b * start.y);
                                    float left = a * sx0;
                                    float right = a * (sx0 + stw);
                                    float ytop = max(float(y0), xymin.y);
                                    float ybot = min(float(y0 + tileHeight), xymax.y);
                                    float top = b * ytop;
                                    float bot = b * ybot;
                                    // top left of rightmost tile in strip
                                    float sTopLeft = sign(right - a * (tileWidth) + float(y0) * b + c);
                                    float s00 = sign(top + left + c);
                                    float s01 = sign(top + right + c);
                                    float s10 = sign(bot + left + c);
                                    float s11 = sign(bot + right + c);
                                    if (sTopLeft == sign(a) && xymin.y <= y0) {
                                        // left ray intersects, need backdrop
                                        fillHit = true;
                                    }
                                    if (s00 * s01 + s00 * s10 + s00 * s11 < 3.0 && xymax.x > sx0) {
                                        // intersects strip
                                        fillHit = true;
                                    }
                                    // TODO: maybe avoid boolean - does it cost a register?
                                    if (fillHit) {
                                        atomic_fetch_or_explicit(&bitmap, 1 << tix, relaxed);
                                    }
                                }
                            }
                            threadgroup_barrier(mem_flags::mem_threadgroup);
                            if (tix == 0) {
                                rd = atomic_load_explicit(&bitmap, relaxed);
                                atomic_store_explicit(&bitmap, 0, relaxed);
                            }
                            threadgroup_barrier(mem_flags::mem_threadgroup);
                            uint fillVote = (rd >> (tix & 16)) & 0xffff;
                            while (fillVote) {
                                uint fillSubIx = ctz(fillVote);
                                fillIx = j + fillSubIx;

                                if (hit) {
                                    float2 start = pts[fillIx];
                                    float2 end = pts[fillIx + 1 == nPoints ? 0 : fillIx + 1];
                                    float2 xymin = min(start, end);
                                    float2 xymax = max(start, end);
                                    // Note: no y-based cull here because it's been done in the earlier pass.
                                    // If we change that to do a strip taller than 1 tile, re-introduce here.

                                    // set up line equation, ax + by + c = 0
                                    float a = end.y - start.y;
                                    float b = start.x - end.x;
                                    float c = -(a * start.x + b * start.y);
                                    float left = a * x0;
                                    float right = a * (x0 + tileWidth);
                                    float ytop = max(float(y0), xymin.y);
                                    float ybot = min(float(y0 + tileHeight), xymax.y);
                                    float top = b * ytop;
                                    float bot = b * ybot;
                                    // top left of tile
                                    float sTopLeft = sign(left + float(y0) * b + c);
                                    float s00 = sign(top + left + c);
                                    float s01 = sign(top + right + c);
                                    float s10 = sign(bot + left + c);
                                    float s11 = sign(bot + right + c);
                                    if (sTopLeft == sign(a) && xymin.y <= y0) {
                                        backdrop -= s00;
                                    }
                                    if (xymin.x < x0 && xymax.x > x0) {
                                        float yEdge = mix(start.y, end.y, (start.x - x0) / b);
                                        if (yEdge >= y0 && yEdge < y0 + tileHeight) {
                                            // line intersects left edge of this tile
                                            encoder.encodeFillEdge(s00, yEdge);
                                            if (b > 0.0) {
                                                encoder.encodeFill(start, float2(x0, yEdge));
                                            } else {
                                                encoder.encodeFill(float2(x0, yEdge), end);
                                            }
                                            anyFill = true;
                                        } else if (s00 * s01 + s00 * s10 + s00 * s11 < 3.0) {
                                            encoder.encodeFill(start, end);
                                            anyFill = true;
                                        }
                                    } else if (s00 * s01 + s00 * s10 + s00 * s11 < 3.0
                                               && xymin.x < x0 + tileWidth && xymax.x > x0) {
                                        encoder.encodeFill(start, end);
                                        anyFill = true;
                                    }
                                } // end if (hit)

                                fillVote &= ~(1 << fillSubIx);
                            }
                        }
                        if (anyFill) {
                            encoder.encodeDrawFill(fill, backdrop);
                        } else if (backdrop != 0.0) {
                            encoder.encodeSolid(fill.rgba_color);
                        }
                        break;
                    }
                    case PIET_ITEM_STROKE_POLYLINE: {
                        PietStrokePolyLinePacked poly = PietStrokePolyLine_read(scene, item_ref);
                        device const float2 *pts = (device const float2 *)(scene + poly.points_ix);
                        uint nPoints = poly.n_points - 1;
                        bool anyStroke = false;
                        float hw = 0.5 * poly.width + 0.5;
                        // use simd ballot to quick-reject segments with no contribution
                        for (uint j = 0; j < nPoints; j += 32) {
                            uint polyIx = j + tix;
                            if (polyIx < nPoints) {
                                float2 start = pts[polyIx];
                                float2 end = pts[polyIx + 1];
                                float2 xymin = min(start, end);
                                float2 xymax = max(start, end);
                                if (xymax.y > sy0 - hw && xymin.y < sy0 + sth + hw &&
                                    xymax.x > sx0 - hw && xymin.x < sx0 + stw + hw) {
                                    // set up line equation, ax + by + c = 0
                                    float a = end.y - start.y;
                                    float b = start.x - end.x;
                                    float c = -(a * start.x + b * start.y);
                                    float left = a * (sx0 - hw);
                                    float right = a * (sx0 + stw + hw);
                                    float top = b * (y0 - hw);
                                    float bot = b * (y0 + tileHeight + hw);
                                    float s00 = sign(top + left + c);
                                    float s01 = sign(top + right + c);
                                    float s10 = sign(bot + left + c);
                                    float s11 = sign(bot + right + c);
                                    if (s00 * s01 + s00 * s10 + s00 * s11 < 3.0) {
                                        // intersects strip
                                        atomic_fetch_or_explicit(&bitmap, 1 << tix, relaxed);
                                    }
                                }
                            }
                            threadgroup_barrier(mem_flags::mem_threadgroup);
                            if (tix == 0) {
                                rd = atomic_load_explicit(&bitmap, relaxed);
                                atomic_store_explicit(&bitmap, 0, relaxed);
                            }
                            threadgroup_barrier(mem_flags::mem_threadgroup);
                            uint polyVote = rd;
                            while (polyVote) {
                                uint polySubIx = ctz(polyVote);
                                polyIx = j + polySubIx;
                                
                                if (hit) {
                                    float2 start = pts[polyIx];
                                    float2 end = pts[polyIx + 1];
                                    float2 xymin = min(start, end);
                                    float2 xymax = max(start, end);
                                    if (xymax.y > y0 - hw && xymin.y < y0 + tileHeight + hw &&
                                        xymax.x > x0 - hw && xymin.x < x0 + tileWidth + hw) {
                                        float a = end.y - start.y;
                                        float b = start.x - end.x;
                                        float c = -(a * start.x + b * start.y);
                                        float hw = 0.5 * poly.width + 0.5;
                                        float left = a * (x0 - hw);
                                        float right = a * (x0 + tileWidth + hw);
                                        float top = b * (y0 - hw);
                                        float bot = b * (y0 + tileHeight + hw);
                                        // If all four corners are on same side of line, cull
                                        float s00 = sign(top + left + c);
                                        float s01 = sign(top + right + c);
                                        float s10 = sign(bot + left + c);
                                        float s11 = sign(bot + right + c);
                                        if (s00 * s01 + s00 * s10 + s00 * s11 < 3.0) {
                                            encoder.encodeLine(start, end);
                                            anyStroke = true;
                                        }
                                    }
                                } // end if (hit)
                                
                                polyVote &= ~(1 << polySubIx);
                            }
                        }
                        if (anyStroke) {
                            encoder.encodeStroke(poly.rgba_color, poly.width);
                        }
                        break;
                    }
                } // end switch(itemType);
                v &= v - 1;
            } // end while (v)
            threadgroup_barrier(mem_flags::mem_threadgroup);
        //} // end for (bitmapIx)
    }
    uint solidColor = encoder.end();
    outTexture.write(unpack_unorm4x8_to_half(solidColor), gid);
}

// Interpret the commands in the command list to produce a pixel.
kernel void
renderKernel(texture2d<half, access::write> outTexture [[texture(0)]],
             const device char *tiles [[buffer(0)]],
             uint2 gid [[thread_position_in_grid]],
             uint2 tgid [[threadgroup_position_in_grid]])
{
    uint tileIx = tgid.y * maxTilesWidth + tgid.x;
    const device char *src = tiles + tileIx * tileBufSize;
    uint x = gid.x;
    uint y = gid.y;
    float2 xy = float2(x, y);

    // Render state (maybe factor out?)
    half3 rgb = half3(1.0);
    float df = 1e9;
    half signedArea = 0.0;

    while (1) {
        Cmd cmd = Cmd_read(src, 0);
        uint tag = cmd.tag;
        if (tag == Cmd_End) {
            break;
        }
        switch (tag) {
            case Cmd_Circle: {
                CmdCirclePacked circle = CmdCircle_load(cmd);
                ushort4 bbox = circle.bbox;
                float2 xy0 = float2(bbox.x, bbox.y);
                float2 xy1 = float2(bbox.z, bbox.w);
                float2 center = mix(xy0, xy1, 0.5);
                float r = length(xy - center);
                // I should make this shade an ellipse properly but am too lazy.
                // But see WebRender ellipse.glsl (linked in notes)
                float circleR = min(center.x - xy0.x, center.y - xy0.y);
                float alpha = saturate(circleR - r);
                rgb = mix(rgb, half3(0.0), alpha);
                break;
            }
            case Cmd_Line: {
                CmdLinePacked line = CmdLine_load(cmd);
                stroke(df, xy, line.start, line.end);
                break;
            }
            case Cmd_Stroke: {
                CmdStrokePacked stroke = CmdStroke_load(cmd);
                half alpha = renderDf(df, stroke.halfWidth);
                half4 fg = unpack_unorm4x8_srgb_to_half(stroke.rgba_color);
                rgb = mix(rgb, fg.rgb, fg.a * alpha);
                df = 1e9;
                break;
            }
            case Cmd_Fill: {
                CmdFillPacked fill = CmdFill_load(cmd);
                float2 start = fill.start - xy;
                float2 end = fill.end - xy;
                float2 window = saturate(float2(start.y, end.y));
                // maybe should be an epsilon test for better numerical stability
                if (window.x != window.y) {
                    float2 t = (window - start.y) / (end.y - start.y);
                    float2 xs = mix(float2(start.x), float2(end.x), t);
                    // This fudge factor might be inadequate when xmax is large, could
                    // happen with small slopes.
                    float xmin = min(min(xs.x, xs.y), 1.0) - 1e-6;
                    float xmax = max(xs.x, xs.y);
                    float b = min(xmax, 1.0);
                    float c = max(b, 0.0);
                    float d = max(xmin, 0.0);
                    float area = (b + 0.5 * (d * d - c * c) - xmin) / (xmax - xmin);
                    // TODO: evaluate accuracy loss from more use of half
                    signedArea += half(area * (window.x - window.y));
                }
                break;
            }
            case Cmd_FillEdge: {
                CmdFillEdgePacked fill = CmdFillEdge_load(cmd);
                signedArea += fill.sign * saturate(y - fill.y + 1);
                break;
            }
            case Cmd_DrawFill: {
                CmdDrawFillPacked draw = CmdDrawFill_load(cmd);
                half alpha = signedArea + half(draw.backdrop);
                alpha = min(abs(alpha), 1.0h); // nonzero winding rule
                // even-odd is: alpha = abs(alpha - 2.0 * round(0.5 * alpha))
                // also: abs(2 * fract(0.5 * (x - 1.0)) - 1.0)
                half4 fg = unpack_unorm4x8_srgb_to_half(draw.rgba_color);
                rgb = mix(rgb, fg.rgb, fg.a * alpha);
                signedArea = 0.0;
                break;
            }
            case Cmd_Solid: {
                CmdSolidPacked solid = CmdSolid_load(cmd);
                half4 fg = unpack_unorm4x8_srgb_to_half(solid.rgba_color);
                rgb = mix(rgb, fg.rgb, fg.a);
                break;
            }
            case Cmd_Bail:
                return;
            // This case shouldn't happen, but we'll keep it for debugging.
            default:
                outTexture.write(half4(1.0, 0.0, 1.0, 1.0), gid);
                return;
        }
        src += sizeof(Cmd);
    }
    // Linear to sRGB conversion. Note that if we had writable sRGB textures
    // we could let this be done in the write call.
    rgb = select(1.055 * pow(rgb, 1/2.4) - 0.055, 12.92 * rgb, rgb < 0.0031308);
    half4 rgba = half4(rgb, 1.0);
    outTexture.write(rgba, gid);
}
