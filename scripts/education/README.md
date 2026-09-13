# 📚 Cápsulas Educativas — Generación y Subida a Supabase Storage

Este módulo genera los archivos de audio (`.mp3`) y subtítulos (`.srt`) para las 6 cápsulas de educación financiera preventiva de Bancoagrícola, definidas en la migración `20260912001200_prevention_engine.sql`.

---

## 🎧 Cápsulas incluidas

| Slug | Título | Duración est. | Tema |
|---|---|---|---|
| `record-crediticio` | ¿Por qué importa tu récord crediticio? | 20 s | Historial |
| `pagar-tarde` | ¿Qué pasa si pagas después de la fecha? | 18 s | Atrasos |
| `organizar-cuota` | Cómo organizar tu pago mensual | 20 s | Presupuesto |
| `fondo-emergencia` | Tu primer fondo de emergencia | 20 s | Ahorro |
| `agro-cosecha` | Planifica tus pagos con la cosecha | 20 s | Agro |
| `mantener-historial` | 3 consejos para mantener un buen historial | 15 s | Historial |

---

## ⚙️ Requisitos previos

1. Configurar en el archivo `.env` de la raíz:
   ```env
   ELEVENLABS_API_KEY=tu_api_key_aqui
   # Opcional: ID de voz en español latino (por defecto: Rachel / 21m00Tcm4TlvDq8ikWAM)
   ELEVENLABS_VOICE_ID=21m00Tcm4TlvDq8ikWAM
   ```

---

## 🚀 Cómo correr el generador

Ejecutar desde la raíz del proyecto:

```bash
npx tsx scripts/education/generate.ts
```

Esto creará en la carpeta `assets/education/`:
- `<slug>.mp3` (Audio generado con ElevenLabs TTS, modelo `eleven_multilingual_v2`)
- `<slug>.srt` (Subtítulos sincronizados)

> **Nota**: Si aún no has agregado la clave `ELEVENLABS_API_KEY` al `.env`, el script generará inmediatamente los archivos `.srt` y dejará los audios pendientes sin fallar.

---

## ☁️ Cómo subir los archivos a Supabase Storage (Bucket "education")

Las cápsulas se sirven públicamente a los clientes por WhatsApp mediante URLs públicas de Supabase Storage.

### Opción A: Vía Dashboard de Supabase (Recomendada / 1 minuto)

1. Abre el panel de tu proyecto en [Supabase](https://supabase.com/dashboard).
2. En el menú lateral, haz clic en **Storage**.
3. Si el bucket **`education`** no existe:
   - Haz clic en **New Bucket**.
   - Nombre: `education`.
   - Marca la casilla **Public bucket** (para que los audios sean accesibles desde WhatsApp/Web).
   - Guarda los cambios.
4. Entra al bucket `education` y sube los archivos de `assets/education/`:
   - `record-crediticio.mp3`, `record-crediticio.srt`
   - `pagar-tarde.mp3`, `pagar-tarde.srt`
   - `organizar-cuota.mp3`, `organizar-cuota.srt`
   - `fondo-emergencia.mp3`, `fondo-emergencia.srt`
   - `agro-cosecha.mp3`, `agro-cosecha.srt`
   - `mantener-historial.mp3`, `mantener-historial.srt`
5. La URL pública de cada archivo quedará en el formato:
   ```text
   https://virurjsqumurwrayztcs.supabase.co/storage/v1/object/public/education/<slug>.mp3
   ```

---

### Opción B: Vía cURL con `SUPABASE_SERVICE_ROLE_KEY`

Puedes subir directamente los archivos por terminal usando la API REST de Storage:

```bash
# Cargar variables de entorno
source .env

# Subir audio de ejemplo:
curl -X POST "${SUPABASE_URL}/storage/v1/object/education/record-crediticio.mp3" \
  -H "Authorization: Bearer ${SUPABASE_SERVICE_ROLE_KEY}" \
  -H "Content-Type: audio/mpeg" \
  --data-binary "@assets/education/record-crediticio.mp3"

# Subir subtítulos:
curl -X POST "${SUPABASE_URL}/storage/v1/object/education/record-crediticio.srt" \
  -H "Authorization: Bearer ${SUPABASE_SERVICE_ROLE_KEY}" \
  -H "Content-Type: text/plain" \
  --data-binary "@assets/education/record-crediticio.srt"
```

---

## 🔒 Regla del proyecto

Este script NO modifica ni escribe directamente en la base de datos Postgres; el catálogo de cápsulas y sus condiciones de elegibilidad están administrados en SQL mediante `education_contents`.
