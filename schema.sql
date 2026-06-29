-- ============================================================================
--  CONTROLE DE GASTOS  —  Esquema do banco (Postgres / Supabase)
--  Rode este arquivo inteiro no SQL Editor do Supabase (uma vez).
--  Bloco 1: tabelas + segurança por usuário (RLS)
--  Bloco 2 (opcional): camada de leitura para o Power BI
-- ============================================================================

create extension if not exists "pgcrypto";   -- gen_random_uuid()

-- ============================================================================
--  BLOCO 1 — TABELAS
--  Espelham 1:1 o "state" do app. Mês é 0..11 (0 = Janeiro), igual ao JS.
-- ============================================================================

-- -------- Lançamentos (despesas) --------
create table if not exists public.expenses (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references auth.users(id) on delete cascade,
  year        int  not null,
  month       int  not null check (month between 0 and 11),
  date        date,
  description text not null,
  value       numeric(12,2) not null default 0,
  category    text not null,
  payment     text,
  paid        boolean not null default false,
  created_at  timestamptz not null default now()
);

-- -------- Parcelamentos --------
create table if not exists public.installments (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references auth.users(id) on delete cascade,
  description text not null,
  total       numeric(12,2) not null default 0,
  category    text not null,
  payment     text,
  count       int  not null check (count > 0),
  start_month int  not null check (start_month between 0 and 11),
  start_year  int  not null,
  paid        boolean not null default false,
  created_at  timestamptz not null default now()
);

-- -------- Renda (um valor por mês) --------
create table if not exists public.income (
  id       uuid primary key default gen_random_uuid(),
  user_id  uuid not null references auth.users(id) on delete cascade,
  year     int not null,
  month    int not null check (month between 0 and 11),
  amount   numeric(12,2) not null default 0,
  unique (user_id, year, month)
);

-- -------- Investimentos --------
create table if not exists public.investments (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references auth.users(id) on delete cascade,
  year        int not null,
  month       int not null check (month between 0 and 11),
  date        date,
  description text not null,
  value       numeric(12,2) not null default 0,
  type        text not null,
  kind        text not null default 'aporte' check (kind in ('aporte','resgate')),
  created_at  timestamptz not null default now()
);

create index if not exists idx_expenses_user_period on public.expenses(user_id, year, month);
create index if not exists idx_invest_user_period   on public.investments(user_id, year, month);
create index if not exists idx_install_user         on public.installments(user_id);

-- ============================================================================
--  SEGURANÇA — Row Level Security
--  Cada usuário só lê/escreve as próprias linhas. Sem isso, "público" = vazado.
-- ============================================================================
alter table public.expenses     enable row level security;
alter table public.installments enable row level security;
alter table public.income       enable row level security;
alter table public.investments  enable row level security;

-- expenses
create policy "exp_sel" on public.expenses for select using (auth.uid() = user_id);
create policy "exp_ins" on public.expenses for insert with check (auth.uid() = user_id);
create policy "exp_upd" on public.expenses for update using (auth.uid() = user_id) with check (auth.uid() = user_id);
create policy "exp_del" on public.expenses for delete using (auth.uid() = user_id);
-- installments
create policy "ins_sel" on public.installments for select using (auth.uid() = user_id);
create policy "ins_ins" on public.installments for insert with check (auth.uid() = user_id);
create policy "ins_upd" on public.installments for update using (auth.uid() = user_id) with check (auth.uid() = user_id);
create policy "ins_del" on public.installments for delete using (auth.uid() = user_id);
-- income
create policy "inc_sel" on public.income for select using (auth.uid() = user_id);
create policy "inc_ins" on public.income for insert with check (auth.uid() = user_id);
create policy "inc_upd" on public.income for update using (auth.uid() = user_id) with check (auth.uid() = user_id);
create policy "inc_del" on public.income for delete using (auth.uid() = user_id);
-- investments
create policy "inv_sel" on public.investments for select using (auth.uid() = user_id);
create policy "inv_ins" on public.investments for insert with check (auth.uid() = user_id);
create policy "inv_upd" on public.investments for update using (auth.uid() = user_id) with check (auth.uid() = user_id);
create policy "inv_del" on public.investments for delete using (auth.uid() = user_id);


-- ============================================================================
--  BLOCO 2 (OPCIONAL) — CAMADA DE LEITURA PARA O POWER BI
--  ----------------------------------------------------------------------------
--  ATENÇÃO / LGPD: as views abaixo são CONSOLIDADAS (todos os usuários), feitas
--  para você (dono do app) gerar estatísticas. Elas são criadas pelo papel
--  "postgres", que ignora o RLS, então quem conseguir ler estas views vê dados
--  de TODOS os usuários. Trate a credencial 'powerbi_ro' como segredo, não
--  exponha descrição livre num dashboard público, e tenha uma política de
--  privacidade se o app for aberto ao público.
--  ----------------------------------------------------------------------------
create schema if not exists reporting;

-- Despesas (com mês 1..12 e data real para a inteligência de tempo do Power BI)
create or replace view reporting.expenses as
select
  e.id,
  e.user_id,
  e.year                              as ano,
  e.month + 1                         as mes_num,         -- 1..12
  coalesce(e.date, make_date(e.year, e.month + 1, 1)) as data,
  e.category                          as categoria,
  e.payment                           as forma_pagamento,
  e.value                             as valor,
  e.paid                              as pago
  -- 'description' propositalmente fora: costuma conter dado pessoal.
from public.expenses e;

-- Parcelamentos "explodidos": uma linha por parcela, já no mês de competência
create or replace view reporting.installments_schedule as
select
  i.id,
  i.user_id,
  i.description                       as descricao,
  i.category                          as categoria,
  i.total                             as valor_total,
  i.count                             as qtd_parcelas,
  g.n + 1                             as parcela_num,      -- 1..count
  ((i.start_year * 12 + i.start_month + g.n) / 12)        as ano,
  ((i.start_year * 12 + i.start_month + g.n) % 12) + 1    as mes_num,
  make_date(
    (i.start_year * 12 + i.start_month + g.n) / 12,
    ((i.start_year * 12 + i.start_month + g.n) % 12) + 1, 1) as data,
  round(i.total / i.count, 2)         as valor_parcela
from public.installments i
cross join lateral generate_series(0, i.count - 1) as g(n);

-- Renda por mês
create or replace view reporting.income as
select
  r.user_id,
  r.year                              as ano,
  r.month + 1                         as mes_num,
  make_date(r.year, r.month + 1, 1)   as data,
  r.amount                            as renda
from public.income r;

-- Investimentos (valor com sinal: resgate é negativo)
create or replace view reporting.investments as
select
  v.id,
  v.user_id,
  v.year                              as ano,
  v.month + 1                         as mes_num,
  coalesce(v.date, make_date(v.year, v.month + 1, 1)) as data,
  v.type                              as tipo,
  v.kind                              as movimento,
  case when v.kind = 'resgate' then -v.value else v.value end as valor_liquido
from public.investments v;

-- ---------------------------------------------------------------------------
--  Papel só-leitura para o Power BI se conectar (troque a senha!).
--  Descomente para usar:
-- ---------------------------------------------------------------------------
-- create role powerbi_ro login password 'TROQUE_ESTA_SENHA_FORTE';
-- grant usage on schema reporting to powerbi_ro;
-- grant select on all tables in schema reporting to powerbi_ro;
-- alter default privileges in schema reporting grant select on tables to powerbi_ro;
