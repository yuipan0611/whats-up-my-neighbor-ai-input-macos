import { build } from 'esbuild';
import { mkdir, copyFile, readFile, writeFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const root = dirname(fileURLToPath(import.meta.url));
const source = join(root, 'node_modules/@novnc/novnc');
await mkdir(join(root, '../static'), { recursive: true });
await build({
  entryPoints: [join(root, 'entry.js')],
  outfile: join(root, '../static/novnc.js'),
  bundle: true, minify: true, format: 'esm', target: ['es2022'],
  legalComments: 'eof',
  banner: { js: '/* noVNC 1.7.0; MPL-2.0. Licenses: /browser/notices.txt. Source: https://github.com/novnc/noVNC/tree/v1.7.0 */' }
});
await copyFile(join(source, 'LICENSE.txt'), join(root, 'LICENSE.noVNC.txt'));
await copyFile(join(source, 'docs/LICENSE.MPL-2.0'), join(root, 'LICENSE.MPL-2.0'));
await copyFile(join(source, 'AUTHORS'), join(root, 'AUTHORS.noVNC'));
await copyFile(join(source, 'vendor/pako/LICENSE'), join(root, 'LICENSE.pako'));
const des = await readFile(join(source, 'core/crypto/des.js'), 'utf8');
await writeFile(join(root, 'LICENSE.des'), des.slice(0, des.indexOf('*/') + 2) + '\n');
const notices = ['noVNC 1.7.0: https://github.com/novnc/noVNC/tree/v1.7.0\n' +
  'Rebuildable, unmodified upstream source: https://registry.npmjs.org/@novnc/novnc/-/novnc-1.7.0.tgz\n' +
  'Only the Neko entrypoint disables logging; upstream source files are not modified.\n'];
for (const file of ['LICENSE.noVNC.txt', 'AUTHORS.noVNC', 'LICENSE.MPL-2.0', 'LICENSE.pako', 'LICENSE.des']) {
  notices.push(file + '\n\n' + await readFile(join(root, file), 'utf8'));
}
await writeFile(join(root, '../static/notices.txt'), notices.join('\n\n--------------------\n\n'));
