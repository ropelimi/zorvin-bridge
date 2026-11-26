-- ============================================================
--  074 — AS MENSAGENS DA EQUIPE, DIA A DIA, PARA O VANTORO
-- ============================================================
--
--  Pedido do escritório (26/11), do lado do Vantoro: as tarefas de SUBSÍDIO
--  (a determinação do juiz que depende de um documento do cliente) contam as
--  TENTATIVAS DE CONTATO com o cliente. A regra do escritório: conta como
--  tentativa a mensagem que uma PESSOA da equipe mandou ao cliente no Zorvin
--  — pelo painel ou pelo celular, sobre qualquer assunto —, uma por dia. O
--  aviso automático e o robô não contam.
--
--  Até aqui o Vantoro só recebia da ponte o resumo do 030/031/033, que traz a
--  ÚLTIMA mensagem de cada conversa. Com ele não dá para marcar as tentativas
--  que já aconteceram: a de terça some quando alguém escreve na quarta. Esta
--  função entrega o que falta — os DIAS em que houve mensagem de gente da
--  equipe em cada conversa —, pela porta `POST /vantoro/mensagens-da-equipe`.
--
--  ------------------------------------------------------------
--  O QUE ELA DEVOLVE
--  ------------------------------------------------------------
--  Uma linha por CONVERSA e por DIA (no fuso de Brasília, America/Sao_Paulo),
--  desde `p_desde`: a PRIMEIRA mensagem de gente da equipe naquele dia, com
--  quem mandou e se foi pelo celular. Só a primeira porque a regra é "uma por
--  dia": o Vantoro não precisa das outras, e mandá-las multiplicaria a
--  resposta por nada.
--
--  `quem` e `pelo_celular` são calculados EXATAMENTE como `ultima_quem` e
--  `ultima_pelo_celular` do resumo (033): o nome de hoje de quem mandou pelo
--  painel, ou o rótulo gravado ("WhatsApp" para o celular). Duas réguas para
--  a mesma pergunta fariam as duas telas do Vantoro discordarem.
--
--  A ordem é a do tempo (a mais antiga primeiro). Assim, quando `p_limite`
--  corta, corta o FIM — e o Vantoro continua pedindo de novo com `desde` no
--  último dia que recebeu (repetir um dia não faz estrago: é uma por dia).
--  `completo` diz se veio tudo: o corte calado é o defeito que mais se
--  repetiu neste projeto (o PostgREST corta em mil e não avisa).
--
--  ------------------------------------------------------------
--  O QUE CONTA COMO "GENTE DA EQUIPE", e por quê
--  ------------------------------------------------------------
--  É a mesma régua de `ehDaEquipeDeVerdade` no index.js (origem 'advogado',
--  sem `automatica`, sem `pelo_quazar`), mais duas cautelas que só fazem
--  sentido olhando o passado:
--
--    ENTRA
--    • `origem = 'advogado'` — a lista do que é do escritório, e não "tudo
--      que não é 'contato'": o 004 já avisava que uma origem futura
--      ('sistema', por exemplo) não pode contar como a equipe agindo;
--    • a mensagem mandada pelo PAINEL (tem `enviado_por_id`), inclusive a que
--      saiu do "Sugerir resposta" (060) e a mensagem agendada (013): nas
--      duas, quem escolheu mandar foi uma pessoa;
--    • a mandada pelo CELULAR ou pelo WhatsApp do computador, fora do Zorvin
--      (o webhook a grava com `enviado_por = 'WhatsApp'`);
--    • conversa finalizada, arquivada ou de telefone desativado HOJE: a
--      tentativa aconteceu quando aconteceu, e o que se fez com a conversa
--      depois não a desfaz.
--
--    FICA DE FORA
--    • `automatica` (037): o aviso de audiência do Vantoro e a resposta do
--      Quazar à noite;
--    • `pelo_quazar` (059): toda resposta do Quazar, de dia e de noite, a
--      faxina e o pedido de nome e CPF (a ponte marca as duas colunas juntas;
--      as duas aqui são cinto e suspensório);
--    • a mensagem SEM AUTOR (nem `enviado_por_id` nem `enviado_por`). É o
--      que sobra de quem não se sabe quem mandou: o aviso antigo que o 037
--      não conseguiu casar com a fila, a linha que `salvarMensagem` regravou
--      sem os extras (coluna faltando: o rótulo do Quazar e o do aviso vão
--      embora junto) e o passado trazido por `/importar-historico`, que
--      chega sem autor — e que pode trazer, entre as nossas, a resposta
--      automática fora do horário, que a ponte manda pela API e não grava em
--      `mensagens`. Sem saber quem foi, não dá para dizer que foi gente;
--    • a mensagem cujo id do WhatsApp está em `zorvin_respostas_automaticas`
--      (021/022): a resposta automática fora do horário não mora em
--      `mensagens`, de propósito, mas uma importação de histórico pode
--      trazê-la para cá — e aí ela é reconhecida pelo id;
--    • a mensagem APAGADA pela equipe (`apagada`, "apagar para todos"): ela
--      sumiu do lado do cliente, e quase sempre é a que foi para a conversa
--      errada. Decisão minha, a confirmar com o escritório;
--    • o GRUPO (`contatos.numero` 'grupo:…'), como no resumo: tentativa de
--      contato é com o cliente;
--    • a reação (emoji) da equipe: ela não é linha de `mensagens`, fica na
--      mensagem reagida (`reacoes`), então nem passa por aqui.
--
--    O QUE NÃO TEM COMO SER SEPARADO
--    • a mensagem automática configurada NO PRÓPRIO WhatsApp Business do
--      celular (saudação, ausência): ela chega ao webhook como qualquer outra
--      mandada do aparelho, e entra como "WhatsApp", pelo celular. A ponte não
--      recebe nenhum sinal que a distinga.
--
--  ------------------------------------------------------------
--  QUEM PODE CHAMAR
--  ------------------------------------------------------------
--  SÓ A PONTE (`service_role`), como o resumo do 030: a função devolve as
--  conversas de TODOS os telefones, sem a regra de quem vê o quê. Liberada
--  para quem entrou no painel, ela seria um atalho por cima das permissões.
--  E, como a do 030, ela NÃO é `security definer`: quem chama é a ponte, que
--  já alcança tudo, e rodar como dona do banco só alargaria quem a usasse.
--
--  plpgsql: os nomes de dentro só são resolvidos quando ela roda, então ela é
--  criada mesmo num banco sem as tabelas (a prova 51l-bis aplica a pasta
--  inteira num banco limpo).
--
--  A LEITURA usa o índice `mensagens_criado_em` (do painel, em agosto): o
--  corte é pela hora (`criado_em >=` a meia-noite de Brasília de `p_desde`), e
--  não pelo dia calculado, que nenhum índice ajudaria.
--
--  Rodável de novo: a função é apagada (todas as versões) e criada de novo.
--  DEPENDE DE JÁ TER RODADO o 021 (as respostas automáticas), o 037
--  (`automatica`) e o 059 (`pelo_quazar`).
-- ============================================================

do $limpa$
declare r record;
begin
  for r in select oid::regprocedure as f from pg_proc
            where proname = 'zorvin_mensagens_da_equipe'
              and pronamespace = 'public'::regnamespace
  loop execute 'drop function ' || r.f; end loop;
end
$limpa$;

create function public.zorvin_mensagens_da_equipe(
  p_desde  date    default null,
  p_limite integer default 20000
) returns jsonb
language plpgsql
stable
set search_path = public
as $fn$
declare
  -- SEM DATA, os últimos 30 dias de Brasília. A porta sempre manda a data; o
  -- padrão é para quem chamar à mão no editor.
  v_desde  date    := coalesce(p_desde, (now() at time zone 'America/Sao_Paulo')::date - 30);
  v_limite integer := greatest(coalesce(p_limite, 20000), 1);
  v_linhas jsonb;
  v_cortou boolean;
begin
  with
  -- AS MENSAGENS DE GENTE DA EQUIPE desde a meia-noite de Brasília de
  -- `v_desde`. Cada condição está explicada no cabeçalho.
  candidatas as (
    select m.id, m.conversa_id, m.criado_em, m.enviado_por, m.enviado_por_id,
           (m.criado_em at time zone 'America/Sao_Paulo')::date as dia
      from mensagens m
     where m.criado_em >= (v_desde::timestamp at time zone 'America/Sao_Paulo')
       and m.origem = 'advogado'
       and not coalesce(m.automatica, false)
       and not coalesce(m.pelo_quazar, false)
       and not coalesce(m.apagada, false)
       and (m.enviado_por_id is not null or nullif(btrim(m.enviado_por), '') is not null)
       and not exists (select 1 from zorvin_respostas_automaticas ra
                        where ra.id_uazapi = m.id_uazapi)
  ),
  -- A PRIMEIRA DE CADA CONVERSA EM CADA DIA. O id desempata duas no mesmo
  -- instante, para a resposta não mudar de uma chamada para outra.
  primeiras as (
    select distinct on (conversa_id, dia) id, conversa_id, dia, criado_em, enviado_por, enviado_por_id
      from candidatas
     order by conversa_id, dia, criado_em, id
  ),
  -- UMA A MAIS que o limite: é ela que diz se o limite cortou.
  escolhidas as (
    select p.*, c.advogado_id, ct.numero as contato_numero, ct.vantoro_cliente_id,
           row_number() over (order by p.criado_em, p.conversa_id, p.id) as n
      from primeiras p
      join conversas c  on c.id = p.conversa_id
      join contatos  ct on ct.id = c.contato_id
     where ct.numero not like 'grupo:%'
     order by p.criado_em, p.conversa_id, p.id
     limit v_limite + 1
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'conversa_id',        e.conversa_id,
           'linha_numero',       a.numero,
           'contato_numero',     e.contato_numero,
           'vantoro_cliente_id', e.vantoro_cliente_id::text,
           'dia',                e.dia,
           'primeira_em',        e.criado_em,
           -- O MESMO `ultima_quem` DO RESUMO (033): o nome de hoje de quem
           -- mandou pelo painel, ou o rótulo gravado ("WhatsApp").
           'quem',               coalesce(nullif(btrim(u.nome), ''), nullif(btrim(e.enviado_por), '')),
           -- E O MESMO `ultima_pelo_celular`.
           'pelo_celular',       (e.enviado_por_id is null and e.enviado_por = 'WhatsApp')
         ) order by e.n) filter (where e.n <= v_limite), '[]'::jsonb),
         count(*) > v_limite
    into v_linhas, v_cortou
    from escolhidas e
    left join advogados a on a.id = e.advogado_id
    left join usuarios  u on u.id = e.enviado_por_id;

  return jsonb_build_object('gerado_em', now(), 'desde', v_desde,
                            'completo', not coalesce(v_cortou, false), 'mensagens', v_linhas);
end
$fn$;

comment on function public.zorvin_mensagens_da_equipe(date, integer) is
  'Para cada conversa e cada dia (Brasília) desde p_desde, a primeira mensagem que uma '
  'pessoa da equipe mandou ao cliente (painel ou celular; sem aviso automático, Quazar, '
  'resposta fora do horário nem mensagem sem autor). Alimenta as tentativas de contato '
  'dos subsídios no Vantoro. Só a ponte chama (service_role): devolve todos os telefones.';

-- SÓ A PONTE, como o 030, o 031 e o 033.
revoke all on function public.zorvin_mensagens_da_equipe(date, integer) from public;
do $grant$
begin
  if exists (select 1 from pg_roles where rolname = 'anon') then
    execute 'revoke all on function public.zorvin_mensagens_da_equipe(date, integer) from anon';
  end if;
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'revoke all on function public.zorvin_mensagens_da_equipe(date, integer) from authenticated';
  end if;
  if exists (select 1 from pg_roles where rolname = 'service_role') then
    execute 'grant execute on function public.zorvin_mensagens_da_equipe(date, integer) to service_role';
  end if;
end
$grant$;

-- ------------------------------------------------------------
--  A CONFERÊNCIA
-- ------------------------------------------------------------
do $conf$
declare
  v_resp    jsonb;
  v_numeros text;
  v_falta   text;
begin
  drop table if exists zorvin_conferencia_074;
  create temp table zorvin_conferencia_074 (item text, resposta text);

  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    insert into zorvin_conferencia_074
    select 'só a ponte chama a função (quem entrou no painel não)',
           (not has_function_privilege('authenticated',
              'public.zorvin_mensagens_da_equipe(date, integer)', 'execute'))::text;
  end if;

  insert into zorvin_conferencia_074
  select 'uma versão só da função',
         ((select count(*) from pg_proc where proname = 'zorvin_mensagens_da_equipe'
                                          and pronamespace = 'public'::regnamespace) = 1)::text;

  if to_regclass('public.conversas') is null or to_regclass('public.mensagens') is null then
    insert into zorvin_conferencia_074 values ('sem as conversas', 'nenhuma — banco sem o Zorvin');
    return;
  end if;

  -- O QUE A FUNÇÃO LÊ, e de qual script vem. Faltando, ela quebraria na
  -- primeira chamada — melhor a conferência dizer qual rodar.
  select string_agg(f.falta, '; ' order by f.ordem) into v_falta
    from (values
      (1, 'automatica', 'rode o script 037 antes (mensagens.automatica)'),
      (2, 'pelo_quazar', 'rode o script 059 antes (mensagens.pelo_quazar)'),
      (3, 'apagada', 'rode o script de agosto sql/2026-08-apagar-mensagem.sql antes (mensagens.apagada)')
    ) f(ordem, coluna, falta)
   where not exists (select 1 from information_schema.columns
                      where table_schema = 'public' and table_name = 'mensagens'
                        and column_name = f.coluna);
  if to_regclass('public.zorvin_respostas_automaticas') is null then
    v_falta := concat_ws('; ', v_falta, 'rode o script 021 antes (zorvin_respostas_automaticas)');
  end if;
  if v_falta is not null then
    insert into zorvin_conferencia_074 values ('o que a função lê', v_falta);
    return;
  end if;

  begin
    -- COMO A PONTE CHAMA: com os dois argumentos, pelos nomes.
    v_resp := public.zorvin_mensagens_da_equipe(
                p_desde  => (now() at time zone 'America/Sao_Paulo')::date - 7,
                p_limite => 20000);
    select 'conversa-dia ' || count(*)
           || ' · pelo celular ' || count(*) filter (where (e ->> 'pelo_celular')::boolean)
      into v_numeros
      from jsonb_array_elements(v_resp -> 'mensagens') e;
    insert into zorvin_conferencia_074 values ('a função responde', 'sim');
    insert into zorvin_conferencia_074
    select 'toda linha traz o dia e a hora da primeira mensagem',
           (not exists (select 1 from jsonb_array_elements(v_resp -> 'mensagens') e
                         where e ->> 'dia' is null or e ->> 'primeira_em' is null))::text;
    insert into zorvin_conferencia_074 values ('os últimos 7 dias', v_numeros);
  exception when others then
    insert into zorvin_conferencia_074
    values ('a função responde', 'NÃO — ' || sqlerrm || ' (código ' || sqlstate || ')');
  end;
end
$conf$;

select * from zorvin_conferencia_074;
