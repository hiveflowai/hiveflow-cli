---
name: fix
description: Fixes a specific problem described by the user. Required args: problem description.
---
Arregla este problema: {{args}}

Workflow:
1. **Reproduce** el problema:
   - Si es un error de runtime, usa `bash_exec` para correr el comando que falla y captura el error real.
   - Si es un bug observable en codigo, identifica el archivo afectado con `glob_files` + `grep_search`.
2. **Diagnostica**:
   - `read_file` los archivos relevantes.
   - Identifica la causa raiz, no solo el sintoma.
3. **Propon la solucion**:
   - Explica la causa en 1-2 frases.
   - Muestra el diff con `edit_file` en `dry_run=true`.
4. **Aplica** el fix con `edit_file` (sin `dry_run`) o `write_file` segun corresponda. El permission system pedira confirmacion si no esta allowlisted.
5. **Verifica**: corre tests o repro-command para confirmar que el fix funciona.

Si el problema es ambiguo o falta info, PREGUNTA antes de actuar. Si la causa raiz esta fuera del scope del directorio actual, dilo.
