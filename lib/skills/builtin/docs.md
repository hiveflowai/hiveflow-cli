---
name: docs
description: Generates or improves documentation (README, docstrings, comments where the WHY is not obvious).
---
Mejora la documentacion del proyecto en el directorio actual.

Pasos:
1. Detecta gaps:
   - Existe README y describe proposito, instalacion, uso?
   - Las funciones publicas de los modulos principales tienen docstrings?
   - Hay comentarios donde el WHY no es obvio del codigo?
2. Para cada gap relevante:
   - `read_file` el target.
   - Genera el bloque de documentacion al estilo del proyecto.
   - Usa `edit_file` con `dry_run=true` para previsualizar antes de aplicar.
3. Prioridades:
   - README sobre cualquier otra cosa si no existe o esta obsoleto.
   - Docstrings en API publica sobre comentarios internos.
   - Documentar el WHY (decisiones, restricciones, gotchas) sobre el WHAT (eso ya lo dice el codigo).

Evita comentarios que solo parafrasean el codigo. Evita docs que se volveran obsoletas (numeros de version, IDs de issues) salvo que sean load-bearing.
