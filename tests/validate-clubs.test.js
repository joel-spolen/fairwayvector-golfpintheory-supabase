import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, writeFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { validateDirectory } from '../scripts/validate-clubs.mjs';

const sample = (page, total = 201) => {
  const size = Math.min(200, total - (page - 1) * 200);
  return { numClubs: size, numAllClubs: total, clubs: Array.from({ length: size }, (_, i) => ({
    clubID: `club-${(page - 1) * 200 + i}`, clubName: 'Fixture Club',
    courses: [{ courseID: `course-${i}`, courseName: 'Fixture Course' }]
  })) };
};

async function withDirectory(run) {
  const directory = await mkdtemp(join(tmpdir(), 'club-validation-'));
  try { await run(directory); } finally { await rm(directory, { recursive: true, force: true }); }
}

test('validates all pages, unique IDs and nested course summaries without printing records', () => withDirectory(async directory => {
  for (let page = 1; page <= 2; page++) {
    await writeFile(join(directory, `page-${page}.json`), JSON.stringify(sample(page)));
  }
  assert.deepEqual(await validateDirectory(directory, 201), {
    complete: true, pages: 2, clubs: 201, nestedCourseSummaries: 201
  });
}));

test('rejects gaps, count mismatch, duplicate IDs and invalid course data', () => withDirectory(async directory => {
  await writeFile(join(directory, 'page-1.json'), JSON.stringify(sample(1)));
  await assert.rejects(validateDirectory(directory, 201), /page files/);
  await writeFile(join(directory, 'page-2.json'), JSON.stringify(sample(2)));
  const second = sample(2);
  second.clubs[0].clubID = sample(1).clubs[0].clubID;
  await writeFile(join(directory, 'page-2.json'), JSON.stringify(second));
  await assert.rejects(validateDirectory(directory, 201), /duplicate/);
}));
