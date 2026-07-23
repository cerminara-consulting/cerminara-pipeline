-- Fix activity-log triggers so they can insert into activities table
-- (the table only has RLS read policy; without SECURITY DEFINER, the
-- insert from the trigger runs as the calling user and gets blocked).

create or replace function public.log_engagement_change()
returns trigger language plpgsql security definer as $$
declare
begin
  if TG_OP = 'INSERT' then
    insert into public.activities(owner_id, engagement_id, type, summary, metadata)
      values (new.owner_id, new.id, 'engagement_created',
              'Created engagement: ' || new.name,
              jsonb_build_object('status', new.status, 'type', new.type));
    return new;
  elsif TG_OP = 'UPDATE' then
    if new.status is distinct from old.status then
      insert into public.activities(owner_id, engagement_id, type, summary, metadata)
        values (new.owner_id, new.id, 'engagement_status_changed',
                'Status: ' || old.status::text || ' → ' || new.status::text,
                jsonb_build_object('from', old.status, 'to', new.status));
    end if;
    if new.name is distinct from old.name or new.notes is distinct from old.notes or
       new.quoted_amount is distinct from old.quoted_amount or new.type is distinct from old.type then
      insert into public.activities(owner_id, engagement_id, type, summary, metadata)
        values (new.owner_id, new.id, 'engagement_updated',
                'Updated engagement details',
                jsonb_build_object());
    end if;
    if new.next_followup_at is distinct from old.next_followup_at and new.next_followup_at is not null then
      insert into public.activities(owner_id, engagement_id, type, summary, metadata)
        values (new.owner_id, new.id, 'followup_scheduled',
                'Follow-up scheduled for ' || to_char(new.next_followup_at, 'YYYY-MM-DD HH12:MI AM'),
                jsonb_build_object('followup_at', new.next_followup_at));
    end if;
    return new;
  end if;
  return new;
end $$;

create or replace function public.log_invoice_change()
returns trigger language plpgsql security definer as $$
begin
  if TG_OP = 'INSERT' then
    insert into public.activities(owner_id, engagement_id, invoice_id, type, summary, metadata)
      values (new.owner_id, new.engagement_id, new.id, 'invoice_created',
              'Invoice created: $' || new.amount::text,
              jsonb_build_object('amount', new.amount, 'status', new.status));
  elsif TG_OP = 'UPDATE' then
    if new.status is distinct from old.status then
      insert into public.activities(owner_id, engagement_id, invoice_id, type, summary, metadata)
        values (
          new.owner_id, new.engagement_id, new.id,
          case
            when new.status = 'sent' then 'invoice_sent'::activity_type
            when new.status = 'paid' then 'invoice_paid'::activity_type
            when new.status = 'overdue' then 'invoice_overdue'::activity_type
            else 'engagement_updated'::activity_type
          end,
          case
            when new.status = 'sent' then 'Invoice sent for $' || new.amount::text
            when new.status = 'paid' then 'Invoice PAID: $' || new.amount::text
            when new.status = 'overdue' then 'Invoice OVERDUE: $' || new.amount::text
            else 'Invoice status: ' || new.status::text
          end,
          jsonb_build_object('from', old.status, 'to', new.status)
        );
    end if;
  end if;
  return new;
end $$;

-- Drop and recreate triggers to ensure they re-bind to the SECURITY DEFINER functions
drop trigger if exists trg_engagements_log on public.engagements;
create trigger trg_engagements_log
  after insert or update on public.engagements
  for each row execute function public.log_engagement_change();

drop trigger if exists trg_invoices_log on public.invoices;
create trigger trg_invoices_log
  after insert or update on public.invoices
  for each row execute function public.log_invoice_change();

-- Grant execute on the trigger functions to the calling role
grant execute on function public.log_engagement_change() to authenticated;
grant execute on function public.log_invoice_change() to authenticated;