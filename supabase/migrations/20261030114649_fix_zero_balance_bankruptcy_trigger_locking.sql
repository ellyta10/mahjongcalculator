
create or replace function private.queue_zero_balance_bankruptcy()
returns trigger language plpgsql security definer set search_path to ''
as $function$
declare v_balance numeric; v_user_id uuid; v_name text;
begin
 if new.from_round_player_id is null or new.entry_type not in ('payment','player_transfer','dealer_adjustment') then return new; end if;
 select rp.user_id,rp.display_name into v_user_id,v_name from public.round_players rp where rp.id=new.from_round_player_id for update;
 if not found then return new; end if;
 select b.current_balance into v_balance from public.round_player_balances b where b.round_player_id=new.from_round_player_id;
 if coalesce(v_balance,0)>0 then return new; end if;
 if exists(select 1 from public.bankruptcy_requests br where br.round_id=new.round_id and br.round_player_id=new.from_round_player_id and br.status='requested') then
  update public.bankruptcy_requests set request_type='auto_zero' where round_id=new.round_id and round_player_id=new.from_round_player_id and status='requested';
 else
  insert into public.bankruptcy_requests(room_id,round_id,round_player_id,requested_by,request_type) values(new.room_id,new.round_id,new.from_round_player_id,v_user_id,'auto_zero');
 end if;
 update public.round_players set bankrupt_requested_at=coalesce(bankrupt_requested_at,now()) where id=new.from_round_player_id;
 insert into public.audit_log(room_id,round_id,actor_user_id,event_type,details)
 values(new.room_id,new.round_id,v_user_id,'bankruptcy_auto_zero_detected',jsonb_build_object('round_player_id',new.from_round_player_id,'display_name',v_name,'ledger_entry_id',new.id));
 return new;
end;
$function$;
