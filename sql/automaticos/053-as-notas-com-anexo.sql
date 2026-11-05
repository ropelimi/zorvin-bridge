-- ============================================================
--  AS NOTAS INTERNAS COM ANEXO (o documento que fica só com a equipe)
--
--  >>> RODAR NO SUPABASE DO **ZORVIN** (o das conversas). <<<
--  Quem roda é a PONTE, sozinha, na publicação que vem com o merge.
--  Pode rodar de novo sem medo.
--
--  ------------------------------------------------------------
--  O QUE ISTO ACRESCENTA
--
--  Pedido do Rodrigo em 05/11: "Nas notas internas precisa ter a
--  possibilidade de anexar documentos." Até aqui a nota interna era só texto:
--  o comprovante que o cliente mandou por e-mail, o print do sistema do banco,
--  o contrato conferido — nada disso tinha onde ficar na conversa sem ir para
--  o cliente.
--
--  Quatro colunas em `notas`, todas opcionais — a nota de sempre continua
--  sendo só texto, e as 1.076 que existem (05/11) não mudam:
--
--    midia_url   o endereço do arquivo no depósito `anexos` (notas/...). O
--                arquivo NUNCA passa pela fila de envio: a nota não vai ao
--                WhatsApp, e o anexo dela também não.
--    midia_tipo  'imagem', 'video', 'audio' ou 'documento' — o painel desenha
--                a nota pelo tipo.
--    midia_mime  o tipo do arquivo, como o navegador disse (application/pdf).
--    midia_nome  o nome do arquivo, como a pessoa o escolheu: é com ele que o
--                documento baixa, e é ele que a ficha do Vantoro lê.
--
--  O TEXTO CONTINUA OBRIGATÓRIO NA COLUNA, e pode ser vazio: a nota que é só o
--  documento grava `texto = ''`. Nenhuma regra nova sobre o texto — uma regra
--  "texto ou anexo" recusaria alguma nota antiga vazia que exista, e o script
--  pararia ali.
--
--  DUAS REGRAS, e nenhuma é enfeite (as mesmas do 034, das rápidas):
--
--    - o tipo é um dos quatro: um tipo desconhecido seria uma nota que o
--      painel não sabe desenhar — o anexo estaria no banco e sumido da tela;
--    - endereço e tipo andam JUNTOS: um endereço sem tipo (ou o contrário) é
--      uma nota que ninguém sabe se tem anexo.
--
--  NENHUMA POLÍTICA NOVA: as quatro políticas de `notas` são de quem entrou,
--  em todas as linhas, e a permissão de `notas` é da TABELA inteira — medido
--  no banco do escritório em 05/11. A conferência confere as duas coisas no
--  papel de quem atende, e também que `notas` continua no tempo real: é por
--  ele que a nota com o documento aparece na tela dos colegas.
--
--  ------------------------------------------------------------
--  O QUE A PONTE FAZ COM ISTO
--
--  A nota sobe para a ficha do Vantoro como sempre subiu, e com uma linha a
--  mais quando tem anexo: "📎 Anexo no Zorvin: <nome do arquivo>". O
--  documento fica no Zorvin. A linha é posta e tirada pela PONTE, num lugar só
--  (ver "As notas internas com anexo (script 053, 05/11)" no CLAUDE.md dela).
--
--  ------------------------------------------------------------
--  ENQUANTO ESTE ARQUIVO NÃO FOR RODADO
--
--  As notas continuam funcionando como sempre. O painel pergunta se as
--  colunas existem e só oferece o anexo na nota quando existem.
-- ============================================================

do $notas$
begin
  -- A TABELA DA CONFERÊNCIA NASCE ANTES DA GUARDA — a lição do 006 e do 007.
  drop table if exists zorvin_conferencia_053;
  create temp table zorvin_conferencia_053 (item text, resposta text);

  if to_regclass('public.notas') is null then
    insert into zorvin_conferencia_053
      values ('sem as tabelas do Zorvin', 'nada a fazer aqui');
    raise notice 'Zorvin: sem a tabela de notas — script 053 não fez nada.';
    return;
  end if;

  execute 'alter table public.notas add column if not exists midia_url text';
  execute 'alter table public.notas add column if not exists midia_tipo text';
  execute 'alter table public.notas add column if not exists midia_mime text';
  execute 'alter table public.notas add column if not exists midia_nome text';

  if not exists (select 1 from pg_constraint
                  where conrelid = 'public.notas'::regclass
                    and conname = 'notas_midia_tipo_conhecido') then
    execute $c$alter table public.notas
      add constraint notas_midia_tipo_conhecido
      check (midia_tipo is null or midia_tipo in ('imagem', 'video', 'audio', 'documento'))$c$;
  end if;
  if not exists (select 1 from pg_constraint
                  where conrelid = 'public.notas'::regclass
                    and conname = 'notas_midia_junta') then
    execute $c$alter table public.notas
      add constraint notas_midia_junta
      check ((midia_url is null) = (midia_tipo is null))$c$;
  end if;

  execute $c$comment on column public.notas.midia_url is
    'O anexo da nota interna (documento, imagem, vídeo ou áudio), no depósito '
    '"anexos" (notas/...). Só a equipe vê: nunca passa pela fila de envio.'$c$;
  execute $c$comment on column public.notas.midia_tipo is
    'imagem, video, audio ou documento — o tipo pelo qual o painel desenha a nota. '
    'Anda junto com midia_url: os dois ou nenhum.'$c$;

  insert into zorvin_conferencia_053
  select 'as quatro colunas do anexo existem'::text,
         ((select count(*) from information_schema.columns
            where table_schema = 'public' and table_name = 'notas'
              and column_name in ('midia_url', 'midia_tipo', 'midia_mime', 'midia_nome')) = 4)::text
  union all
  select 'as duas regras do anexo existem',
         ((select count(*) from pg_constraint
            where conrelid = 'public.notas'::regclass
              and conname in ('notas_midia_tipo_conhecido', 'notas_midia_junta')) = 2)::text
  union all
  select 'quem entrou consegue GRAVAR o anexo numa nota nova',
         (has_column_privilege('authenticated', 'public.notas', 'midia_url', 'INSERT')
          and has_column_privilege('authenticated', 'public.notas', 'midia_tipo', 'INSERT')
          and has_column_privilege('authenticated', 'public.notas', 'midia_nome', 'INSERT'))::text
  union all
  select 'quem entrou consegue LER o anexo',
         (has_column_privilege('authenticated', 'public.notas', 'midia_url', 'SELECT')
          and has_column_privilege('authenticated', 'public.notas', 'midia_nome', 'SELECT'))::text
  union all
  select 'as notas continuam no tempo real (é por ele que os colegas veem o anexo)',
         (not exists (select 1 from pg_publication where pubname = 'supabase_realtime')
          or exists (select 1 from pg_publication_tables
                      where pubname = 'supabase_realtime'
                        and schemaname = 'public' and tablename = 'notas'))::text
  union all
  select 'notas com anexo',
         (select count(*) from public.notas where midia_url is not null)::text;
end $notas$;

-- A RESPOSTA DE "DEU CERTO?", na última linha, que é a que o editor mostra.
select * from zorvin_conferencia_053;
