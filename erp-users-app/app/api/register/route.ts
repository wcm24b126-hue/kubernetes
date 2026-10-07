import { NextResponse } from "next/server";
import bcrypt from "bcryptjs";
import { prisma } from "@/lib/prisma";

export async function POST(req: Request) {
  let body: unknown;
  try {
    body = await req.json();
  } catch {
    return NextResponse.json({ error: "Invalid JSON body." }, { status: 400 });
  }

  const b = (body ?? {}) as { name?: unknown; email?: unknown; password?: unknown };
  const name = String(b.name ?? "").trim();
  const email = String(b.email ?? "").toLowerCase().trim();
  const password = String(b.password ?? "");

  if (!name || !/^\S+@\S+\.\S+$/.test(email) || password.length < 8) {
    return NextResponse.json(
      { error: "Enter a name, a valid email and a password of 8+ characters." },
      { status: 400 }
    );
  }

  if (await prisma.user.findUnique({ where: { email } })) {
    return NextResponse.json({ error: "This email is already registered." }, { status: 409 });
  }

  const user = await prisma.user.create({
    data: { name, email, passwordHash: await bcrypt.hash(password, 12) },
  });

  return NextResponse.json(
    { id: user.id, name: user.name, email: user.email },
    { status: 201 }
  );
}
