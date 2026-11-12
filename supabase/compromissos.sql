-- Compromisso semanal que o vendedor aceita na aba Desempenho.
create table if not exists public.compromissos (
  id        bigint generated always as identity primary key,
  vendedor  text not null,
  semana    date not null,               -- primeiro dia da semana a que o compromisso vale
  tipo      text not null,
  texto     text not null,
  aceito_em timestamptz not null default now(),
  unique (vendedor, semana)
);
alter table public.compromissos enable row level security;

drop policy if exists "logado le"    on public.compromissos;
drop policy if exists "logado grava" on public.compromissos;
drop policy if exists "logado troca" on public.compromissos;
create policy "logado le"    on public.compromissos for select to authenticated using (public.pode_ver(vendedor));
create policy "logado grava" on public.compromissos for insert to authenticated with check (public.eh_rep() or vendedor = public.meu_nome());
create policy "logado troca" on public.compromissos for update to authenticated using (public.eh_rep() or vendedor = public.meu_nome()) with check (public.eh_rep() or vendedor = public.meu_nome());
revoke all on public.compromissos from anon;
grant select, insert, update on public.compromissos to authenticated;

select count(*) as tabela_criada from information_schema.tables where table_schema = 'public' and table_name = 'compromissos';
