#include "PdfiumAndroidTextShaper.hpp"
#include "PdfiumHarfBuzzApi.h"
#include <algorithm>
#include <cmath>
#include <limits>
#include <map>
#include <memory>

namespace {
struct BlobCloser { void operator()(hb_blob_t* value) const { if (value) hb_blob_destroy(value); } };
struct FaceCloser { void operator()(hb_face_t* value) const { if (value) hb_face_destroy(value); } };
struct FontCloser { void operator()(hb_font_t* value) const { if (value) hb_font_destroy(value); } };
struct BufferCloser { void operator()(hb_buffer_t* value) const { if (value) hb_buffer_destroy(value); } };
}

margelo::nitro::inksignpdf::pdfium::PdfiumShapedRun shapeAndroidPdfText(
    std::size_t, std::span<const std::uint8_t> bytes,
    std::u16string_view text, bool rtl, float fontSize) {
  using namespace margelo::nitro::inksignpdf::pdfium;
  PdfiumShapedRun result;
  auto fail = [&]() { result.error = "Unable to shape text with the selected font"; return result; };
  if (bytes.empty() || bytes.size() > (std::numeric_limits<unsigned int>::max)() ||
      text.empty() || text.size() > static_cast<std::size_t>((std::numeric_limits<int>::max)())) return fail();
  std::unique_ptr<hb_blob_t, BlobCloser> blob(hb_blob_create(
    reinterpret_cast<const char*>(bytes.data()), static_cast<unsigned int>(bytes.size()),
    HB_MEMORY_MODE_READONLY, nullptr, nullptr));
  std::unique_ptr<hb_face_t, FaceCloser> face(blob ? hb_face_create(blob.get(), 0) : nullptr);
  std::unique_ptr<hb_font_t, FontCloser> font(face ? hb_font_create(face.get()) : nullptr);
  std::unique_ptr<hb_buffer_t, BufferCloser> buffer(hb_buffer_create());
  const auto scale = static_cast<int>(std::lround(fontSize * 64.0f));
  if (!blob || !face || !font || !buffer || scale <= 0) return fail();
  hb_ot_font_set_funcs(font.get());
  hb_font_set_scale(font.get(), scale, scale);
  hb_buffer_set_cluster_level(buffer.get(), HB_BUFFER_CLUSTER_LEVEL_MONOTONE_GRAPHEMES);
  hb_buffer_set_direction(buffer.get(), rtl ? HB_DIRECTION_RTL : HB_DIRECTION_LTR);
  hb_buffer_add_utf16(buffer.get(), reinterpret_cast<const std::uint16_t*>(text.data()),
                      static_cast<int>(text.size()), 0, static_cast<int>(text.size()));
  hb_buffer_guess_segment_properties(buffer.get());
  hb_shape(font.get(), buffer.get(), nullptr, 0);
  unsigned int infoCount = 0, positionCount = 0;
  auto* infos = hb_buffer_get_glyph_infos(buffer.get(), &infoCount);
  auto* positions = hb_buffer_get_glyph_positions(buffer.get(), &positionCount);
  if (!infoCount || infoCount != positionCount || !infos || !positions) return fail();

  struct RawGlyph { std::uint32_t cluster, glyphId; std::size_t order; double x, y; };
  std::vector<RawGlyph> raw;
  std::vector<std::uint32_t> starts;
  raw.reserve(infoCount); starts.reserve(infoCount);
  double penX = 0, penY = 0;
  for (unsigned int index = 0; index < infoCount; ++index) {
    auto cluster = (std::min)(infos[index].cluster, static_cast<std::uint32_t>(text.size() - 1));
    starts.push_back(cluster);
    raw.push_back({cluster, infos[index].codepoint, index,
      (penX + positions[index].x_offset) / 64.0, -(penY + positions[index].y_offset) / 64.0});
    penX += positions[index].x_advance; penY += positions[index].y_advance;
  }
  std::sort(starts.begin(), starts.end());
  starts.erase(std::unique(starts.begin(), starts.end()), starts.end());
  const double advance = penX / 64.0;
  const double minimum = (std::min)(0.0, advance);
  result.advance = static_cast<float>(std::abs(advance));
  std::map<std::uint32_t, bool> mapped;
  result.glyphs.reserve(raw.size());
  for (const auto& glyph : raw) {
    const auto next = std::upper_bound(starts.begin(), starts.end(), glyph.cluster);
    const auto end = next == starts.end() ? text.size() : static_cast<std::size_t>(*next);
    std::u16string unicode;
    if (!mapped[glyph.cluster]) {
      unicode = text.substr(glyph.cluster, end > glyph.cluster ? end - glyph.cluster : 1);
      mapped[glyph.cluster] = true;
    }
    result.glyphs.push_back({glyph.cluster, glyph.order, glyph.glyphId, std::move(unicode),
      static_cast<float>(glyph.x - minimum), static_cast<float>(glyph.y)});
  }
  return result;
}
