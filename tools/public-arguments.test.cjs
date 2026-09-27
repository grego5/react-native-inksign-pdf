const assert = require('node:assert/strict');
const test = require('node:test');
const {
  validateAddPagesOptions,
  validateTextAnnotationBounds,
  validateTextAnnotationOptions,
  validateTextPlacementOptions,
} = require('../lib/commonjs/publicArguments.js');

test('addPages accepts positive finite DPI and JPEG quality endpoints', () => {
  assert.doesNotThrow(() => validateAddPagesOptions({ targetDpi: Number.MIN_VALUE, jpegQuality: 0 }));
  assert.doesNotThrow(() => validateAddPagesOptions({ targetDpi: 200, jpegQuality: 1 }));
  assert.doesNotThrow(() => validateAddPagesOptions(undefined));
});

test('addPages rejects invalid target DPI at the public boundary', () => {
  for (const targetDpi of [0, -1, Number.NaN, Number.POSITIVE_INFINITY]) {
    assert.throws(
      () => validateAddPagesOptions({ targetDpi }),
      { message: /^invalid_image_target_dpi:/ },
    );
  }
});

test('addPages rejects JPEG quality outside the inclusive 0-to-1 range', () => {
  for (const jpegQuality of [-Number.EPSILON, 1 + Number.EPSILON, Number.NaN, Number.POSITIVE_INFINITY]) {
    assert.throws(
      () => validateAddPagesOptions({ jpegQuality }),
      { message: /^invalid_image_jpeg_quality:/ },
    );
  }
});

test('text annotation bounds require finite coordinates and positive dimensions', () => {
  assert.doesNotThrow(() => validateTextAnnotationBounds({
    x: 10, y: 30, width: 20, height: 40,
  }));
  for (const bounds of [
    { x: Infinity, y: 30, width: 20, height: 40 },
    { x: 10, y: NaN, width: 20, height: 40 },
    { x: 10, y: 30, width: 0, height: 40 },
    { x: 10, y: 30, width: 20, height: -1 },
    { x: 10, y: 30, width: 20, height: Infinity },
    { x: 10, y: 30, width: 20 },
  ]) {
    assert.throws(() => validateTextAnnotationBounds(bounds), { message: /^invalid_text_bounds:/ });
  }
});

test('text options validate alignment and physical placement dimensions', () => {
  assert.doesNotThrow(() => validateTextAnnotationOptions({ alignment: 'center' }));
  assert.throws(() => validateTextAnnotationOptions({ alignment: 'middle' }), {
    message: /^invalid_text_options:/,
  });
  assert.doesNotThrow(() => validateTextPlacementOptions({ width: 80, height: 40 }));
  for (const options of [{ width: 80 }, { width: 0, height: 40 }, { width: 80, height: NaN }]) {
    assert.throws(() => validateTextPlacementOptions(options), {
      message: /^invalid_text_placement_options:/,
    });
  }
});
