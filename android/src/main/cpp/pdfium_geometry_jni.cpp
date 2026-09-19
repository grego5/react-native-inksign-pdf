#include <jni.h>

#include <cstdint>
#include <cstring>
#include <limits>
#include <memory>
#include <optional>
#include <string>
#include <vector>

#include "pdfium/PdfiumDocumentSession.hpp"

namespace {

using margelo::nitro::inksignpdf::pdfium::PdfiumDocumentSession;
using margelo::nitro::inksignpdf::pdfium::PositionedCharacter;
using margelo::nitro::inksignpdf::pdfium::PositionedPage;

constexpr std::uint32_t kPayloadMagic = 0x31504750;  // "PGP1".

void appendByte(std::vector<std::uint8_t>& output, std::uint8_t value) {
  output.push_back(value);
}

void appendU32(std::vector<std::uint8_t>& output, std::uint32_t value) {
  for (int shift = 0; shift < 32; shift += 8) {
    appendByte(output, static_cast<std::uint8_t>(value >> shift));
  }
}

void appendI32(std::vector<std::uint8_t>& output, std::int32_t value) {
  appendU32(output, static_cast<std::uint32_t>(value));
}

void appendDouble(std::vector<std::uint8_t>& output, double value) {
  std::uint64_t bits = 0;
  static_assert(sizeof(bits) == sizeof(value));
  std::memcpy(&bits, &value, sizeof(bits));
  for (int shift = 0; shift < 64; shift += 8) {
    appendByte(output, static_cast<std::uint8_t>(bits >> shift));
  }
}

void appendString(std::vector<std::uint8_t>& output, const std::string& value) {
  appendU32(output, static_cast<std::uint32_t>(value.size()));
  output.insert(output.end(), value.begin(), value.end());
}

void appendColor(std::vector<std::uint8_t>& output,
                 const std::optional<margelo::nitro::inksignpdf::pdfium::RgbaColor>& color) {
  appendByte(output, color.has_value() ? 1 : 0);
  if (!color.has_value()) return;
  appendByte(output, color->red);
  appendByte(output, color->green);
  appendByte(output, color->blue);
  appendByte(output, color->alpha);
}

void appendCharacter(std::vector<std::uint8_t>& output,
                     const PositionedCharacter& character) {
  appendI32(output, character.sourceIndex);
  appendU32(output, character.textObjectOrdinal);
  appendU32(output, character.unicode);
  std::uint32_t flags = 0;
  if (character.generated) flags |= 1u;
  if (character.unicodeMapError) flags |= 2u;
  appendU32(output, flags);
  appendString(output, character.font.family);
  appendI32(output, character.font.flags);
  appendI32(output, character.font.weight);
  appendI32(output, static_cast<std::int32_t>(character.renderMode));
  appendColor(output, character.fillColor);
  appendColor(output, character.strokeColor);
  appendByte(output, character.nextDisplacement.has_value() ? 1 : 0);
  if (character.nextDisplacement.has_value()) {
    appendDouble(output, character.nextDisplacement->x);
    appendDouble(output, character.nextDisplacement->y);
  }
  appendDouble(output, character.origin.x);
  appendDouble(output, character.origin.y);
  appendDouble(output, character.bounds.left);
  appendDouble(output, character.bounds.top);
  appendDouble(output, character.bounds.right);
  appendDouble(output, character.bounds.bottom);
  appendDouble(output, character.matrix.a);
  appendDouble(output, character.matrix.b);
  appendDouble(output, character.matrix.c);
  appendDouble(output, character.matrix.d);
  appendDouble(output, character.matrix.e);
  appendDouble(output, character.matrix.f);
  appendDouble(output, character.fontSize);
}

std::vector<std::uint8_t> encodePage(const PositionedPage& page) {
  const auto characters = page.characters();
  std::vector<std::uint8_t> output;
  output.reserve(64 + characters.size() * 192);
  appendU32(output, kPayloadMagic);
  appendI32(output, page.pageIndex());
  appendDouble(output, page.pageBounds().left);
  appendDouble(output, page.pageBounds().top);
  appendDouble(output, page.pageBounds().right);
  appendDouble(output, page.pageBounds().bottom);
  appendU32(output, static_cast<std::uint32_t>(characters.size()));
  for (const auto& character : characters) appendCharacter(output, character);
  return output;
}

jbyteArray toByteArray(JNIEnv* env, const std::vector<std::uint8_t>& bytes) {
  if (bytes.size() > static_cast<std::size_t>(std::numeric_limits<jsize>::max())) {
    return nullptr;
  }
  const auto array = env->NewByteArray(static_cast<jsize>(bytes.size()));
  if (array == nullptr) return nullptr;
  if (!bytes.empty()) {
    env->SetByteArrayRegion(
        array, 0, static_cast<jsize>(bytes.size()),
        reinterpret_cast<const jbyte*>(bytes.data()));
  }
  return array;
}

}  // namespace

extern "C" JNIEXPORT jlong JNICALL
Java_com_margelo_nitro_inksignpdf_PdfiumGeometrySession_nativeOpen(
    JNIEnv* env, jclass, jbyteArray documentBytes) {
  if (documentBytes == nullptr) return 0;
  const auto length = env->GetArrayLength(documentBytes);
  if (length <= 0) return 0;

  std::vector<std::uint8_t> bytes(static_cast<std::size_t>(length));
  env->GetByteArrayRegion(
      documentBytes, 0, length, reinterpret_cast<jbyte*>(bytes.data()));
  if (env->ExceptionCheck()) return 0;

  auto opened = PdfiumDocumentSession::open(std::move(bytes));
  if (!opened) return 0;
  return reinterpret_cast<jlong>(opened.session.release());
}

extern "C" JNIEXPORT jint JNICALL
Java_com_margelo_nitro_inksignpdf_PdfiumGeometrySession_nativePageCount(
    JNIEnv*, jclass, jlong handle) {
  const auto* session = reinterpret_cast<const PdfiumDocumentSession*>(handle);
  if (session == nullptr) return 0;
  const auto count = session->pageCount();
  if (count > static_cast<std::size_t>(std::numeric_limits<jint>::max())) return 0;
  return static_cast<jint>(count);
}

extern "C" JNIEXPORT jbyteArray JNICALL
Java_com_margelo_nitro_inksignpdf_PdfiumGeometrySession_nativeExtractPage(
    JNIEnv* env, jclass, jlong handle, jint pageIndex) {
  const auto* session = reinterpret_cast<const PdfiumDocumentSession*>(handle);
  if (session == nullptr || pageIndex < 0) return nullptr;
  const auto extracted = session->extractPage(static_cast<std::size_t>(pageIndex));
  if (!extracted) return nullptr;
  return toByteArray(env, encodePage(*extracted.page));
}

extern "C" JNIEXPORT void JNICALL
Java_com_margelo_nitro_inksignpdf_PdfiumGeometrySession_nativeClose(
    JNIEnv*, jclass, jlong handle) {
  auto* session = reinterpret_cast<PdfiumDocumentSession*>(handle);
  if (session == nullptr) return;
  session->close();
  delete session;
}
