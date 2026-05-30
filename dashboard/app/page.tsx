"use client";

import { useCallback, useEffect, useRef, useState, useTransition } from "react";
import {
  CartesianGrid,
  Line,
  LineChart,
  ResponsiveContainer,
  Tooltip,
  XAxis,
  YAxis,
} from "recharts";
import { Badge } from "@/components/ui/badge";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { AnyRecord } from "node:dns";

// ── Types ────────────────────────────────────────────────────────

interface UpstreamServer {
  name: string;
  address: string;
  state: string;
  queries: number;
  drops: number;
  latency: number;
}

interface Snapshot {
  queries: number;
  blocked: number;
  cacheHits: number;
  cacheMisses: number;
  latency: number;
  uptime: number;
  memory: number;
  servers: UpstreamServer[];
}

interface DataPoint {
  time: string;
  qps: number;
  blockedPerSec: number;
}

// ── Helpers ──────────────────────────────────────────────────────

// dnsdist 1.9.x puts all stats flat at the root level
function getStat(data: Record<string, unknown>, key: string): number {
  const val = (data as Record<string, Record<string, unknown>>)[
    "statistics" as string
  ][key]!;
  return typeof val === "number" ? val : 0;
}

function parseSnapshot(data: Record<string, unknown>): Snapshot {
  const servers = ((data.servers ?? []) as UpstreamServer[]).map((s) => ({
    name: s.name || s.address,
    address: s.address,
    state: s.state ?? "unknown",
    queries: s.queries ?? 0,
    drops: s.drops ?? 0,
    latency: s.latency ?? 0,
  }));

  return {
    queries: getStat(data, "queries"),
    blocked: getStat(data, "rule-nxdomain") + getStat(data, "rule-drop"),
    cacheHits: getStat(data, "cache-hits"),
    cacheMisses: getStat(data, "cache-misses"),
    latency: getStat(data, "latency-avg100") / 1000,
    uptime: getStat(data, "uptime"),
    memory: getStat(data, "real-memory-usage"),
    servers,
  };
}

function formatUptime(s: number): string {
  if (s < 60) return `${s}s`;
  if (s < 3600) return `${Math.floor(s / 60)}m`;
  if (s < 86400)
    return `${Math.floor(s / 3600)}h ${Math.floor((s % 3600) / 60)}m`;
  return `${Math.floor(s / 86400)}d ${Math.floor((s % 86400) / 3600)}h`;
}

function formatBytes(b: number): string {
  if (b < 1048576) return `${(b / 1024).toFixed(0)} KB`;
  return `${(b / 1048576).toFixed(1)} MB`;
}

function timeLabel(): string {
  return new Date().toTimeString().slice(0, 8);
}

// ── Constants ────────────────────────────────────────────────────

const POLL_MS = 5_000;
const MAX_PTS = 30;
const INTERVAL_S = POLL_MS / 1000;

// ── Page ─────────────────────────────────────────────────────────

export default function Dashboard() {
  const [snap, setSnap] = useState<Snapshot | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [points, setPoints] = useState<DataPoint[]>([]);
  const prev = useRef<{ queries: number; blocked: number } | null>(null);
  const [, startTransition] = useTransition();

  const fetchStats = useCallback(async () => {
    try {
      const res = await fetch("/api/stats");
      const data: Record<string, unknown> = await res.json();

      if (!res.ok || data.error) {
        setError(String(data.error ?? `HTTP ${res.status}`));
        return;
      }

      const next = parseSnapshot(data);
      setSnap(next);
      setError(null);

      if (prev.current) {
        const qps =
          Math.max(0, next.queries - prev.current.queries) / INTERVAL_S;
        const bps =
          Math.max(0, next.blocked - prev.current.blocked) / INTERVAL_S;
        setPoints((pts) => [
          ...pts.slice(-(MAX_PTS - 1)),
          {
            time: timeLabel(),
            qps: Math.round(qps * 10) / 10,
            blockedPerSec: Math.round(bps * 10) / 10,
          },
        ]);
      }

      prev.current = { queries: next.queries, blocked: next.blocked };
    } catch {
      setError("Tidak dapat terhubung ke dnsdist");
    }
  }, []);

  useEffect(() => {
    const id = setInterval(() => startTransition(() => fetchStats()), POLL_MS);
    return () => clearInterval(id);
  }, [fetchStats, startTransition, snap]);

  const cacheTotal = (snap?.cacheHits ?? 0) + (snap?.cacheMisses ?? 0);
  const cacheHitRate =
    cacheTotal > 0
      ? `${((snap!.cacheHits / cacheTotal) * 100).toFixed(1)}%`
      : "—";

  return (
    <div className="min-h-screen bg-background p-6 font-mono">
      {/* Header */}
      <div className="mb-6 flex items-start justify-between">
        <div>
          <h1 className="text-base font-semibold">internet-sehat DNS</h1>
          <p className="text-xs text-muted-foreground">
            dashboard · refresh {POLL_MS / 1000}s
          </p>
        </div>
        <div className="flex items-center gap-3 text-xs text-muted-foreground">
          {snap && (
            <>
              <span>up {formatUptime(snap.uptime)}</span>
              <span>·</span>
              <span>{formatBytes(snap.memory)}</span>
            </>
          )}
          <Badge variant={error ? "destructive" : "default"}>
            {error ? "error" : "live"}
          </Badge>
        </div>
      </div>

      {/* Error banner */}
      {error && (
        <div className="mb-4 border border-destructive/30 bg-destructive/10 px-4 py-2 text-xs text-destructive">
          {error}
        </div>
      )}

      {/* Stat cards */}
      <div className="mb-4 grid grid-cols-2 gap-3 sm:grid-cols-4">
        <StatCard
          title="Total Queries"
          value={snap?.queries.toLocaleString() ?? "—"}
        />
        <StatCard
          title="Blocked"
          value={snap?.blocked.toLocaleString() ?? "—"}
        />
        <StatCard title="Cache Hit" value={snap ? cacheHitRate : "—"} />
        <StatCard
          title="Avg Latency"
          value={snap ? `${snap.latency.toFixed(1)} ms` : "—"}
        />
      </div>

      {/* Chart */}
      <Card className="mb-4">
        <CardHeader>
          <CardTitle>Query rate (per detik)</CardTitle>
        </CardHeader>
        <CardContent>
          {points.length < 2 ? (
            <div className="flex h-40 items-center justify-center text-xs text-muted-foreground">
              Mengumpulkan data...
            </div>
          ) : (
            <ResponsiveContainer width="100%" height={160}>
              <LineChart
                data={points}
                margin={{ top: 4, right: 8, bottom: 0, left: 0 }}
              >
                <CartesianGrid strokeDasharray="3 3" stroke="var(--border)" />
                <XAxis
                  dataKey="time"
                  tick={{ fontSize: 10, fontFamily: "monospace" }}
                  interval="preserveStartEnd"
                />
                <YAxis
                  tick={{ fontSize: 10 }}
                  width={32}
                  allowDecimals={false}
                />
                <Tooltip
                  contentStyle={{ fontSize: 11, fontFamily: "monospace" }}
                />
                <Line
                  type="monotone"
                  dataKey="qps"
                  name="QPS"
                  stroke="var(--color-chart-2)"
                  dot={false}
                  strokeWidth={1.5}
                />
                <Line
                  type="monotone"
                  dataKey="blockedPerSec"
                  name="Blocked/s"
                  stroke="var(--color-chart-1)"
                  dot={false}
                  strokeWidth={1.5}
                />
              </LineChart>
            </ResponsiveContainer>
          )}
        </CardContent>
      </Card>

      {/* Upstream servers */}
      <Card>
        <CardHeader>
          <CardTitle>Upstream Servers</CardTitle>
        </CardHeader>
        <CardContent>
          {!snap?.servers.length ? (
            <p className="text-xs text-muted-foreground">Tidak ada data</p>
          ) : (
            <table className="w-full text-xs">
              <thead>
                <tr className="border-b text-left text-muted-foreground">
                  <th className="pb-2 pr-4 font-normal">Server</th>
                  <th className="pb-2 pr-4 font-normal">Status</th>
                  <th className="pb-2 pr-4 font-normal">Queries</th>
                  <th className="pb-2 pr-4 font-normal">Drops</th>
                  <th className="pb-2 font-normal">Latency</th>
                </tr>
              </thead>
              <tbody>
                {snap.servers.map((s) => (
                  <tr key={s.address} className="border-b last:border-0">
                    <td className="py-2 pr-4">
                      <div>{s.name}</div>
                      <div className="text-muted-foreground">{s.address}</div>
                    </td>
                    <td className="py-2 pr-4">
                      <Badge
                        variant={s.state === "up" ? "default" : "destructive"}
                      >
                        {s.state}
                      </Badge>
                    </td>
                    <td className="py-2 pr-4 tabular-nums">
                      {s.queries.toLocaleString()}
                    </td>
                    <td className="py-2 pr-4 tabular-nums">
                      {s.drops.toLocaleString()}
                    </td>
                    <td className="py-2 tabular-nums">
                      {s.latency.toFixed(1)} ms
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          )}
        </CardContent>
      </Card>
    </div>
  );
}

// ── Sub-components ───────────────────────────────────────────────

function StatCard({ title, value }: { title: string; value: string }) {
  return (
    <Card size="sm">
      <CardHeader>
        <CardTitle className="text-muted-foreground">{title}</CardTitle>
      </CardHeader>
      <CardContent>
        <p className="text-2xl font-semibold tabular-nums">{value}</p>
      </CardContent>
    </Card>
  );
}
