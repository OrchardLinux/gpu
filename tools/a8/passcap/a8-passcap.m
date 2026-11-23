/*
 * SPDX-License-Identifier: MIT
 * Generated-by: LLM
 *
 * a8-passcap (A8 / iOS 12): one Metal render pass per feature the A8 Mesa refuses, so one jailbroken-iOS session
 * gives the encoding iOS uses for each (see a8/n102/SHADERS.md).
 *
 *   a8-passcap -L                                     list the passes
 *   a8-passcap -l passcap.metallib -o OUTDIR [-m MB]  capture: every pass once, own command buffer each; dump this
 *                                                     process's IOAccel regions before commit ("pre") and after
 *                                                     ("post") as a8-shadercap does; status and target readback per
 *                                                     pass (OUTDIR/passes.txt, OUTDIR/<pass>.c0.bin)
 *   a8-passcap -l passcap.metallib -p PASS [-t SEC]   loop: draw PASS every frame for SEC seconds (default 60), for
 *                                                     a kernel-memory reader to read its TA/3D records (not included)
 *
 * Every pass draws the same triangle (passcap.metal v_tri) into 64x64; "base" is metal-triangle's pass (BGRA8,
 * clear, store). Read-only towards the system, as a8-shadercap: own memory, resident pages, no device pager.
 */
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

#include <mach/mach.h>
#include <mach/vm_statistics.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

enum tex_kind { TEX_NONE, TEX_2D, TEX_ARRAY, TEX_CUBE, TEX_ASTC, TEX_NPOT1, TEX_F32, TEX_I32, TEX_CUBE_SOLID };

struct pass {
    const char *name, *frag, *why;
    MTLPixelFormat c[4]; /* colour formats; c[1] Invalid = one target */
    unsigned samples;    /* 1 or 4 */
    int resolve;         /* samples 4: resolve into a 1x target (else store the 4x target) */
    int load;            /* colour loadAction Load */
    int linear;          /* colour target 0 is a linear (buffer-backed) texture */
    MTLPixelFormat ds;   /* Invalid, Depth32Float or Depth32Float_Stencil8 */
    int ds_load;         /* depth/stencil load Load + store Store (else clear + store) */
    enum tex_kind tex;
    int nodraw;          /* round 2: the pass draws nothing (clear and store only) */
    int tex2;            /* round 2: a second texture at index 1 */
    int fbytes;          /* round 2: fragment buffer 0 = kFragBytes (LOD, bias, layer: values the compiler cannot fold) */
    const char *vert;    /* round 2: vertex function (NULL: v_tri) */
    unsigned size;       /* round 2: target side (0: 64) */
    unsigned verts;      /* round 2: vertex count (0: 3) */
    unsigned ntex;       /* round 4: solid-colour textures at indices 0..ntex-1 (kSolid) */
    unsigned nsamp;      /* round 4: distinct sampler states at indices 0..nsamp-1 (1: one shared) */
    unsigned height;     /* round 5: target height (0: the side) */
    int memoryless;      /* round 5: the depth/stencil texture is MTLStorageModeMemoryless (clear, don't store) */
    int vtex;            /* round 7: the texture (and sampler) is bound to the vertex stage too */
    unsigned prefill;    /* round 12: colour target 0 filled from the CPU with this byte before the pass (0: none),
                          * so a loadAction Load pass shows the loaded value outside the triangle */
};

#define BGRA MTLPixelFormatBGRA8Unorm
#define NONE MTLPixelFormatInvalid
/* round 2's fields (nodraw, tex2, fbytes) default to 0 in the round 1 rows */
#pragma clang diagnostic ignored "-Wmissing-field-initializers"
static const struct pass kPasses[] = {
    { "base", "f_solid", "reference (metal-triangle's pass)", { BGRA, NONE }, 1, 0, 0, 0, NONE, 0, TEX_NONE },
    { "ds_clear", "f_solid", "ZLS: D32F_S8, depth+stencil clear, store", { BGRA, NONE }, 1, 0, 0, 0,
      MTLPixelFormatDepth32Float_Stencil8, 0, TEX_NONE },
    { "ds_load", "f_solid", "ZLS: D32F_S8, depth+stencil load, store", { BGRA, NONE }, 1, 0, 0, 0,
      MTLPixelFormatDepth32Float_Stencil8, 1, TEX_NONE },
    { "d32_clear", "f_solid", "ZLS: D32F only, clear, store (separates the stencil words)", { BGRA, NONE }, 1, 0, 0,
      0, MTLPixelFormatDepth32Float, 0, TEX_NONE },
    { "mrt2", "f_mrt2", "two colour targets (BGRA8 + RGBA8)", { BGRA, MTLPixelFormatRGBA8Unorm }, 1, 0, 0, 0, NONE,
      0, TEX_NONE },
    { "msaa4_resolve", "f_solid", "4x MSAA, resolved into 1x", { BGRA, NONE }, 4, 1, 0, 0, NONE, 0, TEX_NONE },
    { "msaa4_store", "f_solid", "4x MSAA, 4x target stored", { BGRA, NONE }, 4, 0, 0, 0, NONE, 0, TEX_NONE },
    { "load", "f_solid", "colour loadAction Load", { BGRA, NONE }, 1, 0, 1, 0, NONE, 0, TEX_NONE },
    { "linear", "f_solid", "linear (buffer-backed) BGRA8 target", { BGRA, NONE }, 1, 0, 0, 1, NONE, 0, TEX_NONE },
    { "r8", "f_solid", "R8Unorm target", { MTLPixelFormatR8Unorm, NONE }, 1, 0, 0, 0, NONE, 0, TEX_NONE },
    { "rg8", "f_solid", "RG8Unorm target", { MTLPixelFormatRG8Unorm, NONE }, 1, 0, 0, 0, NONE, 0, TEX_NONE },
    { "rgba16f", "f_solid", "RGBA16Float target", { MTLPixelFormatRGBA16Float, NONE }, 1, 0, 0, 0, NONE, 0,
      TEX_NONE },
    { "rgb10a2", "f_solid", "RGB10A2Unorm target", { MTLPixelFormatRGB10A2Unorm, NONE }, 1, 0, 0, 0, NONE, 0,
      TEX_NONE },
    { "r32f", "f_solid", "R32Float target", { MTLPixelFormatR32Float, NONE }, 1, 0, 0, 0, NONE, 0, TEX_NONE },
    { "rgba8u", "f_solid_u", "integer target (RGBA8Uint)", { MTLPixelFormatRGBA8Uint, NONE }, 1, 0, 0, 0, NONE, 0,
      TEX_NONE },
    { "tex_plain", "f_tex", "sample a mipmapped BGRA8 texture (texture-state words)", { BGRA, NONE }, 1, 0, 0, 0, NONE,
      0, TEX_2D },
    { "tex_astc", "f_tex", "sample an ASTC 4x4 LDR texture (texture-state words)", { BGRA, NONE }, 1, 0, 0, 0, NONE, 0,
      TEX_ASTC },
    { "tex_lod", "f_tex_lod", "sample, explicit LOD", { BGRA, NONE }, 1, 0, 0, 0, NONE, 0, TEX_2D },
    { "tex_bias", "f_tex_bias", "sample, LOD bias", { BGRA, NONE }, 1, 0, 0, 0, NONE, 0, TEX_2D },
    { "tex_grad", "f_tex_grad", "sample, gradients", { BGRA, NONE }, 1, 0, 0, 0, NONE, 0, TEX_2D },
    { "tex_gather", "f_tex_gather", "gather", { BGRA, NONE }, 1, 0, 0, 0, NONE, 0, TEX_2D },
    { "tex_offset", "f_tex_offset", "sample, texel offset", { BGRA, NONE }, 1, 0, 0, 0, NONE, 0, TEX_2D },
    { "tex_array", "f_tex_array", "2D array sample", { BGRA, NONE }, 1, 0, 0, 0, NONE, 0, TEX_ARRAY },
    { "tex_cube", "f_tex_cube", "cube sample", { BGRA, NONE }, 1, 0, 0, 0, NONE, 0, TEX_CUBE },
    /* round 2 (see a8/n102/SHADERS.md): what the A8 Mesa still refuses for want of a witness */
    { "nodraw", "f_solid", "clear + store with no draw: does Apple skip the TA (the 0x2c8 3D-only command)?",
      { BGRA, NONE }, 1, 0, 0, 0, NONE, 0, TEX_NONE, 1, 0, 0 },
    { "nodraw_full", "f_solid", "nodraw at 64x64 again, a second encoder in the same command buffer after a draw",
      { BGRA, NONE }, 1, 0, 0, 0, NONE, 0, TEX_NONE, 2, 0, 0 },
    { "srgb", "f_solid", "BGRA8Unorm_sRGB target (PBE gamma bits, end-of-tile format word)",
      { MTLPixelFormatBGRA8Unorm_sRGB, NONE }, 1, 0, 0, 0, NONE, 0, TEX_NONE, 0, 0, 0 },
    { "srgb_rgba", "f_solid", "RGBA8Unorm_sRGB target", { MTLPixelFormatRGBA8Unorm_sRGB, NONE }, 1, 0, 0, 0, NONE, 0,
      TEX_NONE, 0, 0, 0 },
    { "tex2", "f_tex2", "two textures in one program, t0 * t1 (the sample's image field)", { BGRA, NONE }, 1, 0, 0, 0,
      NONE, 0, TEX_2D, 0, 1, 0 },
    { "tex_lod_buf", "f_tex_lod_buf", "explicit LOD from a buffer (where the LOD operand comes from)", { BGRA, NONE },
      1, 0, 0, 0, NONE, 0, TEX_2D, 0, 0, 1 },
    { "tex_bias_buf", "f_tex_bias_buf", "LOD bias from a buffer", { BGRA, NONE }, 1, 0, 0, 0, NONE, 0, TEX_2D, 0, 0, 1 },
    { "tex_grad_asym", "f_tex_grad_asym", "gradients (0.01,0.02) (0.03,0.04): the order of the four gradient registers",
      { BGRA, NONE }, 1, 0, 0, 0, NONE, 0, TEX_2D, 0, 0, 0 },
    { "tex_array_buf", "f_tex_array_buf", "2D array sample, layer from a buffer (its type and register)", { BGRA, NONE },
      1, 0, 0, 0, NONE, 0, TEX_ARRAY, 0, 0, 1 },
    { "load_linear", "f_solid", "colour loadAction Load on a linear (buffer-backed) target (the A8 LOAD of linear)",
      { BGRA, NONE }, 1, 0, 1, 1, NONE, 0, TEX_NONE, 0, 0, 0 },
    /* round 3 (update 31): the rest of the A8's capture list */
    { "tex_read", "f_tex_read", "texel read at the fragment position (texelFetch)", { BGRA, NONE }, 1, 0, 0, 0, NONE, 0,
      TEX_2D, 0, 0, 0 },
    { "mrt3", "f_mrt3", "three colour targets (end of tile, emit for 3 targets)", { BGRA, BGRA, BGRA, NONE }, 1, 0, 0, 0,
      NONE, 0, TEX_NONE, 0, 0, 0 },
    { "mrt4", "f_mrt4", "four colour targets", { BGRA, BGRA, BGRA, BGRA }, 1, 0, 0, 0, NONE, 0, TEX_NONE, 0, 0, 0 },
    { "iter_modes", "f_iter", "flat, no-perspective and centroid varyings, w != 1 (the iterator modes)", { BGRA, NONE },
      1, 0, 0, 0, NONE, 0, TEX_NONE, 0, 0, 0, "v_iter", 0, 0 },
    { "pr_big", "f_solid", "30000 full-screen triangles into 1024x1024, D32F: overflows the parameter buffer (partial "
      "render, context store/resume)", { BGRA, NONE }, 1, 0, 0, 0, MTLPixelFormatDepth32Float, 0, TEX_NONE, 0, 0, 0,
      "v_big", 1024, 90000 },
    { "tex_npot1", "f_tex", "an 800x600 one-level texture, minified into 64x64 (texture state, allocatedSize)",
      { BGRA, NONE }, 1, 0, 0, 0, NONE, 0, TEX_NPOT1, 0, 0, 0 },
    { "tex_lod_var", "f_tex_lod_var", "explicit LOD from a varying (a temp operand)", { BGRA, NONE }, 1, 0, 0, 0, NONE,
      0, TEX_2D, 0, 0, 0 },
    /* round 4 (update 41): 2-7 textures, one shared sampler or one per texture; solid colours (kSolid) */
    { "tex2s", "f_tex2s", "2 textures, 2 samplers", { BGRA, NONE }, 1, 0, 0, 0, NONE, 0, TEX_NONE, 0, 0, 0, NULL, 0, 0,
      2, 2 },
    { "tex3s", "f_tex3s", "3 textures, 3 samplers", { BGRA, NONE }, 1, 0, 0, 0, NONE, 0, TEX_NONE, 0, 0, 0, NULL, 0, 0,
      3, 3 },
    { "tex4", "f_tex4", "4 textures, 1 shared sampler", { BGRA, NONE }, 1, 0, 0, 0, NONE, 0, TEX_NONE, 0, 0, 0, NULL, 0,
      0, 4, 1 },
    { "tex4s", "f_tex4s", "4 textures, 4 samplers", { BGRA, NONE }, 1, 0, 0, 0, NONE, 0, TEX_NONE, 0, 0, 0, NULL, 0, 0,
      4, 4 },
    { "tex5", "f_tex5", "5 textures, 1 shared sampler", { BGRA, NONE }, 1, 0, 0, 0, NONE, 0, TEX_NONE, 0, 0, 0, NULL, 0,
      0, 5, 1 },
    { "tex5s", "f_tex5s", "5 textures, 5 samplers", { BGRA, NONE }, 1, 0, 0, 0, NONE, 0, TEX_NONE, 0, 0, 0, NULL, 0, 0,
      5, 5 },
    { "tex7", "f_tex7", "7 textures, 1 shared sampler (MultiEffect's most)", { BGRA, NONE }, 1, 0, 0, 0, NONE, 0,
      TEX_NONE, 0, 0, 0, NULL, 0, 0, 7, 1 },
    /* round 7: WebRender's GL path: texelFetch of float and integer data textures in the fragment and the vertex
     * stage, and a vertex-stage sample. vread_f32 is last: its vertex PDS data (the texture state DMA'd for the
     * vertex stage) is the block the post snapshot keeps. */
    { "read_f32", "f_read_f32", "fragment texel read of a 4x4 RGBA32Float (texelFetch)", { BGRA, NONE }, 1, 0, 0, 0,
      NONE, 0, TEX_F32 },
    { "read_i32", "f_read_i32", "fragment texel read of a 4x4 RGBA32Sint (isampler2D texelFetch)", { BGRA, NONE }, 1,
      0, 0, 0, NONE, 0, TEX_I32 },
    { "vread_i32", "f_vcolor", "vertex-stage texel read of RGBA32Sint (WebRender's primitive headers)", { BGRA, NONE },
      1, 0, 0, 0, NONE, 0, TEX_I32, 0, 0, 0, "v_read_i32", 0, 0, 0, 0, 0, 0, 1 },
    { "vsample", "f_vcolor", "vertex-stage sample at level 0 of the 64x64 BGRA8 mip chain", { BGRA, NONE }, 1, 0, 0,
      0, NONE, 0, TEX_2D, 0, 0, 0, "v_sample", 0, 0, 0, 0, 0, 0, 1 },
    /* round 10: vertex reads with a fixed position (colour = the read), and a vertex read of the BGRA8 mip chain
     * beside vsample's sample of it; run each alone (-p) so the post snapshot keeps its vertex PDS data */
    { "vread2_f32", "f_vcolor", "vertex read of RGBA32Float, fixed position, colour = texel (1,2) / 16", { BGRA, NONE },
      1, 0, 0, 0, NONE, 0, TEX_F32, 0, 0, 0, "v_read2_f32", 0, 0, 0, 0, 0, 0, 1 },
    { "vread2_i32", "f_vcolor", "vertex read of RGBA32Sint, fixed position, colour = texel (1,2) / 64", { BGRA, NONE },
      1, 0, 0, 0, NONE, 0, TEX_I32, 0, 0, 0, "v_read2_i32", 0, 0, 0, 0, 0, 0, 1 },
    { "vread2_bgra", "f_vcolor", "vertex read of the 64x64 BGRA8 mip chain at (32,32), fixed position", { BGRA, NONE },
      1, 0, 0, 0, NONE, 0, TEX_2D, 0, 0, 0, "v_read2_bgra", 0, 0, 0, 0, 0, 0, 1 },
    /* round 12 (update 55): WebRender's R8 alpha/clip-mask targets loaded, and a cube sample feeding arithmetic.
     * r8_load's target is CPU-filled with 0x5a first (corner = 5a, centre = ff); "r8" is its clear + store
     * reference. tex_cube_mul's faces are solid colours (kCubeFace); the centre samples +Z. */
    { "r8_load", "f_solid", "R8Unorm target, loadAction Load", { MTLPixelFormatR8Unorm, NONE }, 1, 0, 1, 0, NONE, 0,
      TEX_NONE, .prefill = 0x5a },
    { "tex_cube_mul", "f_tex_cube_mul", "cube sample feeding a multiply and an add (solid faces)", { BGRA, NONE }, 1,
      0, 0, 0, NONE, 0, TEX_CUBE_SOLID, 0, 0, 1 },
    /* round 5 (update 42): last in the table, so its PDS DMA block is the one the post snapshot keeps */
    /* round 6: Apple's ZLS for NPOT depth/stencil targets (ZLSCTL extents, allocatedSize), a stored and a loaded
     * pass each, and a memoryless one (no load, no store) */
    { "ds_npot_100x75", "f_solid", "D32F_S8 100x75 clear + store", { BGRA, NONE }, 1, 0, 0, 0,
      MTLPixelFormatDepth32Float_Stencil8, 0, TEX_NONE, 0, 0, 0, NULL, 100, 0, 0, 0, 75 },
    { "ds_npot_100x75_load", "f_solid", "D32F_S8 100x75 load + store", { BGRA, NONE }, 1, 0, 0, 0,
      MTLPixelFormatDepth32Float_Stencil8, 1, TEX_NONE, 0, 0, 0, NULL, 100, 0, 0, 0, 75 },
    { "ds_npot_528x80", "f_solid", "D32F_S8 528x80 clear + store", { BGRA, NONE }, 1, 0, 0, 0,
      MTLPixelFormatDepth32Float_Stencil8, 0, TEX_NONE, 0, 0, 0, NULL, 528, 0, 0, 0, 80 },
    { "ds_npot_528x80_load", "f_solid", "D32F_S8 528x80 load + store", { BGRA, NONE }, 1, 0, 0, 0,
      MTLPixelFormatDepth32Float_Stencil8, 1, TEX_NONE, 0, 0, 0, NULL, 528, 0, 0, 0, 80 },
    { "ds_npot_640x1136", "f_solid", "D32F_S8 640x1136 clear + store", { BGRA, NONE }, 1, 0, 0, 0,
      MTLPixelFormatDepth32Float_Stencil8, 0, TEX_NONE, 0, 0, 0, NULL, 640, 0, 0, 0, 1136 },
    { "ds_npot_640x1136_load", "f_solid", "D32F_S8 640x1136 load + store", { BGRA, NONE }, 1, 0, 0, 0,
      MTLPixelFormatDepth32Float_Stencil8, 1, TEX_NONE, 0, 0, 0, NULL, 640, 0, 0, 0, 1136 },
    { "ds_memoryless", "f_solid", "D32F_S8 640x1136 memoryless (clear, don't store)", { BGRA, NONE }, 1, 0, 0, 0,
      MTLPixelFormatDepth32Float_Stencil8, 0, TEX_NONE, 0, 0, 0, NULL, 640, 0, 0, 0, 1136, 1 },
    { "tex7s", "f_tex7s", "7 textures, 7 samplers (sampler slots 12-13: byte 5 07)", { BGRA, NONE }, 1, 0, 0, 0, NONE, 0,
      TEX_NONE, 0, 0, 0, NULL, 0, 0, 7, 7 },
    { "vread_f32", "f_vcolor", "vertex-stage texel read of RGBA32Float (WebRender's GPU cache, transforms)",
      { BGRA, NONE }, 1, 0, 0, 0, NONE, 0, TEX_F32, 0, 0, 0, "v_read_f32", 0, 0, 0, 0, 0, 0, 1 },
};
/* fragment buffer 0 of the fbytes passes: LOD 1.0, bias 0.5, layer 1 (as float and as uint) */
static const struct { float lod, bias, layer_f; uint32_t layer_u; } kFragBytes = { 1.0f, 0.5f, 1.0f, 1 };
#define NPASSES (sizeof(kPasses) / sizeof(kPasses[0]))
#define TW 64             /* the sampled textures' side */
static unsigned W = 64;   /* the current pass's target width (struct pass size) */
static unsigned H = 64;   /* and height (struct pass height, else the width) */

/* a pass, built once */
struct built {
    id<MTLRenderPipelineState> rps;
    id<MTLDepthStencilState> dss;
    MTLRenderPassDescriptor *rp;
    id<MTLTexture> c0;   /* the target read back (the resolve target for msaa4_resolve) */
    id<MTLBuffer> c0buf; /* linear: the buffer behind c0 */
    NSUInteger c0_pitch;
    id<MTLTexture> tex, tex1;
    id<MTLTexture> ds;              /* round 5: the depth/stencil target (its allocatedSize) */
    id<MTLTexture> solid[8];        /* round 4 */
    id<MTLSamplerState> samp[8];    /* round 4 */
};

/* round 4's texture colours (RGBA8): the centre of a tex2s..tex7 target names the image each channel came from */
static const uint8_t kSolid[8][4] = { { 200, 10, 20, 255 }, { 30, 150, 40, 255 }, { 50, 60, 250, 255 },
                                      { 90, 220, 120, 255 }, { 170, 80, 140, 255 }, { 10, 200, 200, 255 },
                                      { 240, 240, 10, 255 }, { 120, 30, 90, 255 } };
/* round 12: tex_cube_mul's face colours (RGBA8), slices +X -X +Y -Y +Z -Z; out = face * 0.5 + 0.25 */
static const uint8_t kCubeFace[6][4] = { { 255, 0, 0, 255 }, { 0, 255, 0, 255 }, { 0, 0, 255, 255 },
                                         { 255, 255, 0, 255 }, { 204, 102, 51, 255 }, { 0, 255, 255, 255 } };

/* As a8-shadercap: this process's readable IOAccel regions, resident pages only, never an external pager. */
static uint64_t dump_regions(const char *out, const char *stage, uint64_t cap, FILE *idx)
{
    char path[1024];
    vm_address_t addr = 0;
    natural_t depth = 0;
    uint64_t dumped = 0;
    unsigned n = 0;
    const vm_size_t pg = (vm_size_t)getpagesize();
    void *buf = malloc(pg);
    fprintf(idx, "# stage %s page=%lu\n", stage, (unsigned long)pg);
    for (;;) {
        vm_size_t size = 0;
        vm_region_submap_info_data_64_t info;
        mach_msg_type_number_t cnt = VM_REGION_SUBMAP_INFO_COUNT_64;
        if (vm_region_recurse_64(mach_task_self(), &addr, &size, &depth, (vm_region_recurse_info_64_t)&info, &cnt) !=
            KERN_SUCCESS)
            break;
        if (info.is_submap) {
            depth++;
            continue;
        }
        n++;
        const int accel = info.user_tag == VM_MEMORY_IOACCELERATOR || info.user_tag == VM_MEMORY_IOKIT;
        const int want = accel && (info.protection & VM_PROT_READ) && !info.external_pager;
        fprintf(idx, "%s 0x%016llx size=0x%llx tag=%u prot=%d/%d resident=%u extpager=%d%s", stage,
                (unsigned long long)addr, (unsigned long long)size, info.user_tag, info.protection,
                info.max_protection, info.pages_resident, info.external_pager,
                accel && info.external_pager ? " SKIP-EXTPAGER" : "");
        if (want && dumped < cap) {
            snprintf(path, sizeof(path), "%s/region-%s-%016llx.bin", out, stage, (unsigned long long)addr);
            FILE *f = fopen(path, "wb");
            const uint64_t npages = size / pg;
            const uint64_t kpg = vm_kernel_page_size ? vm_kernel_page_size : 4096, sub = pg / kpg ? pg / kpg : 1;
            char *kvec = calloc(size / kpg + 1, 1), *vec = calloc(npages ? npages : 1, 1);
            if (mincore((void *)addr, (size_t)size, kvec) == 0)
                for (uint64_t i = 0; i < npages; i++)
                    for (uint64_t j = 0; j < sub; j++)
                        vec[i] |= kvec[i * sub + j] & 1;
            free(kvec);
            uint64_t wrote = 0, failed = 0;
            for (uint64_t i = 0; f && i < npages && dumped + pg <= cap; i++) {
                if (!(vec[i] & 1))
                    continue;
                vm_size_t got = 0;
                if (vm_read_overwrite(mach_task_self(), addr + i * pg, pg, (vm_address_t)buf, &got) != KERN_SUCCESS ||
                    got != pg) {
                    failed++;
                    continue;
                }
                fseeko(f, (off_t)(i * pg), SEEK_SET);
                fwrite(buf, 1, pg, f);
                wrote++;
                dumped += pg;
            }
            if (f)
                fclose(f);
            free(vec);
            fprintf(idx, " DUMP pages=%llu failed=%llu", (unsigned long long)wrote, (unsigned long long)failed);
        } else if (want) {
            fprintf(idx, " SKIP-CAP");
        }
        fputc('\n', idx);
        fflush(idx);
        addr += size;
    }
    fprintf(idx, "# stage %s: %u regions, %llu bytes dumped\n", stage, n, (unsigned long long)dumped);
    fflush(idx);
    free(buf);
    printf("regions %s: %u, dumped %llu bytes\n", stage, n, (unsigned long long)dumped);
    return dumped;
}

static id<MTLTexture> color_tex(id<MTLDevice> dev, MTLPixelFormat f, unsigned samples, int shared)
{
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:f width:W height:H
                                                                              mipmapped:NO];
    td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    if (samples > 1) {
        td.textureType = MTLTextureType2DMultisample;
        td.sampleCount = samples;
    }
    td.storageMode = shared ? MTLStorageModeShared : MTLStorageModePrivate;
    return [dev newTextureWithDescriptor:td];
}

/* the sampled texture: 64x64 BGRA8 with a full mip chain (array: 2 slices; cube: 6 faces), a gradient */
static id<MTLTexture> sample_tex(id<MTLDevice> dev, enum tex_kind k)
{
    MTLTextureDescriptor *td;
    if (k == TEX_ASTC) {
        /* 64x64 ASTC 4x4 LDR, one level, every block the void-extent (constant colour) block of RGBA16
         * ffff 8000 0000 ffff */
        td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatASTC_4x4_LDR width:TW height:TW
                                                            mipmapped:NO];
        id<MTLTexture> t = [dev newTextureWithDescriptor:td];
        static const uint8_t blk[16] = { 0xfc, 0xfd, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
                                         0xff, 0xff, 0x00, 0x80, 0x00, 0x00, 0xff, 0xff };
        uint8_t *data = malloc((TW / 4) * (TW / 4) * 16);
        for (unsigned i = 0; i < (TW / 4) * (TW / 4); i++) memcpy(data + 16 * i, blk, 16);
        [t replaceRegion:MTLRegionMake2D(0, 0, TW, TW) mipmapLevel:0 withBytes:data bytesPerRow:(TW / 4) * 16];
        free(data);
        return t;
    }
    if (k == TEX_NPOT1) {
        /* vkmark effect2d's background: 800x600, one level (its texture state, and allocatedSize: Apple's padding) */
        td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:BGRA width:800 height:600 mipmapped:NO];
        id<MTLTexture> t = [dev newTextureWithDescriptor:td];
        uint32_t *row = malloc(800 * 600 * 4);
        for (unsigned i = 0; i < 800 * 600; i++)
            row[i] = 0xff000000u | ((i / 800) * 255u / 600) << 8 | (i % 800) * 255u / 800;
        [t replaceRegion:MTLRegionMake2D(0, 0, 800, 600) mipmapLevel:0 withBytes:row bytesPerRow:800 * 4];
        free(row);
        return t;
    }
    if (k == TEX_F32 || k == TEX_I32) {
        /* round 7: WebRender's data textures: 4x4 RGBA32Float / RGBA32Sint, texel (x, y) = (x + 1, y + 1, x * 4 + y,
         * 7) (as floats, or as integers times 3), so a read names the texel it came from */
        td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:k == TEX_F32 ? MTLPixelFormatRGBA32Float
                                                                                    : MTLPixelFormatRGBA32Sint
                                                                width:4 height:4 mipmapped:NO];
        td.usage = MTLTextureUsageShaderRead;
        id<MTLTexture> t = [dev newTextureWithDescriptor:td];
        uint32_t texel[16][4];
        for (unsigned y = 0; y < 4; y++)
            for (unsigned x = 0; x < 4; x++) {
                if (k == TEX_F32) {
                    const float f[4] = { x + 1.0f, y + 1.0f, x * 4.0f + y, 7.0f };
                    memcpy(texel[y * 4 + x], f, 16);
                } else {
                    const int32_t v[4] = { 3 * (int)(x + 1), 3 * (int)(y + 1), 3 * (int)(x * 4 + y), 21 };
                    memcpy(texel[y * 4 + x], v, 16);
                }
            }
        [t replaceRegion:MTLRegionMake2D(0, 0, 4, 4) mipmapLevel:0 withBytes:texel bytesPerRow:4 * 16];
        return t;
    }
    if (k == TEX_CUBE_SOLID) {
        /* round 12: tex_cube's 64x64 mipmapped BGRA8 cube, every level of each face one solid colour (kCubeFace) */
        td = [MTLTextureDescriptor textureCubeDescriptorWithPixelFormat:BGRA size:TW mipmapped:YES];
        id<MTLTexture> t = [dev newTextureWithDescriptor:td];
        uint32_t *px = malloc(TW * TW * 4);
        for (unsigned s = 0; s < 6; s++)
            for (unsigned l = 0; l < t.mipmapLevelCount; l++) {
                const unsigned w = TW >> l ? TW >> l : 1;
                const uint8_t *c = kCubeFace[s];
                for (unsigned i = 0; i < w * w; i++)
                    px[i] = (uint32_t)c[3] << 24 | (uint32_t)c[0] << 16 | (uint32_t)c[1] << 8 | c[2]; /* BGRA bytes */
                [t replaceRegion:MTLRegionMake2D(0, 0, w, w) mipmapLevel:l slice:s withBytes:px bytesPerRow:w * 4
                   bytesPerImage:w * w * 4];
            }
        free(px);
        return t;
    }
    if (k == TEX_CUBE)
        td = [MTLTextureDescriptor textureCubeDescriptorWithPixelFormat:BGRA size:TW mipmapped:YES];
    else
        td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:BGRA width:TW height:TW mipmapped:YES];
    unsigned slices = 1;
    if (k == TEX_ARRAY) {
        td.textureType = MTLTextureType2DArray;
        td.arrayLength = 2;
        slices = 2;
    }
    if (k == TEX_CUBE)
        slices = 6;
    id<MTLTexture> t = [dev newTextureWithDescriptor:td];
    uint32_t *px = malloc(TW * TW * 4);
    for (unsigned s = 0; s < slices; s++)
        for (unsigned l = 0; l < t.mipmapLevelCount; l++) {
            const unsigned w = TW >> l ? TW >> l : 1;
            for (unsigned i = 0; i < w * w; i++)
                px[i] = 0xff000000u | (s * 40u) << 16 | (l * 36u) << 8 | (i % w) * 255u / w;
            [t replaceRegion:MTLRegionMake2D(0, 0, w, w) mipmapLevel:l slice:s withBytes:px bytesPerRow:w * 4
               bytesPerImage:w * w * 4];
        }
    free(px);
    return t;
}

static int build(id<MTLDevice> dev, id<MTLLibrary> lib, const struct pass *p, struct built *b, char *err, size_t n)
{
    NSError *e = nil;
    MTLRenderPipelineDescriptor *rpd = [MTLRenderPipelineDescriptor new];
    W = p->size ? p->size : 64;
    H = p->height ? p->height : W;
    rpd.vertexFunction = [lib newFunctionWithName:@(p->vert ? p->vert : "v_tri")];
    rpd.fragmentFunction = [lib newFunctionWithName:@(p->frag)];
    if (!rpd.vertexFunction || !rpd.fragmentFunction) {
        snprintf(err, n, "function %s missing", p->frag);
        return 0;
    }
    rpd.sampleCount = p->samples;
    MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
    for (unsigned i = 0; i < 4 && p->c[i] != NONE; i++) {
        rpd.colorAttachments[i].pixelFormat = p->c[i];
        id<MTLTexture> t;
        if (i == 0 && p->linear) {
            const NSUInteger align = [dev minimumLinearTextureAlignmentForPixelFormat:p->c[0]];
            const NSUInteger pitch = (W * 4 + align - 1) / align * align;
            b->c0buf = [dev newBufferWithLength:pitch * H options:MTLResourceStorageModeShared];
            MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:p->c[0] width:W
                                                                                       height:H mipmapped:NO];
            td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
            td.storageMode = MTLStorageModeShared;
            t = [b->c0buf newTextureWithDescriptor:td offset:0 bytesPerRow:pitch];
            b->c0_pitch = pitch;
        } else {
            t = color_tex(dev, p->c[i], p->samples, p->samples == 1);
        }
        if (!t) {
            snprintf(err, n, "colour target %u not created", i);
            return 0;
        }
        rp.colorAttachments[i].texture = t;
        rp.colorAttachments[i].loadAction = p->load ? MTLLoadActionLoad : MTLLoadActionClear;
        rp.colorAttachments[i].clearColor = MTLClearColorMake(0.25, 0.5, 0.75, 1.0);
        rp.colorAttachments[i].storeAction = MTLStoreActionStore;
        if (i == 0)
            b->c0 = t;
        if (i == 0 && p->prefill && p->samples == 1 && !p->linear) {
            /* round 12: a known value for loadAction Load to bring in (shared 1x target) */
            const NSUInteger bpp = p->c[0] == MTLPixelFormatR8Unorm ? 1 : p->c[0] == MTLPixelFormatRG8Unorm ? 2
                                 : p->c[0] == MTLPixelFormatRGBA16Float ? 8 : 4;
            uint8_t *fill = malloc(W * bpp * H);
            memset(fill, (int)p->prefill, W * bpp * H);
            [t replaceRegion:MTLRegionMake2D(0, 0, W, H) mipmapLevel:0 withBytes:fill bytesPerRow:W * bpp];
            free(fill);
        }
    }
    if (p->samples > 1 && p->resolve) {
        id<MTLTexture> r = color_tex(dev, p->c[0], 1, 1);
        rp.colorAttachments[0].resolveTexture = r;
        rp.colorAttachments[0].storeAction = MTLStoreActionMultisampleResolve;
        b->c0 = r;
    } else if (p->samples > 1) {
        b->c0 = nil; /* a 4x private target: not read back */
    }
    if (p->ds != NONE) {
        MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:p->ds width:W height:H
                                                                                  mipmapped:NO];
        td.usage = MTLTextureUsageRenderTarget;
        td.storageMode = p->memoryless ? MTLStorageModeMemoryless : MTLStorageModePrivate;
        id<MTLTexture> d = [dev newTextureWithDescriptor:td];
        if (!d) {
            snprintf(err, n, "depth target not created%s", p->memoryless ? " (memoryless)" : "");
            return 0;
        }
        b->ds = d;
        rpd.depthAttachmentPixelFormat = p->ds;
        rp.depthAttachment.texture = d;
        rp.depthAttachment.loadAction = p->ds_load ? MTLLoadActionLoad : MTLLoadActionClear;
        rp.depthAttachment.clearDepth = 0.5;
        rp.depthAttachment.storeAction = p->memoryless ? MTLStoreActionDontCare : MTLStoreActionStore;
        MTLDepthStencilDescriptor *dsd = [MTLDepthStencilDescriptor new];
        dsd.depthCompareFunction = MTLCompareFunctionLess;
        dsd.depthWriteEnabled = YES;
        if (p->ds == MTLPixelFormatDepth32Float_Stencil8) {
            rpd.stencilAttachmentPixelFormat = p->ds;
            rp.stencilAttachment.texture = d;
            rp.stencilAttachment.loadAction = p->ds_load ? MTLLoadActionLoad : MTLLoadActionClear;
            rp.stencilAttachment.clearStencil = 0x5a;
            rp.stencilAttachment.storeAction = p->memoryless ? MTLStoreActionDontCare : MTLStoreActionStore;
            MTLStencilDescriptor *sd = [MTLStencilDescriptor new];
            sd.stencilCompareFunction = MTLCompareFunctionAlways;
            sd.depthStencilPassOperation = MTLStencilOperationReplace;
            dsd.frontFaceStencil = sd;
            dsd.backFaceStencil = sd;
        }
        b->dss = [dev newDepthStencilStateWithDescriptor:dsd];
    }
    b->rps = [dev newRenderPipelineStateWithDescriptor:rpd error:&e];
    if (!b->rps) {
        snprintf(err, n, "pipeline: %s", e.localizedDescription.UTF8String);
        return 0;
    }
    if (p->tex != TEX_NONE)
        b->tex = sample_tex(dev, p->tex);
    if (p->tex2)
        b->tex1 = sample_tex(dev, p->tex);
    for (unsigned i = 0; i < p->ntex && i < 8; i++) {
        MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                                                      width:4 height:4 mipmapped:NO];
        b->solid[i] = [dev newTextureWithDescriptor:td];
        uint8_t px[16 * 4];
        for (unsigned k = 0; k < 16; k++) memcpy(px + 4 * k, kSolid[i], 4);
        [b->solid[i] replaceRegion:MTLRegionMake2D(0, 0, 4, 4) mipmapLevel:0 withBytes:px bytesPerRow:16];
    }
    for (unsigned i = 0; i < p->nsamp && i < 8; i++) {
        /* distinct states, so Metal keeps one per index: filters, address modes and the LOD clamp differ */
        MTLSamplerDescriptor *sd = [MTLSamplerDescriptor new];
        sd.minFilter = sd.magFilter = (i & 1) ? MTLSamplerMinMagFilterNearest : MTLSamplerMinMagFilterLinear;
        sd.sAddressMode = sd.tAddressMode = (i & 2) ? MTLSamplerAddressModeRepeat : MTLSamplerAddressModeClampToEdge;
        sd.lodMaxClamp = 8.0f + (float)i;
        b->samp[i] = [dev newSamplerStateWithDescriptor:sd];
    }
    b->rp = rp;
    return 1;
}

static void encode(id<MTLCommandBuffer> cmd, const struct pass *p, const struct built *b, id<MTLSamplerState> smp)
{
    id<MTLRenderCommandEncoder> re = [cmd renderCommandEncoderWithDescriptor:b->rp];
    [re setRenderPipelineState:b->rps];
    if (b->dss) {
        [re setDepthStencilState:b->dss];
        [re setStencilReferenceValue:0x33];
    }
    if (b->tex) {
        [re setFragmentTexture:b->tex atIndex:0];
        [re setFragmentSamplerState:smp atIndex:0];
        if (p->vtex) {
            [re setVertexTexture:b->tex atIndex:0];
            [re setVertexSamplerState:smp atIndex:0];
        }
    }
    if (b->tex1)
        [re setFragmentTexture:b->tex1 atIndex:1];
    for (unsigned i = 0; i < p->ntex && i < 8; i++)
        [re setFragmentTexture:b->solid[i] atIndex:i];
    for (unsigned i = 0; i < p->nsamp && i < 8; i++)
        [re setFragmentSamplerState:b->samp[i] atIndex:i];
    if (p->fbytes)
        [re setFragmentBytes:&kFragBytes length:sizeof(kFragBytes) atIndex:0];
    if (p->nodraw != 1)
        [re drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:p->verts ? p->verts : 3];
    [re endEncoding];
    if (p->nodraw == 2) {
        /* a second pass over the same target that loads nothing and draws nothing: clear + store again */
        id<MTLRenderCommandEncoder> e2 = [cmd renderCommandEncoderWithDescriptor:b->rp];
        [e2 endEncoding];
    }
}

/* the target's centre and corner pixels (format bytes, first 8), and the whole target to OUTDIR/<pass>.c0.bin */
static void readback(const struct pass *p, const struct built *b, const char *out, FILE *log)
{
    W = p->size ? p->size : 64;
    H = p->height ? p->height : W;
    if (!b->c0) {
        fprintf(log, " readback=none");
        return;
    }
    const NSUInteger bpp = p->c[0] == MTLPixelFormatR8Unorm ? 1 : p->c[0] == MTLPixelFormatRG8Unorm ? 2
                         : p->c[0] == MTLPixelFormatRGBA16Float ? 8 : 4;
    const NSUInteger pitch = W * bpp;
    uint8_t *px = calloc(pitch, H);
    if (b->c0buf) {
        for (unsigned y = 0; y < H; y++)
            memcpy(px + y * pitch, (uint8_t *)b->c0buf.contents + y * b->c0_pitch, pitch);
    } else {
        [b->c0 getBytes:px bytesPerRow:pitch fromRegion:MTLRegionMake2D(0, 0, W, H) mipmapLevel:0];
    }
    char path[1024];
    snprintf(path, sizeof(path), "%s/%s.c0.bin", out, p->name);
    FILE *f = fopen(path, "wb");
    if (f) {
        fwrite(px, pitch, H, f);
        fclose(f);
    }
    const uint8_t *c = px + (H / 2) * pitch + (W / 2) * bpp, *k = px;
    fprintf(log, " bpp=%lu centre=", (unsigned long)bpp);
    for (NSUInteger i = 0; i < bpp; i++) fprintf(log, "%02x", c[i]);
    fprintf(log, " corner=");
    for (NSUInteger i = 0; i < bpp; i++) fprintf(log, "%02x", k[i]);
    free(px);
}

static void usage(const char *a)
{
    fprintf(stderr, "usage: %s -L | -l passcap.metallib (-o OUTDIR [-m MB] [-p PASS] | -p PASS [-t SEC])\n"
                    "  -o OUTDIR -p PASS: capture only PASS (its PDS data and state stay in the post snapshot)\n", a);
    exit(2);
}

int main(int argc, char **argv)
{
    @autoreleasepool {
        const char *libpath = NULL, *out = NULL, *only = NULL;
        uint64_t cap = 64ull << 20;
        double secs = 60;
        int ch, list = 0;
        while ((ch = getopt(argc, argv, "Ll:o:m:p:t:")) != -1) {
            switch (ch) {
            case 'L': list = 1; break;
            case 'l': libpath = optarg; break;
            case 'o': out = optarg; break;
            case 'm': cap = strtoull(optarg, NULL, 0) << 20; break;
            case 'p': only = optarg; break;
            case 't': secs = atof(optarg); break;
            default: usage(argv[0]);
            }
        }
        if (list) {
            for (unsigned i = 0; i < NPASSES; i++) printf("%-14s %s\n", kPasses[i].name, kPasses[i].why);
            return 0;
        }
        if (!libpath || (!out && !only))
            usage(argv[0]);
        setvbuf(stdout, NULL, _IOLBF, 0);
        id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
        if (!dev) { fprintf(stderr, "no MTLDevice (entitlements?)\n"); return 1; }
        printf("device: %s\n", dev.name.UTF8String);
        NSError *e = nil;
        id<MTLLibrary> lib = [dev newLibraryWithURL:[NSURL fileURLWithPath:@(libpath)] error:&e];
        if (!lib) { fprintf(stderr, "library: %s\n", e.localizedDescription.UTF8String); return 1; }
        id<MTLCommandQueue> q = [dev newCommandQueue];
        MTLSamplerDescriptor *sdesc = [MTLSamplerDescriptor new];
        sdesc.minFilter = sdesc.magFilter = MTLSamplerMinMagFilterLinear;
        sdesc.mipFilter = MTLSamplerMipFilterLinear;
        id<MTLSamplerState> smp = [dev newSamplerStateWithDescriptor:sdesc];
        static struct built b[NPASSES];
        char err[256];

        if (only && !out) { /* loop mode, for p5-dump.sh */
            const struct pass *p = NULL;
            for (unsigned i = 0; i < NPASSES; i++)
                if (!strcmp(kPasses[i].name, only)) p = &kPasses[i];
            if (!p) { fprintf(stderr, "no pass %s (-L lists them)\n", only); return 2; }
            if (!build(dev, lib, p, &b[0], err, sizeof(err))) { fprintf(stderr, "%s: %s\n", p->name, err); return 1; }
            struct timespec t0, t;
            clock_gettime(CLOCK_MONOTONIC, &t0);
            unsigned frames = 0, errors = 0;
            do {
                @autoreleasepool {
                    id<MTLCommandBuffer> cmd = [q commandBuffer];
                    encode(cmd, p, &b[0], smp);
                    [cmd commit];
                    [cmd waitUntilCompleted];
                    if (cmd.status != MTLCommandBufferStatusCompleted) {
                        if (!errors) printf("error: %s\n", cmd.error.description.UTF8String);
                        errors++;
                    }
                    frames++;
                }
                usleep(16000);
                clock_gettime(CLOCK_MONOTONIC, &t);
            } while ((t.tv_sec - t0.tv_sec) + (t.tv_nsec - t0.tv_nsec) * 1e-9 < secs);
            printf("pass %s: frames %u errors %u", p->name, frames, errors);
            readback(p, &b[0], "/tmp", stdout);
            printf("\n");
            return errors ? 1 : 0;
        }

        /* capture mode */
        mkdir(out, 0755);
        char path[1024];
        snprintf(path, sizeof(path), "%s/passes.txt", out);
        FILE *log = fopen(path, "w");
        snprintf(path, sizeof(path), "%s/index.txt", out);
        FILE *idx = fopen(path, "w");
        if (!log || !idx) { perror(out); return 1; }
        id<MTLCommandBuffer> cmds[NPASSES];
        unsigned built_ok = 0;
        if (only) {
            unsigned found = 0;
            for (unsigned i = 0; i < NPASSES; i++) found |= !strcmp(kPasses[i].name, only);
            if (!found) { fprintf(stderr, "no pass %s (-L lists them)\n", only); return 2; }
        }
        for (unsigned i = 0; i < NPASSES; i++) {
            cmds[i] = nil;
            if (only && strcmp(kPasses[i].name, only))
                continue; /* -o -p: only that pass */
            if (!build(dev, lib, &kPasses[i], &b[i], err, sizeof(err))) {
                fprintf(log, "%s BUILD-FAIL %s\n", kPasses[i].name, err);
                continue;
            }
            built_ok++;
            cmds[i] = [q commandBuffer];
            cmds[i].label = @(kPasses[i].name);
            encode(cmds[i], &kPasses[i], &b[i], smp);
        }
        fflush(log);
        /* "pre": every pass encoded, nothing committed */
        const uint64_t pre = dump_regions(out, "pre", cap / 2, idx);
        unsigned bad = 0;
        for (unsigned i = 0; i < NPASSES; i++) {
            if (!cmds[i])
                continue;
            [cmds[i] commit];
            [cmds[i] waitUntilCompleted];
            const int okp = cmds[i].status == MTLCommandBufferStatusCompleted;
            bad += !okp;
            fprintf(log, "%s %s status=%ld", kPasses[i].name, okp ? "OK" : "FAIL", (long)cmds[i].status);
            if (okp)
                readback(&kPasses[i], &b[i], out, log);
            if (okp && b[i].tex)
                fprintf(log, " tex=%lux%lu levels=%lu allocatedSize=%lu", (unsigned long)b[i].tex.width,
                        (unsigned long)b[i].tex.height, (unsigned long)b[i].tex.mipmapLevelCount,
                        (unsigned long)b[i].tex.allocatedSize);
            else if (!okp)
                fprintf(log, " error=\"%s\"", cmds[i].error.localizedDescription.UTF8String);
            if (okp && b[i].ds)
                fprintf(log, " ds=%lux%lu allocatedSize=%lu", (unsigned long)b[i].ds.width,
                        (unsigned long)b[i].ds.height, (unsigned long)b[i].ds.allocatedSize);
            fprintf(log, "\n");
            fflush(log);
        }
        dump_regions(out, "post", cap - pre, idx);
        fprintf(log, "# %u passes, %u built, %u failed on the GPU\n", (unsigned)NPASSES, built_ok, bad);
        fclose(log);
        fclose(idx);
        printf("passes %u, built %u, GPU failures %u\n", only ? 1u : (unsigned)NPASSES, built_ok, bad);
        return bad || built_ok != (only ? 1u : (unsigned)NPASSES);
    }
}
