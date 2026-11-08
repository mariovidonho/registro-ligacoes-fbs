-- Telefone do vendedor: editado no perfil, sai no rodapé da folha de proposta.
alter table public.vendedores add column if not exists telefone text;
grant select (telefone) on public.vendedores to authenticated;
grant update (telefone) on public.vendedores to authenticated;

select count(*) as coluna_criada from information_schema.columns
where table_schema = 'public' and table_name = 'vendedores' and column_name = 'telefone';
