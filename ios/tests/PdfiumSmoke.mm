#include "../../core/third_party/pdfium/include/fpdfview.h"
#include "../../core/third_party/pdfium/include/fpdf_edit.h"
#include "../../core/third_party/pdfium/include/fpdf_ppo.h"
#include "../../core/third_party/pdfium/include/fpdf_save.h"
#include "../../core/third_party/pdfium/include/fpdf_text.h"

extern "C" bool ReactNativeInkSignPdfPdfiumSmoke() {
  FPDF_LIBRARY_CONFIG config{};
  config.version = 2;
  FPDF_InitLibraryWithConfig(&config);
  const auto textApi = &FPDFText_LoadPage;
  const auto editApi = &FPDFPage_New;
  const auto importApi = &FPDF_ImportPagesByIndex;
  const auto deleteApi = &FPDFPage_Delete;
  const auto moveApi = &FPDF_MovePages;
  const auto newImageApi = &FPDFPageObj_NewImageObj;
  const auto loadJpegApi = &FPDFImageObj_LoadJpegFileInline;
  const auto matrixApi = &FPDFImageObj_SetMatrix;
  const auto insertApi = &FPDFPage_InsertObject;
  const auto contentApi = &FPDFPage_GenerateContent;
  const auto saveApi = &FPDF_SaveAsCopy;
  FPDF_DestroyLibrary();
  return textApi != nullptr && editApi != nullptr && importApi != nullptr &&
      deleteApi != nullptr && moveApi != nullptr && newImageApi != nullptr &&
      loadJpegApi != nullptr && matrixApi != nullptr && insertApi != nullptr &&
      contentApi != nullptr && saveApi != nullptr;
}
