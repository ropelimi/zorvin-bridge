-- ============================================================
--  A CONTABILIZAÇÃO DOS ATENDIMENTOS — o relatório por protocolo
--
--  >>> RODAR NO SUPABASE DO **ZORVIN** (o das conversas). <<<
--  A ponte aplica sozinha ao subir (sql/automaticos). Pode rodar de novo sem
--  medo.
--
--  ------------------------------------------------------------
--  O PEDIDO
--
--  Depois das abas do 028, o Rodrigo pediu a "contabilização" do DataCrazy:
--  quantos atendimentos houve, quanto tempo o cliente esperou pela primeira
--  resposta e quanto tempo levou até finalizar. E a regra que ele copiou de
--  lá: "as mensagens que permanecem com o status de Aguardando não somam no
--  volume de 'Quantidade Total' até que a interação humana de fato comece".
--
--  ------------------------------------------------------------
--  UM ATENDIMENTO É UM PROTOCOLO (`zorvin_atendimentos`, do 028)
--
--  E ELE SÓ ENTRA NO TOTAL QUANDO A EQUIPE COMEÇA: alguém respondeu, alguém
--  finalizou, ou foi a própria equipe que abriu (a conversa começada por nós,
--  o Reabrir). O protocolo que o cliente abriu e em que ninguém mexeu fica
--  fora do total e aparece à parte, como "esperando resposta".
--
--  Isso vale também para o cliente que volta a escrever numa conversa
--  finalizada. A conversa vai para "Em Atendimento" (o cliente já foi tratado
--  — a decisão do 028), mas o protocolo novo só entra no total quando alguém
--  responder a ele: é a mensagem que "não teve resposta", nas palavras do
--  Rodrigo, e contá-la antes seria contar trabalho que ainda não aconteceu.
--
--  ------------------------------------------------------------
--  O PERÍODO É O DA ABERTURA
--
--  Tudo aqui é dos protocolos ABERTOS no período: o total, os tempos, o "por
--  pessoa", o "por dia" e a lista. Um eixo só faz as contas fecharem — o total
--  é a soma dos em atendimento com os finalizados, e cada protocolo está num
--  e num só.
--
--  OS TEMPOS, em segundos (a tela escreve "12 min", "3 h"):
--    até a primeira resposta — só no protocolo que o CLIENTE abriu. Na
--      conversa começada por nós e no Reabrir não houve cliente esperando;
--    até finalizar — do começo do protocolo até o "Finalizar", em todo
--      protocolo finalizado.
--  A mediana e a média, a régua do Painel: uma conversa esquecida no fim de
--  semana puxa a média, e não a mediana.
--
--  O PERÍODO ANTERIOR, do mesmo tamanho, vem SÓ PARA O TOTAL. Comparar
--  quantos ainda estão em atendimento entre dois meses mediria só que o mês
--  velho teve mais tempo para ser finalizado.
--
--  ------------------------------------------------------------
--  QUEM DEU A PRIMEIRA RESPOSTA
--
--  É quem mandou a mensagem que o 028 anotou como a primeira resposta
--  (`mensagens.enviado_por_id`). A mandada pelo celular, sem o Zorvin, a ponte
--  grava assinada "WhatsApp" e sem id — e ela vira a linha "Pelo celular". A
--  de antes de ago/2026 não tem o id: vale o nome que ela traz.
--
--  As duas colunas vêm por `to_jsonb(m)`: nasceram em `sql/`, à mão, e uma
--  função que as citasse pelo nome morreria num banco sem elas. Em `mensagens`
--  isso é seguro: nenhuma coluna dela é fechada para quem entrou (a régua do
--  012 — `to_jsonb` só em tabela sem coluna fechada).
--
--  ------------------------------------------------------------
--  CADA UM VÊ O QUE É SEU — a régua do Painel e do 010
--
--  Quem não administra recebe os atendimentos de que PARTICIPOU: deu a
--  primeira resposta, finalizou ou reabriu. O recorte é feito AQUI, e não no
--  navegador. Os tempos são de quem fez: a primeira resposta conta para quem
--  respondeu, e o finalizar para quem finalizou. O "esperando resposta" não
--  aparece para ela — ainda não é de ninguém. O "por pessoa" mostra todo
--  mundo, para comparar.
--
--  `security invoker`: a função enxerga só as conversas de quem chama — um
--  relatório não pode ser a porta dos fundos para os clientes de um telefone
--  que a pessoa não atende. De `advogados`, só `departamento_id`, pelo nome:
--  a chave da Uazapi mora lá, e ler a linha inteira morreria com
--  "permission denied" (o 011, consertado no 012).
--
--  ------------------------------------------------------------
--  DEPENDE DE JÁ TER RODADO
--    o 028. Sem ele a função responde {"falta": "028"}, e não números
--    zerados — que se leriam como "ninguém atendeu ninguém".
-- ============================================================

-- Apaga qualquer versão anterior ANTES de criar: `create or replace` com outra
-- lista de argumentos cria uma segunda função de mesmo nome, e a chamada do
-- painel morreria com "could not choose the best candidate".
do $limpa$
declare r record;
begin
  for r in select oid::regprocedure as f from pg_proc
            where proname = 'zorvin_relatorio_atendimentos'
              and pronamespace = 'public'::regnamespace
  loop execute 'drop function ' || r.f; end loop;
end
$limpa$;

-- A FUNÇÃO É CRIADA SEMPRE, mesmo num banco sem as tabelas: é `plpgsql`, e os
-- nomes de dentro só são resolvidos quando ela roda. A 51l-bis, que aplica a
-- pasta num banco limpo, passa; num banco de verdade, ela serve.
create function public.zorvin_relatorio_atendimentos(
  p_desde        timestamptz default null,
  p_ate          timestamptz default null,
  p_quem         uuid        default null,
  p_fuso         text        default 'America/Campo_Grande',
  p_telefone     uuid        default null,
  p_departamento bigint      default null,
  -- QUANTOS PROTOCOLOS, no máximo, vêm na lista de baixo. As contas de cima
  -- são sempre do período inteiro; só a lista é aparada — e ela diz de quantos.
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

  -- QUEM NÃO ADMINISTRA NÃO ESCOLHE. Aqui, e não no navegador. E sem sessão
  -- (`auth.uid()` nulo) o recorte continua ligado: nulo não é "todo mundo".
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
           c.advogado_id, c.contato_id,
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
  meus as (
    select * from autoria
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
                             else (select count(*) from agora where not iniciado) end
    ),
    'tempos', jsonb_build_object(
      'primeira_resposta', (
        select jsonb_build_object('mediana', percentile_cont(0.5) within group (order by x.s),
                                  'media', avg(x.s), 'quantos', count(*))
          from (select greatest(0, extract(epoch from (g.primeira_resposta_em - g.aberto_em))) as s
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
      'atendimentos', (select count(*) from meus where not no_periodo and iniciado)
    ),
    -- TODO MUNDO, mesmo quando o resto está recortado numa pessoa: é para
    -- comparar, como o "por atendente" do Painel. Duas contas por pessoa, cada
    -- uma do seu gesto: as primeiras respostas (nos protocolos que o cliente
    -- abriu) e as finalizações.
    'por_pessoa', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', z.id, 'tipo', z.tipo,
               'nome', coalesce(e.nome, z.rotulo, '(sem nome)'),
               'primeiras', z.primeiras, 'primeira_mediana', z.primeira_mediana,
               'finalizou', z.finalizou, 'finalizar_mediana', z.finalizar_mediana)
             order by (z.primeiras + z.finalizou) desc, coalesce(e.nome, z.rotulo, ''))
        from (select w.chave, w.id, w.tipo, max(w.rotulo) as rotulo,
                     count(*) filter (where w.papel = 'primeira') as primeiras,
                     percentile_cont(0.5) within group (order by w.s)
                       filter (where w.papel = 'primeira') as primeira_mediana,
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
                             greatest(0, extract(epoch from (g.primeira_resposta_em - g.aberto_em))) as s
                        from autoria g
                       where g.no_periodo and g.origem = 'cliente' and g.primeira_resposta_em is not null
                      union all
                      select coalesce(g.finalizado_por::text, 'desconhecido'), g.finalizado_por,
                             case when g.finalizado_por is not null then 'pessoa' else 'desconhecido' end,
                             null, 'finalizou',
                             greatest(0, extract(epoch from (g.finalizado_em - g.aberto_em)))
                        from autoria g
                       where g.no_periodo and g.finalizado_em is not null) w
               group by w.chave, w.id, w.tipo) z
        -- OS NOMES DE HOJE, pela vista `equipe` — a das bolhas. `usuarios`
        -- direto não serve: a regra dela mostra a quem não administra só a
        -- própria linha, e o "por pessoa" viraria "(sem nome)".
        left join public.equipe e on e.id = z.id), '[]'::jsonb),
    'por_dia', coalesce((
      select jsonb_agg(jsonb_build_object('quando', x.dia, 'atendimentos', x.a, 'sem_resposta', x.s)
                       order by x.dia)
        from (select (g.aberto_em at time zone v_fuso)::date as dia,
                     count(*) filter (where g.iniciado) as a,
                     count(*) filter (where not g.iniciado) as s
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
                                      else 'sem_resposta' end) as r
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
$fn$;

comment on function public.zorvin_relatorio_atendimentos(timestamptz, timestamptz, uuid, text, uuid, bigint, integer) is
  'A contabilização por protocolo (script 029): o total (só o que a equipe começou), '
  'em atendimento, finalizados, esperando resposta, os tempos até a primeira resposta '
  'e até finalizar, o período anterior, por pessoa (todos), por dia e a lista. Quem não '
  'administra recebe os de que participou. security invoker.';

-- `public` inclui quem não entrou (`anon`). Tira dele e devolve a quem entrou,
-- na mesma passada — a régua de 2026-09-as-quatro-funcoes-que-rodam-com-poder-de-dono.
revoke all on function public.zorvin_relatorio_atendimentos(timestamptz, timestamptz, uuid, text, uuid, bigint, integer) from public;
do $grant$
begin
  if exists (select 1 from pg_roles where rolname = 'anon') then
    execute 'revoke all on function public.zorvin_relatorio_atendimentos(timestamptz, timestamptz, uuid, text, uuid, bigint, integer) from anon';
  end if;
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'grant execute on function public.zorvin_relatorio_atendimentos(timestamptz, timestamptz, uuid, text, uuid, bigint, integer) to authenticated';
  end if;
end
$grant$;

-- O ÍNDICE DO PERÍODO: a conta recorta os protocolos pela data em que abriram.
-- A tabela é pequena (um protocolo por atendimento), e criar o índice segura a
-- gravação de protocolo por milissegundos.
do $indice$
begin
  if to_regclass('public.zorvin_atendimentos') is not null then
    execute 'create index if not exists zorvin_atendimentos_aberto
               on public.zorvin_atendimentos (aberto_em)';
  end if;
end
$indice$;

-- ----------------------------------------------------------
--  A CONFERÊNCIA VAI DENTRO DO SCRIPT, e é a última linha dele: o editor do
--  Supabase só mostra o resultado do último comando. A tabela temporária
--  nasce ANTES de qualquer guarda — a lição do 006 e do 007.
--
--  E ELA CHAMA A FUNÇÃO COMO QUEM ATENDE (`authenticated`), e não como dona
--  do banco — a régua do 012. Com um telefone e com um departamento também:
--  é o caminho que lê `advogados`, e uma leitura de coluna fechada ali só
--  morreria com o filtro ligado. A troca de papel volta atrás sozinha se
--  falhar.
-- ----------------------------------------------------------
do $conf$
declare
  v_resposta text;
  v_numeros  text;
begin
  drop table if exists zorvin_conferencia_029;
  create temp table zorvin_conferencia_029 (item text, resposta text);

  insert into zorvin_conferencia_029
  select 'a função da contabilização existe',
         (to_regprocedure('public.zorvin_relatorio_atendimentos(timestamptz, timestamptz, uuid, text, uuid, bigint, integer)') is not null)::text;

  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    insert into zorvin_conferencia_029
    select 'quem entrou pode usá-la',
           has_function_privilege('authenticated',
             'public.zorvin_relatorio_atendimentos(timestamptz, timestamptz, uuid, text, uuid, bigint, integer)',
             'execute')::text;
  end if;

  if to_regclass('public.zorvin_atendimentos') is null then
    insert into zorvin_conferencia_029 values ('sem os protocolos', 'rode o script 028 antes');
    return;
  end if;

  execute $q$
    select 'abertos ' || count(*)
           || ' · com atendimento ' || count(*) filter (where primeira_resposta_em is not null
                                                          or finalizado_em is not null
                                                          or origem <> 'cliente')
           || ' · esperando resposta ' || count(*) filter (where primeira_resposta_em is null
                                                             and finalizado_em is null
                                                             and origem = 'cliente')
      from public.zorvin_atendimentos
     where aberto_em >= now() - interval '30 days'
  $q$ into v_numeros;
  insert into zorvin_conferencia_029 values ('protocolos dos últimos 30 dias', v_numeros);

  if not exists (select 1 from pg_roles where rolname = 'authenticated') then
    return;
  end if;

  begin
    perform set_config('role', 'authenticated', true);
    perform public.zorvin_relatorio_atendimentos();
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

  insert into zorvin_conferencia_029
  values ('a função responde para quem atende', v_resposta);
end
$conf$;

-- A RESPOSTA DE "DEU CERTO?", na última linha, que é a que o editor mostra.
select * from zorvin_conferencia_029;
