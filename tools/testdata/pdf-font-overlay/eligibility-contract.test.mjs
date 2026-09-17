import assert from 'node:assert/strict';

const SUPPORTED_RENDER_MODES = new Set([0, 2]);

function decodeScalars(text) {
  const scalars = [];
  for (let index = 0; index < text.length; index += 1) {
    const codeUnit = text.charCodeAt(index);
    if (codeUnit >= 0xd800 && codeUnit <= 0xdbff) {
      const next = text.charCodeAt(index + 1);
      if (!Number.isFinite(next) || next < 0xdc00 || next > 0xdfff) return null;
      scalars.push(0x10000 + ((codeUnit - 0xd800) << 10) + next - 0xdc00);
      index += 1;
    } else if (codeUnit >= 0xdc00 && codeUnit <= 0xdfff) {
      return null;
    } else {
      scalars.push(codeUnit);
    }
  }
  return scalars;
}

function isTransparentScalar(scalar) {
  return scalar <= 0x1f ||
    (scalar >= 0x20 && scalar <= 0x7e) ||
    (scalar >= 0x7f && scalar <= 0x9f) ||
    /\p{White_Space}/u.test(String.fromCodePoint(scalar));
}

function evaluateRun({ text, hasGlyph, geometry, fontSize, renderMode }) {
  const scalars = decodeScalars(text);
  if (scalars == null) return { omitted: true, reason: 'malformed_unicode' };
  if (!geometry.every(Number.isFinite)) return { omitted: true, reason: 'invalid_geometry' };
  if (!Number.isFinite(fontSize) || fontSize <= 0) {
    return { omitted: true, reason: 'invalid_font_size' };
  }
  if (!SUPPORTED_RENDER_MODES.has(renderMode)) {
    return { omitted: true, reason: 'unsupported_render_mode' };
  }

  const painted = scalars.filter((scalar) =>
    !isTransparentScalar(scalar) && hasGlyph(scalar));
  return {
    omitted: painted.length === 0,
    advanceCount: scalars.length,
    painted,
  };
}

function assertEligibilityContract() {
  const usableGlyph = () => true;
  const noGlyph = () => false;
  const valid = { geometry: [1, 2, 3, 4], fontSize: 16, renderMode: 0 };

  const mixed = evaluateRun({
    ...valid,
    text: '2026: שלום',
    hasGlyph: usableGlyph,
  });
  assert.deepEqual(mixed.painted, [0x05e9, 0x05dc, 0x05d5, 0x05dd]);
  assert.equal(mixed.advanceCount, 10);

  const unsupportedGlyph = evaluateRun({
    ...valid,
    text: 'א',
    hasGlyph: noGlyph,
  });
  assert.equal(unsupportedGlyph.omitted, true);

  const universal = evaluateRun({
    ...valid,
    text: 'A 7\n\t',
    hasGlyph: usableGlyph,
  });
  assert.equal(universal.omitted, true);
  assert.equal(universal.advanceCount, 5);

  for (const invalid of [
    { text: '\ud800', reason: 'malformed_unicode' },
    { text: 'א', geometry: [1, Number.NaN, 3, 4], reason: 'invalid_geometry' },
    { text: 'א', fontSize: 0, reason: 'invalid_font_size' },
    { text: 'א', renderMode: -1, reason: 'unsupported_render_mode' },
  ]) {
    const result = evaluateRun({ ...valid, ...invalid, hasGlyph: usableGlyph });
    assert.equal(result.omitted, true);
    assert.equal(result.reason, invalid.reason);
  }
}

if (process.argv[1]?.endsWith('eligibility-contract.test.mjs')) {
  assertEligibilityContract();
  console.log('checked compatibility-text eligibility contract');
}

export { assertEligibilityContract, evaluateRun };
