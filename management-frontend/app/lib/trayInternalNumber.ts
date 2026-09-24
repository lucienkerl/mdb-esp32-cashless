/**
 * The per-tray "internal tray number" (`machine_trays.internal_item_number`):
 * the selection number a machine reports for a tray when it differs from the
 * number on the tray's label. The backend books a sale reported as N on the
 * tray whose internal number is N (see `mqtt-webhook/tray-mapping.ts`); an
 * empty field means no mapping.
 */

/** A selection number is a uint16 on the wire; 0xFFFF is MDB's "unknown item". */
export const MAX_INTERNAL_ITEM_NUMBER = 65534

export interface TrayNumbers {
  id: string
  item_number: number
  internal_item_number: number | null
}

/**
 * Parse what the operator typed. Empty clears the mapping (null); anything but
 * a whole number from 0 to MAX_INTERNAL_ITEM_NUMBER is 'invalid'.
 */
export function parseInternalItemNumber(input: string | number | null | undefined): number | null | 'invalid' {
  const text = String(input ?? '').trim()
  if (text === '') return null
  if (!/^\d+$/.test(text)) return 'invalid'
  const value = Number(text)
  return value <= MAX_INTERNAL_ITEM_NUMBER ? value : 'invalid'
}

/**
 * The other tray of the machine that already has `internalItemNumber`, if any.
 * One reported number can only lead to one tray — the database enforces it
 * too; checking first gives the operator a readable message.
 */
export function findInternalItemNumberConflict<T extends TrayNumbers>(
  trays: readonly T[],
  trayId: string | null,
  internalItemNumber: number,
): T | undefined {
  return trays.find(t => t.id !== trayId && t.internal_item_number === internalItemNumber)
}

/**
 * For a tray WITHOUT a mapping: the tray whose internal number equals this
 * tray's slot number. A mapping wins over the reported number itself, so sales
 * reported as that number go there, not to this tray.
 */
export function findShadowingTray<T extends TrayNumbers>(trays: readonly T[], tray: T): T | undefined {
  if (tray.internal_item_number != null) return undefined
  return trays.find(t => t.id !== tray.id && t.internal_item_number === tray.item_number)
}
