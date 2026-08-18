---
name: review
description: PR-style code review of the current changes or a specific target.
---
Revisa el codigo como un revisor experto haria sobre un PR.

Pasos:
1. Detecta el scope:
   - Si el repo es git, corre `git status` y `git diff` (via `bash_exec`) para identificar cambios pendientes.
   - Si no hay cambios o el repo no es git, revisa los archivos principales (`glob_files` + `read_file`).
2. Para cada hallazgo reporta:
   - Severidad: `BLOCKER` / `MAJOR` / `MINOR` / `NIT`.
   - Archivo:linea afectada.
   - Descripcion concisa del problema.
   - Sugerencia accionable.
3. Cubre estas dimensiones:
   - Correctness (bugs, edge cases).
   - Seguridad superficial (input validation, SQL/cmd injection obvia, secrets leak).
   - Legibilidad (naming, comentarios necesarios, complejidad).
   - Tests (cobertura del nuevo codigo).
   - Convenciones del proyecto (consistencia con el codigo existente).

Cierra con un veredicto: APPROVE / REQUEST_CHANGES / COMMENT.
