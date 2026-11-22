#pragma once

#include <fpdf_edit.h>
#include <fpdf_ppo.h>
#include <fpdf_transformpage.h>

namespace margelo::nitro::inksignpdf::pdfium {

// PDFium's direct getter does not resolve page-tree inheritance. Its importer
// materializes inheritable page attributes on a detached destination page.
inline bool readMediaBox(FPDF_DOCUMENT document, int index, FPDF_PAGE page,
                         float* left, float* bottom, float* right, float* top) {
  if (FPDFPage_GetMediaBox(page, left, bottom, right, top)) return true;
  const auto detached = FPDF_CreateNewDocument();
  if (detached == nullptr) return false;
  const bool imported = FPDF_ImportPagesByIndex(detached, document, &index, 1, 0);
  const auto copied = imported ? FPDF_LoadPage(detached, 0) : nullptr;
  const bool resolved = copied != nullptr &&
      FPDFPage_GetMediaBox(copied, left, bottom, right, top);
  if (copied != nullptr) FPDF_ClosePage(copied);
  FPDF_CloseDocument(detached);
  return resolved;
}

// Coordinates for committed content use the same visible page as both viewers.
inline bool readCoordinateBox(FPDF_PAGE page, float* left, float* bottom,
                              float* right, float* top) {
  FS_RECTF box{};
  if (!FPDF_GetPageBoundingBox(page, &box)) return false;
  *left = box.left; *bottom = box.bottom; *right = box.right; *top = box.top;
  return true;
}

}  // namespace margelo::nitro::inksignpdf::pdfium
