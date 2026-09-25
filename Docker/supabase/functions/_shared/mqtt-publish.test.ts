// Same std-assert specifier the repo's other edge-function tests use.
import { assertEquals, assertRejects, assertStringIncludes } from "jsr:@std/assert";
import { buildConnect, buildPublish, encodeRemainingLength, mqttPublish, PacketReader } from "./mqtt-publish.ts";

// ── A stub broker ──────────────────────────────────────────────────────────
//
// Deliberately NOT built on PacketReader: it decodes the byte stream with its
// own little parser, so a framing bug in the publisher cannot be cancelled
// out by the same bug in the test.

interface SeenConnect {
  protocol: string;
  level: number;
  flags: number;
  keepAlive: number;
  clientId: string;
  username?: string;
  password?: string;
}

interface SeenPublish {
  topic: string;
  qos: number;
  packetId: number;
  payload: Uint8Array;
}

interface Stub {
  port: number;
  connects: SeenConnect[];
  publishes: SeenPublish[];
  counters: { disconnects: number };
  stop: () => Promise<void>;
}

interface StubOptions {
  /** CONNACK return code; anything non-zero is a refusal. */
  connackCode?: number;
  /** Answer a QoS-1 PUBLISH with a PUBACK (default true). */
  ack?: boolean;
  /** Send every reply byte in its own WebSocket frame. */
  dribble?: boolean;
  /** Reply to a PUBACK-worthy publish with this packet id instead. */
  ackPacketId?: number;
}

function startStub(opts: StubOptions = {}): Promise<Stub> {
  const connects: SeenConnect[] = [];
  const publishes: SeenPublish[] = [];
  const counters = { disconnects: 0 };
  const sockets = new Set<WebSocket>();

  const server = Deno.serve({ port: 0, onListen: () => {} }, (req) => {
    const { socket, response } = Deno.upgradeWebSocket(req, { protocol: "mqtt" });
    socket.binaryType = "arraybuffer";
    sockets.add(socket);

    let buf = new Uint8Array(0);

    const send = (bytes: number[]) => {
      if (opts.dribble) {
        for (const b of bytes) socket.send(new Uint8Array([b]));
      } else {
        socket.send(new Uint8Array(bytes));
      }
    };

    socket.onmessage = (ev) => {
      const chunk = new Uint8Array(ev.data as ArrayBuffer);
      const merged = new Uint8Array(buf.length + chunk.length);
      merged.set(buf, 0);
      merged.set(chunk, buf.length);
      buf = merged;

      // Drain every complete packet currently in the buffer.
      for (;;) {
        if (buf.length < 2) return;
        let mult = 1, remaining = 0, i = 1, b: number;
        do {
          if (i >= buf.length) return;
          b = buf[i++];
          remaining += (b & 0x7f) * mult;
          mult *= 128;
        } while (b & 0x80);
        if (buf.length < i + remaining) return;

        const type = buf[0] >> 4;
        const flags = buf[0] & 0x0f;
        const body = buf.slice(i, i + remaining);
        buf = buf.slice(i + remaining);

        const str = (at: number): [string, number] => {
          const len = (body[at] << 8) | body[at + 1];
          return [new TextDecoder().decode(body.subarray(at + 2, at + 2 + len)), at + 2 + len];
        };

        if (type === 1) {
          const [protocol, afterProto] = str(0);
          const level = body[afterProto];
          const connFlags = body[afterProto + 1];
          const keepAlive = (body[afterProto + 2] << 8) | body[afterProto + 3];
          const [clientId, afterId] = str(afterProto + 4);
          let cursor = afterId;
          let username: string | undefined;
          let password: string | undefined;
          if (connFlags & 0x80) [username, cursor] = str(cursor);
          if (connFlags & 0x40) [password, cursor] = str(cursor);
          connects.push({ protocol, level, flags: connFlags, keepAlive, clientId, username, password });
          send([0x20, 0x02, 0x00, opts.connackCode ?? 0]);
        } else if (type === 3) {
          const [topic, afterTopic] = str(0);
          const qos = (flags >> 1) & 0x03;
          let cursor = afterTopic;
          let packetId = 0;
          if (qos > 0) {
            packetId = (body[cursor] << 8) | body[cursor + 1];
            cursor += 2;
          }
          publishes.push({ topic, qos, packetId, payload: body.slice(cursor) });
          if (qos > 0 && (opts.ack ?? true)) {
            const id = opts.ackPacketId ?? packetId;
            send([0x40, 0x02, id >> 8, id & 0xff]);
          }
        } else if (type === 14) {
          counters.disconnects++;
        }
      }
    };
    socket.onclose = () => sockets.delete(socket);
    socket.onerror = () => sockets.delete(socket);

    return response;
  });

  const port = (server.addr as Deno.NetAddr).port;
  const stub: Stub = {
    port,
    connects,
    publishes,
    counters,
    stop: async () => {
      for (const s of sockets) {
        try { s.close() } catch { /* already gone */ }
      }
      await server.shutdown();
    },
  };
  return Promise.resolve(stub);
}

/** Point mqttPublish at the stub, run `fn`, then restore the environment. */
async function withStub(opts: StubOptions, fn: (stub: Stub) => Promise<void>) {
  const stub = await startStub(opts);
  const previous = {
    host: Deno.env.get("MQTT_HOST"),
    port: Deno.env.get("MQTT_WS_PORT"),
    user: Deno.env.get("MQTT_ADMIN_USER"),
    pass: Deno.env.get("MQTT_ADMIN_PASS"),
  };
  Deno.env.set("MQTT_HOST", "127.0.0.1");
  Deno.env.set("MQTT_WS_PORT", String(stub.port));
  Deno.env.set("MQTT_ADMIN_USER", "admin");
  Deno.env.set("MQTT_ADMIN_PASS", "s3cret");
  try {
    await fn(stub);
  } finally {
    for (const [k, v] of Object.entries({
      MQTT_HOST: previous.host,
      MQTT_WS_PORT: previous.port,
      MQTT_ADMIN_USER: previous.user,
      MQTT_ADMIN_PASS: previous.pass,
    })) {
      if (v === undefined) Deno.env.delete(k);
      else Deno.env.set(k, v);
    }
    await stub.stop();
  }
}

/** Let the stub's socket callbacks run before asserting on what it saw. */
const settle = () => new Promise((r) => setTimeout(r, 50));

// ── Encoder units ──────────────────────────────────────────────────────────

Deno.test("remaining length uses MQTT's 7-bit continuation encoding", () => {
  assertEquals(encodeRemainingLength(0), [0x00]);
  assertEquals(encodeRemainingLength(127), [0x7f]);
  assertEquals(encodeRemainingLength(128), [0x80, 0x01]);
  assertEquals(encodeRemainingLength(16_383), [0xff, 0x7f]);
  assertEquals(encodeRemainingLength(16_384), [0x80, 0x80, 0x01]);
});

Deno.test("CONNECT carries MQTT 3.1.1, clean session and credentials", () => {
  const packet = buildConnect("vmflow-fn-abcd1234", "admin", "pw");
  assertEquals(packet[0], 0x10);
  assertEquals([...packet.subarray(2, 8)], [0x00, 0x04, 0x4d, 0x51, 0x54, 0x54]); // "MQTT"
  assertEquals(packet[8], 0x04); // protocol level
  assertEquals(packet[9], 0x02 | 0x80 | 0x40); // clean session + user + pass
});

Deno.test("CONNECT omits the credential flags when there is no username", () => {
  const packet = buildConnect("id", "", "");
  assertEquals(packet[9], 0x02);
});

Deno.test("PUBLISH sets the QoS bits and only carries a packet id above QoS 0", () => {
  const q1 = buildPublish("/a/b/credit", new Uint8Array([0xde, 0xad]), 1, 7);
  assertEquals(q1[0], 0x32);
  assertEquals([...q1.subarray(q1.length - 4)], [0x00, 0x07, 0xde, 0xad]);

  const q0 = buildPublish("/a/b/credit", new Uint8Array([0xde, 0xad]), 0, 7);
  assertEquals(q0[0], 0x30);
  assertEquals([...q0.subarray(q0.length - 2)], [0xde, 0xad]);
});

Deno.test("PacketReader reassembles split packets and splits coalesced ones", () => {
  const reader = new PacketReader();
  reader.push(new Uint8Array([0x20, 0x02]));
  assertEquals(reader.next(), null); // body still missing
  reader.push(new Uint8Array([0x00, 0x00, 0x40, 0x02, 0x00, 0x01]));

  const connack = reader.next()!;
  assertEquals(connack.type, 2);
  assertEquals([...connack.body], [0x00, 0x00]);

  const puback = reader.next()!;
  assertEquals(puback.type, 4);
  assertEquals([...puback.body], [0x00, 0x01]);
  assertEquals(reader.next(), null);
});

// ── End to end against the stub broker ─────────────────────────────────────

Deno.test("publishes a QoS 1 message and disconnects", async () => {
  await withStub({}, async (stub) => {
    await mqttPublish("/company/device/credit", new Uint8Array([0x20, 0x01, 0xff]));
    await settle();

    assertEquals(stub.connects.length, 1);
    assertEquals(stub.connects[0].protocol, "MQTT");
    assertEquals(stub.connects[0].level, 4);
    assertEquals(stub.connects[0].username, "admin");
    assertEquals(stub.connects[0].password, "s3cret");

    assertEquals(stub.publishes.length, 1);
    assertEquals(stub.publishes[0].topic, "/company/device/credit");
    assertEquals(stub.publishes[0].qos, 1);
    assertEquals([...stub.publishes[0].payload], [0x20, 0x01, 0xff]);
    assertEquals(stub.counters.disconnects, 1);
  });
});

Deno.test("publishes QoS 0 without waiting for an acknowledgement", async () => {
  await withStub({ ack: false }, async (stub) => {
    await mqttPublish("/company/device/ota", "https://example.test/fw.bin", { qos: 0 });
    await settle();

    assertEquals(stub.publishes.length, 1);
    assertEquals(stub.publishes[0].qos, 0);
    assertEquals(
      new TextDecoder().decode(stub.publishes[0].payload),
      "https://example.test/fw.bin",
    );
  });
});

Deno.test("survives a broker that dribbles one byte per frame", async () => {
  await withStub({ dribble: true }, async (stub) => {
    await mqttPublish("/company/device/credit", new Uint8Array([0x01]));
    await settle();
    assertEquals(stub.publishes.length, 1);
  });
});

Deno.test("a refused login throws with the broker's reason", async () => {
  await withStub({ connackCode: 5 }, async () => {
    const err = await assertRejects(
      () => mqttPublish("/company/device/credit", new Uint8Array([0x01])),
      Error,
    );
    assertStringIncludes(err.message, "not authorized");
  });
});

Deno.test("a missing PUBACK fails instead of reporting a delivered credit", async () => {
  await withStub({ ack: false }, async () => {
    const err = await assertRejects(
      () => mqttPublish("/company/device/credit", new Uint8Array([0x01])),
      Error,
    );
    assertStringIncludes(err.message, "PUBACK");
  });
});

Deno.test("an unreachable broker throws rather than hanging", async () => {
  const previousHost = Deno.env.get("MQTT_HOST");
  const previousPort = Deno.env.get("MQTT_WS_PORT");
  // Port 1 is reserved and never listening.
  Deno.env.set("MQTT_HOST", "127.0.0.1");
  Deno.env.set("MQTT_WS_PORT", "1");
  try {
    await assertRejects(
      () => mqttPublish("/company/device/credit", new Uint8Array([0x01])),
      Error,
    );
  } finally {
    if (previousHost === undefined) Deno.env.delete("MQTT_HOST");
    else Deno.env.set("MQTT_HOST", previousHost);
    if (previousPort === undefined) Deno.env.delete("MQTT_WS_PORT");
    else Deno.env.set("MQTT_WS_PORT", previousPort);
  }
});
