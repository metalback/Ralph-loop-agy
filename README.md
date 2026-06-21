# Ralph Loop — Autonomous Engineering Loop with Antigravity CLI (agy)

[![PRD](https://img.shields.io/badge/PRD-%231-blue)](https://github.com/metalback/Ralph-loop-agy/issues/1)

**Ralph Loop** es un bucle autónomo de ingeniería de software. Dado un PRD con una tarea y un comando de validación, el loop itera de forma desatendida hasta que el código pasa los tests o se alcanza el límite de iteraciones.

Usa [Antigravity CLI (agy)](https://github.com/antigravity-ai/antigravity) con **Google Gemini** como motor agéntico, ejecutándose dentro de un contenedor Docker aislado.

---

## Requisitos

- **Docker**
- **Node.js 22+** (para instalar agy si no lo tienes)
- **agy v1.0.8** autenticado con Google
- **gh CLI** (opcional, para close automático de issues)

## Instalación

```bash
# 1. Clonar el repo
git clone git@github.com:metalback/Ralph-loop-agy.git
cd Ralph-loop-agy

# 2. Autenticar agy (si no lo has hecho)
agy auth login

# 3. Construir la imagen Docker base
docker build -t ralph-loop-base -f .sandcastle/Dockerfile .
```

## Uso

### Preparar una tarea

Crea o edita `PRD.md` en la raíz del proyecto. Debe incluir:

```markdown
# PRD: Título de la tarea

## Task

Descripción clara del problema a resolver.

## Validation

TEST_CMD: npm test
```

El loop extrae `TEST_CMD:` del PRD para saber qué comando ejecutar como validación. Si el PRD no especifica `TEST_CMD`, el loop intenta detectar el stack automáticamente (`package.json` → `npm test`, `go.mod` → `go test ./...`, etc.).

### Ejecutar el loop

```bash
./ralph_runner.sh
```

El loop:

1. Lee `PRD.md` y extrae `TEST_CMD`
2. Inyecta el PRD + historial de intentos (`progress.log`) en agy
3. agy modifica el código dentro del contenedor Docker
4. Ejecuta el comando de validación
5. Si pasa → **commit automático** a branch `ralph/issue-{id}-{slug}` y merge a la rama base
6. Si falla → escribe el error en `progress.log`, espera 15s, y lo intenta de nuevo
7. **Circuit breaker**: máximo 10 iteraciones. Si se agotan, preserva `progress.log` y termina con error.

### Configuración

Todo es configurable vía variables de entorno o archivo `.env`:

| Variable | Default | Descripción |
|---|---|---|
| `MAX_ITERATIONS` | `10` | Máximo de iteraciones por tarea |
| `COOLDOWN_SECONDS` | `15` | Segundos entre iteraciones |
| `IMAGE_NAME` | `ralph-loop-base` | Nombre de la imagen Docker |
| `DOCKERFILE` | `.sandcastle/Dockerfile` | Path al Dockerfile |
| `PRD_FILE` | `PRD.md` | Path al PRD de la tarea |
| `MODEL` | *(lo que tenga agy configurado)* | Modelo Gemini a usar |

### Proyecto de prueba

```bash
# Ir al proyecto de prueba
cd test/fixtures/sample-bug-project

# Copiar el PRD a la raíz
cp PRD.md ../../PRD.md

# Ejecutar el loop desde la raíz del repo
cd ../..
./ralph_runner.sh
```

## Estructura del proyecto

```
Ralph-loop-agy/
├── ralph_runner.sh          ← Orquestador principal (Bash)
├── ralph-worker.md          ← Skill de agy
├── PRD.md                   ← Tarea actual (input)
├── progress.log             ← Historial de iteraciones (se crea automáticamente)
├── .env                     ← Configuración (opcional, ignorado por git)
├── .sandcastle/
│   └── Dockerfile           ← Imagen base (Alpine + agy + gh + git)
└── test/fixtures/
    ├── sample-bug-project/  ← Proyecto de ejemplo con bug real
    ├── e2e-harness.sh       ← Harness de tests E2E
    └── agents/              ← Mocks para tests
```

## Flujo de trabajo con Sandcastle

Este repo incluye también [Sandcastle](https://github.com/ai-hero/sandcastle) para planificar y orquestar múltiples issues en paralelo. Para usarlo:

```bash
npm run sandcastle
```

Crea issues con label `Sandcastle` en GitHub y el orquestador los planifica, implementa, revisa y mergea automáticamente.

## Safety

- Las credenciales de agy (`~/.config/antigravity-cli`) se montan en **solo lectura** dentro del contenedor
- El código del proyecto se monta en **lectura/escritura** para que agy pueda modificarlo
- El contenedor está aislado: no afecta al sistema host
- `progress.log` está en `.gitignore` — nunca se sube al repo

## Licencia

MIT
