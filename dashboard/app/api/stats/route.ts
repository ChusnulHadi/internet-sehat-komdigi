export async function GET() {
  const base = process.env.DNSDIST_URL ?? 'http://127.0.0.1:8083'
  const key = process.env.DNSDIST_API_KEY ?? process.env.DNSDIST_DASHBOARD_API_KEY ?? ''

  try {
    const res = await fetch(`${base}/api/v1/servers/localhost`, {
      headers: { 'X-API-Key': key },
      cache: 'no-store',
    })

    if (!res.ok) {
      const text = await res.text().catch(() => '')
      return Response.json({ error: `dnsdist HTTP ${res.status}: ${text}` }, { status: 502 })
    }

    return Response.json(await res.json())
  } catch {
    return Response.json({ error: 'dnsdist tidak dapat dijangkau' }, { status: 503 })
  }
}
