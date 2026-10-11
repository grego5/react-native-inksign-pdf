#include "pdfium-adapter/PdfiumFontCoverage.hpp"

#include <algorithm>
#include <cstdint>
#include <optional>
#include <string>
#include <utility>
#include <vector>

namespace margelo::nitro::inksignpdf::pdfium {
namespace {

constexpr std::size_t kMaximumFontBytes = 64 * 1024 * 1024;

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
    std::size_t collectionIndex,
    std::vector<std::uint8_t> bytes,
    std::string& errorMessage) {
  std::uint32_t signature = 0;
  if (!readU32(bytes, 0, signature) || signature != 0x74746366) {
    return collectionIndex == 0 ? std::move(bytes)
                                : std::vector<std::uint8_t>{};
  }
  const auto faceOffset = fontFaceOffset(bytes, collectionIndex);
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

  struct TableCopy final {
    std::size_t sourceOffset;
    std::size_t length;
    std::size_t destinationOffset;
  };
  std::vector<TableCopy> tables;
  tables.reserve(tableCount);
  std::size_t faceSize = 12 + static_cast<std::size_t>(tableCount) * 16;
  // Validate the complete copy plan before allocating the reconstructed face.
  for (std::uint16_t index = 0; index < tableCount; ++index) {
    const auto sourceRecord =
        recordsOffset + static_cast<std::size_t>(index) * 16;
    std::uint32_t tableOffset = 0;
    std::uint32_t tableLength = 0;
    if (!readU32(bytes, sourceRecord + 8, tableOffset) ||
        !readU32(bytes, sourceRecord + 12, tableLength) ||
        tableOffset > bytes.size() ||
        tableLength > bytes.size() - tableOffset) {
      return {};
    }
    const auto dataOffset = (faceSize + 3) & ~static_cast<std::size_t>(3);
    if (dataOffset > kMaximumFontBytes ||
        tableLength > kMaximumFontBytes - dataOffset) {
      errorMessage = "font face exceeds the size limit";
      return {};
    }
    tables.push_back({tableOffset, tableLength, dataOffset});
    faceSize = dataOffset + tableLength;
  }

  std::vector<std::uint8_t> result(faceSize, 0);
  std::copy(bytes.begin() + *faceOffset,
            bytes.begin() + *faceOffset + 12,
            result.begin());
  for (std::size_t index = 0; index < tables.size(); ++index) {
    const auto sourceRecord = recordsOffset + index * 16;
    const auto resultRecord = 12 + index * 16;
    const auto& table = tables[index];
    std::copy(bytes.begin() + sourceRecord,
              bytes.begin() + sourceRecord + 16,
              result.begin() + resultRecord);
    std::copy(bytes.begin() + table.sourceOffset,
              bytes.begin() + table.sourceOffset + table.length,
              result.begin() + table.destinationOffset);
    writeU32(result, resultRecord + 8,
             static_cast<std::uint32_t>(table.destinationOffset));
  }
  return result;
}

}  // namespace

std::shared_ptr<FontResource> loadFontResource(
    std::string source,
    std::vector<std::uint8_t> bytes,
    std::size_t collectionIndex,
    std::string* errorMessage) {
  if (bytes.empty() || bytes.size() > kMaximumFontBytes) {
    if (errorMessage != nullptr) *errorMessage = "font file size is unsupported";
    return nullptr;
  }
  std::string faceError;
  auto standalone = standaloneFontFace(collectionIndex, std::move(bytes), faceError);
  if (standalone.empty()) {
    if (errorMessage != nullptr) {
      *errorMessage = faceError.empty()
          ? "font collection index or table data is invalid" : faceError;
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
  resource->source = std::move(source);
  resource->collectionIndex = collectionIndex;
  resource->bytes = std::make_shared<const std::vector<std::uint8_t>>(
      std::move(standalone));
  return resource;
}

}  // namespace margelo::nitro::inksignpdf::pdfium
