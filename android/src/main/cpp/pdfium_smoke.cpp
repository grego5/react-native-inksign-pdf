#include <fpdfview.h>
#include <fpdf_edit.h>
#include <fpdf_text.h>

extern "C" bool ReactNativeInkSignPdfPdfiumSmoke() {
  FPDF_LIBRARY_CONFIG config{};
  config.version = 2;
  FPDF_InitLibraryWithConfig(&config);
  const auto textApi = &FPDFText_LoadPage;
  const auto editApi = &FPDFPage_New;
  FPDF_DestroyLibrary();
  return textApi != nullptr && editApi != nullptr;
}
