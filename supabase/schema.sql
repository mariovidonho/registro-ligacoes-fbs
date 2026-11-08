-- ATENÇÃO: NÃO rode este arquivo inteiro de novo. Ele recria as regras antigas de acesso livre.
-- A segurança atual está em seguranca_1_logins.sql, seguranca_2_regras.sql e seguranca_3_trancar.sql.
-- Registro de Ligações FBS Prime — banco no Supabase
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

-- Horários do cronograma diário: uma linha só, editada pelo painel administrativo.
-- Enquanto estiver vazia, o site usa os horários padrão que já vêm no código.
-- Tabela à parte: não mexe nas outras nem no espelho do n8n.
create table if not exists public.cronograma (
  id            int primary key default 1 check (id = 1),
  blocos        jsonb not null,
  atualizado_em timestamptz not null default now()
);
alter table public.cronograma enable row level security;
drop policy if exists "site" on public.cronograma;
create policy "site" on public.cronograma for all to anon using (true) with check (true);

-- ---------------------------------------------------------------------------
-- Produção do time (painel admin): equipes, histórico mensal e vendas.
-- Tabelas à parte: não mexem nas de ligações/metas nem no espelho do n8n.
-- ---------------------------------------------------------------------------

-- Equipes (coordenações). `coordenadores` guarda quem coordenou em cada ano,
-- ex.: {"2024": "Danilo", "2025": "Danilo"}.
create table if not exists public.equipes (
  nome          text primary key,
  coordenadores jsonb not null default '{}',
  ativa         boolean not null default true,
  ordem         int not null default 0,
  criado_em     timestamptz not null default now()
);

-- Valor fechado de um mês por equipe (histórico das planilhas ou correção manual).
-- Quando existe, vale este valor; senão o site soma as vendas registradas.
create table if not exists public.producao_mensal (
  ano    int  not null check (ano between 2000 and 2100),
  mes    int  not null check (mes between 1 and 12),
  equipe text not null references public.equipes (nome) on update cascade,
  valor  numeric(14,2) not null check (valor >= 0),
  primary key (ano, mes, equipe)
);

-- Cada venda registrada no admin. `equipe` é a do vendedor no dia da venda.
create table if not exists public.vendas (
  id        bigint generated always as identity primary key,
  vendedor  text not null,
  equipe    text references public.equipes (nome) on update cascade,
  data      date not null,
  valor     numeric(14,2) not null check (valor > 0),
  cliente   text,
  canal     text,
  criado_em timestamptz not null default now()
);
create index if not exists vendas_data_idx on public.vendas (data);

alter table public.equipes         enable row level security;
alter table public.producao_mensal enable row level security;
alter table public.vendas          enable row level security;
drop policy if exists "site" on public.equipes;
drop policy if exists "site" on public.producao_mensal;
drop policy if exists "site" on public.vendas;
create policy "site" on public.equipes         for all to anon using (true) with check (true);
create policy "site" on public.producao_mensal for all to anon using (true) with check (true);
create policy "site" on public.vendas          for all to anon using (true) with check (true);

-- Cópia de cada venda nova para o Airtable (tabela "Marketing - Conjuntos"),
-- feita pelo próprio banco. Só funciona depois que a chave do Airtable for
-- guardada no cofre (Vault) com o nome 'airtable_token'; sem a chave, a venda
-- é salva normalmente e só não é copiada.
create extension if not exists pg_net;

create or replace function public.enviar_venda_airtable()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_token text;
  v_ini   date;
  v_fim   date;
begin
  select decrypted_secret into v_token from vault.decrypted_secrets where name = 'airtable_token';
  if v_token is null then
    return new;
  end if;
  -- semana de segunda a domingo, cortada na virada do mês (mesmo padrão dos relatórios)
  v_ini := greatest(date_trunc('week', new.data)::date, date_trunc('month', new.data)::date);
  v_fim := least(date_trunc('week', new.data)::date + 6, (date_trunc('month', new.data) + interval '1 month - 1 day')::date);
  perform net.http_post(
    url     := 'https://api.airtable.com/v0/appjgrhsM4izs8ilX/tbloaJEIi6zcQB1Lq',
    headers := jsonb_build_object('Authorization', 'Bearer ' || v_token, 'Content-Type', 'application/json'),
    body    := jsonb_build_object('typecast', true, 'records', jsonb_build_array(jsonb_build_object('fields',
      jsonb_strip_nulls(jsonb_build_object(
        'Vendedor', new.vendedor,
        'Cliente',  coalesce(nullif(new.cliente, ''), '(cliente nao informado)') || ' (registrada no site)',
        'Valor',    new.valor,
        'Data',     new.data,
        'Semana',   to_char(v_ini, 'DD') || '-' || to_char(v_fim, 'DD/MM/YYYY'),
        'Canal',    nullif(new.canal, '')
      ))
    )))
  );
  return new;
exception when others then
  -- falha no envio nunca impede de salvar a venda
  return new;
end
$$;

drop trigger if exists vendas_airtable on public.vendas;
create trigger vendas_airtable after insert on public.vendas
  for each row execute function public.enviar_venda_airtable();

-- ---------------------------------------------------------------------------
-- Relatórios (Central do Vendedor): PDFs enviados pelo admin, um por
-- vendedor/semana. O arquivo fica no Storage (pasta pública "relatorios");
-- esta tabela guarda de quem é, a qual semana pertence e quando foi aberto.
-- ---------------------------------------------------------------------------
create table if not exists public.relatorios (
  id        bigint generated always as identity primary key,
  vendedor  text not null,
  ano       int  not null,
  mes       int  not null check (mes between 1 and 12),
  semana    int,            -- 1..5; vazio = relatório do mês
  titulo    text not null,
  caminho   text not null unique,  -- caminho do arquivo dentro do bucket
  tamanho   int,
  criado_em timestamptz not null default now(),
  visto_em  timestamptz      -- primeira vez que o vendedor abriu
);
create index if not exists relatorios_vendedor_idx on public.relatorios (vendedor, ano, mes);
alter table public.relatorios enable row level security;
drop policy if exists "site" on public.relatorios;
create policy "site" on public.relatorios for all to anon using (true) with check (true);

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('relatorios', 'relatorios', true, 20971520, array['application/pdf'])
on conflict (id) do nothing;
drop policy if exists "relatorios leitura" on storage.objects;
drop policy if exists "relatorios envio"   on storage.objects;
drop policy if exists "relatorios remocao" on storage.objects;
create policy "relatorios leitura" on storage.objects for select to anon using (bucket_id = 'relatorios');
create policy "relatorios envio"   on storage.objects for insert to anon with check (bucket_id = 'relatorios');
create policy "relatorios remocao" on storage.objects for delete to anon using (bucket_id = 'relatorios');

-- ---------------------------------------------------------------------------
-- Desempenho (Central do Vendedor)
-- ---------------------------------------------------------------------------

-- Ligações agregadas por vendedor e dia (fuso de São Paulo) desde uma data.
create or replace function public.ligacoes_diarias(p_desde date)
returns table (vendedor text, dia date, total int, atendidas int, agendamentos int)
language sql stable as $$
  select l.vendedor, public.dia_sp(l.ts),
         count(*)::int,
         (count(*) filter (where l.tipo = 'atendeu'))::int,
         (count(*) filter (where lower(l.agendou) = 'sim'))::int
  from public.ligacoes l
  where public.dia_sp(l.ts) >= p_desde
  group by 1, 2
$$;

-- Cópia da tabela "Metricas por Vendedor" do Airtable (números oficiais da
-- semana, lançados no fechamento dos relatórios). Atualizada de hora em hora
-- pela função abaixo; o site só lê.
create table if not exists public.metricas_semanais (
  airtable_id     text primary key,
  vendedor        text not null,
  semana          text not null,   -- rótulo do Airtable, ex.: "26/10-02/11/2026 (FECHADA)"
  agendamentos    int,
  comparecimentos int,
  vendas          int,
  receita         numeric(14,2),
  cards_parados   int,
  zero_comentario int,
  negocios_ativos int,
  dias_atividade  int,
  atualizado_em   timestamptz not null default now()
);
alter table public.metricas_semanais enable row level security;
drop policy if exists "leitura" on public.metricas_semanais;
create policy "leitura" on public.metricas_semanais for select to anon using (true);

create extension if not exists http with schema extensions;

create or replace function public.sync_airtable_metricas()
returns int language plpgsql security definer set search_path = public, extensions as $$
declare
  v_token  text;
  v_offset text;
  v_resp   extensions.http_response;
  v_json   jsonb;
  r        jsonb;
  f        jsonb;
  n        int := 0;
begin
  select decrypted_secret into v_token from vault.decrypted_secrets where name = 'airtable_token';
  if v_token is null then return -1; end if;
  loop
    v_resp := extensions.http((
      'GET',
      'https://api.airtable.com/v0/appjgrhsM4izs8ilX/tblEPH9i2xLXGhIfe?pageSize=100' || coalesce('&offset=' || v_offset, ''),
      array[extensions.http_header('Authorization', 'Bearer ' || v_token)],
      null, null)::extensions.http_request);
    if v_resp.status <> 200 then
      raise exception 'Airtable respondeu HTTP %: %', v_resp.status, left(v_resp.content, 300);
    end if;
    v_json := v_resp.content::jsonb;
    for r in select * from jsonb_array_elements(v_json->'records') loop
      f := r->'fields';
      continue when coalesce(f->>'Vendedor', '') = '' or coalesce(f->>'Semana', '') = '';
      insert into public.metricas_semanais as m (airtable_id, vendedor, semana, agendamentos, comparecimentos, vendas,
             receita, cards_parados, zero_comentario, negocios_ativos, dias_atividade, atualizado_em)
      values (r->>'id', trim(f->>'Vendedor'), trim(f->>'Semana'),
              round((f->>'Agendamentos')::numeric), round((f->>'Comparecimentos')::numeric), round((f->>'Vendas')::numeric),
              (f->>'Receita')::numeric, round((f->>'Cards Parados')::numeric), round((f->>'Zero Comentario')::numeric),
              round((f->>'Negocios Ativos')::numeric), round((f->>'Dias com Atividade CRM')::numeric), now())
      on conflict (airtable_id) do update set
        vendedor = excluded.vendedor, semana = excluded.semana, agendamentos = excluded.agendamentos,
        comparecimentos = excluded.comparecimentos, vendas = excluded.vendas, receita = excluded.receita,
        cards_parados = excluded.cards_parados, zero_comentario = excluded.zero_comentario,
        negocios_ativos = excluded.negocios_ativos, dias_atividade = excluded.dias_atividade, atualizado_em = now();
      n := n + 1;
    end loop;
    v_offset := v_json->>'offset';
    exit when v_offset is null;
  end loop;
  -- o que sumiu do Airtable some daqui também
  delete from public.metricas_semanais where atualizado_em < now();
  return n;
end
$$;

create extension if not exists pg_cron;
select cron.schedule('sync-airtable-metricas', '7 * * * *', 'select public.sync_airtable_metricas()');

-- Ranking anual de vendas por vendedor. Guarda o histórico que veio da
-- imagem do ranking (abril a outubro/2026); de novembro em diante o site soma
-- as vendas registradas no admin. mes = 4 em 2026 é o acumulado até abril;
-- mes nulo = só o total do ano (produção de quem saiu).
create table if not exists public.ranking_historico (
  vendedor text not null,
  ano      int  not null,
  mes      int  check (mes between 1 and 12),
  valor    numeric(14,2) not null,
  ativo    boolean not null default true
);
create unique index if not exists ranking_historico_uk on public.ranking_historico (vendedor, ano, coalesce(mes, 0));
alter table public.ranking_historico enable row level security;
drop policy if exists "site" on public.ranking_historico;
create policy "site" on public.ranking_historico for all to anon using (true) with check (true);

-- ---------------------------------------------------------------------------
-- Eventos fixos do cronograma (ex.: reunião de marketing toda segunda às 10h)
-- e perfil do vendedor (foto, apelido, frase, aniversário).
-- ---------------------------------------------------------------------------
alter table public.cronograma add column if not exists eventos jsonb not null default '[]';
update public.cronograma
   set eventos = '[{"titulo":"Reunião de marketing","dia":1,"inicio":"10:00","fim":"11:00"}]'
 where id = 1 and eventos = '[]';

alter table public.vendedores add column if not exists foto_url   text;
alter table public.vendedores add column if not exists apelido    text;
alter table public.vendedores add column if not exists frase      text;
alter table public.vendedores add column if not exists aniversario text;  -- "dd/mm"

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('fotos', 'fotos', true, 2097152, array['image/jpeg','image/png','image/webp'])
on conflict (id) do nothing;
drop policy if exists "fotos leitura" on storage.objects;
drop policy if exists "fotos envio"   on storage.objects;
drop policy if exists "fotos remocao" on storage.objects;
create policy "fotos leitura" on storage.objects for select to anon using (bucket_id = 'fotos');
create policy "fotos envio"   on storage.objects for insert to anon with check (bucket_id = 'fotos');
create policy "fotos remocao" on storage.objects for delete to anon using (bucket_id = 'fotos');
-- reenviar um relatório com o mesmo nome substitui o arquivo
drop policy if exists "relatorios troca" on storage.objects;
create policy "relatorios troca" on storage.objects for update to anon using (bucket_id = 'relatorios') with check (bucket_id = 'relatorios');

-- ---------------------------------------------------------------------------
-- Campanhas de premiação (Central do Vendedor). O progresso de cada vendedor
-- é a base lançada pelo admin (vendas de antes do site, ex.: outubro/2026)
-- + as vendas registradas no site dentro do período, só dos canais da campanha.
-- ---------------------------------------------------------------------------
create table if not exists public.campanhas (
  id          bigint generated always as identity primary key,
  titulo      text not null,
  premio      text,
  inicio      date not null,
  fim         date not null,
  meta        numeric(14,2) not null check (meta > 0),
  canais      text[] not null default '{}',   -- vazio = qualquer canal
  marco_valor numeric(14,2),                  -- antecipação: valor ...
  marco_ate   date,                           -- ... atingido até esta data
  marco_texto text,
  imagem_url  text,
  ativa       boolean not null default true,
  criado_em   timestamptz not null default now()
);
create table if not exists public.campanha_ajustes (
  campanha_id bigint not null references public.campanhas (id) on delete cascade,
  vendedor    text not null,
  valor       numeric(14,2) not null default 0,
  primary key (campanha_id, vendedor)
);
alter table public.campanhas        enable row level security;
alter table public.campanha_ajustes enable row level security;
drop policy if exists "site" on public.campanhas;
drop policy if exists "site" on public.campanha_ajustes;
create policy "site" on public.campanhas        for all to anon using (true) with check (true);
create policy "site" on public.campanha_ajustes for all to anon using (true) with check (true);

-- ---------------------------------------------------------------------------
-- Metas pessoais (aba "Minha meta" da Central do Vendedor).
-- `config.regra_meta`: ticket médio e o funil de 1 venda (editável no admin).
-- `metas_pessoais`: a meta em R$ que cada vendedor estipulou para o mês, com o
-- plano calculado na hora de salvar (padrão FBS e pelo histórico dele), pra
-- formar uma base de dados mês a mês.
-- ---------------------------------------------------------------------------
create table if not exists public.config (
  chave         text primary key,
  valor         jsonb not null,
  atualizado_em timestamptz not null default now()
);
insert into public.config (chave, valor)
values ('regra_meta', '{"ticket": 500000, "ligacoes": 600, "agendamentos": 20, "comparecimentos": 7}')
on conflict (chave) do nothing;

create table if not exists public.metas_pessoais (
  vendedor      text not null,
  mes           text not null,          -- "AAAA-MM"
  valor         numeric(14,2) not null check (valor > 0),
  plano         jsonb,                  -- regra, taxas do histórico e números calculados ao salvar
  atualizado_em timestamptz not null default now(),
  primary key (vendedor, mes)
);
alter table public.config         enable row level security;
alter table public.metas_pessoais enable row level security;
drop policy if exists "site" on public.config;
drop policy if exists "site" on public.metas_pessoais;
create policy "site" on public.config         for all to anon using (true) with check (true);
create policy "site" on public.metas_pessoais for all to anon using (true) with check (true);

-- Lista inicial de vendedores (a mesma que está no site)
insert into public.vendedores (nome, pin) values
  ('Arthur Lima', '1098'), ('Wellington Augusto', '1111'), ('Rayane Castro', '1095'),
  ('Raissa Gabrielly', '1097'), ('Nayara Lima', '1096'), ('Diane Ruiz', '1094'),
  ('Erick Fernandes', '1099'), ('Camila Abreu', '1264'), ('Javam Trajano', '1265'),
  ('Cley Silva', '1268')
on conflict (nome) do nothing;
