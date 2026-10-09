---
name: carrusel
description: Renders an HTML carousel (one .slide element per slide) to JPG/PNG images plus a PDF and hands them back with HF_SEND. Installs Playwright + Chromium on first use (macOS, Linux, Windows).
---
Renderiza un carrusel HTML a imágenes (una por cada elemento `.slide`) y un PDF para LinkedIn, y entrega los archivos.

Entrada (en la tarea): el HTML completo del carrusel (pegado, una ruta local o una URL), y opcionalmente:
- `slug`: nombre corto del carrusel (default `carrusel`).
- `formato`: `jpg` (default; TikTok exige JPG) o `png`.
Cada slide es un elemento con clase `slide` de 1080×1350 px. Fuentes por Google Fonts o @font-face; imágenes con URL absoluta o data URI.

Pasos:
1. Carpeta de trabajo: `~/.hiveflow/carrusel` (créala si falta). Ahí viven `package.json`, `render.mjs` y `node_modules`.
2. Dependencias (solo la primera vez; verifica antes de instalar):
   - Node 18+: `node -v`. Si falta: macOS `brew install node`, Debian/Ubuntu `sudo apt-get install -y nodejs npm`, Windows `winget install OpenJS.NodeJS.LTS`.
   - Playwright en la carpeta: si no existe `~/.hiveflow/carrusel/node_modules/playwright`, corre ahí `npm init -y >/dev/null && npm install playwright@1`.
   - Chromium: `npx playwright install chromium` (en Linux, si falla por librerías: `npx playwright install --with-deps chromium`).
3. Si no existe `~/.hiveflow/carrusel/render.mjs`, escríbelo con write_file EXACTAMENTE así:
```js
import { chromium } from 'playwright';
import fs from 'node:fs';
import path from 'node:path';
import { pathToFileURL } from 'node:url';

const [, , input, outDir, fmt = 'jpg'] = process.argv;
if (!input || !outDir) { console.error('uso: node render.mjs <html|url> <outDir> [jpg|png]'); process.exit(2); }
const ext = fmt === 'png' ? 'png' : 'jpg';
fs.mkdirSync(outDir, { recursive: true });

const browser = await chromium.launch();
const page = await browser.newPage({ viewport: { width: 1080, height: 1350 }, deviceScaleFactor: 1 });
const url = /^https?:\/\//.test(input) ? input : pathToFileURL(path.resolve(input)).href;
await page.goto(url, { waitUntil: 'networkidle' });
await page.evaluate(() => document.fonts.ready);

const slides = await page.$$('.slide');
if (!slides.length) { console.error('No hay elementos .slide en el HTML'); process.exit(1); }
const files = [];
for (let i = 0; i < slides.length; i++) {
  const f = path.resolve(outDir, `slide-${String(i + 1).padStart(2, '0')}.${ext}`);
  await slides[i].screenshot(ext === 'png' ? { path: f, type: 'png' } : { path: f, type: 'jpeg', quality: 92 });
  files.push(f);
}

// PDF para LinkedIn: una página por slide, armado con las mismas imágenes
const mime = ext === 'png' ? 'image/png' : 'image/jpeg';
const pages = files.map((f) => `<div class="p"><img src="data:${mime};base64,${fs.readFileSync(f).toString('base64')}"></div>`).join('');
const pdfPage = await browser.newPage();
await pdfPage.setContent(`<style>@page{size:1080px 1350px;margin:0}body{margin:0}.p{width:1080px;height:1350px;break-after:page}.p img{width:100%;height:100%;display:block}</style>${pages}`);
const pdf = path.resolve(outDir, `${path.basename(outDir)}.pdf`);
await pdfPage.pdf({ path: pdf, width: '1080px', height: '1350px', printBackground: true });

await browser.close();
for (const f of [...files, pdf]) console.log(`HF_SEND: ${f}`);
```
4. Si la ruta está dentro de un repo git (p. ej. `~/Code/hiveflow/hiveflow-docs/...`), primero actualízalo: `git -C <raíz del repo> pull --ff-only` (si falla por cambios locales, dilo y renderiza lo que hay). Si el HTML viene pegado en la tarea, guárdalo tal cual en `~/hiveflow-carruseles/<slug>-<AAAAMMDD-HHMM>/index.html`. Si es ruta o URL, úsala directo.
5. Renderiza: `cd ~/.hiveflow/carrusel && node render.mjs "<index.html o URL>" "~/hiveflow-carruseles/<slug>-<AAAAMMDD-HHMM>" <formato>` (expande `~` a la ruta absoluta).
6. Revisa la salida: debe haber tantas imágenes como slides y un PDF. Si una fuente no cargó o un slide salió vacío, dilo en el resultado.

Resultado: número de slides y carpeta de salida. Tu respuesta DEBE terminar con las líneas `HF_SEND: /ruta/absoluta` que imprimió el script (una por imagen y una del PDF), copiadas tal cual, cada una en su propia línea y sin formato markdown. Sin esas líneas los archivos NO se entregan.
Nota: con líneas HF_SEND el puente manda hasta 30 archivos por respuesta (`HF_RC_MAX_FILES_MARKED`).
