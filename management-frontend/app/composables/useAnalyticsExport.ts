function escapeCell(value: unknown): string {
  if (value == null) return ''
  if (typeof value === 'number') return String(value).replace('.', ',')
  const s = String(value)
  if (/[;"\n]/.test(s)) return '"' + s.replace(/"/g, '""') + '"'
  return s
}

export function rowsToCsv(rows: Record<string, unknown>[], columns: string[]): string {
  const header = columns.join(';')
  const body = rows.map(r => columns.map(c => escapeCell(r[c])).join(';')).join('\n')
  return '﻿' + header + '\n' + body
}

export function useAnalyticsExport() {
  function download(filename: string, content: string, mime = 'text/csv;charset=utf-8') {
    if (!import.meta.client) return
    const blob = new Blob([content], { type: mime })
    const url = URL.createObjectURL(blob)
    const a = document.createElement('a')
    a.href = url
    a.download = filename
    a.click()
    URL.revokeObjectURL(url)
  }
  return { rowsToCsv, download }
}
