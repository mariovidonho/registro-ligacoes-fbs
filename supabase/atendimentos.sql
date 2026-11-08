-- Ficha de atendimento: um cliente (pelo telefone) com várias visitas/propostas.
-- O site só lê estas tabelas; toda gravação passa pelas funções abaixo, que conferem o papel de quem chama.

create table if not exists public.clientes (
  id        bigint generated always as identity primary key,
  nome      text not null,
  telefone  text not null unique,   -- só números
  telefone2 text,
  canal     text,
  vendedor  text not null,          -- titular
  lgpd_em   timestamptz not null,   -- quando o cliente autorizou o uso dos dados
  criado_em timestamptz not null default now()
);

create table if not exists public.atendimentos (
  id               bigint generated always as identity primary key,
  cliente_id       bigint not null references public.clientes (id) on delete cascade,
  vendedor         text not null,   -- titular
  ajudante         text,            -- modo ajuda: quem atendeu junto
  criado_em        timestamptz not null default now(),
  atualizado_em    timestamptz not null default now(),
  bem              text,
  credito          numeric(14,2),
  renda            numeric(14,2),
  entrada          numeric(14,2),
  parcela          numeric(14,2),
  restricao        boolean,
  restricao_valor  numeric(14,2),
  fgts             boolean,
  fgts_valor       numeric(14,2),
  aluguel          boolean,
  aluguel_valor    numeric(14,2),
  projecoes        jsonb not null default '[{},{}]',
  situacao         text not null default 'em_atendimento'
                   check (situacao in ('em_atendimento','aprovacao_loja','aprovacao_agendada','aprovado','reprovado','vai_voltar','nao_volta','fechou')),
  aprovacao_em     timestamptz,     -- dia e hora marcados para a aprovação
  aprovacao_por    text,
  aprovacao_motivo text,
  resposta_cliente text,
  retorno_em       timestamptz,
  motivo           text,            -- por que não vai voltar
  proposta_em      timestamptz,
  venda_valor      numeric(14,2),
  venda_data       date,
  venda_status     text check (venda_status in ('aguardando','confirmada','recusada'))
);
create index if not exists atendimentos_cliente_idx on public.atendimentos (cliente_id);
create index if not exists atendimentos_situacao_idx on public.atendimentos (situacao);

create table if not exists public.tabelas (
  id            bigint generated always as identity primary key,
  administradora text not null,
  titulo        text not null,
  caminho       text not null unique,
  criado_em     timestamptz not null default now()
);

alter table public.clientes     enable row level security;
alter table public.atendimentos enable row level security;
alter table public.tabelas      enable row level security;
drop policy if exists "le" on public.atendimentos;
drop policy if exists "le" on public.clientes;
drop policy if exists "le" on public.tabelas;
drop policy if exists "rep altera" on public.tabelas;
create policy "le" on public.atendimentos for select to authenticated
  using (public.pode_ver(vendedor) or ajudante = public.meu_nome());
create policy "le" on public.clientes for select to authenticated
  using (public.pode_ver(vendedor) or exists (select 1 from public.atendimentos a where a.cliente_id = clientes.id and a.ajudante = public.meu_nome()));
create policy "le" on public.tabelas for select to authenticated using (public.meu_papel() is not null);
create policy "rep altera" on public.tabelas for all to authenticated using (public.eh_rep()) with check (public.eh_rep());

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('tabelas', 'tabelas', false, 20971520, array['application/pdf'])
on conflict (id) do nothing;
drop policy if exists "tabelas le" on storage.objects;
drop policy if exists "tabelas rep" on storage.objects;
create policy "tabelas le" on storage.objects for select to authenticated using (bucket_id = 'tabelas' and public.meu_papel() is not null);
create policy "tabelas rep" on storage.objects for all to authenticated using (bucket_id = 'tabelas' and public.eh_rep()) with check (bucket_id = 'tabelas' and public.eh_rep());

-- ---- Conferências ----
create or replace function public.at_exigir(p_id bigint) returns public.atendimentos
language plpgsql stable security definer set search_path = public as $$
declare a public.atendimentos;
begin
  select * into a from public.atendimentos where id = p_id;
  if not found or not (public.pode_ver(a.vendedor) or a.ajudante = public.meu_nome()) then raise exception 'Sem permissão'; end if;
  return a;
end
$$;
create or replace function public.at_exigir_gestor(p_id bigint) returns public.atendimentos
language plpgsql stable security definer set search_path = public as $$
declare a public.atendimentos;
begin
  a := public.at_exigir(p_id);
  if public.meu_papel() not in ('representante', 'coordenador') then raise exception 'Sem permissão'; end if;
  return a;
end
$$;

-- ---- Abrir ----
-- quem é o dono deste telefone (sem mostrar dados de cliente de outro vendedor)
create or replace function public.buscar_telefone(p_telefone text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare c public.clientes; v_tel text := regexp_replace(p_telefone, '[^0-9]', '', 'g'); v_meu boolean;
begin
  if public.meu_papel() is null then raise exception 'Sem permissão'; end if;
  select * into c from public.clientes where telefone = v_tel;
  if not found then return jsonb_build_object('existe', false); end if;
  v_meu := public.pode_ver(c.vendedor);
  return jsonb_build_object('existe', true, 'titular', c.vendedor, 'meu', v_meu,
    'nome', case when v_meu then c.nome end, 'cliente_id', case when v_meu then c.id end);
end
$$;

create or replace function public.abrir_atendimento(p_telefone text, p_nome text, p_canal text, p_titular text, p_lgpd boolean) returns bigint
language plpgsql security definer set search_path = public as $$
declare
  v_tel text := regexp_replace(p_telefone, '[^0-9]', '', 'g');
  v_eu text := public.meu_nome();
  v_titular text := coalesce(nullif(p_titular, ''), v_eu);
  c public.clientes;
  v_id bigint;
begin
  if public.meu_papel() is null then raise exception 'Sem permissão'; end if;
  if length(v_tel) < 10 then raise exception 'Telefone inválido'; end if;
  if not p_lgpd then raise exception 'Falta a autorização do cliente'; end if;
  if not exists (select 1 from public.vendedores where nome = v_titular) then raise exception 'Vendedor não encontrado'; end if;
  select * into c from public.clientes where telefone = v_tel;
  if found then
    if c.vendedor <> v_titular then raise exception 'CLIENTE_DE:%', c.vendedor; end if;
    update public.clientes set canal = coalesce(nullif(p_canal, ''), canal), lgpd_em = now() where id = c.id;
  else
    if coalesce(trim(p_nome), '') = '' then raise exception 'Falta o nome do cliente'; end if;
    insert into public.clientes (nome, telefone, canal, vendedor, lgpd_em)
    values (trim(p_nome), v_tel, nullif(p_canal, ''), v_titular, now()) returning * into c;
  end if;
  insert into public.atendimentos (cliente_id, vendedor, ajudante)
  values (c.id, v_titular, case when v_titular <> v_eu then v_eu end) returning id into v_id;
  return v_id;
end
$$;

-- ---- Ficha ----
create or replace function public.salvar_ficha(p_id bigint, p jsonb) returns void
language plpgsql security definer set search_path = public as $$
declare a public.atendimentos := public.at_exigir(p_id);
begin
  update public.clientes set
    nome = coalesce(nullif(trim(p->>'nome'), ''), nome),
    telefone2 = nullif(regexp_replace(coalesce(p->>'telefone2', ''), '[^0-9]', '', 'g'), '')
  where id = a.cliente_id;
  update public.atendimentos set
    bem = nullif(p->>'bem', ''),
    credito = (p->>'credito')::numeric, renda = (p->>'renda')::numeric,
    entrada = (p->>'entrada')::numeric, parcela = (p->>'parcela')::numeric,
    restricao = (p->>'restricao')::boolean, restricao_valor = (p->>'restricao_valor')::numeric,
    fgts = (p->>'fgts')::boolean, fgts_valor = (p->>'fgts_valor')::numeric,
    aluguel = (p->>'aluguel')::boolean, aluguel_valor = (p->>'aluguel_valor')::numeric,
    projecoes = coalesce(p->'projecoes', projecoes),
    atualizado_em = now()
  where id = p_id;
end
$$;

-- ---- Finalizar ----
create or replace function public.finalizar_atendimento(p_id bigint, p_situacao text, p_retorno timestamptz, p_motivo text) returns void
language plpgsql security definer set search_path = public as $$
declare a public.atendimentos := public.at_exigir(p_id);
begin
  if p_situacao not in ('vai_voltar', 'nao_volta') then raise exception 'Situação inválida'; end if;
  if p_situacao = 'vai_voltar' and p_retorno is null then raise exception 'Falta a data do retorno'; end if;
  update public.atendimentos set situacao = p_situacao, retorno_em = p_retorno, motivo = nullif(p_motivo, ''), atualizado_em = now() where id = p_id;
end
$$;

create or replace function public.pedir_aprovacao(p_id bigint, p_quando timestamptz) returns void
language plpgsql security definer set search_path = public as $$
declare a public.atendimentos := public.at_exigir(p_id);
begin
  -- sem data: cliente na loja, aguardando agora
  update public.atendimentos set
    situacao = case when p_quando is null then 'aprovacao_loja' else 'aprovacao_agendada' end,
    aprovacao_em = coalesce(p_quando, now()), aprovacao_por = null, aprovacao_motivo = null, atualizado_em = now()
  where id = p_id;
end
$$;

create or replace function public.decidir_aprovacao(p_id bigint, p_aprovado boolean, p_motivo text, p_resposta text, p_retorno timestamptz) returns void
language plpgsql security definer set search_path = public as $$
declare a public.atendimentos := public.at_exigir_gestor(p_id);
begin
  if a.situacao not in ('aprovacao_loja', 'aprovacao_agendada') then raise exception 'Esta ficha não está em aprovação'; end if;
  update public.atendimentos set
    situacao = case when p_aprovado then 'aprovado' else 'reprovado' end,
    aprovacao_por = public.meu_nome(), aprovacao_motivo = nullif(p_motivo, ''),
    resposta_cliente = nullif(p_resposta, ''), retorno_em = p_retorno, atualizado_em = now()
  where id = p_id;
end
$$;

create or replace function public.marcar_proposta(p_id bigint) returns void
language plpgsql security definer set search_path = public as $$
declare a public.atendimentos := public.at_exigir(p_id);
begin
  if a.situacao <> 'aprovado' then raise exception 'A ficha precisa estar aprovada'; end if;
  update public.atendimentos set proposta_em = now(), atualizado_em = now() where id = p_id;
end
$$;

-- ---- Venda: o vendedor registra e o representante confirma ----
create or replace function public.registrar_fechamento(p_id bigint, p_valor numeric, p_data date) returns void
language plpgsql security definer set search_path = public as $$
declare a public.atendimentos := public.at_exigir(p_id);
begin
  if coalesce(p_valor, 0) <= 0 or p_data is null then raise exception 'Falta o valor ou a data da venda'; end if;
  update public.atendimentos set situacao = 'fechou', venda_valor = p_valor, venda_data = p_data, venda_status = 'aguardando', atualizado_em = now() where id = p_id;
end
$$;

create or replace function public.confirmar_venda(p_id bigint, p_confirma boolean) returns void
language plpgsql security definer set search_path = public as $$
declare a public.atendimentos; c public.clientes;
begin
  perform public.exigir_rep();
  select * into a from public.atendimentos where id = p_id;
  if not found or a.venda_status is distinct from 'aguardando' then raise exception 'Esta venda não está aguardando confirmação'; end if;
  if p_confirma then
    select * into c from public.clientes where id = a.cliente_id;
    insert into public.vendas (vendedor, equipe, data, valor, cliente, canal)
    values (a.vendedor, (select equipe from public.vendedores where nome = a.vendedor), a.venda_data, a.venda_valor, c.nome, c.canal);
  end if;
  update public.atendimentos set venda_status = case when p_confirma then 'confirmada' else 'recusada' end, atualizado_em = now() where id = p_id;
end
$$;

do $$
declare f text;
begin
  foreach f in array array[
    'public.at_exigir(bigint)', 'public.at_exigir_gestor(bigint)', 'public.buscar_telefone(text)',
    'public.abrir_atendimento(text, text, text, text, boolean)', 'public.salvar_ficha(bigint, jsonb)',
    'public.finalizar_atendimento(bigint, text, timestamptz, text)', 'public.pedir_aprovacao(bigint, timestamptz)',
    'public.decidir_aprovacao(bigint, boolean, text, text, timestamptz)', 'public.marcar_proposta(bigint)',
    'public.registrar_fechamento(bigint, numeric, date)', 'public.confirmar_venda(bigint, boolean)'
  ] loop
    execute format('revoke all on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
end
$$;

select count(*) as funcoes from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public' and p.proname in ('abrir_atendimento','salvar_ficha','finalizar_atendimento','pedir_aprovacao','decidir_aprovacao','marcar_proposta','registrar_fechamento','confirmar_venda','buscar_telefone');
