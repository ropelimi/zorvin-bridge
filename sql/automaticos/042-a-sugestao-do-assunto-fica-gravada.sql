-- ============================================================
--  A SUGESTÃO DA IA NO "FINALIZAR" FICA GRAVADA (para medir os acertos)
--
--  >>> RODAR NO SUPABASE DO **ZORVIN** (o das conversas). <<<
--  Quem roda é a PONTE, sozinha, na publicação que vem com o merge.
--  Pode rodar de novo sem medo.
--
--  ------------------------------------------------------------
--  O QUE ISTO ACRESCENTA
--
--  Recomendação nº 5 de 31/10, pedida pelo Rodrigo em 01/11: "A IA sugere o
--  assunto no Finalizar. A lista já abre com o assunto provável marcado, e a
--  pessoa só confere." Quem sugere é a ponte (`POST /copiloto/assunto`); quem
--  marca e grava é o painel.
--
--  E fica gravado O QUE A IA TINHA SUGERIDO, junto do que a pessoa
--  confirmou. Sem isso não há como dizer quantas vezes a IA acertou — e uma
--  sugestão que erra muito, sem ninguém saber, vira o assunto errado no
--  relatório, confirmado por quem conferiu com pressa.
--
--  Uma coluna em `zorvin_tratamentos`, opcional:
--
--    sugestao_ia  o que a IA sugeriu para aquele clique, igual em todas as
--                 linhas dele (um clique são as linhas de um mesmo insert):
--                   {"assuntos": ["<id>", ...], "marcou": true}
--                 `assuntos` são os ids que a IA sugeriu (nenhum, um ou
--                 dois); `marcou` diz se a janela os marcou sozinha (a pessoa
--                 ainda não tinha mexido) ou se eles chegaram só como dica,
--                 com a pessoa já marcando. NULA quando não houve sugestão.
--
--  A conta do acerto, depois: o clique com sugestão em que os assuntos
--  gravados são os mesmos que a IA sugeriu.
--
--  UMA REGRA: é um objeto, de no máximo 2000 caracteres. Quem grava é a tela
--  de quem atende, e a coluna não pode virar depósito de outra coisa.
--
--  NENHUMA PERMISSÃO NOVA: `grant insert on zorvin_tratamentos` (script 005)
--  é da TABELA inteira, e vale para a coluna nova. A conferência confere isso
--  no papel de quem atende.
--
--  ------------------------------------------------------------
--  ENQUANTO ESTE ARQUIVO NÃO FOR RODADO
--
--  O Finalizar continua igual. O painel manda a coluna e, se o banco disser
--  que ela não existe, grava o clique sem ela — a sugestão some do registro,
--  e o registro não se perde.
-- ============================================================

do $sugestao$
begin
  -- A TABELA DA CONFERÊNCIA NASCE ANTES DA GUARDA — a lição do 006 e do 007.
  drop table if exists zorvin_conferencia_042;
  create temp table zorvin_conferencia_042 (item text, resposta text);

  -- A TABELA DOS TRATAMENTOS NASCE NO 005, DENTRO DO BLOCO GUARDADO: num
  -- banco sem o Zorvin ela não existe, e este script não tem o que fazer.
  if to_regclass('public.zorvin_tratamentos') is null then
    insert into zorvin_conferencia_042
      values ('sem a tabela do "Já tratei"', 'nada a fazer aqui');
    raise notice 'Zorvin: sem a tabela zorvin_tratamentos — script 042 não fez nada.';
    return;
  end if;

  execute 'alter table public.zorvin_tratamentos add column if not exists sugestao_ia jsonb';

  if not exists (select 1 from pg_constraint
                  where conrelid = 'public.zorvin_tratamentos'::regclass
                    and conname = 'zorvin_tratamentos_sugestao_ia_forma') then
    execute $c$alter table public.zorvin_tratamentos
      add constraint zorvin_tratamentos_sugestao_ia_forma
      check (sugestao_ia is null
             or (jsonb_typeof(sugestao_ia) = 'object' and length(sugestao_ia::text) <= 2000))$c$;
  end if;

  execute $c$comment on column public.zorvin_tratamentos.sugestao_ia is
    'O que a IA sugeriu no Finalizar para este clique: {"assuntos": [ids], "marcou": bool}. '
    'Igual em todas as linhas do clique; nula sem sugestão. Serve para medir os acertos.'$c$;

  insert into zorvin_conferencia_042
  select 'a coluna da sugestão existe'::text,
         exists (select 1 from information_schema.columns
                  where table_schema = 'public' and table_name = 'zorvin_tratamentos'
                    and column_name = 'sugestao_ia' and data_type = 'jsonb')::text
  union all
  select 'a regra da forma existe',
         exists (select 1 from pg_constraint
                  where conrelid = 'public.zorvin_tratamentos'::regclass
                    and conname = 'zorvin_tratamentos_sugestao_ia_forma')::text
  -- O PAPEL PERGUNTADO PELO `case`, e não por um `or`: o Postgres não promete
  -- a ordem de um `or`, e `has_column_privilege` de um papel que não existe
  -- estoura — num banco de prova sem `authenticated`, o script inteiro.
  union all
  select 'quem entrou consegue GRAVAR a sugestão junto do clique',
         case when not exists (select 1 from pg_roles where rolname = 'authenticated') then 'sem o papel authenticated'
              else has_column_privilege('authenticated', 'public.zorvin_tratamentos', 'sugestao_ia', 'INSERT')::text end
  union all
  select 'quem entrou consegue LER a sugestão',
         case when not exists (select 1 from pg_roles where rolname = 'authenticated') then 'sem o papel authenticated'
              else has_column_privilege('authenticated', 'public.zorvin_tratamentos', 'sugestao_ia', 'SELECT')::text end
  union all
  select 'cliques com sugestão da IA gravada',
         (select count(distinct (conversa_id, quem, quando))
            from public.zorvin_tratamentos where sugestao_ia is not null)::text;
end $sugestao$;

-- A RESPOSTA DE "DEU CERTO?", na última linha, que é a que o editor mostra.
select * from zorvin_conferencia_042;
