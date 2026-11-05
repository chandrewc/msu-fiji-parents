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
