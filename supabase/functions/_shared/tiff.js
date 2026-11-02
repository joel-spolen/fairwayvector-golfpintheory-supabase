// Minimal single-band GeoTIFF reader for GPXZ rasters: classic TIFF or BigTIFF, strips or tiles,
// no/LZW/Deflate compression and predictors 1–3. Anything else is rejected.
const TYPE_SIZES = { 1: 1, 2: 1, 3: 2, 4: 4, 5: 8, 6: 1, 7: 1, 8: 2, 9: 4, 10: 8, 11: 4, 12: 8, 16: 8, 17: 8, 18: 8 };
const MAX_DIMENSION = 10000;

export class TiffError extends Error {}
const fail = message => { throw new TiffError(message); };

function readTags(view, little) {
  const magic = view.byteLength >= 8 ? view.getUint16(2, little) : 0;
  const big = magic === 43;
  if (magic !== 42 && !big) fail('Not a TIFF.');
  if (big && (view.byteLength < 16 || view.getUint16(4, little) !== 8 || view.getUint16(6, little) !== 0)) {
    fail('Unsupported BigTIFF.');
  }
  const word = at => big ? Number(view.getBigUint64(at, little)) : view.getUint32(at, little);
  const offset = word(big ? 8 : 4);
  const countSize = big ? 8 : 2, entrySize = big ? 20 : 12, inline = big ? 8 : 4;
  if (offset + countSize > view.byteLength) fail('IFD out of range.');
  const count = big ? Number(view.getBigUint64(offset, little)) : view.getUint16(offset, little);
  if (offset + countSize + count * entrySize > view.byteLength) fail('IFD out of range.');
  const tags = new Map();
  for (let i = 0; i < count; i++) {
    const entry = offset + countSize + i * entrySize;
    const tag = view.getUint16(entry, little);
    const type = view.getUint16(entry + 2, little);
    const length = word(entry + 4);
    const size = TYPE_SIZES[type];
    if (!size) continue;
    const total = size * length;
    const valueAt = entry + (big ? 12 : 8);
    const start = total <= inline ? valueAt : word(valueAt);
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
      case 16: case 18: values[i] = Number(view.getBigUint64(at, little)); break;
      case 17: values[i] = Number(view.getBigInt64(at, little)); break;
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

/** Image layout from the first IFD; `bytes` may be just the file's leading range (COG header). */
export function readTiffLayout(bytes) {
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
  const sampleFormat = one(339, 1);
  const read = sampleReader(sampleFormat, bits);
  const compression = one(259, 1);
  if (![1, 5, 8, 32946].includes(compression)) fail('Unsupported compression.');
  const tiled = tags.has(322);
  const blockWidth = tiled ? one(322) : width;
  const blockHeight = tiled ? one(323) : Math.min(one(278, height), height);
  const offsets = all(tiled ? 324 : 273), counts = all(tiled ? 325 : 279);
  if (!(blockWidth >= 1 && blockHeight >= 1 && blockWidth <= MAX_DIMENSION && blockHeight <= MAX_DIMENSION)) fail('Invalid block size.');
  const across = Math.ceil(width / blockWidth), down = Math.ceil(height / blockHeight);
  if (!offsets || !counts || offsets.length !== across * down || counts.length !== offsets.length) fail('Invalid block table.');
  const nodataText = tagText(bytes, tags.get(42113));
  return {
    little, width, height, tiled, blockWidth, blockHeight, across, down, offsets, counts, read, compression,
    sampleFormat, bytesPerSample: bits / 8, predictor: one(317, 1),
    pixelScale: all(33550), tiepoint: all(33922), metadata: tagText(bytes, tags.get(42112)),
    nodata: nodataText === null || nodataText.trim() === '' ? null : Number(nodataText)
  };
}

/** Rows actually stored in block row `by` (strips are not padded, tiles are). */
export function blockRows(layout, by) {
  return layout.tiled ? layout.blockHeight : Math.min(layout.blockHeight, layout.height - by * layout.blockHeight);
}

/** Float32 + floating-point predictor (Lantmäteriet COGs): byte planes MSB first, straight to bits. */
function floatPredictorBlock(block, width, rows) {
  const bits = new Uint32Array(width * rows), rowBytes = width * 4;
  for (let row = 0; row < rows; row++) {
    const base = row * rowBytes;
    for (let i = base + 1; i < base + rowBytes; i++) block[i] += block[i - 1];
    const p1 = base + width, p2 = p1 + width, p3 = p2 + width, out = row * width;
    for (let x = 0; x < width; x++) {
      bits[out + x] = ((block[base + x] << 24) | (block[p1 + x] << 16) | (block[p2 + x] << 8) | block[p3 + x]) >>> 0;
    }
  }
  return new Float32Array(bits.buffer);
}

/** Decodes one compressed block into blockWidth × rows samples. */
export async function decodeBlock(layout, raw, rows) {
  const { blockWidth, bytesPerSample, compression } = layout;
  const expected = blockWidth * rows * bytesPerSample;
  let block;
  if (compression === 1) block = raw.slice();
  else if (compression === 5) block = decodeLZW(raw, expected);
  else block = await inflate(raw);
  if (block.length < expected) fail('Truncated block.');
  if (layout.predictor === 3 && bytesPerSample === 4 && layout.sampleFormat === 3) {
    return floatPredictorBlock(block, blockWidth, rows);
  }
  const decoded = undoPredictor(block.subarray(0, expected), layout.predictor, blockWidth, rows, bytesPerSample, layout.little);
  const view = new DataView(decoded.bytes.buffer, decoded.bytes.byteOffset, decoded.bytes.byteLength);
  const values = new Float32Array(blockWidth * rows);
  for (let i = 0; i < values.length; i++) values[i] = layout.read(view, i * bytesPerSample, decoded.little);
  return values;
}

export async function decodeTiff(bytes) {
  const layout = readTiffLayout(bytes);
  const { width, height, blockWidth, blockHeight, across, offsets, counts } = layout;
  const data = new Float32Array(width * height);
  for (let index = 0; index < offsets.length; index++) {
    const bx = index % across, by = Math.floor(index / across);
    const start = offsets[index], length = counts[index];
    if (start + length > bytes.length) fail('Block out of range.');
    const rows = blockRows(layout, by);
    const values = await decodeBlock(layout, bytes.subarray(start, start + length), rows);
    for (let row = 0; row < rows; row++) {
      const y = by * blockHeight + row;
      if (y >= height) break;
      for (let column = 0; column < blockWidth; column++) {
        const x = bx * blockWidth + column;
        if (x >= width) break;
        data[y * width + x] = values[row * blockWidth + column];
      }
    }
  }
  return { width, height, data, pixelScale: layout.pixelScale, tiepoint: layout.tiepoint,
    metadata: layout.metadata, nodata: layout.nodata };
}
