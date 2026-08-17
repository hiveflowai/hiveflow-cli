---
name: analyze
description: Full analysis of the project code in the current directory.
---
Realiza un analisis completo del proyecto en el directorio de trabajo actual.

Pasos:
1. Usa `glob_files` para mapear archivos principales. Evita `node_modules/`, `.git/`, `build/`, `dist/`, `target/`.
2. Identifica lenguaje, framework y forma del repo (mono-repo / multi-paquete / app simple) a partir de `package.json`, `pyproject.toml`, `go.mod`, `Cargo.toml` u otros manifests que existan.
3. Lee con `read_file` los archivos clave (README, manifest principal, entrypoint, configs visibles).
4. Si tienes que confirmar usos cross-file, usa `grep_search`.

Reporta en este orden:
- Resumen ejecutivo (1-3 frases).
- Stack tecnico detectado.
- Estructura del repo (arbol de alto nivel).
- Modulos/componentes principales con su responsabilidad.
- Calidad observable: tests presentes/ausentes, lint config, CI, docs.
- Hallazgos notables (deuda tecnica, codigo muerto, patrones inconsistentes).

No inventes contenido: si necesitas ver un archivo, leelo. Se conciso.
