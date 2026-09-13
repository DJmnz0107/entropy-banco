# Bancoagrícola · Banca Inteligente & Cobranza Preventiva con IA
**Entropía Hack 2026**

Sistema integral de analítica predictiva, cobranza preventiva y agente de voz autónomo para Bancoagrícola.

---

## 🚀 Guía de Inicio Rápido

Para ver las instrucciones detalladas paso a paso de configuración de ambiente, variables `.env`, puertos y ejecución conjunta con el dashboard de `web-banco`, consulta:

👉 **[INSTRUCTIONS.md](INSTRUCTIONS.md)**

---

## 📦 Estructura del Repositorio

* **`apps/agent/`**: Servidor del Agente de Voz (Hono + TypeScript). Maneja los turnos con Gemini (`gemini-3.1-flash-lite`), evaluación en tiempo real con supervisor de compliance, integración con ElevenLabs y orquestación de corridas preventivas.
* **`backend/whatsapp-hackathon-bot/`**: Bot de WhatsApp para entrega de enlaces de pago seguros y cápsulas de educación financiera.
* **`supabase/migrations/`**: 15 migraciones SQL con el modelo relacional, políticas RLS, motor de riesgo (`compute_risk`), propensión de canal (`channel_propensity`) y vistas de impacto (`v_impact`, `v_learning`).
* **`scripts/education/`**: Generador de cápsulas educativas audiovisuales (audio MP3 y subtítulos `.srt`).
* **`assets/education/`**: Subtítulos y metadatos de las 6 cápsulas de educación financiera.

---

## ⚡ Comandos Rápidos

```bash
# 1. Instalar dependencias
npm install

# 2. Correr suite de pruebas de base de datos (71 aserciones)
npm run db:test

# 3. Levantar el agente de voz (puerto 3000)
npm run agent:dev

# 4. Levantar el bot de WhatsApp (puerto 3002)
npm run bot:dev

# 5. Probar llamada simulada en terminal
npx tsx apps/agent/src/scripts/test-custom-llm.ts DEMO-003 http://localhost:3000
```