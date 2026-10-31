-- Player join approval: requests remain outside active membership until Host approval.
create table if not exists public.room_join_requests (
  id uuid primary key default gen_random_uuid(),
  room_id uuid not null references public.rooms(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  display_name text not null check (char_length(btrim(display_name)) between 1 and 40),
  seat_no smallint not null check (seat_no between 1 and 4),
  status text not null default 'pending' check (status in ('pending','approved','rejected','cancelled')),
  requested_at timestamptz not null default now(),
  reviewed_by uuid references auth.users(id),
  reviewed_at timestamptz,
  constraint room_join_requests_room_user_unique unique (room_id,user_id)
);
create unique index if not exists room_join_requests_pending_seat_uidx
  on public.room_join_requests(room_id,seat_no) where status='pending';
create index if not exists room_join_requests_room_status_requested_idx
  on public.room_join_requests(room_id,status,requested_at desc);
alter table public.room_join_requests enable row level security;
drop policy if exists room_join_requests_read_own_or_dealer on public.room_join_requests;
create policy room_join_requests_read_own_or_dealer on public.room_join_requests
for select to authenticated
using (user_id=auth.uid() or exists (
  select 1 from public.room_members rm where rm.room_id=room_join_requests.room_id
  and rm.user_id=auth.uid() and rm.role='dealer' and rm.member_status='active'
));
revoke all on public.room_join_requests from anon,authenticated;
grant select on public.room_join_requests to authenticated;

create or replace function public.request_room_join(p_invite_code text,p_display_name text,p_seat_no smallint)
returns jsonb language plpgsql security definer set search_path=''
as $$
declare v_user_id uuid:=auth.uid(); v_code text:=upper(btrim(coalesce(p_invite_code,'')));
v_room_id uuid; v_round_id uuid; v_round_status text; v_room_status text; v_request_id uuid;
begin
 if v_user_id is null or coalesce((auth.jwt()->>'is_anonymous')::boolean,false) is not true then raise exception 'Guest session required.' using errcode='28000'; end if;
 if char_length(v_code) not between 12 and 64 or v_code !~ '^[A-Z0-9-]+$' then raise exception 'Kode room tidak valid.' using errcode='22023'; end if;
 if p_display_name is null or char_length(btrim(p_display_name)) not between 1 and 40 then raise exception 'Nama harus berisi 1 sampai 40 karakter.' using errcode='22023'; end if;
 if p_seat_no is null or p_seat_no not between 1 and 4 then raise exception 'Pilih seat 1 sampai 4.' using errcode='22023'; end if;
 select id,active_round_id,status into v_room_id,v_round_id,v_room_status from public.rooms
 where invite_code_hash=encode(extensions.digest(v_code,'sha256'),'hex') for update;
 if v_room_id is null or v_round_id is null or v_room_status<>'open' then raise exception 'Room tidak ditemukan atau sudah ditutup.' using errcode='22023'; end if;
 select status into v_round_status from public.rounds where id=v_round_id and room_id=v_room_id for update;
 if not found or v_round_status<>'setup' then raise exception 'Permintaan Player hanya dapat diajukan sebelum ronde dimulai.' using errcode='22023'; end if;
 if exists(select 1 from public.room_members rm where rm.room_id=v_room_id and rm.member_status='active' and (rm.user_id=v_user_id or lower(rm.display_name)=lower(btrim(p_display_name)))) then raise exception 'Kamu atau nama ini sudah terdaftar di Room.' using errcode='23505'; end if;
 if exists(select 1 from public.room_members rm where rm.room_id=v_room_id and rm.seat_no=p_seat_no and rm.member_status='active') then raise exception 'Seat sudah terisi. Pilih seat lain.' using errcode='23505'; end if;
 if exists(select 1 from public.room_join_requests q where q.room_id=v_room_id and q.user_id=v_user_id and q.status='pending') then raise exception 'Permintaan kamu masih menunggu persetujuan Host.' using errcode='23505'; end if;
 insert into public.room_join_requests(room_id,user_id,display_name,seat_no,status,requested_at,reviewed_by,reviewed_at)
 values(v_room_id,v_user_id,btrim(p_display_name),p_seat_no,'pending',now(),null,null)
 on conflict(room_id,user_id) do update set display_name=excluded.display_name,seat_no=excluded.seat_no,status='pending',requested_at=now(),reviewed_by=null,reviewed_at=null
 returning id into v_request_id;
 insert into public.audit_log(room_id,round_id,actor_user_id,event_type,details)
 values(v_room_id,v_round_id,v_user_id,'player_join_requested',jsonb_build_object('display_name',btrim(p_display_name),'seat_no',p_seat_no));
 return jsonb_build_object('request_id',v_request_id,'room_id',v_room_id,'status','pending');
end; $$;

create or replace function public.get_my_room_join_request(p_room_id uuid)
returns jsonb language plpgsql stable security definer set search_path=''
as $$
declare v_result jsonb;
begin
 if auth.uid() is null then raise exception 'Authentication required.' using errcode='28000'; end if;
 select jsonb_build_object('id',q.id,'room_id',q.room_id,'display_name',q.display_name,'seat_no',q.seat_no,'status',q.status,'requested_at',q.requested_at,'reviewed_at',q.reviewed_at)
 into v_result from public.room_join_requests q where q.room_id=p_room_id and q.user_id=auth.uid() order by q.requested_at desc limit 1;
 return v_result;
end; $$;

create or replace function public.review_room_join_request(p_request_id uuid,p_approve boolean)
returns jsonb language plpgsql security definer set search_path=''
as $$
declare v_user_id uuid:=auth.uid(); v_req public.room_join_requests%rowtype; v_room public.rooms%rowtype; v_round public.rounds%rowtype;
begin
 if v_user_id is null then raise exception 'Authentication required.' using errcode='28000'; end if;
 select * into v_req from public.room_join_requests where id=p_request_id for update;
 if not found then raise exception 'Permintaan tidak ditemukan.' using errcode='P0002'; end if;
 if not exists(select 1 from public.room_members rm where rm.room_id=v_req.room_id and rm.user_id=v_user_id and rm.role='dealer' and rm.member_status='active') then raise exception 'Hanya Host room yang dapat meninjau permintaan.' using errcode='42501'; end if;
 if v_req.status<>'pending' then raise exception 'Permintaan ini sudah ditinjau.' using errcode='55000'; end if;
 select * into v_room from public.rooms where id=v_req.room_id for update;
 select * into v_round from public.rounds where id=v_room.active_round_id and room_id=v_room.id for update;
 if p_approve then
  if v_room.status<>'open' or v_round.status<>'setup' then raise exception 'Room sudah tidak menerima Player baru.' using errcode='55000'; end if;
  if exists(select 1 from public.room_members rm where rm.room_id=v_req.room_id and rm.member_status='active' and (rm.seat_no=v_req.seat_no or lower(rm.display_name)=lower(v_req.display_name))) then raise exception 'Seat atau nama sudah digunakan. Tolak permintaan ini dan minta Player memilih seat lain.' using errcode='23505'; end if;
  if exists(select 1 from public.room_members rm where rm.room_id=v_req.room_id and rm.user_id=v_req.user_id) then raise exception 'Player sudah terdaftar di Room.' using errcode='23505'; end if;
  insert into public.room_members(room_id,user_id,role,seat_no,display_name,member_status) values(v_req.room_id,v_req.user_id,'player',v_req.seat_no,v_req.display_name,'active');
  insert into public.round_players(room_id,round_id,user_id,seat_no,display_name,starting_balance) values(v_req.room_id,v_round.id,v_req.user_id,v_req.seat_no,v_req.display_name,v_room.default_starting_balance);
 end if;
 update public.room_join_requests set status=case when p_approve then 'approved' else 'rejected' end,reviewed_by=v_user_id,reviewed_at=now() where id=v_req.id;
 insert into public.audit_log(room_id,round_id,actor_user_id,event_type,details)
 values(v_req.room_id,v_round.id,v_user_id,case when p_approve then 'player_join_approved' else 'player_join_rejected' end,jsonb_build_object('request_id',v_req.id,'player_name',v_req.display_name,'seat_no',v_req.seat_no));
 return jsonb_build_object('request_id',v_req.id,'status',case when p_approve then 'approved' else 'rejected' end);
end; $$;

revoke all on function public.request_room_join(text,text,smallint) from public,anon;
revoke all on function public.get_my_room_join_request(uuid) from public,anon;
revoke all on function public.review_room_join_request(uuid,boolean) from public,anon;
grant execute on function public.request_room_join(text,text,smallint) to authenticated;
grant execute on function public.get_my_room_join_request(uuid) to authenticated;
grant execute on function public.review_room_join_request(uuid,boolean) to authenticated;
