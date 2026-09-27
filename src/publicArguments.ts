export function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}

export function argumentError(code: string, message: string): Error {
  return new Error(`${code}: ${message}`);
}

export function validateAddPagesOptions(value: unknown): void {
  if (value === undefined) return;
  if (!isRecord(value)) {
    throw argumentError('invalid_page_options', 'Page options must be an object');
  }
  if (value.type !== undefined && value.type !== 'pdf' && value.type !== 'image') {
    throw argumentError('invalid_page_type', 'Page type must be pdf or image');
  }
  const sources = value.sources;
  if (sources !== undefined && (!Array.isArray(sources) ||
    !sources.every((source) => typeof source === 'string' && source.trim() !== ''))) {
    throw argumentError('invalid_page_sources', 'Page sources must be non-empty paths');
  }
  const imageSize = value.imagePageSize;
  if (imageSize !== undefined &&
    (!isRecord(imageSize) ||
      typeof imageSize.width !== 'number' || !Number.isFinite(imageSize.width) || imageSize.width <= 0 ||
      typeof imageSize.height !== 'number' || !Number.isFinite(imageSize.height) || imageSize.height <= 0)) {
    throw argumentError('invalid_image_page_size', 'Image page dimensions must be finite positive PDF points');
  }
  const targetDpi = value.targetDpi;
  if (targetDpi !== undefined &&
    (typeof targetDpi !== 'number' || !Number.isFinite(targetDpi) || targetDpi <= 0)) {
    throw argumentError('invalid_image_target_dpi', 'Image target DPI must be finite and positive');
  }
  const jpegQuality = value.jpegQuality;
  if (jpegQuality !== undefined &&
    (typeof jpegQuality !== 'number' || !Number.isFinite(jpegQuality) || jpegQuality < 0 || jpegQuality > 1)) {
    throw argumentError('invalid_image_jpeg_quality', 'Image JPEG quality must be between 0 and 1');
  }
}
