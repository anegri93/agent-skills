#!/usr/bin/env bash
set -euo pipefail

NAME="${1:-}"
if [[ -z "$NAME" ]]; then
  echo "Usage: create-new-project.sh <project-name>"
  exit 1
fi

PM="${PM:-pnpm}" # env override: PM=npm
USE_SUPABASE_LOCAL="${USE_SUPABASE_LOCAL:-true}" # true|false
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

command -v node >/dev/null || { echo "Missing: node"; exit 1; }
command -v git >/dev/null || { echo "Missing: git"; exit 1; }

if [[ "$PM" == "pnpm" ]]; then
  command -v pnpm >/dev/null || { echo "Missing: pnpm"; exit 1; }
fi

echo "==> Creating Next.js app: $NAME"
if [[ "$PM" == "pnpm" ]]; then
  npx create-next-app@latest "$NAME" --ts --eslint --tailwind --app --src-dir --import-alias "@/*" --use-pnpm
else
  npx create-next-app@latest "$NAME" --ts --eslint --tailwind --app --src-dir --import-alias "@/*"
fi

cd "$NAME"

echo "==> Installing base deps"
if [[ "$PM" == "pnpm" ]]; then
  pnpm add @supabase/supabase-js @supabase/ssr zod react-hook-form @hookform/resolvers lucide-react
  pnpm add -D prettier prettier-plugin-tailwindcss
else
  npm i @supabase/supabase-js @supabase/ssr zod react-hook-form @hookform/resolvers lucide-react
  npm i -D prettier prettier-plugin-tailwindcss
fi

echo "==> Init shadcn/ui"
# Official flow supports pnpm dlx / npx for init. Keep interactive to avoid CLI flag drift.
if [[ "$PM" == "pnpm" ]]; then
  pnpm dlx shadcn@latest init
else
  npx shadcn@latest init
fi

echo "==> Creating Supabase helpers"
mkdir -p src/lib/supabase

cat > src/lib/supabase/browser.ts <<'EOF'
import { createBrowserClient } from "@supabase/ssr";

export function createSupabaseBrowserClient() {
  const url = process.env.NEXT_PUBLIC_SUPABASE_URL!;
  const anon = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!;
  return createBrowserClient(url, anon);
}
EOF

cat > src/lib/supabase/server.ts <<'EOF'
import { cookies } from "next/headers";
import { createServerClient } from "@supabase/ssr";

export function createSupabaseServerClient() {
  const cookieStore = cookies();
  const url = process.env.NEXT_PUBLIC_SUPABASE_URL!;
  const anon = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!;

  return createServerClient(url, anon, {
    cookies: {
      getAll() {
        return cookieStore.getAll();
      },
      setAll(cookiesToSet) {
        try {
          cookiesToSet.forEach(({ name, value, options }) => {
            cookieStore.set(name, value, options);
          });
        } catch {
          // In Server Components, set can fail; middleware handles refresh.
        }
      },
    },
  });
}
EOF

cat > src/lib/supabase/middleware.ts <<'EOF'
import { NextResponse, type NextRequest } from "next/server";
import { createServerClient } from "@supabase/ssr";

export async function updateSession(request: NextRequest) {
  let response = NextResponse.next({ request });

  const url = process.env.NEXT_PUBLIC_SUPABASE_URL!;
  const anon = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!;

  const supabase = createServerClient(url, anon, {
    cookies: {
      getAll() {
        return request.cookies.getAll();
      },
      setAll(cookiesToSet) {
        cookiesToSet.forEach(({ name, value }) => request.cookies.set(name, value));
        response = NextResponse.next({ request });
        cookiesToSet.forEach(({ name, value, options }) =>
          response.cookies.set(name, value, options)
        );
      },
    },
  });

  await supabase.auth.getUser();
  return response;
}
EOF

cat > middleware.ts <<'EOF'
import { updateSession } from "@/lib/supabase/middleware";
import type { NextRequest } from "next/server";

export async function middleware(request: NextRequest) {
  return updateSession(request);
}

export const config = {
  matcher: [
    /*
      Skip Next.js internals and static files.
    */
    "/((?!_next/static|_next/image|favicon.ico).*)",
  ],
};
EOF

echo "==> Env templates"
cat > .env.example <<'EOF'
NEXT_PUBLIC_SUPABASE_URL=
NEXT_PUBLIC_SUPABASE_ANON_KEY=
SUPABASE_SERVICE_ROLE_KEY=
EOF

# Create a blank .env.local if not present (user fills it)
if [[ ! -f .env.local ]]; then
  cp .env.example .env.local
fi

echo "==> API route examples"
mkdir -p src/app/api/v1/orders
cat > src/app/api/v1/orders/route.ts <<'EOF'
import { NextResponse } from "next/server";
import { z } from "zod";
import { createSupabaseServerClient } from "@/lib/supabase/server";

const CreateOrder = z.object({
  customer_id: z.string().uuid().optional(),
  notes: z.string().optional(),
});

export async function GET() {
  const supabase = createSupabaseServerClient();
  const { data, error } = await supabase.from("orders").select("*").order("created_at", { ascending: false }).limit(50);
  if (error) return NextResponse.json({ error: error.message }, { status: 500 });
  return NextResponse.json({ data });
}

export async function POST(req: Request) {
  const body = await req.json().catch(() => ({}));
  const parsed = CreateOrder.safeParse(body);
  if (!parsed.success) return NextResponse.json({ error: parsed.error.flatten() }, { status: 400 });

  const supabase = createSupabaseServerClient();
  const { data, error } = await supabase.from("orders").insert({
    customer_id: parsed.data.customer_id ?? null,
    notes: parsed.data.notes ?? null,
    status: "draft",
    currency: "PYG",
    total_cents: 0,
  }).select("*").single();

  if (error) return NextResponse.json({ error: error.message }, { status: 500 });
  return NextResponse.json({ data }, { status: 201 });
}
EOF

mkdir -p src/app/api/v1/public/orders
cat > src/app/api/v1/public/orders/route.ts <<'EOF'
import { NextResponse } from "next/server";
import { z } from "zod";
import crypto from "crypto";
import { createClient } from "@supabase/supabase-js";

/**
 * Public API: third parties can create orders.
 * Auth: X-API-Key (we compare SHA-256 hash against api_keys.key_hash)
 */
const PublicCreateOrder = z.object({
  org_id: z.string().uuid(),
  customer: z.object({
    name: z.string().min(1),
    email: z.string().email().optional(),
    phone: z.string().optional(),
  }),
  items: z.array(z.object({
    sku: z.string().min(1),
    name: z.string().min(1),
    qty: z.number().int().positive(),
    unit_price_cents: z.number().int().nonnegative(),
  })).min(1),
  notes: z.string().optional(),
});

function sha256(input: string) {
  return crypto.createHash("sha256").update(input).digest("hex");
}

export async function POST(req: Request) {
  const apiKey = req.headers.get("x-api-key") || "";
  if (!apiKey) return NextResponse.json({ error: "Missing X-API-Key" }, { status: 401 });

  const body = await req.json().catch(() => ({}));
  const parsed = PublicCreateOrder.safeParse(body);
  if (!parsed.success) return NextResponse.json({ error: parsed.error.flatten() }, { status: 400 });

  const url = process.env.NEXT_PUBLIC_SUPABASE_URL!;
  const serviceRole = process.env.SUPABASE_SERVICE_ROLE_KEY!;
  const supabase = createClient(url, serviceRole, { auth: { persistSession: false } });

  const keyHash = sha256(apiKey);

  const { data: keyRow, error: keyErr } = await supabase
    .from("api_keys")
    .select("id, org_id, revoked_at")
    .eq("org_id", parsed.data.org_id)
    .eq("key_hash", keyHash)
    .maybeSingle();

  if (keyErr) return NextResponse.json({ error: keyErr.message }, { status: 500 });
  if (!keyRow || keyRow.revoked_at) return NextResponse.json({ error: "Invalid API key" }, { status: 403 });

  // Upsert customer
  const { data: cust, error: custErr } = await supabase
    .from("customers")
    .insert({
      org_id: parsed.data.org_id,
      name: parsed.data.customer.name,
      email: parsed.data.customer.email ?? null,
      phone: parsed.data.customer.phone ?? null,
    })
    .select("*")
    .single();

  if (custErr) return NextResponse.json({ error: custErr.message }, { status: 500 });

  // Create order
  const total = parsed.data.items.reduce((sum, it) => sum + it.qty * it.unit_price_cents, 0);

  const { data: order, error: orderErr } = await supabase
    .from("orders")
    .insert({
      org_id: parsed.data.org_id,
      customer_id: cust.id,
      status: "confirmed",
      notes: parsed.data.notes ?? null,
      total_cents: total,
      currency: "PYG",
    })
    .select("*")
    .single();

  if (orderErr) return NextResponse.json({ error: orderErr.message }, { status: 500 });

  // Insert items
  const { error: itemsErr } = await supabase.from("order_items").insert(
    parsed.data.items.map((it) => ({
      org_id: parsed.data.org_id,
      order_id: order.id,
      product_id: null,
      sku: it.sku,
      name: it.name,
      qty: it.qty,
      unit_price_cents: it.unit_price_cents,
      line_total_cents: it.qty * it.unit_price_cents,
    }))
  );

  if (itemsErr) return NextResponse.json({ error: itemsErr.message }, { status: 500 });

  return NextResponse.json({ data: { order_id: order.id } }, { status: 201 });
}
EOF

if command -v supabase >/dev/null && [[ "$USE_SUPABASE_LOCAL" == "true" ]]; then
  echo "==> Supabase local init"
  supabase init || true
  # Create a migration file with baseline schema
  supabase migration new init_orders || true

  # Try to copy schema into latest migration file
  MIG="$(ls -1 supabase/migrations/*_init_orders.sql 2>/dev/null | tail -n 1 || true)"
  if [[ -n "$MIG" && -f "$MIG" ]]; then
    cat > "$MIG" <<'EOF'
-- Baseline schema
EOF
    cat "${SKILL_DIR}/references/DB_SCHEMA.sql" >> "$MIG" 2>/dev/null || true
  fi
else
  echo "==> Supabase CLI not found or disabled. Skipping supabase init."
fi

echo
echo "✅ Done."
echo "Next:"
echo "  1) Fill .env.local with Supabase keys"
echo "  2) Run: $PM dev"
echo "  3) If using Supabase local: supabase start"
