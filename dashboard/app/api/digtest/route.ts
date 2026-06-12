import { Resolver } from "node:dns/promises";

// Jalankan di Node runtime (butuh modul dns), jangan di-cache.
export const runtime = "nodejs";
export const dynamic = "force-dynamic";

type Expect = "allow" | "block";

interface Target {
  label: string;
  domain: string;
  category: string;
  expect: Expect;
}

// Daftar uji: bank Himbara & medsos harus LOLOS, situs porno harus TERBLOKIR.
const TARGETS: Target[] = [
  { label: "BRI", domain: "bri.co.id", category: "Bank Himbara", expect: "allow" },
  { label: "Mandiri", domain: "bankmandiri.co.id", category: "Bank Himbara", expect: "allow" },
  { label: "BNI", domain: "bni.co.id", category: "Bank Himbara", expect: "allow" },
  { label: "BTN", domain: "btn.co.id", category: "Bank Himbara", expect: "allow" },
  { label: "YouTube", domain: "youtube.com", category: "Media Sosial", expect: "allow" },
  { label: "TikTok", domain: "tiktok.com", category: "Media Sosial", expect: "allow" },
  { label: "Facebook", domain: "facebook.com", category: "Media Sosial", expect: "allow" },
  { label: "Pornhub", domain: "pornhub.com", category: "Situs Porno", expect: "block" },
  { label: "Xvideos", domain: "xvideos.com", category: "Situs Porno", expect: "block" },
];

interface DigResult extends Target {
  status: "allowed" | "blocked" | "error";
  addresses: string[];
  ms: number;
  pass: boolean;
  note?: string;
}

async function lookup(
  t: Target,
  resolverAddr: string,
  redirectIp: string,
): Promise<DigResult> {
  const resolver = new Resolver({ timeout: 3000, tries: 1 });
  resolver.setServers([resolverAddr]);

  const t0 = performance.now();
  try {
    const addresses = await resolver.resolve4(t.domain);
    const ms = Math.round(performance.now() - t0);

    // Mode redirect: domain terblokir di-arahkan ke REDIRECT_IP (mis. 0.0.0.0).
    const redirected =
      addresses.length > 0 && addresses.every((a) => a === redirectIp);
    const status: DigResult["status"] =
      addresses.length === 0 || redirected ? "blocked" : "allowed";

    return {
      ...t,
      status,
      addresses,
      ms,
      pass: matchExpect(status, t.expect),
    };
  } catch (e) {
    const ms = Math.round(performance.now() - t0);
    const code = (e as NodeJS.ErrnoException)?.code ?? "ERR";

    // NXDOMAIN / tanpa jawaban = terblokir (mode nxdomain).
    if (["ENOTFOUND", "ENODATA", "NOTFOUND", "NXDOMAIN"].includes(code)) {
      return {
        ...t,
        status: "blocked",
        addresses: [],
        ms,
        pass: matchExpect("blocked", t.expect),
        note: code,
      };
    }

    // Timeout / resolver mati / error lain → tidak bisa dinilai.
    return {
      ...t,
      status: "error",
      addresses: [],
      ms,
      pass: false,
      note: code,
    };
  }
}

function matchExpect(status: DigResult["status"], expect: Expect): boolean {
  if (status === "error") return false;
  return expect === "allow" ? status === "allowed" : status === "blocked";
}

export async function GET() {
  const resolverAddr = process.env.DIGTEST_RESOLVER ?? "127.0.0.1";
  const redirectIp = process.env.DNSDIST_REDIRECT_IP ?? "0.0.0.0";

  const results = await Promise.all(
    TARGETS.map((t) => lookup(t, resolverAddr, redirectIp)),
  );

  return Response.json({ results, resolver: resolverAddr });
}
