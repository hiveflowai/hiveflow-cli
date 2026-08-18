---
name: test
description: Generates automated tests for modules without coverage. Optional args: target file.
---
Genera tests automaticos para: {{args}}

Si `{{args}}` esta vacio, prioriza el modulo con menor cobertura aparente (sin archivo `*test*` adyacente).

Pasos:
1. Detecta el stack de testing del proyecto:
   - Lee manifest principal (`package.json` / `pyproject.toml` / `go.mod` / `Cargo.toml`) y configs (`jest.config`, `vitest.config`, `pytest.ini`, etc.) con `read_file`.
   - Si hay tests existentes, usa `glob_files` + `read_file` sobre 1-2 para inferir convenciones (naming, helpers, fixtures, estilo de asserts).
2. `read_file` el target a testear.
3. Genera tests que cubran:
   - Happy path principal.
   - Edge cases (entrada vacia, null, valores limite).
   - Manejo de errores conocidos.
4. Escribe los tests con `write_file` en el path convencional del proyecto. NO inventes un path nuevo si ya hay convencion.
5. Reporta el comando para ejecutarlos.

No tests-by-convention sin proposito (e.g., `expect(true).toBe(true)`). Cada test debe asertar algo que pudiera fallar.
