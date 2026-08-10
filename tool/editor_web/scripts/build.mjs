import { build } from 'esbuild';
import { createHash } from 'node:crypto';
import { mkdir, readFile, rm, writeFile } from 'node:fs/promises';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const outdirArgument = process.argv.find((argument) => argument.startsWith('--outdir='));
const output = outdirArgument
  ? resolve(root, outdirArgument.slice('--outdir='.length))
  : resolve(root, '../../assets/editor_web');

await rm(output, { recursive: true, force: true });
await mkdir(output, { recursive: true });

await build({
  entryPoints: [resolve(root, 'src/editor.ts')],
  outfile: resolve(output, 'editor.js'),
  bundle: true,
  minify: true,
  sourcemap: false,
  format: 'iife',
  target: ['safari15'],
  legalComments: 'none',
});

const editor = await readFile(resolve(output, 'editor.js'));
const editorHash = createHash('sha256')
  .update(editor)
  .digest('hex')
  .slice(0, 16);
const indexTemplate = await readFile(
  resolve(root, 'src/index.html'),
  'utf8',
);
const hashPlaceholder = '__SYNAPSE_EDITOR_HASH__';
if (!indexTemplate.includes(hashPlaceholder)) {
  throw new Error(`Missing ${hashPlaceholder} in src/index.html`);
}
await writeFile(
  resolve(output, 'index.html'),
  indexTemplate.replaceAll(hashPlaceholder, editorHash),
);
