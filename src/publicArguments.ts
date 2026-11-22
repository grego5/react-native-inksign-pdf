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
  if (value.tag !== undefined) validatePageTag(value.tag);
  if (value.type !== undefined && value.type !== 'pdf' && value.type !== 'image') {
    throw argumentError('invalid_page_type', 'Page input type must be pdf or image');
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
    (value.font !== undefined && value.font !== null &&
      (typeof value.font !== 'string' || value.font.trim() === '')) ||
    (value.fontSize !== undefined &&
      (typeof value.fontSize !== 'number' || !Number.isFinite(value.fontSize) || value.fontSize <= 0)) ||
    (value.color !== undefined &&
      (typeof value.color !== 'string' || !/^#[0-9a-fA-F]{6}$/.test(value.color))) ||
    (value.direction !== undefined && value.direction !== 'ltr' &&
      value.direction !== 'rtl' && value.direction !== 'auto') ||
    (value.maxLines !== undefined &&
      (typeof value.maxLines !== 'number' || !Number.isSafeInteger(value.maxLines) || value.maxLines < 0)) ||
    (value.alignment !== undefined && value.alignment !== 'start' &&
      value.alignment !== 'end' && value.alignment !== 'center') ||
    (value.verticalAnchor !== undefined && value.verticalAnchor !== 'top' &&
      value.verticalAnchor !== 'bottom') ||
    (value.untracked !== undefined && typeof value.untracked !== 'boolean')) {
    throw argumentError(
      'invalid_text_options',
      'Text options must contain a valid direction, alignment, line count, and vertical anchor',
    );
  }
}

export function validatePageIndex(value: unknown): void {
  if (value !== undefined &&
    (typeof value !== 'number' || !Number.isInteger(value) || value < 0)) {
    throw argumentError('invalid_page_index', 'The page index must be a non-negative integer');
  }
}

export function validatePageTag(value: unknown): void {
  if (typeof value !== 'string' || value.length === 0) {
    throw argumentError('invalid_page_tag', 'Page tags must be nonempty strings');
  }
}

export function validatePageQuery(value: unknown, required = false): void {
  if (value === undefined && required) {
    throw argumentError('invalid_page_index', 'A page query is required');
  }
  if (isRecord(value)) {
    validatePageTag(value.tag);
    validatePageIndex(value.index);
  } else {
    validatePageIndex(value);
  }
}

export function validateInputTargetId(value: unknown): void {
  if (typeof value !== 'number' || !Number.isSafeInteger(value) || value <= 0) {
    throw argumentError('invalid_text_id', 'Text IDs must be positive safe integers');
  }
}

export function validateInputTargetFocusOptions(value: unknown): void {
  if (value === undefined) return;
  if (!isRecord(value) ||
    (value.zoom !== undefined &&
      (typeof value.zoom !== 'number' || !Number.isFinite(value.zoom) || value.zoom <= 0)) ||
    (value.verticalAnchor !== undefined && value.verticalAnchor !== 'top' &&
      value.verticalAnchor !== 'bottom' && value.verticalAnchor !== 'center') ||
    (value.edgeOffset !== undefined &&
      (typeof value.edgeOffset !== 'number' || !Number.isFinite(value.edgeOffset) || value.edgeOffset < 0))) {
    throw argumentError('invalid_text_focus_options', 'Text focus options are invalid');
  }
}

export function validateResolveInputUnderlineOptions(value: unknown): void {
  if (!isRecord(value)) {
    throw argumentError('invalid_text_resolution', 'Text resolution options must be an object');
  }
  const fieldName = value.fieldName;
  if (typeof fieldName !== 'string' || fieldName.trim() === '') {
    throw argumentError('invalid_text_field_name', 'Field names must be non-empty strings');
  }
  if (value.bounds !== undefined) validateTextAnnotationBounds(value.bounds);
  if (value.occurrence !== undefined && value.occurrence !== 'first' && value.occurrence !== 'last') {
    throw argumentError('invalid_text_key_options', 'Occurrence must be first or last');
  }
  validateTextAnnotationOptions(value);
}

export function validateCreateInputAreaOptions(value: unknown): void {
  if (!isRecord(value)) throw argumentError('invalid_text_resolution', 'Input area options must be an object');
  validateTextAnnotationBounds(value.bounds);
  validateTextAnnotationOptions(value);
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
  if (
    (hasWidth && (typeof value.width !== 'number' || !Number.isFinite(value.width) || value.width <= 0)) ||
    (hasHeight && (typeof value.height !== 'number' || !Number.isFinite(value.height) || value.height <= 0))) {
    throw argumentError(
      'invalid_text_placement_options',
      'Manual box dimensions must each be finite positive page points when supplied',
    );
  }
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

export function validatePagerDirection(value: unknown): void {
  if (value !== undefined && value !== 'auto' && value !== 'ltr' && value !== 'rtl') {
    throw argumentError('invalid_pager_direction', 'Pager direction must be auto, ltr, or rtl');
  }
}
