-- ============================================================
--  AS MENSAGENS RÁPIDAS COM ANEXO (o vídeo que a equipe manda sempre)
--
--  >>> RODAR NO SUPABASE DO **ZORVIN** (o das conversas). <<<
--  Quem roda é a PONTE, sozinha, na publicação que vem com o merge.
--  Pode rodar de novo sem medo.
--
--  ------------------------------------------------------------
--  O QUE ISTO ACRESCENTA
--
--  Pedido do Rodrigo em 23/10: "Para as mensagens rápidas, precisa ser
--  possível incluir vídeos." Hoje a rápida é só texto, e o vídeo que a equipe
--  manda a todo cliente novo (como funciona o acordo, onde assinar) é
--  procurado no computador e anexado à mão, a cada vez.
--
--  Quatro colunas em `mensagens_rapidas`, todas opcionais — a rápida de
--  sempre continua sendo só texto:
--
--    midia_url   o endereço do arquivo no depósito `anexos` (rapidas/...).
--                O arquivo sobe UMA vez, ao salvar a rápida; usar a rápida
--                manda à fila esse mesmo endereço, sem subir de novo.
--    midia_tipo  'video', 'imagem', 'documento' ou 'audio' — os tipos que a
--                fila de envio conhece.
--    midia_mime  o tipo do arquivo, como o navegador disse (video/mp4).
--    midia_nome  o nome do arquivo, como a pessoa o escolheu: é ele que o
--                cliente vê num documento.
--
--  DUAS REGRAS, e nenhuma é enfeite:
--
--    - o tipo é um dos quatro: um tipo que a fila não conhece viraria uma
--      mensagem que nunca sai;
--    - endereço e tipo andam JUNTOS: o painel decide como desenhar e como
--      mandar pelo tipo, e um endereço sem tipo (ou o contrário) é uma rápida
--      que ninguém sabe se tem anexo.
--
--  NENHUMA POLÍTICA NOVA: `rapidas_tudo` (quem entrou, todas as linhas) já
--  cobre as colunas novas, e a permissão de `mensagens_rapidas` é da TABELA
--  inteira — medido no banco do escritório em 23/10. A conferência confere
--  as duas coisas no papel de quem atende.
--
--  ------------------------------------------------------------
--  ENQUANTO ESTE ARQUIVO NÃO FOR RODADO
--
--  As rápidas continuam funcionando como sempre. O painel pergunta se as
--  colunas existem e só oferece o anexo quando existem.
-- ============================================================

do $rapidas$
begin
  -- A TABELA DA CONFERÊNCIA NASCE ANTES DA GUARDA — a lição do 006 e do 007.
  drop table if exists zorvin_conferencia_034;
  create temp table zorvin_conferencia_034 (item text, resposta text);

  if to_regclass('public.mensagens_rapidas') is null then
    insert into zorvin_conferencia_034
      values ('sem as tabelas do Zorvin', 'nada a fazer aqui');
    raise notice 'Zorvin: sem a tabela de mensagens rápidas — script 034 não fez nada.';
    return;
  end if;

  execute 'alter table public.mensagens_rapidas add column if not exists midia_url text';
  execute 'alter table public.mensagens_rapidas add column if not exists midia_tipo text';
  execute 'alter table public.mensagens_rapidas add column if not exists midia_mime text';
  execute 'alter table public.mensagens_rapidas add column if not exists midia_nome text';

  if not exists (select 1 from pg_constraint
                  where conrelid = 'public.mensagens_rapidas'::regclass
                    and conname = 'mensagens_rapidas_midia_tipo_conhecido') then
    execute $c$alter table public.mensagens_rapidas
      add constraint mensagens_rapidas_midia_tipo_conhecido
      check (midia_tipo is null or midia_tipo in ('video', 'imagem', 'documento', 'audio'))$c$;
  end if;
  if not exists (select 1 from pg_constraint
                  where conrelid = 'public.mensagens_rapidas'::regclass
                    and conname = 'mensagens_rapidas_midia_junta') then
    execute $c$alter table public.mensagens_rapidas
      add constraint mensagens_rapidas_midia_junta
      check ((midia_url is null) = (midia_tipo is null))$c$;
  end if;

  execute $c$comment on column public.mensagens_rapidas.midia_url is
    'O anexo da mensagem rápida (vídeo, imagem, documento ou áudio), no depósito '
    '"anexos". Sobe uma vez, ao salvar; usar a rápida manda este endereço à fila.'$c$;
  execute $c$comment on column public.mensagens_rapidas.midia_tipo is
    'video, imagem, documento ou audio — o tipo que a fila de envio usa. '
    'Anda junto com midia_url: os dois ou nenhum.'$c$;

  insert into zorvin_conferencia_034
  select 'as quatro colunas do anexo existem'::text,
         ((select count(*) from information_schema.columns
            where table_schema = 'public' and table_name = 'mensagens_rapidas'
              and column_name in ('midia_url', 'midia_tipo', 'midia_mime', 'midia_nome')) = 4)::text
  union all
  select 'as duas regras do anexo existem',
         ((select count(*) from pg_constraint
            where conrelid = 'public.mensagens_rapidas'::regclass
              and conname in ('mensagens_rapidas_midia_tipo_conhecido', 'mensagens_rapidas_midia_junta')) = 2)::text
  union all
  select 'quem entrou consegue GRAVAR o anexo numa rápida nova',
         (has_column_privilege('authenticated', 'public.mensagens_rapidas', 'midia_url', 'INSERT')
          and has_column_privilege('authenticated', 'public.mensagens_rapidas', 'midia_tipo', 'INSERT'))::text
  union all
  select 'quem entrou consegue TROCAR o anexo de uma rápida',
         (has_column_privilege('authenticated', 'public.mensagens_rapidas', 'midia_url', 'UPDATE')
          and has_column_privilege('authenticated', 'public.mensagens_rapidas', 'midia_tipo', 'UPDATE'))::text
  union all
  select 'quem entrou consegue LER o anexo',
         has_column_privilege('authenticated', 'public.mensagens_rapidas', 'midia_url', 'SELECT')::text
  union all
  select 'mensagens rápidas com anexo',
         (select count(*) from public.mensagens_rapidas where midia_url is not null)::text;
end $rapidas$;

-- A RESPOSTA DE "DEU CERTO?", na última linha, que é a que o editor mostra.
select * from zorvin_conferencia_034;
