const assert = require('node:assert/strict');
const test = require('node:test');
const { validateAddPagesOptions } = require('../lib/commonjs/publicArguments.js');

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
