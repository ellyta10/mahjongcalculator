create table if not exists private.room_dealer_credentials (
  room_id uuid primary key references public.rooms(id) on delete cascade,
  pin_hash text not null,
  failed_attempts integer not null default 0 check (failed_attempts >= 0),
  locked_until timestamptz
);
alter table private.room_dealer_credentials enable row level security;
revoke all on table private.room_dealer_credentials from public, anon, authenticated;

create or replace function public.create_room(p_name text,p_dealer_display_name text,p_dealer_pin text)
returns jsonb language plpgsql security definer set search_path = ''
as $function$
declare
  v_user_id uuid := auth.uid();
  v_room_id uuid;
  v_round_id uuid;
  v_code text := upper(encode(extensions.gen_random_bytes(16), 'hex'));
begin
  if v_user_id is null or coalesce((auth.jwt()->>'is_anonymous')::boolean, false) is not true then
    raise exception 'Guest session required.' using errcode = '28000';
  end if;
  if p_name is null or char_length(btrim(p_name)) not between 1 and 80 then
    raise exception 'Room name must contain 1 to 80 characters.' using errcode = '22023';
  end if;
  if p_dealer_display_name is null or char_length(btrim(p_dealer_display_name)) not between 1 and 40 then
    raise exception 'Dealer name must contain 1 to 40 characters.' using errcode = '22023';
  end if;
  if p_dealer_pin is null or p_dealer_pin !~ '^[0-9]{6}$' then
    raise exception 'PIN Dealer harus terdiri dari 6 angka.' using errcode = '22023';
  end if;
  insert into public.rooms (name,invite_code_hash,created_by)
  values (btrim(p_name),encode(extensions.digest(v_code,'sha256'),'hex'),v_user_id)
  returning id into v_room_id;
  insert into private.room_dealer_credentials(room_id,pin_hash)
  values (v_room_id,extensions.crypt(p_dealer_pin,extensions.gen_salt('bf',12)));
  insert into public.room_members(room_id,user_id,role,seat_no,display_name)
  values (v_room_id,v_user_id,'dealer',null,btrim(p_dealer_display_name));
  insert into public.rounds(room_id,round_no,status) values(v_room_id,1,'setup') returning id into v_round_id;
  update public.rooms set active_round_id=v_round_id where id=v_room_id;
  insert into public.audit_log(room_id,round_id,actor_user_id,event_type,details)
  values(v_room_id,v_round_id,v_user_id,'room_created',jsonb_build_object('room_name',btrim(p_name),'round_no',1));
  return jsonb_build_object('room_id',v_room_id,'invite_code',v_code);
end;
$function$;
revoke all on function public.create_room(text,text,text) from public,anon;
grant execute on function public.create_room(text,text,text) to authenticated;

create or replace function public.reclaim_dealer_room(p_invite_code text,p_dealer_display_name text,p_dealer_pin text)
returns uuid language plpgsql security definer set search_path = ''
as $function$
declare
  v_user_id uuid := auth.uid();
  v_code text := upper(btrim(coalesce(p_invite_code,'')));
  v_room_id uuid;
  v_old_user_id uuid;
  v_pin_hash text;
  v_failed_attempts integer;
  v_locked_until timestamptz;
  v_round_id uuid;
begin
  if v_user_id is null or coalesce((auth.jwt()->>'is_anonymous')::boolean,false) is not true then
    raise exception 'Guest session required.' using errcode='28000';
  end if;
  if p_dealer_display_name is null or char_length(btrim(p_dealer_display_name)) not between 1 and 40
     or p_dealer_pin is null or p_dealer_pin !~ '^[0-9]{6}$' then
    return null;
  end if;
  select r.id,r.created_by,cred.pin_hash,cred.failed_attempts,cred.locked_until,r.active_round_id
  into v_room_id,v_old_user_id,v_pin_hash,v_failed_attempts,v_locked_until,v_round_id
  from public.rooms r
  join public.room_members rm on rm.room_id=r.id and rm.user_id=r.created_by
  join private.room_dealer_credentials cred on cred.room_id=r.id
  where r.invite_code_hash=encode(extensions.digest(v_code,'sha256'),'hex')
    and r.status='open' and rm.role='dealer'
    and lower(rm.display_name)=lower(btrim(p_dealer_display_name))
  for update of r,rm,cred;
  if v_room_id is null then return null; end if;
  if v_locked_until is not null and v_locked_until > now() then return null; end if;
  if extensions.crypt(p_dealer_pin,v_pin_hash) <> v_pin_hash then
    update private.room_dealer_credentials
    set failed_attempts=failed_attempts+1,
        locked_until=case when failed_attempts+1 >= 5 then now()+interval '15 minutes' else null end
    where room_id=v_room_id;
    return null;
  end if;
  update private.room_dealer_credentials set failed_attempts=0,locked_until=null where room_id=v_room_id;
  if v_old_user_id=v_user_id then return v_room_id; end if;
  if exists(select 1 from public.room_members x where x.room_id=v_room_id and x.user_id=v_user_id) then
    raise exception 'Guest ini sudah menjadi anggota Room.' using errcode='23505';
  end if;
  update public.room_members set user_id=v_user_id,joined_at=now()
  where room_id=v_room_id and user_id=v_old_user_id and role='dealer';
  update public.rooms set created_by=v_user_id where id=v_room_id;
  insert into public.audit_log(room_id,round_id,actor_user_id,event_type,details)
  values(v_room_id,v_round_id,v_user_id,'dealer_identity_reclaimed',jsonb_build_object('previous_user_id',v_old_user_id));
  return v_room_id;
end;
$function$;
revoke all on function public.reclaim_dealer_room(text,text,text) from public,anon;
grant execute on function public.reclaim_dealer_room(text,text,text) to authenticated;
alter table public.rooms drop column if exists dealer_pin_hash;
