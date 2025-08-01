// Copyright 2024 the Vello Authors
// SPDX-License-Identifier: Apache-2.0 OR MIT

// A WGSL shader for rendering sparse strips with alpha blending.
//
// Each strip instance represents a horizontal slice of the rendered output and consists of:
// 1. A variable-width region of alpha values for semi-transparent rendering
// 2. A solid color region for fully opaque areas
//
// The alpha values are stored in a texture and sampled during fragment shading.
// This approach optimizes memory usage by only storing alpha data where needed.
//
//
// `StripInstance::paint` field encodes a color source, a paint type and a paint texture id
// Color source determines where the fragment shader gets color data from
// Paint type determines how the fragment shader uses the color data
// Paint texture id locates the encoded image data `EncodedImage` in `encoded_paints_texture`
// More details in the `StripInstance` documentation below.
//
// `StripInstance::payload` field can either encode a color, [x, y] for image sampling or a slot index
// - If color source is payload and the paint type is solid, the fragment shader uses the color directly.
// - If color source is payload and the paint type is image, the fragment shader samples the image.
// - Otherwise, the fragment shader samples the source clip texture using the given slot index.
// More details in the `StripInstance` documentation below.


// Color source modes - where the fragment shader gets color data from
// Use payload (color or image coordinates)
const COLOR_SOURCE_PAYLOAD: u32 = 0u;
// Sample from clip texture slot
const COLOR_SOURCE_SLOT: u32 = 1u;

// Paint types
const PAINT_TYPE_SOLID: u32 = 0u;  
const PAINT_TYPE_IMAGE: u32 = 1u;  

// Image quality
const IMAGE_QUALITY_LOW = 0u;
const IMAGE_QUALITY_MEDIUM = 1u;
const IMAGE_QUALITY_HIGH = 2u;

struct Config {
    // Width of the rendering target
    width: u32,
    // Height of the rendering target
    height: u32,
    // Height of a strip in the rendering
    // CAUTION: When changing this value, you must also update the fragment shader's
    // logic to handle the new strip height.
    strip_height: u32,
    // Number of trailing zeros in alphas_tex_width (log2 of width).
    // Pre-calculated on CPU since WebGL2 doesn't support `firstTrailingBit`.
    alphas_tex_width_bits: u32,
}

// Strip instance data
//
// The `paint` field is packed with metadata that controls how `payload` is interpreted:
//
// `paint` bit layout:
//   - Bit 31:     `color_source`      0 = use payload, 1 = use slot texture
//   - Bits 29-30: `paint_type`        0 = solid, 1 = image (only used when color_source = 0)
//   - Bits 0-28:  Usage depends on color_source:
//                 - When color_source = 0 and paint_type = 1: `paint_texture_id` (index of `EncodedImage`)
//                 - When color_source = 1: bits 0-7 contain opacity (0-255)
//
// Decision tree for paint/payload interpretation:
//
// color_source = 0 (COLOR_SOURCE_PAYLOAD) - Use payload data directly
// ├── paint_type = 0 (PAINT_TYPE_SOLID) - Solid color rendering
// │   └── payload = [r, g, b, a] RGBA (packed as u8s)
// │
// └── paint_type = 1 (PAINT_TYPE_IMAGE) - Image rendering
//     ├── payload = [x, y] scene coordinates (packed as u16s)
//     └── bits 0-28 = paint_texture_id
//
// color_source = 1 (COLOR_SOURCE_SLOT) - Use slot texture
// ├── payload = slot_index (u32)
// └── bits 0-7 = opacity (0-255, where 255 = fully opaque)
struct StripInstance {
    // [x, y] packed as u16's
    // x, y — coordinates of the strip
    @location(0) xy: u32,
    // [width, dense_width] packed as u16's
    // width — width of the strip
    // dense_width — width of the portion where alpha blending should be applied
    @location(1) widths: u32,
    // Alpha texture column index where this strip's alpha values begin
    // There are [`Config::strip_height`] alpha values per column.
    @location(2) col_idx: u32,
    // See StripInstance documentation above.
    @location(3) payload: u32,
    // See StripInstance documentation above.
    @location(4) paint: u32,
}

struct VertexOutput {
    // Render type for the strip
    @location(0) @interpolate(flat) paint: u32,
    // Texture coordinates for the current fragment
    @location(1) tex_coord: vec2<f32>,
    // UV coordinates for the current fragment, used for image sampling
    @location(2) sample_xy: vec2<f32>,
    // Ending x-position of the dense (alpha) region
    @location(3) @interpolate(flat) dense_end: u32,
    // Color value or slot index when alpha is 0
    @location(4) @interpolate(flat) payload: u32,
    // Normalized device coordinates (NDC) for the current vertex
    @builtin(position) position: vec4<f32>,
};

// TODO: Measure performance of moving to a separate group
@group(0) @binding(1)
var<uniform> config: Config;

@group(1) @binding(0)
var atlas_texture: texture_2d<f32>;

@group(2) @binding(0)
var encoded_paints_texture: texture_2d<u32>;

@vertex
fn vs_main(
    @builtin(vertex_index) in_vertex_index: u32,
    instance: StripInstance,
) -> VertexOutput {
    var out: VertexOutput;
    // Map vertex_index (0-3) to quad corners:
    // 0 → (0,0), 1 → (1,0), 2 → (0,1), 3 → (1,1)
    let x = f32(in_vertex_index & 1u);
    let y = f32(in_vertex_index >> 1u);
    // Unpack the x and y coordinates from the packed u32 instance.xy
    let x0 = instance.xy & 0xffffu;
    let y0 = instance.xy >> 16u;
    // Unpack the total width and dense (alpha) width from the packed u32 instance.widths
    let width = instance.widths & 0xffffu;
    let dense_width = instance.widths >> 16u;
    // Calculate the ending x-position of the dense (alpha) region
    // This boundary is used in the fragment shader to determine if alpha sampling is needed
    out.dense_end = instance.col_idx + dense_width;
    // Calculate the pixel coordinates of the current vertex within the strip
    let pix_x = f32(x0) + x * f32(width);
    let pix_y = f32(y0) + y * f32(config.strip_height);
    // Convert pixel coordinates to normalized device coordinates (NDC)
    // NDC ranges from -1 to 1, with (0,0) at the center of the viewport
    let ndc_x = pix_x * 2.0 / f32(config.width) - 1.0;
    let ndc_y = 1.0 - pix_y * 2.0 / f32(config.height);
    let paint_type = (instance.paint >> 29u) & 0x3u;

    if paint_type == PAINT_TYPE_IMAGE {
        let paint_tex_id = instance.paint & 0x1FFFFFFF;
        
        let encoded_image = unpack_encoded_image(paint_tex_id);
        // Unpack view coordinates for image sampling
        let scene_strip_x = instance.payload & 0xffffu;
        let scene_strip_y = instance.payload >> 16u;
        // Use view coordinates for image sampling (always in global view space)
        out.sample_xy = encoded_image.translate 
            + encoded_image.image_offset
            + encoded_image.transform.xy * f32(scene_strip_x) 
            + encoded_image.transform.zw * f32(scene_strip_y)
            + encoded_image.transform.xy * x * f32(width)
            + encoded_image.transform.zw * y * f32(config.strip_height);
    }

    // Regular texture coordinates for other render types
    out.tex_coord = vec2<f32>(f32(instance.col_idx) + x * f32(width), y * f32(config.strip_height));
    out.position = vec4<f32>(ndc_x, ndc_y, 0.0, 1.0);
    out.payload = instance.payload;
    out.paint = instance.paint;

    return out;
}

@group(0) @binding(0)
var alphas_texture: texture_2d<u32>;

@group(0) @binding(2)
var clip_input_texture: texture_2d<f32>;

@fragment
fn fs_main(in: VertexOutput) -> @location(0) vec4<f32> {
    let x = u32(floor(in.tex_coord.x));
    var alpha = 1.0;
    // Determine if the current fragment is within the dense (alpha) region
    // If so, sample the alpha value from the texture; otherwise, alpha remains fully opaque (1.0)
    if x < in.dense_end {
        let y = u32(floor(in.tex_coord.y));
        // Retrieve alpha value from the texture. We store 16 1-byte alpha
        // values per texel, with each color channel packing 4 alpha values.
        // The code here assumes the strip height is 4, i.e., each color
        // channel encodes the alpha values for a single column within a strip.
        // Divide x by 4 to get the texel position.
        let alphas_index = x;
        let tex_dimensions = textureDimensions(alphas_texture);
        let alphas_tex_width = tex_dimensions.x;
        // Which texel contains the alpha values for this column
        let texel_index = alphas_index / 4u;
        // Which channel (R,G,B,A) in the texel contains the alpha values for this column
        let channel_index = alphas_index % 4u;
        // Calculate texel coordinates
        let tex_x = texel_index & (alphas_tex_width - 1u);
        let tex_y = texel_index >> config.alphas_tex_width_bits;

        // Load all 4 channels from the texture
        let rgba_values = textureLoad(alphas_texture, vec2<u32>(tex_x, tex_y), 0);

        // Get the column's alphas from the appropriate RGBA channel based on the index
        let alphas_u32 = unpack_alphas_from_channel(rgba_values, channel_index);
        // Extract the alpha value for the current y-position from the packed u32 data
        alpha = f32((alphas_u32 >> (y * 8u)) & 0xffu) * (1.0 / 255.0);
    }
    // Apply the alpha value to the unpacked RGBA color or slot index
    let color_source = (in.paint >> 31u) & 0x1u;
    var final_color: vec4<f32>;

    if color_source == COLOR_SOURCE_PAYLOAD {
        let paint_type = (in.paint >> 29u) & 0x3u;

        // in.payload encodes a color for PAINT_TYPE_SOLID or sample_xy for PAINT_TYPE_IMAGE
        if paint_type == PAINT_TYPE_SOLID {
            final_color = alpha * unpack4x8unorm(in.payload);
        } else if paint_type == PAINT_TYPE_IMAGE {
            let paint_tex_id = in.paint & 0x1FFFFFFF;
            let encoded_image = unpack_encoded_image(paint_tex_id);
            let image_offset = encoded_image.image_offset;
            let image_size = encoded_image.image_size;
            let local_xy = in.sample_xy - image_offset;
            let offset = 0.00001;
            let extended_xy = vec2<f32>(
                extend_mode(local_xy.x, encoded_image.extend_modes.x, image_size.x - offset),
                extend_mode(local_xy.y, encoded_image.extend_modes.y, image_size.y - offset)
            );
            
            if encoded_image.quality == IMAGE_QUALITY_HIGH {
                let final_xy = image_offset + extended_xy;
                let sample_color = bicubic_sample(
                    atlas_texture,
                    final_xy,
                    image_offset,
                    image_size,
                    encoded_image.extend_modes
                );
                final_color = alpha * sample_color;
            } else if encoded_image.quality == IMAGE_QUALITY_MEDIUM {
                let final_xy = image_offset + extended_xy - vec2(0.5);
                let sample_color = bilinear_sample(
                    atlas_texture,
                    final_xy,
                    image_offset,
                    image_size,
                    encoded_image.extend_modes
                );
                final_color = alpha * sample_color;
            } else if encoded_image.quality == IMAGE_QUALITY_LOW {
                let final_xy = image_offset + extended_xy;
                final_color = alpha * textureLoad(atlas_texture, vec2<u32>(final_xy), 0);
            }
        }
    } else {
        // in.payload encodes a slot in the source clip texture
        let clip_x = u32(in.position.x) & 0xFFu;
        let clip_y = (u32(in.position.y) & 3) + in.payload * config.strip_height;
        let clip_in_color = textureLoad(clip_input_texture, vec2(clip_x, clip_y), 0);

        // Extract opacity from first 8 bits (quantized from [0, 255])
        let opacity = f32(in.paint & 0xFFu) * (1.0 / 255.0);

        final_color = alpha * opacity * clip_in_color;
    }

    return final_color;
}


struct EncodedImage {
    /// The rendering quality of the image.
    quality: u32,
    /// The extends in the horizontal and vertical direction.
    extend_modes: vec2<u32>,
    /// The size of the image in pixels.
    image_size: vec2<f32>,
    /// The offset of the image in pixels.
    image_offset: vec2<f32>,
    /// Linear transformation matrix coefficients for 2D affine transformation.
    /// Contains [a, b, c, d] where the transformation matrix is:
    /// This enables scaling, rotation, and skewing of the image coordinates.
    transform: vec4<f32>,
    /// Translation offset for 2D affine transformation.
    /// Contains [tx, ty] representing the translation component.
    translate: vec2<f32>,
}

fn unpack_encoded_image(paint_tex_id: u32) -> EncodedImage {
    let texel0 = textureLoad(encoded_paints_texture, vec2<u32>(paint_tex_id, 0), 0);
    let quality = texel0.x & 0x3u;
    let extend_x = (texel0.x >> 2u) & 0x3u;
    let extend_y = (texel0.x >> 4u) & 0x3u;
    let image_size = vec2<f32>(f32(texel0.y >> 16u), f32(texel0.y & 0xFFFFu));
    let image_offset = vec2<f32>(f32(texel0.z >> 16u), f32(texel0.z & 0xFFFFu));

    let texel1 = textureLoad(encoded_paints_texture, vec2<u32>(paint_tex_id + 1u, 0), 0);
    let texel2 = textureLoad(encoded_paints_texture, vec2<u32>(paint_tex_id + 2u, 0), 0);
    let transform = vec4<f32>(
        bitcast<f32>(texel1.x), bitcast<f32>(texel1.y), 
        bitcast<f32>(texel1.z), bitcast<f32>(texel1.w)
    );
    let translate = vec2<f32>(bitcast<f32>(texel2.x), bitcast<f32>(texel2.y));

    return EncodedImage(
        quality, 
        vec2<u32>(extend_x, extend_y),
        image_size,
        image_offset,
        transform,
        translate
    );
}

fn unpack_alphas_from_channel(rgba: vec4<u32>, channel_index: u32) -> u32 {
    switch channel_index {
        case 0u: { return rgba.x; }
        case 1u: { return rgba.y; }
        case 2u: { return rgba.z; }
        case 3u: { return rgba.w; }
        // Fallback, should never happen
        default: { return rgba.x; }
    }
}

const EXTEND_PAD: u32 = 0u;
const EXTEND_REPEAT: u32 = 1u;
const EXTEND_REFLECT: u32 = 2u;
fn extend_mode(t: f32, mode: u32, max: f32) -> f32 {
    switch mode {
        case EXTEND_PAD: {
            return clamp(t, 0.0, max - 1.0);
        }
        case EXTEND_REPEAT: {
            return extend_mode_normalized(t / max, mode) * max;
        }
        case EXTEND_REFLECT, default: {
            return extend_mode_normalized(t / max, mode) * max;
        }
    }
}

fn extend_mode_normalized(t: f32, mode: u32) -> f32 {
    switch mode {
        case EXTEND_PAD: {
            return clamp(t, 0.0, 1.0);
        }
        case EXTEND_REPEAT: {
            return fract(t);
        }
        case EXTEND_REFLECT, default: {
            return abs(t - 2.0 * round(0.5 * t));
        }
    }
}

// Bilinear filtering
//
// Bilinear filtering consists of sampling the 4 surrounding pixels of the target point and
// interpolating them with a bilinear filter.
fn bilinear_sample(
    tex: texture_2d<f32>,
    coords: vec2<f32>,
    image_offset: vec2<f32>,
    image_size: vec2<f32>,
    extend_modes: vec2<u32>
) -> vec4<f32> {
    let atlas_max = image_offset + image_size - vec2(1.0);
    let atlas_uv_clamped = clamp(coords, image_offset, atlas_max);
    let uv_quad = vec4(floor(atlas_uv_clamped), ceil(atlas_uv_clamped));
    let uv_frac = fract(coords);
    let a = textureLoad(tex, vec2<i32>(uv_quad.xy), 0);
    let b = textureLoad(tex, vec2<i32>(uv_quad.xw), 0);
    let c = textureLoad(tex, vec2<i32>(uv_quad.zy), 0);
    let d = textureLoad(tex, vec2<i32>(uv_quad.zw), 0);
    return mix(mix(a, b, uv_frac.y), mix(c, d, uv_frac.y), uv_frac.x);
}

// Bicubic filtering using Mitchell filter with B=1/3, C=1/3
//
// Cubic resampling consists of sampling the 16 surrounding pixels of the target point and
// interpolating them with a cubic filter. The generated matrix is 4x4 and represent the coefficients
// of the cubic function used to  calculate weights based on the `x_fract` and `y_fract` of the
// location we are looking at.
fn bicubic_sample(
    tex: texture_2d<f32>,
    coords: vec2<f32>,
    image_offset: vec2<f32>,
    image_size: vec2<f32>,
    extend_modes: vec2<u32>,
) -> vec4<f32> {
     let atlas_max = image_offset + image_size - vec2(1.0);
     let frac_coords = fract(coords + 0.5);
     // Get cubic weights for x and y directions
     let cx = cubic_weights(frac_coords.x);
     let cy = cubic_weights(frac_coords.y);
     
     // Sample 4x4 grid around coords
     let s00 = textureLoad(tex, vec2<i32>(clamp(coords + vec2(-1.5, -1.5), image_offset, atlas_max)), 0);
     let s10 = textureLoad(tex, vec2<i32>(clamp(coords + vec2(-0.5, -1.5), image_offset, atlas_max)), 0);
     let s20 = textureLoad(tex, vec2<i32>(clamp(coords + vec2(0.5, -1.5), image_offset, atlas_max)), 0);
     let s30 = textureLoad(tex, vec2<i32>(clamp(coords + vec2(1.5, -1.5), image_offset, atlas_max)), 0);
     
     let s01 = textureLoad(tex, vec2<i32>(clamp(coords + vec2(-1.5, -0.5), image_offset, atlas_max)), 0);
     let s11 = textureLoad(tex, vec2<i32>(clamp(coords + vec2(-0.5, -0.5), image_offset, atlas_max)), 0);
     let s21 = textureLoad(tex, vec2<i32>(clamp(coords + vec2(0.5, -0.5), image_offset, atlas_max)), 0);
     let s31 = textureLoad(tex, vec2<i32>(clamp(coords + vec2(1.5, -0.5), image_offset, atlas_max)), 0);
     
     let s02 = textureLoad(tex, vec2<i32>(clamp(coords + vec2(-1.5, 0.5), image_offset, atlas_max)), 0);
     let s12 = textureLoad(tex, vec2<i32>(clamp(coords + vec2(-0.5, 0.5), image_offset, atlas_max)), 0);
     let s22 = textureLoad(tex, vec2<i32>(clamp(coords + vec2(0.5, 0.5), image_offset, atlas_max)), 0);
     let s32 = textureLoad(tex, vec2<i32>(clamp(coords + vec2(1.5, 0.5), image_offset, atlas_max)), 0);
     
     let s03 = textureLoad(tex, vec2<i32>(clamp(coords + vec2(-1.5, 1.5), image_offset, atlas_max)), 0);
     let s13 = textureLoad(tex, vec2<i32>(clamp(coords + vec2(-0.5, 1.5), image_offset, atlas_max)), 0);
     let s23 = textureLoad(tex, vec2<i32>(clamp(coords + vec2(0.5, 1.5), image_offset, atlas_max)), 0);
     let s33 = textureLoad(tex, vec2<i32>(clamp(coords + vec2(1.5, 1.5), image_offset, atlas_max)), 0);
    
    // Interpolate in x direction for each row
    let row0 = cx.x * s00 + cx.y * s10 + cx.z * s20 + cx.w * s30;
    let row1 = cx.x * s01 + cx.y * s11 + cx.z * s21 + cx.w * s31;
    let row2 = cx.x * s02 + cx.y * s12 + cx.z * s22 + cx.w * s32;
    let row3 = cx.x * s03 + cx.y * s13 + cx.z * s23 + cx.w * s33;
    // Interpolate in y direction
    let result = cy.x * row0 + cy.y * row1 + cy.z * row2 + cy.w * row3;
    
    // Clamp each component to [0,1] and ensure color components don't exceed alpha
    return vec4<f32>(
        min(clamp(result.r, 0.0, 1.0), result.a),
        min(clamp(result.g, 0.0, 1.0), result.a),
        min(clamp(result.b, 0.0, 1.0), result.a),
        min(clamp(result.a, 0.0, 1.0), result.a)
    );
}

// Cubic resampler logic borrowed from Skia (same as CPU cubic_resampler function)
// Mitchell-Netravali cubic filter coefficients with parameters B=1/3 and C=1/3
const MF: array<vec4<f32>, 4> = array<vec4<f32>, 4>(
    vec4<f32>(
        (1.0 / 6.0) / 3.0,
        -(3.0 / 6.0) / 3.0 - 1.0 / 3.0,
        (3.0 / 6.0) / 3.0 + 2.0 * 1.0 / 3.0,
        -(1.0 / 6.0) / 3.0 - 1.0 / 3.0
    ),
    vec4<f32>(
        1.0 - (2.0 / 6.0) / 3.0,
        0.0,
        -3.0 + (12.0 / 6.0) / 3.0 + 1.0 / 3.0,
        2.0 - (9.0 / 6.0) / 3.0 - 1.0 / 3.0
    ),
    vec4<f32>(
        (1.0 / 6.0) / 3.0,
        (3.0 / 6.0) / 3.0 + 1.0 / 3.0,
        3.0 - (15.0 / 6.0) / 3.0 - 2.0 * 1.0 / 3.0,
        -2.0 + (9.0 / 6.0) / 3.0 + 1.0 / 3.0
    ),
    vec4<f32>(
        0.0,
        0.0,
        -1.0 / 3.0,
        (1.0 / 6.0) / 3.0 + 1.0 / 3.0
    )
);

// Calculate the weights for a single fractional value (same as CPU weights function)
fn cubic_weights(fract: f32) -> vec4<f32> {
    return vec4<f32>(
        single_weight(fract, MF[0][0], MF[0][1], MF[0][2], MF[0][3]),
        single_weight(fract, MF[1][0], MF[1][1], MF[1][2], MF[1][3]),
        single_weight(fract, MF[2][0], MF[2][1], MF[2][2], MF[2][3]),
        single_weight(fract, MF[3][0], MF[3][1], MF[3][2], MF[3][3])
    );
}

// Calculate a weight based on the fractional value t and the cubic coefficients
// This matches the CPU implementation exactly
fn single_weight(t: f32, a: f32, b: f32, c: f32, d: f32) -> f32 {
    return t * (t * (t * d + c) + b) + a;
}
