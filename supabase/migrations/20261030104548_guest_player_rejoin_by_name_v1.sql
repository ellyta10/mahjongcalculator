CREATE OR REPLACE FUNCTION public.join_room_by_code(p_invite_code text, p_display_name text, p_role text, p_seat_no smallint DEFAULT NULL::smallint)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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

  select r.id, r.active_round_id, r.status
    into v_room_id, v_round_id, v_room_status
  from public.rooms r
  where r.invite_code_hash = encode(extensions.digest(v_code, 'sha256'), 'hex')
  for update;
  if v_room_id is null or v_round_id is null or v_room_status <> 'open' then
    raise exception 'Room tidak ditemukan atau sudah ditutup.' using errcode = '22023';
  end if;

  select r.status into v_round_status
  from public.rounds r
  where r.id = v_round_id and r.room_id = v_room_id
  for update;
  if not found or v_round_status = 'archived' then
    raise exception 'Room tidak memiliki ronde yang dapat diikuti.' using errcode = '22023';
  end if;

  -- Existing identity recovery: room code + unique display name.
  select rm.user_id, rm.role, rm.seat_no, rm.display_name
    into v_existing_user_id, v_existing_role, v_existing_seat, v_existing_name
  from public.room_members rm
  where rm.room_id = v_room_id
    and rm.member_status = 'active'
    and lower(rm.display_name) = lower(btrim(p_display_name))
  for update;

  if found then
    if v_existing_role <> v_role then
      raise exception 'Nama ini sudah terdaftar dengan role berbeda.' using errcode = '22023';
    end if;
    if v_existing_user_id = v_user_id then
      return v_room_id;
    end if;
    if exists (select 1 from public.room_members x where x.room_id = v_room_id and x.user_id = v_user_id) then
      raise exception 'Guest ini sudah menjadi anggota Room.' using errcode = '23505';
    end if;

    update public.room_members
       set user_id = v_user_id, joined_at = now(), left_at = null
     where room_id = v_room_id and user_id = v_existing_user_id
       and member_status = 'active';
    get diagnostics v_rows = row_count;
    if v_rows <> 1 then
      raise exception 'Gagal memulihkan identitas pemain. Coba lagi.' using errcode = '40001';
    end if;

    insert into public.audit_log (room_id, round_id, actor_user_id, event_type, details)
    values (v_room_id, v_round_id, v_user_id, 'guest_identity_reclaimed',
      jsonb_build_object('role', v_role, 'seat_no', v_existing_seat,
                         'display_name', v_existing_name, 'previous_user_id', v_existing_user_id));
    return v_room_id;
  end if;

  if v_role = 'player' and (p_seat_no is null or p_seat_no not between 1 and 4) then
    raise exception 'Player baru harus memilih kursi 1 sampai 4.' using errcode = '22023';
  end if;
  if exists (select 1 from public.room_members rm
             where rm.room_id = v_room_id and rm.member_status = 'active'
               and lower(rm.display_name) = lower(btrim(p_display_name))) then
    raise exception 'Nama sudah digunakan di Room ini.' using errcode = '23505';
  end if;
  if v_role = 'player' and v_round_status <> 'setup' then
    raise exception 'Player baru hanya dapat bergabung sebelum ronde dimulai.' using errcode = '22023';
  end if;
  if v_role = 'player' and exists (
    select 1 from public.room_members rm
    where rm.room_id = v_room_id and rm.role = 'player'
      and rm.seat_no = p_seat_no and rm.member_status = 'active'
  ) then
    raise exception 'Kursi Player sudah terisi.' using errcode = '23505';
  end if;
  if exists (select 1 from public.room_members rm
             where rm.room_id = v_room_id and rm.user_id = v_user_id) then
    raise exception 'Guest ini sudah terdaftar di Room.' using errcode = '23505';
  end if;

  insert into public.room_members (room_id, user_id, role, seat_no, display_name)
  values (v_room_id, v_user_id, v_role, p_seat_no, btrim(p_display_name));

  if v_role = 'player' then
    insert into public.round_players (room_id, round_id, user_id, seat_no, display_name, starting_balance)
    values (v_room_id, v_round_id, v_user_id, p_seat_no, btrim(p_display_name), 0);
  end if;

  insert into public.audit_log (room_id, round_id, actor_user_id, event_type, details)
  values (v_room_id, v_round_id, v_user_id, 'room_member_joined',
          jsonb_build_object('role', v_role, 'seat_no', p_seat_no));
  return v_room_id;
end;
$function$
