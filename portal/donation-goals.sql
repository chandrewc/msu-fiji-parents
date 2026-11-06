-- Isolated Parents Portal donation goals. General fund gifts retain a null goal.
create table public.donation_goals (
 id uuid primary key default gen_random_uuid(),title text not null check(length(trim(title)) between 1 and 120),
 description text not null default '' check(length(description)<=2000),target_cents bigint not null check(target_cents between 100 and 1000000000),
 active boolean not null default true,created_at timestamptz not null default now()
);
alter table public.donation_goals enable row level security;
revoke all on public.donation_goals from public,anon,authenticated;
grant select,insert,update on public.donation_goals to authenticated;
grant all on public.donation_goals to service_role;
create policy goal_read on public.donation_goals for select to authenticated using((select private.enabled()) and (active or (select private.permission('relations'))));
create policy goal_insert on public.donation_goals for insert to authenticated with check((select private.permission('relations')));
create policy goal_update on public.donation_goals for update to authenticated using((select private.permission('relations'))) with check((select private.permission('relations')));
create trigger audit_change after insert or update on public.donation_goals for each row execute function private.audit();
alter table public.stripe_donations add column goal_id uuid references public.donation_goals(id),add column goal_title text not null default '';
alter table public.parent_donations add column goal_id uuid references public.donation_goals(id),add column goal_title text not null default '';
create index stripe_donation_goal on public.stripe_donations(goal_id) where goal_id is not null;
create index offline_donation_goal on public.parent_donations(goal_id) where goal_id is not null;
create function private.stamp_donation_goal() returns trigger language plpgsql security definer set search_path='' as $$
declare goal public.donation_goals;begin
 if tg_op='UPDATE' then
  if tg_table_name='stripe_donations' then
   if new.goal_id is distinct from old.goal_id or new.goal_title is distinct from old.goal_title then raise exception 'Online donation goals cannot be reassigned';end if;return new;
  end if;
  if new.goal_id is not distinct from old.goal_id then new.goal_title=old.goal_title;return new;end if;
 end if;
 if new.goal_id is null then new.goal_title='';return new;end if;
 select * into goal from public.donation_goals where id=new.goal_id for share;
 if not found or not goal.active then raise exception 'This donation goal is no longer accepting gifts';end if;
 new.goal_title=goal.title;return new;
end$$;
revoke all on function private.stamp_donation_goal() from public,anon,authenticated;
create trigger stamp_goal before insert or update of goal_id,goal_title on public.stripe_donations for each row execute function private.stamp_donation_goal();
create trigger stamp_goal before insert or update of goal_id,goal_title on public.parent_donations for each row execute function private.stamp_donation_goal();
-- Only aggregate totals are shared; individual donor rows retain their existing RLS.
create function private.donation_goal_progress() returns table(id uuid,title text,description text,target_cents bigint,active boolean,raised_cents bigint,created_at timestamptz) language sql stable security definer set search_path='' as $$
 select g.id,g.title,g.description,g.target_cents,g.active,
 (coalesce((select sum(d.amount_cents-d.refunded_cents) from public.stripe_donations d where d.goal_id=g.id and d.fund='parents' and d.portal='parents' and d.livemode and not d.verification and d.status in ('paid','partially_refunded','refunded')),0)+coalesce((select sum(d.amount_cents) from public.parent_donations d where d.goal_id=g.id and d.fund='parents'),0))::bigint,g.created_at
 from public.donation_goals g where private.enabled() and (g.active or private.permission('relations')) order by g.created_at desc
$$;
revoke all on function private.donation_goal_progress() from public,anon;
grant execute on function private.donation_goal_progress() to authenticated;
create function public.get_donation_goals() returns table(id uuid,title text,description text,target_cents bigint,active boolean,raised_cents bigint,created_at timestamptz) language sql stable security invoker set search_path='' as $$select * from private.donation_goal_progress()$$;
revoke all on function public.get_donation_goals() from public,anon;
grant execute on function public.get_donation_goals() to authenticated;
