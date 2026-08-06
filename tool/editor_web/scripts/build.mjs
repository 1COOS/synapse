import { build } from 'esbuild';
import { cp, mkdir, rm } from 'node:fs/promises';
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

await cp(resolve(root, 'src/index.html'), resolve(output, 'index.html'));
