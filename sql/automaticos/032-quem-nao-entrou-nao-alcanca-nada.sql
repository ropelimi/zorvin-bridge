-- ============================================================
--  QUEM NÃO ENTROU NÃO ALCANÇA NADA — de novo, e agora sem prazo (22/10)
--
--  Pedido do Rodrigo, depois de olhar os avisos de segurança da Supabase:
--  fechar as funções internas que até quem não entrou no Zorvin consegue
--  chamar.
--
--  ------------------------------------------------------------
--  O QUE FOI MEDIDO NO BANCO DO ESCRITÓRIO, em 22/10 (só lendo)
--
--  * 13 FUNÇÕES QUE RODAM COM PODER DE DONO (`security definer`) podiam ser
--    chamadas por `anon` — o papel de quem não entrou, cuja chave vai no
--    código da página. Sete são gatilhos (chamar um gatilho pelo nome só dá
--    erro). As outras seis, não: `zorvin_atendimento_abre` CRIA um protocolo
--    para a conversa que se pedir, `zorvin_proximo_protocolo` gasta um número
--    da sequência, `zorvin_recontar_situacao` refaz a aba de uma conversa, e
--    `zorvin_atendimento_ciclos` devolve as datas dos atendimentos de qualquer
--    conversa. Tudo pelo endereço `/rest/v1/rpc/…`, com a chave pública.
--
--  * 15 TABELAS criadas pelos scripts desta pasta nasceram com TODAS as
--    permissões para `anon` (ler, gravar, alterar, apagar, esvaziar). Hoje
--    nada vaza: nenhuma política deixa `anon` passar, e a regra de acesso
--    barra. Mas é a armadilha nº 5 inteira de volta — a regra de acesso
--    sozinha, e uma política escrita para `public` abriria a tabela.
--
--  * A CAUSA das duas é a mesma: a herança. Toda tabela, sequência e função
--    que o `postgres` cria em `public` nasce liberada para `anon`. O arquivo
--    `sql/2026-09-a-tabela-nova-nao-nasce-aberta.sql` existia para fechar
--    isso, e a herança medida hoje está aberta — o arquivo não rodou, ou foi
--    desfeito. Não dá para saber qual, e não importa: aqui ela é fechada pela
--    ponte, com a conferência guardada.
--
--  ------------------------------------------------------------
--  O QUE MUDA
--
--  1. `anon` sai de toda tabela e sequência de `public`;
--  2. nenhuma função com poder de dono pode ser chamada por `anon` — nem por
--     `public`, de que `anon` faz parte. Quem estava liberado só por `public`
--     é DEVOLVIDO a `authenticated` e `service_role` na mesma passada: as que
--     vivem dentro das políticas (`pode_ver_conversa`, `meus_telefones`)
--     derrubariam a leitura do escritório inteiro sem isso;
--  3. as funções INTERNAS — as 13 da medição, que só gatilhos e outras
--     funções de dono chamam — saem também de `authenticated`. Ficam para a
--     ponte (`service_role`), que chama `zorvin_recontar_situacao` depois de
--     juntar duas conversas;
--  4. a herança fecha: o que o `postgres` criar daqui para a frente em
--     `public` nasce sem `anon`, e a função nova nasce sem `public`.
--     `authenticated` continua herdando o que sempre herdou — tabela nova
--     segue servindo o painel sem passo extra.
--
--  O QUE NÃO MUDA, e foi conferido no banco antes de escrever: nenhuma das 13
--  é chamada pelo painel, nem por política, nem por função que roda no papel
--  de quem atende. Gatilho dispara sem que ninguém precise de permissão para
--  executá-lo — a permissão é conferida ao CRIAR o gatilho, e não ao disparar.
--
--  Pode rodar de novo sem medo: cada passo tira ou devolve permissão, e
--  repetir não muda o resultado.
-- ============================================================

-- ------------------------------------------------------------
--  1. AS TABELAS E AS SEQUÊNCIAS
-- ------------------------------------------------------------
do $tabelas$
begin
  if exists (select 1 from pg_roles where rolname = 'anon') then
    execute 'revoke all on all tables in schema public from anon';
    execute 'revoke all on all sequences in schema public from anon';
  end if;
end
$tabelas$;

-- ------------------------------------------------------------
--  2 e 3. AS FUNÇÕES
--
--  Pelo que a função É, e não por uma lista de assinaturas: uma assinatura
--  escrita aqui pararia de casar no dia em que alguém mudasse um argumento, e
--  o `revoke` passaria calado sem tirar nada. As internas vão pelo NOME, com
--  qualquer assinatura.
-- ------------------------------------------------------------
do $funcoes$
declare
  f record;
  v_anon boolean := exists (select 1 from pg_roles where rolname = 'anon');
  v_auth boolean := exists (select 1 from pg_roles where rolname = 'authenticated');
  v_ponte boolean := exists (select 1 from pg_roles where rolname = 'service_role');
  v_internas text[] := array[
    -- os gatilhos (001, 017, 028)
    'zorvin_usuario_novo', 'zorvin_cartao_historico', 'zorvin_funil_cliente_novo',
    'zorvin_situacao_da_mensagem', 'zorvin_situacao_desfeita', 'zorvin_situacao_do_clique',
    'zorvin_situacao_guardada',
    -- as que só os gatilhos e as outras funções de dono chamam (028)
    'zorvin_aberta_ou_aguardando', 'zorvin_atendimento_abre', 'zorvin_atendimento_ciclos',
    'zorvin_proximo_protocolo', 'zorvin_situacao_fora_da_regra',
    -- a que só a ponte chama, depois de juntar duas conversas (028)
    'zorvin_recontar_situacao'];
begin
  for f in
    select p.oid::regprocedure as assinatura, p.proname as nome, p.prosecdef as de_dono,
           exists (select 1 from aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
                    where a.grantee = 0 and a.privilege_type = 'EXECUTE') as por_public
      from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and p.prokind = 'f'
       -- as das extensões ficam com quem as instalou
       and not exists (select 1 from pg_depend d where d.classid = 'pg_proc'::regclass
                        and d.objid = p.oid and d.deptype = 'e')
  loop
    -- `anon` sai de TODAS. A que não é de dono e continua liberada por
    -- `public` (as antigas) roda no papel de quem chama — e `anon`, sem
    -- tabela nenhuma, não lê nada por ela.
    if v_anon then
      execute format('revoke execute on function %s from anon', f.assinatura);
    end if;
    if f.de_dono then
      -- DEVOLVER antes de tirar: entre as duas linhas não pode haver um
      -- instante em que a política do escritório fique sem a função dela.
      if f.por_public then
        if v_auth and not (f.nome = any (v_internas)) then
          execute format('grant execute on function %s to authenticated', f.assinatura);
        end if;
        if v_ponte then
          execute format('grant execute on function %s to service_role', f.assinatura);
        end if;
      end if;
      execute format('revoke execute on function %s from public', f.assinatura);
      if f.nome = any (v_internas) then
        if v_auth then
          execute format('revoke execute on function %s from authenticated', f.assinatura);
        end if;
        if v_ponte then
          execute format('grant execute on function %s to service_role', f.assinatura);
        end if;
      end if;
    end if;
  end loop;
end
$funcoes$;

-- ------------------------------------------------------------
--  4. A HERANÇA
--
--  A do `postgres` é a que importa: é com ele que a ponte aplica esta pasta e
--  que o editor de SQL cria as coisas. A do `supabase_admin` é da Supabase, e
--  este login pode não ter direito de mexer nela — vai num bloco que TENTA e
--  anota, para a parte que importa não cair junto (a lição do arquivo de 09/26).
-- ------------------------------------------------------------
do $heranca$
begin
  if exists (select 1 from pg_roles where rolname = 'anon') then
    execute 'alter default privileges for role postgres in schema public revoke all on tables from anon';
    execute 'alter default privileges for role postgres in schema public revoke all on sequences from anon';
    execute 'alter default privileges for role postgres in schema public revoke execute on functions from anon';
  end if;
  -- `public` SÓ SAI PELA HERANÇA GERAL, sem `in schema`. O Postgres dá
  -- EXECUTE a `public` em toda função nova por conta própria, e a herança de
  -- um esquema só ACRESCENTA ao que a geral dá — tirar `public` com
  -- `in schema public` não faz nada. Medido no Postgres da prova: a função
  -- nova continuava nascendo executável por `anon`, por dentro de `public`.
  -- Fora de `public` o `postgres` não cria função nenhuma do Zorvin, e as de
  -- `public` continuam nascendo para quem entrou e para a ponte (a herança do
  -- esquema, logo acima, que não muda).
  execute 'alter default privileges for role postgres revoke execute on functions from public';
end
$heranca$;

drop table if exists zorvin_conferencia_032;
create temp table zorvin_conferencia_032 (item text, resposta text);

do $admin$
begin
  if exists (select 1 from pg_roles where rolname = 'supabase_admin')
     and exists (select 1 from pg_roles where rolname = 'anon') then
    begin
      execute 'alter default privileges for role supabase_admin in schema public revoke all on tables from anon';
      execute 'alter default privileges for role supabase_admin in schema public revoke all on sequences from anon';
      execute 'alter default privileges for role supabase_admin in schema public revoke execute on functions from anon';
      insert into zorvin_conferencia_032 values ('a herança da Supabase (supabase_admin)', 'fechada também');
    exception when others then
      insert into zorvin_conferencia_032
      values ('a herança da Supabase (supabase_admin)',
              'ficou como a Supabase deixou (' || sqlerrm || ') — a que importa é a do postgres');
    end;
  end if;
end
$admin$;

-- ------------------------------------------------------------
--  A CONFERÊNCIA VAI DENTRO DO SCRIPT, e é a última linha dele.
--
--  E ELA NÃO SÓ LÊ A CONFIGURAÇÃO: cria uma tabela e uma função de mentira e
--  pergunta quem as alcança — a diferença entre "a regra diz que não
--  deveria" e "não acontece". As duas vivem dentro da transação do script e
--  somem antes do fim. Depois, NO PAPEL DE QUEM ATENDE (a régua do 012), lê as
--  conversas e chama as funções do painel: fechar demais é o outro jeito de
--  errar isto, e esse aparece na tela de todo mundo.
-- ------------------------------------------------------------
do $conf$
declare
  v_internas text[] := array[
    'zorvin_usuario_novo', 'zorvin_cartao_historico', 'zorvin_funil_cliente_novo',
    'zorvin_situacao_da_mensagem', 'zorvin_situacao_desfeita', 'zorvin_situacao_do_clique',
    'zorvin_situacao_guardada', 'zorvin_aberta_ou_aguardando', 'zorvin_atendimento_abre',
    'zorvin_atendimento_ciclos', 'zorvin_proximo_protocolo', 'zorvin_situacao_fora_da_regra',
    'zorvin_recontar_situacao'];
  v_n int;
  v_quem uuid;
  v_resposta text;
begin
  if not exists (select 1 from pg_roles where rolname = 'anon')
     or not exists (select 1 from pg_roles where rolname = 'authenticated') then
    insert into zorvin_conferencia_032 values ('os papéis da Supabase', 'ausentes neste banco — nada a fechar');
    return;
  end if;

  select count(*) into v_n
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.prosecdef and has_function_privilege('anon', p.oid, 'execute')
     and not exists (select 1 from pg_depend d where d.classid = 'pg_proc'::regclass
                      and d.objid = p.oid and d.deptype = 'e');
  insert into zorvin_conferencia_032
  values ('nenhuma função com poder de dono pode ser chamada por quem não entrou', (v_n = 0)::text);

  -- E NENHUMA O NOMEIA. As antigas que continuam liberadas por `public` não
  -- contam aqui (ver o passo 2); as que a herança deu a `anon` pelo nome, sim.
  select count(*) into v_n
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public'
     and exists (select 1 from aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
                  where a.grantee = (select oid from pg_roles where rolname = 'anon'))
     and not exists (select 1 from pg_depend d where d.classid = 'pg_proc'::regclass
                      and d.objid = p.oid and d.deptype = 'e');
  insert into zorvin_conferencia_032
  values ('nenhuma função dá permissão a quem não entrou pelo nome', (v_n = 0)::text);

  select count(*) into v_n
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = any (v_internas)
     and has_function_privilege('authenticated', p.oid, 'execute');
  insert into zorvin_conferencia_032
  values ('as funções internas não podem ser chamadas por quem entrou', (v_n = 0)::text);

  if to_regprocedure('public.zorvin_recontar_situacao(uuid)') is not null
     and exists (select 1 from pg_roles where rolname = 'service_role') then
    insert into zorvin_conferencia_032
    values ('a ponte continua podendo refazer a aba de uma conversa',
            has_function_privilege('service_role', 'public.zorvin_recontar_situacao(uuid)', 'execute')::text);
  end if;

  select count(*) into v_n
    from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public' and c.relkind in ('r', 'v', 'm', 'p', 'f')
     and (has_table_privilege('anon', c.oid, 'select') or has_table_privilege('anon', c.oid, 'insert')
          or has_table_privilege('anon', c.oid, 'update') or has_table_privilege('anon', c.oid, 'delete')
          or has_table_privilege('anon', c.oid, 'truncate'));
  insert into zorvin_conferencia_032
  values ('quem não entrou não alcança tabela nenhuma', (v_n = 0)::text);

  select count(*) into v_n
    from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public' and c.relkind = 'S'
     and (has_sequence_privilege('anon', c.oid, 'usage') or has_sequence_privilege('anon', c.oid, 'select')
          or has_sequence_privilege('anon', c.oid, 'update'));
  insert into zorvin_conferencia_032
  values ('nem sequência nenhuma', (v_n = 0)::text);

  -- A PROVA DE FOGO: o que nasce depois deste script.
  drop function if exists public.zorvin_teste_da_heranca_032();
  drop table if exists public.zorvin_teste_da_heranca_032;
  create table public.zorvin_teste_da_heranca_032 (id int);
  create function public.zorvin_teste_da_heranca_032() returns int
    language sql security definer set search_path = public as 'select 1';
  insert into zorvin_conferencia_032
  values ('a tabela nova nasce fechada para quem não entrou',
          (not has_table_privilege('anon', 'public.zorvin_teste_da_heranca_032', 'select'))::text),
         ('e continua nascendo aberta para quem entrou',
          has_table_privilege('authenticated', 'public.zorvin_teste_da_heranca_032', 'select')::text),
         ('a função nova nasce fechada para quem não entrou',
          (not has_function_privilege('anon', 'public.zorvin_teste_da_heranca_032()', 'execute'))::text);
  drop function public.zorvin_teste_da_heranca_032();
  drop table public.zorvin_teste_da_heranca_032;

  -- NO PAPEL DE QUEM ATENDE: uma pessoa que administra, que é quem alcança
  -- tudo. Sem ninguém cadastrado (um banco novo), não há em nome de quem.
  if to_regclass('public.usuarios') is null or to_regclass('public.conversas') is null then
    return;
  end if;
  execute 'select id from public.usuarios where admin and coalesce(ativo, true) order by id limit 1' into v_quem;
  if v_quem is null then
    insert into zorvin_conferencia_032 values ('em nome de quem atende', 'ninguém administra ainda — conferido sem a leitura');
    return;
  end if;

  begin
    perform set_config('request.jwt.claim.sub', v_quem::text, true);
    perform set_config('request.jwt.claims', json_build_object('sub', v_quem, 'role', 'authenticated')::text, true);
    perform set_config('role', 'authenticated', true);
    execute 'select count(*) from (select 1 from public.conversas limit 50) x';
    v_resposta := 'sim';
    execute 'reset role';
  exception when others then
    v_resposta := 'NÃO — ' || sqlerrm || ' (código ' || sqlstate || ')';
  end;
  insert into zorvin_conferencia_032 values ('quem atende continua lendo as conversas', v_resposta);

  if to_regprocedure('public.zorvin_saude()') is not null then
    begin
      perform set_config('role', 'authenticated', true);
      execute 'select public.zorvin_saude()';
      v_resposta := 'sim';
      execute 'reset role';
    exception when others then
      v_resposta := 'NÃO — ' || sqlerrm || ' (código ' || sqlstate || ')';
    end;
    insert into zorvin_conferencia_032 values ('e o aviso de que algo parou continua respondendo', v_resposta);
  end if;

  if to_regprocedure('public.zorvin_contar_situacoes(uuid)') is not null then
    begin
      perform set_config('role', 'authenticated', true);
      execute 'select public.zorvin_contar_situacoes(null::uuid)';
      v_resposta := 'sim';
      execute 'reset role';
    exception when others then
      v_resposta := 'NÃO — ' || sqlerrm || ' (código ' || sqlstate || ')';
    end;
    insert into zorvin_conferencia_032 values ('e o número de cada aba também', v_resposta);
  end if;
end
$conf$;

-- A RESPOSTA DE "DEU CERTO?", na última linha, que é a que o editor mostra.
select * from zorvin_conferencia_032;
