import { lstat, readFile, realpath, writeFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { dirname, resolve } from 'node:path';
import { build } from 'esbuild';

const directory = dirname(fileURLToPath(import.meta.url));
const outputPath = resolve(
  directory,
  '../Sources/TipTapSwift/Resources/RichTextEditor/tiptap-bundle.js',
);
const result = await build({
  entryPoints: [resolve(directory, 'src/editor.js')],
  bundle: true,
  minify: true,
  format: 'iife',
  globalName: 'TipTapEditor',
  platform: 'browser',
  outfile: outputPath,
  write: false,
});
const generated = result.outputFiles[0].contents;

if (process.argv.includes('--check')) {
  const committed = await readFile(outputPath);
  if (!committed.equals(generated)) {
    console.error('TipTap bundle differs from the locked source build. Run npm run build.');
    process.exitCode = 1;
  } else {
    console.log('TipTap bundle matches the locked source build.');
  }
} else {
  if ((await realpath(dirname(outputPath))) !== dirname(outputPath) ||
      (await lstat(outputPath)).isSymbolicLink()) {
    throw new Error(`Refusing to replace a symlinked bundle path: ${outputPath}`);
  }
  await writeFile(outputPath, generated);
  console.log(`Wrote ${outputPath}`);
}
