#pragma once

#include <cstdint>
#include <memory>
#include <optional>
#include <span>
#include <string>
#include <vector>

namespace margelo::nitro::inksignpdf::pdfium {

struct Point final {
  double x = 0.0;
  double y = 0.0;
};

struct Rect final {
  double left = 0.0;
  double top = 0.0;
  double right = 0.0;
  double bottom = 0.0;
};

struct AffineMatrix final {
  double a = 1.0;
  double b = 0.0;
  double c = 0.0;
  double d = 1.0;
  double e = 0.0;
  double f = 0.0;
};

struct RgbaColor final {
  std::uint8_t red = 0;
  std::uint8_t green = 0;
  std::uint8_t blue = 0;
  std::uint8_t alpha = 0;
};

enum class TextRenderMode : std::int8_t {
  Unknown = -1,
  Fill = 0,
  Stroke = 1,
  FillStroke = 2,
  Invisible = 3,
  FillClip = 4,
  StrokeClip = 5,
  FillStrokeClip = 6,
  Clip = 7,
};

struct FontMetadata final {
  std::string family;
  std::int32_t flags = 0;
  std::int32_t weight = -1;
};

struct PositionedCharacter final {
  std::int32_t sourceIndex = -1;
  std::uint32_t textObjectOrdinal = 0;
  std::uint32_t unicode = 0;
  bool generated = false;
  bool unicodeMapError = false;
  FontMetadata font;
  std::optional<RgbaColor> fillColor;
  std::optional<RgbaColor> strokeColor;
  TextRenderMode renderMode = TextRenderMode::Unknown;
  std::optional<Point> nextDisplacement;
  Point origin;
  Rect bounds;
  AffineMatrix matrix;
  double fontSize = 0.0;
};

/**
 * Detached page-space text data. The backing storage is immutable after
 * construction, so a snapshot remains valid after all temporary PDFium
 * handles used to create it have been closed.
 */
class PositionedPage final {
 public:
  PositionedPage(std::int32_t pageIndex,
                 Rect pageBounds,
                 std::vector<PositionedCharacter> characters);

  std::int32_t pageIndex() const { return storage_->pageIndex; }
  const Rect& pageBounds() const { return storage_->pageBounds; }
  std::span<const PositionedCharacter> characters() const {
    return storage_->characters;
  }

 private:
  struct Storage final {
    std::int32_t pageIndex;
    Rect pageBounds;
    std::vector<PositionedCharacter> characters;
  };

  std::shared_ptr<const Storage> storage_;
};

using PositionedPageSnapshot = std::shared_ptr<const PositionedPage>;

struct PositionedPageResult final {
  std::uint64_t generation = 0;
  std::int32_t pageIndex = -1;
  PositionedPageSnapshot page;

  bool valid() const { return page != nullptr && pageIndex >= 0; }
};

}  // namespace margelo::nitro::inksignpdf::pdfium
