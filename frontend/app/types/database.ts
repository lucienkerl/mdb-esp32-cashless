/**
 * Database Type Definitions
 * 
 * This file contains TypeScript types for the Supabase database schema.
 * In production, these should be generated using:
 *   npx supabase gen types typescript --project-id <project-id> --schema public > app/types/database.ts
 * 
 * For initial setup, we're defining them manually based on the schema in:
 *   - supabase/migrations/001_initial_schema.sql
 *   - supabase/migrations/002_rls_policies.sql
 */

export type Json =
  | string
  | number
  | boolean
  | null
  | { [key: string]: Json | undefined }
  | Json[]

/**
 * Database schema definition
 * Matches the Supabase public schema structure
 */
export interface Database {
  public: {
    Tables: {
      /**
       * User roles table
       * Stores the role (admin/operator) for each user
       * RLS policies: Users read own, admins manage all
       */
      user_roles: {
        Row: {
          id: number
          user_id: string
          role: 'admin' | 'operator'
          created_at: string
        }
        Insert: {
          id?: number
          user_id: string
          role?: 'admin' | 'operator'
          created_at?: string
        }
        Update: {
          id?: number
          user_id?: string
          role?: 'admin' | 'operator'
          created_at?: string
        }
      }
      /**
       * Machine assignments table
       * Maps operators to their assigned vending machines
       * RLS policies: Operators see own, admins manage all
       */
      machine_assignments: {
        Row: {
          id: number
          operator_id: string
          machine_id: string
          created_at: string
        }
        Insert: {
          id?: number
          operator_id: string
          machine_id: string
          created_at?: string
        }
        Update: {
          id?: number
          operator_id?: string
          machine_id?: string
          created_at?: string
        }
      }
    }
    Views: {
      [_ in never]: never
    }
    Functions: {
      /**
       * Custom access token hook function
       * Adds user_role claim to JWT tokens
       */
      custom_access_token_hook: {
        Args: {
          event: Json
        }
        Returns: Json
      }
    }
    Enums: {
      /**
       * Application roles enum
       * admin: Full access to all features
       * operator: Limited access to assigned machines only
       */
      app_role: 'admin' | 'operator'
    }
    CompositeTypes: {
      [_ in never]: never
    }
  }
}

/**
 * Helper type for database tables
 * Usage: Tables<'user_roles'>
 */
export type Tables<
  PublicTableNameOrOptions extends
    | keyof (Database["public"]["Tables"] & Database["public"]["Views"])
    | { schema: keyof Database },
  TableName extends PublicTableNameOrOptions extends { schema: keyof Database }
    ? keyof (Database[PublicTableNameOrOptions["schema"]]["Tables"] &
        Database[PublicTableNameOrOptions["schema"]]["Views"])
    : never = never,
> = PublicTableNameOrOptions extends { schema: keyof Database }
  ? (Database[PublicTableNameOrOptions["schema"]]["Tables"] &
      Database[PublicTableNameOrOptions["schema"]]["Views"])[TableName] extends {
      Row: infer R
    }
    ? R
    : never
  : PublicTableNameOrOptions extends keyof (Database["public"]["Tables"] &
        Database["public"]["Views"])
    ? (Database["public"]["Tables"] &
        Database["public"]["Views"])[PublicTableNameOrOptions] extends {
        Row: infer R
      }
      ? R
      : never
    : never

/**
 * Helper type for table inserts
 * Usage: TablesInsert<'user_roles'>
 */
export type TablesInsert<
  PublicTableNameOrOptions extends
    | keyof Database["public"]["Tables"]
    | { schema: keyof Database },
  TableName extends PublicTableNameOrOptions extends { schema: keyof Database }
    ? keyof Database[PublicTableNameOrOptions["schema"]]["Tables"]
    : never = never,
> = PublicTableNameOrOptions extends { schema: keyof Database }
  ? Database[PublicTableNameOrOptions["schema"]]["Tables"][TableName] extends {
      Insert: infer I
    }
    ? I
    : never
  : PublicTableNameOrOptions extends keyof Database["public"]["Tables"]
    ? Database["public"]["Tables"][PublicTableNameOrOptions] extends {
        Insert: infer I
      }
      ? I
      : never
    : never

/**
 * Helper type for table updates
 * Usage: TablesUpdate<'user_roles'>
 */
export type TablesUpdate<
  PublicTableNameOrOptions extends
    | keyof Database["public"]["Tables"]
    | { schema: keyof Database },
  TableName extends PublicTableNameOrOptions extends { schema: keyof Database }
    ? keyof Database[PublicTableNameOrOptions["schema"]]["Tables"]
    : never = never,
> = PublicTableNameOrOptions extends { schema: keyof Database }
  ? Database[PublicTableNameOrOptions["schema"]]["Tables"][TableName] extends {
      Update: infer U
    }
    ? U
    : never
  : PublicTableNameOrOptions extends keyof Database["public"]["Tables"]
    ? Database["public"]["Tables"][PublicTableNameOrOptions] extends {
        Update: infer U
      }
      ? U
      : never
    : never

/**
 * Helper type for database enums
 * Usage: Enums<'app_role'>
 */
export type Enums<
  PublicEnumNameOrOptions extends
    | keyof Database["public"]["Enums"]
    | { schema: keyof Database },
  EnumName extends PublicEnumNameOrOptions extends { schema: keyof Database }
    ? keyof Database[PublicEnumNameOrOptions["schema"]]["Enums"]
    : never = never,
> = PublicEnumNameOrOptions extends { schema: keyof Database }
  ? Database[PublicEnumNameOrOptions["schema"]]["Enums"][EnumName]
  : PublicEnumNameOrOptions extends keyof Database["public"]["Enums"]
    ? Database["public"]["Enums"][PublicEnumNameOrOptions]
    : never
