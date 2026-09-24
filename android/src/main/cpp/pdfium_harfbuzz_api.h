#pragma once

#include <cstdint>

// The pinned PDFium static archive contains HarfBuzz's public C ABI. Only the
// stable declarations needed by the exporter are mirrored here because the
// release archive does not ship HarfBuzz headers.
extern "C" {

struct hb_blob_t;
struct hb_face_t;
struct hb_font_t;
struct hb_buffer_t;

using hb_codepoint_t = std::uint32_t;
using hb_mask_t = std::uint32_t;
using hb_position_t = std::int32_t;
using hb_destroy_func_t = void (*)(void*);

union hb_var_int_t {
  std::uint32_t u32;
  std::int32_t i32;
  std::uint16_t u16[2];
  std::int16_t i16[2];
  std::uint8_t u8[4];
  std::int8_t i8[4];
};

struct hb_glyph_info_t {
  hb_codepoint_t codepoint;
  hb_mask_t mask;
  std::uint32_t cluster;
  hb_var_int_t var1;
  hb_var_int_t var2;
};

struct hb_glyph_position_t {
  hb_position_t x_advance;
  hb_position_t y_advance;
  hb_position_t x_offset;
  hb_position_t y_offset;
  hb_var_int_t var;
};

enum hb_memory_mode_t : int {
  HB_MEMORY_MODE_DUPLICATE = 0,
  HB_MEMORY_MODE_READONLY = 1,
  HB_MEMORY_MODE_WRITABLE = 2,
  HB_MEMORY_MODE_READONLY_MAY_MAKE_WRITABLE = 3,
};

enum hb_direction_t : int {
  HB_DIRECTION_INVALID = 0,
  HB_DIRECTION_LTR = 4,
  HB_DIRECTION_RTL = 5,
  HB_DIRECTION_TTB = 6,
  HB_DIRECTION_BTT = 7,
};

enum hb_buffer_cluster_level_t : int {
  HB_BUFFER_CLUSTER_LEVEL_MONOTONE_GRAPHEMES = 0,
  HB_BUFFER_CLUSTER_LEVEL_MONOTONE_CHARACTERS = 1,
  HB_BUFFER_CLUSTER_LEVEL_CHARACTERS = 2,
};

hb_blob_t* hb_blob_create(const char* data,
                          unsigned int length,
                          hb_memory_mode_t memory_mode,
                          void* user_data,
                          hb_destroy_func_t destroy);
void hb_blob_destroy(hb_blob_t* blob);
hb_face_t* hb_face_create(hb_blob_t* blob, unsigned int index);
void hb_face_destroy(hb_face_t* face);
unsigned int hb_face_get_upem(hb_face_t* face);
hb_font_t* hb_font_create(hb_face_t* face);
void hb_font_destroy(hb_font_t* font);
void hb_font_set_scale(hb_font_t* font, int x_scale, int y_scale);
void hb_ot_font_set_funcs(hb_font_t* font);
hb_buffer_t* hb_buffer_create();
void hb_buffer_destroy(hb_buffer_t* buffer);
void hb_buffer_add_utf16(hb_buffer_t* buffer,
                         const std::uint16_t* text,
                         int text_length,
                         unsigned int item_offset,
                         int item_length);
void hb_buffer_set_direction(hb_buffer_t* buffer, hb_direction_t direction);
void hb_buffer_set_cluster_level(hb_buffer_t* buffer,
                                 hb_buffer_cluster_level_t cluster_level);
void hb_buffer_guess_segment_properties(hb_buffer_t* buffer);
unsigned int hb_buffer_get_length(hb_buffer_t* buffer);
hb_glyph_info_t* hb_buffer_get_glyph_infos(hb_buffer_t* buffer,
                                           unsigned int* length);
hb_glyph_position_t* hb_buffer_get_glyph_positions(hb_buffer_t* buffer,
                                                   unsigned int* length);
void hb_shape(hb_font_t* font,
              hb_buffer_t* buffer,
              const void* features,
              unsigned int feature_count);

}  // extern "C"

static_assert(sizeof(hb_glyph_info_t) == 20);
static_assert(sizeof(hb_glyph_position_t) == 20);
