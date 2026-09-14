-- ============================================================
--  AS QUATRO FUNÇÕES QUE RODAM COM PODER DE DONO
--
--  >>> RODAR NO SUPABASE DO **ZORVIN** (o das conversas). <<<
--  Dashboard → SQL Editor → New query → cole tudo → Run.
--  Pode rodar de novo sem medo.
--
--  ------------------------------------------------------------
--  O QUE ISTO FECHA
--
--  Toda função no Postgres nasce executável por `public` — todo mundo,
--  inclusive `anon`, o papel de quem NÃO entrou, cuja chave vai no código da
--  página. Quatro delas são `security definer`: rodam com os poderes de quem as
--  criou e **não passam pela regra de acesso**.
--
--  É o mesmo feitio da vista `equipe`, que foi por onde a lista da equipe vazou
--  (21 linhas medidas, em 09/09). Aqui o vazamento não foi medido — nenhuma
--  delas devolve linha para quem não tem sessão, porque todas dependem de
--  `auth.uid()` e para `anon` ele é nulo. Isto é a mesma segunda camada do
--  `revoke` das tabelas: tirar a permissão DEBAIXO, para a próxima mudança de
--  política não encontrar a porta encostada.
--
--  ------------------------------------------------------------
--  POR QUE ISTO É A MUDANÇA MAIS PERIGOSA DA SÉRIE
--
--  `pode_ver_conversa` e `meus_telefones` NÃO SÃO CHAMADAS POR NINGUÉM — nem
--  pelo painel, nem pela ponte. Elas vivem DENTRO das políticas de acesso, que
--  o banco avalia em nome de quem está logado.
--
--  Quer dizer: se `authenticated` perder a permissão de executá-las, a leitura
--  de `conversas` morre com `permission denied` para o escritório inteiro. É
--  exatamente o formato do acidente de 04/09, quando um `revoke` sem a coluna
--  `setor` derrubou as etiquetas e as notas.
--
--  Por isso aqui não se faz `revoke ... from public` e pronto: cada função
--  **recebe de volta, explicitamente**, a permissão para `authenticated`. Tirar
--  de `public` sem devolver seria o acidente.
--
--  A PONTE NÃO PRECISA DE NENHUMA DELAS. Ela usa a chave de serviço, que ignora
--  a regra de acesso — então as políticas (e as funções dentro delas) nem
--  chegam a ser avaliadas para ela. Foi conferido no código: nenhuma das quatro
--  é chamada em `index.js`.
-- ============================================================

-- ------------------------------------------------------------
--  1) ANTES — o retrato, para comparar depois
-- ------------------------------------------------------------
select p.proname                                             as funcao,
       p.prosecdef                                           as roda_com_poder_de_dono,
       has_function_privilege('anon', p.oid, 'EXECUTE')          as anon_pode,
       has_function_privilege('authenticated', p.oid, 'EXECUTE') as logado_pode
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public'
   and p.proname in ('meus_telefones', 'pode_ver_conversa',
                     'salvar_minha_foto', 'zorvin_admin')
 order by p.proname;

-- E QUAIS POLÍTICAS DEPENDEM DELAS. É a lista do que quebra se eu errar —
-- cada tabela aqui é uma tela que para de carregar.
select tablename as tabela, policyname as regra, cmd as no_que
  from pg_policies
 where schemaname = 'public'
   and (coalesce(qual, '') || coalesce(with_check, ''))
       ~ '(meus_telefones|pode_ver_conversa|zorvin_admin)'
 order by tablename, policyname;


-- ------------------------------------------------------------
--  2) A MUDANÇA — uma a uma, e devolvendo a chave a quem precisa
--
--  O laço percorre TODAS as versões de cada nome. Função pode ter mais de uma
--  assinatura, e fechar só a que alguém lembrou de escrever deixaria a outra
--  aberta — sem ninguém notar, porque a conferência diria "fechada".
-- ------------------------------------------------------------
do $$
declare
  f record;
begin
  for f in
    select p.oid::regprocedure as assinatura
      from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and p.proname in ('meus_telefones', 'pode_ver_conversa',
                         'salvar_minha_foto', 'zorvin_admin')
  loop
    -- `public` é "todo mundo", e é de onde vem o acesso do `anon`. Tirar dele é
    -- o que fecha a porta; tirar só do `anon` não faria nada, porque ele
    -- continuaria alcançando pela porta de todos.
    execute format('revoke all on function %s from public', f.assinatura);
    if exists (select 1 from pg_roles where rolname = 'anon') then
      execute format('revoke all on function %s from anon', f.assinatura);
    end if;
    -- E A CHAVE VOLTA PARA QUEM ESTÁ DENTRO. Sem esta linha, a leitura de
    -- `conversas` morre com "permission denied" para o escritório inteiro:
    -- duas destas funções são avaliadas dentro das políticas, em nome de quem
    -- está logado.
    if exists (select 1 from pg_roles where rolname = 'authenticated') then
      execute format('grant execute on function %s to authenticated', f.assinatura);
    end if;
    raise notice 'fechada para todos e devolvida a quem entra: %', f.assinatura;
  end loop;
end $$;


-- ------------------------------------------------------------
--  3) CONFERÊNCIA — rode e leia
--
--  As quatro linhas têm de vir com `anon_pode = false` e `logado_pode = true`.
--  Qualquer uma com `logado_pode = false` é a leitura de conversas quebrada —
--  desfaça antes de sair da tela (o desfazer está no fim).
-- ------------------------------------------------------------
select p.proname                                             as funcao,
       has_function_privilege('anon', p.oid, 'EXECUTE')          as anon_pode,
       has_function_privilege('authenticated', p.oid, 'EXECUTE') as logado_pode
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public'
   and p.proname in ('meus_telefones', 'pode_ver_conversa',
                     'salvar_minha_foto', 'zorvin_admin')
 order by p.proname;


-- ------------------------------------------------------------
--  4) A PROVA DE FOGO — ler as tabelas que dependem delas
--
--  O que importa aqui é NÃO DAR ERRO. O número pode vir 0, e isso é normal:
--  não há sessão de verdade nesta janela, e as políticas dependem dela.
--
--  ERRO, SIM, é o sinal de que uma política perdeu a função que ela chama — e
--  aí o escritório inteiro fica sem ler conversa.
-- ------------------------------------------------------------
set local role authenticated;
select 'conversas'     as tabela, count(*) from public.conversas
union all select 'mensagens',     count(*) from public.mensagens
union all select 'conversa_tags', count(*) from public.conversa_tags
union all select 'notas',         count(*) from public.notas
union all select 'usuarios',      count(*) from public.usuarios;
reset role;


-- ------------------------------------------------------------
--  5) ESTA PARTE O SQL NÃO CONSEGUE FAZER: ABRIR O PAINEL
--
--  A prova de fogo acima roda SEM SESSÃO, e isso tem um limite que precisa
--  estar escrito: se uma política for do feitio `auth.uid() is not null AND
--  pode_ver_conversa(...)`, o Postgres nem chega a chamar a função quando não
--  há sessão — a conferência passa e o defeito só aparece para quem entra.
--
--  É o mesmo tipo de armadilha da política RESTRITIVA de 04/09: a consulta
--  parecia bem e a tela do escritório é que dizia a verdade.
--
--  ENTÃO A CONFERÊNCIA DE VERDADE É ESTA, e ela é sua:
--
--    1. entre no painel;
--    2. veja se a lista de conversas carrega;
--    3. abra uma conversa e veja as mensagens, as etiquetas e as notas;
--    4. se você administra, abra a tela de departamentos.
--
--  Qualquer coisa que não carregar, desfaça pelo bloco abaixo e me avise.
-- ------------------------------------------------------------


-- ------------------------------------------------------------
--  DESFAZER — se alguma coisa parar de carregar
--
--  Devolve o acesso de todos, que é como estava antes. É seguro rodar: o
--  máximo que acontece é voltar ao estado de hoje.
--
--    do $$
--    declare f record;
--    begin
--      for f in select p.oid::regprocedure as assinatura
--                 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
--                where n.nspname = 'public'
--                  and p.proname in ('meus_telefones','pode_ver_conversa',
--                                    'salvar_minha_foto','zorvin_admin')
--      loop
--        execute format('grant execute on function %s to public', f.assinatura);
--      end loop;
--    end $$;
-- ------------------------------------------------------------
