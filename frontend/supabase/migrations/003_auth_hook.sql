-- Migration: Auth Hook for Custom JWT Claims
-- Created: 2026-02-16
-- Description: Adds user_role to JWT access tokens via Supabase Auth Hook

-- ============================================
-- Custom Access Token Hook Function
-- ============================================
-- This function runs on every token generation (login, token refresh, etc.)
-- It queries the user_roles table and embeds the role into the JWT claims
--
-- IMPORTANT NOTES:
-- - This hook runs automatically on every access token generation
-- - Role changes require token refresh to take effect (tokens valid for 1 hour)
-- - If no role is found, defaults to 'operator' for security
-- - Must be configured in Supabase Dashboard -> Authentication -> Hooks
--

CREATE OR REPLACE FUNCTION public.custom_access_token_hook(event jsonb)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
AS $$
  DECLARE
    claims jsonb;
    user_role public.app_role;
  BEGIN
    -- Extract current claims from the event
    claims := event->'claims';
    
    -- Fetch the user's role from user_roles table
    -- Defaults to NULL if user has no role assigned
    SELECT role INTO user_role 
    FROM public.user_roles 
    WHERE user_id = (event->>'user_id')::uuid;

    -- Add user_role to JWT claims
    -- If no role found, default to 'operator' for security
    IF user_role IS NOT NULL THEN
      claims := jsonb_set(claims, '{user_role}', to_jsonb(user_role));
    ELSE
      -- Default to operator if no role assigned
      -- This ensures new users have limited access by default
      claims := jsonb_set(claims, '{user_role}', '"operator"');
    END IF;

    -- Update the event with modified claims
    event := jsonb_set(event, '{claims}', claims);
    
    RETURN event;
  END;
$$;

-- Add documentation comment
COMMENT ON FUNCTION public.custom_access_token_hook IS 
'Auth hook that adds user_role claim to JWT access tokens.
Runs automatically on token generation. Role changes require token refresh.
Configured in Supabase Dashboard -> Authentication -> Hooks -> custom_access_token_hook';

-- ============================================
-- Required Permissions for Auth Hook
-- ============================================

-- Grant usage on public schema to supabase_auth_admin
-- This allows the auth system to access our custom function
GRANT USAGE ON SCHEMA public TO supabase_auth_admin;

-- Grant execute permission on the hook function
-- Required for the auth system to call our function
GRANT EXECUTE ON FUNCTION public.custom_access_token_hook TO supabase_auth_admin;

-- Revoke execute from authenticated and anonymous users
-- Ensures only the auth system can call this function
REVOKE EXECUTE ON FUNCTION public.custom_access_token_hook FROM authenticated, anon, public;

-- Grant select on user_roles table to supabase_auth_admin
-- Required for the hook to query user roles
GRANT SELECT ON TABLE public.user_roles TO supabase_auth_admin;

-- ============================================
-- Verification Query
-- ============================================
-- After configuring the hook in Supabase Dashboard, verify it works:
--
-- 1. Create a test user and assign a role:
--    INSERT INTO public.user_roles (user_id, role) 
--    VALUES ('user-uuid-here', 'admin');
--
-- 2. Sign in as that user and decode the JWT access_token
-- 3. Verify the payload contains: { "user_role": "admin", ... }
--
-- To test the hook manually:
-- SELECT public.custom_access_token_hook(
--   jsonb_build_object(
--     'user_id', 'user-uuid-here',
--     'claims', '{}'::jsonb
--   )
-- );
