-- ============================================================
--  O RELATÓRIO POR RESPONSÁVEL — o conserto da permissão
--
--  >>> RODAR NO SUPABASE DO **ZORVIN** (o das conversas). <<<
--  Dashboard → SQL Editor → New query → cole tudo → Run.
--  Pode rodar de novo sem medo.
--
--  ------------------------------------------------------------
--  O QUE ACONTECEU
--
--  O script 011 criou `zorvin_relatorio_responsaveis`, e na tela ela
--  respondeu, para todo mundo:
--
--      permission denied for table advogados (código 42501)
--
--  A causa é uma palavra: `to_jsonb(a)`. Ela transforma a linha INTEIRA do
--  telefone em JSON — e para isso precisa ler todas as colunas, inclusive
--  `token`, `servidor` e `instancia`, que desde
--  `sql/2026-09-a-chave-da-uazapi-fica-guardada.sql` ninguém que entra no
--  painel alcança. Não é a coluna que fica de fora: é a consulta inteira que
--  morre. A função é `security invoker` (de propósito: enxerga só o que quem
--  chama enxerga), então ela herda essa trava.
--
--  Ela passou nas provas porque o banco de teste não tinha a trava, e a
--  conferência do 011 rodava como dona do banco, que alcança tudo. Ninguém
--  CHAMOU a função no papel de quem entra no painel antes de ela chegar lá.
--
--  ------------------------------------------------------------
--  O QUE MUDA
--
--  Só uma linha da função: `ativo` passa a ser lido pelo nome, que é uma
--  coluna liberada. O resto é o 011, igual. E a conferência do fim passou a
--  CHAMAR a função no papel `authenticated` — o mesmo de quem atende —, e diz
--  se ela respondeu. Uma conferência que só pergunta "a função existe?" foi
--  exatamente o que deixou isto passar.
--
--  O 011 não é editado: script aplicado não se edita, o conserto é o próximo
--  número. Este substitui a função dele.
-- ============================================================

-- Apaga a versão do 011 (e qualquer outra) ANTES de criar: `create or replace` com outra
-- lista de argumentos cria uma SEGUNDA função de mesmo nome, e a chamada do
-- navegador morreria com "could not choose the best candidate".
do $limpa$
declare r record;
begin
  for r in select oid::regprocedure as f from pg_proc
            where proname = 'zorvin_relatorio_responsaveis'
              and pronamespace = 'public'::regnamespace
  loop execute 'drop function ' || r.f; end loop;
end
$limpa$;

-- A FUNÇÃO É CRIADA SEMPRE, mesmo num banco sem as tabelas: é `plpgsql`, e os
-- nomes de dentro só são resolvidos quando ela roda (a prova 51l-bis aplica
-- esta pasta num banco limpo).
create function public.zorvin_relatorio_responsaveis(
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
       -- TODAS as colunas dela, e em `advogados` quem entrou não pode ler
       -- `token`, `servidor` nem `instancia` (a chave da Uazapi, fechada em
       -- 09/2026). O pedido inteiro morria com "permission denied for table
       -- advogados" — foi o que o script 011 fez em produção.
       -- Só o `false` explícito desativa (a régua da ponte).
       and a.ativo is distinct from false
       and (p_telefone is null or c.advogado_id = p_telefone)
       and (p_departamento is null or a.departamento_id = p_departamento)
  ),
  por_dono as (
    select resp,
           count(*)                                                   as conversas,
           count(*) filter (where espera is not null)                 as esperando,
           -- DIAS DE CALENDÁRIO, no fuso do escritório: a mesma conta do
           -- rótulo "esperando há N dias" da lista, que fica vermelho a
           -- partir de três. Duas contas diferentes fariam a lista dizer
           -- "há 3 dias" de uma conversa que este relatório não conta.
           count(*) filter (where espera is not null
                              and v_hoje - (espera at time zone v_fuso)::date >= 3) as atrasadas,
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
  'há 3 dias ou mais, a espera mais antiga e as não lidas — mais a fila sem '
  'responsável. Quem não administra recebe a própria linha e a sem dono. '
  'security invoker: enxerga só as conversas de quem chama.';

-- `public` inclui quem não entrou (`anon`). Tira dele e devolve a quem entrou,
-- na mesma passada.
revoke all on function public.zorvin_relatorio_responsaveis(uuid, bigint, text) from public;
do $grant$
begin
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'grant execute on function public.zorvin_relatorio_responsaveis(uuid, bigint, text) to authenticated';
  end if;
end
$grant$;

-- ----------------------------------------------------------
--  A CONFERÊNCIA VAI DENTRO DO SCRIPT, e é a última linha dele: o editor do
--  Supabase só mostra o resultado do último comando. Tabela temporária criada
--  ANTES da guarda — a lição do 006 e do 007.
--
--  E ELA CHAMA A FUNÇÃO COMO QUEM ATENDE (`authenticated`), e não como dona
--  do banco: a dona alcança todas as colunas, e foi por conferir assim que o
--  011 chegou à tela quebrado. A troca de papel vale só dentro do bloco, e
--  volta atrás sozinha se a chamada falhar.
-- ----------------------------------------------------------
do $conf$
declare
  v_resposta text;
begin
  drop table if exists zorvin_conferencia_012;
  create temp table zorvin_conferencia_012 (item text, resposta text);

  insert into zorvin_conferencia_012
  select 'a função do relatório existe',
         (to_regprocedure('public.zorvin_relatorio_responsaveis(uuid, bigint, text)') is not null)::text;

  if not exists (select 1 from pg_roles where rolname = 'authenticated') then
    return;
  end if;

  insert into zorvin_conferencia_012
  select 'quem entrou pode usá-la',
         has_function_privilege('authenticated',
           'public.zorvin_relatorio_responsaveis(uuid, bigint, text)', 'execute')::text;

  if not exists (select 1 from information_schema.columns
                  where table_schema = 'public' and table_name = 'conversas'
                    and column_name = 'responsavel_id') then
    insert into zorvin_conferencia_012 values ('sem a coluna do responsável', 'rode o script 008 antes');
    return;
  end if;

  begin
    perform set_config('role', 'authenticated', true);
    perform public.zorvin_relatorio_responsaveis();
    v_resposta := 'sim';
    execute 'reset role';
  exception when others then
    -- A troca de papel é desfeita junto com o bloco que falhou.
    v_resposta := 'NÃO — ' || sqlerrm || ' (código ' || sqlstate || ')';
  end;

  insert into zorvin_conferencia_012
  values ('a função responde para quem atende', v_resposta);
end
$conf$;

-- A RESPOSTA DE "DEU CERTO?", na última linha, que é a que o editor mostra.
select * from zorvin_conferencia_012;
