"use server";

import bcrypt from "bcryptjs";
import { AuthError } from "next-auth";
import { redirect } from "next/navigation";
import { revalidatePath } from "next/cache";
import { auth, signIn, signOut } from "@/auth";
import { prisma } from "@/lib/prisma";

export type FormState = { error?: string } | undefined;

const clean = (v: FormDataEntryValue | null) => String(v ?? "").trim();

async function currentUserId() {
  const s = await auth();
  const id = (s?.user as { id?: string } | undefined)?.id;
  if (!id) redirect("/login");
  return id;
}

// CREATE
export async function register(_: FormState, fd: FormData): Promise<FormState> {
  const name = clean(fd.get("name"));
  const email = clean(fd.get("email")).toLowerCase();
  const password = String(fd.get("password") ?? "");
  if (!name || !/^\S+@\S+\.\S+$/.test(email) || password.length < 8)
    return { error: "Enter a name, a valid email and a password of 8+ characters." };
  if (await prisma.user.findUnique({ where: { email } }))
    return { error: "This email is already registered." };
  await prisma.user.create({
    data: { name, email, passwordHash: await bcrypt.hash(password, 12) },
  });
  await signIn("credentials", { email, password, redirectTo: "/dashboard" });
}

export async function login(_: FormState, fd: FormData): Promise<FormState> {
  try {
    await signIn("credentials", {
      email: clean(fd.get("email")).toLowerCase(),
      password: String(fd.get("password") ?? ""),
      redirectTo: "/dashboard",
    });
  } catch (e) {
    if (e instanceof AuthError) return { error: "Invalid email or password." };
    throw e; // lets the redirect through
  }
}

export async function logout() {
  await signOut({ redirectTo: "/login" });
}

// UPDATE (own name only)
export async function updateName(fd: FormData) {
  const id = await currentUserId();
  const name = clean(fd.get("name"));
  if (!name) return;
  await prisma.user.update({ where: { id }, data: { name } });
  revalidatePath("/dashboard");
}

// DELETE (own account only)
export async function deleteAccount() {
  const id = await currentUserId();
  await prisma.user.delete({ where: { id } });
  await signOut({ redirectTo: "/register" });
}
