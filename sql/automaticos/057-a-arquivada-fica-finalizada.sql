-- ============================================================
--  A CONVERSA ARQUIVADA FICA FINALIZADA, E FORA DOS NÚMEROS
--
--  >>> RODAR NO SUPABASE DO **ZORVIN** (o das conversas). <<<
--  Quem roda é a PONTE, sozinha, na publicação que vem com o merge.
--  Pode rodar de novo sem medo.
--
--  ------------------------------------------------------------
--  O PEDIDO (06/11)
--
--  "Todas as conversas 'Arquivadas' não devem ser contabilizada nos números
--  do Painel, e sempre que alguma conversa que está arquivada enviar
--  mensagem nova, não deve abrir protocolo, as conversas arquivadas precisam
--  se manter finalizadas. Isso porque as conversas arquivadas costumam ser,
--  na grande maioria das vezes, propagandas."
--
--  ------------------------------------------------------------
--  O QUE MUDA
--
--  1. ARQUIVAR FINALIZA. Um gatilho em `conversas.arquivada` (de falso para
--     verdadeiro): a conversa vai para "finalizado", sai da fila de espera,
--     e o atendimento de agora é fechado, em nome de quem arquivou
--     (`auth.uid()`; nulo quando é a ponte ou o editor). NÃO nasce um "Já
--     tratei": arquivar não é tratar, e o relatório não ganha um registro
--     que ninguém marcou.
--
--  2. A MENSAGEM NUMA ARQUIVADA NÃO MEXE EM NADA: entra no histórico, como
--     sempre (a ponte não desarquiva, desde 04/11), e não abre protocolo, não
--     muda a aba, não entra na fila de espera. Vale para a mensagem da equipe
--     também. Quem DESARQUIVA traz a conversa de volta, e a mensagem
--     seguinte do cliente abre o protocolo novo, como numa finalizada.
--
--  3. O REABRIR NUMA ARQUIVADA É RECUSADO (42501), com a frase "desarquive
--     antes de reabrir". E o "Já tratei" desfeito numa arquivada sai do
--     relatório sem tirar a conversa de "finalizado".
--
--  4. OS NÚMEROS DO PAINEL deixam as arquivadas de fora: o painel de
--     mensagens (`painel_mensagens`, de onde saem `painel_dashboard` e
--     `painel_numeros`), a contabilização dos protocolos (052), o "Já tratei"
--     (010) e o funil (043: o cartão do cliente que, naquele funil, só tem
--     conversa arquivada). A carteira por responsável (011/051) e o número
--     das abas (046) já deixavam. "Arquivada" é como a conversa está AGORA:
--     arquivar hoje tira a conversa também dos números de antes.
--
--  5. O QUAZAR À NOITE (055) não escreve para a arquivada.
--
--  6. NA INSTALAÇÃO (e em toda rodada), as arquivadas que não estão
--     finalizadas são finalizadas, sem ninguém (`finalizado_por` nulo): o
--     banco não sabe quando cada uma foi arquivada.
--
--  O QUE NÃO MUDA, e é decisão: a resposta automática fora do horário
--  (021/022) continua respondendo quem escreve numa arquivada. Ela não abre
--  protocolo nem conta nos números, e calar a resposta é outra decisão.
--
--  ------------------------------------------------------------
--  VERSÕES DE REFERÊNCIA (a regra 5 do LEIA-ME)
--
--  Daqui para a frente, a versão de referência destas funções é a deste
--  script: `zorvin_situacao_da_mensagem`, `zorvin_marcar_espera`,
--  `zorvin_recontar_espera`, `zorvin_recontar_situacao`,
--  `zorvin_situacao_fora_da_regra` (do 037), `zorvin_situacao_desfeita`,
--  `zorvin_situacao_guardada` (do 028), `zorvin_relatorio_atendimentos`
--  (do 052), `zorvin_relatorio_tratados` (do 010, na versão que está no
--  banco do escritório), `zorvin_relatorio_funil` (do 043),
--  `zorvin_quazar_noturno_pendentes` (do 055) e a vista `painel_mensagens`
--  (de `sql/2026-08-painel-completo.sql`). Cada uma é a de antes, com a
--  arquivada de fora, e nada mais.
--
--  ------------------------------------------------------------
--  DEPENDE DE JÁ TER RODADO
--    028 e 037 (a situação e o aviso automático). O resto, cada parte só
--    se a função dela existir.
-- ============================================================

do $s057$
declare
  v_finalizadas integer := 0;
  r             record;
begin
  -- A TABELA DA CONFERÊNCIA NASCE ANTES DA GUARDA (a lição do 006 e do 007).
  drop table if exists zorvin_conferencia_057;
  create temp table zorvin_conferencia_057 (item text, resposta text);

  if to_regclass('public.conversas') is null or to_regclass('public.mensagens') is null then
    insert into zorvin_conferencia_057 values ('sem as tabelas do Zorvin', 'nada a fazer aqui');
    raise notice 'Zorvin: sem as tabelas de conversas — script 057 não fez nada.';
    return;
  end if;
  if not exists (select 1 from information_schema.columns
                  where table_schema = 'public' and table_name = 'conversas'
                    and column_name = 'arquivada') then
    insert into zorvin_conferencia_057 values ('a coluna das arquivadas', 'nada a fazer: este banco não arquiva conversas');
    raise notice 'Zorvin: sem conversas.arquivada — script 057 não fez nada.';
    return;
  end if;
  if to_regclass('public.zorvin_atendimentos') is null
     or to_regclass('public.zorvin_tratamentos') is null
     or to_regprocedure('public.zorvin_carencia_da_espera()') is null
     or not exists (select 1 from information_schema.columns
                     where table_schema = 'public' and table_name = 'mensagens'
                       and column_name = 'automatica') then
    insert into zorvin_conferencia_057
      values ('a situação (028) e o aviso automático (037)', 'NÃO — rode o script 028 e o 037 antes');
    raise notice 'Zorvin: sem o 028 ou o 037 — script 057 não fez nada.';
    return;
  end if;

  -- ----------------------------------------------------------
  --  1. A ESPERA (do 037): a arquivada não entra na fila.
  -- ----------------------------------------------------------
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
    -- A CONVERSA ARQUIVADA NÃO ENTRA NA FILA DE ESPERA (057): ela está
    -- finalizada, e quase sempre é propaganda.
    if exists (select 1 from public.conversas c
                where c.id = new.conversa_id and c.arquivada) then
      return null;
    end if;
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
           -- A ARQUIVADA NÃO ESPERA (057).
           case when c.arquivada then null else coalesce(
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
           ) end as quando
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

  -- ----------------------------------------------------------
  --  2. A SITUAÇÃO (do 037 e do 028): a arquivada fica finalizada.
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
  v_arq     boolean;
begin
  begin
    -- O AVISO AUTOMÁTICO não abre atendimento, não é primeira resposta e
    -- não muda a aba (037): é o escritório avisando, e não a equipe
    -- atendendo.
    if new.origem is null or new.origem not in ('contato', 'advogado')
       or coalesce(new.automatica, false) then
      return null;
    end if;

    select c.protocolo, c.situacao, c.arquivada into v_prot, v_sit, v_arq
      from public.conversas c where c.id = new.conversa_id for update;
    if not found then return null; end if;
    -- A CONVERSA ARQUIVADA FICA FINALIZADA (057): a mensagem entra, e não
    -- abre protocolo nem muda a aba. Quem desarquiva traz a conversa de
    -- volta, e a mensagem seguinte do cliente abre o protocolo novo.
    if coalesce(v_arq, false) then return null; end if;

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
  v_arq     boolean;
begin
  select c.arquivada into v_arq from public.conversas c where c.id = p_conversa for update;
  if not found then return null; end if;
  v_arq := coalesce(v_arq, false);

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
      -- A ARQUIVADA SEM ATENDIMENTO NENHUM fica finalizada, e fora da fila (057).
      if v_arq then
        update public.conversas set situacao = 'finalizado', esperando_desde = null
         where id = p_conversa
           and (situacao is distinct from 'finalizado' or esperando_desde is not null);
      end if;
      return (select c.situacao from public.conversas c where c.id = p_conversa);
    end if;
  elsif v_fim is not null then
    select min(m.criado_em) into v_t
      from public.mensagens m
     where m.conversa_id = p_conversa and m.origem = 'contato' and m.criado_em > v_fim;
    -- A ARQUIVADA NÃO ABRE PROTOCOLO pelo que o cliente escreveu (057).
    if v_t is not null and not v_arq then
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

  -- A ARQUIVADA QUE FICOU COM O ATENDIMENTO ABERTO é finalizada agora, sem
  -- ninguém: o banco não sabe quando ela foi arquivada (057).
  if v_arq and v_fim is null then
    v_fim := now();
    update public.zorvin_atendimentos
       set finalizado_em = greatest(v_fim, aberto_em), finalizado_por = null
     where id = v_id and finalizado_em is null;
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
           -- A ARQUIVADA (057): finalizada, fora da fila, e o atendimento de
           -- agora fechado. O que o cliente escreveu depois não conta.
           when c.arquivada then
             c.situacao is distinct from 'finalizado'
             or c.esperando_desde is not null
             or (a.id is null and c.protocolo is not null)
             or (a.id is not null
                 and (a.conversa_id <> c.id
                      or a.finalizado_em is null
                      or exists (select 1 from public.zorvin_atendimentos b
                                  where b.conversa_id = c.id and b.aberto_em > a.aberto_em)))
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
    -- A ARQUIVADA FICA FINALIZADA (057): o clique desfeito sai do
    -- relatório, e a conversa não volta para a fila.
    if exists (select 1 from public.conversas c
                where c.id = new.conversa_id and c.arquivada) then
      return null;
    end if;
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
  -- A ARQUIVADA FICA FINALIZADA (057): para reabrir, desarquive antes.
  if old.situacao = 'finalizado' and new.situacao = 'aberto'
     and coalesce(new.arquivada, false) then
    raise exception 'Esta conversa está arquivada: desarquive antes de reabrir.'
      using errcode = '42501';
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

  -- ----------------------------------------------------------
  --  3. ARQUIVAR FINALIZA
  --
  --  `before update of arquivada`: só quando a gravação menciona a coluna, e
  --  só na passagem de falso para verdadeiro. Ele muda a própria linha (NEW)
  --  e fecha o atendimento de agora. `security definer`: quem atende arquiva
  --  pela tela, e não escreve em `zorvin_atendimentos`.
  --
  --  A guarda da situação (028) não dispara: a gravação da tela menciona só
  --  `arquivada`, e a guarda é `before update of situacao, protocolo`.
  --
  --  Falhando, a conversa é arquivada assim mesmo, e o banco anota o aviso:
  --  arquivar vale mais do que a arrumação da aba, e a próxima rodada deste
  --  script (ou a junção da ponte) termina o serviço.
  -- ----------------------------------------------------------
  execute $x$
create or replace function public.zorvin_arquivada_fica_finalizada()
returns trigger language plpgsql security definer set search_path = public as $f$
begin
  if not coalesce(new.arquivada, false) or coalesce(old.arquivada, false) then
    return new;
  end if;
  begin
    if new.protocolo is not null then
      update public.zorvin_atendimentos
         set finalizado_em = greatest(now(), aberto_em), finalizado_por = auth.uid()
       where protocolo = new.protocolo and conversa_id = new.id and finalizado_em is null;
    end if;
    if new.situacao is distinct from 'finalizado' then
      new.tratada_em := greatest(new.tratada_em, now());
    end if;
    new.situacao := 'finalizado';
    new.esperando_desde := null;
  exception when others then
    raise warning 'Zorvin: arquivar não finalizou a conversa (%): %', sqlstate, sqlerrm;
  end;
  return new;
end
$f$
  $x$;
  execute 'revoke all on function public.zorvin_arquivada_fica_finalizada() from public';
  if exists (select 1 from pg_roles where rolname = 'anon') then
    execute 'revoke all on function public.zorvin_arquivada_fica_finalizada() from anon';
  end if;
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'revoke all on function public.zorvin_arquivada_fica_finalizada() from authenticated';
  end if;
  execute 'drop trigger if exists zorvin_arquivada_fica_finalizada on public.conversas';
  execute 'create trigger zorvin_arquivada_fica_finalizada
             before update of arquivada on public.conversas
             for each row execute function public.zorvin_arquivada_fica_finalizada()';

  -- ----------------------------------------------------------
  --  4. AS ARQUIVADAS DE HOJE, finalizadas. Em toda rodada: é a regra, e
  --     rodar de novo só acha o que ficou fora dela.
  -- ----------------------------------------------------------
  for r in select c.id from public.conversas c
            where c.arquivada and public.zorvin_situacao_fora_da_regra(c.id)
  loop
    perform public.zorvin_recontar_situacao(r.id);
    perform public.zorvin_recontar_espera(r.id);
    v_finalizadas := v_finalizadas + 1;
  end loop;
  insert into zorvin_conferencia_057
  values ('conversas arquivadas finalizadas nesta rodada', v_finalizadas::text);

  -- ----------------------------------------------------------
  --  5. O PAINEL DE MENSAGENS sem as arquivadas. A mesma vista, com as
  --     mesmas colunas, na mesma ordem (o que `create or replace view`
  --     exige), e um `where` no fim. As permissões ficam. Só troca a vista
  --     que existe e que tem o de-para: ela nasceu num script colado à mão.
  -- ----------------------------------------------------------
  if to_regclass('public.painel_mensagens') is not null
     and to_regclass('public.atendentes_de_para') is not null then
    execute $x$
create or replace view public.painel_mensagens
with (security_invoker = true) as
with pessoa_por_nome as (
  select lower(btrim(nome)) as chave, (array_agg(id))[1] as id
  from public.usuarios
  where coalesce(btrim(nome), '') <> ''
  group by 1
  having count(*) = 1
),
id_pelo_rotulo as (
  select lower(btrim(enviado_por)) as chave, (array_agg(enviado_por_id))[1] as id
  from public.mensagens
  where origem = 'advogado'
    and enviado_por_id is not null
    and coalesce(btrim(enviado_por), '') <> ''
  group by 1
  having count(distinct enviado_por_id) = 1
)
select
  m.id,
  m.conversa_id,
  c.advogado_id,
  m.criado_em,
  m.origem,
  coalesce(nullif(btrim(m.enviado_por), ''), '(sem nome)') as rotulo,
  coalesce(m.enviado_por_id, ir.id, irn.id, dp.usuario_id, pn.id) as quem_id,
  coalesce(nullif(btrim(dp.nome_novo), ''), nullif(btrim(m.enviado_por), '')) as quem_nome,
  (coalesce(nullif(btrim(m.enviado_por), ''), '(sem nome)') = 'WhatsApp') as e_aparelho,
  (dp.e_pessoa is not null and dp.e_pessoa = false and m.enviado_por_id is null) as e_rotulo
from public.mensagens m
join public.conversas c on c.id = m.conversa_id
left join public.atendentes_de_para dp
  on lower(btrim(dp.nome_antigo)) = lower(coalesce(nullif(btrim(m.enviado_por), ''), '(sem nome)'))
left join id_pelo_rotulo ir
  on ir.chave = lower(coalesce(nullif(btrim(m.enviado_por), ''), '(sem nome)'))
left join id_pelo_rotulo irn
  on irn.chave = lower(btrim(dp.nome_novo))
left join pessoa_por_nome pn
  on pn.chave = lower(btrim(coalesce(nullif(btrim(dp.nome_novo), ''),
                                     coalesce(nullif(btrim(m.enviado_por), ''), '(sem nome)'))))
-- A ARQUIVADA NÃO CONTA NO PAINEL (057): quase sempre é propaganda.
where not coalesce(c.arquivada, false)
    $x$;
  end if;

  -- ----------------------------------------------------------
  --  6. A CONTABILIZAÇÃO (052), só com o 052: a cópia chama a conta do prazo.
  -- ----------------------------------------------------------
  if to_regprocedure('public.zorvin_prazo_dos_protocolos(uuid[], timestamptz)') is not null then
    execute $x$
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
       -- A ARQUIVADA NÃO CONTA (057): quase sempre é propaganda.
       and not coalesce(c.arquivada, false)
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
    $x$;
  end if;

  -- ----------------------------------------------------------
  --  7. O "JÁ TRATEI" (010), na versão que está no banco do escritório.
  -- ----------------------------------------------------------
  if to_regprocedure('public.zorvin_relatorio_tratados(timestamptz, timestamptz, uuid, text, uuid, bigint, integer)') is not null then
    execute $x$
create or replace function public.zorvin_relatorio_tratados(
  p_desde        timestamptz default null,
  p_ate          timestamptz default null,
  p_quem         uuid        default null,
  p_fuso         text        default 'America/Campo_Grande',
  p_telefone     uuid        default null,
  p_departamento bigint      default null,
  p_limite       integer     default 500
)
returns jsonb
language plpgsql
stable
as $fn$
declare
  v_ate   timestamptz := coalesce(p_ate, now());
  v_desde timestamptz := coalesce(p_desde, '-infinity'::timestamptz);
  v_quem  uuid := p_quem;
  v_fuso  text := coalesce(p_fuso, 'America/Campo_Grande');
  v_lim   integer := least(greatest(coalesce(p_limite, 500), 1), 2000);
  v_saida jsonb;
begin
  if to_regprocedure('public.zorvin_admin()') is not null then
    if not public.zorvin_admin() then v_quem := auth.uid(); end if;
  end if;

  if not exists (select 1 from pg_timezone_names where name = v_fuso) then
    v_fuso := 'America/Campo_Grande';
  end if;

  with base as (
    select t.id, t.conversa_id, t.assunto_id, t.quem, t.quando,
           t.esperava_desde, t.desfeito_em,
           to_jsonb(t) ->> 'observacao' as observacao,
           c.advogado_id, c.contato_id
      from public.zorvin_tratamentos t
      join public.conversas c on c.id = t.conversa_id
      left join public.advogados a on a.id = c.advogado_id
     where t.quando >= v_desde and t.quando <= v_ate
       -- A ARQUIVADA NÃO CONTA (057).
       and not coalesce(c.arquivada, false)
       and (p_telefone is null or c.advogado_id = p_telefone)
       and (p_departamento is null or a.departamento_id = p_departamento)
  ),
  eventos as (
    select conversa_id, quem, quando, advogado_id, contato_id,
           bool_or(desfeito_em is not null)                         as desfeito,
           max(desfeito_em)                                         as desfeito_em,
           min(esperava_desde)                                      as esperava_desde,
           array_agg(distinct assunto_id)                           as assuntos,
           string_agg(observacao, ' · ') filter (where observacao is not null) as observacao
      from base
     group by conversa_id, quem, quando, advogado_id, contato_id
  ),
  meus as (
    select * from eventos where v_quem is null or quem = v_quem
  ),
  valendo as (
    select * from meus where not desfeito
  ),
  nomes as (
    select id, nome from public.equipe
  )
  select jsonb_build_object(
    'so_meu', v_quem is not null,
    'total', jsonb_build_object(
      'tratamentos', (select count(*) from valendo),
      'conversas',   (select count(distinct conversa_id) from valendo),
      'marcacoes',   (select count(*) from base b
                       where b.desfeito_em is null and (v_quem is null or b.quem = v_quem)),
      'desfeitos',   (select count(*) from meus where desfeito),
      'espera_mediana_dias', (select percentile_cont(0.5) within group (
                                 order by extract(epoch from (quando - esperava_desde)) / 86400.0)
                                from valendo where esperava_desde is not null),
      'com_espera', (select count(*) from valendo where esperava_desde is not null)
    ),
    'por_assunto', coalesce((
      select jsonb_agg(jsonb_build_object('id', x.assunto_id, 'nome', x.nome,
                                          'ativo', x.ativo, 'vezes', x.vezes)
                       order by x.vezes desc, x.nome)
        from (select b.assunto_id, s.nome, s.ativo, count(*) as vezes
                from base b
                join public.zorvin_assuntos s on s.id = b.assunto_id
               where b.desfeito_em is null and (v_quem is null or b.quem = v_quem)
               group by b.assunto_id, s.nome, s.ativo) x), '[]'::jsonb),
    'por_pessoa', coalesce((
      select jsonb_agg(jsonb_build_object('id', x.quem, 'nome', x.nome, 'tratamentos', x.n)
                       order by x.n desc, x.nome)
        from (select e.quem, coalesce(n.nome, '(sem nome)') as nome, count(*) as n
                from eventos e left join nomes n on n.id = e.quem
               where not e.desfeito
               group by e.quem, n.nome) x), '[]'::jsonb),
    'por_dia', coalesce((
      select jsonb_agg(jsonb_build_object('quando', x.dia, 'tratamentos', x.n) order by x.dia)
        from (select (quando at time zone v_fuso)::date as dia, count(*) as n
                from valendo group by 1) x), '[]'::jsonb),
    'total_registros', (select count(*) from meus),
    'registros', coalesce((
      select jsonb_agg(r order by r ->> 'quando' desc)
        from (select jsonb_build_object(
                       'quando', e.quando,
                       'quem', e.quem,
                       'quem_nome', n.nome,
                       'conversa_id', e.conversa_id,
                       'advogado_id', e.advogado_id,
                       'contato', jsonb_build_object(
                          'nome', ct.nome, 'numero', ct.numero,
                          'nome_zorvin', to_jsonb(ct) ->> 'nome_zorvin',
                          'vantoro_nome', to_jsonb(ct) ->> 'vantoro_nome'),
                       'assuntos', (select jsonb_agg(s.nome order by s.ordem, s.nome)
                                      from public.zorvin_assuntos s
                                     where s.id = any(e.assuntos)),
                       'observacao', e.observacao,
                       'esperava_desde', e.esperava_desde,
                       'desfeito', e.desfeito,
                       'desfeito_em', e.desfeito_em) as r
                from meus e
                left join nomes n on n.id = e.quem
                left join public.contatos ct on ct.id = e.contato_id
               order by e.quando desc
               limit v_lim) y), '[]'::jsonb)
  ) into v_saida;

  return v_saida;
end
$fn$
    $x$;
  end if;

  -- ----------------------------------------------------------
  --  8. O FUNIL (043), só com o funil de cada telefone.
  -- ----------------------------------------------------------
  if to_regclass('public.zorvin_funis') is not null
     and to_regprocedure('public.zorvin_relatorio_funil(timestamptz, timestamptz, bigint, uuid)') is not null then
    execute $x$
create or replace function public.zorvin_relatorio_funil(
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
  v_tel_tem_funil   boolean := false;
  v_saida jsonb;
begin
  if p_telefone is not null then
    select a.departamento_id into v_dep_do_telefone from public.advogados a where a.id = p_telefone;
    v_tel_tem_funil := exists (select 1 from public.zorvin_funis f
                                where f.advogado_id = p_telefone and f.ativo);
  end if;

  with
  com_funil as (
    select f.advogado_id from public.zorvin_funis f
     where f.ativo and f.advogado_id is not null
  ),
  funis as (
    select d.id as departamento_id, d.nome, d.ordem, null::uuid as telefone_id,
           null::text as telefone, 0 as tipo
      from public.departamentos d
     where exists (select 1 from public.zorvin_etapas e
                    where e.departamento_id = d.id and e.advogado_id is null)
       and (p_departamento is null or d.id = p_departamento)
       and (p_telefone is null or (not v_tel_tem_funil and d.id = v_dep_do_telefone))
       and exists (select 1 from public.conversas c
                     join public.advogados a on a.id = c.advogado_id
                    where a.departamento_id = d.id
                      and a.id not in (select advogado_id from com_funil))
    union all
    select f.departamento_id, d.nome, d.ordem, f.advogado_id, a.nome, 1
      from public.zorvin_funis f
      join public.departamentos d on d.id = f.departamento_id
      join public.advogados a on a.id = f.advogado_id
     where f.ativo and f.advogado_id is not null
       and exists (select 1 from public.zorvin_etapas e where e.advogado_id = f.advogado_id)
       and (p_departamento is null or f.departamento_id = p_departamento)
       and (p_telefone is null or f.advogado_id = p_telefone)
       and exists (select 1 from public.conversas c where c.advogado_id = f.advogado_id)
  ),
  cartoes as (
    select k.etapa_id, k.departamento_id, k.advogado_id, k.movido_em
      from public.zorvin_cartoes k
      join funis f on f.departamento_id = k.departamento_id
                  and f.telefone_id is not distinct from k.advogado_id
     where (p_telefone is null or exists (
             select 1 from public.conversas c
              where c.contato_id = k.contato_id and c.advogado_id = p_telefone))
       -- O CLIENTE SÓ COM CONVERSA ARQUIVADA NESTE FUNIL NÃO CONTA (057):
       -- quase sempre é propaganda.
       and exists (select 1 from public.conversas c
                     join public.advogados a on a.id = c.advogado_id
                    where c.contato_id = k.contato_id and not c.arquivada
                      and a.departamento_id = k.departamento_id
                      and case when k.advogado_id is null
                               then a.id not in (select advogado_id from com_funil)
                               else c.advogado_id = k.advogado_id end)
  ),
  movs as (
    select m.*
      from public.zorvin_movimentos m
      join funis f on f.departamento_id = m.departamento_id
                  and f.telefone_id is not distinct from m.advogado_id
     where m.quando >= v_desde and m.quando < v_ate
       and (p_telefone is null or exists (
             select 1 from public.conversas c
              where c.contato_id = m.contato_id and c.advogado_id = p_telefone))
       -- O CLIENTE SÓ COM CONVERSA ARQUIVADA NESTE FUNIL NÃO CONTA (057):
       -- quase sempre é propaganda.
       and exists (select 1 from public.conversas c
                     join public.advogados a on a.id = c.advogado_id
                    where c.contato_id = m.contato_id and not c.arquivada
                      and a.departamento_id = m.departamento_id
                      and case when m.advogado_id is null
                               then a.id not in (select advogado_id from com_funil)
                               else c.advogado_id = m.advogado_id end)
  ),
  passagens as (
    select s.de_etapa as etapa_id,
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
    select e.id, e.departamento_id, e.advogado_id, e.nome, e.cor, e.ordem, e.ativo,
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
      join funis f on f.departamento_id = e.departamento_id
                  and f.telefone_id is not distinct from e.advogado_id
  )
  select jsonb_build_object(
    'desde', v_desde,
    'ate', v_ate,
    'agora', now(),
    'departamentos', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', f.departamento_id,
               'nome', f.nome,
               'telefone_id', f.telefone_id,
               'telefone', f.telefone,
               'agora', (select count(*) from cartoes k
                          where k.departamento_id = f.departamento_id
                            and k.advogado_id is not distinct from f.telefone_id),
               'entraram_no_funil', (select count(*) from movs m
                                      where m.departamento_id = f.departamento_id
                                        and m.advogado_id is not distinct from f.telefone_id
                                        and m.de_etapa is null),
               'sairam_do_funil', (select count(*) from movs m
                                    where m.departamento_id = f.departamento_id
                                      and m.advogado_id is not distinct from f.telefone_id
                                      and m.para_etapa is null),
               'movimentos', (select count(*) from movs m
                               where m.departamento_id = f.departamento_id
                                 and m.advogado_id is not distinct from f.telefone_id),
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
                  where p.departamento_id = f.departamento_id
                    and p.advogado_id is not distinct from f.telefone_id
                    and (p.ativo or p.agora > 0 or p.entraram > 0 or p.sairam > 0)), '[]'::jsonb))
             order by f.ordem, f.nome, f.tipo, f.telefone)
        from funis f), '[]'::jsonb)
  ) into v_saida;

  return v_saida;
end
$fn$
    $x$;
  end if;

  -- ----------------------------------------------------------
  --  9. O QUAZAR À NOITE (055).
  -- ----------------------------------------------------------
  if to_regprocedure('public.zorvin_quazar_noturno_pendentes(integer, integer)') is not null then
    execute $x$
create or replace function public.zorvin_quazar_noturno_pendentes(
  p_limite integer default 5, p_quieto_s integer default 90)
returns jsonb language plpgsql security definer set search_path = public as $f$
declare
  v_out      jsonb := '[]'::jsonb;
  v_carencia interval := interval '30 minutes';
  r          record;
  v_h        jsonb;
  v_fechou   timestamptz;
  v_ate      timestamptz;
  v_nossa    timestamptz;
begin
  begin
    v_carencia := coalesce(public.zorvin_carencia_da_espera(), interval '30 minutes');
  exception when undefined_function then
    v_carencia := interval '30 minutes';
  end;

  for r in
    select c.id as conversa_id, c.advogado_id, a.departamento_id, d.nome as departamento,
           f.semana, f.fuso, f.quazar, m.id as msg_id, m.criado_em as msg_em
      from public.conversas c
      join public.contatos ct on ct.id = c.contato_id
      join public.advogados a on a.id = c.advogado_id
      join public.departamentos d on d.id = a.departamento_id
      join public.zorvin_fora_do_horario f on f.departamento_id = a.departamento_id
      cross join lateral (
        select m.id, m.criado_em, m.origem
          from public.mensagens m
         where m.conversa_id = c.id
         order by m.criado_em desc, m.id desc
         limit 1) m
     where f.quazar <> 'desligado'
       -- A ARQUIVADA NÃO É CLIENTE ESPERANDO (057).
       and not coalesce(c.arquivada, false)
       and c.ultima_atividade > now() - interval '12 hours'
       and ct.numero not like 'grupo:%'
       and coalesce(a.ativo = false, false) = false
       and m.origem = 'contato'
       and m.criado_em > now() - interval '12 hours'
       and m.criado_em <= now() - make_interval(secs => greatest(coalesce(p_quieto_s, 90), 0))
       and not exists (select 1 from public.zorvin_quazar_noturno q
                        where q.conversa_id = c.id and q.cliente_ate >= m.criado_em)
     order by m.criado_em
  loop
    exit when jsonb_array_length(v_out) >= greatest(coalesce(p_limite, 5), 1);

    -- FECHADO AGORA, e o cliente escreveu depois do fechamento.
    v_h := public.zorvin_horario_de(r.semana, r.fuso, now());
    continue when coalesce((v_h ->> 'aberto')::boolean, false);
    v_ate := (v_h ->> 'abre_em')::timestamptz;
    continue when v_ate is null;
    v_fechou := (v_h ->> 'fechou_em')::timestamptz;
    continue when r.msg_em < coalesce(v_fechou, now() - interval '12 hours');

    -- A EQUIPE NA CONVERSA: a mensagem nossa (inclui o celular) ou o
    -- pedido na fila (a agendada que espera a hora não conta).
    select greatest(
             (select max(m.criado_em) from public.mensagens m
               where m.conversa_id = r.conversa_id and m.origem = 'advogado'),
             (select max(fe.criado_em) from public.fila_envio fe
               where fe.conversa_id = r.conversa_id
                 and (to_jsonb(fe) ->> 'agendada_para') is null))
      into v_nossa;
    continue when v_nossa >= coalesce(v_fechou, r.msg_em - interval '12 hours');
    continue when v_nossa >= r.msg_em - v_carencia;

    v_out := v_out || jsonb_build_object(
      'conversa_id', r.conversa_id,
      'advogado_id', r.advogado_id,
      'departamento_id', r.departamento_id,
      'departamento', r.departamento,
      'modo', r.quazar,
      'fuso', r.fuso,
      'ate', v_ate,
      'fechou_em', v_fechou,
      'cliente_ate', r.msg_em,
      'cliente_ate_id', r.msg_id);
  end loop;
  return v_out;
end
$f$
    $x$;
  end if;
end $s057$;

-- ----------------------------------------------------------
--  A CONFERÊNCIA VAI DENTRO DO SCRIPT, e é a última linha dele.
--
--  As funções do Painel são CHAMADAS no papel de quem atende (a regra 4 do
--  LEIA-ME), e não só perguntadas.
-- ----------------------------------------------------------
do $conf$
declare
  v_resposta text;
begin
  if to_regprocedure('public.zorvin_arquivada_fica_finalizada()') is null then
    return;
  end if;

  insert into zorvin_conferencia_057
  select 'nenhuma conversa arquivada fora de "finalizado" nem na fila',
         (not exists (select 1 from public.conversas c
                       where c.arquivada
                         and (c.situacao is distinct from 'finalizado' or c.esperando_desde is not null)))::text
  union all
  select 'nenhum protocolo aberto numa conversa arquivada',
         (not exists (select 1 from public.zorvin_atendimentos a
                        join public.conversas c on c.id = a.conversa_id
                       where c.arquivada and a.finalizado_em is null))::text
  union all
  select 'conversas arquivadas', (select count(*) from public.conversas c where c.arquivada)::text;

  if to_regclass('public.painel_mensagens') is not null then
    insert into zorvin_conferencia_057
    select 'o painel de mensagens deixa as arquivadas de fora',
           (position('arquivada' in pg_get_viewdef('public.painel_mensagens'::regclass)) > 0)::text;
  end if;

  if not exists (select 1 from pg_roles where rolname = 'authenticated') then
    return;
  end if;

  begin
    perform set_config('role', 'authenticated', true);
    if to_regprocedure('public.zorvin_prazo_dos_protocolos(uuid[], timestamptz)') is not null then
      perform public.zorvin_relatorio_atendimentos();
      perform public.zorvin_relatorio_atendimentos(null, null, null, null,
                (select a.id from public.advogados a limit 1));
    end if;
    if to_regprocedure('public.zorvin_relatorio_tratados(timestamptz, timestamptz, uuid, text, uuid, bigint, integer)') is not null then
      perform public.zorvin_relatorio_tratados();
      perform public.zorvin_relatorio_tratados(null, null, null, null,
                (select a.id from public.advogados a limit 1));
    end if;
    if to_regclass('public.zorvin_funis') is not null
       and to_regprocedure('public.zorvin_relatorio_funil(timestamptz, timestamptz, bigint, uuid)') is not null then
      perform public.zorvin_relatorio_funil();
      perform public.zorvin_relatorio_funil(null, null, null,
                (select a.id from public.advogados a limit 1));
    end if;
    if to_regclass('public.painel_mensagens') is not null then
      perform count(*) from public.painel_mensagens;
    end if;
    v_resposta := 'sim';
    execute 'reset role';
  exception when others then
    v_resposta := 'NÃO — ' || sqlerrm || ' (código ' || sqlstate || ')';
  end;
  insert into zorvin_conferencia_057 values ('os números do Painel respondem para quem atende', v_resposta);
end
$conf$;

-- A RESPOSTA DE "DEU CERTO?", na última linha, que é a que o editor mostra.
select * from zorvin_conferencia_057;
