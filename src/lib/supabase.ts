// Centralized Supabase client helpers.
// Used in both client-side JS (browser) and server-side (Astro pages).
// Reads SUPABASE_URL and SUPABASE_ANON_KEY from import.meta.env.

import { createClient } from '@supabase/supabase-js';

const SUPABASE_URL = import.meta.env.PUBLIC_SUPABASE_URL;
const SUPABASE_ANON_KEY = import.meta.env.PUBLIC_SUPABASE_ANON_KEY;

if (!SUPABASE_URL || !SUPABASE_ANON_KEY) {
  // Don't crash builds (these are only needed at runtime in the browser)
  console.warn('Missing PUBLIC_SUPABASE_URL or PUBLIC_SUPABASE_ANON_KEY in env');
}

/**
 * Create a Supabase client that reads auth tokens from localStorage.
 * This is the canonical client used in browser-side JS.
 */
export function getSupabase() {
  return createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
    auth: {
      persistSession: true,
      autoRefreshToken: true,
      detectSessionInUrl: true,
      storage: typeof localStorage !== 'undefined' ? localStorage : undefined,
    },
  });
}

/**
 * Database row types — match the schema in supabase/migrations/20260722000000_init.sql
 */
export type EngagementType = 'fixed' | 'retainer' | 'hourly';
export type EngagementStatus = 'lead' | 'quoted' | 'active' | 'invoiced' | 'paid' | 'closed' | 'lost';
export type InvoiceStatus = 'draft' | 'sent' | 'paid' | 'overdue' | 'void';

export interface Client {
  id: string;
  owner_id: string;
  name: string;
  company: string | null;
  email: string | null;
  phone: string | null;
  notes: string | null;
  created_at: string;
  updated_at: string;
}

export interface Engagement {
  id: string;
  owner_id: string;
  client_id: string;
  name: string;
  type: EngagementType;
  status: EngagementStatus;
  quoted_amount: number | null;
  hourly_rate: number | null;
  estimated_hours: number | null;
  start_date: string | null;
  end_date: string | null;
  next_followup_at: string | null;
  gcal_event_id: string | null;
  notes: string | null;
  created_at: string;
  updated_at: string;
}

export interface EngagementSummary extends Engagement {
  client_name: string;
  client_company: string | null;
  invoiced_amount: number;
  paid_amount: number;
  open_invoice_count: number;
  last_activity_at: string | null;
}

export interface Invoice {
  id: string;
  owner_id: string;
  engagement_id: string;
  stripe_invoice_id: string | null;
  amount: number;
  currency: string;
  status: InvoiceStatus;
  due_date: string | null;
  description: string | null;
  sent_at: string | null;
  paid_at: string | null;
  created_at: string;
  updated_at: string;
}

export interface TimeEntry {
  id: string;
  owner_id: string;
  engagement_id: string;
  started_at: string;
  ended_at: string;
  minutes: number;
  description: string | null;
  billable: boolean;
  created_at: string;
}

export type ActivityType =
  | 'engagement_created' | 'engagement_status_changed' | 'engagement_updated'
  | 'invoice_created' | 'invoice_sent' | 'invoice_paid' | 'invoice_overdue'
  | 'note_added' | 'followup_scheduled' | 'client_created' | 'client_updated';

export interface Activity {
  id: string;
  owner_id: string;
  engagement_id: string | null;
  invoice_id: string | null;
  type: ActivityType;
  summary: string;
  metadata: Record<string, unknown>;
  created_at: string;
}

/** Statuses in pipeline order, used by both kanban and card list */
export const PIPELINE_STATUSES: EngagementStatus[] = [
  'lead', 'quoted', 'active', 'invoiced', 'paid', 'closed',
];

export const STATUS_LABELS: Record<EngagementStatus, string> = {
  lead: 'Lead',
  quoted: 'Quoted',
  active: 'Active',
  invoiced: 'Invoiced',
  paid: 'Paid',
  closed: 'Closed',
  lost: 'Lost',
};

export const TYPE_LABELS: Record<EngagementType, string> = {
  fixed: 'Fixed bid',
  retainer: 'Retainer',
  hourly: 'Hourly',
};

/** Format USD amount for display */
export function fmtMoney(n: number | null | undefined): string {
  if (n === null || n === undefined) return '—';
  return new Intl.NumberFormat('en-US', {
    style: 'currency',
    currency: 'USD',
    minimumFractionDigits: 0,
    maximumFractionDigits: 0,
  }).format(n);
}

/** Format ISO timestamp for relative display */
export function fmtRelative(iso: string | null | undefined): string {
  if (!iso) return '';
  const ms = Date.now() - new Date(iso).getTime();
  const min = Math.round(ms / 60000);
  if (min < 1) return 'just now';
  if (min < 60) return `${min}m ago`;
  const hr = Math.round(min / 60);
  if (hr < 24) return `${hr}h ago`;
  const d = Math.round(hr / 24);
  if (d < 30) return `${d}d ago`;
  return new Date(iso).toLocaleDateString();
}

/** Format ISO timestamp as YYYY-MM-DD HH:MM for follow-up display */
export function fmtFollowup(iso: string | null | undefined): string {
  if (!iso) return '';
  const d = new Date(iso);
  return d.toLocaleString('en-US', {
    month: 'short', day: 'numeric',
    hour: 'numeric', minute: '2-digit',
  });
}