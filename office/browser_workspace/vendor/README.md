# Reproducible noVNC bundle

Runtime serves the committed `../static/novnc.js`; it needs no Node process,
external CDN, websockify service, or npm download when a user opens the viewer.

```sh
cd office/browser_workspace/vendor
npm ci --ignore-scripts --no-audit --no-fund
npm run build
git diff --exit-code -- ../static/novnc.js ../static/notices.txt
```

`package-lock.json` fixes noVNC 1.7.0, esbuild 0.25.11 and their npm integrity
hashes. `entry.js` disables logging before the application creates an RFB
instance. Upstream source files are unmodified. ES2022 browser support is
required because noVNC 1.7.0 uses top-level await.

noVNC core is MPL-2.0; pako is MIT; DES carries its own attribution/conditions.
Full notices, source links and authors are copied from the pinned npm package
and served at `/browser/notices.txt`. TigerVNC and Xvfb remain separate distro
executables, not copied into this JavaScript bundle. See their package notices
and source packages when distributing a container image.
