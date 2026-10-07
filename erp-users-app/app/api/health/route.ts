import { prisma } from "@/lib/prisma";

export const dynamic = "force-dynamic";

export async function GET() {
  const started = Date.now();
  let db: "ok" | "error" = "ok";
  try {
    await prisma.$queryRaw`SELECT 1`;
  } catch {
    db = "error";
  }
  return Response.json(
    {
      status: db === "ok" ? "ok" : "degraded",
      db,
      latencyMs: Date.now() - started,
      time: new Date().toISOString(),
    },
    {
      status: db === "ok" ? 200 : 503,
      headers: { "cache-control": "no-store" },
    }
  );
}
