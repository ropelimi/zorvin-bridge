-- ============================================================
--  A MENSAGEM QUE NÃO SAIU TENTA DE NOVO SOZINHA
--
--  >>> RODAR NO SUPABASE DO **ZORVIN** (o das conversas). <<<
--  Dashboard → SQL Editor → New query → cole tudo → Run.
--  Pode rodar de novo sem medo.
--
--  ------------------------------------------------------------
--  O QUE ISTO CONSERTA
--
--  Uma falha, e a mensagem morria ali. O envio dava erro, a bolha ficava
--  vermelha com "toque em reenviar daqui a pouco", e ninguém tentava de novo —
--  nunca. Uma piscada de rede entre a Render e a Uazapi, ou um "mandou demais"
--  de trinta segundos, custava uma resposta ao cliente que só sairia se alguém
--  estivesse com aquela conversa aberta para clicar. Fora do horário, ou numa
--  conversa que a atendente já tinha fechado, ela não saía.
--
--  Agora a ponte tenta de novo sozinha, com espera crescente (30s, 2min, 5min,
--  15min) e no máximo cinco vezes — mas SÓ quando a falha prova que nada chegou
--  ao cliente. Reenviar por conta própria uma mensagem que talvez tenha saído
--  seria o cliente recebendo duas vezes, e disso não há desfazer.
--
--  Esta coluna é a hora marcada da próxima tentativa. Sem ela, a ponte não tem
--  onde anotar "volte a este item daqui a 2 minutos", e a única alternativa
--  seria insistir de três em três segundos — o que gastaria as cinco tentativas
--  no primeiro minuto, bem quando o problema ainda está de pé.
--
--  ------------------------------------------------------------
--  ENQUANTO ESTE ARQUIVO NÃO FOR RODADO, NADA MUDA
--
--  A ponte descobre sozinha que a coluna não existe, avisa uma vez no log e
--  volta a se comportar exatamente como antes: a falha vira bolha vermelha e a
--  mensagem espera alguém tocar em reenviar. Nada para de funcionar.
-- ============================================================

alter table public.fila_envio
  add column if not exists tentar_em timestamptz;

comment on column public.fila_envio.tentar_em is
  'A hora a partir da qual este item pode ser tentado de novo. Nulo = pode '
  'agora (é o caso de todo item que nunca falhou). Preenchido só quando a '
  'falha PROVA que a mensagem não chegou ao cliente — nos casos duvidosos o '
  'item vira erro e a decisão de reenviar fica com quem atende.';

-- O ÍNDICE COBRE A PERGUNTA QUE A PONTE FAZ A CADA 3 SEGUNDOS: "quais itens
-- pendentes já podem ser tentados?". Só dos PENDENTES, que são um punhado —
-- um índice sobre a fila inteira custaria escrita em cada mensagem enviada
-- para responder algo que não se pergunta sobre elas.
create index if not exists fila_pendentes_prontos
  on public.fila_envio (tentar_em)
  where status = 'pendente';


-- ------------------------------------------------------------
--  CONFERÊNCIA — rode e leia
-- ------------------------------------------------------------
select 'a coluna existe' as item,
       exists (select 1 from information_schema.columns
                where table_schema = 'public' and table_name = 'fila_envio'
                  and column_name = 'tentar_em') as ok
union all
select 'ela é de data/hora',
       exists (select 1 from information_schema.columns
                where table_schema = 'public' and table_name = 'fila_envio'
                  and column_name = 'tentar_em'
                  and data_type = 'timestamp with time zone')
union all
select 'nenhum item ficou marcado para trás',
       not exists (select 1 from public.fila_envio where tentar_em is not null)
union all
select 'o índice existe',
       exists (select 1 from pg_indexes
                where schemaname = 'public' and indexname = 'fila_pendentes_prontos');


-- ------------------------------------------------------------
--  DEPOIS DE RODAR
--
--  1. Republique a ponte (ou espere a próxima publicação). Ela descobre a
--     coluna sozinha; o sinal de que ligou é o log PARAR de dizer que a coluna
--     não existe.
--
--  2. Para ver a retentativa trabalhando:
--
--       select id, status, tentativas, tentar_em, erro_detalhe
--         from public.fila_envio
--        where tentar_em is not null
--        order by tentar_em desc limit 20;
--
--     Item com `tentar_em` no futuro está esperando a próxima tentativa. Muitos
--     itens assim ao mesmo tempo quer dizer que a Uazapi está fora do ar ou
--     recusando por excesso — e aí o `erro_detalhe` de cada um diz qual dos
--     dois.
-- ------------------------------------------------------------
