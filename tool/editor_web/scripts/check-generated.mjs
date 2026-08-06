import { execFile } from 'node:child_process';
import { mkdtemp, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { dirname, resolve } from 'node:path';
import { promisify } from 'node:util';
import { fileURLToPath } from 'node:url';

const execFileAsync = promisify(execFile);
const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const committed = resolve(root, '../../assets/editor_web');
const temporary = await mkdtemp(resolve(tmpdir(), 'synapse-editor-web-'));

try {
  await execFileAsync(process.execPath, [
    resolve(root, 'scripts/build.mjs'),
    `--outdir=${temporary}`,
  ]);
  for (const filename of ['index.html', 'editor.js']) {
    const expected = await readFile(resolve(committed, filename));
    const actual = await readFile(resolve(temporary, filename));
    if (!expected.equals(actual)) {
      throw new Error(
        `${filename} is stale. Run npm run build in tool/editor_web.`,
      );
    }
  }
} finally {
  await rm(temporary, { recursive: true, force: true });
}
