-- Prepaid card accounts for the serial RFID reader on the pulse input.
--
-- Flow: the reader publishes a card serial to /{company}/{device}/card ->
-- mqtt-webhook resolves the account -> the account balance is delivered to
-- the machine on the /credit topic (the same path send-credit uses) -> the
-- vend that follows arrives as a normal cashless sale and is charged back
-- to the account.
--
-- Accounts are matched by NAME CONTAINING the card serial, so an operator
-- can rename "04A1B2C3" to "Jane Doe (04A1B2C3)" without breaking the card.
-- Keep serials unique across the names in one company; when several names
-- contain the same serial the oldest account wins, deterministically.

-- =========================================================
-- A. card_accounts — one prepaid balance per card / person
-- =========================================================
create table if not exists public.card_accounts (
  id           uuid        primary key default gen_random_uuid(),
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  company_id   uuid        not null references public.companies(id) on delete cascade,
  name         text        not null,
  -- EUR, like sales.item_price and cash_books.initial_balance — not cents.
  balance      float8      not null default 0,
  is_active    boolean     not null default true,
  last_seen_at timestamptz,
  unique (company_id, name)
);

comment on table  public.card_accounts         is 'Prepaid RFID card accounts; matched by card serial contained in name';
comment on column public.card_accounts.name    is 'Free-form; must contain the card serial (uppercase hex) for the reader to find it';
comment on column public.card_accounts.balance is 'Remaining credit in EUR. Auto-created accounts start at 0.';
comment on column public.card_accounts.is_active is 'Deactivated accounts are ignored by the reader — a lost card gets 0 credit';

create index if not exists card_accounts_company_idx
  on public.card_accounts (company_id);

alter table public.card_accounts enable row level security;

grant select, insert, update, delete on public.card_accounts to authenticated;
grant all on public.card_accounts to service_role;

drop policy if exists card_accounts_select on public.card_accounts;
create policy card_accounts_select on public.card_accounts
  for select to authenticated
  using (company_id = public.my_company_id());

drop policy if exists card_accounts_insert on public.card_accounts;
create policy card_accounts_insert on public.card_accounts
  for insert to authenticated
  with check (company_id = public.my_company_id() and (select public.i_am_admin()));

-- Renaming and (de)activating are admin jobs; the balance itself moves
-- through card_account_topup so every change leaves a ledger row.
drop policy if exists card_accounts_update on public.card_accounts;
create policy card_accounts_update on public.card_accounts
  for update to authenticated
  using (company_id = public.my_company_id() and (select public.i_am_admin()))
  with check (company_id = public.my_company_id() and (select public.i_am_admin()));

drop policy if exists card_accounts_delete on public.card_accounts;
create policy card_accounts_delete on public.card_accounts
  for delete to authenticated
  using (company_id = public.my_company_id() and (select public.i_am_admin()));


-- =========================================================
-- B. card_account_transactions — append-only balance ledger
-- =========================================================
create table if not exists public.card_account_transactions (
  id            uuid        primary key default gen_random_uuid(),
  created_at    timestamptz not null default now(),
  company_id    uuid        not null references public.companies(id) on delete cascade,
  account_id    uuid        not null references public.card_accounts(id) on delete cascade,
  -- signed: positive credits the account, negative debits it
  amount        float8      not null,
  balance_after float8      not null,
  type          text        not null,
  sale_id       uuid        references public.sales(id) on delete set null,
  embedded_id   uuid        references public.embeddeds(id) on delete set null,
  description   text,
  created_by    uuid        references auth.users(id) on delete set null,
  constraint card_account_tx_type check (type in ('topup', 'vend', 'adjustment', 'refund'))
);

comment on table public.card_account_transactions is 'Append-only ledger behind card_accounts.balance';

create index if not exists card_account_tx_account_idx
  on public.card_account_transactions (account_id, created_at desc);

create index if not exists card_account_tx_company_idx
  on public.card_account_transactions (company_id, created_at desc);

-- A vend is only ever charged once per sale, whatever the webhook retries.
create unique index if not exists card_account_tx_sale_idx
  on public.card_account_transactions (sale_id)
  where sale_id is not null;

alter table public.card_account_transactions enable row level security;

grant select on public.card_account_transactions to authenticated;
grant all    on public.card_account_transactions to service_role;

-- Read-only for members: rows are written by the RPCs below, never directly,
-- so balance and ledger can never drift apart.
drop policy if exists card_account_tx_select on public.card_account_transactions;
create policy card_account_tx_select on public.card_account_transactions
  for select to authenticated
  using (company_id = public.my_company_id());


-- =========================================================
-- C. card_sessions — which account currently holds the credit
-- =========================================================
-- The device has no idea whose card it read; it only receives an amount.
-- This table is what lets the sale that follows be charged to the right
-- account. One open session per device; a new card supersedes the old one.
create table if not exists public.card_sessions (
  id           uuid        primary key default gen_random_uuid(),
  created_at   timestamptz not null default now(),
  company_id   uuid        not null references public.companies(id) on delete cascade,
  embedded_id  uuid        not null references public.embeddeds(id) on delete cascade,
  account_id   uuid        not null references public.card_accounts(id) on delete cascade,
  card_uid     text        not null,
  credit_sent  float8      not null,
  spent        float8      not null default 0,
  closed_at    timestamptz,
  close_reason text
);

comment on table public.card_sessions is 'Open card session per device: maps an incoming cashless sale back to a card account';

create unique index if not exists card_sessions_one_open_idx
  on public.card_sessions (embedded_id)
  where closed_at is null;

create index if not exists card_sessions_account_idx
  on public.card_sessions (account_id, created_at desc);

alter table public.card_sessions enable row level security;

grant select on public.card_sessions to authenticated;
grant all    on public.card_sessions to service_role;

drop policy if exists card_sessions_select on public.card_sessions;
create policy card_sessions_select on public.card_sessions
  for select to authenticated
  using (company_id = public.my_company_id());


-- =========================================================
-- D. card_account_resolve — find (or create) the account for a serial
-- =========================================================
-- Called by mqtt-webhook with the service role. Returns the account and
-- whether it had to be created, so the caller can log a first sighting.
create or replace function public.card_account_resolve(
  p_company_id uuid,
  p_card_uid   text
)
-- Out-parameter names deliberately avoid the card_accounts column names:
-- plpgsql substitutes declared variables into SQL, and a variable called
-- "name" would poison the ON CONFLICT (company_id, name) target below.
returns table (
  account_id      uuid,
  account_name    text,
  account_balance float8,
  account_active  boolean,
  account_created boolean
)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid text := upper(trim(p_card_uid));
  v_row public.card_accounts%rowtype;
begin
  if v_uid is null or v_uid = '' then
    raise exception 'card uid required';
  end if;

  -- Exact name first (that is what an untouched auto-created account looks
  -- like), then any account carrying the serial somewhere in its name. The
  -- created_at tie-break keeps the choice stable if an operator ends up with
  -- two names containing the same serial.
  select * into v_row
  from public.card_accounts a
  where a.company_id = p_company_id
    and (upper(a.name) = v_uid or upper(a.name) like '%' || v_uid || '%')
  order by (upper(a.name) = v_uid) desc, a.created_at asc
  limit 1;

  if found then
    update public.card_accounts
       set last_seen_at = now()
     where id = v_row.id;

    return query select v_row.id, v_row.name, v_row.balance, v_row.is_active, false;
    return;
  end if;

  -- Unknown card: open an account at zero rather than dropping the read, so
  -- the operator sees it in the list and can name and top it up.
  insert into public.card_accounts (company_id, name, balance, last_seen_at)
  values (p_company_id, v_uid, 0, now())
  on conflict (company_id, name) do update
    set last_seen_at = now()
  returning * into v_row;

  return query select v_row.id, v_row.name, v_row.balance, v_row.is_active, true;
end;
$$;

revoke all on function public.card_account_resolve(uuid, text) from public;
grant execute on function public.card_account_resolve(uuid, text) to service_role;


-- =========================================================
-- E. card_session_open — supersede any open session, start a new one
-- =========================================================
create or replace function public.card_session_open(
  p_company_id  uuid,
  p_embedded_id uuid,
  p_account_id  uuid,
  p_card_uid    text,
  p_credit      float8
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id uuid;
begin
  update public.card_sessions
     set closed_at = now(),
         close_reason = 'superseded'
   where embedded_id = p_embedded_id
     and closed_at is null;

  insert into public.card_sessions (company_id, embedded_id, account_id, card_uid, credit_sent)
  values (p_company_id, p_embedded_id, p_account_id, upper(trim(p_card_uid)), p_credit)
  returning id into v_id;

  return v_id;
end;
$$;

revoke all on function public.card_session_open(uuid, uuid, uuid, text, float8) from public;
grant execute on function public.card_session_open(uuid, uuid, uuid, text, float8) to service_role;


-- =========================================================
-- E2. card_session_close — drop the device's open session
-- =========================================================
-- Used when a card resolves to no spendable credit, and by send-credit so a
-- manually pushed amount is never charged back to whoever tapped last.
create or replace function public.card_session_close(
  p_embedded_id uuid,
  p_reason      text default 'closed'
)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_count integer;
begin
  update public.card_sessions
     set closed_at = now(),
         close_reason = p_reason
   where embedded_id = p_embedded_id
     and closed_at is null;

  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

revoke all on function public.card_session_close(uuid, text) from public;
grant execute on function public.card_session_close(uuid, text) to service_role;


-- =========================================================
-- F. card_account_charge_vend — subtract a completed sale
-- =========================================================
-- Returns NULL when the device has no live card session, which is the normal
-- case for machines paid by coin, bill or a Nayax terminal.
--
-- The session TTL is deliberately generous (15 min): the firmware cancels an
-- idle MDB session after 60 s, so anything older than this is not a customer
-- still standing at the machine.
create or replace function public.card_account_charge_vend(
  p_embedded_id uuid,
  p_amount      float8,
  p_sale_id     uuid
)
returns table (
  account_id   uuid,
  account_name text,
  new_balance  float8
)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_session public.card_sessions%rowtype;
  v_account public.card_accounts%rowtype;
begin
  -- Stale sessions are closed rather than charged.
  update public.card_sessions
     set closed_at = now(),
         close_reason = 'expired'
   where embedded_id = p_embedded_id
     and closed_at is null
     and created_at < now() - interval '15 minutes';

  select * into v_session
  from public.card_sessions
  where embedded_id = p_embedded_id
    and closed_at is null
  order by created_at desc
  limit 1;

  if not found then
    return;
  end if;

  -- A webhook replay of the same sale must not charge twice.
  if p_sale_id is not null and exists (
    select 1 from public.card_account_transactions where sale_id = p_sale_id
  ) then
    return;
  end if;

  update public.card_accounts
     set balance = balance - p_amount,
         updated_at = now()
   where id = v_session.account_id
  returning * into v_account;

  if not found then
    return;
  end if;

  insert into public.card_account_transactions
    (company_id, account_id, amount, balance_after, type, sale_id, embedded_id, description)
  values
    (v_account.company_id, v_account.id, -p_amount, v_account.balance, 'vend',
     p_sale_id, p_embedded_id, 'Vend on card session');

  update public.card_sessions
     set spent = spent + p_amount,
         -- The credit that was handed to the machine is spent; anything the
         -- customer buys after this needs a fresh card presentation.
         closed_at = now(),
         close_reason = 'vend'
   where id = v_session.id;

  return query select v_account.id, v_account.name, v_account.balance;
end;
$$;

revoke all on function public.card_account_charge_vend(uuid, float8, uuid) from public;
grant execute on function public.card_account_charge_vend(uuid, float8, uuid) to service_role;


-- =========================================================
-- G. card_account_topup — the operator-facing balance change
-- =========================================================
-- Admins only, own company only, ledger row always written. Amount is signed:
-- negative amounts are corrections, and are recorded as 'adjustment'.
create or replace function public.card_account_topup(
  p_account_id  uuid,
  p_amount      float8,
  p_description text default null
)
returns float8
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_account public.card_accounts%rowtype;
begin
  if p_amount is null or p_amount = 0 then
    raise exception 'amount must be non-zero';
  end if;

  select * into v_account
  from public.card_accounts
  where id = p_account_id
    and company_id = public.my_company_id();

  if not found then
    raise exception 'card account not found';
  end if;

  if not public.i_am_admin() then
    raise exception 'admin role required';
  end if;

  update public.card_accounts
     set balance = balance + p_amount,
         updated_at = now()
   where id = p_account_id
  returning * into v_account;

  insert into public.card_account_transactions
    (company_id, account_id, amount, balance_after, type, description, created_by)
  values
    (v_account.company_id, v_account.id, p_amount, v_account.balance,
     case when p_amount > 0 then 'topup' else 'adjustment' end,
     p_description, auth.uid());

  return v_account.balance;
end;
$$;

revoke all on function public.card_account_topup(uuid, float8, text) from public;
grant execute on function public.card_account_topup(uuid, float8, text) to authenticated;
grant execute on function public.card_account_topup(uuid, float8, text) to service_role;
