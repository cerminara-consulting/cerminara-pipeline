# Cerminara Pipeline Tracker

Solo-operator CRM / consulting engagement tracker. Single-user app hosted at
`tracker.cerminaraconsulting.com`. Built on Astro + Supabase.

## What's in here

- **Mobile-first card list view** — for "I'm at a coffee shop, what's due?"
- **Desktop kanban view** — drag engagements between Lead → Quoted → Active → Invoiced → Paid → Closed
- **Auth** — password or magic link via Supabase Auth, single user only
- **Engagement types** — fixed-bid, retainer, or hourly
- **Invoices** — track billable amounts per engagement (Stripe wiring coming)
- **Activity log** — every state change is recorded automatically via DB triggers

## Setup

```bash
npm install
cp .env.example .env
# Fill in SUPABASE_URL and SUPABASE_ANON_KEY from the secrets file
npm run dev
```

The dev server runs at `http://localhost:4321`.

## Stack

- **Astro 4** — static site output, islands of interactivity where needed
- **Supabase** — Postgres + Auth + RLS, single-tenant
- **No build tools beyond Astro** — no Tailwind, no React, just vanilla CSS + small JS islands

## Roadmap

- [ ] Stripe integration (invoice creation + webhook for paid status)
- [ ] Gmail intake (daily scan of unread for consulting signals)
- [ ] Google Calendar sync (push follow-ups to GCal)
- [ ] Daily 7am summary cron (overlaps with current heartbeat)