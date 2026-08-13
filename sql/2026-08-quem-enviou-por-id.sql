-- QUEM ENVIOU, PELO ID — e não só pelo nome.
--
-- Até aqui a mensagem enviada guardava `enviado_por`, que é TEXTO: o nome do
-- atendente no momento do envio. Serve para mostrar na bolha, e para isso é
-- ótimo — é o nome que a pessoa tinha quando escreveu.
--
-- Para CONTAR, não serve. Quem troca o nome no perfil vira duas pessoas no
-- relatório: as mensagens antigas ficam com o nome velho e as novas com o
-- novo, e nenhuma soma bate. Dois atendentes homônimos viram um só.
--
-- O id do usuário não muda. Daqui em diante ele viaja junto, e o painel conta
-- por ele quando existe e pelo nome quando não existe — o histórico anterior
-- continua contando, com a imprecisão que ele já tinha.
--
-- `enviado_por` FICA. Ele não é redundante: é o nome de então, e é o que a
-- bolha mostra. Trocar por um `join` faria uma mensagem de 2025 aparecer
-- assinada com o nome de 2027.
--
-- Rodar no SQL Editor do Supabase. Idempotente.

alter table mensagens  add column if not exists enviado_por_id uuid;
alter table fila_envio add column if not exists enviado_por_id uuid;

-- O índice é para o painel: ele agrupa por autor e por período, e sem isto a
-- contagem varre a tabela inteira a cada abertura da tela.
create index if not exists mensagens_enviado_por_id_idx
  on mensagens (enviado_por_id, criado_em desc);

-- E este para o corte por telefone, que é a outra metade do painel: a conversa
-- é que diz de qual telefone a mensagem é.
create index if not exists mensagens_conversa_criado_idx
  on mensagens (conversa_id, criado_em desc);

comment on column mensagens.enviado_por_id is
  'Usuário (auth.users.id) que enviou. Nulo nas recebidas e nas anteriores a ago/2026.';
