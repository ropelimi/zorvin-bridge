-- ============================================================
--  O RELATÓRIO DO FUNIL
--
--  >>> RODAR NO SUPABASE DO **ZORVIN** (o das conversas). <<<
--  Dashboard → SQL Editor → New query → cole tudo → Run.
--  Pode rodar de novo sem medo.
--
--  ------------------------------------------------------------
--  O QUE ISTO ACRESCENTA
--
--  Pedido do Rodrigo em 07/10, logo depois do funil (script 017): "quantos
--  clientes há em cada etapa, e quanto tempo eles ficam em cada uma". A tela
--  é uma seção do Painel de números, embaixo da mesma barra de filtros.
--
--  UMA FUNÇÃO: zorvin_relatorio_funil(p_desde, p_ate, p_departamento,
--  p_telefone). Para cada departamento que quem chama alcança, e para cada
--  etapa dele:
--
--    AGORA (não depende do período)
--      agora              quantos cartões estão nela hoje
--      agora_mediana_s    há quanto tempo, na mediana, eles estão nela
--      mais_antigo        desde quando está lá o cartão mais parado
--
--    NO PERÍODO
--      entraram           quantas vezes um cartão CHEGOU nela
--      sairam             quantas vezes um cartão SAIU dela (para outra etapa,
--                         ou para fora do funil)
--      tempo_mediana_s    quanto tempo ficaram nela os que SAÍRAM no período
--      tempo_media_s      (a média, ao lado: uma conversa esquecida por um mês
--                         puxa a média e não mexe na mediana — as duas juntas
--                         dizem se o número é o normal ou um caso só)
--
--  ------------------------------------------------------------
--  O TEMPO NUMA ETAPA SAI DOS MOVIMENTOS, e não do cartão. O cartão só sabe
--  onde está agora (`movido_em`); quanto tempo ele passou em "Em atendimento"
--  antes de ir para "Proposta enviada" só existe no histórico: a saída é o
--  movimento com `de_etapa` = a etapa, e a chegada é o último movimento com
--  `para_etapa` = a etapa ANTES dela, do mesmo cliente no mesmo funil.
--
--  SÓ CONTA O TEMPO DE QUEM SAIU. Quem ainda está na etapa não terminou de
--  passar por ela — somar o "até agora" dele puxaria o número para baixo
--  justamente nas etapas em que os cartões empacam. Esse tempo aparece à
--  parte, em `agora_mediana_s`.
--
--  ------------------------------------------------------------
--  QUEM VÊ O QUÊ
--
--  `security invoker`, como o 010 e o 011: as regras de acesso de
--  `zorvin_cartoes`, `zorvin_movimentos` e `conversas` valem lá dentro, no
--  papel de quem chama. Ninguém conta pelo relatório os clientes de um
--  telefone que não atende.
--
--  E SÓ APARECEM OS DEPARTAMENTOS EM QUE A PESSOA VÊ ALGUMA CONVERSA. O funil
--  de um departamento que ela não atende viria todo zerado, e zerado se lê
--  como "ninguém" — a armadilha nº 2 do painel.
--
--  O FILTRO DE TELEFONE vira "os clientes que conversam por este telefone",
--  no funil do departamento dele. O funil é por departamento e o cartão é o
--  cliente; o telefone recorta quais clientes contam.
--
--  ------------------------------------------------------------
--  SEM O SCRIPT 017 a função responde {"falta": "017"}, e não uma lista
--  vazia — que a tela leria como "o funil está vazio".
--
--  DE `advogados` só se leem `id` e `departamento_id`, pelo nome. Nada de
--  `to_jsonb(a)`, que morre na chave da Uazapi — a lição do 012.
-- ============================================================

-- Apaga qualquer versão antes de criar: `create or replace` com outra lista
-- de argumentos cria uma SEGUNDA função de mesmo nome, e a chamada do
-- navegador morreria com "could not choose the best candidate" (o 010).
do $limpa$
declare r record;
begin
  for r in select oid::regprocedure as f from pg_proc
            where proname = 'zorvin_relatorio_funil'
              and pronamespace = 'public'::regnamespace
  loop execute 'drop function ' || r.f; end loop;
end
$limpa$;

-- A FUNÇÃO É CRIADA SEMPRE, mesmo num banco limpo: é `plpgsql`, e os nomes de
-- dentro só são resolvidos quando ela roda (a prova 51l-bis aplica esta pasta
-- num banco limpo).
create function public.zorvin_relatorio_funil(
  p_desde        timestamptz default null,
  p_ate          timestamptz default null,
  p_departamento bigint      default null,
  p_telefone     uuid        default null
)
returns jsonb
language plpgsql
stable
security invoker
set search_path = public
as $fn$
declare
  v_desde timestamptz := coalesce(p_desde, now() - interval '30 days');
  v_ate   timestamptz := coalesce(p_ate, now());
  v_dep_do_telefone bigint;
  v_saida jsonb;
begin
  if to_regclass('public.zorvin_cartoes') is null
     or to_regclass('public.zorvin_movimentos') is null
     or to_regclass('public.zorvin_etapas') is null then
    return jsonb_build_object('falta', '017');
  end if;

  if p_telefone is not null then
    select a.departamento_id into v_dep_do_telefone from public.advogados a where a.id = p_telefone;
  end if;

  with
  deps as (
    -- Os departamentos com funil em que quem chama vê alguma conversa. A
    -- consulta a `conversas` passa pela regra de acesso de quem chama.
    select d.id, d.nome, d.ordem
      from public.departamentos d
     where exists (select 1 from public.zorvin_etapas e where e.departamento_id = d.id)
       and (p_departamento is null or d.id = p_departamento)
       and (p_telefone is null or d.id = v_dep_do_telefone)
       and exists (select 1 from public.conversas c
                     join public.advogados a on a.id = c.advogado_id
                    where a.departamento_id = d.id)
  ),
  cartoes as (
    select k.etapa_id, k.departamento_id, k.movido_em
      from public.zorvin_cartoes k
     where k.departamento_id in (select id from deps)
       and (p_telefone is null or exists (
             select 1 from public.conversas c
              where c.contato_id = k.contato_id and c.advogado_id = p_telefone))
  ),
  movs as (
    select m.*
      from public.zorvin_movimentos m
     where m.departamento_id in (select id from deps)
       and m.quando >= v_desde and m.quando < v_ate
       and (p_telefone is null or exists (
             select 1 from public.conversas c
              where c.contato_id = m.contato_id and c.advogado_id = p_telefone))
  ),
  passagens as (
    -- Cada SAÍDA de uma etapa no período, com o tempo que o cartão ficou
    -- nela: da última chegada a ela até esta saída.
    select s.departamento_id, s.de_etapa as etapa_id,
           extract(epoch from s.quando - (
             select max(c.quando) from public.zorvin_movimentos c
              where c.contato_id = s.contato_id
                and c.departamento_id = s.departamento_id
                and c.para_etapa = s.de_etapa
                and c.quando <= s.quando)) as segundos
      from movs s
     where s.de_etapa is not null
  ),
  por_etapa as (
    select e.id, e.departamento_id, e.nome, e.cor, e.ordem, e.ativo,
           (select count(*) from cartoes k where k.etapa_id = e.id)                         as agora,
           (select percentile_cont(0.5) within group (order by extract(epoch from now() - k.movido_em))
              from cartoes k where k.etapa_id = e.id)                                       as agora_mediana_s,
           (select min(k.movido_em) from cartoes k where k.etapa_id = e.id)                 as mais_antigo,
           (select count(*) from movs m where m.para_etapa = e.id)                          as entraram,
           (select count(*) from movs m where m.de_etapa = e.id)                            as sairam,
           (select percentile_cont(0.5) within group (order by p.segundos)
              from passagens p where p.etapa_id = e.id and p.segundos is not null)          as tempo_mediana_s,
           (select avg(p.segundos)
              from passagens p where p.etapa_id = e.id and p.segundos is not null)          as tempo_media_s,
           (select count(*) from passagens p where p.etapa_id = e.id and p.segundos is not null) as tempo_quantos
      from public.zorvin_etapas e
     where e.departamento_id in (select id from deps)
  )
  select jsonb_build_object(
    'desde', v_desde,
    'ate', v_ate,
    'agora', now(),
    'departamentos', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', d.id,
               'nome', d.nome,
               'agora', (select count(*) from cartoes k where k.departamento_id = d.id),
               'entraram_no_funil', (select count(*) from movs m
                                      where m.departamento_id = d.id and m.de_etapa is null),
               'sairam_do_funil', (select count(*) from movs m
                                    where m.departamento_id = d.id and m.para_etapa is null),
               'movimentos', (select count(*) from movs m where m.departamento_id = d.id),
               'etapas', coalesce((
                 select jsonb_agg(jsonb_build_object(
                          'id', p.id, 'nome', p.nome, 'cor', p.cor, 'ordem', p.ordem,
                          'ativo', p.ativo, 'agora', p.agora,
                          'agora_mediana_s', round(p.agora_mediana_s::numeric),
                          'mais_antigo', p.mais_antigo,
                          'entraram', p.entraram, 'sairam', p.sairam,
                          'tempo_mediana_s', round(p.tempo_mediana_s::numeric),
                          'tempo_media_s', round(p.tempo_media_s::numeric),
                          'tempo_quantos', p.tempo_quantos)
                        order by p.ordem, p.nome)
                   from por_etapa p
                  where p.departamento_id = d.id
                    -- A ETAPA DESATIVADA SÓ APARECE SE AINDA PESA: com cartão
                    -- dentro, ou com movimento no período. Escondê-la nesse
                    -- caso sumiria com clientes do relatório; mostrá-la
                    -- sempre encheria a tabela de linhas zeradas.
                    and (p.ativo or p.agora > 0 or p.entraram > 0 or p.sairam > 0)), '[]'::jsonb))
             order by d.ordem, d.nome)
        from deps d), '[]'::jsonb)
  ) into v_saida;

  return v_saida;
end
$fn$;

comment on function public.zorvin_relatorio_funil(timestamptz, timestamptz, bigint, uuid) is
  'O relatório do funil: por departamento e por etapa, quantos cartões estão '
  'nela agora e há quanto tempo, e no período quantos entraram, quantos '
  'saíram e quanto tempo ficaram. security invoker: conta só o que quem chama '
  'enxerga.';

-- `public` inclui quem não entrou (`anon`). Tira dele e devolve a quem entrou,
-- na mesma passada.
revoke all on function public.zorvin_relatorio_funil(timestamptz, timestamptz, bigint, uuid) from public;
do $grant$
begin
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'grant execute on function public.zorvin_relatorio_funil(timestamptz, timestamptz, bigint, uuid) to authenticated';
  end if;
end
$grant$;

-- O índice que a conta do tempo pede: "a última chegada a esta etapa, deste
-- cliente, antes desta saída". Sem ele, cada saída varre o histórico do
-- cliente inteiro.
do $indice$
begin
  if to_regclass('public.zorvin_movimentos') is not null then
    execute 'create index if not exists zorvin_movimentos_chegada
               on public.zorvin_movimentos (contato_id, departamento_id, para_etapa, quando desc)';
    execute 'create index if not exists zorvin_movimentos_periodo
               on public.zorvin_movimentos (departamento_id, quando)';
  end if;
end
$indice$;

-- ----------------------------------------------------------
--  A CONFERÊNCIA VAI DENTRO DO SCRIPT, e é a última linha dele: o editor do
--  Supabase só mostra o resultado do último comando. A tabela temporária
--  nasce ANTES de qualquer guarda — a lição do 006 e do 007.
--
--  E ELA CHAMA A FUNÇÃO COMO QUEM ATENDE (`authenticated`), e não como dona
--  do banco — a régua do 012. A troca de papel volta atrás sozinha se falhar.
-- ----------------------------------------------------------
do $conf$
declare
  v_resposta text;
begin
  drop table if exists zorvin_conferencia_019;
  create temp table zorvin_conferencia_019 (item text, resposta text);

  insert into zorvin_conferencia_019
  select 'a função do relatório existe',
         (to_regprocedure('public.zorvin_relatorio_funil(timestamptz, timestamptz, bigint, uuid)') is not null)::text;

  if not exists (select 1 from pg_roles where rolname = 'authenticated') then
    return;
  end if;

  if to_regclass('public.zorvin_cartoes') is null then
    insert into zorvin_conferencia_019 values ('sem o funil', 'rode o script 017 antes');
    return;
  end if;

  begin
    perform set_config('role', 'authenticated', true);
    perform public.zorvin_relatorio_funil();
    -- E COM UM TELEFONE: é o caminho que lê `advogados`, e uma leitura de
    -- coluna fechada ali só morreria com o filtro ligado.
    perform public.zorvin_relatorio_funil(null, null, null,
              (select a.id from public.advogados a limit 1));
    v_resposta := 'sim';
    execute 'reset role';
  exception when others then
    v_resposta := 'NÃO — ' || sqlerrm || ' (código ' || sqlstate || ')';
  end;

  insert into zorvin_conferencia_019
  values ('a função responde para quem atende', v_resposta);
end
$conf$;

-- A RESPOSTA DE "DEU CERTO?", na última linha, que é a que o editor mostra.
select * from zorvin_conferencia_019;
