-- ============================================================
--  A FILA ACEITA O STATUS "cancelada"
--
--  >>> RODAR NO SUPABASE DO **ZORVIN** (o das conversas). <<<
--  Dashboard → SQL Editor → New query → cole tudo → Run.
--  Pode rodar de novo sem medo.
--
--  ------------------------------------------------------------
--  POR QUE EXISTE
--
--  O script 013 (a mensagem agendada) perguntou, na conferência dele, se o
--  banco aceita o status 'cancelada' — e no banco do escritório a resposta foi
--  NÃO (02/10). Existe em `fila_envio` uma regra (CHECK) com a lista fechada de
--  status, criada à mão no começo do projeto e que não está em arquivo nenhum.
--  Sem 'cancelada' na lista, todo "Cancelar" de mensagem agendada seria
--  recusado pelo banco (código 23514).
--
--  O 013 NÃO FOI EDITADO, e não pode ser: script aplicado não se edita (a
--  ponte guarda a impressão digital). O conserto é o próximo número.
--
--  ------------------------------------------------------------
--  O QUE ELE FAZ — E O QUE ELE SE RECUSA A FAZER
--
--  Para cada regra de `fila_envio` que fala de `status` e não conhece
--  'cancelada', ele confere se ela é SÓ uma lista de valores — a forma em que
--  o Postgres escreve `status in ('a','b',...)`. Sendo, ele a refaz com a MESMA
--  lista mais 'cancelada', com o mesmo nome. Nenhum valor que já valia deixa
--  de valer.
--
--  Se a regra tiver qualquer outra coisa dentro (outra coluna, um "and", uma
--  conta), ele NÃO MEXE — reescrever o que não se entende inteiro é o jeito de
--  afrouxar uma regra sem ninguém ver. Aí a conferência mostra a regra como
--  ela é, e o conserto vira uma conversa.
--
--  A troca acontece numa transação só (o editor do Supabase roda tudo junto):
--  não existe instante em que a fila fique sem regra nenhuma.
-- ============================================================

do $cancelada$
declare
  r record;
  valores text[];
  resto text;
  ajustadas int := 0;
  recusadas int := 0;
begin
  -- A TABELA DA CONFERÊNCIA NASCE ANTES DA GUARDA — a lição do 006 e do 007.
  drop table if exists zorvin_conferencia_014;
  create temp table zorvin_conferencia_014 (item text, resposta text);

  if to_regclass('public.fila_envio') is null then
    insert into zorvin_conferencia_014
      values ('sem as tabelas do Zorvin', 'nada a fazer aqui');
    raise notice 'Zorvin: sem a fila de envio — script 014 não fez nada.';
    return;
  end if;

  for r in
    select c.conname, pg_get_constraintdef(c.oid) as def
      from pg_constraint c
     where c.conrelid = 'public.fila_envio'::regclass and c.contype = 'c'
       and pg_get_constraintdef(c.oid) ilike '%status%'
       and pg_get_constraintdef(c.oid) !~* '\mcancelada\M'
  loop
    -- OS VALORES DA LISTA: tudo o que está entre aspas simples. O Postgres
    -- escreve a lista de dois jeitos — `ARRAY['a'::text, 'b'::text]` ou
    -- `'{a,b}'::text[]` — e o segundo é um literal só, que se abre aqui.
    select array_agg(v order by n, k)
      into valores
      from regexp_matches(r.def, '''([^'']*)''', 'g') with ordinality as t(m, n),
           lateral unnest(case when m[1] like '{%}'
                               then string_to_array(btrim(m[1], '{}'), ',')
                               else array[m[1]] end) with ordinality as u(v, k);

    -- O QUE SOBRA sem os valores, os tipos e a pontuação tem de ser só a
    -- palavra "status" e as palavras da forma da lista. Qualquer outra coisa
    -- (outra coluna, "AND", "OR", "IS NOT NULL", uma função) = não mexo.
    resto := regexp_replace(r.def, '''[^'']*''', ' ', 'g');
    resto := regexp_replace(resto, '::\s*(text|character varying|varchar|character|bpchar)(\[\])?', ' ', 'gi');
    resto := regexp_replace(resto, '\m(CHECK|status|ANY|ARRAY|IN)\M', ' ', 'gi');
    resto := regexp_replace(resto, '[\s\(\)\[\],=]', '', 'g');

    if resto = '' and coalesce(array_length(valores, 1), 0) > 0 then
      execute format('alter table public.fila_envio drop constraint %I', r.conname);
      -- Escrita como `ARRAY['a', 'b', …]`, um literal por valor: é a forma que
      -- o Postgres devolve com cada valor entre aspas, e é ela que esta mesma
      -- leitura sabe abrir na próxima rodada.
      execute format(
        'alter table public.fila_envio add constraint %I check (status::text = any (array[%s]::text[]))',
        r.conname,
        (select string_agg(quote_literal(v), ', ') from unnest(array_append(valores, 'cancelada')) v));
      ajustadas := ajustadas + 1;
      raise notice 'Zorvin: a regra % passou a aceitar cancelada.', r.conname;
    else
      recusadas := recusadas + 1;
      insert into zorvin_conferencia_014
        values ('NÃO MEXI nesta regra (mande a foto): ' || r.conname, r.def);
    end if;
  end loop;

  -- ----------------------------------------------------------
  --  A CONFERÊNCIA — a última linha do script, que é a que o editor mostra.
  -- ----------------------------------------------------------
  insert into zorvin_conferencia_014
  select 'regras ajustadas agora'::text, ajustadas::text
  union all
  select 'o banco aceita o status cancelada',
         (not exists (select 1 from pg_constraint
                       where conrelid = 'public.fila_envio'::regclass and contype = 'c'
                         and pg_get_constraintdef(oid) ilike '%status%'
                         and pg_get_constraintdef(oid) !~* '\mcancelada\M'))::text
  union all
  select 'a regra de status, como ficou: ' || conname, pg_get_constraintdef(oid)
    from pg_constraint
   where conrelid = 'public.fila_envio'::regclass and contype = 'c'
     and pg_get_constraintdef(oid) ilike '%status%';
end $cancelada$;

select * from zorvin_conferencia_014;
