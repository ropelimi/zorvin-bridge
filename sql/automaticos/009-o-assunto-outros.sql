-- ============================================================
--  O ASSUNTO "OUTROS" DO "JÁ TRATEI"
--
--  >>> RODAR NO SUPABASE DO **ZORVIN** (o das conversas). <<<
--  Dashboard → SQL Editor → New query → cole tudo → Run.
--  Pode rodar de novo sem medo.
--
--  ------------------------------------------------------------
--  O QUE ISTO ACRESCENTA
--
--  Pedido do Rodrigo em 30/09: a checklist do "Já tratei" precisa de uma
--  opção "OUTROS". Os oito assuntos cobrem o dia a dia do escritório; o que
--  sobra não tem onde ir, e a equipe marca o assunto mais parecido — que é o
--  relatório mentindo em silêncio.
--
--  "OUTROS" SOZINHO NÃO DIZ NADA. Um relatório com "OUTROS: 40" não responde
--  o que a equipe fez; é a mesma pergunta de antes, com um número em cima.
--  Por isso ele vem com uma DESCRIÇÃO obrigatória, escrita por quem tratou:
--
--    zorvin_assuntos.pede_descricao    este assunto exige texto
--    zorvin_tratamentos.observacao     o texto que foi escrito
--
--  A MARCA É UMA COLUNA, e não o nome "OUTROS" escrito no painel. Quem compra
--  o programa pode chamar de "Diversos", ou querer descrição também em
--  "RECLAMAÇÃO"; conferir o nome à mão seria uma regra escondida que só vale
--  para o escritório. A chave fica na tela de administração.
--
--  ------------------------------------------------------------
--  RODAR DE NOVO NÃO DESFAZ ESCOLHA DE NINGUÉM
--
--  O "OUTROS" nasce com a marca ligada UMA VEZ: na rodada em que a coluna é
--  criada. Se depois alguém desligar a marca pela tela, rodar o script de
--  novo não a religa — um script que desfaz configuração a cada rodada é o
--  tipo de coisa que se descobre como "mudou sozinho".
--
--  E se o escritório já tiver um assunto chamado "Outros" (criado à mão),
--  ele é aproveitado: ganha a marca, em vez de nascer um segundo.
--
--  ------------------------------------------------------------
--  DEPENDE DE JÁ TER RODADO
--    005 — o "Já tratei" (assuntos e tratamentos)
-- ============================================================

-- A GUARDA EXISTE POR CAUSA DA PROVA 51l-bis, que aplica esta pasta num banco
-- LIMPO. Lá `zorvin_assuntos` existe (o 005 a cria fora do bloco guardado), mas
-- `zorvin_tratamentos` não — ela depende de `conversas`. Cada metade é
-- conferida por si.
do $outros$
declare
  coluna_nova boolean;
begin
  -- A TABELA DA CONFERÊNCIA NASCE ANTES DA GUARDA — a lição do 006 e do 007:
  -- criada depois, o `select` da última linha estoura num banco limpo.
  drop table if exists zorvin_conferencia_009;
  create temp table zorvin_conferencia_009 (item text, resposta text);

  if to_regclass('public.zorvin_assuntos') is null then
    insert into zorvin_conferencia_009
      values ('sem a tabela dos assuntos', 'rode o script 005 antes');
    raise notice 'Zorvin: sem zorvin_assuntos — script 009 não fez nada. Rode o 005 antes.';
    return;
  end if;

  coluna_nova := not exists (
    select 1 from information_schema.columns
     where table_schema = 'public' and table_name = 'zorvin_assuntos'
       and column_name = 'pede_descricao');

  execute 'alter table public.zorvin_assuntos
             add column if not exists pede_descricao boolean not null default false';

  execute $c$comment on column public.zorvin_assuntos.pede_descricao is
    'Marcar este assunto no "Já tratei" exige escrever o que foi tratado '
    '(zorvin_tratamentos.observacao). Nasce ligada no OUTROS.'$c$;

  -- O OUTROS: aproveita um que já exista (ativo), senão cria no fim da lista.
  -- A marca só é ligada na rodada que criou a coluna — ver o cabeçalho.
  if coluna_nova then
    update public.zorvin_assuntos
       set pede_descricao = true
     where ativo and lower(nome) = 'outros';
  end if;

  if not exists (select 1 from public.zorvin_assuntos
                  where ativo and lower(nome) = 'outros') then
    insert into public.zorvin_assuntos (nome, ordem, pede_descricao)
    select 'OUTROS', coalesce(max(ordem), 0) + 1, true
      from public.zorvin_assuntos;
  end if;

  -- O TEXTO, em quem registra. Guardado só se a tabela existir: num banco sem
  -- `conversas`, o 005 não criou os tratamentos.
  if to_regclass('public.zorvin_tratamentos') is not null then
    execute 'alter table public.zorvin_tratamentos add column if not exists observacao text';

    -- UM TETO, para o relatório continuar sendo relatório: 500 caracteres
    -- cabem com folga o que se escreve numa linha de atendimento, e um texto
    -- colado de vinte parágrafos viraria uma tabela ilegível.
    if not exists (select 1 from pg_constraint
                    where conname = 'zorvin_tratamentos_observacao_tamanho'
                      and conrelid = 'public.zorvin_tratamentos'::regclass) then
      execute 'alter table public.zorvin_tratamentos
                 add constraint zorvin_tratamentos_observacao_tamanho
                 check (observacao is null or char_length(observacao) <= 500)';
    end if;

    execute $c$comment on column public.zorvin_tratamentos.observacao is
      'O que foi tratado, escrito por quem tratou. Obrigatório (pelo painel) '
      'quando o assunto pede_descricao; nulo nos outros.'$c$;
  end if;

  -- ----------------------------------------------------------
  --  A CONFERÊNCIA VAI DENTRO DO SCRIPT, e é a última linha dele: o editor do
  --  Supabase só mostra o resultado do último comando.
  -- ----------------------------------------------------------
  insert into zorvin_conferencia_009
  select 'o OUTROS existe e pede descrição'::text,
         exists (select 1 from public.zorvin_assuntos
                  where ativo and lower(nome) = 'outros' and pede_descricao)::text
  union all
  select 'o registro guarda o texto',
         exists (select 1 from information_schema.columns
                  where table_schema = 'public' and table_name = 'zorvin_tratamentos'
                    and column_name = 'observacao')::text
  union all
  select 'assuntos que pedem descrição',
         (select string_agg(nome, ', ' order by ordem)
            from public.zorvin_assuntos where ativo and pede_descricao);
end $outros$;

-- A RESPOSTA DE "DEU CERTO?", na última linha, que é a que o editor mostra.
select * from zorvin_conferencia_009;
