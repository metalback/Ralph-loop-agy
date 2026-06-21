# PRD: Ralph Loop con Antigravity CLI (agy)

## Problem Statement

Desarrollar un entorno de ingeniería agéntica autónomo *(hands-off)* que permite a una IA iterar sobre un problema de código de forma desatendida, resolviendo bugs y fallos de validación sin intervención humana. El sistema debe:

- Operar un bucle autónomo donde un agente IA (agy + Gemini 3.5 Flash) intenta resolver un problema, se valida contra tests, y si falla, itera con el contexto de errores previos.
- Ser agnóstico al stack tecnológico — funcionar con cualquier proyecto que tenga un comando de validación (test/lint).
- Preservar el contexto entre iteraciones sin depender de la ventana de contexto del LLM, usando archivos de texto plano como memoria externa.
- Garantizar aislamiento mediante Docker para proteger credenciales y sistema host.

## Solution

Un **orquestador Bash** (`ralph_runner.sh`) que:
1. Lee un `PRD.md` con la definición de la tarea y extrae el comando de validación.
2. Levanta un contenedor Docker con agy autenticado, montando el código del proyecto en RW y las credenciales de agy en RO.
3. Inyecta el PRD + historial de intentos (`progress.log`) en agy vía una skill `ralph-worker.md`.
4. agy intenta resolver el problema y corre los tests.
5. Si los tests pasan (exit 0) → commit a una branch feature, merge a la rama base al final.
6. Si fallan → captura stderr, escribe en `progress.log`, espera 15s, y repite.
7. Circuit breaker: máximo 10 iteraciones. Si se agotan, preserva `progress.log` para análisis humano y termina con exit 1.

## User Stories

1. Como desarrollador, quiero definir una tarea en un PRD.md, para que el loop sepa qué problema resolver.
2. Como desarrollador, quiero que el loop ejecute agy automáticamente dentro de un contenedor Docker, para no exponer mi sistema host a código generado por IA.
3. Como desarrollador, quiero que el loop inyecte el contexto de la tarea (PRD) y el historial de intentos fallidos a agy en cada iteración, para que el agente no repita errores previos.
4. Como desarrollador, quiero que el loop valide el código modificado contra un comando de test/lint, para determinar éxito/fracaso de forma determinista.
5. Como desarrollador, quiero que el loop haga auto-commit a una branch feature cuando los tests pasan, para mantener trazabilidad del trabajo del agente.
6. Como desarrollador, quiero que al final de todas las tareas, las branches se fusionen automáticamente a la rama base, para integrar el trabajo completo.
7. Como desarrollador, quiero que el loop tenga un circuit breaker de 10 iteraciones máximas con cooldown de 15s, para evitar bucles infinitos y consumo excesivo de API.
8. Como desarrollador, quiero que las credenciales de agy se monten en solo lectura dentro del contenedor, para proteger los tokens OAuth contra filtraciones.
9. Como desarrollador, quiero que el loop sea agnóstico al stack del proyecto, para usarlo con proyectos Node, Python, Go, Rust, etc.
10. Como desarrollador, quiero que el loop cree una imagen Docker base liviana sobre la marcha, para minimizar tiempos de descarga y arranque.

## Implementation Decisions

### Módulos a construir

**1. `ralph_runner.sh`** — Orquestador principal (Bash)
- Lee PRD.md y extrae `TEST_CMD`, `PRD_BODY`, `BASE_BRANCH`
- Detecta si se necesita construir imagen Docker o usar una existente
- Monta contenedor con:
  - `$PWD:/workspace:cached,rw`
  - `~/.config/antigravity-cli:/home/agent/.config/antigravity-cli:ro`
  - Variables de entorno: `MODEL`, `MAX_ITERATIONS`, `COOLDOWN`
- Loop principal:
  - Inyecta contexto: concatena PRD.md + progress.log
  - Ejecuta `agy --non-interactive --load-skill ralph-worker`
  - Captura stdout/stderr
  - Si agy produjo cambios → corre `TEST_CMD`
  - Exit 0 → commit + branch
  - Exit != 0 → apendiza stderr a progress.log → cooldown → itera
  - Si llega a MAX_ITERATIONS → exit 1 con progress.log intacto

**2. `ralph-worker.md`** — Skill de Antigravity
- Template con instrucciones para el agente:
  - "Eres un ingeniero de software autónomo. Tu tarea está definida en el texto a continuación."
  - "Lee el historial de intentos previos y NO repitas los mismos errores."
  - "Modifica el código necesario para resolver la tarea."
  - "Ejecuta el comando de validación especificado."
  - "Si los tests fallan, analiza el error, propón una solución diferente e infórmala."
  - "Si los tests pasan, confirma el éxito."

**3. `Dockerfile`** — Imagen base minimal
- `FROM node:22-alpine`
- Instalar: git, curl, jq, gh CLI, agy (npm global)
- `~350MB` en vez de 2.4GB
- USER agent con UID/GID dinámicos (build-args)

**4. `progress.log`** — Memoria externa del loop
- Archivo de texto plano, acumulativo
- Cada entrada: timestamp + iteración + error capturado
- Formato: `[2026-06-21 08:00] Iteración 3 | stderr: ...`

**5. `.env`** — Configuración
- `MODEL="gemini-3.5-flash-medium"`
- `MAX_ITERATIONS=10`
- `COOLDOWN_SECONDS=15`
- `OPENCODE_BASE_URL=https://opencode.ai/zen/go/v1`
- `OPENCODE_API_KEY=...`
- `GH_TOKEN=...`

### Decisiones de arquitectura

- El orquestador corre **en el host**, no dentro del contenedor. Solo agy se ejecuta dentro del sandbox Docker.
- El comando de test se infiere del PRD. Si el PRD no especifica `TEST_CMD` explícitamente, el loop puede detectar archivos de configuración (`package.json`, `go.mod`, `Cargo.toml`, `requirements.txt`) para sugerir uno.
- La imagen Docker se construye bajo demanda con `docker build -t ralph-loop-base .sandcastle/Dockerfile`.
- El primero de los `MAX_ITERATIONS` intentos no lleva `progress.log` (está vacío o no existe).
- El auto-commit usa prefijo `RALPH:` en el mensaje, incluyendo número de iteración y resumen de cambios.
- No hay soporte CI/CD en esta versión. Solo desarrollo local con TTY disponible.

## Testing Decisions

- El testing del loop mismo se hace con un **proyecto de prueba** que tenga un bug conocido y un test que falle.
- Se valida que el loop complete en ≤ 5 iteraciones para bugs simples.
- Se valida que el circuit breaker se active después de 10 iteraciones y preserve progress.log.
- Se valida que las credenciales montadas en :ro no puedan ser modificadas desde el contenedor.
- No se escriben tests unitarios para el orquestador Bash — se prueba end-to-end con proyectos reales.

## Out of Scope

- CI/CD support (GitHub Actions, etc.)
- Interfaz gráfica o TUI más allá de agy
- Múltiples tareas en paralelo (una a la vez)
- Planificación automática de tareas (depende del usuario escribir el PRD)
- Code review humano del output del agente
- Soporte para múltiples modelos Gemini en runtime (fijo en .env)

## Further Notes

- agy v1.0.8 debe estar autenticado con Google antes de ejecutar el loop (`agy auth login`)
- El Docker build se ejecuta una sola vez (o cuando se cambie el Dockerfile), no por tarea
- El archivo `progress.log` **no se hace commit** — debe estar en `.gitignore`
- Compatible con el flujo Sandcastle: este loop resuelve issues individuales; Sandcastle puede usarse para planificar y orquestar múltiples issues
