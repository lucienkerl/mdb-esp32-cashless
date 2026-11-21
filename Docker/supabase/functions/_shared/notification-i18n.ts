/**
 * Per-locale notification strings + price formatting for push pushes.
 *
 * Single source of truth for the ~8 strings we send to user devices.
 * Emoji prefixes (🛒 💵 🟡 ⚠️ 🚨) stay universal and are concatenated
 * by the callers; this module only supplies translated words and
 * locale-aware currency formatting.
 */

export type Locale = 'en' | 'de' | 'fr' | 'nl'

/**
 * Clamp any input (user-supplied locale, Accept-Language header,
 * iOS `Locale.current` code) to our supported set. Unknown → 'en'.
 */
export function normalizeLocale(raw: string | null | undefined): Locale {
  if (!raw) return 'en'
  const prefix = raw.toLowerCase().split(/[-_]/)[0] ?? ''
  if (prefix === 'de') return 'de'
  if (prefix === 'fr') return 'fr'
  if (prefix === 'nl') return 'nl'
  return 'en'
}

export interface TranslationSet {
  sale: string
  left: string
  refillAt: (threshold: number) => string
  inMachine: string
  slot: string
  noStockInfo: string
  lowStockTitle: string
  remaining: string
  testMachine: string
  sampleProduct: string
  newDealsTitle: string
  newDealsBody: (count: number, retailers: string) => string
  machineOfflineTitle: string
  machineOfflineBody: (machine: string, duration: string) => string
  machineOnlineTitle: string
  machineOnlineBody: (machine: string, duration: string) => string
  unknownMachine: string
  emailOpen: string
  emailFooter: string
  emailManage: string
  testEmailTitle: string
  testEmailBody: string
  /** Unit for whole days in formatDuration (minutes and hours are "min"/"h" everywhere). */
  dayUnit: string
}

const en: TranslationSet = {
  sale: 'Sale',
  left: 'left',
  inMachine: 'in machine',
  slot: 'Slot',
  refillAt: (n) => `refill at ${n}`,
  noStockInfo: 'No stock info',
  lowStockTitle: 'Low Stock Alert',
  remaining: 'remaining',
  testMachine: 'Test Machine',
  sampleProduct: 'Sample Product',
  newDealsTitle: 'New deals',
  newDealsBody: (n, r) =>
    r
      ? `${n} new ${n === 1 ? 'deal' : 'deals'} — ${r}`
      : `${n} new ${n === 1 ? 'deal' : 'deals'}`,
  machineOfflineTitle: 'Machine offline',
  machineOfflineBody: (m, d) => `${m} has not been reachable for ${d}.`,
  machineOnlineTitle: 'Machine back online',
  machineOnlineBody: (m, d) => `${m} is reachable again after ${d} offline.`,
  unknownMachine: 'A machine',
  emailOpen: 'Open in VMflow',
  emailFooter: 'You are receiving this email because you turned on email for this notification in VMflow.',
  emailManage: 'Manage notifications',
  testEmailTitle: 'Test email',
  testEmailBody: 'Email notifications from VMflow reach you. You can choose per event which channels to use.',
  dayUnit: 'd',
}

const de: TranslationSet = {
  sale: 'Verkauf',
  left: 'übrig',
  inMachine: 'im Automaten',
  slot: 'Fach',
  refillAt: (n) => `nachfüllen bei ${n}`,
  noStockInfo: 'Kein Bestand',
  lowStockTitle: 'Bestandswarnung',
  remaining: 'übrig',
  testMachine: 'Testmaschine',
  sampleProduct: 'Beispielprodukt',
  newDealsTitle: 'Neue Angebote',
  newDealsBody: (n, r) =>
    r
      ? `${n} ${n === 1 ? 'neues Angebot' : 'neue Angebote'} — ${r}`
      : `${n} ${n === 1 ? 'neues Angebot' : 'neue Angebote'}`,
  machineOfflineTitle: 'Automat offline',
  machineOfflineBody: (m, d) => `${m} ist seit ${d} nicht erreichbar.`,
  machineOnlineTitle: 'Automat wieder online',
  machineOnlineBody: (m, d) => `${m} ist nach ${d} wieder erreichbar.`,
  unknownMachine: 'Ein Automat',
  emailOpen: 'In VMflow öffnen',
  emailFooter: 'Sie erhalten diese E-Mail, weil Sie für diese Benachrichtigung E-Mail in VMflow eingeschaltet haben.',
  emailManage: 'Benachrichtigungen verwalten',
  testEmailTitle: 'Test-E-Mail',
  testEmailBody: 'E-Mail-Benachrichtigungen von VMflow kommen bei Ihnen an. Pro Ereignis wählen Sie, über welche Kanäle Sie benachrichtigt werden.',
  dayUnit: 'Tg.',
}

const fr: TranslationSet = {
  sale: 'Vente',
  left: 'restant',
  inMachine: 'dans la machine',
  slot: 'Emplacement',
  refillAt: (n) => `réapprovisionner à ${n}`,
  noStockInfo: 'Aucune info de stock',
  lowStockTitle: 'Alerte stock bas',
  remaining: 'restant',
  testMachine: 'Machine de test',
  sampleProduct: 'Produit exemple',
  newDealsTitle: 'Nouvelles offres',
  newDealsBody: (n, r) =>
    r
      ? `${n} ${n === 1 ? 'nouvelle offre' : 'nouvelles offres'} — ${r}`
      : `${n} ${n === 1 ? 'nouvelle offre' : 'nouvelles offres'}`,
  machineOfflineTitle: 'Machine hors ligne',
  machineOfflineBody: (m, d) => `${m} est injoignable depuis ${d}.`,
  machineOnlineTitle: 'Machine de nouveau en ligne',
  machineOnlineBody: (m, d) => `${m} est de nouveau joignable après ${d} hors ligne.`,
  unknownMachine: 'Une machine',
  emailOpen: 'Ouvrir dans VMflow',
  emailFooter: 'Vous recevez cet e-mail car vous avez activé l’e-mail pour cette notification dans VMflow.',
  emailManage: 'Gérer les notifications',
  testEmailTitle: 'E-mail de test',
  testEmailBody: 'Les notifications par e-mail de VMflow vous parviennent. Vous pouvez choisir les canaux pour chaque événement.',
  dayUnit: 'j',
}

const nl: TranslationSet = {
  sale: 'Verkoop',
  left: 'over',
  inMachine: 'in automaat',
  slot: 'Vak',
  refillAt: (n) => `bijvullen bij ${n}`,
  noStockInfo: 'Geen voorraadinfo',
  lowStockTitle: 'Lage voorraad melding',
  remaining: 'over',
  testMachine: 'Testmachine',
  sampleProduct: 'Voorbeeldproduct',
  newDealsTitle: 'Nieuwe aanbiedingen',
  newDealsBody: (n, r) =>
    r
      ? `${n} nieuwe ${n === 1 ? 'aanbieding' : 'aanbiedingen'} — ${r}`
      : `${n} nieuwe ${n === 1 ? 'aanbieding' : 'aanbiedingen'}`,
  machineOfflineTitle: 'Automaat offline',
  machineOfflineBody: (m, d) => `${m} is al ${d} niet bereikbaar.`,
  machineOnlineTitle: 'Automaat weer online',
  machineOnlineBody: (m, d) => `${m} is na ${d} offline weer bereikbaar.`,
  unknownMachine: 'Een automaat',
  emailOpen: 'Openen in VMflow',
  emailFooter: 'Je ontvangt deze e-mail omdat je e-mail voor deze melding in VMflow hebt ingeschakeld.',
  emailManage: 'Meldingen beheren',
  testEmailTitle: 'Test-e-mail',
  testEmailBody: 'E-mailmeldingen van VMflow komen bij je aan. Per gebeurtenis kies je welke kanalen je gebruikt.',
  dayUnit: 'd',
}

export function t(locale: Locale): TranslationSet {
  if (locale === 'de') return de
  if (locale === 'fr') return fr
  if (locale === 'nl') return nl
  return en
}

/**
 * Locale-aware EUR currency formatting.
 *   en → '€2.50'   (en-GB style, symbol-first)
 *   de → '2,50 €'  (de-DE style, symbol-last with NBSP separator)
 *   fr → '2,50 €'  (fr-FR style, symbol-last with NBSP separator)
 *   nl → '€ 2,50'  (nl-BE style, symbol-first with NBSP separator)
 *
 * Callers embed the returned string directly in the notification body.
 */
export function formatPrice(amount: number, locale: Locale): string {
  const bcp47 = locale === 'de' ? 'de-DE' : locale === 'fr' ? 'fr-FR' : locale === 'nl' ? 'nl-BE' : 'en-GB'
  return new Intl.NumberFormat(bcp47, {
    style: 'currency',
    currency: 'EUR',
  }).format(amount)
}

/**
 * Short outage duration: "4 min", "2 h 5 min", "3 Tg. 4 h". Rounded to whole
 * minutes; anything under a minute reads as "1 min".
 */
export function formatDuration(minutes: number, locale: Locale): string {
  const m = Math.max(1, Math.round(minutes))
  if (m < 60) return `${m} min`
  const h = Math.floor(m / 60)
  if (h < 48) {
    const rest = m % 60
    return rest > 0 ? `${h} h ${rest} min` : `${h} h`
  }
  const d = Math.floor(h / 24)
  const restH = h % 24
  const unit = t(locale).dayUnit
  return restH > 0 ? `${d} ${unit} ${restH} h` : `${d} ${unit}`
}
