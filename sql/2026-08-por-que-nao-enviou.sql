-- ============================================================
--  POR QUE A MENSAGEM NÃO SAIU
--
--  A bolha vermelha dizia só "não enviado". Quem atende ficava sem saber se o
--  número está errado, se o cliente não tem WhatsApp, se a linha do escritório
--  caiu ou se foi coisa de um minuto que basta tentar de novo — e cada um
--  desses casos pede uma ação diferente. Sem o motivo, a única ação possível
--  era clicar em "reenviar" e torcer.
--
--  São duas colunas, cada uma com um trabalho:
--
--    `erro_detalhe`  o texto técnico, como a Uazapi mandou. É onde se olha
--                    quando é preciso investigar. Já existia em algumas
--                    instalações; aqui ele é garantido.
--
--    `erro_motivo`   a mesma coisa dita em português, para aparecer na tela.
--                    Fica NULO quando a ponte não reconheceu o erro — e nesse
--                    caso a tela mostra o texto técnico, que é feio mas é
--                    verdadeiro. Frase genérica no lugar de motivo desconhecido
--                    seria pior: pareceria resposta.
--
--  Nenhuma das duas é obrigatória: mensagem que sai não preenche nem uma.
--
--  Seguro rodar de novo.
-- ============================================================

alter table fila_envio add column if not exists erro_detalhe text;
alter table fila_envio add column if not exists erro_motivo  text;

comment on column fila_envio.erro_detalhe is
  'O erro como a Uazapi (ou o banco) devolveu. Linguagem de máquina, para investigar.';
comment on column fila_envio.erro_motivo is
  'O mesmo erro em português, para aparecer na tela de quem atende. Nulo quando '
  'a ponte não reconheceu o erro — aí a tela mostra o texto técnico.';


-- ------------------------------------------------------------
--  A TELA VAI PASSAR A LER A FILA
--
--  Até agora o painel só sabia da fila pelo aviso em tempo real, e por isso a
--  mensagem que falhou SUMIA ao recarregar a página: ela nunca chegou a
--  `mensagens`, e a bolha vermelha só existia na memória do navegador. Quem
--  atualizasse a tela perdia a mensagem e o motivo junto.
--
--  A permissão de leitura para isso JÁ EXISTE — a política `fila_envio_leitura`
--  foi criada no SQL dos departamentos e diz exatamente o que precisa dizer:
--  vê-se a fila de uma conversa que se pode ver. Não há nada a mexer nela, e
--  recriá-la aqui só criaria uma segunda versão da mesma regra para alguém
--  manter igual depois.
--
--  O que falta é o índice: os itens COM ERRO de UMA conversa. Parcial de
--  propósito — a esmagadora maioria das linhas da fila é 'enviada', e indexar
--  todas seria pagar caro por uma consulta que ninguém faz.
-- ------------------------------------------------------------
create index if not exists fila_envio_erro_da_conversa
  on fila_envio (conversa_id, criado_em) where status = 'erro';


-- ------------------------------------------------------------
--  DISPENSAR UMA FALHA
--
--  Se a mensagem falhou porque o número não tem WhatsApp, reenviar vai falhar
--  de novo, sempre. Sem um jeito de tirar aquilo da tela, a bolha vermelha fica
--  ali para sempre — e uma tela cheia de alarme que ninguém pode resolver é uma
--  tela cujo alarme se aprende a ignorar.
--
--  A política deixa fazer UMA coisa: virar um item que está com erro em
--  'descartada'. Não deixa mexer em item que saiu, nem devolver um item para a
--  fila por fora (o `with check` prende o valor novo). E 'descartada' não é
--  status que a ponte processe, então dispensar não reenvia nada.
-- ------------------------------------------------------------
drop policy if exists fila_envio_descartar on fila_envio;
create policy fila_envio_descartar on fila_envio for update to authenticated
using (
  status = 'erro'
  and exists (select 1 from conversas c where c.id = fila_envio.conversa_id)
)
with check (
  status = 'descartada'
  and exists (select 1 from conversas c where c.id = fila_envio.conversa_id)
);


-- ------------------------------------------------------------
--  CONFERÊNCIA — rode e leia
-- ------------------------------------------------------------
select 'coluna erro_detalhe' as item,
       exists(select 1 from information_schema.columns
               where table_name='fila_envio' and column_name='erro_detalhe') as ok
union all
select 'coluna erro_motivo',
       exists(select 1 from information_schema.columns
               where table_name='fila_envio' and column_name='erro_motivo')
union all
select 'a tela pode ler a fila (já existia)',
       exists(select 1 from pg_policies where tablename='fila_envio' and policyname='fila_envio_leitura')
union all
select 'índice dos itens com erro',
       exists(select 1 from pg_indexes where indexname='fila_envio_erro_da_conversa')
union all
select 'dá para dispensar uma falha',
       exists(select 1 from pg_policies where tablename='fila_envio' and policyname='fila_envio_descartar');
