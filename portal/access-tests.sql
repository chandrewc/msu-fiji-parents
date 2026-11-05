begin;
-- Synthetic users exist only within this rolled-back transaction. No emails sent.
insert into auth.users(id,email) values
('10000000-0000-4000-8000-000000000001','parent-one@example.invalid'),
('10000000-0000-4000-8000-000000000002','parent-two@example.invalid'),
('10000000-0000-4000-8000-000000000003','admin@example.invalid'),
('10000000-0000-4000-8000-000000000004','pending@example.invalid');
update public.parents set full_name='Test Parent',username='test_'||right(user_id::text,1),relationship='Parent',approved=true,profile_complete=true;
update public.parents set role='super_admin',protected=true where user_id='10000000-0000-4000-8000-000000000003';
update public.parents set approved=false where user_id='10000000-0000-4000-8000-000000000004';
insert into public.newsletters(title,issue_date) values('Test Issue',current_date);
insert into public.parent_donations(user_id,amount_cents) values('10000000-0000-4000-8000-000000000001',2500),('10000000-0000-4000-8000-000000000002',5000);
insert into public.stripe_donations(id,member_id,amount_cents,checkout_session_id) values('20000000-0000-4000-8000-000000000001','10000000-0000-4000-8000-000000000001',2500,'cs_portal_fixture');
set local role authenticated;
select set_config('request.jwt.claim.sub','10000000-0000-4000-8000-000000000001',true);
do $$begin
 if (select count(*) from public.parents)<>3 then raise exception 'Directory access failed';end if;
 if (select count(*) from public.parent_private)<>1 then raise exception 'Student privacy failed';end if;
 if (select count(*) from public.parent_donations)<>1 then raise exception 'Donation ownership failed';end if;
 if (select public.has_admin_permission('parents')) then raise exception 'Ordinary parent has admin';end if;
 begin update public.parents set approved=true;raise exception 'Direct status update was allowed';exception when insufficient_privilege then null;end;
 begin perform public.admin_parent_access('10000000-0000-4000-8000-000000000002','deactivate');raise exception 'Non-admin access change allowed';exception when raise_exception then if sqlerrm='Non-admin access change allowed' then raise;end if;end;
end$$;
select set_config('request.jwt.claim.sub','10000000-0000-4000-8000-000000000004',true);
do $$begin
 if (select count(*) from public.parents)<>1 then raise exception 'Pending account sees directory';end if;
 if (select count(*) from public.newsletters)<>0 then raise exception 'Pending account sees publications';end if;
end$$;
select set_config('request.jwt.claim.sub','10000000-0000-4000-8000-000000000003',true);
select public.admin_parent_access('10000000-0000-4000-8000-000000000002','deactivate');
select set_config('request.jwt.claim.sub','10000000-0000-4000-8000-000000000002',true);
do $$begin
 if (select count(*) from public.newsletters)<>0 or (select count(*) from public.parent_private)<>0 or (select count(*) from public.parent_donations)<>0 then raise exception 'Deactivated account retains private access';end if;
end$$;
select set_config('request.jwt.claim.sub','10000000-0000-4000-8000-000000000003',true);
select public.admin_parent_access('10000000-0000-4000-8000-000000000002','reactivate');
select public.set_parent_permissions('10000000-0000-4000-8000-000000000002',array['newsletter'],'parent');
select set_config('request.jwt.claim.sub','10000000-0000-4000-8000-000000000002',true);
do $$begin
 if not public.has_admin_permission('newsletter') or public.has_admin_permission('news') then raise exception 'Delegated permissions failed';end if;
end$$;
insert into public.newsletters(title,issue_date) values('Delegated Publish',current_date);
update public.newsletters set title='Delegated Edit' where title='Delegated Publish';
delete from public.newsletters where title='Delegated Edit';
reset role;
select public.record_stripe_donation_event('evt_fixture_one','20000000-0000-4000-8000-000000000001','cs_portal_fixture','pi_fixture','paid',0);
select public.record_stripe_donation_event('evt_fixture_one','20000000-0000-4000-8000-000000000001','cs_portal_fixture','pi_fixture','paid',0);
select public.record_stripe_donation_event('evt_fixture_two','20000000-0000-4000-8000-000000000001','cs_portal_fixture','pi_fixture','failed',0);
select public.record_stripe_donation_event('evt_fixture_three','20000000-0000-4000-8000-000000000001','cs_portal_fixture','pi_fixture','partially_refunded',1000);
select public.record_stripe_donation_event('evt_fixture_four','20000000-0000-4000-8000-000000000001','cs_portal_fixture','pi_fixture','paid',0);
do $$begin
 if not exists(select 1 from public.stripe_donations where id='20000000-0000-4000-8000-000000000001' and status='partially_refunded' and refunded_cents=1000) then raise exception 'Out of order refund regression';end if;
 if (select count(*) from public.stripe_donation_events)<>4 then raise exception 'Duplicate event inserted';end if;
 if not exists(select 1 from public.admin_activity_log where action='newsletters.delete') then raise exception 'Audit missing';end if;
end$$;
select 'All access, publishing, delegation, deactivation and payment-state assertions passed' as result;
rollback;
