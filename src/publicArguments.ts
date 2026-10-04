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
  if (value.activePage !== undefined && value.activePage !== 'current' &&
    value.activePage !== 'firstAdded' && value.activePage !== 'lastAdded') {
    throw argumentError('invalid_active_page', 'Active page must be current, firstAdded, or lastAdded');
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

export function validateTextAnnotationBounds(value: unknown): void {
  if (!isRecord(value) ||
    typeof value.x !== 'number' || !Number.isFinite(value.x) ||
    typeof value.y !== 'number' || !Number.isFinite(value.y) ||
    typeof value.width !== 'number' || !Number.isFinite(value.width) || value.width <= 0 ||
    typeof value.height !== 'number' || !Number.isFinite(value.height) || value.height <= 0) {
    throw argumentError(
      'invalid_text_bounds',
      'Text bounds must have finite x/y coordinates and positive finite width/height',
    );
  }
}

export function validateTextAnnotationOptions(value: unknown): void {
  if (value === undefined) return;
  if (!isRecord(value) ||
    (value.direction !== undefined && value.direction !== 'ltr' &&
      value.direction !== 'rtl' && value.direction !== 'auto') ||
    (value.maxLines !== undefined &&
      (typeof value.maxLines !== 'number' || !Number.isInteger(value.maxLines) || value.maxLines < 0)) ||
    (value.alignment !== undefined && value.alignment !== 'start' &&
      value.alignment !== 'end' && value.alignment !== 'center') ||
    (value.verticalAnchor !== undefined && value.verticalAnchor !== 'top' &&
      value.verticalAnchor !== 'bottom')) {
    throw argumentError(
      'invalid_text_options',
      'Text options must contain a valid direction, alignment, line count, and vertical anchor',
    );
  }
}

export function validateTextModeOptions(value: unknown): void {
  validateViewportOptions(value);
  if (value === undefined) return;
  if (!isRecord(value)) {
    throw argumentError('invalid_text_placement_options', 'Placement options must be an object');
  }
  validateTextAnnotationOptions(value);
  const hasWidth = value.width !== undefined;
  const hasHeight = value.height !== undefined;
  if (hasWidth !== hasHeight ||
    (hasWidth && (typeof value.width !== 'number' || !Number.isFinite(value.width) || value.width <= 0)) ||
    (hasHeight && (typeof value.height !== 'number' || !Number.isFinite(value.height) || value.height <= 0))) {
    throw argumentError(
      'invalid_text_placement_options',
      'Manual box width and height must be supplied together as finite positive page points',
    );
  }
}

export function validateTextInsertionByKeyOptions(value: unknown): void {
  if (value === undefined) return;
  if (!isRecord(value) ||
    (value.occurrence !== undefined && value.occurrence !== 'first' && value.occurrence !== 'last')) {
    throw argumentError('invalid_text_key_options', 'Occurrence must be first or last');
  }
  validateTextAnnotationOptions(value);
}

export function validateViewportOptions(value: unknown): void {
  if (value === undefined) return;
  if (!isRecord(value)) {
    throw argumentError('invalid_viewport', 'Viewport options must be an object');
  }
  const hasX = value.x !== undefined;
  const hasY = value.y !== undefined;
  if (hasX !== hasY) {
    throw argumentError('invalid_viewport', 'Viewport x and y must be supplied together');
  }
  const coordinateKeys: ReadonlyArray<'x' | 'y'> = ['x', 'y'];
  for (const key of coordinateKeys) {
    const coordinate = value[key];
    if (coordinate !== undefined && (typeof coordinate !== 'number' || !Number.isFinite(coordinate))) {
      throw argumentError('invalid_viewport', `Viewport ${key} must be finite`);
    }
  }
  const zoom = value.zoom;
  if (zoom !== undefined &&
    (typeof zoom !== 'number' || !Number.isFinite(zoom) || zoom <= 0)) {
    throw argumentError('invalid_viewport', 'Viewport zoom must be finite and positive');
  }
}
