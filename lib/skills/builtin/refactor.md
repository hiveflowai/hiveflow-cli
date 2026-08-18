---
name: refactor
description: Refactoring proposals for a file or component. Optional args: path or target name.
---
Identifica y propone refactorizaciones para: {{args}}

Si `{{args}}` esta vacio, analiza el archivo mas critico del proyecto (entrypoint o modulo central).

Pasos:
1. `read_file` el target. Si la ruta es ambigua o es solo un nombre, usa `glob_files` primero.
2. Identifica oportunidades de refactor:
   - Funciones largas (> 50 lineas) o con > 1 responsabilidad.
   - Duplicacion de codigo (busca patrones similares con `grep_search`).
   - Nombres poco claros, abstracciones faltantes o sobreingenieria.
   - Manejo de errores inconsistente.
3. Para cada propuesta:
   - Cita el rango de lineas afectado.
   - Explica el problema en 1 frase.
   - Muestra el cambio sugerido con `edit_file` en `dry_run=true` para previsualizar.
4. NO apliques cambios sin confirmar primero con el usuario.

Prioriza cambios de alto impacto / bajo riesgo.
