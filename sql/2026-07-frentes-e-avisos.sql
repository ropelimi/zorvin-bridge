-- ============================================================
--  FRENTES DE ATENDIMENTO + AVISOS DE AUDIÊNCIA
--
--  Rode uma vez no Supabase do Zorvin:
--    Dashboard → SQL Editor → New query → cole tudo → Run
--
--  Pode rodar de novo sem medo: tudo é "if not exists".
--  Nada é apagado nem alterado — só entram colunas novas, vazias.
-- ============================================================

-- ------------------------------------------------------------
--  1. A FRENTE FICA NO CONTATO
--
--  Quem a pessoa é não muda de advogado para advogado: se o João é nosso
--  cliente, ele é cliente em qualquer conversa. Por isso a etiqueta mora aqui,
--  e não precisa ser descoberta de novo a cada número que fala com ele.
--
--  frente_em guarda QUANDO foi classificado: a ponte só volta a perguntar ao
--  Vantoro uma vez por semana, em vez de a cada mensagem.
-- ------------------------------------------------------------
alter table contatos add column if not exists frente text;
alter table contatos add column if not exists frente_em timestamptz;
alter table contatos add column if not exists vantoro_cliente_id bigint;
alter table contatos add column if not exists vantoro_nome text;

-- ------------------------------------------------------------
--  2. NÚMEROS NOSSOS DE USO INTERNO
--
--  RH e cadastro (contato com vendedores externos) não atendem cliente nem
--  fazem acordo. Preenchendo frente_fixa, TODA conversa desse número recebe
--  essa etiqueta, sem perguntar nada ao Vantoro.
--
--  Deixe NULL nos números dos advogados — neles quem manda é quem está do
--  outro lado.
-- ------------------------------------------------------------
alter table advogados add column if not exists frente_fixa text;

-- ------------------------------------------------------------
--  3. A FRENTE COPIADA NA CONVERSA
--
--  É por aqui que o painel filtra. Fica repetida de propósito: filtrar a lista
--  de conversas sem precisar cruzar tabela a cada abertura de tela.
-- ------------------------------------------------------------
alter table conversas add column if not exists frente text;
create index if not exists conversas_frente_idx on conversas (frente);

-- ------------------------------------------------------------
--  4. AVISO DE AUDIÊNCIA NA FILA DE ENVIO
--
--  Liga o item da fila ao aviso lá no Vantoro. Serve para duas coisas:
--
--  a) confirmar de volta SÓ quando a Uazapi realmente enviar — antes disso o
--     aviso continua pendente no Vantoro, e um envio que falhou não fica
--     parecendo entregue;
--
--  b) o índice único impede que o mesmo aviso entre duas vezes na fila, caso
--     um ciclo de busca repita antes de o anterior ter sido processado. Quem
--     garante isso é o banco, não a ordem em que o código roda.
-- ------------------------------------------------------------
alter table fila_envio add column if not exists aviso_vantoro_id bigint;
create unique index if not exists fila_envio_aviso_unico
  on fila_envio (aviso_vantoro_id) where aviso_vantoro_id is not null;

-- ------------------------------------------------------------
--  5. DEPOIS: marque os números internos
--
--  Troque o número pelo real e rode. Enquanto não fizer isso, as conversas do
--  RH são classificadas como qualquer outra (provavelmente DESCONHECIDA).
--
--    update advogados set frente_fixa = 'INTERNO' where numero = '5511999999999';
--
--  Frentes válidas: CLIENTE, ACORDO, LEAD, INTERNO, DESCONHECIDA.
-- ------------------------------------------------------------
