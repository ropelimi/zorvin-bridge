-- A NOTA GUARDA TAMBÉM O RÉU DO PROCESSO.
--
-- RODAR NO SUPABASE `zorvin` (o do WhatsApp: conversas, mensagens, contatos,
-- notas, advogados). NÃO é no `vantoro` — lá o banco é do Django, e mudança de
-- tabela entra por migration, senão o código e o banco divergem.
--
-- Rodar INTEIRO no SQL Editor. Idempotente: pode rodar de novo.
--
-- ------------------------------------------------------------------
-- POR QUE O RÉU, E NÃO O TIPO DA AÇÃO
-- ------------------------------------------------------------------
--
-- Um cliente com oito ações costuma ter oito da MESMA espécie. Na tela isso
-- aparecia como oito linhas dizendo "NEGATIVAÇÃO INCLUSÃO INDEVIDA EM CADASTRO
-- DE INADIMPLENTES" — repetido, e por isso inútil para escolher qual é qual.
--
-- O que distingue uma ação da outra, para quem atende, é CONTRA QUEM ela é. É
-- assim que a equipe fala delas: "a do banco", "a da operadora".
--
-- É UMA CÓPIA, pelo mesmo motivo de `processo_numero`: sem ela, desenhar a nota
-- na conversa exigiria perguntar ao Vantoro qual é o processo de cada uma — uma
-- ida à rede por nota, numa lista que rola. E com o Vantoro fora do ar as notas
-- apareceriam sem dizer de que ação são. O `processo_id` continua sendo a
-- verdade; isto aqui é só o rótulo.
--
-- E ELA RESOLVE UM BURACO: ação ainda não distribuída não tem número. A bolha
-- só desenhava o vínculo quando havia número, então nessas a nota ficava ligada
-- ao processo no banco e MUDA na tela — o vínculo existia sem aparecer.

alter table notas add column if not exists processo_reu text;

comment on column notas.processo_reu is
  'O réu do processo, copiado para a tela não precisar perguntar. É ele que '
  'identifica a ação para quem atende — o tipo se repete entre as ações do '
  'mesmo cliente. O `processo_id` é a verdade.';
