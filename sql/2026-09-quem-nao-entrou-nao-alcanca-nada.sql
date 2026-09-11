-- ============================================================
--  QUEM NÃO ENTROU NÃO ALCANÇA NADA — a segunda camada
--
--  >>> RODAR NO SUPABASE DO **ZORVIN** (o das conversas). <<<
--  Dashboard → SQL Editor → New query → cole tudo → Run.
--  Pode rodar de novo sem medo.
--
--  ------------------------------------------------------------
--  PRIMEIRO, O QUE ISTO **NÃO** É
--
--  Não é o conserto de um vazamento. Hoje `anon` — o papel de quem não entrou,
--  cuja chave vai no código da página — não tira UMA LINHA de tabela nenhuma:
--  as 42 políticas do banco são todas para `authenticated`, e sem política a
--  regra de acesso não devolve nada. Isso foi medido na varredura de 09/09.
--
--  ------------------------------------------------------------
--  ENTÃO POR QUE MEXER
--
--  Porque a regra de acesso está sozinha. Ela é a ÚNICA coisa entre a chave
--  pública e o banco inteiro: `anon` tem DELETE, INSERT, UPDATE, SELECT e até
--  TRUNCATE em todas as tabelas. Enquanto nenhuma política o alcançar, nada
--  acontece. Na primeira que o alcançar, acontece tudo.
--
--  E isso não é hipótese. Aconteceu duas vezes, as duas achadas na mesma
--  varredura:
--
--    - `painel dispensa aviso de falha`, em `fila_envio`, valia para
--      `{anon, authenticated}`. Quem não entrou podia marcar como descartada
--      qualquer mensagem com erro — ou seja, fazer sumir todas as bolhas
--      vermelhas do escritório, e a equipe acreditar que as mensagens saíram.
--    - a vista `equipe` entregava 21 linhas de `usuarios` a quem não entrou.
--
--  As duas já foram fechadas. O que este arquivo faz é tirar a permissão
--  DEBAIXO delas, para a terceira não custar o mesmo susto: com o `revoke`, uma
--  política escrita sem querer para `anon` encontra a porta fechada assim
--  mesmo.
--
--  ------------------------------------------------------------
--  O QUE PODE QUEBRAR: nada que o painel faça
--
--  Foi conferido no código antes de escrever isto. `App.jsx` só monta o
--  `Painel` quando existe sessão, e `Login.jsx` não lê tabela nenhuma — nenhuma
--  consulta sai do painel com a chave anônima. Depois de entrar, quem fala com
--  o banco é `authenticated`, que não é tocado aqui.
--
--  A ponte também não: ela usa a chave de serviço.
-- ============================================================

-- ------------------------------------------------------------
--  1) ANTES — o retrato, para comparar depois
-- ------------------------------------------------------------
select 'tabelas que quem não entrou alcança' as item,
       count(distinct table_name)::text      as quanto
  from information_schema.role_table_grants
 where table_schema = 'public' and grantee = 'anon'
union all
select 'e com quantas permissões ao todo',
       count(*)::text
  from information_schema.role_table_grants
 where table_schema = 'public' and grantee = 'anon'
union all
select 'contagens que quem está dentro continua vendo (contatos)',
       (select count(*)::text from public.contatos);


-- ------------------------------------------------------------
--  2) A MUDANÇA
--
--  "ALL TABLES" no Postgres inclui as VISTAS — que é o que se quer, já que foi
--  justamente por uma vista que a lista da equipe vazou.
--
--  As SEQUÊNCIAS vão junto. Elas são o que permite inserir numa tabela cujo id
--  se gera sozinho; sem elas, um INSERT que escapasse por uma política mal
--  escrita esbarraria aqui também. `authenticated` mantém as suas — é assim que
--  uma nota nova ganha número.
-- ------------------------------------------------------------
revoke all on all tables    in schema public from anon;
revoke all on all sequences in schema public from anon;


-- ------------------------------------------------------------
--  3) A FUNÇÃO QUE APAGA, FECHADA PARA QUEM NÃO É A PONTE
--
--  `limpar_eventos_recebidos()` é `security definer` e APAGA linhas. Funções
--  nascem executáveis por `public`, que inclui `anon` — então, como estava,
--  qualquer um com a chave da página podia mandar rodá-la.
--
--  O estrago seria discreto e por isso pior: ela só apaga eventos já
--  processados com mais de 7 dias, então ninguém notaria nada — e a pista de
--  "esta mensagem chegou aqui?" sumiria justo quando alguém fosse procurar.
--
--  Quem a chama é a PONTE, de hora em hora, com a chave de serviço. É a única
--  que precisa.
-- ------------------------------------------------------------
do $$
begin
  if to_regprocedure('public.limpar_eventos_recebidos()') is not null then
    execute 'revoke all on function public.limpar_eventos_recebidos() from public';
    if exists (select 1 from pg_roles where rolname = 'anon') then
      execute 'revoke all on function public.limpar_eventos_recebidos() from anon';
    end if;
    if exists (select 1 from pg_roles where rolname = 'authenticated') then
      execute 'revoke all on function public.limpar_eventos_recebidos() from authenticated';
    end if;
    -- E devolvida a quem a usa. Sem esta linha a limpeza da caixa de entrada
    -- pararia calada, e a tabela cresceria para sempre.
    if exists (select 1 from pg_roles where rolname = 'service_role') then
      execute 'grant execute on function public.limpar_eventos_recebidos() to service_role';
    end if;
  end if;
end $$;


-- ------------------------------------------------------------
--  4) CONFERÊNCIA — rode e leia
-- ------------------------------------------------------------
select 'quem não entrou não tem permissão em tabela nenhuma' as item,
       not exists (select 1 from information_schema.role_table_grants
                    where table_schema = 'public' and grantee = 'anon') as ok
union all
select 'nem em sequência nenhuma',
       not exists (select 1 from information_schema.role_usage_grants
                    where object_schema = 'public' and grantee = 'anon')
union all
select 'quem está DENTRO continua lendo as conversas',
       has_table_privilege('authenticated', 'public.conversas', 'SELECT')
union all
select 'e continua podendo enfileirar um envio',
       has_table_privilege('authenticated', 'public.fila_envio', 'INSERT')
union all
select 'e apagar uma nota',
       has_table_privilege('authenticated', 'public.notas', 'DELETE')
union all
select 'a limpeza da caixa é só da ponte',
       not has_function_privilege('anon', 'public.limpar_eventos_recebidos()', 'EXECUTE')
union all
select 'e a ponte continua podendo chamá-la',
       has_function_privilege('service_role', 'public.limpar_eventos_recebidos()', 'EXECUTE');


-- ------------------------------------------------------------
--  5) A PROVA DE FOGO — ler como quem NÃO entrou
--
--  Tem de dar ERRO de permissão. Erro aqui é a boa notícia; número é a porta
--  aberta. Antes desta mudança as duas devolviam 0 — o vazio da regra de
--  acesso, que é proteção de uma camada só.
-- ------------------------------------------------------------
set local role anon;
select count(*) from public.contatos;
reset role;


-- ------------------------------------------------------------
--  6) O QUE FICA PARA A PRÓXIMA RODADA — só leitura, não muda nada
--
--  (a) AS FUNÇÕES. Toda função nasce executável por `public`, e várias aqui são
--      `security definer` — ou seja, rodam com os poderes de quem as criou e
--      não passam pela regra de acesso. É o mesmo feitio da vista `equipe`, que
--      foi por onde a lista da equipe vazou.
--
--      Não mexo nelas agora porque fechá-las em bloco pode derrubar o painel: o
--      acesso de `authenticated` a várias delas vem justamente do `public`, e
--      tirar de um é tirar do outro. Precisa ser uma a uma, com o nome de quem
--      chama cada qual — e para isso serve esta lista.
--
--  (b) AS PERMISSÕES QUE NASCEM SOZINHAS. Se o banco estiver configurado para
--      dar tudo a `anon` em cada tabela nova, a próxima tabela reabre o que
--      este arquivo acabou de fechar, e ninguém fica sabendo.
-- ------------------------------------------------------------
select p.proname                              as funcao,
       p.prosecdef                            as roda_com_poder_de_dono,
       has_function_privilege('anon', p.oid, 'EXECUTE')          as anon_pode,
       has_function_privilege('authenticated', p.oid, 'EXECUTE') as logado_pode
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public'
 order by p.prosecdef desc, p.proname;

select defaclobjtype as tipo_de_objeto,
       pg_get_userbyid(defaclrole) as quem_cria,
       defaclacl      as permissoes_que_nascem_juntas
  from pg_default_acl d
  join pg_namespace n on n.oid = d.defaclnamespace
 where n.nspname = 'public';
