#include "pdfium-adapter/PdfiumFontFallback.hpp"

#include <fpdf_sysfontinfo.h>
#include <fpdfview.h>

#include <algorithm>
#include <cstdint>
#include <memory>
#include <optional>
#include <string>
#include <unordered_set>
#include <utility>
#include <vector>

namespace margelo::nitro::inksignpdf::pdfium {
namespace {

bool providerReadU16(const std::vector<std::uint8_t>& bytes,
                     std::size_t offset,
                     std::uint16_t& value) {
  if (offset > bytes.size() || bytes.size() - offset < 2) return false;
  value = static_cast<std::uint16_t>(bytes[offset] << 8 | bytes[offset + 1]);
  return true;
}

bool providerReadU32(const std::vector<std::uint8_t>& bytes,
                     std::size_t offset,
                     std::uint32_t& value) {
  if (offset > bytes.size() || bytes.size() - offset < 4) return false;
  value = (static_cast<std::uint32_t>(bytes[offset]) << 24) |
      (static_cast<std::uint32_t>(bytes[offset + 1]) << 16) |
      (static_cast<std::uint32_t>(bytes[offset + 2]) << 8) |
      static_cast<std::uint32_t>(bytes[offset + 3]);
  return true;
}

std::optional<std::pair<std::size_t, std::size_t>> providerFontTableRange(
    const std::vector<std::uint8_t>& bytes,
    std::uint32_t table) {
  std::uint16_t tableCount = 0;
  if (!providerReadU16(bytes, 4, tableCount)) return std::nullopt;
  const std::size_t recordsOffset = 12;
  if (recordsOffset > bytes.size() ||
      static_cast<std::size_t>(tableCount) * 16 >
          bytes.size() - recordsOffset) {
    return std::nullopt;
  }
  for (std::uint16_t index = 0; index < tableCount; ++index) {
    const auto recordOffset =
        recordsOffset + static_cast<std::size_t>(index) * 16;
    std::uint32_t tag = 0;
    std::uint32_t offset = 0;
    std::uint32_t length = 0;
    if (!providerReadU32(bytes, recordOffset, tag) ||
        !providerReadU32(bytes, recordOffset + 8, offset) ||
        !providerReadU32(bytes, recordOffset + 12, length)) {
      return std::nullopt;
    }
    if (tag == table && offset <= bytes.size() &&
        length <= bytes.size() - offset) {
      return std::make_pair(static_cast<std::size_t>(offset),
                            static_cast<std::size_t>(length));
    }
  }
  return std::nullopt;
}

struct ProviderFontHandle final {
  std::shared_ptr<const PdfiumResolvedFont> resource;
};

class CallerFontSystemInfo final {
 public:
  CallerFontSystemInfo() : defaultInfo_(FPDF_GetDefaultSystemFontInfo()) {
    if (defaultInfo_ == nullptr) return;
    api.version = 2;
    api.Release = &release;
    api.EnumFonts = &enumFonts;
    api.MapFont = &mapFont;
    api.GetFont = &getFont;
    api.GetFontData = &getFontData;
    api.GetFaceName = &getFaceName;
    api.GetFontCharset = &getFontCharset;
    api.DeleteFont = &deleteFont;
  }

  ~CallerFontSystemInfo() {
    for (auto* handle : ownedHandles_) delete handle;
    ownedHandles_.clear();
    if (defaultInfo_ != nullptr) {
      FPDF_FreeDefaultSystemFontInfo(defaultInfo_);
    }
  }

  CallerFontSystemInfo(const CallerFontSystemInfo&) = delete;
  CallerFontSystemInfo& operator=(const CallerFontSystemInfo&) = delete;

  bool ready() const { return defaultInfo_ != nullptr; }
  FPDF_SYSFONTINFO* interface() { return &api; }

 private:
  static CallerFontSystemInfo* from(FPDF_SYSFONTINFO* info) {
    return reinterpret_cast<CallerFontSystemInfo*>(info);
  }

  std::shared_ptr<const PdfiumResolvedFont> resourceFor(
      const char* face,
      int weight,
      FPDF_BOOL italic) const {
    return resolveActiveFont(face, weight, italic);
  }

  ProviderFontHandle* createHandle(
      const std::shared_ptr<const PdfiumResolvedFont>& resource) {
    if (resource == nullptr || resource->bytes == nullptr) return nullptr;
    auto* handle = new ProviderFontHandle{resource};
    ownedHandles_.emplace(handle);
    return handle;
  }

  bool owns(void* font) const {
    return ownedHandles_.find(static_cast<ProviderFontHandle*>(font)) !=
        ownedHandles_.end();
  }

  static void release(FPDF_SYSFONTINFO* info) {
    auto* provider = from(info);
    if (provider->defaultInfo_ != nullptr &&
        provider->defaultInfo_->Release != nullptr &&
        !provider->defaultReleased_) {
      provider->defaultReleased_ = true;
      provider->defaultInfo_->Release(provider->defaultInfo_);
    }
  }

  static void enumFonts(FPDF_SYSFONTINFO* info, void* mapper) {
    auto* provider = from(info);
    if (provider->defaultInfo_ != nullptr &&
        provider->defaultInfo_->EnumFonts != nullptr) {
      provider->defaultInfo_->EnumFonts(provider->defaultInfo_, mapper);
    }
  }

  static void* mapFont(FPDF_SYSFONTINFO* info,
                       int weight,
                       FPDF_BOOL italic,
                       int charset,
                       int pitch_family,
                       const char* face,
                       FPDF_BOOL* bExact) {
    auto* provider = from(info);
    if (provider->defaultInfo_ == nullptr ||
        provider->defaultInfo_->MapFont == nullptr) {
      return nullptr;
    }

    if (const auto resource = provider->resourceFor(face, weight, italic);
        resource != nullptr) {
      if (auto* handle = provider->createHandle(resource); handle != nullptr) {
        return handle;
      }
    }

    return provider->defaultInfo_->MapFont(
        provider->defaultInfo_, weight, italic, charset, pitch_family, face,
        bExact);
  }

  static void* getFont(FPDF_SYSFONTINFO* info, const char* face) {
    auto* provider = from(info);
    if (provider->defaultInfo_ == nullptr ||
        provider->defaultInfo_->GetFont == nullptr) {
      return nullptr;
    }
    if (const auto resource = provider->resourceFor(face, 400, false);
        resource != nullptr) {
      if (auto* handle = provider->createHandle(resource); handle != nullptr) {
        return handle;
      }
    }
    return provider->defaultInfo_->GetFont(provider->defaultInfo_, face);
  }

  static unsigned long getFontData(FPDF_SYSFONTINFO* info,
                                   void* font,
                                   unsigned int table,
                                   unsigned char* buffer,
                                   unsigned long bufferSize) {
    auto* provider = from(info);
    if (provider->owns(font)) {
      const auto* handle = static_cast<const ProviderFontHandle*>(font);
      const auto& bytes = *handle->resource->bytes;
      std::size_t offset = 0;
      std::size_t length = bytes.size();
      if (table != 0) {
        const auto range = providerFontTableRange(bytes, table);
        if (!range) {
          return 0;
        }
        offset = range->first;
        length = range->second;
      }
      if (buffer == nullptr || bufferSize < length) {
        return static_cast<unsigned long>(length);
      }
      std::copy(bytes.begin() + offset, bytes.begin() + offset + length,
                buffer);
      return static_cast<unsigned long>(length);
    }
    if (provider->defaultInfo_ == nullptr ||
        provider->defaultInfo_->GetFontData == nullptr || font == nullptr) {
      return 0;
    }
    return provider->defaultInfo_->GetFontData(
        provider->defaultInfo_, font, table, buffer, bufferSize);
  }

  static unsigned long getFaceName(FPDF_SYSFONTINFO* info,
                                   void* font,
                                   char* buffer,
                                   unsigned long bufferSize) {
    auto* provider = from(info);
    if (provider->owns(font)) {
      const auto* handle = static_cast<const ProviderFontHandle*>(font);
      const auto& path = handle->resource->path;
      if (buffer == nullptr || bufferSize < path.size() + 1) {
        return static_cast<unsigned long>(path.size() + 1);
      }
      std::copy(path.begin(), path.end(), buffer);
      buffer[path.size()] = '\0';
      return static_cast<unsigned long>(path.size() + 1);
    }
    if (provider->defaultInfo_ == nullptr ||
        provider->defaultInfo_->GetFaceName == nullptr) {
      return 0;
    }
    return provider->defaultInfo_->GetFaceName(
        provider->defaultInfo_, font, buffer, bufferSize);
  }

  static int getFontCharset(FPDF_SYSFONTINFO* info, void* font) {
    auto* provider = from(info);
    if (provider->owns(font)) return FXFONT_DEFAULT_CHARSET;
    if (provider->defaultInfo_ == nullptr ||
        provider->defaultInfo_->GetFontCharset == nullptr) {
      return FXFONT_DEFAULT_CHARSET;
    }
    return provider->defaultInfo_->GetFontCharset(provider->defaultInfo_,
                                                  font);
  }

  static void deleteFont(FPDF_SYSFONTINFO* info, void* font) {
    auto* provider = from(info);
    if (provider->owns(font)) {
      provider->ownedHandles_.erase(static_cast<ProviderFontHandle*>(font));
      delete static_cast<ProviderFontHandle*>(font);
      return;
    }
    if (provider->defaultInfo_ != nullptr &&
        provider->defaultInfo_->DeleteFont != nullptr) {
      provider->defaultInfo_->DeleteFont(provider->defaultInfo_, font);
    }
  }

  FPDF_SYSFONTINFO api{};
  FPDF_SYSFONTINFO* defaultInfo_ = nullptr;
  bool defaultReleased_ = false;
  std::unordered_set<ProviderFontHandle*> ownedHandles_;
};




}  // namespace

static std::unique_ptr<CallerFontSystemInfo> systemFontInfo;

bool installSystemFontProvider() {
  if (systemFontInfo != nullptr) return true;
  auto candidate = std::make_unique<CallerFontSystemInfo>();
  if (!candidate->ready()) return false;
  FPDF_SetSystemFontInfo(candidate->interface());
  systemFontInfo = std::move(candidate);
  return true;
}

void uninstallSystemFontProvider() {
  systemFontInfo.reset();
}


}  // namespace margelo::nitro::inksignpdf::pdfium
