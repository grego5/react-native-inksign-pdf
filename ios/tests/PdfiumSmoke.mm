#include "../../core/third_party/pdfium/include/fpdfview.h"
#include "../../core/third_party/pdfium/include/fpdf_edit.h"
#include "../../core/third_party/pdfium/include/fpdf_text.h"

extern "C" bool ReactNativeInkSignPdfPdfiumSmoke() {
  FPDF_LIBRARY_CONFIG config{};
  config.version = 2;
  FPDF_InitLibraryWithConfig(&config);
  const auto textApi = &FPDFText_LoadPage;
  const auto editApi = &FPDFPage_New;
  FPDF_DestroyLibrary();
  return textApi != nullptr && editApi != nullptr;
}
