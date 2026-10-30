create or replace function public.review_round_calculation(p_submission_id uuid,p_approve boolean)
returns uuid language plpgsql security definer set search_path = ''
as $$
declare
  v_sub public.round_calculation_submissions%rowtype;
  v_user uuid := auth.uid();
  v_role text;
  v_winners smallint[];
  v_obligations jsonb;
begin
  if v_user is null or p_approve is null then raise exception 'Login and decision required.' using errcode = '22023'; end if;
  select * into v_sub from public.round_calculation_submissions where id = p_submission_id for update;
  if not found then raise exception 'Submission not found.' using errcode = '22023'; end if;

  perform 1 from public.rounds r join public.rooms rm on rm.id = r.room_id where r.id = v_sub.round_id and r.room_id = v_sub.room_id and r.status = 'active' and rm.active_round_id = r.id and rm.status = 'open' for update of r, rm;
  if not found then raise exception 'Round is no longer active.' using errcode = '55000'; end if;

  select role into v_role from public.room_members
  where room_id = v_sub.room_id and user_id = v_user and member_status = 'active';
  if v_role is distinct from 'dealer' then raise exception 'Only Dealer can review this result.' using errcode = '42501'; end if;
  if v_sub.status <> 'pending' then raise exception 'Submission already reviewed.' using errcode = '55000'; end if;

  if p_approve then
    select array_agg((p->>'seat_no')::smallint order by (p->>'seat_no')::smallint)
      into v_winners
    from jsonb_array_elements(v_sub.snapshot->'players') p
    where (p->>'net_rupiah')::numeric > 0;

    if coalesce(cardinality(v_winners),0) > 0 then
      select coalesce(jsonb_agg(jsonb_build_object(
        'payer_seat', o.payer_seat,
        'winner_seat', o.winner_seat,
        'amount_due', o.amount_due::numeric + coalesce(existing.amount_due,0)::numeric
      ) order by o.payer_seat,o.winner_seat),'[]'::jsonb)
      into v_obligations
      from jsonb_to_recordset(v_sub.snapshot->'obligations') as o(
        payer_seat smallint,winner_seat smallint,amount_due bigint
      )
      join public.round_players payer
        on payer.room_id=v_sub.room_id and payer.round_id=v_sub.round_id and payer.seat_no=o.payer_seat
      join public.round_players winner
        on winner.room_id=v_sub.room_id and winner.round_id=v_sub.round_id and winner.seat_no=o.winner_seat
      left join public.payment_obligations existing
        on existing.room_id=v_sub.room_id and existing.round_id=v_sub.round_id
       and existing.payer_round_player_id=payer.id
       and existing.winner_round_player_id=winner.id;

      perform public.declare_winners_and_obligations(v_sub.round_id,v_winners,v_obligations);
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
