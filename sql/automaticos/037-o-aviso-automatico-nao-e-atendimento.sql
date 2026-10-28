-- ------------------------------------------------------------
--  037. O AVISO AUTOMÁTICO NÃO É ATENDIMENTO (28/10)
--
--  Auditoria de 27/10. O aviso de audiência que o Vantoro manda pela ponte
--  entra em `mensagens` como mensagem do escritório (origem 'advogado', sem
--  autor) — e toda conta que pergunta "a equipe já agiu?" o lia como gente
--  respondendo:
--
--    - a FILA DE ESPERA (004–006, 020): o cliente que tinha perguntado algo
--      saía da fila quando o aviso saía, sem ninguém ter respondido;
--    - a SITUAÇÃO E O PROTOCOLO (028): o aviso virava a "primeira resposta"
--      do atendimento que o cliente abriu, e tirava a conversa de "Novos";
--    - por tabela, a CONTABILIZAÇÃO (029): o tempo até a primeira resposta
--      era o do aviso.
--
--  MEDIDO em 28/10, só contando: 38 avisos desde 13/08, em 14 conversas. Num
--  deles o cliente estava esperando resposta, e continua fora da fila só por
--  causa do aviso; 6 protocolos têm um aviso como primeira resposta.
--
--  O 004 já dizia, ao escrever a regra da espera: "um else faria qualquer
--  origem futura ('sistema', aviso automático) zerar a espera de um cliente
--  que continua sem resposta". A regra era essa; o aviso é que entrou como
--  'advogado'.
--
--  O QUE FAZ:
--    1. `mensagens.automatica` (padrão falso). A ponte marca a linha do aviso
--       ao gravá-la (`gravarEnviadaNoHistorico`); aqui são marcadas as que já
--       existem, pelo item da fila que as mandou: a mesma conversa, o mesmo
--       texto, sem autor, até 10 minutos da hora do envio.
--    2. As contas de "a equipe agiu" deixam a mensagem automática de fora. São
--       as versões de referência daqui para a frente (regra 5 do LEIA-ME):
--         - o gatilho da espera (`zorvin_marcar_espera`, do 020);
--         - a recontagem da espera (`zorvin_recontar_espera`, do 006);
--         - as cinco funções da situação, do 028.
--    3. Os protocolos cuja primeira resposta foi um aviso ganham a primeira
--       resposta de gente, ou nenhuma; as conversas com aviso têm a espera
--       e a situação recontadas.
--
--  O QUE NÃO MUDA, de propósito:
--    - a ORIGEM continua 'advogado': a bolha, o lado dela, o menu, a
--      resposta do cliente ao aviso (26/10) e o Controle de atendimento do
--      Vantoro leem a origem, e o aviso continua sendo do escritório;
--    - a resposta fora do horário (022) continua contando o aviso como
--      conversa em andamento: responder "estamos fechados" ao "ok, ciente" de
--      quem acabou de recebê-lo seria pior do que calar;
--    - a distribuição (023) continua sem distribuir quem responde a um aviso:
--      é cliente que o escritório procurou, e não um lead.
--
--  A CONVERSA QUE SÓ TEM O AVISO não abre atendimento nem vai para "Novos":
--  fica em "Em Atendimento" (o padrão da coluna, no 028), sem protocolo. Quando
--  o cliente responde, o protocolo é dele, e a conversa vai para "Novos" —
--  ninguém da equipe falou com ele ainda.
--
--  TUDO OU NADA (a ponte roda cada script numa transação), e rodável de novo.
--  Num banco sem o Zorvin (a 51l-bis), sai cedo.
-- ------------------------------------------------------------

create temporary table zorvin_conferencia_037 (item text, resposta text) on commit drop;

do $automatico$
declare
  v_marcadas    int := 0;
  v_protocolos  int := 0;
  v_conversas   int := 0;
  v_tem_fila    boolean;
  v_tem_espera  boolean;
  v_tem_situacao boolean;
begin
  if to_regclass('public.mensagens') is null or to_regclass('public.conversas') is null then
    insert into zorvin_conferencia_037 values
      ('o aviso automático não é atendimento', 'nada a fazer — este banco não tem o Zorvin');
    return;
  end if;

  -- ----------------------------------------------------------
  --  AS TRAVAS, NA ORDEM DO WEBHOOK (a lição do 028): os registros do "Já
  --  tratei" e as mensagens primeiro, a conversa depois. Na ordem contrária,
  --  uma mensagem chegando no meio do caminho esperaria por nós enquanto nós
  --  esperávamos por ela.
  -- ----------------------------------------------------------
  if to_regclass('public.zorvin_tratamentos') is not null then
    execute 'lock table public.zorvin_tratamentos in access exclusive mode';
  end if;
  execute 'lock table public.mensagens in access exclusive mode';
  execute 'lock table public.conversas in access exclusive mode';

  -- ----------------------------------------------------------
  --  1. A MARCA
  -- ----------------------------------------------------------
  execute 'alter table public.mensagens add column if not exists automatica boolean not null default false';
  execute $x$
    comment on column public.mensagens.automatica is
      'Mensagem que o escritório mandou sem ninguém escrever (o aviso de audiência do '
      'Vantoro). Não conta como a equipe agindo: não tira da fila de espera, não é '
      'primeira resposta e não abre atendimento (script 037).'
  $x$;

  select exists (select 1 from information_schema.columns
                  where table_schema = 'public' and table_name = 'fila_envio'
                    and column_name = 'aviso_vantoro_id')
     and exists (select 1 from information_schema.columns
                  where table_schema = 'public' and table_name = 'fila_envio'
                    and column_name = 'enviado_em')
    into v_tem_fila;

  -- AS LINHAS DOS AVISOS QUE JÁ SAÍRAM: a de cada item, a mais perto da hora
  -- do envio. O autor vem por `to_jsonb`, porque `enviado_por_id` nasceu à mão.
  if v_tem_fila then
    execute $x$
      update public.mensagens m set automatica = true
        from (select distinct on (f.id) m2.id as msg_id
                from public.fila_envio f
                join public.mensagens m2
                  on m2.conversa_id = f.conversa_id and m2.origem = 'advogado'
                 and m2.texto is not distinct from f.texto
                 and (to_jsonb(m2) ->> 'enviado_por_id') is null
                 and m2.criado_em between f.enviado_em - interval '10 minutes'
                                      and f.enviado_em + interval '10 minutes'
               where f.aviso_vantoro_id is not null and f.status = 'enviada'
                 and f.enviado_em is not null
               order by f.id, abs(extract(epoch from m2.criado_em - f.enviado_em))) x
       where m.id = x.msg_id and not m.automatica
    $x$;
    get diagnostics v_marcadas = row_count;
  end if;

  -- ----------------------------------------------------------
  --  2. A ESPERA — o gatilho (do 020) e a recontagem (do 006), com a
  --     mensagem automática de fora. Nada mais mudou neles.
  -- ----------------------------------------------------------
  v_tem_espera := to_regprocedure('public.zorvin_carencia_da_espera()') is not null
                  and exists (select 1 from information_schema.columns
                               where table_schema = 'public' and table_name = 'conversas'
                                 and column_name = 'tratada_em');
  if v_tem_espera then
    execute $x$
          create or replace function public.zorvin_marcar_espera()
          returns trigger
          language plpgsql
          as $fn$
          declare
            nossa     timestamptz;
            carencia  interval;
          begin
            -- DENTRO DO BLOCO, e não na declaração: o `exception` lá de baixo não
            -- protege a declaração das variáveis (auditoria de 07/10).
            carencia := public.zorvin_carencia_da_espera();
            if new.origem = 'contato' then
              if exists (select 1 from public.mensagens m
                          where m.conversa_id = new.conversa_id
                            and m.origem = 'advogado' and not m.automatica
                            and m.criado_em >= new.criado_em)
                 or exists (select 1 from public.conversas c
                             where c.id = new.conversa_id
                               and c.tratada_em >= new.criado_em) then
                return null;
              end if;

              select greatest(
                       (select max(m.criado_em) from public.mensagens m
                         where m.conversa_id = new.conversa_id
                           and m.origem = 'advogado' and not m.automatica),
                       c.tratada_em)
                into nossa
                from public.conversas c
               where c.id = new.conversa_id;

              if nossa is null or new.criado_em > nossa + carencia then
                update public.conversas
                   set esperando_desde = case
                         when esperando_desde is null then new.criado_em
                         when nossa is not null
                              and esperando_desde <= nossa + carencia then new.criado_em
                         else least(esperando_desde, new.criado_em)
                       end
                 where id = new.conversa_id;
              else
                update public.conversas
                   set esperando_desde = coalesce(esperando_desde, new.criado_em)
                 where id = new.conversa_id;
              end if;

            elsif new.origem = 'advogado' and not coalesce(new.automatica, false) then
              update public.conversas
                 set esperando_desde = null,
                     tratada_em = null
               where id = new.conversa_id
                 and coalesce(esperando_desde, tratada_em) <= new.criado_em;
            end if;
            return null;
          exception when others then
            raise warning 'zorvin_espera: %', sqlerrm;
            return null;
          end
          $fn$
        $x$;

    execute $x$
        create or replace function public.zorvin_recontar_espera(p_conversa uuid default null)
        returns integer
        language plpgsql
        as $fn$
        declare n integer;
        begin
          with certo as (
            select c.id,
                   coalesce(
                     (select min(m.criado_em)
                        from public.mensagens m
                       where m.conversa_id = c.id
                         and m.origem = 'contato'
                         and m.criado_em > coalesce(nossa.quando, '-infinity'::timestamptz)
                         and (nossa.quando is null
                              or m.criado_em > nossa.quando
                                               + public.zorvin_carencia_da_espera())),
                     (select min(m.criado_em)
                        from public.mensagens m
                       where m.conversa_id = c.id
                         and m.origem = 'contato'
                         and m.criado_em > coalesce(nossa.quando, '-infinity'::timestamptz))
                   ) as quando
              from public.conversas c
              cross join lateral (
                select greatest(
                         (select max(m2.criado_em) from public.mensagens m2
                           where m2.conversa_id = c.id and m2.origem = 'advogado' and not m2.automatica),
                         c.tratada_em) as quando
              ) nossa
             where p_conversa is null or c.id = p_conversa
          )
          update public.conversas c
             set esperando_desde = certo.quando
            from certo
           where c.id = certo.id
             and c.esperando_desde is distinct from certo.quando;
          get diagnostics n = row_count;
          return n;
        end
        $fn$
      $x$;
  end if;

  -- ----------------------------------------------------------
  --  3. A SITUAÇÃO (028) — as cinco funções, com a mensagem automática de
  --     fora. A única regra nova é a de `zorvin_aberta_ou_aguardando`: sem
  --     mensagem do cliente, ninguém está aguardando.
  -- ----------------------------------------------------------
  v_tem_situacao := to_regclass('public.zorvin_atendimentos') is not null
                    and to_regclass('public.zorvin_tratamentos') is not null;
  if v_tem_situacao then
  execute $x$
      create or replace function public.zorvin_aberta_ou_aguardando(p_conversa uuid)
      returns text language sql stable security definer set search_path = public as $f$
        select case
                 when exists (select 1 from public.mensagens m
                               where m.conversa_id = p_conversa and m.origem = 'advogado'
                                 and not m.automatica)
                   or exists (select 1 from public.zorvin_tratamentos t
                               where t.conversa_id = p_conversa and t.desfeito_em is null)
                   -- SEM MENSAGEM DO CLIENTE não há quem esteja aguardando: é a
                   -- conversa que só tem o aviso automático (037).
                   or not exists (select 1 from public.mensagens m
                                   where m.conversa_id = p_conversa and m.origem = 'contato')
                 then 'aberto' else 'aguardando' end
      $f$
    $x$;

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
             where m.conversa_id = p_conversa and m.origem in ('contato', 'advogado') and not m.automatica
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
                                        where m.conversa_id = p_conversa and m.origem = 'advogado' and not m.automatica
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
                                    where m.conversa_id = p_conversa and m.origem = 'advogado' and not m.automatica
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
                                      where m.conversa_id = p_conversa and m.origem = 'advogado' and not m.automatica
                                        and m.criado_em >= v_t);
            return next;
          end if;
        else
          -- SEM "JÁ TRATEI" NENHUM: um atendimento só, aberto, desde a
          -- primeira mensagem. Sem mensagem, nenhum.
          select m.criado_em, m.origem into v_t, v_o
            from public.mensagens m
           where m.conversa_id = p_conversa and m.origem in ('contato', 'advogado') and not m.automatica
           order by m.criado_em
           limit 1;
          if v_t is not null then
            aberto_em := v_t;
            origem := case when v_o = 'contato' then 'cliente' else 'equipe' end;
            finalizado_em := null; finalizado_por := null; cliques := null;
            primeira_resposta_em := (select min(m.criado_em) from public.mensagens m
                                      where m.conversa_id = p_conversa and m.origem = 'advogado' and not m.automatica
                                        and m.criado_em >= v_t);
            return next;
          end if;
        end if;
        return;
      end
      $f$
    $x$;

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
          -- O AVISO AUTOMÁTICO não abre atendimento, não é primeira resposta e
          -- não muda a aba (037): é o escritório avisando, e não a equipe
          -- atendendo.
          if new.origem is null or new.origem not in ('contato', 'advogado')
             or coalesce(new.automatica, false) then
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
                       where m.conversa_id = p_conversa and m.origem = 'advogado' and not m.automatica and m.criado_em >= v_t));
            v_fim := null;
          end if;
        elsif v_resp is null then
          update public.zorvin_atendimentos
             set primeira_resposta_em = (select min(m.criado_em) from public.mensagens m
                                          where m.conversa_id = p_conversa and m.origem = 'advogado' and not m.automatica
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

  execute $x$
      create or replace function public.zorvin_situacao_fora_da_regra(p_conversa uuid)
      returns boolean language sql stable security definer set search_path = public as $f$
        select case
                 when a.id is null then
                   c.protocolo is not null
                   or exists (select 1 from public.mensagens m
                               where m.conversa_id = c.id and m.origem in ('contato', 'advogado') and not m.automatica)
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

    -- OS PROTOCOLOS CUJA PRIMEIRA RESPOSTA FOI UM AVISO: a primeira mensagem
    -- de gente no mesmo trecho — a régua de `zorvin_atendimento_ciclos` —, ou
    -- nenhuma. O protocolo não muda de número, nem de começo.
    update public.zorvin_atendimentos a
       set primeira_resposta_em = (select min(m.criado_em) from public.mensagens m
                                    where m.conversa_id = a.conversa_id and m.origem = 'advogado'
                                      and not m.automatica
                                      and m.criado_em >= a.aberto_em
                                      and (a.finalizado_em is null or m.criado_em <= a.finalizado_em))
     where exists (select 1 from public.mensagens x
                    where x.conversa_id = a.conversa_id and x.automatica
                      and x.criado_em = a.primeira_resposta_em);
    get diagnostics v_protocolos = row_count;
  end if;

  -- ----------------------------------------------------------
  --  4. AS CONVERSAS COM AVISO, RECONTADAS: a espera do zero, e a situação de
  --     quem ficou fora da regra.
  -- ----------------------------------------------------------
  if v_tem_espera then
    perform public.zorvin_recontar_espera(c.id)
       from public.conversas c
      where exists (select 1 from public.mensagens m where m.conversa_id = c.id and m.automatica);
  end if;
  if v_tem_situacao then
    perform public.zorvin_recontar_situacao(c.id)
       from public.conversas c
      where exists (select 1 from public.mensagens m where m.conversa_id = c.id and m.automatica)
        and public.zorvin_situacao_fora_da_regra(c.id);
  end if;
  select count(*) into v_conversas
    from public.conversas c
   where exists (select 1 from public.mensagens m where m.conversa_id = c.id and m.automatica);

  -- ----------------------------------------------------------
  --  A CONFERÊNCIA
  -- ----------------------------------------------------------
  insert into zorvin_conferencia_037 values
    ('avisos marcados como automáticos agora', v_marcadas::text),
    ('conversas com aviso automático', v_conversas::text),
    ('protocolos com a primeira resposta corrigida agora', v_protocolos::text);

  if v_tem_fila then
    execute $x$
      insert into zorvin_conferencia_037
      select 'todo aviso que saiu está marcado',
             (not exists (
                select 1 from public.fila_envio f
                 where f.aviso_vantoro_id is not null and f.status = 'enviada'
                   and f.enviado_em is not null
                   and exists (select 1 from public.mensagens m2
                                where m2.conversa_id = f.conversa_id and m2.origem = 'advogado'
                                  and m2.texto is not distinct from f.texto
                                  and (to_jsonb(m2) ->> 'enviado_por_id') is null
                                  and m2.criado_em between f.enviado_em - interval '10 minutes'
                                                       and f.enviado_em + interval '10 minutes')
                   and not exists (select 1 from public.mensagens m2
                                    where m2.conversa_id = f.conversa_id and m2.automatica
                                      and m2.criado_em between f.enviado_em - interval '10 minutes'
                                                           and f.enviado_em + interval '10 minutes')))::text
    $x$;
  end if;
  if v_tem_espera then
    insert into zorvin_conferencia_037 values
      ('a espera não conta o aviso',
       (position('not m.automatica' in pg_get_functiondef('public.zorvin_marcar_espera()'::regprocedure)) > 0
        and position('not m2.automatica' in pg_get_functiondef('public.zorvin_recontar_espera(uuid)'::regprocedure)) > 0)::text);
  end if;
  if v_tem_situacao then
    insert into zorvin_conferencia_037
    select 'nenhum protocolo com um aviso como primeira resposta',
           (not exists (select 1 from public.zorvin_atendimentos a
                         where exists (select 1 from public.mensagens x
                                        where x.conversa_id = a.conversa_id and x.automatica
                                          and x.criado_em = a.primeira_resposta_em)))::text
    union all
    select 'nenhuma conversa com aviso fora da regra da situação',
           (not exists (select 1 from public.conversas c
                         where exists (select 1 from public.mensagens m
                                        where m.conversa_id = c.id and m.automatica)
                           and public.zorvin_situacao_fora_da_regra(c.id)))::text;
  end if;
end $automatico$;

-- A RESPOSTA DE "DEU CERTO?", na última linha, que é a que o editor mostra.
select * from zorvin_conferencia_037;
