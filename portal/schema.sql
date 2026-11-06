-- Empty, isolated parents portal. Never run against the Brother Network project.
create schema if not exists private;
revoke all on schema private from public;
grant usage on schema private to authenticated;
create table public.parents (
 user_id uuid primary key references auth.users(id) on delete cascade,
 full_name text not null default '' check(length(full_name)<=120),
 username text unique check(username ~ '^[A-Za-z0-9_]{3,32}$'),
 relationship text not null default '' check(relationship in ('','Parent','Guardian','Other family')),
 city text not null default '' check(length(city)<=120), state text not null default '' check(length(state)<=80),
 directory_email text not null default '' check(length(directory_email)<=254), directory_phone text not null default '' check(length(directory_phone)<=30),
 avatar_path text, approved boolean not null default false, rejected boolean not null default false,
 role text not null default 'parent' check(role in ('parent','admin','super_admin')),
 protected boolean not null default false, deactivated_at timestamptz, profile_complete boolean not null default false,
 created_at timestamptz not null default now()
);
create table public.parent_private (
 user_id uuid primary key references public.parents(user_id) on delete cascade,
 email text not null default '' check(length(email)<=254), phone text not null default '' check(length(phone)<=30),
 student_name text not null default '' check(length(student_name)<=120), student_details text not null default '' check(length(student_details)<=1000)
);
create table public.parent_admin_permissions (
 user_id uuid references public.parents(user_id) on delete cascade,
 permission text check(permission in ('requests','parents','newsletter','news','relations','activity')),
 primary key(user_id,permission)
);
create function private.enabled() returns boolean language sql stable security definer set search_path='' as $$
 select exists(select 1 from public.parents where user_id=auth.uid() and approved and not rejected and deactivated_at is null and profile_complete)
$$;
create function private.permission(k text) returns boolean language sql stable security definer set search_path='' as $$
 select private.enabled() and exists(select 1 from public.parents p where p.user_id=auth.uid() and (p.role in ('admin','super_admin') or exists(select 1 from public.parent_admin_permissions a where a.user_id=p.user_id and a.permission=k)))
$$;
create function public.has_admin_permission(p_permission text) returns boolean language sql stable security invoker set search_path='' as $$select private.permission(p_permission)$$;
create function private.not_deactivated() returns boolean language sql stable security definer set search_path='' as $$select exists(select 1 from public.parents where user_id=auth.uid() and deactivated_at is null)$$;
create function private.new_parent() returns trigger language plpgsql security definer set search_path='' as $$begin
 insert into public.parents(user_id) values(new.id);
 insert into public.parent_private(user_id,email) values(new.id,coalesce(new.email,''));
 return new; end$$;
create trigger on_parent_signup after insert on auth.users for each row execute function private.new_parent();
create table public.admin_activity_log(id bigint generated always as identity primary key,actor_id uuid,action text not null,record_id text,created_at timestamptz not null default now());
create function private.audit() returns trigger language plpgsql security definer set search_path='' as $$begin
 if private.permission('activity') or exists(select 1 from public.parents where user_id=auth.uid() and role in ('admin','super_admin') and deactivated_at is null) or exists(select 1 from public.parent_admin_permissions where user_id=auth.uid()) then
 insert into public.admin_activity_log(actor_id,action,record_id) values(auth.uid(),tg_table_name||'.'||lower(tg_op),coalesce(to_jsonb(new)->>'id',to_jsonb(old)->>'id',to_jsonb(new)->>'user_id',to_jsonb(old)->>'user_id')); end if;
 return coalesce(new,old); end$$;
create table public.newsletters(id uuid primary key default gen_random_uuid(),title text not null check(length(title) between 1 and 200),body text not null default '' check(length(body)<=20000),issue_date date not null,pdf_url text not null default '' check(pdf_url='' or pdf_url like 'https://%'),pdf_path text,created_at timestamptz not null default now());
create table public.announcements(id uuid primary key default gen_random_uuid(),title text not null check(length(title) between 1 and 200),body text not null check(length(body) between 1 and 20000),created_at timestamptz not null default now());
create table public.parent_relations(user_id uuid primary key references public.parents(user_id),relationship_status text not null default 'Not contacted' check(length(relationship_status)<=80),priority text not null default 'Normal' check(priority in ('Low','Normal','High')),last_contact date,follow_up date,next_action text not null default '' check(length(next_action)<=500),notes text not null default '' check(length(notes)<=3000));
create table public.parent_contacts(id uuid primary key default gen_random_uuid(),user_id uuid not null references public.parents(user_id),contact_date date not null default current_date,method text not null default 'Other',summary text not null check(length(summary)<=3000),created_at timestamptz not null default now());
create table public.parent_donations(id uuid primary key default gen_random_uuid(),user_id uuid not null references public.parents(user_id),fund text not null default 'parents' check(fund='parents'),amount_cents bigint not null check(amount_cents between 1 and 10000000),donation_date date not null default current_date,purpose text not null default '' check(length(purpose)<=500),method text not null default 'Other',created_at timestamptz not null default now());
create table public.stripe_donations(
 id uuid primary key,member_id uuid not null references public.parents(user_id),fund text not null default 'parents' check(fund='parents'),portal text not null default 'parents' check(portal='parents'),
 amount_cents bigint not null check(amount_cents between 100 and 10000000),currency text not null default 'usd' check(currency='usd'),purpose text not null default '' check(length(purpose)<=500),
 checkout_session_id text unique,payment_intent_id text unique,status text not null default 'pending' check(status in ('pending','paid','failed','expired','partially_refunded','refunded')),
 refunded_cents bigint not null default 0 check(refunded_cents between 0 and amount_cents),livemode boolean not null default true check(livemode=true),created_at timestamptz not null default now(),paid_at timestamptz);
create index on public.stripe_donations(member_id,created_at desc);
create table public.stripe_donation_events(event_id text primary key,donation_id uuid not null references public.stripe_donations(id),processed_at timestamptz not null default now());
create table public.portal_settings(id boolean primary key default true check(id),checkout_verified boolean not null default false,verified_at timestamptz);
insert into public.portal_settings(id) values(true);
-- Atomic idempotent payment event processing; only the server role can invoke it.
create function public.record_stripe_donation_event(p_event_id text,p_donation_id uuid,p_session_id text,p_payment_intent_id text,p_status text,p_refunded_cents bigint default 0) returns text language plpgsql security invoker set search_path='' as $$
declare d public.stripe_donations; n integer; refund bigint;
begin
 if p_status not in ('paid','failed','expired','partially_refunded','refunded') then raise exception 'Invalid status'; end if;
 select * into d from public.stripe_donations where id=p_donation_id and fund='parents' and portal='parents' and livemode for update;
 if not found then raise exception 'Donation not found'; end if;
 if d.checkout_session_id is distinct from p_session_id or (d.payment_intent_id is not null and d.payment_intent_id is distinct from p_payment_intent_id) then raise exception 'Payment mismatch'; end if;
 if p_refunded_cents<0 or p_refunded_cents>d.amount_cents then raise exception 'Invalid refund'; end if;
 insert into public.stripe_donation_events values(p_event_id,d.id,now()) on conflict do nothing; get diagnostics n=row_count;
 if n=0 then return 'duplicate'; end if;
 refund=greatest(d.refunded_cents,p_refunded_cents);
 update public.stripe_donations set payment_intent_id=coalesce(d.payment_intent_id,p_payment_intent_id),refunded_cents=refund,
 status=case when refund=d.amount_cents then 'refunded' when refund>0 then 'partially_refunded' when d.status='paid' or p_status='paid' then 'paid' when d.status in ('failed','expired') then d.status else p_status end,
 paid_at=case when p_status='paid' or refund>0 then coalesce(d.paid_at,now()) else d.paid_at end where id=d.id;
 return 'processed'; end$$;
create function public.save_parent_profile(p_full_name text,p_username text,p_relationship text,p_email text,p_phone text,p_city text default '',p_state text default '',p_directory_email text default '',p_directory_phone text default '',p_student_name text default '',p_student_details text default '') returns void language plpgsql security definer set search_path='' as $$begin
 if auth.uid() is null or not private.not_deactivated() then raise exception 'Sign in required'; end if;
 if length(trim(p_full_name))<2 or length(trim(p_email))<3 or length(trim(p_phone))<7 or p_relationship not in ('Parent','Guardian','Other family') then raise exception 'Complete the required profile fields'; end if;
 update public.parents set full_name=trim(p_full_name),username=lower(trim(p_username)),relationship=p_relationship,city=p_city,state=p_state,directory_email=p_directory_email,directory_phone=p_directory_phone,profile_complete=true where user_id=auth.uid();
 update public.parent_private set email=p_email,phone=p_phone,student_name=p_student_name,student_details=p_student_details where user_id=auth.uid();
 end$$;
create function public.admin_parent_access(p_user_id uuid,p_action text) returns void language plpgsql security definer set search_path='' as $$
declare target public.parents; begin
 if not private.permission(case when p_action in ('approve','reject') then 'requests' else 'parents' end) then raise exception 'Administrator permission required'; end if;
 select * into target from public.parents where user_id=p_user_id for update;
 if not found or target.protected or target.role='super_admin' or p_user_id=auth.uid() then raise exception 'Protected account'; end if;
 if target.role='admin' and not exists(select 1 from public.parents where user_id=auth.uid() and role='super_admin') then raise exception 'Super administrator required'; end if;
 if p_action='approve' then
 if not target.profile_complete then raise exception 'Profile incomplete'; end if;
 update public.parents set approved=true,rejected=false where user_id=p_user_id;
 elsif p_action='reject' then update public.parents set approved=false,rejected=true where user_id=p_user_id;
 elsif p_action='deactivate' then update public.parents set deactivated_at=now() where user_id=p_user_id;
 elsif p_action='reactivate' then update public.parents set deactivated_at=null where user_id=p_user_id;
 else raise exception 'Unknown action'; end if;
 end$$;
create function public.set_parent_permissions(p_user_id uuid,p_permissions text[],p_role text default 'parent') returns void language plpgsql security definer set search_path='' as $$
declare actor_role text; target public.parents; begin
 select role into actor_role from public.parents where user_id=auth.uid() and approved and not rejected and deactivated_at is null;
 if actor_role not in ('admin','super_admin') or actor_role is null then raise exception 'Full administrator required'; end if;
 select * into target from public.parents where user_id=p_user_id for update;
 if not found or target.protected or target.role='super_admin' or p_user_id=auth.uid() or not target.approved or target.deactivated_at is not null then raise exception 'Protected or inactive account'; end if;
 if p_role not in ('parent','admin') or ((p_role<>target.role or target.role='admin') and actor_role<>'super_admin') then raise exception 'Super administrator required'; end if;
 delete from public.parent_admin_permissions where user_id=p_user_id;
 insert into public.parent_admin_permissions(user_id,permission) select p_user_id,unnest(p_permissions);
 update public.parents set role=p_role where user_id=p_user_id;
 end$$;
-- Default privileges are closed. All client writes use policies or narrow RPCs.
do $$declare t text; begin foreach t in array array['parents','parent_private','parent_admin_permissions','admin_activity_log','newsletters','announcements','parent_relations','parent_contacts','parent_donations','stripe_donations','stripe_donation_events','portal_settings'] loop
 execute format('alter table public.%I enable row level security',t);
 execute format('revoke all on public.%I from public,anon,authenticated',t);
 execute format('grant all on public.%I to service_role',t);
 end loop; end$$;
grant select on public.parents,public.parent_private,public.parent_admin_permissions,public.admin_activity_log,public.stripe_donations to authenticated;
grant select,insert,update,delete on public.newsletters,public.announcements,public.parent_relations,public.parent_contacts,public.parent_donations to authenticated;
create policy parent_read on public.parents for select to authenticated using(user_id=(select auth.uid()) or ((select private.enabled()) and approved and not rejected and deactivated_at is null) or (select private.permission('parents')) or (select private.permission('requests')));
create policy private_read on public.parent_private for select to authenticated using((user_id=(select auth.uid()) and (select private.not_deactivated())) or (select private.permission('parents')) or (select private.permission('requests')) or (select private.permission('relations')));
create policy permissions_read on public.parent_admin_permissions for select to authenticated using(user_id=(select auth.uid()) or (select private.permission('parents')));
create policy log_read on public.admin_activity_log for select to authenticated using((select private.permission('activity')));
create policy donation_read on public.stripe_donations for select to authenticated using((select private.enabled()) and (member_id=(select auth.uid()) or (select private.permission('relations'))));
create policy newsletter_read on public.newsletters for select to authenticated using((select private.enabled()));
create policy newsletter_write on public.newsletters for all to authenticated using((select private.permission('newsletter'))) with check((select private.permission('newsletter')));
create policy announcement_read on public.announcements for select to authenticated using((select private.enabled()));
create policy announcement_write on public.announcements for all to authenticated using((select private.permission('news'))) with check((select private.permission('news')));
create policy relations_write on public.parent_relations for all to authenticated using((select private.permission('relations')) and exists(select 1 from public.parents p where p.user_id=parent_relations.user_id and p.approved and not p.rejected and p.deactivated_at is null)) with check((select private.permission('relations')) and exists(select 1 from public.parents p where p.user_id=parent_relations.user_id and p.approved and not p.rejected and p.deactivated_at is null));
create policy contacts_write on public.parent_contacts for all to authenticated using((select private.permission('relations')) and exists(select 1 from public.parents p where p.user_id=parent_contacts.user_id and p.approved and not p.rejected and p.deactivated_at is null)) with check((select private.permission('relations')) and exists(select 1 from public.parents p where p.user_id=parent_contacts.user_id and p.approved and not p.rejected and p.deactivated_at is null));
create policy manual_donation_read on public.parent_donations for select to authenticated using((select private.enabled()) and user_id=(select auth.uid()));
create policy manual_donation_write on public.parent_donations for all to authenticated using((select private.permission('relations')) and exists(select 1 from public.parents p where p.user_id=parent_donations.user_id and p.approved and not p.rejected and p.deactivated_at is null)) with check((select private.permission('relations')) and exists(select 1 from public.parents p where p.user_id=parent_donations.user_id and p.approved and not p.rejected and p.deactivated_at is null));
-- Server-only tables have no client policy.
do $$declare t text; begin foreach t in array array['parents','parent_private','parent_admin_permissions','newsletters','announcements','parent_relations','parent_contacts','parent_donations'] loop execute format('create trigger audit_change after insert or update or delete on public.%I for each row execute function private.audit()',t); end loop; end$$;
-- Function ACLs: private helpers are unavailable through PostgREST.
revoke execute on all functions in schema private from public,anon,authenticated;
grant execute on function private.enabled(),private.permission(text),private.not_deactivated() to authenticated;
revoke execute on all functions in schema public from public,anon,authenticated;
grant execute on function public.has_admin_permission(text),public.save_parent_profile(text,text,text,text,text,text,text,text,text,text,text),public.admin_parent_access(uuid,text),public.set_parent_permissions(uuid,text[],text) to authenticated;
grant execute on function public.record_stripe_donation_event(text,uuid,text,text,text,bigint) to service_role;
insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types) values('parent-avatars','parent-avatars',false,5242880,array['image/jpeg','image/png','image/webp']),('parent-newsletters','parent-newsletters',false,20971520,array['application/pdf']);
create policy avatar_read on storage.objects for select to authenticated using(bucket_id='parent-avatars' and (select private.enabled()));
create policy avatar_insert on storage.objects for insert to authenticated with check(bucket_id='parent-avatars' and (select private.enabled()) and (storage.foldername(name))[1]=(select auth.uid())::text);
create policy avatar_update on storage.objects for update to authenticated using(bucket_id='parent-avatars' and (select private.enabled()) and (storage.foldername(name))[1]=(select auth.uid())::text) with check(bucket_id='parent-avatars' and (select private.enabled()) and (storage.foldername(name))[1]=(select auth.uid())::text);
create policy newsletter_storage_read on storage.objects for select to authenticated using(bucket_id='parent-newsletters' and (select private.enabled()));
create policy newsletter_storage_write on storage.objects for all to authenticated using(bucket_id='parent-newsletters' and (select private.permission('newsletter'))) with check(bucket_id='parent-newsletters' and (select private.permission('newsletter')));

create function public.admin_edit_parent(p_user_id uuid,p_full_name text,p_username text,p_relationship text,p_email text,p_phone text,p_city text,p_state text,p_directory_email text,p_directory_phone text,p_student_name text,p_student_details text) returns void language plpgsql security definer set search_path='' as $$
declare target public.parents; begin
 if not private.permission('parents') then raise exception 'Parent administrator required'; end if;
 select * into target from public.parents where user_id=p_user_id for update;
 if not found or target.protected or target.role='super_admin' then raise exception 'Protected account'; end if;
 if target.role='admin' and not exists(select 1 from public.parents where user_id=auth.uid() and role='super_admin') then raise exception 'Super administrator required';end if;
 if length(trim(p_full_name))<2 or length(trim(p_email))<3 or length(trim(p_phone))<7 or p_relationship not in ('Parent','Guardian','Other family') then raise exception 'Complete the required fields';end if;
 update public.parents set full_name=trim(p_full_name),username=lower(trim(p_username)),relationship=p_relationship,city=p_city,state=p_state,directory_email=p_directory_email,directory_phone=p_directory_phone where user_id=p_user_id;
 update public.parent_private set email=p_email,phone=p_phone,student_name=p_student_name,student_details=p_student_details where user_id=p_user_id;
 end$$;
revoke all on function public.admin_edit_parent(uuid,text,text,text,text,text,text,text,text,text,text,text) from public,anon;
grant execute on function public.admin_edit_parent(uuid,text,text,text,text,text,text,text,text,text,text,text) to authenticated;

drop policy parent_read on public.parents; create policy parent_read on public.parents for select to authenticated using(user_id=(select auth.uid()) or (select private.permission('parents')) or (select private.permission('requests')) or ((select private.permission('relations')) and approved and not rejected and deactivated_at is null)); create function private.directory() returns table(user_id uuid,full_name text,username text,relationship text,city text,state text,directory_email text,directory_phone text) language sql stable security definer set search_path='' as $$ select p.user_id,p.full_name,p.username,p.relationship,p.city,p.state,p.directory_email,p.directory_phone from public.parents p where private.enabled() and p.approved and not p.rejected and p.deactivated_at is null order by p.full_name $$; revoke all on function private.directory() from public,anon; grant execute on function private.directory() to authenticated; create function public.get_parent_directory() returns table(user_id uuid,full_name text,username text,relationship text,city text,state text,directory_email text,directory_phone text) language sql stable security invoker set search_path='' as $$ select * from private.directory() $$; revoke all on function public.get_parent_directory() from public,anon; grant execute on function public.get_parent_directory() to authenticated;
alter function public.save_parent_profile(text,text,text,text,text,text,text,text,text,text,text) set schema private;
alter function public.admin_parent_access(uuid,text) set schema private;
alter function public.set_parent_permissions(uuid,text[],text) set schema private;
alter function public.admin_edit_parent(uuid,text,text,text,text,text,text,text,text,text,text,text) set schema private;
create function public.save_parent_profile(p_full_name text,p_username text,p_relationship text,p_email text,p_phone text,p_city text default '',p_state text default '',p_directory_email text default '',p_directory_phone text default '',p_student_name text default '',p_student_details text default '') returns void language sql security invoker set search_path='' as $$select private.save_parent_profile(p_full_name,p_username,p_relationship,p_email,p_phone,p_city,p_state,p_directory_email,p_directory_phone,p_student_name,p_student_details)$$;
create function public.admin_parent_access(p_user_id uuid,p_action text) returns void language sql security invoker set search_path='' as $$select private.admin_parent_access(p_user_id,p_action)$$;
create function public.set_parent_permissions(p_user_id uuid,p_permissions text[],p_role text default 'parent') returns void language sql security invoker set search_path='' as $$select private.set_parent_permissions(p_user_id,p_permissions,p_role)$$;
create function public.admin_edit_parent(p_user_id uuid,p_full_name text,p_username text,p_relationship text,p_email text,p_phone text,p_city text,p_state text,p_directory_email text,p_directory_phone text,p_student_name text,p_student_details text) returns void language sql security invoker set search_path='' as $$select private.admin_edit_parent(p_user_id,p_full_name,p_username,p_relationship,p_email,p_phone,p_city,p_state,p_directory_email,p_directory_phone,p_student_name,p_student_details)$$;
revoke all on function public.save_parent_profile(text,text,text,text,text,text,text,text,text,text,text),public.admin_parent_access(uuid,text),public.set_parent_permissions(uuid,text[],text),public.admin_edit_parent(uuid,text,text,text,text,text,text,text,text,text,text,text) from public,anon;
grant execute on function public.save_parent_profile(text,text,text,text,text,text,text,text,text,text,text),public.admin_parent_access(uuid,text),public.set_parent_permissions(uuid,text[],text),public.admin_edit_parent(uuid,text,text,text,text,text,text,text,text,text,text,text) to authenticated;
alter table public.stripe_donations add column verification boolean not null default false; alter table public.stripe_donations add constraint verification_amount check(not verification or amount_cents=100);
alter table public.admin_activity_log add column actor_name text,add column record_label text;
create or replace function private.audit() returns trigger language plpgsql security definer set search_path='' as $$
declare j jsonb;label text;actor text;begin
 if private.permission('activity') or exists(select 1 from public.parents where user_id=auth.uid() and role in ('admin','super_admin') and deactivated_at is null) or exists(select 1 from public.parent_admin_permissions where user_id=auth.uid()) then
 j=coalesce(to_jsonb(new),to_jsonb(old));
 select full_name into actor from public.parents where user_id=auth.uid();
 label=coalesce(j->>'title',j->>'full_name',(select full_name from public.parents where user_id::text=j->>'user_id'),'Portal record');
 if j->>'permission' is not null then label=label||' · '||(j->>'permission');end if;
 insert into public.admin_activity_log(actor_id,actor_name,action,record_id,record_label) values(auth.uid(),coalesce(nullif(actor,''),'Administrator'),tg_table_name||'.'||lower(tg_op),coalesce(j->>'id',j->>'user_id'),label);
 end if;return coalesce(new,old);end$$;
alter table public.parent_contacts alter column contact_date set default (now() at time zone 'America/Chicago')::date; alter table public.parent_donations alter column donation_date set default (now() at time zone 'America/Chicago')::date;
alter table public.parents drop constraint parents_relationship_check; alter table public.parents add constraint parents_relationship_check check(relationship in ('','Parent','Guardian','Other family','Executive Staff'));
create or replace function private.save_parent_profile(p_full_name text,p_username text,p_relationship text,p_email text,p_phone text,p_city text default '',p_state text default '',p_directory_email text default '',p_directory_phone text default '',p_student_name text default '',p_student_details text default '') returns void language plpgsql security definer set search_path='' as $$begin
 if auth.uid() is null or not private.not_deactivated() then raise exception 'Sign in required'; end if;
 if length(trim(p_full_name))<2 or length(trim(p_email))<3 or length(trim(p_phone))<7 or p_relationship not in ('Parent','Guardian','Other family','Executive Staff') then raise exception 'Complete the required profile fields'; end if;
 update public.parents set full_name=trim(p_full_name),username=lower(trim(p_username)),relationship=p_relationship,city=p_city,state=p_state,directory_email=p_directory_email,directory_phone=p_directory_phone,profile_complete=true where user_id=auth.uid();
 update public.parent_private set email=p_email,phone=p_phone,student_name=p_student_name,student_details=p_student_details where user_id=auth.uid();
 end$$;
create or replace function private.admin_edit_parent(p_user_id uuid,p_full_name text,p_username text,p_relationship text,p_email text,p_phone text,p_city text,p_state text,p_directory_email text,p_directory_phone text,p_student_name text,p_student_details text) returns void language plpgsql security definer set search_path='' as $$
declare target public.parents; begin
 if not private.permission('parents') then raise exception 'Parent administrator required'; end if;
 select * into target from public.parents where user_id=p_user_id for update;
 if not found or target.protected or target.role='super_admin' then raise exception 'Protected account'; end if;
 if target.role='admin' and not exists(select 1 from public.parents where user_id=auth.uid() and role='super_admin') then raise exception 'Super administrator required';end if;
 if length(trim(p_full_name))<2 or length(trim(p_email))<3 or length(trim(p_phone))<7 or p_relationship not in ('Parent','Guardian','Other family','Executive Staff') then raise exception 'Complete the required fields';end if;
 update public.parents set full_name=trim(p_full_name),username=lower(trim(p_username)),relationship=p_relationship,city=p_city,state=p_state,directory_email=p_directory_email,directory_phone=p_directory_phone where user_id=p_user_id;
 update public.parent_private set email=p_email,phone=p_phone,student_name=p_student_name,student_details=p_student_details where user_id=p_user_id;
 end$$;
create or replace function private.directory() returns table(user_id uuid,full_name text,username text,relationship text,city text,state text,directory_email text,directory_phone text) language sql stable security definer set search_path='' as $$ select p.user_id,p.full_name,p.username,p.relationship,p.city,p.state,p.directory_email,p.directory_phone from public.parents p where private.enabled() and p.approved and not p.rejected and p.deactivated_at is null and p.relationship<>'Executive Staff' order by p.full_name $$;
-- Private announcement images, isolated to the Parents Portal.
alter table public.announcements add column image_paths text[] not null default '{}', add column image_description text not null default '';
alter table public.announcements add constraint announcement_image_paths_valid check (
 cardinality(image_paths)<=6 and array_position(image_paths,null) is null and
 (cardinality(image_paths)=0 or (array_ndims(image_paths)=1 and array_to_string(image_paths,',') ~ '^([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.(jpg|png|webp))(,[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.(jpg|png|webp))*$'))
), add constraint announcement_image_description_valid check(length(image_description)<=500);
insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types) values('parent-announcements','parent-announcements',false,5242880,array['image/jpeg','image/png','image/webp']);
create policy announcement_image_read on storage.objects for select to authenticated using(bucket_id='parent-announcements' and ((select private.permission('news')) or ((select private.enabled()) and exists(select 1 from public.announcements a where name=any(a.image_paths)))));
create policy announcement_image_insert on storage.objects for insert to authenticated with check(bucket_id='parent-announcements' and (select private.permission('news')) and name ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.(jpg|png|webp)$');
create policy announcement_image_delete on storage.objects for delete to authenticated using(bucket_id='parent-announcements' and (select private.permission('news')));

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
