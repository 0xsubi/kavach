// Assembles the loadable unpacked Chrome extension in dist/: builds the
// Flutter web popup with the two flags an extension-hosted page actually
// needs (see below), bundles the TS shell with esbuild, and copies the
// manifest + icons + popup build together.
import { build } from 'esbuild';
import { cpSync, existsSync, mkdirSync, rmSync, copyFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { execFileSync } from 'node:child_process';
import path from 'node:path';

const root = path.dirname(fileURLToPath(import.meta.url));
const distDir = path.join(root, 'dist');
const popupDir = path.join(root, '..', 'flutter_popup');
const popupBuildDir = path.join(popupDir, 'build', 'web');

console.log('Building Flutter web popup...');
execFileSync(
  'flutter',
  [
    'build',
    'web',
    // Default Flutter web fetches the CanvasKit renderer from
    // www.gstatic.com — blocked by an extension page's default CSP
    // (script-src 'self'), which renders as a silent blank page with no
    // build-time error. Bundle it locally instead.
    '--no-web-resources-cdn',
    // Default <base href="/"> resolves every relative asset path against
    // the extension root, not popup/ where this build actually lands —
    // also a silent blank page (every asset 404s). Must match the
    // "popup/" path this script copies the build output into below.
    '--base-href=/popup/',
  ],
  { cwd: popupDir, stdio: 'inherit' },
);

rmSync(distDir, { recursive: true, force: true });
mkdirSync(distDir, { recursive: true });

await build({
  entryPoints: [
    path.join(root, 'src', 'background', 'service-worker.ts'),
    path.join(root, 'src', 'content', 'detect-forms.ts'),
  ],
  outdir: distDir,
  outbase: path.join(root, 'src'),
  bundle: true,
  format: 'esm',
  target: 'chrome120',
  sourcemap: true,
});

copyFileSync(path.join(root, 'manifest.chrome.json'), path.join(distDir, 'manifest.json'));
cpSync(path.join(root, 'icons'), path.join(distDir, 'icons'), { recursive: true });

if (!existsSync(popupBuildDir)) {
  throw new Error(`Flutter build did not produce ${popupBuildDir} — check the build output above for errors.`);
}
cpSync(popupBuildDir, path.join(distDir, 'popup'), { recursive: true });

console.log(`Built unpacked extension at ${distDir}`);
