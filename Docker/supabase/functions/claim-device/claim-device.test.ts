import { assertEquals, assertMatch, assertNotEquals } from "https://deno.land/std@0.224.0/assert/mod.ts"
import { generateSoftApPassword } from "./index.ts"

Deno.test("generateSoftApPassword: length 12", () => {
  for (let i = 0; i < 100; i++) {
    assertEquals(generateSoftApPassword().length, 12)
  }
})

Deno.test("generateSoftApPassword: alphabet has no confusable chars", () => {
  // Reject if any of 0, O, 1, l, I appears in 1000 generations.
  for (let i = 0; i < 1000; i++) {
    const pwd = generateSoftApPassword()
    assertMatch(pwd, /^[ABCDEFGHJKLMNPQRSTUVWXYZabcdefghjkmnpqrstuvwxyz23456789]+$/)
  }
})

Deno.test("generateSoftApPassword: low collision rate (sanity)", () => {
  const seen = new Set<string>()
  for (let i = 0; i < 1000; i++) {
    seen.add(generateSoftApPassword())
  }
  // 1000 draws from a ~70-bit space — collisions astronomically unlikely.
  assertEquals(seen.size, 1000)
})

Deno.test("generateSoftApPassword: independent calls produce different values", () => {
  // Catches a regression where someone caches the result accidentally.
  assertNotEquals(generateSoftApPassword(), generateSoftApPassword())
})
