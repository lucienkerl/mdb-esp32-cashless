import { describe, it, expect } from 'vitest'
import {
  splitList,
  buildAppleAppSiteAssociation,
  normalizeFingerprint,
  buildAssetLinks,
} from '../appAssociation'

const FP = '14:6D:E9:83:C5:73:06:50:D8:EE:B9:95:2F:34:FC:64:16:A0:83:42:E6:1D:BE:A8:8A:04:96:B2:3F:CF:44:E5'

describe('splitList', () => {
  it('splits on commas and whitespace and drops empties', () => {
    expect(splitList(' a, b\nc,,  ')).toEqual(['a', 'b', 'c'])
    expect(splitList(undefined)).toEqual([])
    expect(splitList('')).toEqual([])
  })
})

describe('buildAppleAppSiteAssociation', () => {
  it('lists the app ids under webcredentials', () => {
    expect(buildAppleAppSiteAssociation(['4JT3V7XVXM.de.kerl-handel.app'])).toEqual({
      webcredentials: { apps: ['4JT3V7XVXM.de.kerl-handel.app'] },
    })
  })

  it('drops ids without a team prefix and returns null when none remain', () => {
    expect(buildAppleAppSiteAssociation(['de.kerl-handel.app'])).toBeNull()
    expect(buildAppleAppSiteAssociation([])).toBeNull()
  })
})

describe('normalizeFingerprint', () => {
  it('accepts the Play Console format and plain hex', () => {
    expect(normalizeFingerprint(FP)).toBe(FP)
    expect(normalizeFingerprint(FP.replace(/:/g, '').toLowerCase())).toBe(FP)
  })

  it('rejects anything that is not 32 bytes', () => {
    expect(normalizeFingerprint('AB:CD')).toBeNull()
    expect(normalizeFingerprint(FP + ':00')).toBeNull()
  })
})

describe('buildAssetLinks', () => {
  it('grants get_login_creds to the package with its certificates', () => {
    expect(buildAssetLinks('de.kerlhandel.app', [FP, FP.toLowerCase()])).toEqual([
      {
        relation: ['delegate_permission/common.get_login_creds'],
        target: {
          namespace: 'android_app',
          package_name: 'de.kerlhandel.app',
          sha256_cert_fingerprints: [FP],
        },
      },
    ])
  })

  it('returns null without a package or a valid fingerprint', () => {
    expect(buildAssetLinks('', [FP])).toBeNull()
    expect(buildAssetLinks('de.kerlhandel.app', ['nope'])).toBeNull()
  })
})
