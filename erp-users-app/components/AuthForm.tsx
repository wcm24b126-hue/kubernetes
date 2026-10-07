"use client";

import { useFormState, useFormStatus } from "react-dom";
import type { FormState } from "@/app/actions";

function Submit({ label }: { label: string }) {
  const { pending } = useFormStatus();
  return <button disabled={pending}>{pending ? "Please wait..." : label}</button>;
}

export default function AuthForm({
  action, label, withName,
}: {
  action: (s: FormState, f: FormData) => Promise<FormState>;
  label: string;
  withName?: boolean;
}) {
  const [state, formAction] = useFormState(action, undefined);
  return (
    <form action={formAction} className="card col">
      {withName && <input name="name" placeholder="Full name" required />}
      <input name="email" type="email" placeholder="Email" required />
      <input name="password" type="password" placeholder="Password (8+ characters)" minLength={8} required />
      {state?.error && <p className="err">{state.error}</p>}
      <Submit label={label} />
    </form>
  );
}
