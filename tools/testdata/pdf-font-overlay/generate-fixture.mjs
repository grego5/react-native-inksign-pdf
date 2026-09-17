import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import { assertEligibilityContract } from './eligibility-contract.test.mjs';

const directory = path.dirname(fileURLToPath(import.meta.url));
const outputPath = path.join(directory, 'nonembedded-identity-text.pdf');

const expected = {
  pageWidth: 240,
  pageHeight: 160,
  firstText: '2026: שלום',
  secondText: 'A-7',
  firstTextMatrix: [1, 0, 0, 1, 24, 96],
  secondTextMatrix: [1, 0, 0, 1, 92, 52],
  firstFontSize: 18,
  secondFontSize: 12,
};

const header = Buffer.from([
  0x25, 0x50, 0x44, 0x46, 0x2d, 0x31, 0x2e, 0x37, 0x0a,
  0x25, 0xe2, 0xe3, 0xcf, 0xd3, 0x0a,
]);

const objects = [
  '<< /Type /Catalog /Pages 2 0 R >>',
  '<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
  `<< /Type /Page /Parent 2 0 R /MediaBox [0 0 ${expected.pageWidth} ${expected.pageHeight}] /Resources << /Font << /F0 4 0 R >> >> /Contents 7 0 R >>`,
  '<< /Type /Font /Subtype /Type0 /BaseFont /OverlaySans /Encoding /Identity-H /DescendantFonts [5 0 R] /ToUnicode 6 0 R >>',
  '<< /Type /Font /Subtype /CIDFontType2 /BaseFont /OverlaySans /CIDSystemInfo << /Registry (Adobe) /Ordering (Identity) /Supplement 0 >> /FontDescriptor 8 0 R /DW 600 /CIDToGIDMap /Identity >>',
  stream(toUnicodeCMap()),
  stream(contentStream()),
  '<< /Type /FontDescriptor /FontName /OverlaySans /Flags 4 /FontBBox [0 -200 1000 900] /ItalicAngle 0 /Ascent 900 /Descent -200 /CapHeight 700 /StemV 80 >>',
];

function stream(contents) {
  const body = Buffer.from(contents, 'ascii');
  return Buffer.concat([
    Buffer.from(`<< /Length ${body.byteLength} >>\nstream\n`, 'ascii'),
    body,
    Buffer.from('\nendstream', 'ascii'),
  ]);
}

function toUnicodeCMap() {
  return `/CIDInit /ProcSet findresource begin
12 dict begin
begincmap
/CMapName /OverlayToUnicode def
/CMapType 2 def
/CIDSystemInfo << /Registry (Adobe) /Ordering (UCS) /Supplement 0 >> def
1 begincodespacerange
<0001> <000D>
endcodespacerange
13 beginbfchar
<0001> <0032>
<0002> <0030>
<0003> <0032>
<0004> <0036>
<0005> <003A>
<0006> <0020>
<0007> <05E9>
<0008> <05DC>
<0009> <05D5>
<000A> <05DD>
<000B> <0041>
<000C> <002D>
<000D> <0037>
endbfchar
endcmap
CMapName currentdict /CMap defineresource pop
end
end`;
}

function contentStream() {
  return `q
0.8 w
0 0 0 RG
10 10 220 140 re
S
0.6 w
20 40 m
220 40 l
S
BT
/F0 ${expected.firstFontSize} Tf
0 0 0 rg
1 0 0 1 ${expected.firstTextMatrix[4]} ${expected.firstTextMatrix[5]} Tm
<000100020003000400050006000700080009000A> Tj
ET
BT
/F0 ${expected.secondFontSize} Tf
1 0 0 1 ${expected.secondTextMatrix[4]} ${expected.secondTextMatrix[5]} Tm
<000B000C000D> Tj
ET
Q`;
}

function buildPdf() {
  const chunks = [header];
  const offsets = [0];
  let offset = header.byteLength;
  for (const object of objects) {
    const body = Buffer.isBuffer(object) ? object : Buffer.from(object, 'ascii');
    const serialized = Buffer.concat([
      Buffer.from(`${offsets.length} 0 obj\n`, 'ascii'),
      body,
      Buffer.from('\nendobj\n', 'ascii'),
    ]);
    offsets.push(offset);
    chunks.push(serialized);
    offset += serialized.byteLength;
  }

  const xrefOffset = offset;
  const xref = [
    `xref\n0 ${offsets.length}`,
    '0000000000 65535 f',
    ...offsets.slice(1).map((value) => `${String(value).padStart(10, '0')} 00000 n`),
    'trailer',
    `<< /Size ${offsets.length} /Root 1 0 R >>`,
    'startxref',
    String(xrefOffset),
    '%%EOF',
    '',
  ].join('\n');
  chunks.push(Buffer.from(xref, 'ascii'));
  return Buffer.concat(chunks);
}

function writeFixture() {
  fs.mkdirSync(directory, { recursive: true });
  fs.writeFileSync(outputPath, buildPdf());
  console.log(`wrote ${path.relative(process.cwd(), outputPath)}`);
}

function checkFixture() {
  assertEligibilityContract();
  assert(fs.existsSync(outputPath), `missing fixture: ${outputPath}`);
  const committed = fs.readFileSync(outputPath);
  assert(committed.equals(buildPdf()), 'fixture is stale; regenerate it');
  assert(committed.includes(Buffer.from('/FontDescriptor 8 0 R', 'ascii')));
  assert(!committed.includes(Buffer.from('/FontFile', 'ascii')));
  console.log(`checked ${path.relative(process.cwd(), outputPath)}`);
}

if (process.argv.includes('--check')) {
  checkFixture();
} else {
  writeFixture();
}

export { buildPdf, expected };
