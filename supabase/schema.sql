-- Registro de Ligações FBS Prime — banco no Supabase
-- Cole este arquivo inteiro no Supabase: SQL Editor > New query > Run.
-- Pode rodar de novo sem problema (não apaga dados).
--
-- Datas de "dia" e "semana" são calculadas no fuso de São Paulo, então uma
-- ligação às 22h conta no dia certo (a planilha usava UTC).

create table if not exists public.vendedores (
  nome      text primary key,
  pin       text not null,
  criado_em timestamptz not null default now()
);

create table if not exists public.ligacoes (
  id              bigint generated always as identity primary key,
  vendedor        text not null,
  tipo            text not null check (tipo in ('atendeu', 'caixa_postal')),
  ts              timestamptz not null,
  agendou         text,
  chamou_whatsapp text,
  criado_em       timestamptz not null default now(),
  -- o site pode reenviar a mesma ligação se a resposta se perder no caminho:
  -- isto garante que ela é gravada uma vez só
  unique (vendedor, ts)
);
create index if not exists ligacoes_ts_idx on public.ligacoes (ts);

create table if not exists public.fechamentos (
  vendedor     text not null,
  data         date not null,
  atendidas    int  not null,
  caixa_postal int  not null,
  total        int  not null,
  fechado_em   timestamptz not null default now(),
  primary key (vendedor, data)
);

create table if not exists public.metas (
  vendedor                  text not null,
  semana                    date not null, -- segunda-feira da semana
  meta_agendamentos         int  not null default 1,
  meta_comparecimentos      int  not null default 1,
  progresso_comparecimentos int  not null default 0,
  meta_vendas               int  not null default 1,
  progresso_vendas          int  not null default 0,
  meta_ligacoes             int  not null default 1,
  primary key (vendedor, semana)
);

-- Dia (fuso de São Paulo) de um timestamp
create or replace function public.dia_sp(t timestamptz)
returns date language sql immutable as $$
  select (t at time zone 'America/Sao_Paulo')::date
$$;

-- Tudo que a tela do vendedor precisa ao entrar: ligações recentes,
-- fechamento de hoje e dias anteriores que ficaram sem fechar.
create or replace function public.dados_vendedor(p_vendedor text)
returns jsonb language sql stable as $$
  with hoje as (select public.dia_sp(now()) as d)
  select jsonb_build_object(
    'ligacoes', coalesce((
      select jsonb_agg(jsonb_build_object('tipo', l.tipo, 'ts', l.ts, 'agendou', l.agendou) order by l.ts)
      from public.ligacoes l, hoje
      where l.vendedor = p_vendedor and public.dia_sp(l.ts) >= hoje.d - 40
    ), '[]'::jsonb),
    'fechado', (
      select jsonb_build_object('closedAt', f.fechado_em, 'atendidas', f.atendidas,
                                'caixaPostal', f.caixa_postal, 'total', f.total)
      from public.fechamentos f, hoje
      where f.vendedor = p_vendedor and f.data = hoje.d
    ),
    'pendentes', coalesce((
      select jsonb_agg(p order by p->>'data')
      from (
        select jsonb_build_object(
          'data', public.dia_sp(l.ts),
          'atendeu', count(*) filter (where l.tipo = 'atendeu'),
          'caixa', count(*) filter (where l.tipo = 'caixa_postal'),
          'total', count(*)) as p
        from public.ligacoes l, hoje
        where l.vendedor = p_vendedor
          and public.dia_sp(l.ts) between hoje.d - 7 and hoje.d - 1
          and not exists (select 1 from public.fechamentos f
                          where f.vendedor = l.vendedor and f.data = public.dia_sp(l.ts))
        group by public.dia_sp(l.ts)
      ) x
    ), '[]'::jsonb)
  )
$$;

-- Ranking do painel admin, já somado pelo período (tipo = dia | mes | ano;
-- valor = '2026-09-26' | '2026-09' | '2026')
create or replace function public.admin_ranking(p_tipo text, p_valor text)
returns table (vendedor text, atendeu int, caixa int, total int, last_ts timestamptz, closed jsonb)
language sql stable as $$
  with l as (
    select l.vendedor, l.tipo, l.ts
    from public.ligacoes l
    where to_char(l.ts at time zone 'America/Sao_Paulo',
                  case p_tipo when 'dia' then 'YYYY-MM-DD' when 'mes' then 'YYYY-MM' else 'YYYY' end) = p_valor
  ),
  nomes as (
    select nome as vendedor from public.vendedores
    union
    select l.vendedor from l
  )
  select n.vendedor,
         (count(l.ts) filter (where l.tipo = 'atendeu'))::int,
         (count(l.ts) filter (where l.tipo = 'caixa_postal'))::int,
         count(l.ts)::int,
         max(l.ts),
         (select jsonb_build_object('closedAt', f.fechado_em, 'atendidas', f.atendidas,
                                    'caixaPostal', f.caixa_postal, 'total', f.total)
          from public.fechamentos f
          where p_tipo = 'dia' and f.vendedor = n.vendedor and f.data::text = p_valor)
  from nomes n
  left join l on l.vendedor = n.vendedor
  group by n.vendedor
  order by 4 desc
$$;

-- Metas da semana atual do vendedor. Se a semana ainda não tem linha, cria uma
-- com cada meta = resultado da semana anterior + 1 (sempre um pouco melhor);
-- o admin pode mudar qualquer meta depois no painel. Devolve também o resultado
-- da semana anterior, pro admin avaliar.
create or replace function public.get_metas(p_vendedor text)
returns jsonb language plpgsql as $$
declare
  v_hoje     date := public.dia_sp(now());
  v_semana   date := date_trunc('week', v_hoje)::date;
  v_anterior date := v_semana - 7;
  m          public.metas;
  ant        public.metas;
  lig_atual int; ag_atual int; lig_ant int; ag_ant int; dias_ant int;
begin
  select count(*), count(*) filter (where lower(agendou) = 'sim')
    into lig_atual, ag_atual
    from public.ligacoes
   where vendedor = p_vendedor and public.dia_sp(ts) between v_semana and v_semana + 6;

  select count(*), count(*) filter (where lower(agendou) = 'sim'), count(distinct public.dia_sp(ts))
    into lig_ant, ag_ant, dias_ant
    from public.ligacoes
   where vendedor = p_vendedor and public.dia_sp(ts) between v_anterior and v_anterior + 6;
  select * into ant from public.metas where vendedor = p_vendedor and semana = v_anterior;

  select * into m from public.metas where vendedor = p_vendedor and semana = v_semana;
  if not found then
    insert into public.metas (vendedor, semana, meta_agendamentos, meta_comparecimentos, meta_vendas, meta_ligacoes)
    values (p_vendedor, v_semana,
            ag_ant + 1,
            coalesce(ant.progresso_comparecimentos, 0) + 1,
            coalesce(ant.progresso_vendas, 0) + 1,
            lig_ant + 1)
    on conflict do nothing;
    select * into m from public.metas where vendedor = p_vendedor and semana = v_semana;
  end if;

  return jsonb_build_object(
    'semana', v_semana,
    'agendamentos',    jsonb_build_object('meta', m.meta_agendamentos,    'progresso', ag_atual),
    'comparecimentos', jsonb_build_object('meta', m.meta_comparecimentos, 'progresso', m.progresso_comparecimentos),
    'vendas',          jsonb_build_object('meta', m.meta_vendas,          'progresso', m.progresso_vendas),
    'ligacoes',        jsonb_build_object('meta', m.meta_ligacoes,        'progresso', lig_atual),
    'anterior', jsonb_build_object(
      'semana', v_anterior,
      'ligacoes', lig_ant,
      'agendamentos', ag_ant,
      'comparecimentos', coalesce(ant.progresso_comparecimentos, 0),
      'vendas', coalesce(ant.progresso_vendas, 0),
      'dias', dias_ant)
  );
end
$$;

-- Altera 1 campo da semana atual (progresso de vendas/comparecimentos ou meta editada pelo admin)
create or replace function public.set_meta(p_vendedor text, p_campo text, p_valor int)
returns void language plpgsql as $$
declare
  v_semana date := date_trunc('week', public.dia_sp(now()))::date;
  v_coluna text := case p_campo
    when 'progressoComparecimentos' then 'progresso_comparecimentos'
    when 'progressoVendas'          then 'progresso_vendas'
    when 'metaAgendamentos'         then 'meta_agendamentos'
    when 'metaComparecimentos'      then 'meta_comparecimentos'
    when 'metaVendas'               then 'meta_vendas'
    when 'metaLigacoes'             then 'meta_ligacoes'
  end;
begin
  if v_coluna is null then
    raise exception 'campo desconhecido: %', p_campo;
  end if;
  perform public.get_metas(p_vendedor); -- garante que a linha da semana existe
  execute format('update public.metas set %I = $1 where vendedor = $2 and semana = $3', v_coluna)
    using p_valor, p_vendedor, v_semana;
end
$$;

-- Acesso pelo site (chave pública "anon"). Mesmo nível de segurança de hoje
-- com os webhooks do n8n: ferramenta interna, PINs só como trava básica.
alter table public.vendedores  enable row level security;
alter table public.ligacoes    enable row level security;
alter table public.fechamentos enable row level security;
alter table public.metas       enable row level security;

drop policy if exists "site" on public.vendedores;
drop policy if exists "site" on public.ligacoes;
drop policy if exists "site" on public.fechamentos;
drop policy if exists "site" on public.metas;
create policy "site" on public.vendedores  for all to anon using (true) with check (true);
create policy "site" on public.ligacoes    for all to anon using (true) with check (true);
create policy "site" on public.fechamentos for all to anon using (true) with check (true);
create policy "site" on public.metas       for all to anon using (true) with check (true);

-- Lista inicial de vendedores (a mesma que está no site)
insert into public.vendedores (nome, pin) values
  ('Arthur Lima', '1098'), ('Wellington Augusto', '1111'), ('Rayane Castro', '1095'),
  ('Raissa Gabrielly', '1097'), ('Nayara Lima', '1096'), ('Diane Ruiz', '1094'),
  ('Erick Fernandes', '1099'), ('Camila Abreu', '1264'), ('Javam Trajano', '1265'),
  ('Cley Silva', '1268')
on conflict (nome) do nothing;
