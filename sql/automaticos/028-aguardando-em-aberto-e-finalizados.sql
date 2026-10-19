-- ============================================================
--  AGUARDANDO, EM ABERTO E FINALIZADOS — a situação de cada conversa, com
--  um protocolo por atendimento
--
--  >>> RODAR NO SUPABASE DO **ZORVIN** (o das conversas). <<<
--  A ponte aplica sozinha ao subir (sql/automaticos). Pode rodar de novo sem
--  medo — na ordem da pasta, como diz a regra 5 do LEIA-ME.
--
--  ------------------------------------------------------------
--  O PEDIDO
--
--  O Rodrigo pediu o que o DataCrazy faz nas conversas, "para facilitar a
--  organização": três abas que separam a lista.
--
--    AGUARDANDO   o cliente que a equipe ainda não atendeu
--    EM ABERTO    o que já foi atendido e não foi finalizado
--    FINALIZADOS  o que a equipe deu por encerrado
--
--  E a dinâmica dos protocolos: ao finalizar, o atendimento fecha; uma
--  mensagem nova do cliente (ou o "Reabrir") começa um atendimento novo, com
--  um protocolo novo. O protocolo é só da equipe — não vai para o cliente.
--
--  Decidido com ele:
--
--    - O "JÁ TRATEI" VIRA O "FINALIZAR". Um botão só, com a mesma checklist:
--      o registro do que foi tratado É a finalização, e o relatório continua
--      contando como sempre contou.
--    - O QUE JÁ EXISTE NÃO MUDA DE SENTIDO. Nas palavras dele: "o que está
--      aguardando continua aguardando, o que estiver como Já tratei fica como
--      finalizado. Caso o cliente tenha enviado mensagem após já ter sido
--      finalizado, então a conversa deve ficar aberta novamente, porém já com
--      a tratativa (finalizado), pois o cliente em si já foi tratado".
--    - AGUARDANDO E EM ABERTO SÃO ABAS SEPARADAS.
--
--  ------------------------------------------------------------
--  AS REGRAS, numa linha cada
--
--    1. AGUARDANDO é a conversa em que a equipe NUNCA AGIU: nenhuma mensagem
--       nossa (nem a do celular) e nenhum "Já tratei". É a régua do DataCrazy
--       ("sem o primeiro atendimento humano"), e a resposta automática fora
--       do horário não conta — ela não é gente, e mora fora de `mensagens`.
--    2. EM ABERTO é a conversa em que a equipe já agiu e que não está
--       finalizada. Inclui o cliente que escreveu DEPOIS de finalizado: ele
--       volta como "em aberto", com protocolo novo, e a finalização de antes
--       fica registrada — "o cliente em si já foi tratado".
--    3. FINALIZADA é a conversa cujo atendimento de agora foi fechado por um
--       "Já tratei", e em que o cliente não escreveu depois disso.
--    4. SÓ O CLIENTE REABRE SOZINHO. Mensagem da equipe numa conversa
--       finalizada não a reabre: é a descrição do DataCrazy ("uma nova
--       mensagem do cliente ou Reabrir"), e é o que deixa a atendente mandar
--       o "obrigado, até mais" depois de finalizar sem ter de finalizar de
--       novo.
--    5. A MENSAGEM QUE CHEGA ATRASADA COM DATA DE ANTES DA FINALIZAÇÃO NÃO
--       REABRE (a caixa de entrada reprocessando, a importação de
--       histórico). É a mesma régua da fila de espera (script 005): o que o
--       cliente escreveu antes do "Já tratei" está coberto por ele. Duas
--       réguas diriam coisas diferentes sobre a mesma mensagem.
--
--  ------------------------------------------------------------
--  O "REABRIR" TEM DOIS SENTIDOS, E OS DOIS EXISTEM
--
--    - REABRIR, para continuar: o pedido do DataCrazy. A conversa volta para
--      "em aberto" com um PROTOCOLO NOVO, e a finalização de antes continua
--      contando — ela aconteceu. A tela pede isto gravando `situacao =
--      'aberto'` numa conversa finalizada; o gatilho daqui de baixo abre o
--      atendimento novo. É a única mudança de situação que a tela pode pedir.
--    - DESFAZER A FINALIZAÇÃO, porque foi engano: é o "Voltar para a fila" de
--      sempre (marcar o clique como desfeito). Desfeito o clique, o MESMO
--      atendimento volta a ficar aberto — como se não tivesse sido
--      finalizado —, e o relatório deixa de contá-lo.
--
--  Reabrir para continuar NÃO desfaz o registro de ninguém, e é decisão: um
--  "Reabrir" que apagasse do relatório o "Já tratei" de verdade de uma
--  colega, só porque alguém quis voltar a falar com o cliente, seria trabalho
--  sumindo calado.
--
--  ------------------------------------------------------------
--  QUEM ESCREVE A SITUAÇÃO É O BANCO
--
--  `conversas.situacao` e `conversas.protocolo` ficam na própria conversa (a
--  lista filtra por elas, e o tempo real já leva a mudança a todo painel),
--  mas quem as escreve são os gatilhos: a mensagem que entra, o "Já tratei",
--  o clique desfeito. Um gatilho de guarda recusa (42501) qualquer outra
--  mudança feita pela tela — fora o "Reabrir". Uma tela que gravasse a
--  situação por conta própria faria o protocolo e a aba discordarem.
--
--  `zorvin_atendimentos` é o histórico: um por protocolo. Quem entrou LÊ (o
--  das conversas que vê) e não escreve nada.
--
--  ------------------------------------------------------------
--  O QUE JÁ EXISTE É MONTADO UMA VEZ, NA RODADA QUE CRIA A TABELA
--
--  Cada "Já tratei" não desfeito fecha um atendimento; o que o cliente
--  escreveu depois dele abre o seguinte. Os protocolos saem numerados pela
--  data em que cada atendimento começou. Rodar de novo NÃO renumera nada
--  (regra 5 do LEIA-ME): protocolo que muda de número deixa de ser
--  protocolo.
--
--  E ENQUANTO MONTA, NINGUÉM GRAVA MENSAGEM. As travas do começo seguram por
--  alguns segundos o webhook que chegar durante a montagem; sem elas, a
--  mensagem gravada no meio ficaria fora da montagem e sem gatilho nenhum que
--  a visse — o cliente novo daquele instante nasceria "em aberto".
--
--  ------------------------------------------------------------
--  O QUE ISTO NÃO FAZ, AINDA
--
--  A "contabilização" do DataCrazy — relatório por protocolo, tempo até a
--  primeira resposta, tempo até finalizar. Os campos para isso nascem aqui
--  (`aberto_em`, `primeira_resposta_em`, `finalizado_em`); a tela, não.
--
--  ------------------------------------------------------------
--  DEPENDE DE JÁ TER RODADO
--    as tabelas do Zorvin (`conversas`, `mensagens`), o 004 (a fila de
--    espera) e o 005 (o "Já tratei"). Sem eles — um banco limpo, a prova
--    51l-bis —, não faz nada e diz isso.
-- ============================================================

do $situacao$
declare
  v_criou boolean;
begin
  -- A TABELA DA CONFERÊNCIA NASCE ANTES DE TUDO — a lição do 006 e do 007.
  drop table if exists zorvin_conferencia_028;
  create temp table zorvin_conferencia_028 (item text, resposta text);

  -- ----------------------------------------------------------
  --  A GUARDA
  -- ----------------------------------------------------------
  if to_regclass('public.conversas') is null or to_regclass('public.mensagens') is null then
    insert into zorvin_conferencia_028 values ('sem as tabelas do Zorvin', 'nada a fazer aqui');
    raise notice 'Zorvin: sem as tabelas do Zorvin — o script 028 não tem o que criar.';
    return;
  end if;
  if not exists (select 1 from information_schema.columns
                  where table_schema = 'public' and table_name = 'conversas'
                    and column_name = 'esperando_desde') then
    insert into zorvin_conferencia_028
      values ('a fila de espera (script 004)', 'rode o script 004 antes deste');
    return;
  end if;
  if to_regclass('public.zorvin_tratamentos') is null then
    insert into zorvin_conferencia_028
      values ('o "Já tratei" (script 005)', 'rode o script 005 antes deste');
    return;
  end if;

  -- ----------------------------------------------------------
  --  AS TRAVAS — antes de mexer em qualquer linha, e nesta ordem
  --
  --  Os registros do "Já tratei" e as mensagens primeiro, a conversa depois:
  --  é a ordem em que o webhook as toca (a mensagem entra, e o gatilho dela
  --  mexe na conversa). Na ordem contrária, um webhook no meio do caminho
  --  esperaria por nós enquanto nós esperávamos por ele.
  -- ----------------------------------------------------------
  execute 'lock table public.zorvin_tratamentos in access exclusive mode';
  execute 'lock table public.mensagens in share row exclusive mode';
  execute 'lock table public.conversas in access exclusive mode';

  v_criou := to_regclass('public.zorvin_atendimentos') is null;

  -- ----------------------------------------------------------
  --  1. O NÚMERO DO PROTOCOLO
  --
  --  O ano em que o atendimento começou (no fuso do escritório), um traço e
  --  um número que só cresce: "2026-000123". O número não recomeça no ano
  --  novo — recomeçar exigiria uma trava a cada atendimento, e o ano na
  --  frente já diz de quando ele é.
  --
  --  SEIS DÍGITOS NO MÍNIMO, E NUNCA CORTADOS: `lpad` CORTA o texto maior que
  --  a largura, e o atendimento de número 1.000.000 viraria "100000" — o
  --  mesmo número de outro.
  -- ----------------------------------------------------------
  execute 'create sequence if not exists public.zorvin_protocolo_seq';

  execute $x$
    create or replace function public.zorvin_formatar_protocolo(p_numero bigint, p_quando timestamptz)
    returns text language sql stable set search_path = public as $f$
      select to_char(coalesce(p_quando, now()) at time zone 'America/Sao_Paulo', 'YYYY') || '-'
             || case when length(p_numero::text) < 6 then lpad(p_numero::text, 6, '0')
                     else p_numero::text end
    $f$
  $x$;

  execute $x$
    create or replace function public.zorvin_proximo_protocolo(p_quando timestamptz)
    returns text language sql volatile security definer set search_path = public as $f$
      select public.zorvin_formatar_protocolo(nextval('public.zorvin_protocolo_seq'), p_quando)
    $f$
  $x$;

  -- ----------------------------------------------------------
  --  2. OS ATENDIMENTOS — um por protocolo
  -- ----------------------------------------------------------
  execute $x$
    create table if not exists public.zorvin_atendimentos (
      id                   uuid primary key default gen_random_uuid(),
      protocolo            text not null unique,
      conversa_id          uuid not null references public.conversas(id) on delete cascade,
      aberto_em            timestamptz not null default now(),
      -- QUEM ABRIU: a mensagem do cliente, a da equipe (a conversa começada
      -- por nós), ou o "Reabrir" de alguém — e aí `aberto_por` diz quem.
      origem               text not null check (origem in ('cliente', 'equipe', 'reabertura')),
      aberto_por           uuid,
      primeira_resposta_em timestamptz,
      finalizado_em        timestamptz,
      finalizado_por       uuid
    )
  $x$;
  execute $x$
    comment on table public.zorvin_atendimentos is
      'Um atendimento por protocolo. Abre com a primeira mensagem da conversa, '
      'com a mensagem do cliente depois de uma finalização, ou com o Reabrir; '
      'fecha com o "Já tratei". Escrito só pelos gatilhos do script 028 — quem '
      'entrou lê os das conversas que vê.'
  $x$;
  execute 'create index if not exists zorvin_atendimentos_conversa
             on public.zorvin_atendimentos (conversa_id, aberto_em desc)';

  -- ----------------------------------------------------------
  --  3. A SITUAÇÃO NA CONVERSA, e o clique ligado ao atendimento
  --
  --  'aberto' é o PADRÃO da coluna: a conversa que nasce pela "Nova
  --  conversa" do painel, ainda sem mensagem, é a equipe começando — e não
  --  um cliente esperando. A mensagem do cliente que cria a conversa pela
  --  ponte passa pelo gatilho na mesma gravação, e ele a põe em
  --  'aguardando'.
  -- ----------------------------------------------------------
  execute $x$
    alter table public.conversas
      add column if not exists situacao text not null default 'aberto'
        check (situacao in ('aguardando', 'aberto', 'finalizado')),
      add column if not exists protocolo text
  $x$;
  execute $x$
    comment on column public.conversas.situacao is
      'aguardando (a equipe nunca agiu), aberto (já agiu e não finalizou) ou '
      'finalizado (o atendimento de agora foi fechado por um "Já tratei"). '
      'Escrita pelos gatilhos do script 028; a tela só pode pedir o Reabrir.'
  $x$;
  execute $x$
    comment on column public.conversas.protocolo is
      'O protocolo do atendimento de agora (zorvin_atendimentos). Nulo na '
      'conversa que ainda não tem mensagem nenhuma.'
  $x$;
  execute 'create index if not exists conversas_situacao
             on public.conversas (advogado_id, situacao)';

  execute $x$
    alter table public.zorvin_tratamentos
      add column if not exists atendimento_id uuid
        references public.zorvin_atendimentos(id) on delete set null
  $x$;
  execute 'create index if not exists zorvin_tratamentos_atendimento
             on public.zorvin_tratamentos (atendimento_id)';

  -- ----------------------------------------------------------
  --  4. AS CONTAS DE APOIO
  -- ----------------------------------------------------------

  -- A EQUIPE JÁ AGIU NESTA CONVERSA? Uma mensagem nossa (do painel ou do
  -- celular) ou um "Já tratei" que não foi desfeito. É a pergunta que separa
  -- "aguardando" de "em aberto" — a regra 1.
  execute $x$
    create or replace function public.zorvin_aberta_ou_aguardando(p_conversa uuid)
    returns text language sql stable security definer set search_path = public as $f$
      select case
               when exists (select 1 from public.mensagens m
                             where m.conversa_id = p_conversa and m.origem = 'advogado')
                 or exists (select 1 from public.zorvin_tratamentos t
                             where t.conversa_id = p_conversa and t.desfeito_em is null)
               then 'aberto' else 'aguardando' end
    $f$
  $x$;

  -- ABRE UM ATENDIMENTO e devolve o id e o protocolo. NÃO mexe na conversa:
  -- quem chama grava a situação junto, numa gravação só — e o gatilho de
  -- guarda, que roda DENTRO da gravação da conversa, não pode gravá-la de
  -- novo.
  execute $x$
    create or replace function public.zorvin_atendimento_abre(
      p_conversa uuid, p_quando timestamptz, p_origem text, p_por uuid, p_resposta timestamptz,
      out o_id uuid, out o_protocolo text)
    language plpgsql volatile security definer set search_path = public as $f$
    begin
      insert into public.zorvin_atendimentos
             (protocolo, conversa_id, aberto_em, origem, aberto_por, primeira_resposta_em)
      values (public.zorvin_proximo_protocolo(p_quando), p_conversa, p_quando, p_origem, p_por, p_resposta)
      returning id, protocolo into o_id, o_protocolo;
    end
    $f$
  $x$;

  -- ----------------------------------------------------------
  --  5. OS ATENDIMENTOS DE UMA CONVERSA, contados do zero
  --
  --  A montagem de quem já existia, e a de uma conversa que por algum motivo
  --  ficou sem nenhum (ver `zorvin_recontar_situacao`). Devolve os
  --  atendimentos em ordem, cada um com os cliques que o fecharam — e NÃO
  --  grava nada: quem chama numera e grava.
  --
  --  As mesmas regras dos gatilhos, aplicadas ao que já aconteceu:
  --    - o primeiro atendimento começa na primeira mensagem, de quem for;
  --    - um "Já tratei" fecha o atendimento de agora; outro clique logo em
  --      seguida, sem mensagem do cliente no meio, é do MESMO atendimento;
  --    - depois de fechado, só a mensagem do cliente abre o seguinte.
  -- ----------------------------------------------------------
  execute $x$
    create or replace function public.zorvin_atendimento_ciclos(p_conversa uuid)
    returns table (aberto_em timestamptz, origem text, primeira_resposta_em timestamptz,
                   finalizado_em timestamptz, finalizado_por uuid, cliques timestamptz[])
    language plpgsql stable security definer set search_path = public as $f$
    declare
      k          record;
      v_tem      boolean := false;   -- já há um atendimento montado, fechado
      v_aberto   timestamptz;
      v_origem   text;
      v_fim      timestamptz;
      v_por      uuid;
      v_cliques  timestamptz[];
      v_t        timestamptz;
      v_o        text;
    begin
      for k in
        select t.quando, (array_agg(t.quem))[1] as quem
          from public.zorvin_tratamentos t
         where t.conversa_id = p_conversa and t.desfeito_em is null
         group by t.quando
         order by t.quando
      loop
        if not v_tem then
          select m.criado_em, m.origem into v_t, v_o
            from public.mensagens m
           where m.conversa_id = p_conversa and m.origem in ('contato', 'advogado')
             and m.criado_em <= k.quando
           order by m.criado_em
           limit 1;
          v_aberto  := coalesce(v_t, k.quando);
          v_origem  := case when v_o = 'contato' then 'cliente' else 'equipe' end;
          v_fim     := k.quando;
          v_por     := k.quem;
          v_cliques := array[k.quando];
          v_tem     := true;
        else
          select min(m.criado_em) into v_t
            from public.mensagens m
           where m.conversa_id = p_conversa and m.origem = 'contato'
             and m.criado_em > v_fim and m.criado_em <= k.quando;
          if v_t is null then
            v_cliques := v_cliques || k.quando;
          else
            aberto_em := v_aberto; origem := v_origem; finalizado_em := v_fim;
            finalizado_por := v_por; cliques := v_cliques;
            primeira_resposta_em := (select min(m.criado_em) from public.mensagens m
                                      where m.conversa_id = p_conversa and m.origem = 'advogado'
                                        and m.criado_em >= v_aberto and m.criado_em <= v_fim);
            return next;
            v_aberto  := v_t;
            v_origem  := 'cliente';
            v_fim     := k.quando;
            v_por     := k.quem;
            v_cliques := array[k.quando];
          end if;
        end if;
      end loop;

      if v_tem then
        aberto_em := v_aberto; origem := v_origem; finalizado_em := v_fim;
        finalizado_por := v_por; cliques := v_cliques;
        primeira_resposta_em := (select min(m.criado_em) from public.mensagens m
                                  where m.conversa_id = p_conversa and m.origem = 'advogado'
                                    and m.criado_em >= v_aberto and m.criado_em <= v_fim);
        return next;
        -- O QUE O CLIENTE ESCREVEU DEPOIS DO ÚLTIMO "JÁ TRATEI" abre o
        -- atendimento de agora — "a conversa deve ficar aberta novamente".
        select min(m.criado_em) into v_t
          from public.mensagens m
         where m.conversa_id = p_conversa and m.origem = 'contato' and m.criado_em > v_fim;
        if v_t is not null then
          aberto_em := v_t; origem := 'cliente'; finalizado_em := null;
          finalizado_por := null; cliques := null;
          primeira_resposta_em := (select min(m.criado_em) from public.mensagens m
                                    where m.conversa_id = p_conversa and m.origem = 'advogado'
                                      and m.criado_em >= v_t);
          return next;
        end if;
      else
        -- SEM "JÁ TRATEI" NENHUM: um atendimento só, aberto, desde a
        -- primeira mensagem. Sem mensagem, nenhum.
        select m.criado_em, m.origem into v_t, v_o
          from public.mensagens m
         where m.conversa_id = p_conversa and m.origem in ('contato', 'advogado')
         order by m.criado_em
         limit 1;
        if v_t is not null then
          aberto_em := v_t;
          origem := case when v_o = 'contato' then 'cliente' else 'equipe' end;
          finalizado_em := null; finalizado_por := null; cliques := null;
          primeira_resposta_em := (select min(m.criado_em) from public.mensagens m
                                    where m.conversa_id = p_conversa and m.origem = 'advogado'
                                      and m.criado_em >= v_t);
          return next;
        end if;
      end if;
      return;
    end
    $f$
  $x$;

  -- ----------------------------------------------------------
  --  6. A MONTAGEM DO QUE JÁ EXISTE — só na rodada que cria a tabela
  --
  --  Primeiro todos os atendimentos de todas as conversas, numa tabela de
  --  passagem; depois a numeração, pela data em que cada um começou. Assim o
  --  protocolo mais baixo é o atendimento mais antigo, e não o da conversa
  --  que por acaso foi lida primeiro.
  -- ----------------------------------------------------------
  if v_criou then
    create temp table zorvin_ciclos_028 on commit drop as
    select gen_random_uuid() as id, c.id as conversa_id, x.*
      from public.conversas c
     cross join lateral public.zorvin_atendimento_ciclos(c.id) x;

    insert into public.zorvin_atendimentos
           (id, protocolo, conversa_id, aberto_em, origem, primeira_resposta_em, finalizado_em, finalizado_por)
    select z.id, public.zorvin_formatar_protocolo(z.n, z.aberto_em), z.conversa_id, z.aberto_em,
           z.origem, z.primeira_resposta_em, z.finalizado_em, z.finalizado_por
      from (select y.*, row_number() over (order by y.aberto_em, y.conversa_id) as n
              from zorvin_ciclos_028 y) z;

    -- A SEQUÊNCIA CONTINUA DE ONDE A MONTAGEM PAROU.
    if exists (select 1 from zorvin_ciclos_028) then
      perform setval('public.zorvin_protocolo_seq', (select count(*) from zorvin_ciclos_028));
    end if;

    update public.zorvin_tratamentos t
       set atendimento_id = z.id
      from zorvin_ciclos_028 z
     where z.cliques is not null
       and t.conversa_id = z.conversa_id
       and t.desfeito_em is null
       and t.quando = any (z.cliques);

    -- A FINALIZADA QUE FICOU NA FILA DE ESPERA (o "Já tratei" de uma conversa
    -- respondida nunca gravou `tratada_em`, e uma mensagem atrasada do
    -- cliente podia tê-la posto na fila depois) sai dela no conserto do fim
    -- (13), pela mesma recontagem de toda rodada — uma escrita só da regra.
    update public.conversas c
       set protocolo = a.protocolo,
           situacao = case when a.finalizado_em is not null then 'finalizado'
                           else public.zorvin_aberta_ou_aguardando(c.id) end
      from (select distinct on (y.conversa_id) y.conversa_id, y.protocolo, y.finalizado_em
              from public.zorvin_atendimentos y
             order by y.conversa_id, y.aberto_em desc) a
     where a.conversa_id = c.id;
  end if;

  -- ----------------------------------------------------------
  --  7. O GATILHO DAS MENSAGENS
  --
  --  A mensagem do cliente abre o primeiro atendimento ("aguardando", se a
  --  equipe nunca agiu), ou o seguinte, se chegou depois da finalização. A
  --  da equipe abre o primeiro (a conversa começada por nós), anota a
  --  primeira resposta e tira de "aguardando" — e numa conversa finalizada
  --  não faz nada (regra 4).
  --
  --  A CONVERSA É TRAVADA (`for update`) antes de olhar o protocolo: duas
  --  mensagens do mesmo cliente no mesmo segundo, por dois webhooks,
  --  abririam dois atendimentos sem a trava.
  --
  --  O CORPO VIVE NUM `exception when others`, como o do 004 e o do 017: um
  --  gatilho que estoura derruba o INSERT da mensagem, e perder a mensagem
  --  do cliente é o pior desfecho deste sistema. Perder a aba certa é um
  --  incômodo — e a próxima mensagem conserta.
  -- ----------------------------------------------------------
  execute $x$
    create or replace function public.zorvin_situacao_da_mensagem()
    returns trigger language plpgsql security definer set search_path = public as $f$
    declare
      v_prot    text;
      v_sit     text;
      v_id      uuid;
      v_aberto  timestamptz;
      v_fim     timestamptz;
      v_resp    timestamptz;
      v_novo    text;
    begin
      begin
        if new.origem is null or new.origem not in ('contato', 'advogado') then
          return null;
        end if;

        select c.protocolo, c.situacao into v_prot, v_sit
          from public.conversas c where c.id = new.conversa_id for update;
        if not found then return null; end if;

        select a.id, a.aberto_em, a.finalizado_em, a.primeira_resposta_em
          into v_id, v_aberto, v_fim, v_resp
          from public.zorvin_atendimentos a where a.protocolo = v_prot;

        if new.origem = 'contato' then
          if v_id is null then
            select o_protocolo into v_novo
              from public.zorvin_atendimento_abre(new.conversa_id, new.criado_em, 'cliente', null, null);
            update public.conversas
               set situacao = public.zorvin_aberta_ou_aguardando(new.conversa_id), protocolo = v_novo
             where id = new.conversa_id;
          elsif v_fim is not null and new.criado_em > v_fim then
            select o_protocolo into v_novo
              from public.zorvin_atendimento_abre(new.conversa_id, new.criado_em, 'cliente', null, null);
            update public.conversas set situacao = 'aberto', protocolo = v_novo
             where id = new.conversa_id;
          end if;
        else
          if v_id is null then
            select o_protocolo into v_novo
              from public.zorvin_atendimento_abre(new.conversa_id, new.criado_em, 'equipe', null, new.criado_em);
            update public.conversas set situacao = 'aberto', protocolo = v_novo
             where id = new.conversa_id;
          elsif v_fim is null then
            if v_resp is null and new.criado_em >= v_aberto then
              update public.zorvin_atendimentos set primeira_resposta_em = new.criado_em where id = v_id;
            end if;
            if v_sit is distinct from 'aberto' then
              update public.conversas set situacao = 'aberto' where id = new.conversa_id;
            end if;
          end if;
        end if;
      exception when others then
        raise warning 'Zorvin: a situação da conversa não acompanhou a mensagem (%): %', sqlstate, sqlerrm;
      end;
      return null;
    end
    $f$
  $x$;
  execute 'revoke all on function public.zorvin_situacao_da_mensagem() from public';
  execute 'drop trigger if exists zorvin_situacao_da_mensagem on public.mensagens';
  execute 'create trigger zorvin_situacao_da_mensagem
             after insert on public.mensagens
             for each row execute function public.zorvin_situacao_da_mensagem()';

  -- ----------------------------------------------------------
  --  8. O "JÁ TRATEI" FINALIZA
  --
  --  ANTES de gravar o clique: liga a linha ao atendimento de agora e o
  --  fecha. Um clique são várias linhas (uma por assunto) com o mesmo
  --  `quando`; a primeira fecha, as outras encontram o atendimento fechado e
  --  só se ligam a ele. Um segundo clique numa conversa já finalizada também
  --  só se liga.
  --
  --  E FINALIZAR TIRA DA FILA DE ESPERA: a conversa finalizada não pode
  --  continuar dizendo "esperando há 5 dias" — a aba e a fila diriam coisas
  --  opostas. É o que o "Já tratei" sempre fez na conversa que esperava;
  --  agora vale em toda finalização, e a finalização passa a ser a nossa
  --  última ação também na conta da espera (`tratada_em`).
  --
  --  QUEM FINALIZOU sai da sessão, como o `quem` do 020 — o 020 o escreve
  --  depois deste gatilho (a ordem é a do nome), com o mesmo valor.
  --
  --  Se a gravação do clique for recusada depois (a regra de acesso do 020
  --  confere a conversa DEPOIS dos gatilhos), tudo isto volta junto: é uma
  --  gravação só.
  -- ----------------------------------------------------------
  execute $x$
    create or replace function public.zorvin_situacao_do_clique()
    returns trigger language plpgsql security definer set search_path = public as $f$
    declare
      v_prot    text;
      v_id      uuid;
      v_aberto  timestamptz;
      v_fim     timestamptz;
      v_quando  timestamptz;
      v_quem    uuid;
    begin
      begin
        -- DENTRO DO BLOCO, e não na declaração: o `exception` lá de baixo
        -- não protege a declaração (a lição do 020).
        v_quando := coalesce(new.quando, now());
        v_quem := coalesce(auth.uid(), new.quem);
        if new.desfeito_em is not null then return new; end if;

        select c.protocolo into v_prot
          from public.conversas c where c.id = new.conversa_id for update;
        if not found then return new; end if;

        select a.id, a.aberto_em, a.finalizado_em into v_id, v_aberto, v_fim
          from public.zorvin_atendimentos a where a.protocolo = v_prot;

        if v_id is null then
          -- A CONVERSA SEM ATENDIMENTO NENHUM (sem mensagem): o clique abre e
          -- fecha um, para o registro ter onde se prender.
          select o_id, o_protocolo into v_id, v_prot
            from public.zorvin_atendimento_abre(new.conversa_id, v_quando, 'equipe', null, null);
          v_aberto := v_quando;
        end if;

        new.atendimento_id := v_id;

        if v_fim is null then
          -- O RELÓGIO DE QUEM ESCREVEU pode estar um tico à frente do banco:
          -- o fim nunca vem antes do começo.
          update public.zorvin_atendimentos
             set finalizado_em = greatest(v_quando, v_aberto), finalizado_por = v_quem
           where id = v_id;
          update public.conversas
             set situacao = 'finalizado', protocolo = v_prot,
                 tratada_em = now(), esperando_desde = null
           where id = new.conversa_id;
        end if;
      exception when others then
        raise warning 'Zorvin: o "Já tratei" não finalizou a conversa (%): %', sqlstate, sqlerrm;
      end;
      return new;
    end
    $f$
  $x$;
  execute 'revoke all on function public.zorvin_situacao_do_clique() from public';
  execute 'drop trigger if exists zorvin_situacao_do_clique on public.zorvin_tratamentos';
  execute 'create trigger zorvin_situacao_do_clique
             before insert on public.zorvin_tratamentos
             for each row execute function public.zorvin_situacao_do_clique()';

  -- ----------------------------------------------------------
  --  9. O CLIQUE DESFEITO REABRE O MESMO ATENDIMENTO
  --
  --  É o "foi engano": o clique marcado como desfeito deixa de fechar o
  --  atendimento. Sobrou outro clique nele (duas pessoas finalizaram juntas)?
  --  Então continua fechado, pelo mais antigo que sobrou. Não sobrou nenhum?
  --  Volta a ficar aberto, com o MESMO protocolo — e a conversa volta para
  --  "em aberto" ou "aguardando", pela regra 1.
  --
  --  SÓ O ATENDIMENTO DE AGORA REABRE: desfazer o clique de um atendimento
  --  que já tem outro depois dele não pode deixar dois abertos.
  -- ----------------------------------------------------------
  execute $x$
    create or replace function public.zorvin_situacao_desfeita()
    returns trigger language plpgsql security definer set search_path = public as $f$
    declare
      v_prot  text;
      v_id    uuid;
      v_fim   timestamptz;
      v_q     timestamptz;
      v_quem  uuid;
    begin
      begin
        if old.desfeito_em is not null or new.desfeito_em is null then return null; end if;

        select c.protocolo into v_prot
          from public.conversas c where c.id = new.conversa_id for update;
        select a.id, a.finalizado_em into v_id, v_fim
          from public.zorvin_atendimentos a where a.protocolo = v_prot;
        if v_id is null or v_fim is null or new.atendimento_id is distinct from v_id then
          return null;
        end if;

        select t.quando, t.quem into v_q, v_quem
          from public.zorvin_tratamentos t
         where t.atendimento_id = v_id and t.desfeito_em is null
         order by t.quando
         limit 1;

        if v_q is not null then
          update public.zorvin_atendimentos set finalizado_em = v_q, finalizado_por = v_quem
           where id = v_id and finalizado_em is distinct from v_q;
        else
          update public.zorvin_atendimentos set finalizado_em = null, finalizado_por = null
           where id = v_id;
          update public.conversas
             set situacao = public.zorvin_aberta_ou_aguardando(new.conversa_id)
           where id = new.conversa_id;
        end if;
      exception when others then
        raise warning 'Zorvin: o "Já tratei" desfeito não reabriu a conversa (%): %', sqlstate, sqlerrm;
      end;
      return null;
    end
    $f$
  $x$;
  execute 'revoke all on function public.zorvin_situacao_desfeita() from public';
  execute 'drop trigger if exists zorvin_situacao_desfeita on public.zorvin_tratamentos';
  execute 'create trigger zorvin_situacao_desfeita
             after update of desfeito_em on public.zorvin_tratamentos
             for each row execute function public.zorvin_situacao_desfeita()';

  -- ----------------------------------------------------------
  --  10. A GUARDA DA SITUAÇÃO — e o "Reabrir"
  --
  --  Só dispara quando a gravação MENCIONA `situacao` ou `protocolo` (`before
  --  update of`): a prévia, a ordem, as não lidas e a espera, que mexem na
  --  conversa a cada mensagem, nem passam por aqui.
  --
  --  PASSAM: a mudança feita pelos gatilhos deste script (eles gravam a
  --  conversa de dentro de outro gatilho, e `pg_trigger_depth()` é maior que
  --  1) e a feita sem ninguém entrado (a ponte, o editor da Supabase, a
  --  montagem: `auth.uid()` nulo).
  --
  --  DA TELA, SÓ O REABRIR: `situacao = 'aberto'` numa conversa finalizada
  --  abre um atendimento novo, com protocolo novo, em nome de quem pediu. A
  --  regra de acesso de `conversas` já decidiu se a pessoa vê a conversa —
  --  quem não vê grava zero linhas, e a tela diz que o banco não deixou.
  --  Qualquer outra mudança de situação ou de protocolo pela tela é recusada.
  -- ----------------------------------------------------------
  execute $x$
    create or replace function public.zorvin_situacao_guardada()
    returns trigger language plpgsql security definer set search_path = public as $f$
    declare
      v_prot text;
    begin
      if new.situacao is not distinct from old.situacao
         and new.protocolo is not distinct from old.protocolo then
        return new;
      end if;
      if pg_trigger_depth() > 1 or auth.uid() is null then
        return new;
      end if;
      if old.situacao = 'finalizado' and new.situacao = 'aberto'
         and new.protocolo is not distinct from old.protocolo then
        select o_protocolo into v_prot
          from public.zorvin_atendimento_abre(new.id, now(), 'reabertura', auth.uid(), null);
        new.protocolo := v_prot;
        return new;
      end if;
      raise exception 'A situação da conversa é do banco: ela muda com as mensagens, com o “Já tratei” e com o Reabrir.'
        using errcode = '42501';
    end
    $f$
  $x$;
  execute 'revoke all on function public.zorvin_situacao_guardada() from public';
  execute 'drop trigger if exists zorvin_situacao_guardada on public.conversas';
  execute 'create trigger zorvin_situacao_guardada
             before update of situacao, protocolo on public.conversas
             for each row execute function public.zorvin_situacao_guardada()';

  -- ----------------------------------------------------------
  --  11. RECONTAR UMA CONVERSA — para a ponte, depois de juntar duas
  --
  --  Juntar conversas MUDA mensagens de casa (um UPDATE, e não um INSERT), e
  --  nenhum gatilho de mensagem vê isso. A ponte chama esta função para a
  --  conversa que ficou. Ela nunca renumera nada:
  --    - sem atendimento nenhum, monta do zero, pela conta da instalação;
  --    - finalizada, e com mensagem do cliente depois da finalização (veio
  --      da outra conversa), abre o atendimento seguinte;
  --    - aberta, completa a primeira resposta e acerta "aguardando".
  --  Rodar de novo não muda nada.
  -- ----------------------------------------------------------
  execute $x$
    create or replace function public.zorvin_recontar_situacao(p_conversa uuid)
    returns text language plpgsql volatile security definer set search_path = public as $f$
    declare
      v_prot    text;
      v_id      uuid;
      v_aberto  timestamptz;
      v_fim     timestamptz;
      v_resp    timestamptz;
      v_t       timestamptz;
      v_sit     text;
      z         record;
    begin
      perform 1 from public.conversas c where c.id = p_conversa for update;
      if not found then return null; end if;

      -- O ATENDIMENTO DE AGORA É O MAIS RECENTE da conversa, e não o que a
      -- conversa diz ter: é justamente quando os dois discordam que esta
      -- função é chamada.
      select a.id, a.protocolo, a.aberto_em, a.finalizado_em, a.primeira_resposta_em
        into v_id, v_prot, v_aberto, v_fim, v_resp
        from public.zorvin_atendimentos a
       where a.conversa_id = p_conversa
       order by a.aberto_em desc, a.protocolo desc
       limit 1;

      if v_id is null then
        for z in select * from public.zorvin_atendimento_ciclos(p_conversa) loop
          select o_id, o_protocolo into v_id, v_prot
            from public.zorvin_atendimento_abre(p_conversa, z.aberto_em, z.origem, null, z.primeira_resposta_em);
          update public.zorvin_atendimentos
             set finalizado_em = z.finalizado_em, finalizado_por = z.finalizado_por
           where id = v_id;
          if z.cliques is not null then
            update public.zorvin_tratamentos set atendimento_id = v_id
             where conversa_id = p_conversa and desfeito_em is null and quando = any (z.cliques);
          end if;
          v_fim := z.finalizado_em;
        end loop;
        if v_id is null then
          -- SEM MENSAGEM NEM CLIQUE: não há atendimento a montar, e um
          -- protocolo que aponta para o nada sai.
          update public.conversas set protocolo = null
           where id = p_conversa and protocolo is not null;
          return (select c.situacao from public.conversas c where c.id = p_conversa);
        end if;
      elsif v_fim is not null then
        select min(m.criado_em) into v_t
          from public.mensagens m
         where m.conversa_id = p_conversa and m.origem = 'contato' and m.criado_em > v_fim;
        if v_t is not null then
          select o_id, o_protocolo into v_id, v_prot
            from public.zorvin_atendimento_abre(p_conversa, v_t, 'cliente', null,
                   (select min(m.criado_em) from public.mensagens m
                     where m.conversa_id = p_conversa and m.origem = 'advogado' and m.criado_em >= v_t));
          v_fim := null;
        end if;
      elsif v_resp is null then
        update public.zorvin_atendimentos
           set primeira_resposta_em = (select min(m.criado_em) from public.mensagens m
                                        where m.conversa_id = p_conversa and m.origem = 'advogado'
                                          and m.criado_em >= v_aberto)
         where id = v_id;
      end if;

      v_sit := case when v_fim is not null then 'finalizado'
                    else public.zorvin_aberta_ou_aguardando(p_conversa) end;
      update public.conversas set situacao = v_sit, protocolo = v_prot
       where id = p_conversa
         and (situacao is distinct from v_sit or protocolo is distinct from v_prot);
      -- E A FINALIZADA FICA FORA DA FILA DE ESPERA, pela régua do clique.
      if v_fim is not null then
        update public.conversas
           set tratada_em = greatest(tratada_em, v_fim), esperando_desde = null
         where id = p_conversa and esperando_desde is not null;
      end if;
      return v_sit;
    end
    $f$
  $x$;

  -- ----------------------------------------------------------
  --  12. QUEM ALCANÇA O QUÊ
  --
  --  Quem entrou LÊ os atendimentos das conversas que vê — a regra pergunta
  --  às próprias `conversas`, e a permissão por telefone e departamento vale
  --  lá dentro. E não escreve nenhum: a tabela nasce aberta para quem entrou
  --  na Supabase (a herança das tabelas novas), e por isso tudo é tirado
  --  antes de a leitura ser devolvida.
  --
  --  As funções nascem executáveis por todo mundo (`public`), e são tiradas
  --  de lá: só a ponte chama a recontagem.
  -- ----------------------------------------------------------
  execute 'alter table public.zorvin_atendimentos enable row level security';
  execute 'drop policy if exists zorvin_atendimentos_leitura on public.zorvin_atendimentos';
  execute 'create policy zorvin_atendimentos_leitura on public.zorvin_atendimentos
             for select to authenticated
             using (exists (select 1 from public.conversas c
                             where c.id = zorvin_atendimentos.conversa_id))';
  execute 'revoke all on table public.zorvin_atendimentos from public';
  execute 'revoke all on sequence public.zorvin_protocolo_seq from public';
  if exists (select 1 from pg_roles where rolname = 'anon') then
    execute 'revoke all on table public.zorvin_atendimentos from anon';
    execute 'revoke all on sequence public.zorvin_protocolo_seq from anon';
  end if;
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'revoke all on table public.zorvin_atendimentos from authenticated';
    execute 'revoke all on sequence public.zorvin_protocolo_seq from authenticated';
    execute 'grant select on table public.zorvin_atendimentos to authenticated';
  end if;
  if exists (select 1 from pg_roles where rolname = 'service_role') then
    execute 'grant all on table public.zorvin_atendimentos to service_role';
  end if;

  execute 'revoke all on function public.zorvin_formatar_protocolo(bigint, timestamptz) from public';
  execute 'revoke all on function public.zorvin_proximo_protocolo(timestamptz) from public';
  execute 'revoke all on function public.zorvin_aberta_ou_aguardando(uuid) from public';
  execute 'revoke all on function public.zorvin_atendimento_abre(uuid, timestamptz, text, uuid, timestamptz) from public';
  execute 'revoke all on function public.zorvin_atendimento_ciclos(uuid) from public';
  execute 'revoke all on function public.zorvin_recontar_situacao(uuid) from public';
  if exists (select 1 from pg_roles where rolname = 'service_role') then
    execute 'grant execute on function public.zorvin_recontar_situacao(uuid) to service_role';
  end if;

  -- ----------------------------------------------------------
  --  12b. QUANTAS EM CADA ABA — numa pergunta só
  --
  --  O número ao lado de cada aba do painel. `security invoker`: conta só o
  --  que quem pergunta enxerga, pela regra de acesso de `conversas`. E fica de
  --  fora o que a lista também não mostra — a arquivada (mora na pasta dela)
  --  e a conversa sem mensagem nenhuma —, senão o número diria uma coisa e a
  --  lista outra. Três consultas do painel, uma por aba, seriam três idas à
  --  rede para a mesma pergunta.
  --
  --  `arquivada` vem por `to_jsonb`: a coluna foi criada à mão no começo do
  --  projeto e não está em script nenhum, e uma função `sql` que a citasse
  --  pelo nome não seria criada num banco sem ela.
  -- ----------------------------------------------------------
  execute $x$
    create or replace function public.zorvin_contar_situacoes(p_telefone uuid)
    returns jsonb language sql stable security invoker set search_path = public as $f$
      select jsonb_build_object(
               'aguardando', count(*) filter (where c.situacao = 'aguardando'),
               'aberto',     count(*) filter (where c.situacao = 'aberto'),
               'finalizado', count(*) filter (where c.situacao = 'finalizado'))
        from public.conversas c
       where c.advogado_id = p_telefone
         and not coalesce((to_jsonb(c) ->> 'arquivada')::boolean, false)
         and exists (select 1 from public.mensagens m where m.conversa_id = c.id)
    $f$
  $x$;
  execute 'revoke all on function public.zorvin_contar_situacoes(uuid) from public';
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'grant execute on function public.zorvin_contar_situacoes(uuid) to authenticated';
  end if;

  -- ----------------------------------------------------------
  --  13. QUEM FICOU FORA DA REGRA — uma pergunta só, para o conserto e
  --      para a conferência
  --
  --  Fora da regra é: conversa com mensagem e sem atendimento; o atendimento
  --  de agora não é o mais recente; a aba não é a que o atendimento diz; a
  --  conversa finalizada com mensagem do cliente depois da finalização (a
  --  reabertura que não aconteceu); ou a finalizada que continua na fila de
  --  espera.
  --
  --  Depois da montagem, ninguém fica. Numa rodada de novo, pode ter ficado
  --  alguém (um gatilho que tropeçou e se calou, para não perder a
  --  mensagem): a recontagem o acerta, e não renumera ninguém.
  -- ----------------------------------------------------------
  execute $x$
    create or replace function public.zorvin_situacao_fora_da_regra(p_conversa uuid)
    returns boolean language sql stable security definer set search_path = public as $f$
      select case
               when a.id is null then
                 c.protocolo is not null
                 or exists (select 1 from public.mensagens m
                             where m.conversa_id = c.id and m.origem in ('contato', 'advogado'))
               else
                 a.conversa_id <> c.id
                 or exists (select 1 from public.zorvin_atendimentos b
                             where b.conversa_id = c.id and b.aberto_em > a.aberto_em)
                 or (a.finalizado_em is not null and c.situacao <> 'finalizado')
                 or (a.finalizado_em is null
                     and c.situacao <> public.zorvin_aberta_ou_aguardando(c.id))
                 or (a.finalizado_em is not null
                     and exists (select 1 from public.mensagens m
                                  where m.conversa_id = c.id and m.origem = 'contato'
                                    and m.criado_em > a.finalizado_em))
                 or (a.finalizado_em is not null and c.esperando_desde is not null)
             end
        from public.conversas c
        left join public.zorvin_atendimentos a on a.protocolo = c.protocolo
       where c.id = p_conversa
    $f$
  $x$;
  execute 'revoke all on function public.zorvin_situacao_fora_da_regra(uuid) from public';

  perform public.zorvin_recontar_situacao(c.id)
     from public.conversas c
    where public.zorvin_situacao_fora_da_regra(c.id);

  -- ----------------------------------------------------------
  --  A CONFERÊNCIA
  -- ----------------------------------------------------------
  insert into zorvin_conferencia_028
  select 'conversas por situação',
         'aguardando ' || count(*) filter (where situacao = 'aguardando')
         || ' · em aberto ' || count(*) filter (where situacao = 'aberto')
         || ' · finalizadas ' || count(*) filter (where situacao = 'finalizado')
    from public.conversas
  union all
  select 'protocolos', (select count(*) from public.zorvin_atendimentos)::text
  union all
  select 'a situação de toda conversa bate com o protocolo dela',
         (select case when count(*) = 0 then 'true'
                      else 'NÃO — ' || count(*) || ' conversa(s) fora da regra' end
            from public.conversas c
           where public.zorvin_situacao_fora_da_regra(c.id))
  union all
  select 'a mensagem acompanha a situação',
         exists (select 1 from pg_trigger
                  where tgname = 'zorvin_situacao_da_mensagem'
                    and tgrelid = 'public.mensagens'::regclass)::text
  union all
  select 'o “Já tratei” finaliza',
         exists (select 1 from pg_trigger
                  where tgname = 'zorvin_situacao_do_clique'
                    and tgrelid = 'public.zorvin_tratamentos'::regclass)::text
  union all
  select 'a tela não escreve a situação por fora',
         exists (select 1 from pg_trigger
                  where tgname = 'zorvin_situacao_guardada'
                    and tgrelid = 'public.conversas'::regclass)::text;
end
$situacao$;

-- ----------------------------------------------------------
--  E A CONFERÊNCIA NO PAPEL DE QUEM ATENDE — a régua 4 do LEIA-ME: quem
--  entrou LÊ os protocolos sem "permission denied", e NÃO consegue gravar
--  um. A troca de papel volta atrás sozinha se falhar.
-- ----------------------------------------------------------
do $conf$
declare
  v_le      text;
  v_escreve text;
begin
  if to_regclass('public.zorvin_atendimentos') is null
     or not exists (select 1 from pg_roles where rolname = 'authenticated') then
    return;
  end if;
  begin
    perform set_config('role', 'authenticated', true);
    perform count(*) from public.zorvin_atendimentos;
    v_le := 'true';
    execute 'reset role';
  exception when others then
    v_le := 'NÃO — ' || sqlerrm || ' (código ' || sqlstate || ')';
  end;
  -- GRAVAR TEM DE SER RECUSADO. Se passar, o erro de mentira lá do fim
  -- desfaz a linha — a conferência não pode deixar protocolo inventado.
  begin
    perform set_config('role', 'authenticated', true);
    insert into public.zorvin_atendimentos (protocolo, conversa_id, origem)
    select 'conferencia-028', c.id, 'equipe' from public.conversas c limit 1;
    raise exception 'gravou' using errcode = 'ZV028';
  exception
    when insufficient_privilege then v_escreve := 'true';
    when sqlstate 'ZV028' then v_escreve := 'NÃO — quem entrou consegue gravar um protocolo';
    when others then v_escreve := 'NÃO — ' || sqlerrm || ' (código ' || sqlstate || ')';
  end;
  execute 'reset role';
  insert into zorvin_conferencia_028 values
    ('quem entrou lê os protocolos', v_le),
    ('quem entrou não grava protocolo', v_escreve);
end
$conf$;

-- A RESPOSTA DE "DEU CERTO?", na última linha, que é a que o editor mostra.
select * from zorvin_conferencia_028;
