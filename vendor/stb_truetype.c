#define STB_TRUETYPE_IMPLEMENTATION
#include "stb_truetype.h"

/* Guard for FontAtlas.zig's stbtt_fontinfo_storage — if the struct
   grows past 256 bytes, compilation fails here and the Zig buffer
   must be bumped in lockstep. 160 bytes today on x86_64 (10 ints +
   2 ptrs + 6 × 16-byte stbtt__buf). */
_Static_assert(sizeof(stbtt_fontinfo) <= 256,
    "stbtt_fontinfo grew past FontAtlas storage — bump stbtt_fontinfo_size");
