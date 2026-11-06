begin;
-- Disposable fixtures exist only in this rolled-back transaction. No credentials, emails, Checkout sessions or payments are created.
insert into auth.users(id,email) values
('71000000-0000-4000-8000-000000000001','goal-parent@example.invalid'),
('71000000-0000-4000-8000-000000000002','goal-manager@example.invalid'),
('71000000-0000-4000-8000-000000000003','goal-pending@example.invalid');
update public.parents set full_name='Goal test',relationship='Parent',approved=true,profile_complete=true where user_id::text like '71000000-%';
update public.parents set approved=false where user_id='71000000-0000-4000-8000-000000000003';
insert into public.parent_admin_permissions(user_id,permission) values('71000000-0000-4000-8000-000000000002','relations');
set local role authenticated;
select set_config('request.jwt.claim.sub','71000000-0000-4000-8000-000000000002',true);
insert into public.donation_goals(id,title,target_cents) values('72000000-0000-4000-8000-000000000001','Fixture goal',20000),('72000000-0000-4000-8000-000000000002','Other fixture',30000);
insert into public.parent_donations(user_id,amount_cents,goal_id,goal_title) values('71000000-0000-4000-8000-000000000001',2500,'72000000-0000-4000-8000-000000000001','Forged client title');
reset role;
insert into public.stripe_donations(id,member_id,amount_cents,goal_id,status,refunded_cents) values
('73000000-0000-4000-8000-000000000001','71000000-0000-4000-8000-000000000001',10000,'72000000-0000-4000-8000-000000000001','partially_refunded',3000),
('73000000-0000-4000-8000-000000000002','71000000-0000-4000-8000-000000000001',5000,'72000000-0000-4000-8000-000000000001','pending',0),
('73000000-0000-4000-8000-000000000003','71000000-0000-4000-8000-000000000001',5000,'72000000-0000-4000-8000-000000000001','failed',0),
('73000000-0000-4000-8000-000000000004','71000000-0000-4000-8000-000000000001',5000,'72000000-0000-4000-8000-000000000001','refunded',5000);
insert into public.stripe_donations(id,member_id,amount_cents,goal_id,status,verification) values('73000000-0000-4000-8000-000000000005','71000000-0000-4000-8000-000000000001',100,'72000000-0000-4000-8000-000000000001','paid',true);
insert into public.stripe_donations(id,member_id,amount_cents,status) values('73000000-0000-4000-8000-000000000006','71000000-0000-4000-8000-000000000001',9000,'paid');
do $$begin
 if not exists(select 1 from public.parent_donations where goal_id='72000000-0000-4000-8000-000000000001' and goal_title='Fixture goal') then raise exception 'Goal label not stamped by database';end if;
 begin update public.stripe_donations set goal_id='72000000-0000-4000-8000-000000000002' where id='73000000-0000-4000-8000-000000000001';raise exception 'Online goal was reassigned';exception when raise_exception then if sqlerrm='Online goal was reassigned' then raise;end if;end;
end$$;
set local role authenticated;
select set_config('request.jwt.claim.sub','71000000-0000-4000-8000-000000000001',true);
do $$begin
 if (select raised_cents from public.get_donation_goals() where id='72000000-0000-4000-8000-000000000001')<>9500 then raise exception 'Incorrect confirmed net goal total';end if;
 begin insert into public.donation_goals(title,target_cents) values('Unauthorized',100);raise exception 'Parent created goal';exception when insufficient_privilege then null;end;
 update public.donation_goals set title='Unauthorized edit' where id='72000000-0000-4000-8000-000000000001';
 if exists(select 1 from public.donation_goals where title='Unauthorized edit') then raise exception 'Parent edited goal';end if;
 begin delete from public.donation_goals where id='72000000-0000-4000-8000-000000000001';raise exception 'Goal deleted';exception when insufficient_privilege then null;end;
end$$;
select set_config('request.jwt.claim.sub','71000000-0000-4000-8000-000000000002',true);
update public.donation_goals set title='Renamed fixture',active=false where id='72000000-0000-4000-8000-000000000001';
do $$begin
 if (select raised_cents from public.get_donation_goals() where id='72000000-0000-4000-8000-000000000001')<>9500 then raise exception 'Closed goal total disappeared for manager';end if;
 begin insert into public.parent_donations(user_id,amount_cents,goal_id) values('71000000-0000-4000-8000-000000000001',100,'72000000-0000-4000-8000-000000000001');raise exception 'Closed goal accepted gift';exception when raise_exception then if sqlerrm='Closed goal accepted gift' then raise;end if;end;
end$$;
select set_config('request.jwt.claim.sub','71000000-0000-4000-8000-000000000001',true);
do $$begin
 if exists(select 1 from public.get_donation_goals() where id='72000000-0000-4000-8000-000000000001') then raise exception 'Closed goal offered to parent';end if;
 if not exists(select 1 from public.stripe_donations where id='73000000-0000-4000-8000-000000000001' and goal_title='Fixture goal') then raise exception 'Historical label changed';end if;
end$$;
select set_config('request.jwt.claim.sub','71000000-0000-4000-8000-000000000003',true);
do $$begin
 if exists(select 1 from public.get_donation_goals()) or exists(select 1 from public.donation_goals) then raise exception 'Pending account sees goals';end if;
end$$;
select set_config('request.jwt.claim.sub','71000000-0000-4000-8000-000000000002',true);
update public.donation_goals set active=true where id='72000000-0000-4000-8000-000000000001';
reset role;
update public.stripe_donations set refunded_cents=10000,status='refunded' where id='73000000-0000-4000-8000-000000000001';
set local role authenticated;
select set_config('request.jwt.claim.sub','71000000-0000-4000-8000-000000000001',true);
do $$begin
 if (select raised_cents from public.get_donation_goals() where id='72000000-0000-4000-8000-000000000001')<>2500 then raise exception 'Refund total stale';end if;
end$$;
set local role anon;
do $$begin
 begin perform public.get_donation_goals();raise exception 'Anonymous goal access allowed';exception when insufficient_privilege then null;end;
end$$;
reset role;
do $$begin
 if not exists(select 1 from public.admin_activity_log where action='donation_goals.update' and record_id='72000000-0000-4000-8000-000000000001') then raise exception 'Goal audit missing';end if;
end$$;
select 'Goal permissions, totals, refunds, snapshot labels, closure/reopening and audit assertions passed' as result;
rollback;
