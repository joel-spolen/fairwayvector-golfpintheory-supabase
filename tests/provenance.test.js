import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = fileURLToPath(new URL('../', import.meta.url));
const manifest = JSON.parse(readFileSync(new URL('../docs/source-provenance.json', import.meta.url), 'utf8'));
const digest = bytes => createHash('sha256').update(bytes).digest('hex');
// Preserve leading indentation, internal spacing and interior blank lines.
const normalize = text => text.split(/\r?\n/).map(line => line.trimEnd()).join('\n').trimEnd();

test('legacy provenance manifest has exactly eleven unique reviewed copies', () => {
  assert.equal(manifest.algorithm, 'sha256');
  assert.equal(manifest.copyPolicy, 'content copied; whitespace normalized');
  assert.equal(manifest.files.length, 11);
  assert.equal(new Set(manifest.files.map(file => file.source)).size, 11);
  assert.equal(new Set(manifest.files.map(file => file.destination)).size, 11);
});

test('normalization accepts only the documented whitespace differences', () => {
  const content = 'begin;\n    select 1;\n\ncommit;';
  assert.equal(normalize('begin; \r\n    select 1;\t\r\n  \r\ncommit;\r\n\r\n'), content);
  assert.notEqual(normalize(content.replace('    select', 'select')), content);
  assert.notEqual(normalize(content.replace('select 1', 'select  1')), content);
  assert.notEqual(normalize(content.replace('select 1', 'select 2')), content);
  assert.notEqual(normalize(content.replace('\n\n', '\n')), content);
  assert.notEqual(normalize(content.replace('    select 1;\n', '')), content);
});

for (const file of manifest.files) {
  test(`copied content; whitespace normalized: ${file.destination}`, () => {
    assert.match(file.sha256, /^[a-f0-9]{64}$/);
    assert.match(file.normalizedSha256, /^[a-f0-9]{64}$/);
    const destination = normalize(readFileSync(resolve(root, file.destination), 'utf8'));
    assert.equal(digest(destination), file.normalizedSha256, `copied content changed: ${file.destination}`);
  });
}

// Explicit opt-in only: a standalone checkout and CI need no sibling repository.
test('optional comparison with the original iOS repository', {
  skip: !process.env.LEGACY_SOURCE_ROOT
}, () => {
  for (const file of manifest.files) {
    const source = normalize(readFileSync(resolve(process.env.LEGACY_SOURCE_ROOT, file.source), 'utf8'));
    const destination = normalize(readFileSync(resolve(root, file.destination), 'utf8'));
    assert.equal(digest(source), file.normalizedSha256, `original content changed: ${file.source}`);
    assert.equal(destination, source, `incomplete or changed copy: ${file.destination}`);
  }
});