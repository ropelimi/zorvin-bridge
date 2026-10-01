-- ============================================================
--  O RELATÓRIO POR RESPONSÁVEL
--
--  >>> RODAR NO SUPABASE DO **ZORVIN** (o das conversas). <<<
--  Dashboard → SQL Editor → New query → cole tudo → Run.
--  Pode rodar de novo sem medo.
--
--  ------------------------------------------------------------
--  O QUE ISTO ACRESCENTA
--
--  O responsável pela conversa nasceu em 30/09 (script 008) como o primeiro
--  passo para CRM, e o motivo escrito lá era este: *"sem isso não há como
--  cobrar a fila de ninguém"*. A coluna existia; o lugar onde se LÊ a carteira
--  de cada pessoa, não. Pedido do Rodrigo em 01/10.
--
--  Por pessoa — e uma linha para "sem responsável" —, AGORA:
--
--    conversas     quantas estão com ela (arquivadas e telefones desativados
--                  ficam de fora: não são trabalho de ninguém)
--    esperando     quantas têm cliente esperando resposta (`esperando_desde`)
--    atrasadas     quantas esperam há 3 dias ou mais — a mesma régua do
--                  vermelho da lista, em dias de calendário
--    mais_antiga   desde quando espera o cliente mais esquecido dela
--    nao_lidas     a soma do selo verde
--
--  É uma FOTO DE AGORA, e não um período: "quantas conversas a Jenifer tinha
--  em setembro" não tem resposta — o banco guarda só o dono de hoje (o
--  histórico de passes ficou para depois, no script 008). Por isso a função
--  não recebe datas, e a tela diz isso.
--
--  ------------------------------------------------------------
--  A CONTA É FEITA AQUI, e não no navegador
--
--  A régua do Painel: a API devolve no máximo 1000 linhas e NÃO AVISA que
--  cortou. O escritório tem ~1.800 conversas; somar no navegador daria uma
--  carteira menor com cara de carteira inteira.
--
--  ------------------------------------------------------------
--  CADA UM VÊ O SEU — e a fila sem dono
--
--  Quem não administra recebe a PRÓPRIA linha e a de "sem responsável" — a
--  segunda porque é a fila de onde qualquer um pode puxar trabalho. As
--  carteiras dos colegas são para quem administra cobrar; o recorte é FEITO
--  AQUI (`auth.uid()`), como no relatório do "Já tratei".
--
--  E A FUNÇÃO É `security invoker`: enxerga só as conversas que quem chama já
--  enxerga pelas regras de `conversas`.
--
--  ------------------------------------------------------------
--  DEPENDE DE JÁ TER RODADO
--    008 — o responsável. Sem ele a função responde `{"falta": "008"}`, e a
--          tela diz qual script falta em vez de mostrar uma tabela vazia.
--    004 — a espera. Sem ele as colunas de espera vêm zeradas.
-- ============================================================

-- Apaga qualquer versão anterior ANTES de criar: `create or replace` com outra
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
       -- `ativo` por `to_jsonb` também: só o `false` explícito desativa (a
       -- régua da ponte), e uma base sem a coluna não pode derrubar a função.
       and (to_jsonb(a) ->> 'ativo')::boolean is distinct from false
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
-- ----------------------------------------------------------
do $conf$
begin
  drop table if exists zorvin_conferencia_011;
  create temp table zorvin_conferencia_011 (item text, resposta text);

  insert into zorvin_conferencia_011
  select 'a função do relatório existe',
         (to_regprocedure('public.zorvin_relatorio_responsaveis(uuid, bigint, text)') is not null)::text;

  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    insert into zorvin_conferencia_011
    select 'quem entrou pode usá-la',
           has_function_privilege('authenticated',
             'public.zorvin_relatorio_responsaveis(uuid, bigint, text)', 'execute')::text;
  end if;

  if not exists (select 1 from information_schema.columns
                  where table_schema = 'public' and table_name = 'conversas'
                    and column_name = 'responsavel_id') then
    insert into zorvin_conferencia_011 values ('sem a coluna do responsável', 'rode o script 008 antes');
    return;
  end if;

  execute $q$
    insert into zorvin_conferencia_011
    select 'conversas com responsável', count(*)::text
      from public.conversas where responsavel_id is not null
    union all
    select 'conversas sem responsável', count(*)::text
      from public.conversas where responsavel_id is null
  $q$;
end
$conf$;

-- A RESPOSTA DE "DEU CERTO?", na última linha, que é a que o editor mostra.
select * from zorvin_conferencia_011;
