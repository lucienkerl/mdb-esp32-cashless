import { assertEquals } from 'jsr:@std/assert';
import { applyHeartbeatSignal, applyStatusNetwork, parseStatusExtras } from './network-status.ts';

const NOW = '2026-11-06T12:00:00.000Z';

Deno.test('parseStatusExtras: cellular segments', () => {
  assertEquals(
    parseStatusExtras(['uplink:cellular', 'op:Vodafone DE', 'rssi:-78', 'mode:LTE-M', 'ip:10.0.0.1']),
    { uplink: 'cellular', op: 'Vodafone DE', rssi: -78, mode: 'LTE-M', ip: '10.0.0.1' },
  );
});

Deno.test('parseStatusExtras: wifi segments, SSID with a colon keeps its tail', () => {
  assertEquals(
    parseStatusExtras(['uplink:wifi', 'ssid:Cafe: Gast', 'rssi:-62', 'ip:192.168.1.47']),
    { uplink: 'wifi', ssid: 'Cafe: Gast', rssi: -62, ip: '192.168.1.47' },
  );
});

Deno.test('parseStatusExtras: skips empty, malformed and firmware segments', () => {
  assertEquals(parseStatusExtras(['', 'noColon', ':x', 'op:', 'rssi:abc', 'v:1.0']), {});
});

Deno.test('applyStatusNetwork: no extras leaves diagnostics alone', () => {
  assertEquals(applyStatusNetwork({ state: 'ENABLED' }, {}, NOW), null);
});

Deno.test('applyStatusNetwork: wifi writes network and drops a stale cellular block', () => {
  const prev = { state: 'ENABLED', cellular: { uplink: 'cellular', op: 'Telekom.de', rssi: -90 } };
  assertEquals(
    applyStatusNetwork(prev, { uplink: 'wifi', ssid: 'Office', rssi: -62, ip: '192.168.1.47' }, NOW),
    {
      state: 'ENABLED',
      network: { uplink: 'wifi', ssid: 'Office', rssi: -62, ip: '192.168.1.47', measured_at: NOW },
    },
  );
});

Deno.test('applyStatusNetwork: cellular writes network and the legacy cellular block', () => {
  const extras = { uplink: 'cellular', op: 'Telekom.de', rssi: -78, mode: 'LTE-M', ip: '10.0.0.1' };
  assertEquals(applyStatusNetwork(null, extras, NOW), {
    network: { ...extras, measured_at: NOW },
    cellular: extras,
  });
});

Deno.test('applyStatusNetwork: extras without uplink mean cellular', () => {
  const out = applyStatusNetwork(null, { op: 'Telekom.de', rssi: -78 }, NOW)!;
  assertEquals((out.network as Record<string, unknown>).uplink, 'cellular');
  assertEquals((out.cellular as Record<string, unknown>).uplink, 'cellular');
});

Deno.test('applyHeartbeatSignal: wifi rssi refreshes the network block', () => {
  const prev = { uplink: 'wifi', ssid: 'Office', rssi: -62, ip: '192.168.1.47', measured_at: '2026-11-06T08:00:00.000Z' };
  assertEquals(applyHeartbeatSignal({ state: 'ENABLED', rssi: -71 }, prev, NOW), {
    state: 'ENABLED',
    network: { uplink: 'wifi', ssid: 'Office', rssi: -71, ip: '192.168.1.47', measured_at: NOW },
  });
});

Deno.test('applyHeartbeatSignal: never stores a top-level rssi', () => {
  assertEquals(applyHeartbeatSignal({ state: 'ENABLED', rssi: -71 }, null, NOW), { state: 'ENABLED' });
  assertEquals(
    applyHeartbeatSignal({ state: 'ENABLED', rssi: -71 }, { uplink: 'cellular', rssi: -80 }, NOW),
    { state: 'ENABLED' },
  );
});

Deno.test('applyHeartbeatSignal: payload without rssi passes through', () => {
  assertEquals(applyHeartbeatSignal({ state: 'IDLE', polls: 3 }, { uplink: 'wifi' }, NOW), { state: 'IDLE', polls: 3 });
});
