#include <stddef.h>
#include <stdlib.h>

/* Scratch allocator for stb_truetype.

   Glyphs outside the fixed atlas are rasterized the first time they are
   drawn, which happens while a frame is being rendered, and the render path
   must not call malloc. Every block stb allocates during a rasterize call is
   freed before that call returns, so a bump arena that rewinds when its last
   live block is freed is enough.

   A request that does not fit falls through to malloc, so stb never sees
   NULL. Such requests are counted in teru_stbtt_fallback_allocs, which a
   test reads to prove the arena is big enough for the glyphs teru
   rasterizes. */
#define TERU_STBTT_ARENA_SIZE (512 * 1024)

static _Alignas(16) unsigned char teru_stbtt_arena[TERU_STBTT_ARENA_SIZE];
static size_t teru_stbtt_used;
static size_t teru_stbtt_live;
unsigned teru_stbtt_fallback_allocs;

static void *teru_stbtt_malloc(size_t n) {
    size_t need = (n + 15) & ~(size_t)15;
    if (need <= TERU_STBTT_ARENA_SIZE - teru_stbtt_used) {
        void *p = teru_stbtt_arena + teru_stbtt_used;
        teru_stbtt_used += need;
        teru_stbtt_live += 1;
        return p;
    }
    teru_stbtt_fallback_allocs += 1;
    return malloc(n);
}

static void teru_stbtt_free(void *p) {
    unsigned char *b = p;
    if (p == NULL) return;
    if (b >= teru_stbtt_arena && b < teru_stbtt_arena + TERU_STBTT_ARENA_SIZE) {
        teru_stbtt_live -= 1;
        if (teru_stbtt_live == 0) teru_stbtt_used = 0;
        return;
    }
    free(p);
}

#define STBTT_malloc(x, u) ((void)(u), teru_stbtt_malloc(x))
#define STBTT_free(x, u) ((void)(u), teru_stbtt_free(x))

/* stb's asserts are libc assert(), which aborts the process. Glyphs are now
   rasterized for whatever a program prints, from whatever fonts are
   installed, so one odd glyph must not take down the terminal or, in teruwm,
   the whole desktop session. With them compiled out stb behaves as it does
   in any build that defines NDEBUG: a glyph it cannot handle comes out
   blank or misdrawn. */
#define STBTT_assert(x) ((void)0)

#define STB_TRUETYPE_IMPLEMENTATION
#include "stb_truetype.h"

/* Guard for stb.zig's stbtt_fontinfo storage — if the struct
   grows past 256 bytes, compilation fails here and the Zig buffer
   must be bumped in lockstep. 160 bytes today on x86_64 (10 ints +
   2 ptrs + 6 × 16-byte stbtt__buf). */
_Static_assert(sizeof(stbtt_fontinfo) <= 256,
    "stbtt_fontinfo grew past the Zig storage — bump stbtt_fontinfo in stb.zig");
