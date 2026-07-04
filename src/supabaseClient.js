import { createClient } from "@supabase/supabase-js";

const supabaseUrl = import.meta.env.VITE_SUPABASE_URL?.trim() ?? "";
const supabaseAnonKey = import.meta.env.VITE_SUPABASE_ANON_KEY?.trim() ?? "";
const appEnvironment = import.meta.env.VITE_A2Z_ENVIRONMENT?.trim() ?? "local";
const authMode = import.meta.env.VITE_A2Z_AUTH_MODE?.trim() ?? "demo";

export const supabaseConfig = {
  url: supabaseUrl,
  environment: appEnvironment,
  authMode,
  hasRequiredConfig: Boolean(supabaseUrl && supabaseAnonKey)
};

export const supabase = supabaseConfig.hasRequiredConfig
  ? createClient(supabaseUrl, supabaseAnonKey, {
      auth: {
        autoRefreshToken: true,
        detectSessionInUrl: true,
        persistSession: true
      }
    })
  : null;

export function requireSupabaseClient() {
  if (!supabase) {
    throw new Error("Supabase is not configured. Set VITE_SUPABASE_URL and VITE_SUPABASE_ANON_KEY.");
  }

  return supabase;
}
