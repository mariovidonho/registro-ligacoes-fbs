# Handoff — Registro de Ligações FBS Prime (pronto pro Claude Code)

## O que já existe
Um protótipo funcional de página única (`registro_ligacoes_fbs.html`) onde vendedores registram ligações (Atendeu / Caixa Postal), fecham o relatório do dia, e um admin acompanha tudo num painel com ranking, filtro por dia/mês/ano, e gestão de vendedores. Testado e aprovado dentro do Claude — agora precisa virar um site publicado de verdade.

O arquivo já tem comentários `TODO CLAUDE CODE (1/6)` até `(6/6)` marcando exatamente os 6 pontos que usam `window.storage` (um recurso que só existe dentro do Claude e não funciona fora daqui).

## O que precisa ser feito

1. **Criar repositório no GitHub** com esse HTML (pode virar `index.html` de um projeto simples, ou continuar como está).
2. **Trocar os 6 pontos de `window.storage`** por chamadas `fetch()` para webhooks do n8n, que por sua vez leem/escrevem numa planilha do Google Sheets. Os 6 pontos, com o que cada um precisa fazer:
   - **Ler lista de vendedores + PINs** (hoje: `loadVendorList`)
   - **Salvar lista de vendedores + PINs** quando o admin adiciona/remove alguém (hoje: `saveVendorList`)
   - **Ler histórico de ligações de um vendedor + status do dia** (hoje: `loadVendorData`)
   - **Salvar uma ligação nova** — aqui vale repensar a estrutura: hoje o protótipo reescreve o array inteiro a cada clique, o que não funciona bem numa planilha. O ideal é cada ligação virar **uma linha nova** (INSERT), não reescrever tudo (hoje: `saveAllCalls`)
   - **Marcar/desmarcar o dia como fechado** (hoje: `fecharRelatorio` / `reopenDay`)
   - **Ler os dados agregados de todos os vendedores pro ranking**, já somados pelo período (dia/mês/ano) — evitar buscar vendedor por vendedor como o protótipo faz hoje (hoje: `loadAdminData`)
3. **Estrutura sugerida da planilha** (uma aba "Ligações"): `Vendedor | Tipo (atendeu/caixa_postal) | Data/Hora`. Uma aba separada "Vendedores": `Nome | PIN`. Uma aba "Fechamentos": `Vendedor | Data | Atendidas | Caixa Postal | Total | Fechado em`.
4. **Publicar no Vercel**, conectando direto no repositório do GitHub (import automático, sem configuração extra — é HTML puro).

## Pontos de atenção
- A senha do admin já está com hash (SHA-256) no código, não em texto puro — manter esse padrão.
- Os PINs dos vendedores hoje são os IDs deles no CRM Convex (Arthur Lima=1098, Wellington Augusto=1111, Rayane Castro=1095, Raissa Gabrielly=1097, Nayara Lima=1096, Diane Ruiz=1094, Erick Fernandes=1099, Camila Abreu=1264, Javam Trajano=1265, Cley Silva=1268) — isso é segurança básica, não crítica (ver ressalva abaixo).
- **Isso não tem segurança de nível empresarial** — é uma ferramenta interna pra um time pequeno e de confiança. Não guardar nada sensível além do que já está aqui (contagem de ligações).
- Os webhooks do n8n precisam existir e estar publicados antes dessa troca funcionar — se ainda não foram criados, esse é o primeiro passo antes de mexer no HTML.
