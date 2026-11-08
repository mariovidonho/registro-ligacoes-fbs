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

-- PINs não ficam mais em texto no banco: o login usa só a versão criptografada
update public.vendedores set pin = null;

select count(*) as regras_abertas from pg_policies where policyname = 'site';
