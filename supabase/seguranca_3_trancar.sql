-- Segurança, etapa 3: tranca o banco (rodar depois que o site com login estiver no ar).

-- Fim do acesso livre pela chave pública
do $$
declare t text;
begin
  foreach t in array array['vendedores','ligacoes','fechamentos','metas','cronograma','equipes','producao_mensal','vendas',
                           'relatorios','ranking_historico','campanhas','campanha_ajustes','config','metas_pessoais'] loop
    execute format('drop policy if exists "site" on public.%I', t);
  end loop;
end
$$;
drop policy if exists "leitura" on public.metricas_semanais;

-- A planilha espelho (n8n) segue lendo só o que não tem dado de cliente nem PIN
drop policy if exists "espelho" on public.ligacoes;
drop policy if exists "espelho" on public.fechamentos;
drop policy if exists "espelho" on public.metas;
create policy "espelho" on public.ligacoes    for select to anon using (true);
create policy "espelho" on public.fechamentos for select to anon using (true);
create policy "espelho" on public.metas       for select to anon using (true);

-- Só quem tem perfil no sistema conta como "logado" (uma conta criada por fora não vê nada)
do $$
declare t text;
begin
  foreach t in array array['vendedores','cronograma','equipes','ranking_historico','campanhas','campanha_ajustes','config','metricas_semanais'] loop
    execute format('drop policy if exists "logado le" on public.%I', t);
    execute format('create policy "logado le" on public.%I for select to authenticated using (public.meu_papel() is not null)', t);
  end loop;
end
$$;

create or replace function public.vendas_resumo()
returns table (vendedor text, data date, valor numeric, canal text)
language sql stable security definer set search_path = public as $$
  select v.vendedor, v.data, v.valor, v.canal from public.vendas v where public.meu_papel() is not null
$$;

create or replace function public.ligacoes_diarias(p_desde date)
returns table (vendedor text, dia date, total int, atendidas int, agendamentos int)
language sql stable security definer set search_path = public as $$
  select l.vendedor, public.dia_sp(l.ts),
         count(*)::int,
         (count(*) filter (where l.tipo = 'atendeu'))::int,
         (count(*) filter (where lower(l.agendou) = 'sim'))::int
  from public.ligacoes l
  where public.dia_sp(l.ts) >= p_desde and public.meu_papel() is not null
  group by 1, 2
$$;

-- Arquivos: relatórios privados (link temporário); fotos seguem com link público, mas só logado envia
drop policy if exists "relatorios leitura" on storage.objects;
drop policy if exists "relatorios envio"   on storage.objects;
drop policy if exists "relatorios remocao" on storage.objects;
drop policy if exists "relatorios troca"   on storage.objects;
drop policy if exists "fotos leitura"      on storage.objects;
drop policy if exists "fotos envio"        on storage.objects;
drop policy if exists "fotos remocao"      on storage.objects;
drop policy if exists "fotos logado envia"  on storage.objects;
drop policy if exists "fotos logado remove" on storage.objects;
create policy "fotos logado envia"  on storage.objects for insert to authenticated with check (bucket_id = 'fotos' and public.meu_papel() is not null);
create policy "fotos logado remove" on storage.objects for delete to authenticated using (bucket_id = 'fotos' and public.meu_papel() is not null);
update storage.buckets set public = false where id = 'relatorios';

-- Funções: sem login, só a lista de nomes da tela de entrada
do $$
declare f text;
begin
  foreach f in array array[
    'public.dados_vendedor(text)', 'public.admin_ranking(text, text)', 'public.get_metas(text)', 'public.set_meta(text, text, integer)',
    'public.ligacoes_diarias(date)', 'public.vendas_resumo()', 'public.meu_perfil()', 'public.trocar_meu_pin(text)',
    'public.admin_criar_vendedor(text, text, text)', 'public.admin_criar_coordenador(text, text, text)',
    'public.admin_redefinir_pin(text, text)', 'public.admin_remover_acesso(text, text)', 'public.admin_definir_equipe(text, text)',
    'public.admin_coordenadores()'
  ] loop
    execute format('revoke all on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
end
$$;
revoke all on function public.sync_airtable_metricas() from public, anon, authenticated;

-- PINs visíveis para o representante: cifrados, numa tabela sem acesso direto, lidos só por admin_ver_pins()
do $$
begin
  if not exists (select 1 from vault.secrets where name = 'pins_chave') then
    perform vault.create_secret(encode(extensions.gen_random_bytes(32), 'hex'), 'pins_chave', 'Chave que cifra os PINs visíveis ao representante');
  end if;
end
$$;
create table if not exists public.pins_visiveis (
  nome          text not null,
  papel         text not null,
  pin_cifrado   bytea not null,
  atualizado_em timestamptz not null default now(),
  primary key (nome, papel)
);
alter table public.pins_visiveis enable row level security;

create or replace function public.guardar_pin(p_nome text, p_papel text, p_pin text) returns void
language sql security definer set search_path = public, extensions as $$
  insert into public.pins_visiveis (nome, papel, pin_cifrado)
  values (p_nome, p_papel, extensions.pgp_sym_encrypt(p_pin, (select decrypted_secret from vault.decrypted_secrets where name = 'pins_chave')))
  on conflict (nome, papel) do update set pin_cifrado = excluded.pin_cifrado, atualizado_em = now()
$$;
revoke all on function public.guardar_pin(text, text, text) from public, anon, authenticated;

create or replace function public.admin_ver_pins()
returns table (nome text, papel text, pin text)
language plpgsql stable security definer set search_path = public, extensions as $$
begin
  perform public.exigir_rep();
  return query
    select p.nome, p.papel, extensions.pgp_sym_decrypt(p.pin_cifrado, (select decrypted_secret from vault.decrypted_secrets where name = 'pins_chave'))
    from public.pins_visiveis p;
end
$$;
revoke all on function public.admin_ver_pins() from public, anon;
grant execute on function public.admin_ver_pins() to authenticated;

create or replace function public.trocar_meu_pin(p_novo text) returns void
language plpgsql security definer set search_path = public, extensions, auth as $$
declare r public.perfis;
begin
  if p_novo !~ '^[0-9]{6}$' then raise exception 'O PIN precisa ter 6 números'; end if;
  select * into r from public.perfis where user_id = auth.uid();
  update auth.users set encrypted_password = extensions.crypt('fbs-' || p_novo, extensions.gen_salt('bf')), updated_at = now()
   where id = auth.uid();
  update public.perfis set trocar_pin = false where user_id = auth.uid();
  perform public.guardar_pin(r.nome, r.papel, p_novo);
end
$$;

create or replace function public.admin_criar_vendedor(p_nome text, p_pin text, p_equipe text) returns void
language plpgsql security definer set search_path = public as $$
declare v_id uuid;
begin
  perform public.exigir_rep();
  if p_pin !~ '^[0-9]{4,6}$' then raise exception 'O PIN provisório precisa ter de 4 a 6 números'; end if;
  insert into public.vendedores (nome, equipe) values (trim(p_nome), p_equipe);
  v_id := public.criar_login(public.email_login(trim(p_nome)), 'fbs-' || p_pin);
  insert into public.perfis (user_id, papel, nome, equipe, trocar_pin) values (v_id, 'vendedor', trim(p_nome), p_equipe, true);
  perform public.guardar_pin(trim(p_nome), 'vendedor', p_pin);
end
$$;

create or replace function public.admin_criar_coordenador(p_nome text, p_pin text, p_equipe text) returns void
language plpgsql security definer set search_path = public as $$
declare v_id uuid;
begin
  perform public.exigir_rep();
  if p_pin !~ '^[0-9]{4,6}$' then raise exception 'O PIN provisório precisa ter de 4 a 6 números'; end if;
  v_id := public.criar_login(public.email_login(trim(p_nome)), 'fbs-' || p_pin);
  insert into public.perfis (user_id, papel, nome, equipe, trocar_pin) values (v_id, 'coordenador', trim(p_nome), p_equipe, true);
  perform public.guardar_pin(trim(p_nome), 'coordenador', p_pin);
end
$$;

create or replace function public.admin_redefinir_pin(p_nome text, p_pin text) returns void
language plpgsql security definer set search_path = public, extensions, auth as $$
declare r record;
begin
  perform public.exigir_rep();
  if p_pin !~ '^[0-9]{4,6}$' then raise exception 'O PIN provisório precisa ter de 4 a 6 números'; end if;
  update auth.users set encrypted_password = extensions.crypt('fbs-' || p_pin, extensions.gen_salt('bf')), updated_at = now()
   where id in (select user_id from public.perfis where nome = p_nome and papel in ('vendedor', 'coordenador'));
  update public.perfis set trocar_pin = true where nome = p_nome and papel in ('vendedor', 'coordenador');
  for r in select papel from public.perfis where nome = p_nome and papel in ('vendedor', 'coordenador') loop
    perform public.guardar_pin(p_nome, r.papel, p_pin);
  end loop;
end
$$;

create or replace function public.admin_remover_acesso(p_nome text, p_papel text) returns void
language plpgsql security definer set search_path = public, auth as $$
begin
  perform public.exigir_rep();
  if p_papel not in ('vendedor', 'coordenador') then raise exception 'Papel inválido'; end if;
  delete from auth.users where id in (select user_id from public.perfis where nome = p_nome and papel = p_papel);
  delete from public.pins_visiveis where nome = p_nome and papel = p_papel;
  if p_papel = 'vendedor' then delete from public.vendedores where nome = p_nome; end if;
end
$$;

-- traz os PINs de quem ainda não trocou, e só depois tira o texto puro da tabela de vendedores
select public.guardar_pin(v.nome, 'vendedor', v.pin)
from public.vendedores v
join public.perfis p on p.nome = v.nome and p.papel = 'vendedor' and p.trocar_pin
where v.pin is not null;
update public.vendedores set pin = null;

select count(*) as regras_abertas from pg_policies where policyname = 'site';
