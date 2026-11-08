-- Segurança, etapa 2: regras do login novo (só acrescenta; o acesso antigo continua até a etapa 3).

-- Vendedores: todo logado vê nome/foto/equipe (nunca o PIN); cada um edita o próprio perfil.
-- Criar, remover e mudar de equipe passa pelas funções admin_*.
revoke select, insert, update, delete on public.vendedores from authenticated;
grant select (nome, equipe, foto_url, apelido, frase, aniversario, criado_em) on public.vendedores to authenticated;
grant update (foto_url, apelido, frase, aniversario) on public.vendedores to authenticated;
drop policy if exists "logado le" on public.vendedores;
drop policy if exists "proprio perfil" on public.vendedores;
create policy "logado le" on public.vendedores for select to authenticated using (auth.uid() is not null);
create policy "proprio perfil" on public.vendedores for update to authenticated
  using (public.eh_rep() or nome = public.meu_nome()) with check (public.eh_rep() or nome = public.meu_nome());

-- Dados de cada vendedor: ele, o coordenador da equipe e o representante
drop policy if exists "logado" on public.ligacoes;
drop policy if exists "logado grava" on public.ligacoes;
drop policy if exists "logado apaga" on public.ligacoes;
create policy "logado" on public.ligacoes for select to authenticated using (public.pode_ver(vendedor));
create policy "logado grava" on public.ligacoes for insert to authenticated with check (public.eh_rep() or vendedor = public.meu_nome());
create policy "logado apaga" on public.ligacoes for delete to authenticated using (public.eh_rep() or vendedor = public.meu_nome());

drop policy if exists "logado" on public.fechamentos;
drop policy if exists "logado altera" on public.fechamentos;
create policy "logado" on public.fechamentos for select to authenticated using (public.pode_ver(vendedor));
create policy "logado altera" on public.fechamentos for all to authenticated
  using (public.eh_rep() or vendedor = public.meu_nome()) with check (public.eh_rep() or vendedor = public.meu_nome());

drop policy if exists "logado" on public.metas;
create policy "logado" on public.metas for all to authenticated using (public.pode_ver(vendedor)) with check (public.pode_ver(vendedor));

drop policy if exists "logado" on public.metas_pessoais;
create policy "logado" on public.metas_pessoais for all to authenticated using (public.pode_ver(vendedor)) with check (public.pode_ver(vendedor));

drop policy if exists "logado" on public.relatorios;
drop policy if exists "marca visto" on public.relatorios;
drop policy if exists "rep envia" on public.relatorios;
drop policy if exists "rep remove" on public.relatorios;
create policy "logado" on public.relatorios for select to authenticated using (public.pode_ver(vendedor));
create policy "marca visto" on public.relatorios for update to authenticated
  using (public.eh_rep() or vendedor = public.meu_nome()) with check (public.eh_rep() or vendedor = public.meu_nome());
create policy "rep envia" on public.relatorios for insert to authenticated with check (public.eh_rep());
create policy "rep remove" on public.relatorios for delete to authenticated using (public.eh_rep());

-- Vendas têm nome de cliente: só o dono, a equipe e o representante. Totais vêm de vendas_resumo().
drop policy if exists "logado" on public.vendas;
drop policy if exists "rep altera" on public.vendas;
create policy "logado" on public.vendas for select to authenticated using (public.pode_ver(vendedor));
create policy "rep altera" on public.vendas for all to authenticated using (public.eh_rep()) with check (public.eh_rep());

drop policy if exists "rep" on public.producao_mensal;
create policy "rep" on public.producao_mensal for all to authenticated using (public.eh_rep()) with check (public.eh_rep());

-- Compartilhado com todo o time; só o representante altera
do $$
declare t text;
begin
  foreach t in array array['cronograma','equipes','ranking_historico','campanhas','campanha_ajustes','config','metricas_semanais'] loop
    execute format('drop policy if exists "logado le" on public.%I', t);
    execute format('drop policy if exists "rep altera" on public.%I', t);
    execute format('create policy "logado le" on public.%I for select to authenticated using (auth.uid() is not null)', t);
    execute format('create policy "rep altera" on public.%I for all to authenticated using (public.eh_rep()) with check (public.eh_rep())', t);
  end loop;
end
$$;

-- Arquivos
drop policy if exists "relatorios logado le" on storage.objects;
drop policy if exists "relatorios rep altera" on storage.objects;
drop policy if exists "fotos logado envia" on storage.objects;
drop policy if exists "fotos logado remove" on storage.objects;
create policy "relatorios logado le" on storage.objects for select to authenticated
  using (bucket_id = 'relatorios' and exists (select 1 from public.relatorios r where r.caminho = name and public.pode_ver(r.vendedor)));
create policy "relatorios rep altera" on storage.objects for all to authenticated
  using (bucket_id = 'relatorios' and public.eh_rep()) with check (bucket_id = 'relatorios' and public.eh_rep());
create policy "fotos logado envia" on storage.objects for insert to authenticated with check (bucket_id = 'fotos');
create policy "fotos logado remove" on storage.objects for delete to authenticated using (bucket_id = 'fotos');

select count(*) as regras from pg_policies where roles @> array['authenticated']::name[];
