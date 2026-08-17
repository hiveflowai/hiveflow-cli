---
name: summary
description: Executive summary of the project in the current directory.
---
Genera un resumen ejecutivo del proyecto.

Pasos:
1. Lee README, manifest principal (`package.json` / equivalente), y los 2-3 archivos de entrada principales con `read_file` + `glob_files`.
2. Si el repo es git, corre `git log -1 --format=%cs` (via `bash_exec`) para conocer la fecha de la ultima actividad.

Reporta en este formato:
- **Nombre y proposito**: que hace el proyecto, en 1 frase.
- **Stack**: lenguajes, frameworks, runtime principal.
- **Estado**: madurez (POC / WIP / production), ultima actividad si la conoces.
- **Como se ejecuta**: comando(s) para correr / build / test.
- **Estructura**: 3-5 directorios top-level con su rol.
- **Riesgos visibles** (opcional, 1-3 bullets): deuda obvia, bloqueadores, dependencias delicadas.

Pensado para que alguien que llega al repo entienda en < 60 segundos que tiene en frente.
