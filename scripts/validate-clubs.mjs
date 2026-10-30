import { readdir, readFile } from 'node:fs/promises';
import { resolve, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const PAGE_SIZE = 200;
const EXPECTED_TOTAL = 30062;
const fail = message => { throw new Error(message); };
const integer = value => typeof value === 'number' && Number.isSafeInteger(value) ? value
  : typeof value === 'string' && /^\d+$/.test(value) && Number.isSafeInteger(Number(value)) ? Number(value) : NaN;

export async function validateDirectory(directory, expectedTotal = EXPECTED_TOTAL,
  expectedCourseSummaries = null, { collect = false } = {}) {
  const names = await readdir(directory);
  const pages = names.map(name => /^page-(\d+)\.json$/.exec(name)).filter(Boolean)
    .map(match => Number(match[1])).sort((a, b) => a - b);
  const expectedPages = Math.ceil(expectedTotal / PAGE_SIZE);
  if (pages.length !== expectedPages) fail(`Found ${pages.length} page files; expected ${expectedPages}.`);
  const ids = new Set();
  const allClubs = collect ? [] : null;
  let nestedCourses = 0;
  for (let index = 0; index < expectedPages; index++) {
    const page = index + 1;
    if (pages[index] !== page) fail(`Missing page ${page}.`);
    let body;
    try { body = JSON.parse(await readFile(join(directory, `page-${page}.json`), 'utf8')); }
    catch { fail(`Page ${page} is unreadable or invalid JSON.`); }
    const expectedCount = Math.min(PAGE_SIZE, expectedTotal - (page - 1) * PAGE_SIZE);
    if (!Array.isArray(body?.clubs) || integer(body.numAllClubs) !== expectedTotal
        || integer(body.numClubs) !== expectedCount || body.clubs.length !== expectedCount) {
      fail(`Page ${page} has inconsistent reported totals or page size.`);
    }
    for (const club of body.clubs) {
      const id = typeof club?.clubID === 'string' && club.clubID.length ? club.clubID
        : Number.isSafeInteger(club?.clubID) ? String(club.clubID) : null;
      if (!id || Buffer.byteLength(id) > 100 || ids.has(id)) fail(`Page ${page} has a missing, oversized or duplicate club ID.`);
      if (typeof club.clubName !== 'string' || !club.clubName || Buffer.byteLength(club.clubName) > 500
          || !Array.isArray(club.courses) || club.courses.length > 100) {
        fail(`Page ${page} contains malformed club summaries.`);
      }
      for (const course of club.courses) {
        const validCourseId = typeof course?.courseID === 'string' && course.courseID.length > 0
          || Number.isSafeInteger(course?.courseID);
        if (!course || !validCourseId
            || Buffer.byteLength(String(course.courseID)) > 100
            || typeof course.courseName !== 'string' || !course.courseName
            || Buffer.byteLength(course.courseName) > 500) {
          fail(`Page ${page} contains a malformed course summary.`);
        }
      }
      ids.add(id);
      nestedCourses += club.courses.length;
      if (allClubs) {
        allClubs.push({ ...club, clubID: id,
          courses: club.courses.map(course => ({ ...course, courseID: String(course.courseID) })) });
      }
    }
  }
  if (ids.size !== expectedTotal) fail(`Found ${ids.size} unique clubs; expected ${expectedTotal}.`);
  if (expectedCourseSummaries !== null && nestedCourses !== expectedCourseSummaries) {
    fail(`Found ${nestedCourses} nested course summaries; expected ${expectedCourseSummaries}.`);
  }
  return { complete: true, pages: expectedPages, clubs: ids.size,
    nestedCourseSummaries: nestedCourses, ...(allClubs ? { data: allClubs } : {}) };
}

async function main() {
  const args = process.argv.slice(2);
  if (args.length !== 2 || args[0] !== '--directory') {
    fail('Usage: node scripts/validate-clubs.mjs --directory <download-folder>');
  }
  const result = await validateDirectory(resolve(args[1]), EXPECTED_TOTAL, 44559);
  console.log(`Validated complete directory: ${result.clubs} unique clubs across ${result.pages} pages; ${result.nestedCourseSummaries} course summaries.`);
  console.log('Only aggregate counts are shown. No records are printed or uploaded.');
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main().catch(error => { console.error(error.message); process.exitCode = 1; });
}
