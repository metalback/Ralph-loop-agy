# Coding Standards — Ralph Loop (Google ADK)

## Stack

- **Runtime**: Bun o Node.js 22+
- **Language**: TypeScript estricto (strict mode), evitar `any`
- **Agent Engine**: Antigravity CLI (agy) v1.0.8
- **AI Model**: Google Gemini Pro (via agy)
- **Package manager**: npm o bun

## Style

- TypeScript estricto, `strict: true` en tsconfig
- Preferir named exports sobre default exports
- Nombres de archivos en kebab-case (e.g., `ralph-loop.ts`)
- Funciones y variables en camelCase
- Constantes y variables de entorno en UPPER_SNAKE_CASE
- Componentes TUI funcionales, sin clases
- Tests junto al código: `*.test.ts`

## Testing

- Tests para toda la lógica de negocio
- Usar Vitest o Bun test
- Probar comportamiento externo, no implementación interna
- Tests descriptivos con `describe` / `it`

## Commits

- Prefijo `RALPH:` en todos los mensajes de commit
- Mensajes descriptivos: qué se cambió y por qué
