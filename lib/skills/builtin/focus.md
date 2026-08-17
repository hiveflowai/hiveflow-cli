---
name: focus
description: Focuses the analysis on a specific file. Required args: path to the file.
---
Analiza en profundidad el archivo: {{args}}

Pasos:
1. Verifica que el archivo existe. Si la ruta es ambigua o es solo un nombre, usa `glob_files` para localizarlo.
2. Lee el archivo completo con `read_file`.
3. Reporta:
   - **Proposito**: que hace este archivo, en 1-2 frases.
   - **API publica**: funciones / clases / exports expuestos.
   - **Dependencias**: imports y archivos del proyecto de los que depende.
   - **Quien lo usa**: usa `grep_search` para encontrar callers en el resto del repo.
   - **Estructura interna**: principales bloques / secciones.
   - **Notas**: gotchas, deuda tecnica visible, TODOs.
4. Si el archivo es grande (> 1000 lineas), divide el reporte por seccion.

No resumas funciones triviales individualmente. Enfocate en lo que aporta valor entender.
