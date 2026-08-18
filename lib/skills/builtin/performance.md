---
name: performance
description: Performance analysis: hot paths, algorithmic complexity, I/O and avoidable allocations.
---
Analiza el rendimiento del codigo en el directorio actual.

Pasos:
1. Identifica entrypoints y hot paths con `glob_files` + `grep_search` (loops anidados, llamadas sincronas a I/O, allocations en loops calientes, regex compiladas en loop).
2. Lee los archivos sospechosos con `read_file`.
3. Reporta:
   - Hot paths con complejidad >= O(n^2) reducible.
   - I/O bloqueante (sync filesystem / network) en codigo caliente.
   - N+1 queries / fetches.
   - Allocations en loops (string concat, array push, JSON parse repetido).
   - Cache ausente donde claramente serviria.
   - Falta de paginacion / streaming en endpoints que devuelven listas grandes.
4. Por cada hallazgo: archivo:linea, problema, impacto estimado (alto / medio / bajo), fix sugerido.

Distingue micro-optimizaciones (skip) de fixes con impacto real (report). No prematura-optimices.
