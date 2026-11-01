// Minimal single-band GeoTIFF reader for GPXZ rasters: classic TIFF, strips or tiles,
// no/LZW/Deflate compression and predictors 1–3. Anything else is rejected.
const TYPE_SIZES = { 1: 1, 2: 1, 3: 2, 4: 4, 5: 8, 6: 1, 7: 1, 8: 2, 9: 4, 10: 8, 11: 4, 12: 8, 16: 8 };
const MAX_DIMENSION = 10000;

export class TiffError extends Error {}
const fail = message => { throw new TiffError(message); };

function readTags(view, little) {
  if (view.byteLength < 8 || view.getUint16(2, little) !== 42) fail('Not a classic TIFF.');
  const offset = view.getUint32(4, little);
  if (offset + 2 > view.byteLength) fail('IFD out of range.');
  const count = view.getUint16(offset, little);
  if (offset + 2 + count * 12 > view.byteLength) fail('IFD out of range.');
  const tags = new Map();
  for (let i = 0; i < count; i++) {
    const entry = offset + 2 + i * 12;
    const tag = view.getUint16(entry, little);
    const type = view.getUint16(entry + 2, little);
    const length = view.getUint32(entry + 4, little);
    const size = TYPE_SIZES[type];
    if (!size) continue;
    const total = size * length;
    const start = total <= 4 ? entry + 8 : view.getUint32(entry + 8, little);
    if (length > 10_000_000 || start + total > view.byteLength) fail('Tag out of range.');
    tags.set(tag, { type, length, start });
  }
  return tags;
}

function tagValues(view, little, tag) {
  const { type, length, start } = tag;
  const size = TYPE_SIZES[type];
  const values = new Array(length);
  for (let i = 0; i < length; i++) {
    const at = start + i * size;
    switch (type) {
      case 1: case 7: values[i] = view.getUint8(at); break;
      case 3: values[i] = view.getUint16(at, little); break;
      case 4: values[i] = view.getUint32(at, little); break;
      case 6: values[i] = view.getInt8(at); break;
      case 8: values[i] = view.getInt16(at, little); break;
      case 9: values[i] = view.getInt32(at, little); break;
      case 11: values[i] = view.getFloat32(at, little); break;
      case 12: values[i] = view.getFloat64(at, little); break;
      case 16: values[i] = Number(view.getBigUint64(at, little)); break;
      default: fail('Unsupported tag type.');
    }
  }
  return values;
}

function tagText(bytes, tag) {
  if (!tag || tag.type !== 2) return null;
  let text = '';
  for (let i = 0; i < tag.length; i++) {
    const byte = bytes[tag.start + i];
    if (byte === 0) break;
    text += String.fromCharCode(byte);
  }
  return text;
}

async function inflate(bytes) {
  const stream = new Blob([bytes]).stream().pipeThrough(new DecompressionStream('deflate'));
  return new Uint8Array(await new Response(stream).arrayBuffer());
}

// TIFF LZW: MSB-first codes, 9–12 bits, code width grows one code early.
export function decodeLZW(input, expected) {
  const out = new Uint8Array(expected);
  const prefix = new Int16Array(4096);
  const suffix = new Uint8Array(4096);
  const size = new Uint16Array(4096);
  for (let i = 0; i < 256; i++) { prefix[i] = -1; suffix[i] = i; size[i] = 1; }
  let next = 258, width = 9, previous = -1, position = 0, bit = 0;
  const totalBits = input.length * 8;
  const write = code => {
    const length = size[code];
    if (position + length > expected) fail('LZW output overflow.');
    let current = code;
    for (let i = length - 1; i >= 0; i--) { out[position + i] = suffix[current]; current = prefix[current]; }
    position += length;
    return out[position - length];
  };
  while (bit + width <= totalBits) {
    let code = 0;
    for (let i = 0; i < width; i++, bit++) code = (code << 1) | ((input[bit >> 3] >> (7 - (bit & 7))) & 1);
    if (code === 257) break;
    if (code === 256) { next = 258; width = 9; previous = -1; continue; }
    if (previous === -1) {
      if (code > 255) fail('Invalid LZW code.');
      write(code);
      previous = code;
      continue;
    }
    let first;
    if (code < next && (code < 256 || code > 257)) first = write(code);
    else if (code === next) {
      first = write(previous);
      if (position >= expected) fail('LZW output overflow.');
      out[position++] = first;
    } else fail('Invalid LZW code.');
    if (next < 4096) { prefix[next] = previous; suffix[next] = first; size[next] = size[previous] + 1; next++; }
    previous = code;
    if (next >= (1 << width) - 1 && width < 12) width++;
  }
  return out.subarray(0, position);
}

function undoPredictor(block, predictor, width, rows, bytesPerSample, little) {
  const rowBytes = width * bytesPerSample;
  if (predictor === 2) {
    const view = new DataView(block.buffer, block.byteOffset, block.byteLength);
    for (let row = 0; row < rows; row++) {
      for (let x = 1; x < width; x++) {
        const at = row * rowBytes + x * bytesPerSample, before = at - bytesPerSample;
        if (bytesPerSample === 1) block[at] += block[before];
        else if (bytesPerSample === 2) view.setUint16(at, view.getUint16(at, little) + view.getUint16(before, little), little);
        else if (bytesPerSample === 4) view.setUint32(at, (view.getUint32(at, little) + view.getUint32(before, little)) >>> 0, little);
        else fail('Unsupported predictor sample size.');
      }
    }
    return { bytes: block, little };
  }
  if (predictor === 3) {
    // Floating-point predictor stores byte planes most-significant first.
    const out = new Uint8Array(block.length);
    for (let row = 0; row < rows; row++) {
      const base = row * rowBytes;
      for (let i = 1; i < rowBytes; i++) block[base + i] += block[base + i - 1];
      for (let x = 0; x < width; x++) {
        for (let b = 0; b < bytesPerSample; b++) out[base + x * bytesPerSample + b] = block[base + b * width + x];
      }
    }
    return { bytes: out, little: false };
  }
  if (predictor !== 1) fail('Unsupported predictor.');
  return { bytes: block, little };
}

function sampleReader(format, bits) {
  const readers = {
    '1:8': (v, at) => v.getUint8(at), '1:16': (v, at, l) => v.getUint16(at, l), '1:32': (v, at, l) => v.getUint32(at, l),
    '2:8': (v, at) => v.getInt8(at), '2:16': (v, at, l) => v.getInt16(at, l), '2:32': (v, at, l) => v.getInt32(at, l),
    '3:32': (v, at, l) => v.getFloat32(at, l), '3:64': (v, at, l) => v.getFloat64(at, l)
  };
  return readers[`${format}:${bits}`] ?? fail('Unsupported sample format.');
}

export async function decodeTiff(bytes) {
  if (!(bytes instanceof Uint8Array) || bytes.length < 8) fail('Not a TIFF.');
  const order = String.fromCharCode(bytes[0], bytes[1]);
  if (order !== 'II' && order !== 'MM') fail('Not a TIFF.');
  const little = order === 'II';
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  const tags = readTags(view, little);
  const all = id => tags.has(id) ? tagValues(view, little, tags.get(id)) : null;
  const one = (id, fallback) => {
    const values = all(id);
    if (values?.length) return values[0];
    if (fallback === undefined) fail(`Missing TIFF tag ${id}.`);
    return fallback;
  };
  const width = one(256), height = one(257);
  if (!(width >= 1 && height >= 1 && width <= MAX_DIMENSION && height <= MAX_DIMENSION)) fail('Invalid raster size.');
  if (one(277, 1) !== 1 || one(284, 1) !== 1) fail('Only single-band rasters are supported.');
  const bits = one(258);
  const read = sampleReader(one(339, 1), bits);
  const bytesPerSample = bits / 8;
  const compression = one(259, 1);
  const predictor = one(317, 1);
  const tiled = tags.has(322);
  const blockWidth = tiled ? one(322) : width;
  const blockHeight = tiled ? one(323) : Math.min(one(278, height), height);
  const offsets = all(tiled ? 324 : 273), counts = all(tiled ? 325 : 279);
  if (!(blockWidth >= 1 && blockHeight >= 1 && blockWidth <= MAX_DIMENSION && blockHeight <= MAX_DIMENSION)) fail('Invalid block size.');
  const across = Math.ceil(width / blockWidth), down = Math.ceil(height / blockHeight);
  if (!offsets || !counts || offsets.length !== across * down || counts.length !== offsets.length) fail('Invalid block table.');

  const data = new Float32Array(width * height);
  for (let index = 0; index < offsets.length; index++) {
    const bx = index % across, by = Math.floor(index / across);
    const start = offsets[index], length = counts[index];
    if (start + length > bytes.length) fail('Block out of range.');
    const raw = bytes.subarray(start, start + length);
    const rows = tiled ? blockHeight : Math.min(blockHeight, height - by * blockHeight);
    const expected = blockWidth * rows * bytesPerSample;
    let block;
    if (compression === 1) block = raw.slice();
    else if (compression === 5) block = decodeLZW(raw, expected);
    else if (compression === 8 || compression === 32946) block = await inflate(raw);
    else fail('Unsupported compression.');
    if (block.length < expected) fail('Truncated block.');
    const decoded = undoPredictor(block.subarray(0, expected), predictor, blockWidth, rows, bytesPerSample, little);
    const blockView = new DataView(decoded.bytes.buffer, decoded.bytes.byteOffset, decoded.bytes.byteLength);
    for (let row = 0; row < rows; row++) {
      const y = by * blockHeight + row;
      if (y >= height) break;
      for (let column = 0; column < blockWidth; column++) {
        const x = bx * blockWidth + column;
        if (x >= width) break;
        data[y * width + x] = read(blockView, (row * blockWidth + column) * bytesPerSample, decoded.little);
      }
    }
  }
  const nodataText = tagText(bytes, tags.get(42113));
  return {
    width, height, data,
    pixelScale: all(33550),
    tiepoint: all(33922),
    metadata: tagText(bytes, tags.get(42112)),
    nodata: nodataText === null || nodataText.trim() === '' ? null : Number(nodataText)
  };
}
