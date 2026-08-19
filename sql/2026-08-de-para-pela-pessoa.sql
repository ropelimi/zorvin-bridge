-- ============================================================
--  O DE-PARA APONTANDO PARA A PESSOA, E NÃO PARA UM NOME
--
--  O relato: em "quem participou da conversa" apareciam DOIS "Rodrigo Sousa",
--  um com foto e outro sem.
--
--  A causa está aqui. As primeiras linhas de `atendentes_de_para` foram
--  escritas quando só havia texto para comparar: o começo do e-mail
--  ("rodrigo") apontando para o nome por extenso ("Rodrigo Sousa"), com
--  `usuario_id` vazio. Naquele momento era o que dava para fazer.
--
--  Só que uma linha assim aponta para um NOME, e não para uma PESSOA. Daí as
--  duas consequências:
--
--    • a tela via duas coisas diferentes — a pessoa (que tem id e foto) e um
--      nome solto (que não tem nem um nem outro) — e desenhava as duas;
--    • no dia em que alguém trocar de nome no cadastro, a linha continua
--      apontando para o nome antigo, e as mensagens dela voltam a mostrar o
--      nome de antes.
--
--  O painel já junta as duas na tela (dois nomes iguais é sempre erro, venha
--  de onde vier). Isto aqui arruma a origem: preenche o `usuario_id` de toda
--  linha em que o `nome_novo` bate com alguém do cadastro.
--
--  Depende de `atendentes_de_para` (SQL do Painel) e de `zorvin_sem_acento`
--  (SQL da busca), ambos já rodados. Seguro rodar de novo.
-- ============================================================

set search_path = public;

update atendentes_de_para d
   set usuario_id = u.id
  from usuarios u
 where d.usuario_id is null
   and d.e_pessoa
   and d.nome_novo is not null
   and zorvin_sem_acento(u.nome) = zorvin_sem_acento(d.nome_novo);


-- ------------------------------------------------------------
--  CONFERÊNCIA — rode e leia
--
--  `aponta_para` diz o que cada linha resolve hoje:
--
--    "a pessoa (id)"  — o certo. Acompanha renome, tem foto.
--    "só um nome"     — o `nome_novo` não bate com ninguém no cadastro. Ou a
--                       pessoa saiu do escritório, ou o nome está escrito
--                       diferente. Confira como ele está em `usuarios`.
--    "não é pessoa"   — rótulo do importador. É para ser assim.
-- ------------------------------------------------------------
select d.nome_antigo,
       coalesce(u.nome, d.nome_novo, '—') as vira,
       case when not d.e_pessoa        then 'não é pessoa'
            when d.usuario_id is not null then 'a pessoa (id)'
            else 'só um nome'
       end                                as aponta_para
  from atendentes_de_para d
  left join usuarios u on u.id = d.usuario_id
 order by 3, 1;
