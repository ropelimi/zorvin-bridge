-- ============================================================
--  031 — O CONTROLE DE ATENDIMENTO COM DEPARTAMENTO E FINALIZADOS
-- ============================================================
--
--  Pedido do escritório (22/10), sobre a tela do Vantoro que o 030 alimenta:
--  "Preciso que a tela de Controle de atendimento seja mais parecida com os
--  filtros do Zorvin. Precisa poder filtrar por departamento, e ao invés de
--  'Esperando resposta', 'Contato falou por último' etc., ter as opções de
--  'Novos', 'Em atendimento' e 'Finalizados'."
--
--  Duas coisas faltavam no resumo do 030 para isso:
--
--    • O DEPARTAMENTO de cada conversa (o do telefone, como no painel), com a
--      chave e a ordem dele — a tela do Vantoro monta a fileira de
--      departamentos na mesma ordem da do Zorvin.
--
--    • AS FINALIZADAS. O 030 as deixava de fora, porque a tela só mostrava o
--      que estava aberto. Agora há a aba, e elas vêm — com QUANDO e POR QUEM o
--      atendimento foi finalizado (o protocolo de agora, `zorvin_atendimentos`).
--      Só as dos últimos `p_dias` dias, e no máximo `p_finalizados` (as mais
--      recentes): as finalizadas de um ano inteiro não cabem num pedido, e
--      ninguém procura a de oito meses atrás nesta tela.
--
--  AS ABERTAS SÃO CONTADAS À PARTE das finalizadas, cada uma com o seu limite.
--  Num limite só, um dia de muitas finalizações empurraria para fora justamente
--  uma conversa aberta — e é a aberta que a tela existe para não deixar escapar.
--
--  A ASSINATURA GANHA UM ARGUMENTO COM PADRÃO (`p_finalizados`, 500). A ponte
--  continua chamando com `p_dias` e `p_limite`, e o PostgREST acha esta versão
--  pelo padrão: a ponte NÃO muda com este script. A versão do 030 é apagada
--  antes — duas funções de mesmo nome fariam a chamada morrer com "could not
--  choose the best candidate".
--
--  O RESTO É O 030, igual: só a ponte chama (service_role), grupo e telefone
--  desligado ficam de fora, a espera é a do Zorvin, e quem mandou por último
--  vem da última mensagem, pelo nome de hoje.
--
--  DEPENDE DE JÁ TER RODADO o 028 (situação e protocolos).
-- ============================================================

do $limpa$
declare r record;
begin
  for r in select oid::regprocedure as f from pg_proc
            where proname = 'zorvin_controle_atendimento'
              and pronamespace = 'public'::regnamespace
  loop execute 'drop function ' || r.f; end loop;
end
$limpa$;

create function public.zorvin_controle_atendimento(
  p_dias        integer default 60,
  p_limite      integer default 3000,
  p_finalizados integer default 500
) returns jsonb
language plpgsql
stable
set search_path = public
as $fn$
declare
  v_linhas jsonb;
  v_dias   interval := make_interval(days => greatest(coalesce(p_dias, 60), 1));
begin
  with
  -- QUAIS CONVERSAS: as abertas e as finalizadas, cada grupo com o seu corte.
  -- Só os ids e a ordem; o resto é buscado uma vez só, mais abaixo.
  abertas as (
    select c.id, 0 as grupo,
           coalesce(c.esperando_desde, 'infinity'::timestamptz) as o1,
           -(extract(epoch from coalesce(c.ultima_atividade, '-infinity'::timestamptz))) as o2
      from conversas c
      join advogados a  on a.id = c.advogado_id
      join contatos  ct on ct.id = c.contato_id
     where coalesce(c.situacao, 'aberto') <> 'finalizado'
       and not coalesce(c.arquivada, false)
       and coalesce(a.ativo, true)
       and ct.numero not like 'grupo:%'
       -- TODA conversa esperando entra, por velha que seja a espera: é ela que
       -- a tela existe para mostrar. As outras, só com movimento recente.
       and (c.esperando_desde is not null or c.ultima_atividade >= now() - v_dias)
     order by 3, 4
     limit greatest(coalesce(p_limite, 3000), 1)
  ),
  finalizadas as (
    select c.id, 1 as grupo,
           'infinity'::timestamptz as o1,
           -(extract(epoch from coalesce(c.ultima_atividade, '-infinity'::timestamptz))) as o2
      from conversas c
      join advogados a  on a.id = c.advogado_id
      join contatos  ct on ct.id = c.contato_id
     where c.situacao = 'finalizado'
       and not coalesce(c.arquivada, false)
       and coalesce(a.ativo, true)
       and ct.numero not like 'grupo:%'
       and c.ultima_atividade >= now() - v_dias
     order by 4
     limit greatest(coalesce(p_finalizados, 500), 0)
  ),
  escolhidas as (
    select * from abertas
    union all
    select * from finalizadas
  )
  select coalesce(jsonb_agg(to_jsonb(l) - 'grupo' - 'o1' - 'o2'
                            order by l.grupo, l.o1, l.o2), '[]'::jsonb)
    into v_linhas
    from (
      select
        e.grupo, e.o1, e.o2,
        c.id                                   as conversa_id,
        c.situacao                             as situacao,
        c.esperando_desde                      as esperando_desde,
        c.ultima_atividade                     as ultima_atividade,
        coalesce(c.nao_lidas, 0)               as nao_lidas,
        r.nome                                 as responsavel,
        a.numero                               as linha_numero,
        a.nome                                 as linha_nome,
        -- O DEPARTAMENTO É O DO TELEFONE, como no painel.
        d.nome                                 as departamento,
        d.slug                                 as departamento_slug,
        d.ordem                                as departamento_ordem,
        ct.numero                              as contato_numero,
        coalesce(nullif(btrim(ct.vantoro_nome), ''), nullif(btrim(ct.nome_zorvin), ''),
                 nullif(btrim(ct.nome), ''))   as contato_nome,
        ct.vantoro_cliente_id::text            as vantoro_cliente_id,
        m.criado_em                            as ultima_em,
        m.origem                               as ultima_origem,
        case when m.origem = 'contato' then null
             else coalesce(nullif(btrim(u.nome), ''), nullif(btrim(m.enviado_por), '')) end
                                               as ultima_quem,
        (m.origem = 'advogado' and m.enviado_por_id is null
           and m.enviado_por = 'WhatsApp')     as ultima_pelo_celular,
        m.tipo                                 as ultima_tipo,
        left(m.texto, 200)                     as ultima_texto,
        -- QUANDO E POR QUEM FOI FINALIZADO: o protocolo de agora. Só preenche
        -- na conversa finalizada — na aberta, o protocolo ainda não fechou.
        case when c.situacao = 'finalizado' then za.finalizado_em end
                                               as finalizado_em,
        case when c.situacao = 'finalizado' then nullif(btrim(fu.nome), '') end
                                               as finalizado_por
      from escolhidas e
      join conversas c  on c.id = e.id
      join advogados a  on a.id = c.advogado_id
      join contatos  ct on ct.id = c.contato_id
      left join departamentos d on d.id = a.departamento_id
      left join usuarios r on r.id = c.responsavel_id
      left join zorvin_atendimentos za on za.protocolo = c.protocolo
      left join usuarios fu on fu.id = za.finalizado_por
      left join lateral (
        select mm.criado_em, mm.origem, mm.enviado_por, mm.enviado_por_id, mm.tipo, mm.texto
          from mensagens mm
         where mm.conversa_id = c.id
         order by mm.criado_em desc
         limit 1
      ) m on true
      left join usuarios u on u.id = m.enviado_por_id
    ) l;

  return jsonb_build_object('gerado_em', now(), 'conversas', v_linhas);
end
$fn$;

comment on function public.zorvin_controle_atendimento(integer, integer, integer) is
  'O resumo das conversas (abertas e finalizadas recentes) para a tela Controle de '
  'Atendimento do Vantoro, com o departamento de cada uma. Só a ponte chama '
  '(service_role): devolve todos os telefones, sem a regra de quem vê.';

-- SÓ A PONTE, como no 030.
revoke all on function public.zorvin_controle_atendimento(integer, integer, integer) from public;
do $grant$
begin
  if exists (select 1 from pg_roles where rolname = 'anon') then
    execute 'revoke all on function public.zorvin_controle_atendimento(integer, integer, integer) from anon';
  end if;
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'revoke all on function public.zorvin_controle_atendimento(integer, integer, integer) from authenticated';
  end if;
  if exists (select 1 from pg_roles where rolname = 'service_role') then
    execute 'grant execute on function public.zorvin_controle_atendimento(integer, integer, integer) to service_role';
  end if;
end
$grant$;

-- ------------------------------------------------------------
--  A CONFERÊNCIA
-- ------------------------------------------------------------
do $conf$
declare
  v_lista   jsonb;
  v_numeros text;
begin
  drop table if exists zorvin_conferencia_031;
  create temp table zorvin_conferencia_031 (item text, resposta text);

  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    insert into zorvin_conferencia_031
    select 'só a ponte chama a função (quem entrou no painel não)',
           (not has_function_privilege('authenticated',
              'public.zorvin_controle_atendimento(integer, integer, integer)', 'execute'))::text;
  end if;

  insert into zorvin_conferencia_031
  select 'uma versão só da função',
         ((select count(*) from pg_proc where proname = 'zorvin_controle_atendimento'
                                          and pronamespace = 'public'::regnamespace) = 1)::text;

  if to_regclass('public.conversas') is null or to_regclass('public.mensagens') is null then
    insert into zorvin_conferencia_031 values ('sem as conversas', 'nenhuma — banco sem o Zorvin');
    return;
  end if;
  if to_regclass('public.zorvin_atendimentos') is null then
    insert into zorvin_conferencia_031 values ('sem os protocolos', 'rode o script 028 antes');
    return;
  end if;

  begin
    -- COMO A PONTE CHAMA: só com os dois primeiros. É o que prova que ela não
    -- precisa mudar com este script.
    v_lista := public.zorvin_controle_atendimento(p_dias => 60, p_limite => 3000) -> 'conversas';
    select 'novos ' || count(*) filter (where e ->> 'situacao' = 'aguardando')
           || ' · em atendimento ' || count(*) filter (where coalesce(e ->> 'situacao', 'aberto') = 'aberto')
           || ' · finalizados ' || count(*) filter (where e ->> 'situacao' = 'finalizado')
      into v_numeros
      from jsonb_array_elements(v_lista) e;
    insert into zorvin_conferencia_031 values ('a função responde', 'sim');
    insert into zorvin_conferencia_031 values ('o resumo de agora', v_numeros);
  exception when others then
    insert into zorvin_conferencia_031
    values ('a função responde', 'NÃO — ' || sqlerrm || ' (código ' || sqlstate || ')');
  end;
end
$conf$;

select * from zorvin_conferencia_031;
