#include "pdfium-adapter/PdfiumFontCoverage.hpp"

#include <algorithm>
#include <cstdint>
#include <fstream>
#include <limits>
#include <optional>
#include <string>
#include <vector>

namespace margelo::nitro::inksignpdf::pdfium {
namespace {

bool readU16(const std::vector<std::uint8_t>& bytes,
             std::size_t offset,
             std::uint16_t& value) {
  if (offset > bytes.size() || bytes.size() - offset < 2) return false;
  value = static_cast<std::uint16_t>(bytes[offset] << 8 | bytes[offset + 1]);
  return true;
}

bool readU32(const std::vector<std::uint8_t>& bytes,
             std::size_t offset,
             std::uint32_t& value) {
  if (offset > bytes.size() || bytes.size() - offset < 4) return false;
  value = (static_cast<std::uint32_t>(bytes[offset]) << 24) |
      (static_cast<std::uint32_t>(bytes[offset + 1]) << 16) |
      (static_cast<std::uint32_t>(bytes[offset + 2]) << 8) |
      static_cast<std::uint32_t>(bytes[offset + 3]);
  return true;
}

void writeU32(std::vector<std::uint8_t>& bytes,
              std::size_t offset,
              std::uint32_t value) {
  bytes[offset] = static_cast<std::uint8_t>(value >> 24);
  bytes[offset + 1] = static_cast<std::uint8_t>(value >> 16);
  bytes[offset + 2] = static_cast<std::uint8_t>(value >> 8);
  bytes[offset + 3] = static_cast<std::uint8_t>(value);
}

bool hasTable(const std::vector<std::uint8_t>& bytes, std::uint32_t table) {
  std::uint16_t tableCount = 0;
  if (!readU16(bytes, 4, tableCount)) return false;
  constexpr std::size_t recordsOffset = 12;
  if (recordsOffset > bytes.size() ||
      static_cast<std::size_t>(tableCount) * 16 >
          bytes.size() - recordsOffset) {
    return false;
  }
  for (std::uint16_t index = 0; index < tableCount; ++index) {
    const auto recordOffset =
        recordsOffset + static_cast<std::size_t>(index) * 16;
    std::uint32_t tag = 0;
    std::uint32_t offset = 0;
    std::uint32_t length = 0;
    if (!readU32(bytes, recordOffset, tag) ||
        !readU32(bytes, recordOffset + 8, offset) ||
        !readU32(bytes, recordOffset + 12, length)) {
      return false;
    }
    if (tag == table && offset <= bytes.size() &&
        length <= bytes.size() - offset) {
      return true;
    }
  }
  return false;
}

std::optional<std::size_t> fontFaceOffset(
    const std::vector<std::uint8_t>& bytes,
    std::size_t collectionIndex) {
  std::uint32_t signature = 0;
  if (!readU32(bytes, 0, signature)) return std::nullopt;
  if (signature != 0x74746366) {
    if (collectionIndex != 0) return std::nullopt;
    return 0;
  }
  if (bytes.size() < 12 || collectionIndex > (bytes.size() - 12) / 4) {
    return std::nullopt;
  }
  std::uint32_t faceCount = 0;
  if (!readU32(bytes, 8, faceCount) || collectionIndex >= faceCount) {
    return std::nullopt;
  }
  std::uint32_t offset = 0;
  if (!readU32(bytes, 12 + collectionIndex * 4, offset) ||
      offset > bytes.size()) {
    return std::nullopt;
  }
  return static_cast<std::size_t>(offset);
}

std::vector<std::uint8_t> standaloneFontFace(
    const FontSelection& selection,
    const std::vector<std::uint8_t>& bytes) {
  std::uint32_t signature = 0;
  if (!readU32(bytes, 0, signature) || signature != 0x74746366) {
    return selection.collectionIndex == 0 ? bytes
                                         : std::vector<std::uint8_t>{};
  }
  const auto faceOffset = fontFaceOffset(bytes, selection.collectionIndex);
  if (!faceOffset || *faceOffset > bytes.size() ||
      bytes.size() - *faceOffset < 12) {
    return {};
  }
  std::uint16_t tableCount = 0;
  if (!readU16(bytes, *faceOffset + 4, tableCount)) return {};
  const auto recordsOffset = *faceOffset + 12;
  if (recordsOffset > bytes.size() ||
      static_cast<std::size_t>(tableCount) * 16 >
          bytes.size() - recordsOffset) {
    return {};
  }

  std::vector<std::uint8_t> result(
      12 + static_cast<std::size_t>(tableCount) * 16, 0);
  std::copy(bytes.begin() + *faceOffset,
            bytes.begin() + *faceOffset + 12,
            result.begin());
  std::size_t dataOffset = result.size();
  for (std::uint16_t index = 0; index < tableCount; ++index) {
    const auto sourceRecord =
        recordsOffset + static_cast<std::size_t>(index) * 16;
    const auto resultRecord = 12 + static_cast<std::size_t>(index) * 16;
    std::uint32_t tableOffset = 0;
    std::uint32_t tableLength = 0;
    if (!readU32(bytes, sourceRecord + 8, tableOffset) ||
        !readU32(bytes, sourceRecord + 12, tableLength) ||
        tableOffset > bytes.size() ||
        tableLength > bytes.size() - tableOffset) {
      return {};
    }
    std::copy(bytes.begin() + sourceRecord,
              bytes.begin() + sourceRecord + 8,
              result.begin() + resultRecord);
    dataOffset = (dataOffset + 3) & ~static_cast<std::size_t>(3);
    if (dataOffset > (std::numeric_limits<std::size_t>::max)() -
            tableLength) {
      return {};
    }
    result.resize(dataOffset + tableLength, 0);
    std::copy(bytes.begin() + tableOffset,
              bytes.begin() + tableOffset + tableLength,
              result.begin() + dataOffset);
    if (dataOffset > (std::numeric_limits<std::uint32_t>::max)()) return {};
    writeU32(result, resultRecord + 8,
             static_cast<std::uint32_t>(dataOffset));
    dataOffset += tableLength;
  }
  return result;
}

}  // namespace

std::shared_ptr<FontResource> loadFontResource(
    const std::string& path,
    std::size_t collectionIndex,
    std::string* errorMessage) {
  if (path.empty() || path.front() != '/') {
    if (errorMessage != nullptr) *errorMessage = "font path must be absolute";
    return nullptr;
  }
  std::ifstream input(path, std::ios::binary | std::ios::ate);
  if (!input) {
    if (errorMessage != nullptr) *errorMessage = "font path is not readable";
    return nullptr;
  }
  const auto end = input.tellg();
  constexpr std::streamoff kMaximumFontBytes = 64 * 1024 * 1024;
  if (end <= 0 || end > kMaximumFontBytes) {
    if (errorMessage != nullptr) *errorMessage = "font file size is unsupported";
    return nullptr;
  }
  std::vector<std::uint8_t> sourceBytes(static_cast<std::size_t>(end));
  input.seekg(0, std::ios::beg);
  if (!input.read(reinterpret_cast<char*>(sourceBytes.data()), end)) {
    if (errorMessage != nullptr) *errorMessage = "font file could not be read";
    return nullptr;
  }

  FontSelection selection{path, collectionIndex};
  const auto standalone = standaloneFontFace(selection, sourceBytes);
  if (standalone.empty()) {
    if (errorMessage != nullptr) {
      *errorMessage = "font collection index is invalid";
    }
    return nullptr;
  }
  if (!hasTable(standalone, 0x636D6170)) {
    if (errorMessage != nullptr) {
      *errorMessage = "font has no usable Unicode cmap";
    }
    return nullptr;
  }

  auto resource = std::make_shared<FontResource>();
  resource->selection = std::move(selection);
  resource->bytes = std::make_shared<const std::vector<std::uint8_t>>(
      standalone);
  return resource;
}

}  // namespace margelo::nitro::inksignpdf::pdfium
