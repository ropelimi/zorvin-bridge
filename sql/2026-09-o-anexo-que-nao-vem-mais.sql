-- ============================================================
--  O ANEXO QUE NÃO VEM MAIS — dito na tela, em vez de "indisponível" para sempre
--
--  >>> RODAR NO SUPABASE DO **ZORVIN** (o das conversas). <<<
--  Dashboard → SQL Editor → New query → cole tudo → Run.
--  Pode rodar de novo sem medo.
--
--  ------------------------------------------------------------
--  O QUE ISTO CONSERTA
--
--  Hoje a conversa mostra "indisponível" em duas situações que são opostas para
--  quem está atendendo:
--
--    - o arquivo está a caminho e chega em dois minutos;
--    - o arquivo não existe mais e não vai chegar nunca.
--
--  As duas são a mesma palavra na tela. Quem atende fica esperando, recarrega,
--  espera mais — e no segundo caso está esperando por nada. Pior: não tem como
--  saber que precisa pedir ao cliente que mande de novo.
--
--  MEDIDO em 11/09, no resgate dos anexos vazios do escritório. A rota que
--  serve neste servidor é `POST /message/download`, e ela respondeu:
--
--      400 {"error":"Message does not contain downloadable media"}
--
--  Não é a rota falhando — é a rota funcionando e dizendo que aquela mensagem
--  não tem arquivo. Essa resposta não muda com o tempo.
--
--  Esta coluna guarda essa resposta. Preenchida, quer dizer "não vem mais, e
--  este foi o motivo". Vazia, quer dizer o de sempre: ou já chegou, ou ainda
--  pode chegar.
--
--  ------------------------------------------------------------
--  ELA GUARDA A RESPOSTA DA UAZAPI, E NÃO CONTEÚDO DE CLIENTE
--
--  O que entra aqui é o texto técnico da recusa. Nenhum pedaço da mensagem do
--  cliente passa por esta coluna — ela fica sob as mesmas regras da tabela
--  `mensagens`, que já são as certas.
--
--  ------------------------------------------------------------
--  ENQUANTO ESTE ARQUIVO NÃO FOR RODADO, NADA MUDA
--
--  A ponte descobre sozinha que a coluna não existe, avisa uma vez no log e
--  segue. O anexo continua vazio e escrito "indisponível", como sempre esteve.
-- ============================================================

alter table public.mensagens
  add column if not exists midia_erro text;

comment on column public.mensagens.midia_erro is
  'Por que este anexo NÃO VEM MAIS. Preenchido só quando a Uazapi dá uma '
  'resposta definitiva (a mensagem não tem mídia, ou ela não consegue ler o '
  'conteúdo) — nunca por uma falha passageira, que continua sendo tentada de '
  'novo. Vazio = ou o arquivo já chegou, ou ainda pode chegar.';


-- ------------------------------------------------------------
--  CONFERÊNCIA — rode e leia
-- ------------------------------------------------------------
select 'a coluna existe' as item,
       exists (select 1 from information_schema.columns
                where table_schema = 'public' and table_name = 'mensagens'
                  and column_name = 'midia_erro') as ok
union all
select 'e nenhuma mensagem nasceu marcada',
       not exists (select 1 from public.mensagens where midia_erro is not null)
union all
select 'quem está dentro continua lendo as mensagens',
       has_table_privilege('authenticated', 'public.mensagens', 'SELECT');


-- ------------------------------------------------------------
--  DEPOIS DE RODAR
--
--  1. Republique a ponte. Ela descobre a coluna sozinha; o sinal é o log PARAR
--     de dizer que ela não existe.
--
--  2. Abra o resgate de anexos uma vez
--     (`/anexos/resgatar?token=…&dias=10&limite=10`, repetindo até dar zero).
--     Ele marca os que já se sabe perdidos — é por ali que os 38 anexos vazios
--     de hoje deixam de dizer "indisponível" e passam a dizer o que houve.
--
--  3. Para ver quantos são, e por quê:
--
--       select left(midia_erro, 60) as motivo, count(*)
--         from public.mensagens
--        where midia_erro is not null
--        group by 1 order by 2 desc;
-- ------------------------------------------------------------
