#include "pdfium-adapter/PdfiumPngImage.hpp"

#include <zlib.h>

#include <array>
#include <cstring>
#include <iomanip>
#include <limits>
#include <locale>
#include <sstream>
#include <string_view>

namespace margelo::nitro::inksignpdf::pdfium {
namespace {

constexpr std::array<std::uint8_t, 8> signature{137, 80, 78, 71, 13, 10, 26, 10};

std::uint32_t read32(const std::uint8_t* bytes) {
  return (std::uint32_t(bytes[0]) << 24) | (std::uint32_t(bytes[1]) << 16) |
      (std::uint32_t(bytes[2]) << 8) | bytes[3];
}

PdfiumError invalid(const char* message) {
  return {PdfiumErrorCode::InvalidInput, message};
}

struct PngImage {
  std::uint32_t width = 0;
  std::uint32_t height = 0;
  int transparent = -1;
  std::vector<std::uint8_t> compressed;
};

PdfiumError readPng(const std::vector<std::uint8_t>& bytes, PngImage& image) {
  if (bytes.size() < signature.size() ||
      std::memcmp(bytes.data(), signature.data(), signature.size()) != 0) {
    return invalid("Image is not a PNG");
  }
  bool header = false;
  bool data = false;
  bool dataEnded = false;
  for (std::size_t offset = 8; bytes.size() - offset >= 12;) {
    const auto length = read32(bytes.data() + offset);
    if (length > 0x7fffffff || length > bytes.size() - offset - 12) {
      return invalid("PNG chunk length is invalid");
    }
    const auto* type = bytes.data() + offset + 4;
    const auto* body = type + 4;
    const std::string_view kind(reinterpret_cast<const char*>(type), 4);
    auto crc = crc32(0, type, 4);
    crc = crc32(crc, body, length);
    if (crc != read32(body + length)) return invalid("PNG chunk checksum is invalid");
    if (!header && kind != "IHDR") return invalid("PNG header is missing");
    if (data && kind != "IDAT") dataEnded = true;
    if (kind == "IHDR") {
      if (header || length != 13) return invalid("PNG header is invalid");
      image.width = read32(body);
      image.height = read32(body + 4);
      if (image.width == 0 || image.height == 0 || image.width > 0x7fffffff ||
          image.height > 0x7fffffff || body[8] != 4 || body[9] != 0 ||
          body[10] != 0 || body[11] != 0 || body[12] != 0) {
        return invalid("PNG must be non-interlaced 4-bit grayscale");
      }
      header = true;
    } else if (kind == "tRNS") {
      if (data || length != 2 || image.transparent >= 0 || body[0] != 0 || body[1] > 15) {
        return invalid("PNG transparency is invalid");
      }
      image.transparent = body[1];
    } else if (kind == "IDAT") {
      if (dataEnded) return invalid("PNG image chunks are not contiguous");
      data = true;
      image.compressed.insert(image.compressed.end(), body, body + length);
    } else if (kind == "IEND") {
      if (length != 0 || image.compressed.empty() || offset + 12 != bytes.size()) {
        return invalid("PNG ending is invalid");
      }
      return {};
    } else if ((type[0] & 32) == 0) {
      return invalid("PNG contains an unsupported critical chunk");
    }
    offset += length + 12;
  }
  return invalid("PNG ending is missing");
}

// Validate compressed external data before publishing a PDF, without allocating a raster.
PdfiumError validateSamples(const PngImage& image) {
  const std::uint64_t stride = (std::uint64_t(image.width) + 1) / 2 + 1;
  const std::uint64_t expected = stride * image.height;
  constexpr std::uint64_t maximumDecodedBytes = 256 * 1024 * 1024;
  if (expected > maximumDecodedBytes) return invalid("PNG exceeds the supported decoded size");
  if (image.compressed.size() > (std::numeric_limits<uInt>::max)()) {
    return invalid("PNG exceeds the supported compressed size");
  }
  z_stream stream{};
  if (inflateInit(&stream) != Z_OK) return invalid("Unable to initialize PNG decompression");
  struct EndInflate {
    z_stream* stream;
    ~EndInflate() { inflateEnd(stream); }
  } end{&stream};
  stream.next_in = const_cast<Bytef*>(image.compressed.data());
  stream.avail_in = static_cast<uInt>(image.compressed.size());
  std::array<std::uint8_t, 16384> decoded{};
  std::uint64_t count = 0;
  int status;
  do {
    stream.next_out = decoded.data();
    stream.avail_out = static_cast<uInt>(decoded.size());
    status = inflate(&stream, Z_NO_FLUSH);
    if (status != Z_OK && status != Z_STREAM_END) return invalid("PNG compressed samples are invalid");
    const auto produced = decoded.size() - stream.avail_out;
    for (std::size_t index = 0; index < produced; ++index) {
      if ((count + index) % stride == 0 && decoded[index] > 4) {
        return invalid("PNG row filter is invalid");
      }
    }
    count += produced;
    if (count > expected) return invalid("PNG has excess samples");
  } while (status != Z_STREAM_END);
  if (count != expected || stream.avail_in != 0) return invalid("PNG sample count is invalid");
  return {};
}

}  // namespace

PdfiumError encodeGrayscalePng4(std::span<const std::uint8_t> pixels,
                                int width, int height, std::size_t rowStride,
                                std::size_t pixelStride,
                                std::vector<std::uint8_t>& png) {
  if (width <= 0 || height <= 0 || width > 8192 || height > 8192 ||
      (pixelStride != 1 && pixelStride != 4) ||
      rowStride < static_cast<std::size_t>(width) * pixelStride ||
      rowStride > pixels.size() / static_cast<std::size_t>(height)) {
    return invalid("Grayscale PNG raster is invalid");
  }
  const auto rowBytes = (static_cast<std::size_t>(width) + 1) / 2;
  std::vector<std::uint8_t> rows((rowBytes + 1) * height);
  std::vector<std::uint8_t> previous(rowBytes);
  for (int y = 0; y < height; ++y) {
    auto* row = rows.data() + (rowBytes + 1) * y;
    row[0] = y == 0 ? 0 : 2; // Up predictor keeps repeated document rows compact.
    for (std::size_t byte = 0; byte < rowBytes; ++byte) {
      const auto x = byte * 2;
      const auto* source = pixels.data() + rowStride * y;
      auto packed = static_cast<std::uint8_t>(((source[x * pixelStride] + 8) / 17) << 4);
      if (x + 1 < static_cast<std::size_t>(width)) {
        packed |= static_cast<std::uint8_t>((source[(x + 1) * pixelStride] + 8) / 17);
      }
      row[byte + 1] = y == 0 ? packed : static_cast<std::uint8_t>(packed - previous[byte]);
      previous[byte] = packed;
    }
  }
  uLongf compressedSize = compressBound(static_cast<uLong>(rows.size()));
  std::vector<std::uint8_t> compressed(compressedSize);
  if (compress2(compressed.data(), &compressedSize, rows.data(),
                static_cast<uLong>(rows.size()), 4) != Z_OK) {
    return invalid("Unable to compress grayscale PNG");
  }
  compressed.resize(compressedSize);
  png.assign(signature.begin(), signature.end());
  auto append32 = [](std::vector<std::uint8_t>& target, std::uint32_t value) {
    for (int shift : {24, 16, 8, 0}) target.push_back(static_cast<std::uint8_t>(value >> shift));
  };
  auto chunk = [&](const char* type, std::span<const std::uint8_t> data) {
    append32(png, static_cast<std::uint32_t>(data.size()));
    const auto start = png.size();
    png.insert(png.end(), type, type + 4);
    png.insert(png.end(), data.begin(), data.end());
    append32(png, static_cast<std::uint32_t>(crc32(0, png.data() + start,
        static_cast<uInt>(data.size() + 4))));
  };
  std::vector<std::uint8_t> header;
  append32(header, width);
  append32(header, height);
  header.insert(header.end(), {4, 0, 0, 0, 0});
  chunk("IHDR", header);
  chunk("IDAT", compressed);
  chunk("IEND", {});
  return {};
}

PdfiumError makeGrayscalePngPage(const PdfiumAppendInput& input,
                                std::vector<std::uint8_t>& pdf) {
  PngImage image;
  if (auto error = readPng(input.bytes, image); !error) return error;
  if (auto error = validateSamples(image); !error) return error;

  // PDF's PNG predictor consumes the IDAT zlib stream unchanged, including row filters.
  std::ostringstream content;
  content.imbue(std::locale::classic());
  content << std::setprecision(17);
  const auto& m = input.placement;
  content << "q " << m.a << ' ' << m.b << ' ' << m.c << ' ' << m.d << ' '
          << m.e << ' ' << m.f << " cm /Im0 Do Q\n";
  const auto operations = content.str();
  std::ostringstream output;
  output.imbue(std::locale::classic());
  output << std::setprecision(17) << "%PDF-1.7\n";
  std::array<std::streamoff, 6> offsets{};
  auto object = [&](int number) {
    offsets[number] = output.tellp();
    output << number << " 0 obj\n";
  };
  object(1);
  output << "<< /Type /Catalog /Pages 2 0 R >>\nendobj\n";
  object(2);
  output << "<< /Type /Pages /Count 1 /Kids [3 0 R] >>\nendobj\n";
  object(3);
  output << "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 " << input.pageWidth
         << ' ' << input.pageHeight << "] /Rotate " << input.rotation * 90
         << " /Resources << /XObject << /Im0 4 0 R >> >> /Contents 5 0 R >>\nendobj\n";
  object(4);
  output << "<< /Type /XObject /Subtype /Image /Width " << image.width
         << " /Height " << image.height << " /ColorSpace /DeviceGray /BitsPerComponent 4"
         << " /Filter /FlateDecode /DecodeParms << /Predictor 15 /Colors 1 /BitsPerComponent 4 /Columns "
         << image.width << " >>";
  if (image.transparent >= 0) output << " /Mask [" << image.transparent << ' ' << image.transparent << ']';
  output << " /Length " << image.compressed.size() << " >>\nstream\n";
  output.write(reinterpret_cast<const char*>(image.compressed.data()),
               static_cast<std::streamsize>(image.compressed.size()));
  output << "\nendstream\nendobj\n";
  object(5);
  output << "<< /Length " << operations.size() << " >>\nstream\n" << operations
         << "endstream\nendobj\n";
  const auto xref = output.tellp();
  output << "xref\n0 6\n0000000000 65535 f \n";
  for (int number = 1; number <= 5; ++number) {
    output << std::setw(10) << std::setfill('0') << offsets[number] << " 00000 n \n";
  }
  output << "trailer\n<< /Size 6 /Root 1 0 R >>\nstartxref\n" << xref << "\n%%EOF\n";
  const auto bytes = output.str();
  pdf.assign(bytes.begin(), bytes.end());
  return {};
}

}  // namespace margelo::nitro::inksignpdf::pdfium
