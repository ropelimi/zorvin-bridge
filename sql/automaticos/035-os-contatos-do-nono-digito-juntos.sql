-- ------------------------------------------------------------
--  035. OS CONTATOS DUPLICADOS PELO NONO DÍGITO, JUNTOS (27/10)
--
--  Pedido do Rodrigo: "Junta as conversas duplicadas que já existem."
--
--  Até a correção da ponte de 27/10 (`contatoDoAviso`), o aviso de audiência
--  para um cliente antigo criava um SEGUNDO contato: o cadastro do Vantoro tem
--  o celular com o nono dígito, e o WhatsApp do cliente é a forma sem ele. A
--  equipe via a mesma pessoa duas vezes — a GIRLEIS RIBEIRO MATOS em
--  (77) 8154-5221 e em (77) 98154-5221 —, e a resposta do cliente caía na
--  conversa que não tinha os avisos.
--
--  O QUE FAZ: para cada celular com mais de um contato (as formas com e sem o
--  nono dígito, com e sem o 55), sobra UM contato, com tudo junto.
--
--    - As conversas do mesmo telefone do escritório viram uma só, com o que o
--      "Juntar duas conversas" do painel leva (`mudarDeConversa` na ponte):
--      mensagem, nota, envio da fila, tarefa, "Já tratei" e etiqueta — e
--      também a resposta automática de fora do horário, que o painel deixava
--      ir embora com a conversa, e era o que o cliente recebeu. O que bateria
--      de frente com o que a conversa que fica já tem — a mesma etiqueta, a
--      mesma mensagem gravada nas duas — sai, em vez de duplicar. As não
--      lidas se somam, e a espera (005) e a situação (028) da conversa que
--      fica são recontadas do zero, como a ponte faz depois de juntar. O "Já
--      tratei" dela continua o dela: o clique na conversa que sai tratou
--      aquela conversa, e levá-lo junto poderia tirar da fila uma pergunta do
--      cliente que ninguém respondeu. A distribuição e os atendimentos
--      contados na conversa que sai vão com ela, como no painel.
--    - O HISTÓRICO DE ALTERAÇÕES (cadastro e notas) passa para o contato e a
--      conversa que ficam: é por eles que a tela de histórico procura.
--    - A conversa de um telefone que o contato que fica não tem só muda de dono.
--    - O FUNIL: o cartão do contato que sai passa para o que fica, com o
--      histórico. Se o que fica já tem cartão naquele departamento, fica o
--      dele, e o que sobra sai com o próprio histórico — que era de um contato
--      que não devia existir. O "Juntar duas conversas" apagava o cartão junto
--      com o contato; aqui ele não se perde.
--    - O nome, a foto e o cliente do Vantoro que só o contato que sai tinha
--      passam para o que fica.
--
--  QUEM FICA: o contato por onde o cliente ESCREVE — o da mensagem mais recente
--  vinda dele. É a forma que o WhatsApp usa hoje, e é por ela que as próximas
--  mensagens chegam. O contato que um aviso criou nunca recebeu mensagem do
--  cliente (ela ia para o outro), então é ele que sai. Sem mensagem do cliente
--  em nenhum dos dois, fica o mais antigo.
--
--  O NÚMERO DE QUEM FICA NÃO MUDA. O script de agosto o trocava pela forma com o
--  nono dígito; a forma certa é a que o WhatsApp usa, e quem a acerta quando
--  ela muda é a entrada de mensagens.
--
--  POR QUE NÃO O SCRIPT DE AGOSTO (sql/2026-08-juntar-duplicados-nono-digito.sql)
--  como estava: ele apagava o contato que saía com o cartão do funil junto (o
--  017 apaga em cascata), perdia o nome e o cliente do Vantoro dele, e movia
--  TODA tabela com `conversa_id` — inclusive a da distribuição, que aceita uma
--  linha só por conversa (o 023), e onde a junção estouraria.
--
--  TUDO OU NADA: a ponte roda cada script numa transação.
--  Rodável de novo: na segunda vez não há duplicado, e nada acontece.
--  Num banco sem o Zorvin (a 51l-bis), sai cedo.
--  Fica o registro em `juntada_contatos_log`, a mesma tabela de agosto.
-- ------------------------------------------------------------

create temporary table zorvin_conferencia_035 (item text, resposta text) on commit drop;

do $juntar$
declare
  g            record;
  perdedor     record;
  cv           record;
  tab          text;
  u            record;
  cond         text;
  fica         text;
  destino      text;
  saiu         jsonb;
  col          text;
  n            int;
  msgs         int;
  convs        int;
  juntados     int := 0;
  detalhe      text;
  tem_criado   boolean;
  tem_ultima   boolean;
  tem_resumo   boolean;
  tem_lidas    boolean;
  tem_funil    boolean;
  tem_alteracoes boolean;
begin
  if to_regclass('public.contatos') is null or to_regclass('public.conversas') is null then
    insert into zorvin_conferencia_035 values
      ('contatos duplicados pelo nono dígito', 'nenhum — este banco não tem o Zorvin');
    return;
  end if;

  create table if not exists public.juntada_contatos_log (
    id            bigserial primary key,
    em            timestamptz not null default now(),
    celular       text,
    ficou_id      text,
    ficou_nome    text,
    ficou_numero  text,
    saiu_id       text,
    saiu_nome     text,
    saiu_numero   text,
    conversas     int,
    mensagens     int,
    detalhe       text
  );
  -- Só a ponte (o papel de serviço) alcança: RLS ligada e nenhuma política.
  alter table public.juntada_contatos_log enable row level security;

  select exists (select 1 from information_schema.columns
                  where table_schema = 'public' and table_name = 'contatos'
                    and column_name = 'criado_em') into tem_criado;
  select exists (select 1 from information_schema.columns
                  where table_schema = 'public' and table_name = 'conversas'
                    and column_name = 'ultima_atividade') into tem_ultima;
  select exists (select 1 from information_schema.columns
                  where table_schema = 'public' and table_name = 'conversas'
                    and column_name = 'ultima_mensagem') into tem_resumo;
  select exists (select 1 from information_schema.columns
                  where table_schema = 'public' and table_name = 'conversas'
                    and column_name = 'nao_lidas') into tem_lidas;
  tem_funil := to_regclass('public.zorvin_cartoes') is not null;
  -- O histórico de alterações (sql/2026-08-notas-e-historico.sql): sem chave
  -- estrangeira, de propósito — então ninguém o leva junto se não for aqui.
  select count(*) = 2 from information_schema.columns
   where table_schema = 'public' and table_name = 'alteracoes'
     and column_name in ('contato_id', 'conversa_id') into tem_alteracoes;

  ------------------------------------------------------------------
  -- Os grupos: contatos que são o mesmo celular. A chave é a de
  -- `variantesDoNumero` na ponte: sem o 55, e com o nono dígito posto no
  -- celular de 10 dígitos. Só celular ganha o 9 — fixo tem 8 dígitos começando
  -- em 2..5, e pôr um 9 nele juntaria dois clientes diferentes.
  ------------------------------------------------------------------
  create temporary table _035_contatos on commit drop as
  with limpos as (
    select id::text as id, nome, numero,
           regexp_replace(coalesce(numero, ''), '[^0-9]', '', 'g') as dig
      from public.contatos
     where coalesce(numero, '') not like 'grupo:%'
  ),
  nacionais as (
    select id, nome, numero,
           case when dig like '55%' and length(dig) in (12, 13) then substr(dig, 3) else dig end as nac
      from limpos
  ),
  chaves as (
    select id, nome, numero,
           case when length(nac) = 10 and substr(nac, 3, 1) in ('6', '7', '8', '9')
                then substr(nac, 1, 2) || '9' || substr(nac, 3)
                else nac end as chave
      from nacionais
     where length(nac) between 10 and 11
  )
  select c.id, c.nome, c.numero, c.chave,
         null::timestamptz as escreveu, null::timestamptz as nasceu
    from chaves c
   where c.chave in (select chave from chaves group by chave having count(*) > 1);

  -- A mensagem mais recente que o CLIENTE mandou, por contato.
  if to_regclass('public.mensagens') is not null then
    update _035_contatos d
       set escreveu = (select max(m.criado_em)
                         from public.mensagens m
                         join public.conversas v on v.id = m.conversa_id
                        where v.contato_id::text = d.id and m.origem = 'contato');
  end if;
  if tem_criado then
    execute 'update _035_contatos d set nasceu = (select ct.criado_em from public.contatos ct
                                                   where ct.id::text = d.id)';
  end if;

  ------------------------------------------------------------------
  -- O que se leva de uma conversa para a outra: o que o "Juntar duas
  -- conversas" leva, das tabelas que existem neste banco.
  ------------------------------------------------------------------
  create temporary table _035_tabelas on commit drop as
  select t as tabela
    from unnest(array['mensagens', 'notas', 'fila_envio', 'zorvin_tarefas',
                      'zorvin_tratamentos', 'conversa_tags',
                      'zorvin_respostas_automaticas']) t
   where to_regclass('public.' || t) is not null;

  -- Os índices únicos de cada uma que incluem `conversa_id`: é o que diz se
  -- mover a linha bate de frente com uma que a conversa que fica já tem. Um
  -- índice com uma coluna só (`conversa_id`) quer dizer "uma linha por
  -- conversa". O índice parcial e o de expressão ficam de fora: lido pelas
  -- colunas, o de expressão pareceria "uma linha por conversa" e apagaria o
  -- que não bate. Se um deles existisse e batesse, o banco recusaria a
  -- junção inteira, que é o lado seguro.
  create temporary table _035_unicos on commit drop as
  select pc.relname::text as tabela,
         array(select a.attname::text
                 from unnest(i.indkey) with ordinality k(attnum, ord)
                 join pg_attribute a on a.attrelid = i.indrelid and a.attnum = k.attnum
                where a.attname <> 'conversa_id'
                order by k.ord) as outras
    from pg_index i
    join pg_class pc     on pc.oid = i.indrelid
    join pg_namespace ns on ns.oid = pc.relnamespace
   where ns.nspname = 'public' and i.indisunique and i.indpred is null
     and i.indexprs is null
     and pc.relname in (select tabela from _035_tabelas)
     and exists (select 1 from pg_attribute a
                  where a.attrelid = i.indrelid and a.attname = 'conversa_id'
                    and a.attnum = any (i.indkey));

  ------------------------------------------------------------------
  -- Um celular por vez.
  ------------------------------------------------------------------
  for g in select distinct chave from _035_contatos order by chave loop

    select d.id into fica
      from _035_contatos d where d.chave = g.chave
     order by d.escreveu desc nulls last, d.nasceu asc nulls last, d.id
     limit 1;

    for perdedor in
      select d.id, d.nome, d.numero from _035_contatos d
       where d.chave = g.chave and d.id <> fica
       order by d.id
    loop
      convs := 0; msgs := 0; detalhe := '';

      ----------------------------------------------------------------
      -- As conversas.
      ----------------------------------------------------------------
      for cv in select v.id::text as id, v.advogado_id::text as adv
                  from public.conversas v where v.contato_id::text = perdedor.id
      loop
        select v.id::text into destino
          from public.conversas v
         where v.contato_id::text = fica and v.advogado_id::text is not distinct from cv.adv
         limit 1;

        if destino is null then
          -- Quem fica não tem conversa nesse telefone: a conversa muda de dono.
          update public.conversas
             set contato_id = (select ct.id from public.contatos ct where ct.id::text = fica)
           where id::text = cv.id;
          convs   := convs + 1;
          detalhe := detalhe || 'conversa passou para quem fica; ';
          continue;
        end if;

        -- As duas existem: leva o que está pendurado e apaga a que sobra.
        for tab in select tabela from _035_tabelas order by tabela loop
          for u in select outras from _035_unicos where tabela = tab loop
            select string_agg(format('d.%I = o.%I', c, c), ' and ') into cond
              from unnest(u.outras) c;
            execute format(
              'delete from public.%I o
                where o.conversa_id::text = $1
                  and exists (select 1 from public.%I d where d.conversa_id::text = $2%s)',
              tab, tab, coalesce(' and ' || cond, '')) using cv.id, destino;
          end loop;

          execute format(
            'update public.%I set conversa_id =
                (select v.id from public.conversas v where v.id::text = $1)
              where conversa_id::text = $2', tab)
            using destino, cv.id;
          get diagnostics n = row_count;
          if tab = 'mensagens' then msgs := msgs + n; end if;
        end loop;

        if tem_lidas then
          update public.conversas d
             set nao_lidas = coalesce(d.nao_lidas, 0)
                           + coalesce((select o.nao_lidas from public.conversas o where o.id::text = cv.id), 0)
           where d.id::text = destino;
        end if;
        if tem_ultima and tem_resumo then
          update public.conversas d
             set ultima_mensagem = o.ultima_mensagem, ultima_atividade = o.ultima_atividade
            from public.conversas o
           where d.id::text = destino and o.id::text = cv.id
             and o.ultima_atividade > coalesce(d.ultima_atividade, '-infinity'::timestamptz);
        elsif tem_ultima then
          update public.conversas d
             set ultima_atividade = o.ultima_atividade
            from public.conversas o
           where d.id::text = destino and o.id::text = cv.id
             and o.ultima_atividade > coalesce(d.ultima_atividade, '-infinity'::timestamptz);
        end if;

        if tem_alteracoes then
          update public.alteracoes
             set conversa_id = (select v.id from public.conversas v where v.id::text = destino)
           where conversa_id::text = cv.id;
        end if;

        delete from public.conversas where id::text = cv.id;

        -- A espera (o 005) e a situação (o 028) da conversa que fica, do
        -- zero: mudar mensagem de casa é UPDATE, e os gatilhos só veem INSERT.
        if to_regprocedure('public.zorvin_recontar_espera(uuid)') is not null then
          perform public.zorvin_recontar_espera(destino::uuid);
        end if;
        if to_regprocedure('public.zorvin_recontar_situacao(uuid)') is not null then
          perform public.zorvin_recontar_situacao(destino::uuid);
        end if;

        convs   := convs + 1;
        detalhe := detalhe || 'conversas juntadas; ';
      end loop;

      ----------------------------------------------------------------
      -- O funil.
      ----------------------------------------------------------------
      if tem_funil then
        -- O cartão de um departamento onde quem fica já tem o seu: sai, e o
        -- histórico dele também (o gatilho do 017 anota a saída, e ela sai
        -- junto — o contato não devia existir).
        delete from public.zorvin_cartoes o
         where o.contato_id::text = perdedor.id
           and exists (select 1 from public.zorvin_cartoes d
                        where d.contato_id::text = fica
                          and d.departamento_id = o.departamento_id);
        if to_regclass('public.zorvin_movimentos') is not null then
          delete from public.zorvin_movimentos m
           where m.contato_id::text = perdedor.id
             and exists (select 1 from public.zorvin_cartoes d
                          where d.contato_id::text = fica
                            and d.departamento_id = m.departamento_id);
          update public.zorvin_movimentos
             set contato_id = (select ct.id from public.contatos ct where ct.id::text = fica)
           where contato_id::text = perdedor.id;
        end if;
        update public.zorvin_cartoes
           set contato_id = (select ct.id from public.contatos ct where ct.id::text = fica)
         where contato_id::text = perdedor.id;
        get diagnostics n = row_count;
        if n > 0 then detalhe := detalhe || 'cartão do funil passou para quem fica; '; end if;
      end if;

      if tem_alteracoes then
        update public.alteracoes
           set contato_id = (select ct.id from public.contatos ct where ct.id::text = fica)
         where contato_id::text = perdedor.id;
      end if;

      ----------------------------------------------------------------
      -- O contato que sai — só se ficou sem conversa nenhuma —, e o que só
      -- ele tinha passa para quem fica: nome, foto, o cliente do Vantoro.
      -- Depois de apagado, para um campo único (o cliente do Vantoro) não
      -- bater nele mesmo.
      ----------------------------------------------------------------
      select to_jsonb(ct) into saiu from public.contatos ct where ct.id::text = perdedor.id;
      delete from public.contatos ct
       where ct.id::text = perdedor.id
         and not exists (select 1 from public.conversas v where v.contato_id::text = perdedor.id);
      get diagnostics n = row_count;

      if n > 0 then
        juntados := juntados + 1;
        for col in
          select c.column_name::text from information_schema.columns c
           where c.table_schema = 'public' and c.table_name = 'contatos'
             and c.column_name not in ('id', 'numero', 'criado_em', 'atualizado_em')
             and c.is_generated = 'NEVER' and c.is_identity = 'NO'
        loop
          begin
            execute format(
              'update public.contatos w
                  set %1$I = (jsonb_populate_record(null::public.contatos, $1)).%1$I
                where w.id::text = $2
                  and (w.%1$I is null or w.%1$I::text = '''')
                  and (jsonb_populate_record(null::public.contatos, $1)).%1$I is not null
                  and (jsonb_populate_record(null::public.contatos, $1)).%1$I::text <> ''''', col)
              using saiu, fica;
            get diagnostics n = row_count;
            if n > 0 then detalhe := detalhe || format('%s veio do contato que saiu; ', col); end if;
          exception when unique_violation then
            detalhe := detalhe || format('%s ficou como estava (já é de outro contato); ', col);
          end;
        end loop;
      end if;

      insert into public.juntada_contatos_log
        (celular, ficou_id, ficou_nome, ficou_numero,
         saiu_id, saiu_nome, saiu_numero, conversas, mensagens, detalhe)
      select g.chave, ct.id::text, ct.nome, ct.numero,
             perdedor.id, perdedor.nome, perdedor.numero, convs, msgs, nullif(detalhe, '')
        from public.contatos ct where ct.id::text = fica;
    end loop;
  end loop;

  ------------------------------------------------------------------
  -- A conferência: quantos saíram, e se sobrou algum celular repetido.
  ------------------------------------------------------------------
  insert into zorvin_conferencia_035
  select 'contatos juntados agora', juntados::text
  union all
  select 'nenhum celular com dois contatos',
         (not exists (
            with limpos as (
              select regexp_replace(coalesce(numero, ''), '[^0-9]', '', 'g') as dig
                from public.contatos where coalesce(numero, '') not like 'grupo:%'
            ),
            nacionais as (
              select case when dig like '55%' and length(dig) in (12, 13) then substr(dig, 3) else dig end as nac
                from limpos
            )
            select 1
              from nacionais
             where length(nac) between 10 and 11
             group by case when length(nac) = 10 and substr(nac, 3, 1) in ('6', '7', '8', '9')
                           then substr(nac, 1, 2) || '9' || substr(nac, 3) else nac end
            having count(*) > 1))::text;
end $juntar$;

-- A RESPOSTA DE "DEU CERTO?", na última linha, que é a que o editor mostra.
select * from zorvin_conferencia_035;
