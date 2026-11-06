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
