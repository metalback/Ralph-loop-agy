# Product Requirement Document (PRD)
## Proyecto: Implementación de Ralph Loop con Antigravity CLI (agy)
## 1. Introducción y Objetivos
### 1.1 Propósito del Documento
Este documento define los requerimientos técnicos y funcionales para el diseño y construcción de un entorno de ingeniería agéntica autónomo basado en el patrón **Ralph Loop**. El sistema utilizará **Antigravity CLI (agy)** como motor agéntico central (Harness Core) alimentado por **Google Gemini Pro**, y operará de manera desatendida dentro de un entorno aislado para resolver tareas de software complejas.
### 1.2 Objetivos Principales
 * **Autonomía Completa (*Hands-Off*):** Permitir que la IA itere de forma desatendida resolviendo errores de código hasta cumplir con criterios de éxito deterministas.
 * **Preservación de Contexto Limpio:** Mitigar la degradación del modelo mediante el reinicio de la ventana de contexto en cada iteración, delegando la memoria a largo plazo a archivos físicos en el disco del host.
 * **Seguridad Operacional:** Garantizar el aislamiento absoluto del código generado mediante contenedores, protegiendo las credenciales OAuth de Google Pro contra filtraciones o corrupción.
## 2. Arquitectura de la Solución y Flujo de Datos
El sistema se compone de tres capas desacopladas: la **Capa de Control** (Orquestador Bash/Python), la **Capa Agéntica** (agy encapsulado en Docker) y la **Capa de Validación** (Suite de pruebas y linters locales).
```
[ Host Workspace: Código, tasks.md, progress.txt ]
       │
       ├── (Montaje de Volumenes RO/RW)
       ▼
┌────────────────────────────────────────────────────────┐
│ Docker Sandbox (Aislamiento Total)                      │
│                                                        │
│  1. Orquestador lee progress.txt y actualiza contexto  │
│  2. Invocación Atómica: agy /ralph-worker             │
│  3. agy modifica el código fuente                      │
│  4. Validación Ejecutada (Linter / Test Runner)        │
│                                                        │
└────────────────────────────────────────────────────────┘
       │
       ├── Pasa Tests ───► [Git Commit & Cierre del Loop]
       │
       └── Falla ────────► [Escribe Logs en progress.txt] ──► (Siguiente Iteración)

```
## 3. Requerimientos Funcionales (RF)
### RF-1: Gestión Desacoplada del Estado (Memory offloading)
 * **RF-1.1:** El sistema **no** debe mantener el historial de la sesión de chat entre iteraciones de ejecución. Cada llamada a agy debe ser un inicio limpio (/clear).
 * **RF-1.2:** Se mantendrán dos archivos de texto plano en la raíz del espacio de trabajo del host que actuarán como la única fuente de verdad:
   * tasks.md: El backlog técnico con los requerimientos de la tarea origen.
   * progress.txt: Registro acumulativo de intentos, hipótesis fallidas y errores de compilación anteriores.
### RF-2: Orquestación del Ciclo de Vida del Agente
 * **RF-2.1:** El orquestador debe automatizar la ejecución de agy utilizando el parámetro --non-interactive (o equivalente) para evitar bloqueos por prompts de terminal.
 * **RF-2.2:** Antes de cada iteración, el orquestador inyectará el contenido de progress.txt y tasks.md en el contexto inmediato del agente a través de una **Skill** de Antigravity preconfigurada.
### RF-3: Validación Determinista Externa
 * **RF-3.1:** El éxito de la tarea será determinado exclusivamente por herramientas de análisis estático y dinámico del entorno (ej. pytest, npm test, golangci-lint), nunca por criterio del propio LLM.
 * **RF-3.2:** Si la suite de pruebas falla, el script capturará las últimas 20 líneas del output estándar de error (stderr) y las apendizará al archivo progress.txt antes de iniciar la siguiente iteración.
## 4. Requerimientos No Funcionales (RNF)
### RNF-1: Seguridad y Aislamiento (Sandboxing)
 * **RNF-1.1:** Toda la ejecución de comandos generados por la IA y la ejecución de pruebas se realizará dentro de un contenedor **Docker** aislado.
 * **RNF-1.2:** Los archivos de configuración que contienen las credenciales OAuth de Google Pro se montarán desde el host hacia el contenedor en modo **Solo Lectura (:ro)**. El contenedor no tendrá permisos para reescribir ni exportar estas credenciales fuera de la comunicación SSL nativa con la API de Google.
### RNF-2: Circuito Cerrado de Emergencia (*Circuit Breaker*)
 * **RNF-2.1:** Para evitar el consumo excesivo de la cuota de la API de Google Pro y la generación de bucles infinitos por bugs lógicos, el orquestador implementará un límite estricto de **10 iteraciones máximas** por tarea.
 * **RNF-2.2:** Se configurará un retraso obligatorio (*cool down*) de **5 segundos** entre iteraciones para mitigar bloqueos temporales por políticas de *Rate Limiting* (Errores HTTP 429) de la API de Google.
### RNF-3: Estabilidad de Sesión OAuth
 * **RNF-3.1:** El entorno debe soportar la persistencia de los *Refresh Tokens* obtenidos en el host. En caso de entornos remotos (CI/CD), el orquestador debe proveer el mecanismo *OAuth Device Flow* exponiendo el código de verificación de 8 dígitos en los logs de salida estandarizados.
## 5. Criterios de Aceptación Técnicos
| ID | Escenario | Comportamiento Esperado |
|---|---|---|
| **CA-01** | Inicio de tarea con errores previos | agy lee el archivo progress.txt, identifica que la solución anterior falló por un problema de tipos de datos, y propone una alternativa modificando el código sin repetir el error previo. |
| **CA-02** | Validación exitosa de código | El linter y los tests unitarios retornan Exit Code: 0. El orquestador detiene inmediatamente el bucle, ejecuta un git commit automático y limpia los archivos temporales. |
| **CA-03** | Activación del *Circuit Breaker* | Tras 10 intentos fallidos continuos, el orquestador rompe el flujo, preserva el archivo progress.txt intacto para análisis humano y retorna un código de salida 1. |
| **CA-04** | Integridad de credenciales | Si el agente intenta realizar una acción de escritura o alteración sobre el directorio .config/antigravity-cli, el sistema operativo del contenedor bloquea la operación (Read-only file system) y los tokens del host permanecen intactos. |
## 6. Plan de Implementación por Fases
 1. **Fase 1 (Configuración del Host):** Autenticación de agy con la cuenta de Google Pro de forma interactiva y verificación de la correcta creación del directorio de configuración local.
 2. **Fase 2 (Construcción del Sandbox):** Creación del Dockerfile base que incluya el binario de agy, las herramientas de testing del proyecto y la Skill ralph-worker.md.
 3. **Fase 3 (Scripting del Orquestador):** Desarrollo del script de control (ralph_runner.sh) con lógica de lectura/escritura de logs y manejo del *Circuit Breaker*.
 4. **Fase 4 (Pruebas de Estrés):** Inyección controlada de un bug complejo en un entorno de desarrollo para validar que el agente itera y soluciona el problema de manera autónoma en menos de 5 iteraciones.
