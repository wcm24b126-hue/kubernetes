import { redirect } from "next/navigation";
import { auth } from "@/auth";
import { prisma } from "@/lib/prisma";
import { logout, updateName, deleteAccount } from "../actions";

export const dynamic = "force-dynamic";

export default async function Dashboard() {
  const session = await auth();
  const meId = (session?.user as { id?: string } | undefined)?.id;
  if (!meId) redirect("/login");

  // READ: never select passwordHash
  const users = await prisma.user.findMany({
    select: { id: true, name: true, email: true, createdAt: true },
    orderBy: { createdAt: "desc" },
  });
  const me = users.find((u) => u.id === meId);
  if (!me) redirect("/login");

  return (
    <main>
      <div className="bar">
        <h1>Dashboard</h1>
        <form action={logout}><button>Log out</button></form>
      </div>
      <p>Signed in as <b>{me.email}</b></p>

      <section className="card">
        <h2>Update your name</h2>
        <form action={updateName} className="row">
          <input name="name" defaultValue={me.name} required />
          <button>Save</button>
        </form>
      </section>

      <section className="card">
        <h2>Registered users ({users.length})</h2>
        <table>
          <thead><tr><th>Name</th><th>Email</th><th>Registered</th></tr></thead>
          <tbody>
            {users.map((u) => (
              <tr key={u.id}>
                <td>{u.name}{u.id === meId ? " (you)" : ""}</td>
                <td>{u.email}</td>
                <td>{u.createdAt.toISOString().slice(0, 10)}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </section>

      <section className="card danger">
        <h2>Delete my account</h2>
        <form action={deleteAccount}><button>Delete account</button></form>
      </section>
    </main>
  );
}
