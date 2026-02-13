param(
  [Parameter(Mandatory=$true)]
  [string]$Name
)

$PM = $env:PM
if (-not $PM) { $PM = "pnpm" }

Write-Host "==> Creating Next.js app: $Name"

# Requires Node + Git
node -v *> $null
if ($LASTEXITCODE -ne 0) { throw "Missing: node" }
git --version *> $null
if ($LASTEXITCODE -ne 0) { throw "Missing: git" }

if ($PM -eq "pnpm") {
  pnpm -v *> $null
  if ($LASTEXITCODE -ne 0) { throw "Missing: pnpm" }
  npx create-next-app@latest $Name --ts --eslint --tailwind --app --src-dir --import-alias "@/*" --use-pnpm
} else {
  npx create-next-app@latest $Name --ts --eslint --tailwind --app --src-dir --import-alias "@/*"
}

Set-Location $Name

Write-Host "==> Installing base deps"
if ($PM -eq "pnpm") {
  pnpm add @supabase/supabase-js @supabase/ssr zod react-hook-form @hookform/resolvers lucide-react
  pnpm add -D prettier prettier-plugin-tailwindcss
  pnpm dlx shadcn@latest init
} else {
  npm i @supabase/supabase-js @supabase/ssr zod react-hook-form @hookform/resolvers lucide-react
  npm i -D prettier prettier-plugin-tailwindcss
  npx shadcn@latest init
}

New-Item -ItemType Directory -Force -Path "src/lib/supabase" | Out-Null

@'
import { createBrowserClient } from "@supabase/ssr";

export function createSupabaseBrowserClient() {
  const url = process.env.NEXT_PUBLIC_SUPABASE_URL!;
  const anon = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!;
  return createBrowserClient(url, anon);
}
'@ | Set-Content -Encoding UTF8 "src/lib/supabase/browser.ts"

@'
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
        } catch {}
      },
    },
  });
}
'@ | Set-Content -Encoding UTF8 "src/lib/supabase/server.ts"

@'
NEXT_PUBLIC_SUPABASE_URL=
NEXT_PUBLIC_SUPABASE_ANON_KEY=
SUPABASE_SERVICE_ROLE_KEY=
'@ | Set-Content -Encoding UTF8 ".env.example"

if (-not (Test-Path ".env.local")) {
  Copy-Item ".env.example" ".env.local"
}

Write-Host "✅ Done. Next: fill .env.local and run `$PM dev`"
