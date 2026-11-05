-- ============================================================
--  A CARTEIRA CONTA A PARTIR DE 2 DIAS — "Há +2 dias" (05/11)
--
--  Aplicado sozinho pela ponte, ao subir (ver o LEIA-ME desta pasta).
--  Pode rodar de novo sem medo.
--
--  ------------------------------------------------------------
--  O PEDIDO
--
--  Do Rodrigo, junto com o pedido do Painel novo: "Existe lá números sobre
--  'Há 3+ dias', que na verdade deve ser 'Há +2 dias'."
--
--  Desde 02/11 a tela "Esperando resposta" conta as conversas de cada pessoa
--  que esperam há 2 dias ou mais (`DIAS_DAS_ATRASADAS`, no painel). A carteira
--  do Painel de números continuava contando a partir de 3, pela função do 011
--  (com o conserto do 012): a mesma pessoa tinha um número numa tela e outro
--  na outra, e a coluna dizia "Há 3+ dias".
--
--  ------------------------------------------------------------
--  O QUE MUDA
--
--  Só a régua das atrasadas: 2 dias de calendário, no fuso do escritório, e
--  não 3. O resto é o 012, igual — a mesma lista de argumentos, as mesmas
--  chaves na resposta, os mesmos recortes (arquivada e telefone desativado
--  fora; quem não administra vê a própria carteira e a fila sem dono).
--
--  E A RESPOSTA DIZ A RÉGUA (`dias_atrasada`): o rótulo da tela sai dela, e
--  não de um número escrito no painel. Um banco que ainda não recebeu este
--  script não manda a chave, e a tela continua dizendo "Há 3+ dias" — que é
--  o que aquele banco contou. Rótulo e conta não discordam em nenhum dos dois.
--
--  Medido em 05/11, só contando: 172 conversas com responsável esperavam há
--  3 dias ou mais, e 197 há 2 ou mais; sem responsável, 349 e 350.
--
--  O 011 e o 012 não são editados: script aplicado não se edita. Este
--  substitui a função deles, e é a versão de referência dela daqui para a
--  frente (a regra 5 do LEIA-ME).
-- ============================================================

-- A MESMA LISTA DE ARGUMENTOS do 012: `create or replace` troca o corpo e
-- guarda as permissões — e ninguém vê um instante sem a função.
create or replace function public.zorvin_relatorio_responsaveis(
  p_telefone     uuid    default null,
  p_departamento bigint  default null,
  p_fuso         text    default 'America/Campo_Grande'
)
returns jsonb
language plpgsql
stable
as $fn$
declare
  v_eu    uuid := auth.uid();
  v_admin boolean := true;
  v_fuso  text := coalesce(p_fuso, 'America/Campo_Grande');
  v_hoje  date;
  -- A RÉGUA DAS ATRASADAS: a mesma da tela "Esperando resposta" (02/11).
  v_dias  constant integer := 2;
  v_saida jsonb;
begin
  -- SEM O SCRIPT 008 não há o que contar. Diz qual falta, em vez de devolver
  -- uma lista vazia — que a tela leria como "ninguém tem conversa".
  if not exists (select 1 from information_schema.columns
                  where table_schema = 'public' and table_name = 'conversas'
                    and column_name = 'responsavel_id') then
    return jsonb_build_object('falta', '008');
  end if;

  if to_regprocedure('public.zorvin_admin()') is not null then
    v_admin := public.zorvin_admin();
  end if;

  if not exists (select 1 from pg_timezone_names where name = v_fuso) then
    v_fuso := 'America/Campo_Grande';
  end if;
  v_hoje := (now() at time zone v_fuso)::date;

  with base as (
    -- As colunas que vieram de scripts posteriores entram por `to_jsonb`, e
    -- não pelo nome: num banco sem o 004 a função continua de pé, com a
    -- espera zerada, em vez de morrer com "column does not exist".
    select (to_jsonb(c) ->> 'responsavel_id')::uuid                 as resp,
           (to_jsonb(c) ->> 'esperando_desde')::timestamptz         as espera,
           coalesce((to_jsonb(c) ->> 'nao_lidas')::int, 0)          as nao_lidas
      from public.conversas c
      left join public.advogados a on a.id = c.advogado_id
     -- ARQUIVADA E TELEFONE DESATIVADO ficam fora: não são trabalho de ninguém
     -- agora, e contá-los faria a carteira parecer maior do que a fila real.
     where coalesce((to_jsonb(c) ->> 'arquivada')::boolean, false) = false
       -- `ativo` PELO NOME, e NUNCA `to_jsonb(a)`: `to_jsonb` de uma linha lê
       -- TODAS as colunas dela, e em `advogados` quem entrou não pode ler a
       -- chave da Uazapi. O pedido inteiro morria com "permission denied for
       -- table advogados" — o que o 011 fez em produção (ver o 012).
       -- Só o `false` explícito desativa (a régua da ponte).
       and a.ativo is distinct from false
       and (p_telefone is null or c.advogado_id = p_telefone)
       and (p_departamento is null or a.departamento_id = p_departamento)
  ),
  por_dono as (
    select resp,
           count(*)                                                   as conversas,
           count(*) filter (where espera is not null)                 as esperando,
           -- DIAS DE CALENDÁRIO, no fuso do escritório: a mesma conta da
           -- tela "Esperando resposta" e do rótulo "esperando há N dias" da
           -- lista. Quem escreveu anteontem às 23h entra hoje.
           count(*) filter (where espera is not null
                              and v_hoje - (espera at time zone v_fuso)::date >= v_dias) as atrasadas,
           min(espera)                                                as mais_antiga,
           sum(nao_lidas)                                             as nao_lidas
      from base
     group by resp
  ),
  visiveis as (
    -- QUEM NÃO ADMINISTRA vê a própria carteira e a fila sem dono.
    select * from por_dono
     where v_admin or resp is null or resp = v_eu
  )
  select jsonb_build_object(
    'so_meu', not v_admin,
    'agora', now(),
    -- A RÉGUA QUE ESTA RESPOSTA USOU: é dela que sai o rótulo "Há +2 dias".
    'dias_atrasada', v_dias,
    'linhas', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', v.resp,
               'nome', e.nome,
               'conversas', v.conversas,
               'esperando', v.esperando,
               'atrasadas', v.atrasadas,
               'mais_antiga', v.mais_antiga,
               'nao_lidas', v.nao_lidas)
             -- Quem tem cliente esperando há mais tempo vem primeiro: é a
             -- pergunta que esta tela existe para responder.
             order by v.atrasadas desc, v.esperando desc, v.conversas desc, e.nome)
        from visiveis v
        left join public.equipe e on e.id = v.resp
       where v.resp is not null), '[]'::jsonb),
    'sem_responsavel', (
      select jsonb_build_object(
               'conversas', v.conversas, 'esperando', v.esperando,
               'atrasadas', v.atrasadas, 'mais_antiga', v.mais_antiga,
               'nao_lidas', v.nao_lidas)
        from visiveis v where v.resp is null),
    'total', (
      select jsonb_build_object(
               'conversas', coalesce(sum(conversas), 0),
               'esperando', coalesce(sum(esperando), 0),
               'atrasadas', coalesce(sum(atrasadas), 0))
        from visiveis)
  ) into v_saida;

  return v_saida;
end
$fn$;

comment on function public.zorvin_relatorio_responsaveis(uuid, bigint, text) is
  'A carteira de cada responsável, AGORA: conversas, quantas esperam, quantas '
  'há 2 dias ou mais (a régua vai na resposta, em dias_atrasada), a espera mais '
  'antiga e as não lidas — mais a fila sem responsável. Quem não administra '
  'recebe a própria linha e a sem dono. security invoker: enxerga só as '
  'conversas de quem chama.';

-- As permissões ditas de novo: `create or replace` guarda as de uma função que
-- já existe, e a que tivesse sumido nasceria com as da herança (a régua do
-- 035). `public` inclui quem não entrou (`anon`): tira dele e devolve a quem
-- entrou, na mesma passada.
revoke all on function public.zorvin_relatorio_responsaveis(uuid, bigint, text) from public;
do $grant$
begin
  if exists (select 1 from pg_roles where rolname = 'anon') then
    execute 'revoke all on function public.zorvin_relatorio_responsaveis(uuid, bigint, text) from anon';
  end if;
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'grant execute on function public.zorvin_relatorio_responsaveis(uuid, bigint, text) to authenticated';
  end if;
  if exists (select 1 from pg_roles where rolname = 'service_role') then
    execute 'grant execute on function public.zorvin_relatorio_responsaveis(uuid, bigint, text) to service_role';
  end if;
end
$grant$;

-- ----------------------------------------------------------
--  A CONFERÊNCIA VAI DENTRO DO SCRIPT, e é a última linha dele. Tabela
--  temporária criada ANTES da guarda — a lição do 006 e do 007.
--
--  E ELA CHAMA A FUNÇÃO COMO QUEM ATENDE (`authenticated`), e não como dona
--  do banco (a regra 4 do LEIA-ME): é o que pega uma função que só quebra
--  para quem entrou. E pergunta a régua que a resposta diz.
-- ----------------------------------------------------------
do $conf$
declare
  v_resposta text;
  v_dias     text;
begin
  drop table if exists zorvin_conferencia_051;
  create temp table zorvin_conferencia_051 (item text, resposta text);

  insert into zorvin_conferencia_051
  select 'a função da carteira existe',
         (to_regprocedure('public.zorvin_relatorio_responsaveis(uuid, bigint, text)') is not null)::text;

  if not exists (select 1 from pg_roles where rolname = 'authenticated') then
    return;
  end if;

  insert into zorvin_conferencia_051
  select 'quem entrou pode usá-la',
         has_function_privilege('authenticated',
           'public.zorvin_relatorio_responsaveis(uuid, bigint, text)', 'execute')::text;
  if exists (select 1 from pg_roles where rolname = 'anon') then
    insert into zorvin_conferencia_051
    select 'quem não entrou não pode',
           (not has_function_privilege('anon',
              'public.zorvin_relatorio_responsaveis(uuid, bigint, text)', 'execute'))::text;
  end if;

  if not exists (select 1 from information_schema.columns
                  where table_schema = 'public' and table_name = 'conversas'
                    and column_name = 'responsavel_id') then
    insert into zorvin_conferencia_051 values ('sem a coluna do responsável', 'rode o script 008 antes');
    return;
  end if;

  begin
    perform set_config('role', 'authenticated', true);
    v_dias := public.zorvin_relatorio_responsaveis() ->> 'dias_atrasada';
    v_resposta := 'sim';
    execute 'reset role';
  exception when others then
    -- A troca de papel é desfeita junto com o bloco que falhou.
    v_resposta := 'NÃO — ' || sqlerrm || ' (código ' || sqlstate || ')';
  end;

  insert into zorvin_conferencia_051
  values ('a função responde para quem atende', v_resposta);
  if v_resposta = 'sim' then
    insert into zorvin_conferencia_051
    values ('a resposta diz que as atrasadas contam a partir de 2 dias', (v_dias = '2')::text);
  end if;
end
$conf$;

-- A RESPOSTA DE "DEU CERTO?", na última linha, que é a que o editor mostra.
select * from zorvin_conferencia_051;
