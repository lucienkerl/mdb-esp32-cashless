import mqtt from "npm:mqtt@5";
import { encodeBase64 } from "jsr:@std/encoding/base64";

const MQTT_HOST = Deno.env.get("MQTT_HOST") ?? "broker";
const MQTT_USER = Deno.env.get("MQTT_ADMIN_USER") ?? "admin";
const MQTT_PASS = Deno.env.get("MQTT_ADMIN_PASS") ?? "admin";
const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const WEBHOOK_SECRET = Deno.env.get("MQTT_WEBHOOK_SECRET") ?? "";
const DLQ_PATH = Deno.env.get("DLQ_PATH") ?? "/data/dlq.db";

function errMessage(err: unknown): string {
  return err instanceof Error ? err.message : String(err);
}

// Topics: /{company_id}/{device_id}/{event}
// Leading / creates empty first level, so pattern is /+/+/{event}
// `/dex` is included so DEX audit snapshots reach the reconciliation pipeline.
// `/card` carries RFID card presentations from the reader on the pulse input.
const topics = [
  "/+/+/sale",
  "/+/+/status",
  "/+/+/paxcounter",
  "/+/+/mdb-log",
  "/+/+/restart",
  "/+/+/dex",
  "/+/+/card",
];

// Topic prefixes that we deliberately drop without forwarding.
//
// `/healthcheck/` exists because something (likely an external uptime probe
// using the vmflow MQTT credentials) was publishing /healthcheck/ping/status,
// which the wildcard subscriptions pick up. mqtt-webhook then tries to
// UPDATE embeddeds.id=ping, the DB rejects "ping" as a uuid, the webhook
// returns 500, the message gets retried via DLQ, and the loop pegs the
// server. Filtering at the forwarder is the cheapest place to break it —
// the broker still queues the publish, we ACK it and silently drop.
const IGNORED_TOPIC_PREFIXES = ["/healthcheck/"];

function isIgnoredTopic(topic: string): boolean {
  return IGNORED_TOPIC_PREFIXES.some((p) => topic.startsWith(p));
}

// Deno KV is the local dead-letter queue. When a webhook call fails with a
// retryable error (5xx, network) we persist the (topic, payload, attempt,
// last_error, first_seen) tuple so a separate drain loop can retry it later.
// KV writes go to DLQ_PATH which is a persistent Docker volume, so the DLQ
// survives forwarder restarts and longer Supabase outages than the broker's
// retention window.
const kv = await Deno.openKv(DLQ_PATH);

interface DlqEntry {
  topic: string;
  payload_b64: string;
  first_seen: number;
  last_attempt: number;
  attempts: number;
  last_error: string;
}

async function enqueueDlq(topic: string, payload_b64: string, err: string) {
  const id = `${Date.now()}-${crypto.randomUUID()}`;
  const entry: DlqEntry = {
    topic,
    payload_b64,
    first_seen: Date.now(),
    last_attempt: Date.now(),
    attempts: 1,
    last_error: err,
  };
  await kv.set(["dlq", id], entry);
  console.warn(`DLQ enqueue ${topic} id=${id} err=${err}`);
}

// Retryable = transient infrastructure errors. 4xx responses indicate a
// permanent issue (bad payload, missing device) — retrying won't help, so
// we drop those. 5xx / network / timeout all go to DLQ.
function isRetryable(status: number | null): boolean {
  if (status === null) return true; // network / fetch threw
  if (status >= 500) return true;
  return false;
}

async function forward(topic: string, payload_b64: string): Promise<{ ok: boolean; status: number | null; error?: string }> {
  try {
    const res = await fetch(`${SUPABASE_URL}/functions/v1/mqtt-webhook`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "X-Webhook-Secret": WEBHOOK_SECRET,
      },
      body: JSON.stringify({ topic, payload: payload_b64 }),
    });
    if (res.ok) return { ok: true, status: res.status };
    const body = await res.text().catch(() => "<no body>");
    return { ok: false, status: res.status, error: `HTTP ${res.status}: ${body.slice(0, 200)}` };
  } catch (err) {
    return { ok: false, status: null, error: errMessage(err) };
  }
}

// DLQ drain loop. Runs every 30s, replaying oldest entries first. On
// success the entry is removed; on failure attempts++ and last_error is
// updated. We cap retries at 500 attempts (~1 week at 30s) to prevent
// malformed entries from looping forever.
async function drainDlq() {
  while (true) {
    try {
      const now = Date.now();
      const entries = kv.list<DlqEntry>({ prefix: ["dlq"] });
      let drained = 0;
      let dropped = 0;
      for await (const { key, value } of entries) {
        // Drop stale DLQ entries whose topic is now on the ignore list —
        // otherwise they would keep retrying forever after a hot-fix
        // adds a prefix to IGNORED_TOPIC_PREFIXES.
        if (isIgnoredTopic(value.topic)) {
          await kv.delete(key);
          dropped++;
          continue;
        }

        // Exponential backoff capped at 5min: retry after 5s, 10s, 20s, ..., 5min.
        const sinceLast = now - value.last_attempt;
        const backoffMs = Math.min(300_000, 5000 * Math.pow(2, Math.min(value.attempts, 6)));
        if (sinceLast < backoffMs) continue;

        const { ok, status, error } = await forward(value.topic, value.payload_b64);
        if (ok) {
          await kv.delete(key);
          drained++;
        } else if (!isRetryable(status) || value.attempts >= 500) {
          console.error(`DLQ drop ${value.topic} after ${value.attempts} attempts: ${error}`);
          await kv.delete(key);
          dropped++;
        } else {
          const updated: DlqEntry = {
            ...value,
            attempts: value.attempts + 1,
            last_attempt: now,
            last_error: error ?? "unknown",
          };
          await kv.set(key, updated);
        }
      }
      if (drained || dropped) {
        console.log(`DLQ drain: sent=${drained} dropped=${dropped}`);
      }
    } catch (err) {
      console.error("DLQ drain loop error:", errMessage(err));
    }
    await new Promise((r) => setTimeout(r, 30_000));
  }
}

const client = mqtt.connect(`mqtt://${MQTT_HOST}:1883`, {
  clientId: "vmflow-forwarder",
  clean: false, // persistent session — broker queues QoS 1 messages while we're offline
  reconnectPeriod: 5000,
  username: MQTT_USER,
  password: MQTT_PASS,
});

client.on("connect", (connack: { sessionPresent: boolean }) => {
  console.log(`Connected to mqtt://${MQTT_HOST}:1883 (session present: ${connack.sessionPresent})`);
  // Always (re-)subscribe so new topics are picked up even with a persistent session
  client.subscribe(topics, { qos: 1 }, (err) => {
    if (err) console.error("Subscribe error:", err);
    else console.log("Subscribed to:", topics.join(", "));
  });
});

client.on("message", async (topic: string, payload: Buffer) => {
  if (isIgnoredTopic(topic)) return;
  const payload_b64 = encodeBase64(new Uint8Array(payload));
  const { ok, status, error } = await forward(topic, payload_b64);
  if (ok) {
    console.log(`${topic} -> ${status}`);
    return;
  }
  if (!isRetryable(status)) {
    console.warn(`${topic} -> ${status} (permanent, dropping): ${error}`);
    return;
  }
  console.error(`${topic} -> ${status ?? "ERR"} (retryable, to DLQ): ${error}`);
  await enqueueDlq(topic, payload_b64, error ?? "unknown");
});

client.on("error", (err: Error) => console.error("MQTT error:", err));
client.on("reconnect", () => console.log("Reconnecting to MQTT..."));
client.on("close", () => console.log("MQTT connection closed"));

// Start DLQ drain loop (fire-and-forget — runs for the lifetime of the process)
drainDlq();
