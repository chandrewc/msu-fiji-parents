begin;
-- Synthetic accounts and storage metadata are rolled back. No files or emails are created.
insert into auth.users(id,email) values
('61000000-0000-4000-8000-000000000001','images-parent@example.invalid'),
('61000000-0000-4000-8000-000000000002','images-publisher@example.invalid'),
('61000000-0000-4000-8000-000000000003','images-pending@example.invalid'),
('61000000-0000-4000-8000-000000000004','images-newsletter@example.invalid');
update public.parents set full_name='Image test',relationship='Parent',approved=true,profile_complete=true where user_id::text like '61000000-%';
update public.parents set approved=false where user_id='61000000-0000-4000-8000-000000000003';
insert into public.parent_admin_permissions(user_id,permission) values('61000000-0000-4000-8000-000000000002','news'),('61000000-0000-4000-8000-000000000004','newsletter');
set local role authenticated;
select set_config('request.jwt.claim.sub','61000000-0000-4000-8000-000000000001',true);
do $$begin
 begin insert into storage.objects(bucket_id,name) values('parent-announcements','62000000-0000-4000-8000-000000000001.png');raise exception 'Parent upload allowed';exception when insufficient_privilege then null;end;
end$$;
select set_config('request.jwt.claim.sub','61000000-0000-4000-8000-000000000004',true);
do $$begin
 begin insert into storage.objects(bucket_id,name) values('parent-announcements','62000000-0000-4000-8000-000000000001.png');raise exception 'Newsletter-only upload allowed';exception when insufficient_privilege then null;end;
end$$;
select set_config('request.jwt.claim.sub','61000000-0000-4000-8000-000000000002',true);
insert into storage.objects(bucket_id,name) values('parent-announcements','62000000-0000-4000-8000-000000000001.png');
do $$begin
 if not exists(select 1 from storage.objects where bucket_id='parent-announcements' and name='62000000-0000-4000-8000-000000000001.png') then raise exception 'Publisher preview denied';end if;
 begin insert into storage.objects(bucket_id,name) values('parent-announcements','invalid.svg');raise exception 'Invalid image allowed';exception when insufficient_privilege then null;end;
end$$;
select set_config('request.jwt.claim.sub','61000000-0000-4000-8000-000000000001',true);
do $$begin
 if exists(select 1 from storage.objects where bucket_id='parent-announcements' and name='62000000-0000-4000-8000-000000000001.png') then raise exception 'Unpublished image exposed';end if;
end$$;
select set_config('request.jwt.claim.sub','61000000-0000-4000-8000-000000000002',true);
insert into public.announcements(id,title,body,image_paths,image_description) values('63000000-0000-4000-8000-000000000001','Image fixture','Body',array['62000000-0000-4000-8000-000000000001.png'],'Family event');
do $$begin
 begin update public.announcements set image_paths=array['https://example.invalid/x.png'] where id='63000000-0000-4000-8000-000000000001';raise exception 'External image path allowed';exception when check_violation then null;end;
 begin update public.announcements set image_paths=array_fill('62000000-0000-4000-8000-000000000001.png'::text,array[7]) where id='63000000-0000-4000-8000-000000000001';raise exception 'Seven images allowed';exception when check_violation then null;end;
end$$;
select set_config('request.jwt.claim.sub','61000000-0000-4000-8000-000000000001',true);
do $$begin
 if not exists(select 1 from storage.objects where bucket_id='parent-announcements' and name='62000000-0000-4000-8000-000000000001.png') then raise exception 'Approved member image denied';end if;
 begin delete from storage.objects where bucket_id='parent-announcements' and name='62000000-0000-4000-8000-000000000001.png';exception when insufficient_privilege then null;end;
 if not exists(select 1 from storage.objects where bucket_id='parent-announcements' and name='62000000-0000-4000-8000-000000000001.png') then raise exception 'Parent deleted image';end if;
end$$;
select set_config('request.jwt.claim.sub','61000000-0000-4000-8000-000000000003',true);
do $$begin
 if exists(select 1 from storage.objects where bucket_id='parent-announcements' and name='62000000-0000-4000-8000-000000000001.png') then raise exception 'Pending account sees image';end if;
end$$;
reset role;
update public.parents set deactivated_at=now() where user_id='61000000-0000-4000-8000-000000000001';
set local role authenticated;
select set_config('request.jwt.claim.sub','61000000-0000-4000-8000-000000000001',true);
do $$begin
 if exists(select 1 from storage.objects where bucket_id='parent-announcements' and name='62000000-0000-4000-8000-000000000001.png') then raise exception 'Deactivated account sees image';end if;
end$$;
select set_config('request.jwt.claim.sub','61000000-0000-4000-8000-000000000002',true);
update public.announcements set image_paths='{}' where id='63000000-0000-4000-8000-000000000001';
-- Storage deletion itself must be exercised through the Storage API, not SQL.
select 'Announcement image permissions, publication, editing, constraints and image removal from publications passed' as result;
rollback;
