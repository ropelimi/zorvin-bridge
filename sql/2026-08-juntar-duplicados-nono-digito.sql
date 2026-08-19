-- ------------------------------------------------------------
--  2. JUNTAR OS CONTATOS DUPLICADOS PELO NONO DÍGITO
--
--  Roda a mesma conta do script de conferência (1) e faz o que ele mostrou:
--  para cada celular que virou dois contatos ("+55 31 9945-6790" e
--  "+55 31 99945-6790"), sobra UM contato só, com todo o histórico junto.
--
--  QUEM FICA: o contato cuja conversa teve atividade mais recente — é por onde
--  o cliente está falando hoje. É a MESMA regra do script de conferência, então
--  a lista que você viu é exatamente o que vai acontecer aqui.
--
--  O NÚMERO DE QUEM FICA é corrigido para a forma completa (55 + DDD + 9 +
--  número). Sem isso, se quem ficou fosse o contato escrito sem o nono dígito,
--  a próxima mensagem que a equipe mandasse sairia para um número que não
--  existe — o contato certo, com o telefone errado.
--
--  NADA SE PERDE: mensagem, nota interna, etiqueta e envio ainda na fila são
--  MOVIDOS para a conversa que fica, e só depois a conversa vazia é apagada.
--  As não lidas das duas se somam. As tabelas penduradas na conversa são
--  descobertas na hora (qualquer tabela com a coluna `conversa_id`), então uma
--  tabela nova criada depois deste script também é levada junto, em vez de
--  sumir em cascata sem ninguém ver.
--
--  TUDO OU NADA: é um bloco só. Se qualquer passo falhar, o banco volta
--  exatamente como estava — não existe "juntou metade".
--
--  Seguro rodar de novo: na segunda vez não há mais duplicado, e ele não faz
--  nada.
--
--  Depois de rodar, a última consulta mostra o relatório do que foi feito.
-- ------------------------------------------------------------

-- Onde fica o registro do que foi juntado (para conferir depois, e para saber
-- de onde veio cada conversa se alguém perguntar).
create table if not exists juntada_contatos_log (
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
alter table juntada_contatos_log enable row level security;

do $$
declare
  g            record;
  perdedor     record;
  cv           record;
  tab          record;
  fica_id      text;
  fica_nome    text;
  fica_numero  text;
  destino_id   text;
  cond         text;
  n            int;
  msgs         int;
  convs        int;
  detalhe      text;
  numero_certo text;
  ja_usado     int;
begin
  ------------------------------------------------------------------
  -- Os grupos: contatos que são o mesmo celular.
  --
  -- Só celular ganha o nono dígito. Fixo tem 8 dígitos e começa em 2..5;
  -- pôr um 9 nele inventaria um número que não existe — e juntaria dois
  -- clientes diferentes.
  ------------------------------------------------------------------
  create temporary table _juntar_dup on commit drop as
  with limpos as (
    select id::text as id, nome, numero,
           regexp_replace(coalesce(numero, ''), '[^0-9]', '', 'g') as dig
      from contatos
  ),
  nacionais as (
    select id, nome, numero,
           case when dig like '55%' and length(dig) in (12, 13)
                then substr(dig, 3) else dig end as nac
      from limpos
  ),
  chaves as (
    select id, nome, numero,
           case when length(nac) = 10 and substr(nac, 3, 1) in ('6','7','8','9')
                then substr(nac, 1, 2) || '9' || substr(nac, 3)
                else nac end as chave
      from nacionais
     where length(nac) between 10 and 11
  ),
  repetidos as (
    select chave from chaves group by chave having count(*) > 1
  )
  select c.id, c.nome, c.numero, c.chave,
         (select max(v.ultima_atividade) from conversas v
           where v.contato_id::text = c.id) as visto
    from chaves c join repetidos r on r.chave = c.chave;

  ------------------------------------------------------------------
  -- As tabelas penduradas na conversa, descobertas AGORA (não uma lista
  -- fixa que envelhece). Para cada uma, as colunas do índice único que
  -- inclui `conversa_id` — é o que diz se mover a linha bate de frente com
  -- uma linha que o destino já tem (o caso da etiqueta repetida).
  ------------------------------------------------------------------
  create temporary table _juntar_tabelas on commit drop as
  with unicos as (
    select pc.relname as tabela,
           (select array_agg(a.attname order by k.ord)
              from unnest(i.indkey) with ordinality k(attnum, ord)
              join pg_attribute a on a.attrelid = i.indrelid
                                 and a.attnum  = k.attnum) as cols
      from pg_index i
      join pg_class pc     on pc.oid = i.indrelid
      join pg_namespace ns on ns.oid = pc.relnamespace
     where ns.nspname = 'public' and i.indisunique
  ),
  alvos as (
    select c.table_name as tabela
      from information_schema.columns c
      join information_schema.tables  t
        on t.table_schema = c.table_schema and t.table_name = c.table_name
     where c.table_schema = 'public' and c.column_name = 'conversa_id'
       and t.table_type = 'BASE TABLE'
       and c.table_name <> 'conversas'
  )
  select a.tabela,
         (select u.cols from unicos u
           where u.tabela = a.tabela and 'conversa_id' = any (u.cols)
           limit 1) as unicas
    from alvos a;

  ------------------------------------------------------------------
  -- Um celular por vez.
  ------------------------------------------------------------------
  for g in select distinct chave from _juntar_dup order by chave loop

    select d.id, d.nome, d.numero into fica_id, fica_nome, fica_numero
      from _juntar_dup d where d.chave = g.chave
     order by d.visto desc nulls last, d.id
     limit 1;

    for perdedor in
      select d.id, d.nome, d.numero from _juntar_dup d
       where d.chave = g.chave and d.id <> fica_id
       order by d.id
    loop
      convs := 0; msgs := 0; detalhe := '';

      for cv in select v.id::text as id, v.advogado_id::text as adv,
                       v.nao_lidas, v.ultima_atividade
                  from conversas v where v.contato_id::text = perdedor.id
      loop
        select v.id::text into destino_id
          from conversas v
         where v.contato_id::text = fica_id and v.advogado_id::text = cv.adv
         limit 1;

        if destino_id is null then
          -- Quem fica não tem conversa nesse telefone: a conversa inteira
          -- muda de dono. Nada é movido, nada é apagado.
          update conversas
             set contato_id = (select ct.id from contatos ct where ct.id::text = fica_id)
           where id::text = cv.id;
          convs   := convs + 1;
          detalhe := detalhe || 'conversa passou para quem fica; ';
          continue;
        end if;

        -- As duas existem: move o que está pendurado e apaga a que sobra.
        for tab in select t.tabela, t.unicas from _juntar_tabelas t order by t.tabela loop
          if tab.unicas is not null and array_length(tab.unicas, 1) > 1 then
            select string_agg(format('d.%I is not distinct from o.%I', c, c), ' and ')
              into cond
              from unnest(tab.unicas) c where c <> 'conversa_id';
            if cond is not null then
              execute format(
                'delete from public.%I o
                  where o.conversa_id::text = $1
                    and exists (select 1 from public.%I d
                                 where d.conversa_id::text = $2 and %s)',
                tab.tabela, tab.tabela, cond) using cv.id, destino_id;
            end if;
          end if;

          execute format(
            'update public.%I set conversa_id =
                (select v.id from conversas v where v.id::text = $1)
              where conversa_id::text = $2', tab.tabela)
            using destino_id, cv.id;
          get diagnostics n = row_count;
          if tab.tabela = 'mensagens' then msgs := msgs + n; end if;
        end loop;

        update conversas d
           set nao_lidas        = coalesce(d.nao_lidas, 0) + coalesce(cv.nao_lidas, 0),
               ultima_atividade = greatest(d.ultima_atividade, cv.ultima_atividade)
         where d.id::text = destino_id;

        delete from conversas where id::text = cv.id;
        convs   := convs + 1;
        detalhe := detalhe || 'conversas juntadas; ';
      end loop;

      -- Só sai o contato que ficou realmente sem conversa nenhuma.
      delete from contatos ct
       where ct.id::text = perdedor.id
         and not exists (select 1 from conversas v where v.contato_id::text = perdedor.id);

      insert into juntada_contatos_log
        (celular, ficou_id, ficou_nome, ficou_numero,
         saiu_id, saiu_nome, saiu_numero, conversas, mensagens, detalhe)
      values (g.chave, fica_id, fica_nome, fica_numero,
              perdedor.id, perdedor.nome, perdedor.numero, convs, msgs,
              nullif(detalhe, ''));
    end loop;

    ------------------------------------------------------------------
    -- O número de quem ficou passa a ser a forma completa.
    ------------------------------------------------------------------
    numero_certo := '55' || g.chave;
    select count(*) into ja_usado
      from contatos ct where ct.numero = numero_certo and ct.id::text <> fica_id;
    if ja_usado = 0 and fica_numero is distinct from numero_certo then
      update contatos set numero = numero_certo where id::text = fica_id;
      insert into juntada_contatos_log
        (celular, ficou_id, ficou_nome, ficou_numero, detalhe)
      values (g.chave, fica_id, fica_nome, numero_certo,
              format('número corrigido: %s -> %s', fica_numero, numero_certo));
    end if;

  end loop;
end $$;

-- O relatório do que acabou de ser feito.
select to_char(em, 'DD/MM/YYYY HH24:MI') as quando,
       celular, ficou_nome, ficou_numero,
       saiu_nome, saiu_numero, conversas, mensagens, detalhe
  from juntada_contatos_log
 where em > now() - interval '5 minutes'
 order by id;
