-- ============================================================
--  A TABELA NOVA NÃO NASCE ABERTA
--
--  >>> RODAR NO SUPABASE DO **ZORVIN** (o das conversas). <<<
--  Dashboard → SQL Editor → New query → cole tudo → Run.
--  Pode rodar de novo sem medo.
--
--  ------------------------------------------------------------
--  O QUE ISTO CONSERTA
--
--  O arquivo anterior (`2026-09-quem-nao-entrou-nao-alcanca-nada.sql`) tirou
--  112 permissões de `anon` em 16 tabelas. Foi medido depois: zero.
--
--  E aquilo tem prazo de validade. A varredura seguinte mostrou por quê:
--
--      tipo  quem cria        o que nasce junto
--      r     postgres         anon=arwdDxtm     (inserir, ler, alterar,
--      S     postgres         anon=rwU           apagar, esvaziar…)
--      f     postgres         anon=X
--
--  Toda tabela, sequência e função NOVA criada em `public` nasce liberada para
--  `anon` — o papel de quem não entrou, cuja chave vai no código da página. Não
--  foi descuido de ninguém: é a configuração que o Supabase deixa pronta, e foi
--  assim que as 16 tabelas chegaram lá.
--
--  Quer dizer que a PRÓXIMA tabela que alguém criar reabre o que fechamos, e
--  ninguém fica sabendo. É o tipo de coisa que só aparece meses depois, numa
--  varredura que talvez ninguém faça.
--
--  ------------------------------------------------------------
--  O QUE **NÃO** MUDA: quem está dentro
--
--  Só `anon` sai da herança. `authenticated` continua recebendo o que sempre
--  recebeu em cada tabela nova — então nada no jeito de trabalhar muda, e uma
--  tabela criada amanhã continua servindo o painel sem passo extra nenhum.
--
--  (A regra de acesso continua sendo assunto à parte: tabela nova precisa da
--   POLÍTICA junto, ou o painel vê vazio sem mensagem de erro. Isso está na
--   armadilha 1 do CLAUDE.md do painel e não muda com este arquivo.)
--
--  ------------------------------------------------------------
--  DOIS DONOS, E SÓ UM DELES É NOSSO
--
--  A herança está registrada duas vezes: uma para `postgres` e outra para
--  `supabase_admin`. A que importa para nós é a do `postgres` — é com ele que
--  o editor de SQL cria as coisas, e portanto é dele toda tabela que este
--  projeto criou (`eventos_recebidos`, entre outras).
--
--  A do `supabase_admin` é do próprio Supabase, e pode ser que este login nem
--  tenha direito de mexer nela. Por isso ela vai dentro de um bloco que TENTA e
--  DIZ o que houve, em vez de derrubar o arquivo inteiro num erro de permissão
--  — o que faria a parte que funciona não ser aplicada.
-- ============================================================

-- ------------------------------------------------------------
--  1) ANTES — o retrato, para comparar depois
-- ------------------------------------------------------------
select case d.defaclobjtype when 'r' then 'tabelas e vistas'
                            when 'S' then 'sequências'
                            when 'f' then 'funções'
                            else d.defaclobjtype::text end as nasce_para,
       pg_get_userbyid(d.defaclrole)                       as quem_cria,
       array_to_string(d.defaclacl, ' | ')                 as heranca
  from pg_default_acl d
  join pg_namespace n on n.oid = d.defaclnamespace
 where n.nspname = 'public'
 order by quem_cria, nasce_para;


-- ------------------------------------------------------------
--  2) A MUDANÇA — o que o `postgres` cria
--
--  Este é o dono que importa: é com ele que o editor de SQL cria as coisas.
-- ------------------------------------------------------------
alter default privileges for role postgres in schema public revoke all    on tables    from anon;
alter default privileges for role postgres in schema public revoke all    on sequences from anon;
alter default privileges for role postgres in schema public revoke execute on functions from anon;


-- ------------------------------------------------------------
--  3) A MUDANÇA — o que o `supabase_admin` cria (se der)
--
--  TENTA E DIZ. Sem o bloco, um erro de permissão aqui derrubaria o arquivo
--  inteiro — e a parte 2, que é a que importa e que funciona, não teria sido
--  aplicada. Falhar aqui não é problema: o Supabase cria as próprias coisas nos
--  esquemas dele, e o que nos interessa em `public` vem do `postgres`.
-- ------------------------------------------------------------
do $$
begin
  execute 'alter default privileges for role supabase_admin in schema public revoke all on tables from anon';
  execute 'alter default privileges for role supabase_admin in schema public revoke all on sequences from anon';
  execute 'alter default privileges for role supabase_admin in schema public revoke execute on functions from anon';
  raise notice 'A herança do supabase_admin também foi fechada.';
exception when others then
  raise notice 'Não deu para mexer na herança do supabase_admin (%). Tudo bem: '
               'a que importa é a do postgres, que é com quem o editor de SQL cria '
               'as tabelas deste projeto.', sqlerrm;
end $$;


-- ------------------------------------------------------------
--  4) CONFERÊNCIA — rode e leia
--
--  `anon_na_heranca` tem de ser FALSE em todas as linhas do `postgres`.
--  `logado_na_heranca` tem de continuar TRUE — senão a próxima tabela nasce
--  invisível para o painel, que é o outro jeito de errar isto.
-- ------------------------------------------------------------
select case d.defaclobjtype when 'r' then 'tabelas e vistas'
                            when 'S' then 'sequências'
                            when 'f' then 'funções'
                            else d.defaclobjtype::text end as nasce_para,
       pg_get_userbyid(d.defaclrole)                       as quem_cria,
       array_to_string(d.defaclacl, ' | ')  ~ 'anon='          as anon_na_heranca,
       array_to_string(d.defaclacl, ' | ')  ~ 'authenticated=' as logado_na_heranca
  from pg_default_acl d
  join pg_namespace n on n.oid = d.defaclnamespace
 where n.nspname = 'public'
 order by quem_cria, nasce_para;


-- ------------------------------------------------------------
--  5) A PROVA DE FOGO — uma tabela de mentira, criada e apagada aqui
--
--  Conferir a herança é ler a configuração. Isto é outra coisa: CRIA uma tabela
--  de verdade, pergunta quem a alcança, e apaga. É a diferença entre "a regra
--  diz que não deveria" e "não acontece".
--
--  Ela vive três linhas e some. Nenhum dado é tocado.
-- ------------------------------------------------------------
create table if not exists public.zorvin_teste_de_heranca (id int);

select 'a tabela nova NÃO nasce aberta para quem não entrou' as item,
       not has_table_privilege('anon', 'public.zorvin_teste_de_heranca', 'SELECT') as ok
union all
select 'e continua nascendo visível para quem está dentro',
       has_table_privilege('authenticated', 'public.zorvin_teste_de_heranca', 'SELECT');

drop table public.zorvin_teste_de_heranca;


-- ------------------------------------------------------------
--  DEPOIS DE RODAR
--
--  Nada muda no painel — isto só vale para tabelas que ainda não existem.
--  Confira mesmo assim: entre, abra uma conversa, mande uma mensagem. Se algo
--  falhar, não é daqui, mas eu quero saber.
--
--  Desfazer:
--      alter default privileges for role postgres in schema public
--        grant all on tables to anon;
--      alter default privileges for role postgres in schema public
--        grant all on sequences to anon;
--      alter default privileges for role postgres in schema public
--        grant execute on functions to anon;
-- ------------------------------------------------------------
