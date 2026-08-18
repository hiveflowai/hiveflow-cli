---
name: think
description: Deep thinking about a technical topic of the project. Required args: the topic.
---
Razona en profundidad sobre: {{args}}

Reglas:
1. Si necesitas contexto del repo para razonar bien, leelo (`read_file`, `glob_files`, `grep_search`). No inventes hechos.
2. Estructura tu respuesta:
   - **Pregunta(s) que estas resolviendo**: re-articula el tema en 1-2 frases.
   - **Contexto relevante**: hechos del repo o conocimiento tecnico necesarios.
   - **Analisis**: razonamiento paso a paso, exploracion de alternativas, tradeoffs.
   - **Conclusion**: respuesta o recomendacion accionable con confianza calibrada.
3. Si el tema admite multiples enfoques, considera al menos 2 y comparalos explicitamente.
4. Si necesitas mas informacion del usuario para responder bien, pidela en lugar de inventar.

Se exhaustivo pero conciso: profundidad > longitud.
