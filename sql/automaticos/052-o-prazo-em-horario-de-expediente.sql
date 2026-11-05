-- ============================================================
--  O PRAZO EM HORÁRIO DE EXPEDIENTE — a conta justa do Painel (05/11)
--
--  Aplicado sozinho pela ponte, ao subir (ver o LEIA-ME desta pasta).
--  Pode rodar de novo sem medo.
--
--  ------------------------------------------------------------
--  O PEDIDO
--
--  Do Rodrigo: "A tela 'Painel' preciso de um dashboard de verdade [...]
--  Tem que fazer sentido também as informações que me ajudem a melhorar o
--  atendimento, organizar a equipe e dar feedbacks e fazer cobranças de forma
--  correta."
--
--  ------------------------------------------------------------
--  O QUE ESTAVA TORTO NA CONTA DO TEMPO
--
--  O 029 mede o tempo até a primeira resposta no RELÓGIO: o cliente que
--  escreve na sexta às 19h e é respondido na segunda às 8h05 entra com 61
--  horas. Medido em 05/11, só contando, nos protocolos que o cliente abriu
--  nos últimos 30 dias: a mediana no relógio era de 2 h 59 min, e boa parte
--  dela é noite e fim de semana. Cobrar alguém por isso não é cobrar de forma
--  correta: quem chega às 8h e responde a fila da noite parece a mais lenta.
--
--  ------------------------------------------------------------
--  O QUE ESTE SCRIPT FAZ
--
--  1. `zorvin_prazo_dos_protocolos(ids, agora)`: para cada protocolo que o
--     CLIENTE abriu, quantos minutos de EXPEDIENTE se passaram até a primeira
--     ação da equipe (responder ou finalizar) e até a primeira resposta, e o
--     prazo do departamento. O expediente é o da aba "Fora do horário" (021,
--     com os feriados), e o prazo é o da aba "Aviso de espera" (041: 30
--     minutos se ninguém mudou). É A MESMA RÉGUA do aviso de cliente sem
--     resposta: o aviso toca quando um cliente passa do prazo, e o Painel
--     conta quantos foram atendidos antes disso.
--
--     A conta é a de `zorvin_minutos_no_expediente` (041), feita de uma vez
--     para todos os protocolos, e não um por um. Medido em produção: um por
--     um, 724 protocolos levavam 530 ms, e um ano inteiro passaria dos 8
--     segundos que a API dá a uma consulta. Duas escritas da mesma conta
--     divergiriam no primeiro conserto — por isso a CONFERÊNCIA do fim compara
--     as duas, protocolo por protocolo, nos dados de verdade.
--
--  2. Uma versão nova de `zorvin_relatorio_atendimentos` (a do 029), com a
--     MESMA lista de argumentos e as MESMAS chaves de antes, mais:
--       - `prazo`: no prazo, atrasados (responderam depois do prazo), sem
--         ação fora do prazo, e aguardando (ainda dentro dele);
--       - `antes.prazo`: o mesmo, no período anterior do mesmo tamanho;
--       - `tempos.primeira_resposta.mediana_expediente` (e a média);
--       - `por_departamento`: os mesmos números, departamento a departamento;
--       - `por_pessoa[].primeira_mediana_expediente`;
--       - `por_dia[].finalizados`, `no_prazo` e `prazo_julgados`;
--       - em cada registro, o `prazo` e os `minutos_ate_acao`.
--
--  ------------------------------------------------------------
--  O PRAZO É DA EQUIPE, E NÃO DE UMA PESSOA — e é decisão
--
--  "No prazo" diz se o cliente foi atendido antes de o prazo vencer. Quando
--  ninguém agiu a tempo, quem finalmente responde não foi quem atrasou: quem
--  pega a conversa esquecida (a faxina, a volta das férias) levaria a culpa
--  de um atraso que é da equipe. Então o prazo é contado para a equipe, para
--  o departamento e por dia — e com uma pessoa escolhida, ou para quem não
--  administra, ele vem nulo (a tela mostra o da pessoa pelo tempo dela, e a
--  carteira atrasada, que é dela).
--
--  O que se compara com o período anterior também é decisão, e vem do 029:
--  o TOTAL e o PRAZO. O prazo compara bem porque julga os dois períodos do
--  mesmo jeito — o protocolo sem ação que já passou do prazo conta como fora
--  dele, nos dois. A mediana e os finalizados não: o período velho teve mais
--  tempo para responder e finalizar os seus.
--
--  ------------------------------------------------------------
--  O que é "primeira ação": a primeira resposta OU o "Finalizar" (o "Já
--  tratei"), o que vier antes. O "obrigado!" do cliente finalizado em 5
--  minutos foi atendido a tempo, e não precisava de resposta.
--
--  `security invoker`, como o 029: cada um vê só as conversas que vê.
--
--  ------------------------------------------------------------
--  DEPENDE DE JÁ TER RODADO
--    o 021 (o expediente e os feriados), o 028 (os protocolos) e o 041 (o
--    prazo de cada departamento). Sem eles, este script não mexe em nada, a
--    função do 029 continua como estava, e a conferência diz qual falta.
-- ============================================================

do $prazo$
begin
  -- A TABELA DA CONFERÊNCIA nasce ANTES de qualquer guarda (a lição do 006 e
  -- do 007): a última linha do script a lê, e ela tem de existir sempre.
  drop table if exists zorvin_conferencia_052;
  create temp table zorvin_conferencia_052 (item text, resposta text);

  if to_regclass('public.conversas') is null or to_regclass('public.advogados') is null
     or to_regclass('public.departamentos') is null then
    insert into zorvin_conferencia_052 values ('sem as tabelas do Zorvin', 'nada a fazer aqui');
    return;
  end if;
  if to_regclass('public.zorvin_atendimentos') is null then
    insert into zorvin_conferencia_052 values ('os protocolos (028)', 'rode o script 028 antes');
    return;
  end if;
  if to_regclass('public.zorvin_fora_do_horario') is null or to_regclass('public.zorvin_feriados') is null then
    insert into zorvin_conferencia_052 values ('o expediente dos departamentos (021)', 'rode o script 021 antes');
    return;
  end if;
  if to_regclass('public.zorvin_aviso_de_espera') is null
     or to_regprocedure('public.zorvin_minutos_no_expediente(jsonb,text,timestamptz,timestamptz)') is null then
    insert into zorvin_conferencia_052 values ('o prazo de cada departamento (041)', 'rode o script 041 antes');
    return;
  end if;

  -- ----------------------------------------------------------
  --  1. A CONTA DO PRAZO
  --
  --  `language sql`: o corpo é conferido ao criar, e por isso ela mora aqui,
  --  depois da guarda — num banco sem o 021 ela não teria o que ler.
  -- ----------------------------------------------------------
  execute $sql$
    create or replace function public.zorvin_prazo_dos_protocolos(
      p_ids   uuid[],
      p_agora timestamptz default now()
    )
    returns table (
      id              uuid,
      departamento_id bigint,
      limite          integer,
      acao_em         timestamptz,
      min_acao        integer,
      min_resposta    integer
    )
    language sql
    stable
    security invoker
    set search_path = public
    as $f$
      with alvos as materialized (
        -- SÓ O QUE O CLIENTE ABRIU: na conversa começada por nós e no Reabrir
        -- não houve cliente esperando.
        select z.id, a.departamento_id,
               coalesce(v.minutos, 30) as limite,
               z.aberto_em,
               least(z.primeira_resposta_em, z.finalizado_em) as acao_em,
               -- SEM AÇÃO, CONTA ATÉ AGORA: é assim que se sabe se o prazo já
               -- venceu para quem ainda espera.
               coalesce(least(z.primeira_resposta_em, z.finalizado_em), p_agora) as fim_acao,
               z.primeira_resposta_em as fim_resposta,
               -- A SEMANA E O FUSO DO DEPARTAMENTO (021). Sem a semana, conta
               -- o relógio inteiro — a régua de `zorvin_minutos_no_expediente`.
               case when jsonb_typeof(f.semana) = 'object' then f.semana end as semana,
               coalesce(nullif(btrim(f.fuso), ''), 'America/Sao_Paulo') as fuso
          from public.zorvin_atendimentos z
          join public.conversas c on c.id = z.conversa_id
          left join public.advogados a on a.id = c.advogado_id
          left join public.zorvin_aviso_de_espera v on v.departamento_id = a.departamento_id
          left join public.zorvin_fora_do_horario f on f.departamento_id = a.departamento_id
         where z.id = any (p_ids)
           and z.origem = 'cliente'
      ),
      pontas as materialized (
        -- O DIA DE CADA PONTA, no fuso do departamento. E o primeiro dia que
        -- conta: no máximo 62 dias antes do fim, a régua do 041.
        select x.id, x.aberto_em, x.fim_acao, x.fim_resposta, x.semana, x.fuso,
               (x.aberto_em at time zone x.fuso)::date as dia_aberto,
               greatest((x.aberto_em at time zone x.fuso)::date,
                        (x.fim_acao at time zone x.fuso)::date - 62) as ini_acao,
               case when x.fim_resposta is not null
                    then greatest((x.aberto_em at time zone x.fuso)::date,
                                  (x.fim_resposta at time zone x.fuso)::date - 62) end as ini_resposta,
               greatest((x.fim_acao at time zone x.fuso)::date,
                        coalesce((x.fim_resposta at time zone x.fuso)::date,
                                 (x.fim_acao at time zone x.fuso)::date)) as dia_fim
          from alvos x
         where x.semana is not null
      ),
      dias as (
        -- CADA DIA DE CADA PROTOCOLO, com a faixa da semana daquele dia.
        select p.id, d::date as dia, p.semana, p.fuso,
               p.semana -> (array['seg','ter','qua','qui','sex','sab','dom'])[extract(isodow from d)::int] as faixa
          from pontas p
          cross join lateral generate_series(p.ini_acao::timestamp, p.dia_fim::timestamp, interval '1 day') d
      ),
      janelas as (
        -- QUANDO O DEPARTAMENTO ABRE E FECHA NAQUELE DIA. A hora só é lida
        -- depois de a forma ser conferida (o `case` garante a ordem): uma
        -- semana com lixo não pode derrubar o Painel. Feriado não abre.
        select j.id, j.dia,
               case when j.ok then ((j.dia + (j.faixa ->> 0)::time) at time zone j.fuso) end as abre,
               case when j.ok then ((j.dia + (j.faixa ->> 1)::time) at time zone j.fuso) end as fecha
          from (select d.*,
                       -- `case`, e não `and`: o banco não promete a ordem de um `and`,
                       -- e o tamanho de algo que não é lista estoura.
                       case when jsonb_typeof(d.faixa) is distinct from 'array' then false
                            when jsonb_array_length(d.faixa) <> 2 then false
                            else coalesce((d.faixa ->> 0) ~ '^(([01]?[0-9]|2[0-3]):[0-5][0-9](:[0-5][0-9])?|24:00(:00)?)$'
                                          and (d.faixa ->> 1) ~ '^(([01]?[0-9]|2[0-3]):[0-5][0-9](:[0-5][0-9])?|24:00(:00)?)$',
                                          false)
                                 and not exists (select 1 from public.zorvin_feriados h where h.dia = d.dia)
                            end as ok
                  from dias d) j
      ),
      somas as (
        select j.id,
               sum(case when j.dia >= p.ini_acao
                        then greatest(0, extract(epoch from least(p.fim_acao, j.fecha) - greatest(p.aberto_em, j.abre)))
                        else 0 end) as s_acao,
               sum(case when p.fim_resposta is not null and j.dia >= p.ini_resposta
                        then greatest(0, extract(epoch from least(p.fim_resposta, j.fecha) - greatest(p.aberto_em, j.abre)))
                        else 0 end) as s_resposta
          from janelas j
          join pontas p on p.id = j.id
         where j.abre is not null and j.abre < j.fecha
         group by j.id
      )
      select x.id, x.departamento_id, x.limite, x.acao_em,
             (case when x.semana is null
                   then floor(greatest(0, extract(epoch from x.fim_acao - x.aberto_em)) / 60)
                   else floor(coalesce(s.s_acao, 0) / 60) end)::integer,
             (case when x.fim_resposta is null then null
                   when x.semana is null
                   then floor(greatest(0, extract(epoch from x.fim_resposta - x.aberto_em)) / 60)
                   else floor(coalesce(s.s_resposta, 0) / 60) end)::integer
        from alvos x
        left join somas s on s.id = x.id
    $f$
  $sql$;

  execute $sql$
    comment on function public.zorvin_prazo_dos_protocolos(uuid[], timestamptz) is
      'Para cada protocolo que o cliente abriu: os minutos de expediente (021) até a primeira '
      'ação da equipe (responder ou finalizar; sem ação, até agora) e até a primeira resposta, '
      'e o prazo do departamento (041). A conta de zorvin_minutos_no_expediente, feita de uma '
      'vez para todos. security invoker.'
  $sql$;

  -- ----------------------------------------------------------
  --  2. A CONTABILIZAÇÃO, COM O PRAZO
  --
  --  A versão do 029, com a mesma lista de argumentos: `create or replace`
  --  troca o corpo e guarda as permissões. Ela é a versão de referência
  --  daqui para a frente (a regra 5 do LEIA-ME).
  -- ----------------------------------------------------------
  execute $sql$
    create or replace function public.zorvin_relatorio_atendimentos(
      p_desde        timestamptz default null,
      p_ate          timestamptz default null,
      p_quem         uuid        default null,
      p_fuso         text        default 'America/Campo_Grande',
      p_telefone     uuid        default null,
      p_departamento bigint      default null,
      -- QUANTOS PROTOCOLOS, no máximo, vêm na lista de baixo. As contas de
      -- cima são sempre do período inteiro; só a lista é aparada — e ela diz
      -- de quantos.
      p_limite       integer     default 500
    )
    returns jsonb
    language plpgsql
    stable
    security invoker
    set search_path = public
    as $fn$
    declare
      v_ate    timestamptz := coalesce(p_ate, now());
      v_desde  timestamptz := coalesce(p_desde, '-infinity'::timestamptz);
      v_agora  timestamptz := now();
      v_antes  timestamptz;
      v_tmp    timestamptz;
      v_quem   uuid := p_quem;
      v_so_meu boolean := p_quem is not null;
      v_fuso   text := coalesce(p_fuso, 'America/Campo_Grande');
      v_lim    integer := least(greatest(coalesce(p_limite, 500), 1), 2000);
      v_saida  jsonb;
    begin
      if to_regclass('public.zorvin_atendimentos') is null then
        return jsonb_build_object('falta', '028');
      end if;

      -- QUEM NÃO ADMINISTRA NÃO ESCOLHE. Aqui, e não no navegador. E sem
      -- sessão (`auth.uid()` nulo) o recorte continua ligado: nulo não é
      -- "todo mundo".
      if to_regprocedure('public.zorvin_admin()') is not null then
        if not public.zorvin_admin() then
          v_quem := auth.uid();
          v_so_meu := true;
        end if;
      end if;

      -- Fuso inválido derrubaria a tela com "time zone not recognized".
      if not exists (select 1 from pg_timezone_names where name = v_fuso) then
        v_fuso := 'America/Campo_Grande';
      end if;

      if v_desde > v_ate then
        v_tmp := v_desde; v_desde := v_ate; v_ate := v_tmp;
      end if;
      -- O PERÍODO ANTERIOR, do mesmo tamanho e encostado neste. Sem começo
      -- escolhido não há anterior — e `-infinity` menos um intervalo estoura.
      v_antes := case when isfinite(v_desde) then v_desde - (v_ate - v_desde) else v_desde end;

      with base as (
        -- OS PROTOCOLOS DOS DOIS PERÍODOS, já recortados por lugar. A conversa
        -- passa pela regra de acesso de `conversas`, no papel de quem chama.
        select a.id, a.protocolo, a.conversa_id, a.aberto_em, a.origem, a.aberto_por,
               a.primeira_resposta_em, a.finalizado_em, a.finalizado_por,
               c.advogado_id, c.contato_id, ad.departamento_id,
               -- A INTERAÇÃO HUMANA COMEÇOU: a resposta, a finalização, ou a
               -- equipe abrindo o protocolo ela mesma.
               (a.primeira_resposta_em is not null or a.finalizado_em is not null
                  or a.origem <> 'cliente') as iniciado,
               a.aberto_em >= v_desde as no_periodo
          from public.zorvin_atendimentos a
          join public.conversas c on c.id = a.conversa_id
          left join public.advogados ad on ad.id = c.advogado_id
         where a.aberto_em >= v_antes and a.aberto_em <= v_ate
           and (p_telefone is null or c.advogado_id = p_telefone)
           and (p_departamento is null or ad.departamento_id = p_departamento)
      ),
      autoria as (
        -- QUEM MANDOU A PRIMEIRA RESPOSTA, uma ida pelo índice por protocolo.
        select b.*, r.por_id, r.rotulo
          from base b
          left join lateral (
            select nullif(y.x ->> 'enviado_por_id', '')::uuid as por_id,
                   nullif(btrim(y.x ->> 'enviado_por'), '') as rotulo
              from (select to_jsonb(m) as x
                      from public.mensagens m
                     where m.conversa_id = b.conversa_id
                       and m.origem = 'advogado'
                       and m.criado_em = b.primeira_resposta_em
                     order by m.id
                     limit 1) y
          ) r on true
      ),
      prazos as materialized (
        -- O PRAZO DE CADA PROTOCOLO QUE O CLIENTE ABRIU, de uma vez (1, acima).
        select * from public.zorvin_prazo_dos_protocolos(
          (select coalesce(array_agg(b.id), '{}'::uuid[]) from base b where b.origem = 'cliente'),
          v_agora)
      ),
      completa as (
        select g.*, p.min_acao, p.min_resposta, p.limite,
               case when g.origem <> 'cliente' or p.id is null then null
                    when g.primeira_resposta_em is not null or g.finalizado_em is not null
                    then case when p.min_acao < p.limite then 'no_prazo' else 'atrasado' end
                    -- A RÉGUA DO AVISO (041): ele toca quando os minutos chegam ao prazo.
                    when p.min_acao >= p.limite then 'sem_acao'
                    else 'aguardando' end as prazo
          from autoria g
          left join prazos p on p.id = g.id
      ),
      meus as (
        select * from completa
         where not v_so_meu
            or v_quem = por_id or v_quem = finalizado_por or v_quem = aberto_por
      ),
      agora as (
        select * from meus where no_periodo
      )
      select jsonb_build_object(
        'so_meu', v_so_meu,
        'desde', case when isfinite(v_desde) then v_desde end,
        'ate', v_ate,
        'total', jsonb_build_object(
          'atendimentos',   (select count(*) from agora where iniciado),
          'em_atendimento', (select count(*) from agora where iniciado and finalizado_em is null),
          'finalizados',    (select count(*) from agora where finalizado_em is not null),
          'sem_resposta',   case when v_so_meu then null
                                 else (select count(*) from agora where not iniciado) end,
          'do_cliente',     case when v_so_meu then null
                                 else (select count(*) from agora where origem = 'cliente') end
        ),
        -- O PRAZO É DA EQUIPE (ver o cabeçalho): com uma pessoa, nulo.
        'prazo', case when v_so_meu then null else (
          select jsonb_build_object(
                   'no_prazo',   count(*) filter (where prazo = 'no_prazo'),
                   'atrasados',  count(*) filter (where prazo = 'atrasado'),
                   'sem_acao',   count(*) filter (where prazo = 'sem_acao'),
                   'aguardando', count(*) filter (where prazo = 'aguardando'),
                   'limite_min', min(limite) filter (where prazo is not null),
                   'limite_max', max(limite) filter (where prazo is not null))
            from agora) end,
        'tempos', jsonb_build_object(
          'primeira_resposta', (
            select jsonb_build_object('mediana', percentile_cont(0.5) within group (order by x.s),
                                      'media', avg(x.s), 'quantos', count(*),
                                      'mediana_expediente', percentile_cont(0.5) within group (order by x.se),
                                      'media_expediente', avg(x.se))
              from (select greatest(0, extract(epoch from (g.primeira_resposta_em - g.aberto_em))) as s,
                           g.min_resposta * 60 as se
                      from agora g
                     where g.origem = 'cliente' and g.primeira_resposta_em is not null
                       and (not v_so_meu or g.por_id = v_quem)) x),
          'finalizar', (
            select jsonb_build_object('mediana', percentile_cont(0.5) within group (order by x.s),
                                      'media', avg(x.s), 'quantos', count(*))
              from (select greatest(0, extract(epoch from (g.finalizado_em - g.aberto_em))) as s
                      from agora g
                     where g.finalizado_em is not null
                       and (not v_so_meu or g.finalizado_por = v_quem)) x)
        ),
        'antes', jsonb_build_object(
          'existe', isfinite(v_desde),
          'atendimentos', (select count(*) from meus where not no_periodo and iniciado),
          -- O PRAZO COMPARA BEM: os dois períodos são julgados do mesmo jeito.
          'prazo', case when v_so_meu or not isfinite(v_desde) then null else (
            select jsonb_build_object(
                     'no_prazo',   count(*) filter (where prazo = 'no_prazo'),
                     'atrasados',  count(*) filter (where prazo = 'atrasado'),
                     'sem_acao',   count(*) filter (where prazo = 'sem_acao'),
                     'aguardando', count(*) filter (where prazo = 'aguardando'))
              from meus where not no_periodo) end
        ),
        'por_departamento', coalesce((
          select jsonb_agg(jsonb_build_object(
                   'id', x.departamento_id,
                   'nome', coalesce(dp.nome, '(sem departamento)'),
                   'atendimentos', x.atendimentos,
                   'em_atendimento', x.em_atendimento,
                   'finalizados', x.finalizados,
                   'sem_resposta', case when v_so_meu then null else x.sem_resposta end,
                   'primeira_mediana_expediente', x.mediana_expediente,
                   'prazo', case when v_so_meu then null else jsonb_build_object(
                              'no_prazo', x.no_prazo, 'atrasados', x.atrasados,
                              'sem_acao', x.sem_acao, 'aguardando', x.aguardando,
                              'limite', x.limite) end)
                 order by x.atendimentos desc, coalesce(dp.nome, ''))
            from (select g.departamento_id,
                         count(*) filter (where g.iniciado) as atendimentos,
                         count(*) filter (where g.iniciado and g.finalizado_em is null) as em_atendimento,
                         count(*) filter (where g.finalizado_em is not null) as finalizados,
                         count(*) filter (where not g.iniciado) as sem_resposta,
                         count(*) filter (where g.prazo = 'no_prazo') as no_prazo,
                         count(*) filter (where g.prazo = 'atrasado') as atrasados,
                         count(*) filter (where g.prazo = 'sem_acao') as sem_acao,
                         count(*) filter (where g.prazo = 'aguardando') as aguardando,
                         max(g.limite) as limite,
                         percentile_cont(0.5) within group (order by g.min_resposta * 60)
                           filter (where g.origem = 'cliente' and g.primeira_resposta_em is not null
                                     and (not v_so_meu or g.por_id = v_quem)) as mediana_expediente
                    from agora g
                   group by g.departamento_id) x
            left join public.departamentos dp on dp.id = x.departamento_id), '[]'::jsonb),
        -- TODO MUNDO, mesmo quando o resto está recortado numa pessoa: é para
        -- comparar, como o "por atendente" do Painel. Duas contas por pessoa,
        -- cada uma do seu gesto: as primeiras respostas (nos protocolos que o
        -- cliente abriu) e as finalizações.
        'por_pessoa', coalesce((
          select jsonb_agg(jsonb_build_object(
                   'id', z.id, 'tipo', z.tipo,
                   'nome', coalesce(e.nome, z.rotulo, '(sem nome)'),
                   'primeiras', z.primeiras, 'primeira_mediana', z.primeira_mediana,
                   'primeira_mediana_expediente', z.primeira_mediana_expediente,
                   'finalizou', z.finalizou, 'finalizar_mediana', z.finalizar_mediana)
                 order by (z.primeiras + z.finalizou) desc, coalesce(e.nome, z.rotulo, ''))
            from (select w.chave, w.id, w.tipo, max(w.rotulo) as rotulo,
                         count(*) filter (where w.papel = 'primeira') as primeiras,
                         percentile_cont(0.5) within group (order by w.s)
                           filter (where w.papel = 'primeira') as primeira_mediana,
                         percentile_cont(0.5) within group (order by w.se)
                           filter (where w.papel = 'primeira') as primeira_mediana_expediente,
                         count(*) filter (where w.papel = 'finalizou') as finalizou,
                         percentile_cont(0.5) within group (order by w.s)
                           filter (where w.papel = 'finalizou') as finalizar_mediana
                    from (select case when g.por_id is not null then g.por_id::text
                                      when g.rotulo = 'WhatsApp' then 'celular'
                                      when g.rotulo is not null then 'rotulo:' || lower(g.rotulo)
                                      else 'desconhecido' end as chave,
                                 g.por_id as id,
                                 case when g.por_id is not null then 'pessoa'
                                      when g.rotulo = 'WhatsApp' then 'celular'
                                      when g.rotulo is not null then 'rotulo'
                                      else 'desconhecido' end as tipo,
                                 case when g.por_id is not null then null
                                      when g.rotulo = 'WhatsApp' then 'Pelo celular'
                                      else g.rotulo end as rotulo,
                                 'primeira' as papel,
                                 greatest(0, extract(epoch from (g.primeira_resposta_em - g.aberto_em))) as s,
                                 g.min_resposta * 60 as se
                            from completa g
                           where g.no_periodo and g.origem = 'cliente' and g.primeira_resposta_em is not null
                          union all
                          select coalesce(g.finalizado_por::text, 'desconhecido'), g.finalizado_por,
                                 case when g.finalizado_por is not null then 'pessoa' else 'desconhecido' end,
                                 null, 'finalizou',
                                 greatest(0, extract(epoch from (g.finalizado_em - g.aberto_em))),
                                 null
                            from completa g
                           where g.no_periodo and g.finalizado_em is not null) w
                   group by w.chave, w.id, w.tipo) z
            -- OS NOMES DE HOJE, pela vista `equipe` — a das bolhas. `usuarios`
            -- direto não serve: a regra dela mostra a quem não administra só a
            -- própria linha, e o "por pessoa" viraria "(sem nome)".
            left join public.equipe e on e.id = z.id), '[]'::jsonb),
        'por_dia', coalesce((
          select jsonb_agg(jsonb_build_object(
                   'quando', x.dia, 'atendimentos', x.a, 'sem_resposta', x.s,
                   'finalizados', x.f,
                   'no_prazo', case when v_so_meu then null else x.np end,
                   'prazo_julgados', case when v_so_meu then null else x.pj end)
                 order by x.dia)
            from (select (g.aberto_em at time zone v_fuso)::date as dia,
                         count(*) filter (where g.iniciado) as a,
                         count(*) filter (where not g.iniciado) as s,
                         count(*) filter (where g.finalizado_em is not null) as f,
                         count(*) filter (where g.prazo = 'no_prazo') as np,
                         count(*) filter (where g.prazo in ('no_prazo', 'atrasado', 'sem_acao')) as pj
                    from agora g group by 1) x), '[]'::jsonb),
        'total_registros', (select count(*) from agora),
        'registros', coalesce((
          select jsonb_agg(y.r order by y.aberto_em desc, y.protocolo desc)
            from (select g.aberto_em, g.protocolo, jsonb_build_object(
                           'protocolo', g.protocolo,
                           'conversa_id', g.conversa_id,
                           'advogado_id', g.advogado_id,
                           'contato', jsonb_build_object(
                              'nome', ct.nome, 'numero', ct.numero,
                              'nome_zorvin', to_jsonb(ct) ->> 'nome_zorvin',
                              'vantoro_nome', to_jsonb(ct) ->> 'vantoro_nome'),
                           'origem', g.origem,
                           'aberto_em', g.aberto_em,
                           'aberto_por', g.aberto_por,
                           'aberto_por_nome', ea.nome,
                           'primeira_resposta_em', g.primeira_resposta_em,
                           'respondeu_por', g.por_id,
                           'respondeu_nome', case when g.primeira_resposta_em is null then null
                                                  when g.por_id is not null then coalesce(er.nome, '(sem nome)')
                                                  when g.rotulo = 'WhatsApp' then 'Pelo celular'
                                                  else g.rotulo end,
                           'pelo_celular', coalesce(g.por_id is null and g.rotulo = 'WhatsApp', false),
                           'finalizado_em', g.finalizado_em,
                           'finalizado_por', g.finalizado_por,
                           'finalizado_nome', ef.nome,
                           'estado', case when g.finalizado_em is not null then 'finalizado'
                                          when g.iniciado then 'em_atendimento'
                                          else 'sem_resposta' end,
                           'prazo', g.prazo,
                           'minutos_ate_acao', g.min_acao,
                           'limite', g.limite) as r
                    from agora g
                    left join public.contatos ct on ct.id = g.contato_id
                    left join public.equipe ea on ea.id = g.aberto_por
                    left join public.equipe er on er.id = g.por_id
                    left join public.equipe ef on ef.id = g.finalizado_por
                   order by g.aberto_em desc, g.protocolo desc
                   limit v_lim) y), '[]'::jsonb)
      ) into v_saida;

      return v_saida;
    end
    $fn$
  $sql$;

  execute $sql$
    comment on function public.zorvin_relatorio_atendimentos(timestamptz, timestamptz, uuid, text, uuid, bigint, integer) is
      'A contabilização por protocolo (029, com o prazo do 052): o total (só o que a equipe '
      'começou), em atendimento, finalizados, esperando resposta, o prazo em horário de '
      'expediente (da equipe), os tempos até a primeira resposta (no relógio e no expediente) '
      'e até finalizar, o período anterior (o total e o prazo), por departamento, por pessoa '
      '(todos), por dia e a lista. Quem não administra recebe os de que participou. '
      'security invoker.'
  $sql$;

  -- As permissões ditas de novo, nas duas: `create or replace` guarda as de
  -- uma função que já existe, e a que nasce agora viria com as da herança (a
  -- régua do 035). `public` inclui quem não entrou (`anon`).
  execute 'revoke all on function public.zorvin_prazo_dos_protocolos(uuid[], timestamptz) from public';
  execute 'revoke all on function public.zorvin_relatorio_atendimentos(timestamptz, timestamptz, uuid, text, uuid, bigint, integer) from public';
  if exists (select 1 from pg_roles where rolname = 'anon') then
    execute 'revoke all on function public.zorvin_prazo_dos_protocolos(uuid[], timestamptz) from anon';
    execute 'revoke all on function public.zorvin_relatorio_atendimentos(timestamptz, timestamptz, uuid, text, uuid, bigint, integer) from anon';
  end if;
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'grant execute on function public.zorvin_prazo_dos_protocolos(uuid[], timestamptz) to authenticated';
    execute 'grant execute on function public.zorvin_relatorio_atendimentos(timestamptz, timestamptz, uuid, text, uuid, bigint, integer) to authenticated';
  end if;
  if exists (select 1 from pg_roles where rolname = 'service_role') then
    execute 'grant execute on function public.zorvin_prazo_dos_protocolos(uuid[], timestamptz) to service_role';
    execute 'grant execute on function public.zorvin_relatorio_atendimentos(timestamptz, timestamptz, uuid, text, uuid, bigint, integer) to service_role';
  end if;

  insert into zorvin_conferencia_052
  select 'a conta do prazo existe',
         (to_regprocedure('public.zorvin_prazo_dos_protocolos(uuid[], timestamptz)') is not null)::text;
end
$prazo$;

-- ----------------------------------------------------------
--  A CONFERÊNCIA VAI DENTRO DO SCRIPT, e é a última linha dele.
--
--  1. AS DUAS ESCRITAS DA CONTA DOS MINUTOS DÃO O MESMO, protocolo por
--     protocolo, nos dados de verdade dos últimos 30 dias: a desta conta (de
--     uma vez) e a do aviso de espera (`zorvin_minutos_no_expediente`, um por
--     um). Uma diferença aqui quer dizer que o Painel e o aviso discordam
--     sobre quanto um cliente esperou.
--  2. A FUNÇÃO RESPONDE PARA QUEM ATENDE (`authenticated`), com um telefone
--     e com um departamento — a regra 4 do LEIA-ME.
--  3. E PARA QUEM ADMINISTRA, com os dados de verdade dos últimos 30 dias.
-- ----------------------------------------------------------
do $conf$
declare
  v_resposta text;
  v_iguais   text;
  v_numeros  text;
  v_tem      boolean;
  v_admin    uuid;
  v_prazo    jsonb;
begin
  if to_regprocedure('public.zorvin_prazo_dos_protocolos(uuid[], timestamptz)') is null then
    return;
  end if;

  insert into zorvin_conferencia_052
  select 'a contabilização com o prazo existe',
         (to_regprocedure('public.zorvin_relatorio_atendimentos(timestamptz, timestamptz, uuid, text, uuid, bigint, integer)') is not null)::text;

  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    insert into zorvin_conferencia_052
    select 'quem entrou pode usar as duas',
           (has_function_privilege('authenticated', 'public.zorvin_prazo_dos_protocolos(uuid[], timestamptz)', 'execute')
            and has_function_privilege('authenticated',
                  'public.zorvin_relatorio_atendimentos(timestamptz, timestamptz, uuid, text, uuid, bigint, integer)',
                  'execute'))::text;
  end if;
  if exists (select 1 from pg_roles where rolname = 'anon') then
    insert into zorvin_conferencia_052
    select 'quem não entrou não pode usar nenhuma',
           (not has_function_privilege('anon', 'public.zorvin_prazo_dos_protocolos(uuid[], timestamptz)', 'execute')
            and not has_function_privilege('anon',
                  'public.zorvin_relatorio_atendimentos(timestamptz, timestamptz, uuid, text, uuid, bigint, integer)',
                  'execute'))::text;
  end if;

  -- 1. As duas escritas da conta. UM DADO ESTRANHO NÃO DERRUBA O SCRIPT: a
  --    conferência diz o erro, e as funções ficam — o script desfeito
  --    inteiro pararia os seguintes por causa de uma linha da conferência.
  begin
    execute $q$
      with p as (
        select p.*, z.aberto_em, z.primeira_resposta_em, f.semana, f.fuso
          from public.zorvin_prazo_dos_protocolos(
                 (select coalesce(array_agg(id), '{}'::uuid[]) from public.zorvin_atendimentos
                   where origem = 'cliente' and aberto_em > now() - interval '30 days'), now()) p
          join public.zorvin_atendimentos z on z.id = p.id
          join public.conversas c on c.id = z.conversa_id
          left join public.advogados a on a.id = c.advogado_id
          left join public.zorvin_fora_do_horario f on f.departamento_id = a.departamento_id
      )
      select case when count(*) = 0 then 'sem protocolo do cliente nos últimos 30 dias para comparar'
                  when count(*) filter (where
                         p.min_acao is distinct from public.zorvin_minutos_no_expediente(
                           p.semana, p.fuso, p.aberto_em, coalesce(p.acao_em, now()))
                      or (p.primeira_resposta_em is not null and p.min_resposta is distinct from
                            public.zorvin_minutos_no_expediente(p.semana, p.fuso, p.aberto_em, p.primeira_resposta_em))) = 0
                  then 'true'
                  else 'NÃO — ' || count(*) filter (where
                         p.min_acao is distinct from public.zorvin_minutos_no_expediente(
                           p.semana, p.fuso, p.aberto_em, coalesce(p.acao_em, now()))
                      or (p.primeira_resposta_em is not null and p.min_resposta is distinct from
                            public.zorvin_minutos_no_expediente(p.semana, p.fuso, p.aberto_em, p.primeira_resposta_em)))
                       || ' de ' || count(*) || ' protocolos diferem da conta do aviso de espera' end
        from p
    $q$ into v_iguais;
  exception when others then
    v_iguais := 'NÃO — ' || sqlerrm || ' (código ' || sqlstate || ')';
  end;
  insert into zorvin_conferencia_052
  values ('a conta do prazo bate com a do aviso de espera, protocolo por protocolo (últimos 30 dias)', v_iguais);

  -- O que a conta diz, para quem confere ler: só números.
  begin
    execute $q$
      select count(*) || ' abertos pelo cliente · no prazo '
             || count(*) filter (where p.acao_em is not null and p.min_acao < p.limite)
             || ' · atrasados ' || count(*) filter (where p.acao_em is not null and p.min_acao >= p.limite)
             || ' · sem ação fora do prazo ' || count(*) filter (where p.acao_em is null and p.min_acao >= p.limite)
        from public.zorvin_prazo_dos_protocolos(
               (select coalesce(array_agg(id), '{}'::uuid[]) from public.zorvin_atendimentos
                 where origem = 'cliente' and aberto_em > now() - interval '30 days'), now()) p
    $q$ into v_numeros;
  exception when others then
    v_numeros := 'NÃO — ' || sqlerrm || ' (código ' || sqlstate || ')';
  end;
  insert into zorvin_conferencia_052 values ('protocolos dos últimos 30 dias', v_numeros);

  if not exists (select 1 from pg_roles where rolname = 'authenticated') then
    return;
  end if;

  -- 2. No papel de quem atende, sem ninguém: a regra de acesso não deixa ver
  --    conversa nenhuma, e o que se confere é que as duas funções respondem.
  --
  --    A CONTA DO PRAZO É CHAMADA DIRETO, e não só pela contabilização: lá
  --    dentro ela só roda quando há protocolo — o banco não lê o lado de um
  --    `join` cujo outro lado veio vazio —, e quem não vê nenhum não a
  --    chamaria. Foi a prova que mostrou: sem a leitura dos feriados, a
  --    contabilização respondia "sim" para quem não vê nada.
  begin
    perform set_config('role', 'authenticated', true);
    v_tem := (public.zorvin_relatorio_atendimentos() ? 'por_departamento');
    perform count(*) from public.zorvin_prazo_dos_protocolos('{}'::uuid[]);
    perform public.zorvin_relatorio_atendimentos(null, null, null, null,
              (select a.id from public.advogados a limit 1));
    perform public.zorvin_relatorio_atendimentos(null, null, null, null, null,
              (select a.departamento_id from public.advogados a
                where a.departamento_id is not null limit 1));
    v_resposta := 'sim';
    execute 'reset role';
  exception when others then
    v_resposta := 'NÃO — ' || sqlerrm || ' (código ' || sqlstate || ')';
  end;

  insert into zorvin_conferencia_052
  values ('a função responde para quem atende', v_resposta);
  if v_resposta <> 'sim' then
    return;
  end if;
  insert into zorvin_conferencia_052
  values ('a resposta traz os departamentos', coalesce(v_tem, false)::text);

  -- 3. NO PAPEL DE QUEM ADMINISTRA (a primeira pessoa ativa que administra),
  --    que vê os dados de verdade dos últimos 30 dias: é por ele que a conta
  --    do prazo roda de fato, com as semanas e os feriados do escritório.
  --    Só lê; a troca de quem é desfeita no fim, ou junto com o bloco que
  --    falhou.
  if to_regclass('public.usuarios') is null then
    return;
  end if;
  execute 'select u.id from public.usuarios u where u.admin and u.ativo order by u.id limit 1' into v_admin;
  if v_admin is null then
    return;
  end if;
  begin
    perform set_config('request.jwt.claim.sub', v_admin::text, true);
    perform set_config('role', 'authenticated', true);
    v_prazo := public.zorvin_relatorio_atendimentos(now() - interval '30 days', now()) -> 'prazo';
    execute 'reset role';
    perform set_config('request.jwt.claim.sub', '', true);
    v_resposta := case when jsonb_typeof(v_prazo) = 'object' then 'sim'
                       else 'NÃO — a resposta veio sem o prazo' end;
  exception when others then
    v_resposta := 'NÃO — ' || sqlerrm || ' (código ' || sqlstate || ')';
  end;
  insert into zorvin_conferencia_052
  values ('a função responde para quem administra, com o prazo (últimos 30 dias)', v_resposta);
end
$conf$;

-- A RESPOSTA DE "DEU CERTO?", na última linha, que é a que o editor mostra.
select * from zorvin_conferencia_052;
