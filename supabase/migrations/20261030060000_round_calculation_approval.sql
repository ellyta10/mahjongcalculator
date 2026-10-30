
create table if not exists public.round_calculation_submissions (
  id uuid primary key default gen_random_uuid(),
  room_id uuid not null,
  round_id uuid not null,
  submitted_by uuid not null references auth.users(id),
  client_request_id uuid not null,
  snapshot jsonb not null,
  status text not null default 'pending' check (status in ('pending','approved','rejected')),
  reviewed_by uuid references auth.users(id),
  reviewed_at timestamptz,
  created_at timestamptz not null default now(),
  unique (round_id, submitted_by, client_request_id),
  foreign key (room_id, round_id) references public.rounds(room_id, id) on delete cascade
);

create index if not exists round_calculation_submissions_room_round_created_idx
  on public.round_calculation_submissions(room_id, round_id, created_at desc);

alter table public.round_calculation_submissions enable row level security;
revoke all on public.round_calculation_submissions from anon, authenticated;
grant select on public.round_calculation_submissions to authenticated;

drop policy if exists room_members_read_calculation_submissions on public.round_calculation_submissions;
create policy room_members_read_calculation_submissions
  on public.round_calculation_submissions for select to authenticated
  using (private.is_room_member(room_id));

create or replace function private.reject_calculation_submission_delete()
returns trigger language plpgsql security definer set search_path = ''
as $$
begin
  raise exception 'Calculation submissions are append-only.' using errcode = '55000';
end;
$$;

drop trigger if exists reject_calculation_submission_delete on public.round_calculation_submissions;
create trigger reject_calculation_submission_delete
before delete on public.round_calculation_submissions
for each row execute function private.reject_calculation_submission_delete();

create or replace function public.submit_round_calculation(
  p_round_id uuid, p_snapshot jsonb, p_client_request_id uuid
)
returns uuid language plpgsql security definer set search_path = ''
as $$
declare
  v_round public.rounds%rowtype;
  v_user uuid := auth.uid();
  v_role text;
  v_rate numeric;
  v_count integer;
  v_seats integer;
  v_net numeric;
  v_id uuid;
  v_existing jsonb;
begin
  if v_user is null then raise exception 'Login required.' using errcode = '28000'; end if;
  if p_client_request_id is null
     or jsonb_typeof(p_snapshot) <> 'object'
     or jsonb_typeof(p_snapshot->'players') <> 'array'
     or jsonb_typeof(p_snapshot->'obligations') <> 'array' then
    raise exception 'Invalid calculation snapshot.' using errcode = '22023';
  end if;
  v_rate := (p_snapshot->>'chip_rate')::numeric;
  if v_rate <= 0 or v_rate <> trunc(v_rate) then
    raise exception 'Chip rate must be a positive integer.' using errcode = '22023';
  end if;

  select * into v_round from public.rounds where id = p_round_id for update;
  if not found then raise exception 'Round not found.' using errcode = '22023'; end if;

  select role into v_role from public.room_members
  where room_id = v_round.room_id and user_id = v_user and member_status = 'active';
  if v_role not in ('dealer','player') then
    raise exception 'Only Dealer or Player can submit a result.' using errcode = '42501';
  end if;
  if v_round.status <> 'active' or not exists (
    select 1 from public.rooms where id = v_round.room_id
      and active_round_id = v_round.id and status = 'open'
  ) then raise exception 'Round is not active.' using errcode = '55000'; end if;

  select count(*), count(distinct seat_no), coalesce(sum(net_points),0)
  into v_count, v_seats, v_net
  from jsonb_to_recordset(p_snapshot->'players') as p(
    seat_no smallint, round_player_id uuid, display_name text,
    starting_points bigint, final_points bigint, net_points bigint, net_rupiah bigint
  );
  if v_count <> 4 or v_seats <> 4 or v_net <> 0 then
    raise exception 'Four distinct seats and a balanced result are required.' using errcode = '23514';
  end if;

  if exists (
    select 1 from jsonb_to_recordset(p_snapshot->'players') as p(
      seat_no smallint, round_player_id uuid, display_name text,
      starting_points bigint, final_points bigint, net_points bigint, net_rupiah bigint
    )
    left join public.round_players rp
      on rp.id = p.round_player_id and rp.room_id = v_round.room_id
     and rp.round_id = v_round.id and rp.seat_no = p.seat_no
    where rp.id is null or p.seat_no not between 1 and 4
       or p.display_name is null or p.display_name is distinct from rp.display_name
       or p.starting_points is null or p.final_points is null
       or p.net_points is null or p.net_rupiah is null
       or p.starting_points::numeric * v_rate <> rp.starting_balance
       or p.net_points <> p.final_points - p.starting_points
       or p.net_rupiah::numeric <> p.net_points::numeric * v_rate
       or rp.starting_balance + p.net_rupiah < 0
  ) then raise exception 'Result does not match the Room players or starting balances.' using errcode = '23514'; end if;

  if exists (
    select 1 from public.round_players rp
    where rp.room_id = v_round.room_id and rp.round_id = v_round.id
      and not exists (
        select 1 from jsonb_to_recordset(p_snapshot->'players') as p(
          seat_no smallint, round_player_id uuid, display_name text,
          starting_points bigint, final_points bigint, net_points bigint, net_rupiah bigint
        ) where p.round_player_id = rp.id
      )
  ) then raise exception 'All four Room players must be included.' using errcode = '23514'; end if;

  if exists (
    select 1
    from jsonb_to_recordset(p_snapshot->'obligations') as o(
      payer_seat smallint, winner_seat smallint, amount_due bigint
    )
    left join jsonb_to_recordset(p_snapshot->'players') as payer(
      seat_no smallint, round_player_id uuid, display_name text,
      starting_points bigint, final_points bigint, net_points bigint, net_rupiah bigint
    ) on payer.seat_no = o.payer_seat
    left join jsonb_to_recordset(p_snapshot->'players') as winner(
      seat_no smallint, round_player_id uuid, display_name text,
      starting_points bigint, final_points bigint, net_points bigint, net_rupiah bigint
    ) on winner.seat_no = o.winner_seat
    where o.amount_due <= 0 or o.payer_seat = o.winner_seat
       or payer.net_rupiah >= 0 or winner.net_rupiah <= 0
  ) then raise exception 'Invalid payment allocation.' using errcode = '23514'; end if;

  if exists (
    select 1 from jsonb_to_recordset(p_snapshot->'players') as p(
      seat_no smallint, round_player_id uuid, display_name text,
      starting_points bigint, final_points bigint, net_points bigint, net_rupiah bigint
    )
    where (p.net_rupiah < 0 and -p.net_rupiah::numeric <> coalesce((
      select sum(o.amount_due)::numeric from jsonb_to_recordset(p_snapshot->'obligations') as o(
        payer_seat smallint, winner_seat smallint, amount_due bigint
      ) where o.payer_seat = p.seat_no
    ),0))
    or (p.net_rupiah > 0 and p.net_rupiah::numeric <> coalesce((
      select sum(o.amount_due)::numeric from jsonb_to_recordset(p_snapshot->'obligations') as o(
        payer_seat smallint, winner_seat smallint, amount_due bigint
      ) where o.winner_seat = p.seat_no
    ),0))
  ) then raise exception 'Payment allocations must equal the calculated results.' using errcode = '23514'; end if;

  select id, snapshot into v_id, v_existing from public.round_calculation_submissions
  where round_id = p_round_id and submitted_by = v_user and client_request_id = p_client_request_id;
  if found then
    if v_existing is distinct from p_snapshot then raise exception 'Request ID conflict.' using errcode = '23505'; end if;
    return v_id;
  end if;

  insert into public.round_calculation_submissions(room_id,round_id,submitted_by,client_request_id,snapshot)
  values(v_round.room_id,p_round_id,v_user,p_client_request_id,p_snapshot)
  returning id into v_id;

  insert into public.audit_log(room_id,round_id,actor_user_id,event_type,details)
  values(v_round.room_id,p_round_id,v_user,'round_calculation_submitted',jsonb_build_object('submission_id',v_id));
  return v_id;
end;
$$;

create or replace function public.review_round_calculation(p_submission_id uuid,p_approve boolean)
returns uuid language plpgsql security definer set search_path = ''
as $$
declare
  v_sub public.round_calculation_submissions%rowtype;
  v_user uuid := auth.uid();
  v_role text;
  v_winners smallint[];
begin
  if v_user is null or p_approve is null then raise exception 'Login and decision required.' using errcode = '22023'; end if;
  select * into v_sub from public.round_calculation_submissions where id = p_submission_id for update;
  if not found then raise exception 'Submission not found.' using errcode = '22023'; end if;

  perform 1 from public.rounds where id = v_sub.round_id and room_id = v_sub.room_id and status = 'active' for update;
  if not found then raise exception 'Round is no longer active.' using errcode = '55000'; end if;

  select role into v_role from public.room_members
  where room_id = v_sub.room_id and user_id = v_user and member_status = 'active';
  if v_role <> 'dealer' then raise exception 'Only Dealer can review this result.' using errcode = '42501'; end if;
  if v_sub.status <> 'pending' then raise exception 'Submission already reviewed.' using errcode = '55000'; end if;

  if p_approve then
    select array_agg((p->>'seat_no')::smallint order by (p->>'seat_no')::smallint)
      into v_winners
    from jsonb_array_elements(v_sub.snapshot->'players') p
    where (p->>'net_rupiah')::numeric > 0;

    update public.round_players rp
    set final_balance = rp.starting_balance + p.net_rupiah,
        net_result = p.net_rupiah
    from jsonb_to_recordset(v_sub.snapshot->'players') as p(
      seat_no smallint, round_player_id uuid, display_name text,
      starting_points bigint, final_points bigint, net_points bigint, net_rupiah bigint
    )
    where rp.id = p.round_player_id and rp.room_id = v_sub.room_id and rp.round_id = v_sub.round_id;

    if coalesce(cardinality(v_winners),0) > 0 then
      perform public.declare_winners_and_obligations(v_sub.round_id,v_winners,v_sub.snapshot->'obligations');
    end if;
  end if;

  update public.round_calculation_submissions
  set status = case when p_approve then 'approved' else 'rejected' end,
      reviewed_by = v_user, reviewed_at = now()
  where id = v_sub.id;

  insert into public.audit_log(room_id,round_id,actor_user_id,event_type,details)
  values(v_sub.room_id,v_sub.round_id,v_user,
    case when p_approve then 'round_calculation_approved' else 'round_calculation_rejected' end,
    jsonb_build_object('submission_id',v_sub.id));
  return v_sub.id;
end;
$$;

revoke all on function public.submit_round_calculation(uuid,jsonb,uuid) from public,anon;
revoke all on function public.review_round_calculation(uuid,boolean) from public,anon;
grant execute on function public.submit_round_calculation(uuid,jsonb,uuid) to authenticated;
grant execute on function public.review_round_calculation(uuid,boolean) to authenticated;

do $$
declare t text;
begin
  foreach t in array array['rooms','room_members','rounds','round_players','round_winners',
    'payment_obligations','payment_reports','chip_ledger','bankruptcy_requests','audit_log',
    'round_calculation_submissions'] loop
    if not exists(select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename=t) then
      execute format('alter publication supabase_realtime add table public.%I',t);
    end if;
  end loop;
end;
$$;
