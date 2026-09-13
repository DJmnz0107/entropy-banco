/**
 * Generador de cápsulas educativas de audio y subtítulos.
 *
 * Lee los guiones oficiales definidos en seed_prevention_config() y genera:
 *  - assets/education/<slug>.mp3 con ElevenLabs TTS (modelo eleven_multilingual_v2)
 *  - assets/education/<slug>.srt con subtítulos temporizados
 *
 * Ejecutar con:
 *   npx tsx scripts/education/generate.ts
 */

import 'dotenv/config';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const ROOT_DIR = path.resolve(__dirname, '../..');
const ASSETS_DIR = path.join(ROOT_DIR, 'assets/education');

// Cargar .env de la raíz explícitamente si es necesario
const envPath = path.join(ROOT_DIR, '.env');
if (fs.existsSync(envPath)) {
  const envContent = fs.readFileSync(envPath, 'utf8');
  for (const line of envContent.split('\n')) {
    const match = line.match(/^\s*([\w.-]+)\s*=\s*(.*)?\s*$/);
    if (match) {
      const key = match[1];
      const val = (match[2] || '').trim().replace(/^["']|["']$/g, '');
      if (!process.env[key]) {
        process.env[key] = val;
      }
    }
  }
}

const ELEVENLABS_API_KEY = process.env.ELEVENLABS_API_KEY;
// Voz en español latino por defecto (o la configurada en ELEVENLABS_VOICE_ID)
// Voz predeterminada: 'Rachel' / 'Paulina' / 'Nicole' o configurable
const VOICE_ID = process.env.ELEVENLABS_VOICE_ID || '21m00Tcm4TlvDq8ikWAM';
const MODEL_ID = 'eleven_multilingual_v2';

interface EducationContent {
  slug: string;
  title: string;
  description: string;
  topic: string;
  duration_s: number;
  script: string;
}

export const EDUCATION_CONTENTS: EducationContent[] = [
  {
    slug: 'record-crediticio',
    title: '¿Por qué importa tu récord crediticio?',
    description: 'Qué es el historial y cómo te abre puertas.',
    topic: 'historial',
    duration_s: 20,
    script:
      'Tu récord crediticio es tu carta de presentación. Pagar a tiempo te ayuda a conseguir mejores tasas y más oportunidades. Un solo atraso puede quedar registrado. Si ves que no llegas a tu fecha, avísanos antes: juntos buscamos una opción.',
  },
  {
    slug: 'pagar-tarde',
    title: '¿Qué pasa si pagas después de la fecha?',
    description: 'Recargos, intereses y récord: lo que cuesta un atraso.',
    topic: 'atrasos',
    duration_s: 18,
    script:
      'Pagar tarde no solo suma recargos: también afecta tu récord. Programa un recordatorio dos días antes de tu fecha y, si no te alcanza, llámanos antes del vencimiento.',
  },
  {
    slug: 'organizar-cuota',
    title: 'Cómo organizar tu pago mensual',
    description: 'Separar la cuota el día que recibes tu ingreso.',
    topic: 'presupuesto',
    duration_s: 20,
    script:
      'El truco es simple: el día que recibes tu ingreso, separa primero el dinero de tu cuota. Anota tus gastos fijos, deja un pequeño colchón y verás que llegar a la fecha es más fácil.',
  },
  {
    slug: 'fondo-emergencia',
    title: 'Tu primer fondo de emergencia',
    description: 'Pequeños ahorros para imprevistos.',
    topic: 'ahorro',
    duration_s: 20,
    script:
      'Un imprevisto no tiene que convertirse en deuda. Empieza con poco: guarda un dólar al día. En tres meses tendrás un colchón para emergencias sin atrasar tus pagos.',
  },
  {
    slug: 'agro-cosecha',
    title: 'Planifica tus pagos con la cosecha',
    description: 'Alinear pagos con el ciclo productivo.',
    topic: 'agro',
    duration_s: 20,
    script:
      'Si tu ingreso llega con la cosecha, planifica desde ahora: separa una parte de cada venta para las cuotas de los meses sin ingreso. Y si el clima afecta tu cultivo, avísanos antes de la fecha.',
  },
  {
    slug: 'mantener-historial',
    title: '3 consejos para mantener un buen historial',
    description: 'Para quien paga bien y quiere seguir así.',
    topic: 'historial',
    duration_s: 15,
    script:
      'Uno: paga antes de la fecha. Dos: usa recordatorios. Tres: si algo cambia, avísanos a tiempo. Así tu buen historial sigue creciendo.',
  },
];

/**
 * Formatea segundos a formato de tiempo SRT: HH:MM:SS,mmm
 */
function formatSrtTime(totalSeconds: number): string {
  const hours = Math.floor(totalSeconds / 3600);
  const minutes = Math.floor((totalSeconds % 3600) / 60);
  const seconds = Math.floor(totalSeconds % 60);
  const millis = Math.floor((totalSeconds % 1) * 1000);

  const hStr = String(hours).padStart(2, '0');
  const mStr = String(minutes).padStart(2, '0');
  const sStr = String(seconds).padStart(2, '0');
  const msStr = String(millis).padStart(3, '0');

  return `${hStr}:${mStr}:${sStr},${msStr}`;
}

/**
 * Divide el texto en oraciones y genera subtítulos .srt distribuyendo la duración estimada.
 */
function generateSrt(script: string, totalDurationSeconds: number): string {
  // Dividir por oraciones usando signos de puntuación (. ! ?)
  const sentences = script
    .split(/(?<=[.?!:])\s+/)
    .map((s) => s.trim())
    .filter((s) => s.length > 0);

  if (sentences.length === 0) return '';

  const totalWords = script.split(/\s+/).length;
  let currentTime = 0;
  const srtBlocks: string[] = [];

  sentences.forEach((sentence, index) => {
    const sentenceWords = sentence.split(/\s+/).length;
    const duration = (sentenceWords / totalWords) * totalDurationSeconds;
    const startTime = currentTime;
    const endTime = Math.min(currentTime + duration, totalDurationSeconds);

    srtBlocks.push(
      `${index + 1}\n${formatSrtTime(startTime)} --> ${formatSrtTime(endTime)}\n${sentence}\n`,
    );

    currentTime = endTime;
  });

  return srtBlocks.join('\n');
}

/**
 * Llama a la API de ElevenLabs TTS para generar el archivo de audio MP3.
 */
async function generateAudio(slug: string, text: string, apiKey: string): Promise<Buffer> {
  const url = `https://api.elevenlabs.io/v1/text-to-speech/${VOICE_ID}`;

  const response = await fetch(url, {
    method: 'POST',
    headers: {
      'xi-api-key': apiKey,
      'Content-Type': 'application/json',
      Accept: 'audio/mpeg',
    },
    body: JSON.stringify({
      text,
      model_id: MODEL_ID,
      voice_settings: {
        stability: 0.5,
        similarity_boost: 0.75,
        style: 0.0,
        use_speaker_boost: true,
      },
    }),
  });

  if (!response.ok) {
    const errText = await response.text();
    throw new Error(`Error en ElevenLabs API (${response.status}): ${errText}`);
  }

  const arrayBuffer = await response.arrayBuffer();
  return Buffer.from(arrayBuffer);
}

async function main() {
  console.log('🎙️ Generador de Cápsulas Educativas (Audio + Subtítulos)');
  console.log(`📁 Directorio de salida: ${ASSETS_DIR}\n`);

  if (!fs.existsSync(ASSETS_DIR)) {
    fs.mkdirSync(ASSETS_DIR, { recursive: true });
  }

  const hasApiKey = Boolean(ELEVENLABS_API_KEY && ELEVENLABS_API_KEY.trim().length > 0);

  if (!hasApiKey) {
    console.log(
      'ℹ️ ELEVENLABS_API_KEY no encontrada en .env.',
    );
    console.log(
      '   Se generarán todos los archivos de subtítulos (.srt).',
    );
    console.log(
      '   Cuando agregues ELEVENLABS_API_KEY al .env, vuelve a ejecutar este script para generar los .mp3.\n',
    );
  }

  for (const item of EDUCATION_CONTENTS) {
    console.log(`▶ Procesando: [${item.slug}] ${item.title}`);

    // 1. Generar subtítulos .srt
    const srtPath = path.join(ASSETS_DIR, `${item.slug}.srt`);
    const srtContent = generateSrt(item.script, item.duration_s);
    fs.writeFileSync(srtPath, srtContent, 'utf8');
    console.log(`  ✅ Subtítulos guardados: ${item.slug}.srt`);

    // 2. Generar audio .mp3 si hay API key
    const mp3Path = path.join(ASSETS_DIR, `${item.slug}.mp3`);
    if (hasApiKey) {
      try {
        console.log(`  ⏳ Generando audio con ElevenLabs (${VOICE_ID})...`);
        const audioBuffer = await generateAudio(item.slug, item.script, ELEVENLABS_API_KEY!);
        fs.writeFileSync(mp3Path, audioBuffer);
        console.log(`  🔊 Audio guardado: ${item.slug}.mp3 (${audioBuffer.length} bytes)`);
      } catch (err: any) {
        console.error(`  ❌ Error generando audio para ${item.slug}:`, err.message);
      }
    } else {
      console.log(`  ⏸️ Audio pendiente (falta ELEVENLABS_API_KEY en .env)`);
    }
  }

  console.log('\n✨ Proceso finalizado exitosamente.');
}

void main();
