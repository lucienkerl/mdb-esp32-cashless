# Phase 1: Foundation & Auth - Research

**Researched:** 2026-02-16
**Domain:** Nuxt 3 + shadcn-vue + Supabase Authentication & RBAC
**Confidence:** HIGH

## Summary

Phase 1 requires establishing a Nuxt 3 project with shadcn-vue UI components and Supabase Auth integration. The stack choices are well-supported with mature libraries and documentation. The @nuxtjs/supabase module provides first-class Nuxt integration with SSR cookie support, auto-imported composables, and server-side utilities.

For role-based access control (Admin/Operator), Supabase offers two primary patterns: (1) Custom Claims in JWT via Auth Hooks for role-based permissions, and (2) Row Level Security (RLS) policies with membership tables for multi-tenant data isolation. The recommended approach combines both: custom claims for quick role checks in the app, and RLS for database-level security enforcement.

**Primary recommendation:** Use @nuxtjs/supabase with SSR cookies enabled, implement RBAC via custom JWT claims + RLS policies, and use shadcn-nuxt module for zero-config UI components.

## Standard Stack

### Core
| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| Nuxt | ^3.15+ | Full-stack Vue framework | Official Vue meta-framework, Nitro SSR, file-based routing |
| @nuxtjs/supabase | ^1.4+ | Supabase integration | First-class Nuxt module, SSR support, auto-imports |
| shadcn-nuxt | latest | UI components | Tailwind-based, headless, copy-paste friendly |
| Tailwind CSS | ^4.0+ | Styling | Utility-first, integrates with shadcn-vue |
| @supabase/supabase-js | ^2.48+ | Supabase client | Core SDK, type-safe |

### Supporting
| Library | Version | Purpose | When to Use |
|---------|---------|---------|-------------|
| jwt-decode | ^4.0+ | JWT parsing | Reading custom claims from access_token |
| zod | ^3.23+ | Schema validation | Form validation, type-safe env |
| @vueuse/nuxt | ^12.0+ | Vue utilities | SSR-safe composables |

### Installation
```bash
# Create Nuxt project
pnpm create nuxt@latest mdb-frontend

# Add Supabase module
pnpm dlx nuxi@latest module add @nuxtjs/supabase

# Add shadcn-nuxt
pnpm dlx nuxi@latest module add shadcn-nuxt

# Add Tailwind CSS v4
pnpm add -D tailwindcss @tailwindcss/vite

# Initialize shadcn-vue
pnpm dlx shadcn-vue@latest init

# Add commonly used components
pnpm dlx shadcn-vue@latest add button card input label form avatar dropdown-menu
```

## Architecture Patterns

### Recommended Project Structure
```
frontend/
├── app/
│   ├── components/           # Vue components
│   │   └── ui/              # shadcn-vue components (auto-generated)
│   ├── composables/         # Auto-imported composables
│   │   ├── useAuth.ts       # Auth state & helpers
│   │   └── useRole.ts       # Role checking composable
│   ├── layouts/
│   │   ├── default.vue      # Main app layout
│   │   └── auth.vue         # Auth pages layout (no nav)
│   ├── middleware/
│   │   ├── auth.ts          # Require authentication
│   │   └── admin.ts         # Require admin role
│   ├── pages/
│   │   ├── index.vue        # Dashboard
│   │   ├── login.vue
│   │   ├── machines/
│   │   │   └── index.vue
│   │   └── admin/
│   │       ├── users.vue
│   │       └── machines.vue
│   ├── plugins/
│   │   └── ssr-width.ts     # VueUse SSR width fix
│   ├── types/
│   │   └── database.ts      # Generated Supabase types
│   └── app.vue
├── server/
│   └── api/                 # Server routes (if needed)
├── supabase/
│   ├── migrations/          # Database migrations
│   └── seed.sql             # Seed data
├── components.json          # shadcn-vue config
├── nuxt.config.ts
├── tailwind.config.ts
└── package.json
```

### Pattern 1: Nuxt Config for Supabase + shadcn
**What:** Configure Nuxt with both Supabase and shadcn modules
**When to use:** Project initialization
**Source:** https://supabase.nuxtjs.org/ + https://www.shadcn-vue.com/docs/installation/nuxt
**Example:**
```typescript
// nuxt.config.ts
export default defineNuxtConfig({
  modules: [
    '@nuxtjs/supabase',
    'shadcn-nuxt',
    '@vueuse/nuxt',
  ],
  
  // Supabase configuration
  supabase: {
    url: process.env.NUXT_PUBLIC_SUPABASE_URL,
    key: process.env.NUXT_PUBLIC_SUPABASE_KEY,
    redirectOptions: {
      login: '/login',
      callback: '/confirm',
      exclude: ['/login', '/register', '/forgot-password'],
    },
    // Enable SSR cookies (required for server-side auth)
    useSsrCookies: true,
    clientOptions: {
      auth: {
        flowType: 'pkce',
        autoRefreshToken: true,
        detectSessionInUrl: true,
        persistSession: true,
      },
    },
  },
  
  // shadcn-vue configuration
  shadcn: {
    prefix: '',
    componentDir: './app/components/ui',
  },
  
  // Tailwind CSS v4
  css: ['~/assets/css/tailwind.css'],
  vite: {
    plugins: [
      import('@tailwindcss/vite').then(m => m.default()),
    ],
  },
})
```

### Pattern 2: Auth Middleware
**What:** Protect routes requiring authentication
**When to use:** Pages that require logged-in users
**Source:** https://supabase.nuxtjs.org/composables/usesupabasesession
**Example:**
```typescript
// middleware/auth.ts
export default defineNuxtRouteMiddleware((to, _from) => {
  const session = useSupabaseSession()
  
  if (!session.value) {
    return navigateTo('/login')
  }
})

// middleware/admin.ts
export default defineNuxtRouteMiddleware((to, _from) => {
  const session = useSupabaseSession()
  const { isAdmin } = useRole() // Custom composable
  
  if (!session.value) {
    return navigateTo('/login')
  }
  
  if (!isAdmin.value) {
    return navigateTo('/') // Or show 403
  }
})

// Usage in pages
// pages/admin/users.vue
<script setup lang="ts">
definePageMeta({
  middleware: ['auth', 'admin'],
})
</script>
```

### Pattern 3: Role Checking Composable
**What:** Decode JWT custom claims to check user roles
**When to use:** UI rendering based on role, conditional navigation
**Source:** https://supabase.com/docs/guides/database/postgres/custom-claims-and-role-based-access-control-rbac
**Example:**
```typescript
// composables/useRole.ts
import { jwtDecode } from 'jwt-decode'

interface CustomJwtPayload {
  user_role?: 'admin' | 'operator'
}

export function useRole() {
  const session = useSupabaseSession()
  
  const userRole = computed(() => {
    if (!session.value?.access_token) return null
    try {
      const decoded = jwtDecode<CustomJwtPayload>(session.value.access_token)
      return decoded.user_role || 'operator' // Default to operator
    } catch {
      return null
    }
  })
  
  const isAdmin = computed(() => userRole.value === 'admin')
  const isOperator = computed(() => userRole.value === 'operator')
  
  return {
    userRole,
    isAdmin,
    isOperator,
  }
}
```

### Pattern 4: Database Schema for RBAC + Multi-tenancy
**What:** Tables for user roles and machine assignments with RLS policies
**When to use:** Foundation for Admin/Operator access control
**Source:** https://supabase.com/docs/guides/database/postgres/row-level-security
**Example:**
```sql
-- User roles table
CREATE TYPE public.app_role AS ENUM ('admin', 'operator');

CREATE TABLE public.user_roles (
  id bigint GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,
  user_id uuid REFERENCES auth.users ON DELETE CASCADE NOT NULL,
  role app_role NOT NULL DEFAULT 'operator',
  created_at timestamptz DEFAULT now(),
  UNIQUE (user_id)
);

-- Machine assignments for operators
CREATE TABLE public.machine_assignments (
  id bigint GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,
  operator_id uuid REFERENCES auth.users ON DELETE CASCADE NOT NULL,
  machine_id text NOT NULL, -- ESP32 device ID
  created_at timestamptz DEFAULT now(),
  UNIQUE (operator_id, machine_id)
);

-- Enable RLS
ALTER TABLE public.user_roles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.machine_assignments ENABLE ROW LEVEL SECURITY;

-- RLS: Users can read their own role
CREATE POLICY "Users can read own role" ON public.user_roles
  FOR SELECT USING (auth.uid() = user_id);

-- RLS: Admins can read all roles
CREATE POLICY "Admins can read all roles" ON public.user_roles
  FOR SELECT USING (
    EXISTS (
      SELECT 1 FROM public.user_roles
      WHERE user_id = auth.uid() AND role = 'admin'
    )
  );

-- RLS: Operators see only their assigned machines
CREATE POLICY "Operators see assigned machines" ON public.machine_assignments
  FOR SELECT USING (
    operator_id = auth.uid() OR
    EXISTS (
      SELECT 1 FROM public.user_roles
      WHERE user_id = auth.uid() AND role = 'admin'
    )
  );
```

### Pattern 5: Auth Hook for Custom Claims
**What:** Add user_role to JWT access token via Supabase Auth Hook
**When to use:** Need role info in JWT for client-side checks
**Source:** https://supabase.com/docs/guides/auth/auth-hooks#hook-custom-access-token
**Example:**
```sql
-- Create auth hook function
CREATE OR REPLACE FUNCTION public.custom_access_token_hook(event jsonb)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
AS $$
  DECLARE
    claims jsonb;
    user_role public.app_role;
  BEGIN
    -- Fetch user role
    SELECT role INTO user_role 
    FROM public.user_roles 
    WHERE user_id = (event->>'user_id')::uuid;

    claims := event->'claims';

    IF user_role IS NOT NULL THEN
      claims := jsonb_set(claims, '{user_role}', to_jsonb(user_role));
    ELSE
      claims := jsonb_set(claims, '{user_role}', '"operator"');
    END IF;

    event := jsonb_set(event, '{claims}', claims);
    RETURN event;
  END;
$$;

-- Grant permissions
GRANT USAGE ON SCHEMA public TO supabase_auth_admin;
GRANT EXECUTE ON FUNCTION public.custom_access_token_hook TO supabase_auth_admin;
REVOKE EXECUTE ON FUNCTION public.custom_access_token_hook FROM authenticated, anon, public;
GRANT SELECT ON TABLE public.user_roles TO supabase_auth_admin;
```

### Anti-Patterns to Avoid

1. **Storing role only in user_metadata:** This isn't secure for RLS policies. Always have a database table for roles.
2. **Checking session.value without SSR awareness:** On SSR, session may be null initially. Use `useSupabaseSession()` which handles hydration.
3. **Using localStorage for auth state:** Use SSR cookies (`useSsrCookies: true`) so server can access session.
4. **Skip RLS because "we check in the app":** RLS is the security layer of last resort. Always enable it.
5. **Creating one policy per table per role:** Combine policies using functions to reduce complexity.

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Auth state management | Pinia stores | @nuxtjs/supabase composables | Handles SSR, auto-refresh, cookies |
| Session persistence | localStorage | @supabase/ssr cookie storage | Server can access session, XSS resistant |
| JWT parsing | Manual regex | jwt-decode library | Handles edge cases, typed |
| Form validation | Manual checks | zod + vee-validate | Type-safe, schema-first |
| UI components | From scratch | shadcn-vue | Accessible, customizable, consistent |
| Database types | Manual interfaces | supabase gen types | Auto-generated from schema |

## Common Pitfalls

### Pitfall 1: Session Not Available During SSR
**What goes wrong:** `useSupabaseSession()` returns null on first SSR render even when user is logged in.
**Why it happens:** Session is extracted from cookies during SSR, may not be available immediately in setup.
**How to avoid:** Use `useAsyncData` with `server: false` for client-only fetches, or wrap in `onMounted`.
**Warning signs:** Flash of unauthenticated content, hydration mismatches.

### Pitfall 2: RLS Policies Blocking Legitimate Access
**What goes wrong:** Queries return empty arrays or permission errors unexpectedly.
**Why it happens:** RLS policies are ANDed together; if one fails, access is denied. Policies apply to ALL queries including from Supabase Dashboard (with override).
**How to avoid:** Test policies with actual client code, not just SQL Editor. Use `EXPLAIN` to debug.
**Warning signs:** "No rows returned" when data exists, 403 errors from PostgREST.

### Pitfall 3: Auth Hook Not Updating
**What goes wrong:** User role changes but JWT still has old role.
**Why it happens:** Access tokens are valid for 1 hour. Changes to user_roles table don't invalidate existing tokens.
**How to avoid:** Force token refresh after role change with `supabase.auth.refreshSession()`, or document 1-hour delay.
**Warning signs:** Role changes don't take effect immediately.

### Pitfall 4: Nuxt 4 Directory Structure Confusion
**What goes wrong:** Files in wrong directories, components not auto-importing.
**Why it happens:** Nuxt 4 moves pages, layouts, components to `app/` directory. Nuxt 3 puts them at root.
**How to avoid:** Explicitly use Nuxt 3 structure (root level) or set `future: { compatibilityVersion: 4 }` to opt into v4 structure.
**Warning signs:** 404s for pages, layouts not applied.

### Pitfall 5: shadcn-vue Import Errors
**What goes wrong:** "Component not found" errors or hydration mismatches.
**Why it happens:** Nuxt auto-import can conflict with shadcn-vue's component paths if not configured correctly.
**How to avoid:** Ensure `shadcn-nuxt` is in modules array, use `pnpm dlx nuxi prepare` after adding components.
**Warning signs:** Console warnings about unresolved components.

## Code Examples

### Supabase Client with Types
```typescript
// types/database.ts (generated via: npx supabase gen types typescript)
export type Json = string | number | boolean | null | { [key: string]: Json | undefined } | Json[]

export interface Database {
  public: {
    Tables: {
      user_roles: {
        Row: {
          id: number
          user_id: string
          role: 'admin' | 'operator'
          created_at: string
        }
        Insert: {
          user_id: string
          role?: 'admin' | 'operator'
        }
        Update: {
          role?: 'admin' | 'operator'
        }
      }
      machine_assignments: {
        Row: {
          id: number
          operator_id: string
          machine_id: string
          created_at: string
        }
        Insert: {
          operator_id: string
          machine_id: string
        }
      }
    }
  }
}
```

### Login Page with shadcn-vue
```vue
<!-- pages/login.vue -->
<script setup lang="ts">
import { z } from 'zod'
import { useForm } from 'vee-validate'
import { toTypedSchema } from '@vee-validate/zod'

definePageMeta({
  layout: 'auth',
})

const supabase = useSupabaseClient()
const toast = useToast()

const formSchema = toTypedSchema(z.object({
  email: z.string().email('Invalid email address'),
  password: z.string().min(8, 'Password must be at least 8 characters'),
}))

const form = useForm({
  validationSchema: formSchema,
})

const onSubmit = form.handleSubmit(async (values) => {
  const { error } = await supabase.auth.signInWithPassword({
    email: values.email,
    password: values.password,
  })

  if (error) {
    toast.error(error.message)
    return
  }

  await navigateTo('/')
})
</script>

<template>
  <div class="min-h-screen flex items-center justify-center">
    <Card class="w-full max-w-md">
      <CardHeader>
        <CardTitle>Sign In</CardTitle>
        <CardDescription>
          Enter your credentials to access the dashboard
        </CardDescription>
      </CardHeader>
      <CardContent>
        <form @submit="onSubmit" class="space-y-4">
          <FormField v-slot="{ componentField }" name="email">
            <FormItem>
              <FormLabel>Email</FormLabel>
              <FormControl>
                <Input type="email" placeholder="admin@example.com" v-bind="componentField" />
              </FormControl>
              <FormMessage />
            </FormItem>
          </FormField>
          
          <FormField v-slot="{ componentField }" name="password">
            <FormItem>
              <FormLabel>Password</FormLabel>
              <FormControl>
                <Input type="password" v-bind="componentField" />
              </FormControl>
              <FormMessage />
            </FormItem>
          </FormField>

          <Button type="submit" class="w-full" :disabled="form.isSubmitting.value">
            <Loader2 v-if="form.isSubmitting.value" class="mr-2 h-4 w-4 animate-spin" />
            Sign In
          </Button>
        </form>
      </CardContent>
    </Card>
  </div>
</template>
```

### Navigation with Role-based Menu
```vue
<!-- components/AppNavigation.vue -->
<script setup lang="ts">
const { isAdmin, isOperator } = useRole()
const supabase = useSupabaseClient()

async function logout() {
  await supabase.auth.signOut()
  await navigateTo('/login')
}
</script>

<template>
  <nav class="border-b bg-background">
    <div class="flex h-16 items-center px-4">
      <div class="flex items-center gap-6">
        <NuxtLink to="/" class="font-bold text-xl">
          MDB Dashboard
        </NuxtLink>
        
        <div class="flex items-center gap-4">
          <!-- Admin-only links -->
          <template v-if="isAdmin">
            <NuxtLink to="/admin/users" class="text-sm font-medium">
              Users
            </NuxtLink>
            <NuxtLink to="/admin/machines" class="text-sm font-medium">
              All Machines
            </NuxtLink>
          </template>
          
          <!-- Operator links -->
          <NuxtLink to="/machines" class="text-sm font-medium">
            My Machines
          </NuxtLink>
        </div>
      </div>
      
      <div class="ml-auto flex items-center gap-4">
        <Button variant="ghost" @click="logout">
          Logout
        </Button>
      </div>
    </div>
  </nav>
</template>
```

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| @supabase/auth-helpers | @supabase/ssr | 2024 | New package, framework-agnostic, still beta |
| Manual Supabase client | @nuxtjs/supabase module | 2023 | Auto-imports, SSR handling, composables |
| Nuxt 3 structure | Nuxt 4 app/ directory | 2025 | Better separation of concerns |
| shadcn-vue manual setup | shadcn-nuxt module | 2025 | Zero-config, auto-import support |
| Tailwind v3 | Tailwind v4 | 2025 | CSS-first config, faster builds |

**Deprecated/outdated:**
- **@supabase/auth-helpers-nextjs/sveltekit/remix:** Replaced by @supabase/ssr (Jan 2024)
- **Nuxt 2:** Use Nuxt 3 for Vue 3 and better SSR
- **Implicit auth flow:** Use PKCE flow for SSR compatibility

## Open Questions

1. **Token Refresh Timing**
   - What we know: Tokens refresh automatically but role changes require manual refresh
   - What's unclear: Best UX pattern for forcing re-login after role change
   - Recommendation: Force token refresh or set short session timeouts for role-sensitive operations

2. **Machine Assignment Granularity**
   - What we know: Need operator-to-machine mapping
   - What's unclear: Should assignments be hierarchical (groups of machines) or 1:1
   - Recommendation: Start with 1:1 mapping, can extend to groups later

3. **Initial Admin Creation**
   - What we know: First user needs to be admin
   - What's unclear: Should this be automated or manual SQL insert
   - Recommendation: Document manual SQL approach for v1, automate in v2

## Sources

### Primary (HIGH confidence)
- https://supabase.nuxtjs.org/ - @nuxtjs/supabase module docs
- https://www.shadcn-vue.com/docs/installation/nuxt - shadcn-vue Nuxt installation
- https://supabase.com/docs/guides/auth/server-side - Supabase SSR guide
- https://supabase.com/docs/guides/database/postgres/row-level-security - RLS docs
- https://supabase.com/docs/guides/database/postgres/custom-claims-and-role-based-access-control-rbac - RBAC patterns

### Secondary (MEDIUM confidence)
- https://nuxt.com/docs/3.x/directory-structure - Nuxt 3 directory structure
- https://github.com/nuxt-modules/supabase - Module source code
- https://makerkit.dev/blog/tutorials/supabase-rls-best-practices - Production RLS patterns

### Tertiary (LOW confidence)
- WebSearch results for Nuxt 3 + Supabase patterns (verified against official docs)

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH - All libraries are official/mature
- Architecture: HIGH - Based on official docs and patterns
- Pitfalls: HIGH - Well-documented issues in Supabase/Nuxt communities

**Research date:** 2026-02-16
**Valid until:** 2026-06-16 (4 months for stable stack)
