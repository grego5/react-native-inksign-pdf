#!/usr/bin/env node

import { existsSync, readFileSync, writeFileSync } from 'node:fs';
import { join, resolve } from 'node:path';

const baseNames = [
  'synthetic-moderate-straight',
  'synthetic-fast-straight',
  'synthetic-moderate-curve',
  'synthetic-fast-curve',
  'synthetic-moderate-curve-short',
  'synthetic-fast-curve-short',
  'synthetic-accel-before-reference',
  'synthetic-accel-across-reference',
  'synthetic-accel-after-reference',
];
const angles = [0, 45, 90];
const cellWidth = 290;
const cellHeight = 210;
const margin = 10;

function usage() {
  console.error('Usage: node tools/make-stroke-replay-sheet.mjs --dir ARTIFACT_DIR --out OUTPUT.svg');
}

let artifactDir;
let outputPath;
for (let index = 2; index < process.argv.length; ++index) {
  const argument = process.argv[index];
  if (argument === '--dir' && index + 1 < process.argv.length) artifactDir = process.argv[++index];
  else if (argument === '--out' && index + 1 < process.argv.length) outputPath = process.argv[++index];
  else { usage(); process.exit(2); }
}
if (!artifactDir || !outputPath) { usage(); process.exit(2); }
artifactDir = resolve(artifactDir);
outputPath = resolve(outputPath);

function rows(path) {
  if (!existsSync(path)) throw new Error('missing artifact: ' + path);
  return readFileSync(path, 'utf8').split(/\r?\n/).map(line => line.trim())
    .filter(line => line && !line.startsWith('#'));
}

function readInput(name) {
  const lines = rows(join(artifactDir, name + '-input.csv'));
  const header = lines.shift().split(',');
  const time = header.indexOf('time');
  const x = header.indexOf('x');
  const y = header.indexOf('y');
  const result = [];
  const seen = new Set();
  for (const line of lines) {
    const fields = line.split(',');
    const value = {event: fields[1], time: Number(fields[time]),
      point: {x: Number(fields[x]), y: Number(fields[y])}};
    const key = value.event + '|' + value.time + '|' + value.point.x + '|' + value.point.y;
    if (!seen.has(key)) { seen.add(key); result.push(value); }
  }
  return result;
}

function readGeometry(name) {
  const lines = rows(join(artifactDir, name + '-geometry.csv'));
  const header = lines.shift().split(',');
  const index = field => header.indexOf(field);
  const paths = new Map();
  for (const line of lines) {
    const fields = line.split(',');
    const pathName = fields[index('path')];
    const segment = {
      p0: {x: Number(fields[index('p0x')]), y: Number(fields[index('p0y')])},
      c1: {x: Number(fields[index('c1x')]), y: Number(fields[index('c1y')])},
      c2: {x: Number(fields[index('c2x')]), y: Number(fields[index('c2y')])},
      p3: {x: Number(fields[index('p3x')]), y: Number(fields[index('p3y')])},
    };
    if (!paths.has(pathName)) paths.set(pathName, []);
    paths.get(pathName).push(segment);
  }
  return [...paths.values()];
}

function readTable(name, suffix) {
  const lines = rows(join(artifactDir, name + suffix));
  const header = lines.shift().split(',');
  return lines.map(line => {
    const fields = line.split(',');
    const value = {};
    for (let index = 0; index < header.length; ++index)
      value[header[index]] = fields[index] ?? '';
    return value;
  });
}

function startupSummary(name) {
  return readTable(name, '-envelope.csv')[0] ?? {};
}

function writeStartupSources(name) {
  const diagnostics = readTable(name, '-diagnostics.csv');
  const startupRows = readTable(name, '-envelope.csv');
  const startup = startupRows[0] ?? {};
  const bySource = new Map(diagnostics.map(value => [value.modeled_index, value]));
  const initial = bySource.get('0') ?? {};
  const initialRadius = Number(initial.final_radius_page);
  const output = [
    '# schema=synthetic-envelope-sources-v2; values copied from production replay diagnostics',
    'source_index,source_x,source_y,raw_normalized_speed,dt_seconds,turn_factor,effective_speed_display,target_radius_page,radius_page,segment_distance_page,max_radius_change_page,limited_target_radius_page,response_alpha,final_radius_page,contains_initial_circle,initial_circle_containment_margin',
  ];
  for (const diagnostic of diagnostics) {
    const sourceX = Number(diagnostic.page_x);
    const sourceY = Number(diagnostic.page_y);
    const radius = Number(diagnostic.final_radius_page);
    const marginToInitial = Number.isFinite(sourceX) && Number.isFinite(sourceY) &&
      Number.isFinite(radius) && Number.isFinite(initialRadius)
      ? radius - (Math.hypot(sourceX - Number(initial.page_x), sourceY - Number(initial.page_y)) + initialRadius)
      : NaN;
    output.push([
      diagnostic.modeled_index, diagnostic.page_x ?? '', diagnostic.page_y ?? '',
      Number(diagnostic.display_speed) / 960,
      diagnostic.dt_seconds ?? '', diagnostic.turn_factor ?? '',
      diagnostic.effective_speed_display ?? '',
      diagnostic.target_radius_page ?? '', diagnostic.radius_page ?? '',
      diagnostic.segment_distance_page ?? '', diagnostic.max_radius_change_page ?? '',
      diagnostic.limited_target_radius_page ?? '',
      diagnostic.response_alpha ?? '', diagnostic.final_radius_page ?? '',
      Number.isFinite(marginToInitial) ? (marginToInitial >= 0 ? 1 : 0) : '',
      Number.isFinite(marginToInitial) ? marginToInitial : '',
    ].join(','));
  }
  writeFileSync(join(artifactDir, name + '-startup-sources.csv'), output.join('\n') + '\n');
}

function rotate(point, degrees) {
  const angle = degrees * Math.PI / 180;
  const cosine = Math.cos(angle);
  const sine = Math.sin(angle);
  return {x: point.x * cosine - point.y * sine, y: point.x * sine + point.y * cosine};
}

function inverseRotate(point, degrees) { return rotate(point, -degrees); }
function allPoints(paths) {
  return paths.flatMap(path => path.flatMap(segment => [segment.p0, segment.c1, segment.c2, segment.p3]));
}
function bounds(points) {
  return {minX: Math.min(...points.map(point => point.x)),
    maxX: Math.max(...points.map(point => point.x)),
    minY: Math.min(...points.map(point => point.y)),
    maxY: Math.max(...points.map(point => point.y))};
}
function pathData(path, map) {
  const point = value => {
    const mapped = map(value);
    return mapped.x.toFixed(3) + ' ' + mapped.y.toFixed(3);
  };
  return 'M ' + point(path[0].p0) + ' ' +
    path.map(segment => 'C ' + point(segment.c1) + ' ' + point(segment.c2) + ' ' + point(segment.p3)).join(' ') + ' Z';
}
function inputDirection(name) {
  const input = readInput(name);
  const down = input.find(value => value.event === 'down');
  const next = input.find(value => value.event === 'move' || value.event === 'up');
  const dx = next.point.x - down.point.x;
  const dy = next.point.y - down.point.y;
  const length = Math.hypot(dx, dy) || 1;
  return {x: dx / length, y: dy / length, start: down.point};
}

function transformPaths(paths, transform) {
  return paths.map(path => path.map(segment => {
    const result = {};
    for (const key of ['p0', 'c1', 'c2', 'p3']) result[key] = transform(segment[key]);
    return result;
  }));
}

function cubicPoint(segment, t) {
  const u = 1 - t;
  return {
    x: u ** 3 * segment.p0.x + 3 * u ** 2 * t * segment.c1.x +
      3 * u * t ** 2 * segment.c2.x + t ** 3 * segment.p3.x,
    y: u ** 3 * segment.p0.y + 3 * u ** 2 * t * segment.c1.y +
      3 * u * t ** 2 * segment.c2.y + t ** 3 * segment.p3.y,
  };
}

function polygonForPath(path) {
  return path.flatMap(segment => Array.from({length: 33}, (_, index) =>
    cubicPoint(segment, index / 32))).filter((point, index, values) =>
      index === 0 || point.x !== values[index - 1].x || point.y !== values[index - 1].y);
}

function pointInPolygon(point, polygon) {
  let inside = false;
  for (let index = 0, previous = polygon.length - 1; index < polygon.length; previous = index++) {
    const left = polygon[index];
    const right = polygon[previous];
    const crosses = (left.y > point.y) !== (right.y > point.y);
    if (crosses && point.x < (right.x - left.x) * (point.y - left.y) /
        (right.y - left.y) + left.x) inside = !inside;
  }
  return inside;
}

function rasterFilledContours(paths, rasterBounds, scale) {
  const polygons = paths.map(polygonForPath);
  const width = Math.max(1, Math.ceil((rasterBounds.maxX - rasterBounds.minX) * scale));
  const height = Math.max(1, Math.ceil((rasterBounds.maxY - rasterBounds.minY) * scale));
  const pixels = new Uint8Array(width * height);
  for (let y = 0; y < height; ++y) {
    for (let x = 0; x < width; ++x) {
      const point = {x: rasterBounds.minX + (x + 0.5) / scale,
        y: rasterBounds.minY + (y + 0.5) / scale};
      if (polygons.some(polygon => pointInPolygon(point, polygon))) pixels[y * width + x] = 1;
    }
  }
  return {pixels, width, height};
}

function filledContourDifference(base, rotated, angle) {
  const inversePaths = transformPaths(rotated.paths, point => inverseRotate(point, angle));
  const points = [...allPoints(base.paths), ...allPoints(inversePaths)];
  const rawBounds = bounds(points);
  const padding = 1;
  const rasterBounds = {minX: rawBounds.minX - padding, maxX: rawBounds.maxX + padding,
    minY: rawBounds.minY - padding, maxY: rawBounds.maxY + padding};
  const scale = 8;
  const left = rasterFilledContours(base.paths, rasterBounds, scale);
  const right = rasterFilledContours(inversePaths, rasterBounds, scale);
  let differentPixels = 0;
  let leftPixels = 0;
  let rightPixels = 0;
  let intersection = 0;
  for (let index = 0; index < left.pixels.length; ++index) {
    leftPixels += left.pixels[index];
    rightPixels += right.pixels[index];
    intersection += left.pixels[index] && right.pixels[index] ? 1 : 0;
    differentPixels += left.pixels[index] !== right.pixels[index] ? 1 : 0;
  }
  const union = leftPixels + rightPixels - intersection;
  return {scale, width: left.width, height: left.height, differentPixels,
    xorFraction: differentPixels / left.pixels.length, iou: union === 0 ? 1 : intersection / union};
}

const data = new Map();
for (const base of baseNames) {
  for (const angle of angles) {
    const name = angle === 0 ? base : base + '-rot' + angle;
    writeStartupSources(name);
    data.set(name, {name, base, angle, paths: readGeometry(name), input: readInput(name), startup: startupSummary(name)});
  }
}

const svg = [];
const sheetWidth = margin * 2 + angles.length * 2 * cellWidth;
const sheetHeight = 42 + baseNames.length * cellHeight;
svg.push('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ' + sheetWidth + ' ' + sheetHeight + '">');
svg.push('<title>Synthetic production replay comparison: filled published cubics</title>');
svg.push('<rect width="100%" height="100%" fill="white"/>');
svg.push('<text x="10" y="22" font-family="sans-serif" font-size="16" fill="#111827">Synthetic production replay — filled published contours; startup zooms use the same pixel scale as the matching full stroke</text>');

for (let row = 0; row < baseNames.length; ++row) {
  const base = baseNames[row];
  const items = angles.flatMap(angle => {
    const item = data.get(angle === 0 ? base : base + '-rot' + angle);
    return [item, item];
  });
  const fullBounds = items.map(item => bounds(allPoints(item.paths)));
  const maxWidth = Math.max(...fullBounds.map(value => value.maxX - value.minX));
  const maxHeight = Math.max(...fullBounds.map(value => value.maxY - value.minY));
  const scale = Math.min((cellWidth - 2 * margin) / maxWidth, (cellHeight - 45) / maxHeight);
  const rowY = 42 + row * cellHeight;
  for (let column = 0; column < items.length; ++column) {
    const item = items[column];
    const box = fullBounds[column];
    const direction = inputDirection(item.name);
    const normalCenter = {x: (box.minX + box.maxX) / 2, y: (box.minY + box.maxY) / 2};
    const zoomWidth = (cellWidth - 2 * margin) / scale;
    const zoomHeight = (cellHeight - 45) / scale;
    const zoomCenter = {x: direction.start.x + direction.x * zoomWidth * 0.18,
      y: direction.start.y + direction.y * zoomHeight * 0.18};
    const isZoom = column % 2 === 1;
    const center = isZoom ? zoomCenter : normalCenter;
    const viewWidth = (cellWidth - 2 * margin) / scale;
    const viewHeight = (cellHeight - 45) / scale;
    const cellX = margin + column * cellWidth;
    const orientation = angles[Math.floor(column / 2)];
    const label = base.replace('synthetic-', '') + ' · ' + orientation + '° · ' +
      (isZoom ? 'startup zoom' : 'full') + ' · forward';
    svg.push('<text x="' + (cellX + margin) + '" y="' + (rowY + 15) + '" font-family="sans-serif" font-size="11" fill="#111827">' + label + '</text>');
    const clipId = 'clip-' + row + '-' + column;
    svg.push('<clipPath id="' + clipId + '"><rect x="' + (cellX + margin) + '" y="' + (rowY + 25) + '" width="' + (cellWidth - 2 * margin) + '" height="' + (cellHeight - 30) + '"/></clipPath>');
    const map = value => ({x: cellX + margin + (value.x - (center.x - viewWidth / 2)) * scale,
      y: rowY + 25 + (value.y - (center.y - viewHeight / 2)) * scale});
    svg.push('<g clip-path="url(#' + clipId + ')">');
    for (const path of item.paths)
      svg.push('<path d="' + pathData(path, map) + '" fill="#111827" stroke="none"/>');
    svg.push('</g>');
    svg.push('<rect x="' + (cellX + margin) + '" y="' + (rowY + 25) + '" width="' + (cellWidth - 2 * margin) + '" height="' + (cellHeight - 30) + '" fill="none" stroke="#d1d5db"/>');
  }
}
svg.push('</svg>\n');
writeFileSync(outputPath, svg.join('\n'));

function segmentationDifference(base, rotated) {
  const left = base.paths.reduce((sum, path) => sum + path.length, 0);
  const right = rotated.paths.reduce((sum, path) => sum + path.length, 0);
  return {basePaths: base.paths.length, rotatedPaths: rotated.paths.length,
    baseSegments: left, rotatedSegments: right, segmentCountDifference: Math.abs(left - right)};
}
function maxInputDifference(base, rotated, angle) {
  let maxError = 0;
  for (let index = 0; index < Math.min(base.input.length, rotated.input.length); ++index) {
    const left = base.input[index];
    const right = rotated.input[index];
    const actual = inverseRotate(right.point, angle);
    maxError = Math.max(maxError, Math.abs(left.time - right.time),
      Math.abs(left.point.x - actual.x), Math.abs(left.point.y - actual.y));
  }
  return {maxError, countMismatch: Math.abs(base.input.length - rotated.input.length)};
}

const report = ['# Synthetic production-replay fixture report', '',
  'The SVG sheet contains separately filled published production contours only. No diagnostic centerline, section marker, or outline is drawn.', '',
  '| Fixture | Rotation | Input inverse-rotation max error | Filled raster scale | Different pixels / fraction | IoU | Segmentation (paths; segments) | Startup diagnostic |',
  '|---|---:|---:|---:|---:|---:|---:|---:|'];
for (const base of baseNames) {
  for (const angle of [45, 90]) {
    const input = maxInputDifference(data.get(base), data.get(base + '-rot' + angle), angle);
    const rotated = data.get(base + '-rot' + angle);
    const geometry = filledContourDifference(data.get(base), rotated, angle);
    const segmentation = segmentationDifference(data.get(base), rotated);
    const startup = rotated.startup;
    const startupDiagnostic = (startup.has_moving_diagnostic ?? 'unknown') + ' / ' +
      (startup.evidence_status ?? 'unknown') + ' / ' + (startup.evidence_reason ?? 'unknown');
    report.push('| ' + base + ' | ' + angle + '° | ' + input.maxError.toExponential(6) + ' (' + input.countMismatch + ') | ' + geometry.scale + ' px/page | ' + geometry.differentPixels + ' / ' + geometry.xorFraction.toExponential(6) + ' | ' + geometry.iou.toFixed(8) + ' | ' + segmentation.basePaths + '/' + segmentation.rotatedPaths + '; ' + segmentation.baseSegments + '/' + segmentation.rotatedSegments + ' (Δ' + segmentation.segmentCountDifference + ') | ' + startupDiagnostic + ' |');
  }
}
report.push('', 'Per-source modeled radius and causal width-recurrence records are in each fixture’s -startup-sources.csv companion, generated from the replay -diagnostics.csv and -envelope.csv artifacts. The replay tables remain authoritative for published geometry evidence and terminal observations.');
writeFileSync(join(artifactDir, 'synthetic-startup-rotation-report.md'), report.join('\n') + '\n');

const findings = [
  '# Synthetic startup findings',
  '',
  '- Tested range: delayed-acceleration and speed-band controls with 0°/45°/90° copies; zero smoothing; 1.0–4.0 page-unit pen diameters; explicit 8 ms sampling. Production normalized speed remains clamped to 1.0 at saturation.',
  '- Width response uses the effective display speed, the exact periodic turn factor, temporal alpha, and a symmetric 0.15-per-page-unit radius-change limit.',
  '- The offline startup-envelope evaluator reports sampled evidence from published contours. Unsupported sections remain unsupported and are not classified as passes.',
  '- Moving samples start at the configured minimum radius; later ordinary radii follow the causal effective-speed target and spatial limit.',
  '- Actual width valley: not reproduced. Published-cubic evidence reports no sampled width valley and no inward-side movement for the long or short curved cases.',
  '- Short curved cases: terminal taper decreases emitted radius monotonically to the 0.01 boundary at contact; contact remains nonzero-width. This is terminal taper, not startup necking.',
  '- The screenshot is not claimed explained by these fixtures. The full and startup-zoom comparison is visual evidence for review, not an appearance-acceptance pass.',
  '',
  'Artifacts:',
  '',
  '- ../synthetic-startup-comparison.svg — filled published contours with full and matching-scale startup views.',
  '- synthetic-startup-rotation-report.md — inverse-rotated filled-contour raster differences; segmentation counts are reported separately and are not treated as silhouette defects.',
  '- synthetic-*-startup-sources.csv — source positions, target/radius/turn/temporal-response samples, containment margin, and final emitted radius.',
  '- synthetic-*-diagnostics.csv — complete modeled speed/acceleration/width/taper samples.',
  '- synthetic-*-envelope.csv and synthetic-*-terminal.csv — offline envelope evidence and terminal observations.',
];
writeFileSync(join(artifactDir, 'synthetic-startup-findings.md'), findings.join('\n') + '\n');
