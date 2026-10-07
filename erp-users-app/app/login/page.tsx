import Link from "next/link";
import AuthForm from "@/components/AuthForm";
import { login } from "../actions";

export default function LoginPage() {
  return (
    <main>
      <h1>Log in</h1>
      <AuthForm action={login} label="Log in" />
      <p>No account? <Link href="/register">Register</Link></p>
    </main>
  );
}
