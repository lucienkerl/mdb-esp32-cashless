-- Migration: RLS Policies for RBAC
-- Created: 2026-02-16
-- Description: Row Level Security policies for user_roles and machine_assignments tables

-- ============================================
-- RLS Policies for user_roles table
-- ============================================

-- Policy: Users can read their own role
-- Allows authenticated users to see their own role entry
CREATE POLICY "Users can read own role" 
  ON public.user_roles
  FOR SELECT 
  USING (auth.uid() = user_id);

COMMENT ON POLICY "Users can read own role" ON public.user_roles 
  IS 'Authenticated users can only view their own role';

-- Policy: Admins can read all roles
-- Allows admins to view all user roles for user management
CREATE POLICY "Admins can read all roles" 
  ON public.user_roles
  FOR SELECT 
  USING (
    EXISTS (
      SELECT 1 FROM public.user_roles
      WHERE user_id = auth.uid() AND role = 'admin'
    )
  );

COMMENT ON POLICY "Admins can read all roles" ON public.user_roles 
  IS 'Admins can view all user roles for management';

-- Policy: Admins can insert roles
-- Allows admins to assign roles to new users
CREATE POLICY "Admins can insert roles" 
  ON public.user_roles
  FOR INSERT 
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM public.user_roles
      WHERE user_id = auth.uid() AND role = 'admin'
    )
  );

COMMENT ON POLICY "Admins can insert roles" ON public.user_roles 
  IS 'Only admins can assign roles to users';

-- Policy: Admins can update roles
-- Allows admins to change user roles
CREATE POLICY "Admins can update roles" 
  ON public.user_roles
  FOR UPDATE 
  USING (
    EXISTS (
      SELECT 1 FROM public.user_roles
      WHERE user_id = auth.uid() AND role = 'admin'
    )
  )
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM public.user_roles
      WHERE user_id = auth.uid() AND role = 'admin'
    )
  );

COMMENT ON POLICY "Admins can update roles" ON public.user_roles 
  IS 'Only admins can modify user roles';

-- Policy: Admins can delete roles
-- Allows admins to remove role assignments
CREATE POLICY "Admins can delete roles" 
  ON public.user_roles
  FOR DELETE 
  USING (
    EXISTS (
      SELECT 1 FROM public.user_roles
      WHERE user_id = auth.uid() AND role = 'admin'
    )
  );

COMMENT ON POLICY "Admins can delete roles" ON public.user_roles 
  IS 'Only admins can remove user roles';

-- ============================================
-- RLS Policies for machine_assignments table
-- ============================================

-- Policy: Operators see their assigned machines
-- Allows operators to view only machines assigned to them
CREATE POLICY "Operators see assigned machines" 
  ON public.machine_assignments
  FOR SELECT 
  USING (
    operator_id = auth.uid() OR
    EXISTS (
      SELECT 1 FROM public.user_roles
      WHERE user_id = auth.uid() AND role = 'admin'
    )
  );

COMMENT ON POLICY "Operators see assigned machines" ON public.machine_assignments 
  IS 'Operators see only their assigned machines; admins see all';

-- Policy: Admins can manage all machine assignments
-- Allows admins to create, update, and delete machine assignments
CREATE POLICY "Admins can insert machine assignments" 
  ON public.machine_assignments
  FOR INSERT 
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM public.user_roles
      WHERE user_id = auth.uid() AND role = 'admin'
    )
  );

COMMENT ON POLICY "Admins can insert machine assignments" ON public.machine_assignments 
  IS 'Only admins can assign machines to operators';

CREATE POLICY "Admins can update machine assignments" 
  ON public.machine_assignments
  FOR UPDATE 
  USING (
    EXISTS (
      SELECT 1 FROM public.user_roles
      WHERE user_id = auth.uid() AND role = 'admin'
    )
  )
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM public.user_roles
      WHERE user_id = auth.uid() AND role = 'admin'
    )
  );

COMMENT ON POLICY "Admins can update machine assignments" ON public.machine_assignments 
  IS 'Only admins can modify machine assignments';

CREATE POLICY "Admins can delete machine assignments" 
  ON public.machine_assignments
  FOR DELETE 
  USING (
    EXISTS (
      SELECT 1 FROM public.user_roles
      WHERE user_id = auth.uid() AND role = 'admin'
    )
  );

COMMENT ON POLICY "Admins can delete machine assignments" ON public.machine_assignments 
  IS 'Only admins can remove machine assignments';
