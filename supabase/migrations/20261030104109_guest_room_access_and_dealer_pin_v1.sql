alter table public.rooms
  add column if not exists dealer_pin_hash text;

alter table public.round_players
  drop constraint if exists round_players_room_id_user_id_fkey;

alter table public.round_players
  add constraint round_players_room_id_user_id_fkey
  foreign key (room_id, user_id)
  references public.room_members(room_id, user_id)
  on update cascade
  on delete restrict;

create unique index if not exists room_members_active_display_name_uidx
  on public.room_members (room_id, lower(display_name))
  where member_status = 'active';

drop function if exists public.create_room(text, text);

create or replace function public.create_room(p_name text, p_dealer_display_name text, p_dealer_pin text)
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
    raise exception 'Dealer display name must contain 1 to 40 characters.' using errcode = '22023';
  end if;
  if p_dealer_pin is null or p_dealer_pin !~ '^[0-9]{6}$' then
    raise exception 'PIN Dealer harus terdiri dari 6 angka.' using errcode = '22023';
  end if;
  insert into public.rooms (name, invite_code_hash, created_by, dealer_pin_hash)
  values (btrim(p_name), encode(extensions.digest(v_code, 'sha256'), 'hex'),
          v_user_id, extensions.crypt(p_dealer_pin, extensions.gen_salt('bf', 12)))
  returning id into v_room_id;
  insert into public.room_members (room_id, user_id, role, seat_no, display_name)
  values (v_room_id, v_user_id, 'dealer', null, btrim(p_dealer_display_name));
  insert into public.rounds (room_id, round_no, status)
  values (v_room_id, 1, 'setup') returning id into v_round_id;
  update public.rooms set active_round_id = v_round_id where id = v_room_id;
  insert into public.audit_log (room_id, round_id, actor_user_id, event_type, details)
  values (v_room_id, v_round_id, v_user_id, 'room_created',
          jsonb_build_object('room_name', btrim(p_name), 'round_no', 1));
  return jsonb_build_object('room_id', v_room_id, 'invite_code', v_code);
end;
$function$;
revoke all on function public.create_room(text, text, text) from public, anon;
grant execute on function public.create_room(text, text, text) to authenticated;

create or replace function public.join_room_by_code(p_invite_code text, p_display_name text, p_role text, p_seat_no smallint default null)
returns uuid language plpgsql security definer set search_path = ''
as $function$
declare
  v_user_id uuid := auth.uid();
  v_code text := upper(btrim(coalesce(p_invite_code, '')));
  v_role text := lower(btrim(coalesce(p_role, '')));
  v_room_id uuid;
  v_round_id uuid;
  v_round_status text;
  v_room_status text;
  v_existing_user_id uuid;
  v_existing_role text;
  v_existing_seat smallint;
  v_existing_name text;
  v_rows integer;
begin
  if v_user_id is null or coalesce((auth.jwt()->>'is_anonymous')::boolean, false) is not true then
    raise exception 'Guest session required.' using errcode = '28000';
  end if;
  if char_length(v_code) not between 12 and 64 or v_code !~ '^[A-Z0-9-]+$' then
    raise exception 'Kode room tidak valid.' using errcode = '22023';
  end if;
  if p_display_name is null or char_length(btrim(p_display_name)) not between 1 and 40 then
    raise exception 'Nama harus berisi 1 sampai 40 karakter.' using errcode = '22023';
  end if;
  if v_role not in ('player', 'viewer') then
    raise exception 'Role yang dapat bergabung hanya Player atau Viewer.' using errcode = '22023';
  end if;
  if v_role = 'viewer' and p_seat_no is not null then
    raise exception 'Viewer tidak menggunakan kursi.' using errcode = '22023';
  end if;
  select r.id, r.active_round_id, r.status into v_room_id, v_round_id, v_room_status
  from public.rooms r
  where r.invite_code_hash = encode(extensions.digest(v_code, 'sha256'), 'hex')
  for update;
  if v_room_id is null or v_round_id is null or v_room_status <> 'open' then
    raise exception 'Room tidak ditemukan atau sudah ditutup.' using errcode = '22023';
  end if;
  select r.status into v_round_status from public.rounds r
  where r.id = v_round_id and r.room_id = v_room_id for update;
  if not found or v_round_status = 'archived' then
    raise exception 'Room tidak memiliki ronde yang dapat diikuti.' using errcode = '22023';
  end if;
  select rm.user_id, rm.role, rm.seat_no, rm.display_name
  into v_existing_user_id, v_existing_role, v_existing_seat, v_existing_name
  from public.room_members rm
  where rm.room_id = v_room_id and rm.member_status = 'active'
    and lower(rm.display_name) = lower(btrim(p_display_name))
  for update;
  if found then
    if v_existing_role <> v_role then
      raise exception 'Nama ini sudah terdaftar dengan role berbeda.' using errcode = '22023';
    end if;
    if v_existing_user_id = v_user_id then return v_room_id; end if;
    if exists (select 1 from public.room_members x where x.room_id = v_room_id and x.user_id = v_user_id) then
      raise exception 'Guest ini sudah menjadi anggota Room.' using errcode = '23505';
    end if;
    update public.room_members set user_id = v_user_id, joined_at = now(), left_at = null
    where room_id = v_room_id and user_id = v_existing_user_id and member_status = 'active';
    get diagnostics v_rows = row_count;
    if v_rows <> 1 then raise exception 'Gagal memulihkan identitas pemain. Coba lagi.' using errcode = '40001'; end if;
    insert into public.audit_log (room_id, round_id, actor_user_id, event_type, details)
    values (v_room_id, v_round_id, v_user_id, 'guest_identity_reclaimed',
      jsonb_build_object('role', v_role, 'seat_no', v_existing_seat,
        'display_name', v_existing_name, 'previous_user_id', v_existing_user_id));
    return v_room_id;
  end if;
  if v_role = 'player' and (p_seat_no is null or p_seat_no not between 1 and 4) then
    raise exception 'Player baru harus memilih kursi 1 sampai 4.' using errcode = '22023';
  end if;
  if exists (select 1 from public.room_members rm where rm.room_id = v_room_id
    and rm.member_status = 'active' and lower(rm.display_name) = lower(btrim(p_display_name))) then
    raise exception 'Nama sudah digunakan di Room ini.' using errcode = '23505';
  end if;
  if v_role = 'player' and v_round_status <> 'setup' then
    raise exception 'Player baru hanya dapat bergabung sebelum ronde dimulai.' using errcode = '22023';
  end if;
  if v_role = 'player' and exists (select 1 from public.room_members rm
    where rm.room_id = v_room_id and rm.role = 'player' and rm.seat_no = p_seat_no and rm.member_status = 'active') then
    raise exception 'Kursi Player sudah terisi.' using errcode = '23505';
  end if;
  if exists (select 1 from public.room_members rm where rm.room_id = v_room_id and rm.user_id = v_user_id) then
    raise exception 'Guest ini sudah terdaftar di Room.' using errcode = '23505';
  end if;
  insert into public.room_members (room_id, user_id, role, seat_no, display_name)
  values (v_room_id, v_user_id, v_role, p_seat_no, btrim(p_display_name));
  if v_role = 'player' then
    insert into public.round_players (room_id, round_id, user_id, seat_no, display_name, starting_balance)
    values (v_room_id, v_round_id, v_user_id, p_seat_no, btrim(p_display_name), 0);
  end if;
  insert into public.audit_log (room_id, round_id, actor_user_id, event_type, details)
  values (v_room_id, v_round_id, v_user_id, 'room_member_joined', jsonb_build_object('role', v_role, 'seat_no', p_seat_no));
  return v_room_id;
end;
$function$;
revoke all on function public.join_room_by_code(text, text, text, smallint) from public, anon;
grant execute on function public.join_room_by_code(text, text, text, smallint) to authenticated;

create or replace function public.reclaim_dealer_room(p_invite_code text, p_dealer_display_name text, p_dealer_pin text)
returns uuid language plpgsql security definer set search_path = ''
as $function$
declare
  v_user_id uuid := auth.uid();
  v_code text := upper(btrim(coalesce(p_invite_code, '')));
  v_room_id uuid;
  v_old_user_id uuid;
  v_stored_pin_hash text;
  v_round_id uuid;
begin
  if v_user_id is null or coalesce((auth.jwt()->>'is_anonymous')::boolean, false) is not true then
    raise exception 'Guest session required.' using errcode = '28000';
  end if;
  if p_dealer_display_name is null or char_length(btrim(p_dealer_display_name)) not between 1 and 40 then
    raise exception 'Nama Dealer tidak valid.' using errcode = '22023';
  end if;
  if p_dealer_pin is null or p_dealer_pin !~ '^[0-9]{6}$' then
    raise exception 'PIN Dealer harus 6 angka.' using errcode = '22023';
  end if;
  select r.id, r.created_by, r.dealer_pin_hash, r.active_round_id
  into v_room_id, v_old_user_id, v_stored_pin_hash, v_round_id
  from public.rooms r
  join public.room_members rm on rm.room_id = r.id and rm.user_id = r.created_by
  where r.invite_code_hash = encode(extensions.digest(v_code, 'sha256'), 'hex')
    and r.status = 'open' and rm.role = 'dealer'
    and lower(rm.display_name) = lower(btrim(p_dealer_display_name))
  for update of r, rm;
  if v_room_id is null or v_stored_pin_hash is null
    or extensions.crypt(p_dealer_pin, v_stored_pin_hash) <> v_stored_pin_hash then
    raise exception 'Kode Room, nama Dealer, atau PIN salah.' using errcode = '28000';
  end if;
  if v_old_user_id = v_user_id then return v_room_id; end if;
  if exists (select 1 from public.room_members x where x.room_id = v_room_id and x.user_id = v_user_id) then
    raise exception 'Guest ini sudah menjadi anggota Room.' using errcode = '23505';
  end if;
  update public.room_members set user_id = v_user_id, joined_at = now()
  where room_id = v_room_id and user_id = v_old_user_id and role = 'dealer';
  update public.rooms set created_by = v_user_id where id = v_room_id;
  insert into public.audit_log (room_id, round_id, actor_user_id, event_type, details)
  values (v_room_id, v_round_id, v_user_id, 'dealer_identity_reclaimed',
          jsonb_build_object('previous_user_id', v_old_user_id));
  return v_room_id;
end;
$function$;
revoke all on function public.reclaim_dealer_room(text, text, text) from public, anon;
grant execute on function public.reclaim_dealer_room(text, text, text) to authenticated;
