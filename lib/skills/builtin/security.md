---
name: security
description: Security analysis focused on common vulnerabilities (OWASP top 10 where applicable).
---
Realiza un analisis de seguridad del codigo en el directorio actual.

Pasos:
1. Usa `glob_files` y `grep_search` para mapear superficies de ataque:
   - Endpoints HTTP/API (rutas, controllers, middlewares).
   - Manejo de input externo (req.body, query, form, headers).
   - Acceso a filesystem / shell / SQL / templating.
   - Auth, sessions, tokens, secrets.
2. Lee los archivos identificados con `read_file`.
3. Reporta hallazgos por categoria:
   - Inyeccion (SQL, comando, template, NoSQL).
   - Autenticacion / autorizacion deficiente.
   - Exposicion de datos sensibles (logs con PII, secrets hardcoded, error messages verbose).
   - Configuracion insegura (CORS abierto, debug en prod, deps con CVEs conocidos).
   - SSRF / XXE / deserializacion insegura.
4. Por cada hallazgo: severidad (Critical / High / Medium / Low), archivo:linea, exploit potencial en 1 frase, mitigacion recomendada.

No inventes vulnerabilidades. Si no encuentras nada en una categoria, dilo.
