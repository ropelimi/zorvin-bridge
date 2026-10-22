-- ============================================================
--  030 — O CONTROLE DE ATENDIMENTO, VISTO DO VANTORO
-- ============================================================
--
--  Pedido do escritório (21/10): uma tela no Vantoro, parecida com a de
--  Ordens de serviço, que mostre as conversas do Zorvin pela ordem de quem
--  espera há mais tempo — com quando foi e quem mandou a última mensagem, e se
--  quem mandou por último foi o contato.
--
--  O Vantoro não lê este banco, e não vai passar a ler: são dois sistemas, e
--  dar a ele a chave daqui seria dar a chave de todas as conversas a mais um
--  servidor. Quem lê é a ponte, que já tem a chave — e entrega ao Vantoro só o
--  RESUMO, por uma porta assinada (`POST /vantoro/atendimento`).
--
--  Esta função é o resumo: uma linha por conversa aberta, com a última
--  mensagem dela.
--
--  ------------------------------------------------------------
--  O QUE ENTRA
--  ------------------------------------------------------------
--    • conversa que não está FINALIZADA nem ARQUIVADA;
--    • de telefone ativo, e que não é grupo (`contatos.numero` 'grupo:…');
--    • TODA conversa com alguém esperando, qualquer que seja a idade da
--      espera — a que espera há três meses é justamente a que a tela existe
--      para mostrar, e um corte por data a esconderia;
--    • e as outras, só com movimento nos últimos `p_dias` dias. Sem isso, o
--      "em aberto" de um ano de WhatsApp viria inteiro a cada pedido.
--
--  A ESPERA É A DO ZORVIN (`conversas.esperando_desde`), e não uma conta nova:
--  a mesma que a lista do painel usa, com a carência de 30 minutos e o "Já
--  tratei". Duas réguas para a mesma pergunta fariam a tela do Vantoro e a
--  do Zorvin discordarem sobre quem está esperando.
--
--  QUEM MANDOU POR ÚLTIMO É OUTRA PERGUNTA, e vem da última mensagem de
--  verdade. As duas costumam coincidir, e quando não coincidem é informação:
--  o contato falou por último, mas alguém marcou "Já tratei" (ou ele escreveu
--  um "obrigado" dentro da carência).
--
--  ------------------------------------------------------------
--  QUEM PODE CHAMAR
--  ------------------------------------------------------------
--  SÓ A PONTE (`service_role`). A função devolve as conversas de TODOS os
--  telefones, sem a regra de quem vê o quê — essa regra é aplicada do lado do
--  Vantoro, com a mesma permissão que ele mesmo manda para cá. Liberada para
--  quem entrou no painel, ela seria um atalho por cima das permissões.
--
--  plpgsql: os nomes de dentro só são resolvidos quando ela roda, então ela é
--  criada mesmo num banco sem as tabelas (a prova 51l-bis aplica a pasta
--  inteira num banco limpo).
--
--  DEPENDE DE JÁ TER RODADO o 004 (a espera) e o 028 (a situação).
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
  p_dias   integer default 60,
  p_limite integer default 3000
) returns jsonb
language plpgsql
stable
set search_path = public
as $fn$
declare
  v_linhas jsonb;
begin
  -- As duas colunas da ordem servem só para ordenar, e saem da resposta.
  select coalesce(jsonb_agg(to_jsonb(l) - 'ordem_espera' - 'ordem_movimento'
                            order by l.ordem_espera, l.ordem_movimento), '[]'::jsonb)
    into v_linhas
    from (
      select
        c.id                                   as conversa_id,
        c.situacao                             as situacao,
        c.esperando_desde                      as esperando_desde,
        c.ultima_atividade                     as ultima_atividade,
        coalesce(c.nao_lidas, 0)               as nao_lidas,
        r.nome                                 as responsavel,
        a.numero                               as linha_numero,
        a.nome                                 as linha_nome,
        ct.numero                              as contato_numero,
        -- O NOME QUE O PAINEL MOSTRA, na mesma ordem (zorvin-painel/src/contato.js).
        coalesce(nullif(btrim(ct.vantoro_nome), ''), nullif(btrim(ct.nome_zorvin), ''),
                 nullif(btrim(ct.nome), ''))   as contato_nome,
        ct.vantoro_cliente_id::text            as vantoro_cliente_id,
        m.criado_em                            as ultima_em,
        m.origem                               as ultima_origem,
        -- QUEM, pelo nome de HOJE quando se sabe a pessoa: o rótulo gravado na
        -- mensagem é o nome do dia do envio, e quem mudou de nome continuaria
        -- aparecendo pelo antigo.
        case when m.origem = 'contato' then null
             else coalesce(nullif(btrim(u.nome), ''), nullif(btrim(m.enviado_por), '')) end
                                               as ultima_quem,
        -- MANDADA DO CELULAR (ou do WhatsApp Web), fora do Zorvin: a ponte
        -- grava 'WhatsApp' no lugar do nome, porque não há como saber quem foi.
        (m.origem = 'advogado' and m.enviado_por_id is null
           and m.enviado_por = 'WhatsApp')     as ultima_pelo_celular,
        m.tipo                                 as ultima_tipo,
        left(m.texto, 200)                     as ultima_texto,
        -- A ORDEM: quem espera primeiro, do mais antigo para o mais novo; depois
        -- os outros, do movimento mais recente para o mais antigo. Vai junto
        -- para o `limit` cortar o que menos importa, e não o que mais importa.
        coalesce(c.esperando_desde, 'infinity'::timestamptz) as ordem_espera,
        -(extract(epoch from coalesce(c.ultima_atividade, '-infinity'::timestamptz)))
                                               as ordem_movimento
      from conversas c
      join advogados a  on a.id = c.advogado_id
      join contatos  ct on ct.id = c.contato_id
      left join usuarios r on r.id = c.responsavel_id
      left join lateral (
        select mm.criado_em, mm.origem, mm.enviado_por, mm.enviado_por_id, mm.tipo, mm.texto
          from mensagens mm
         where mm.conversa_id = c.id
         order by mm.criado_em desc
         limit 1
      ) m on true
      left join usuarios u on u.id = m.enviado_por_id
      where coalesce(c.situacao, 'aberto') <> 'finalizado'
        and not coalesce(c.arquivada, false)
        and coalesce(a.ativo, true)
        and ct.numero not like 'grupo:%'
        and (c.esperando_desde is not null
             or c.ultima_atividade >= now() - make_interval(days => greatest(coalesce(p_dias, 60), 1)))
      order by ordem_espera, ordem_movimento
      limit greatest(coalesce(p_limite, 3000), 1)
    ) l;

  return jsonb_build_object('gerado_em', now(), 'conversas', v_linhas);
end
$fn$;

comment on function public.zorvin_controle_atendimento(integer, integer) is
  'O resumo das conversas abertas para a tela Controle de Atendimento do Vantoro. '
  'Só a ponte chama (service_role): devolve todos os telefones, sem a regra de quem vê.';

-- SÓ A PONTE. `public` inclui quem não entrou e quem entrou; tira de todos e
-- devolve só a ela.
revoke all on function public.zorvin_controle_atendimento(integer, integer) from public;
do $grant$
begin
  if exists (select 1 from pg_roles where rolname = 'anon') then
    execute 'revoke all on function public.zorvin_controle_atendimento(integer, integer) from anon';
  end if;
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'revoke all on function public.zorvin_controle_atendimento(integer, integer) from authenticated';
  end if;
  if exists (select 1 from pg_roles where rolname = 'service_role') then
    execute 'grant execute on function public.zorvin_controle_atendimento(integer, integer) to service_role';
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
  drop table if exists zorvin_conferencia_030;
  create temp table zorvin_conferencia_030 (item text, resposta text);

  -- "quem entrou NÃO pode" é notícia boa, e por isso a pergunta é feita ao
  -- contrário: `false` aqui seria o defeito.
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    insert into zorvin_conferencia_030
    select 'só a ponte chama a função (quem entrou no painel não)',
           (not has_function_privilege('authenticated',
              'public.zorvin_controle_atendimento(integer, integer)', 'execute'))::text;
  end if;

  if to_regclass('public.conversas') is null or to_regclass('public.mensagens') is null then
    insert into zorvin_conferencia_030 values ('sem as conversas', 'nenhuma — banco sem o Zorvin');
    return;
  end if;

  begin
    v_lista := public.zorvin_controle_atendimento(60, 3000) -> 'conversas';
    select 'conversas no resumo ' || jsonb_array_length(v_lista)
           || ' · esperando ' || (select count(*) from jsonb_array_elements(v_lista) e
                                   where e ->> 'esperando_desde' is not null)
      into v_numeros;
    insert into zorvin_conferencia_030 values ('a função responde', 'sim');
    insert into zorvin_conferencia_030 values ('o resumo de agora', v_numeros);
  exception when others then
    insert into zorvin_conferencia_030
    values ('a função responde', 'NÃO — ' || sqlerrm || ' (código ' || sqlstate || ')');
  end;
end
$conf$;

-- A RESPOSTA DE "DEU CERTO?", na última linha, que é a que o editor mostra.
select * from zorvin_conferencia_030;
