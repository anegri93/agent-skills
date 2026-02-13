# Stack estándar (Next.js + Supabase + Vercel)

## Frontend
- Next.js (App Router) + React + TypeScript
- Tailwind CSS + shadcn/ui para UI consistente y rápida de iterar

## Backend (cómo "funciona")
En este stack, el "backend" principal vive dentro de Next.js en Vercel:

1) **API Routes / Route Handlers (Next.js)**
   - Carpeta: `src/app/api/**`
   - Son endpoints HTTP (REST) que corren como funciones serverless/edge en Vercel.
   - Usalos para:
     - lógica de negocio (crear pedidos, validar, etc.)
     - integraciones con terceros (webhooks, APIs externas)
     - exponer una "Public API" para que otras apps creen pedidos

2) **Supabase**
   - Postgres (DB), Auth (usuarios), Storage (archivos), Realtime (opcional)
   - La DB es "fuente de verdad". Idealmente aplicás RLS en Supabase.

## Comunicación con Supabase
- Desde UI server-side (Server Components / Route Handlers): usar cliente server (cookies o service role).
- Desde UI client-side: usar cliente browser con `anon key` + RLS.

Patrón recomendado:
- Endpoints sensibles (crear pedidos, precios, etc.) => hacerlo desde server (Route Handlers) con validación (Zod) y/o service role.
- Lecturas seguras y filtradas => permitirlas desde cliente con RLS.

## Public API para terceros
- Endpoint `POST /api/v1/public/orders`
- Autenticación: `X-API-Key`
- En DB guardás hash del key (no el key en claro)
- El endpoint valida el API key y crea el pedido asociado a una organización (tenant)

## Deploy en Vercel
- Variables de entorno:
  - `NEXT_PUBLIC_SUPABASE_URL`
  - `NEXT_PUBLIC_SUPABASE_ANON_KEY`
  - `SUPABASE_SERVICE_ROLE_KEY` (solo server)
- Vercel detecta Next automáticamente y despliega.
