import Link from "next/link";
import AuthForm from "@/components/AuthForm";
import { register } from "../actions";

export default function RegisterPage() {
  return (
    <main>
      <h1>Create an account</h1>
      <AuthForm action={register} label="Register" withName />
      <p>Already registered? <Link href="/login">Log in</Link></p>
    </main>
  );
}
