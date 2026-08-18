---
name: files
description: Lists the relevant project files (excludes build artifacts and deps).
---
Lista los archivos principales del proyecto en el directorio actual.

Pasos:
1. Usa `glob_files` para encontrar archivos de codigo fuente. `node_modules/`, `.git/`, `dist/`, `build/`, `target/`, `__pycache__/` deben quedar fuera (el tool ya excluye `.git/`; el resto evitalos via `path=` o filtrando manualmente la salida).
2. Selecciona extensiones segun el manifest detectado:
   - `package.json` -> `*.js`, `*.ts`, `*.tsx`, `*.jsx`.
   - `go.mod` -> `*.go`.
   - `Cargo.toml` -> `*.rs`.
   - `pyproject.toml` / `requirements.txt` -> `*.py`.
   - Default: `*.sh`, `*.md`, `*.json`, `*.yaml`, `*.toml`.
3. Agrupa la salida por directorio top-level.
4. Indica el total de archivos. Si sospechas de outliers en tamano, corre `wc -l` via `bash_exec` sobre los candidatos.

Output limpio, paths relativos al cwd.
