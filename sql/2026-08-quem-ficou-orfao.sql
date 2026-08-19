-- ============================================================
--  QUEM FICOU ÓRFÃO — a assinatura que não aponta para ninguém
--
--  O relato: "o Rodrigo ADMIN era o usuário administrador, eu alterei para o
--  Rodrigo Sousa e excluí o administrador; ou seja, o Rodrigo ADMIN tem que
--  mudar para Rodrigo Sousa".
--
--  É o caso em que as duas pistas normais falham de uma vez. A mensagem
--  guarda o id de quem escreveu e o nome de então:
--
--    • o ID não acha ninguém — a conta foi apagada;
--    • o NOME não acha ninguém — o nome gravado é justamente o antigo.
--
--  Sem uma terceira pista, essa mensagem não tem como voltar para a pessoa.
--  A terceira pista é `atendentes_de_para`, que já existe desde o SQL do
--  Painel: ela foi feita para "rodrigo" e "Rodrigo Sousa" pararem de ser
--  contados como duas pessoas. É a mesma pergunta, então é a mesma tabela —
--  uma linha aqui arruma a CONTA do Painel e a ASSINATURA na conversa, e quem
--  administra não precisa aprender dois lugares.
--
--  Não se reescreve `mensagens`: um `update` ali não tem volta, e o de-para
--  é reversível (errou, apaga a linha).
--
--  Depende de `atendentes_de_para` (SQL do Painel) e de `zorvin_sem_acento`
--  (SQL da busca), ambos já rodados. Seguro rodar de novo.
-- ============================================================

set search_path = public;


-- ------------------------------------------------------------
--  PASSO 1 — QUEM ESTÁ ÓRFÃO. Rode e leia.
--
--  Sai uma linha por assinatura que não aponta para ninguém: o nome que está
--  gravado nas mensagens, quantas mensagens são, e desde quando. É a lista do
--  que vale a pena arrumar — se uma assinatura tem duas mensagens de 2024,
--  provavelmente não vale.
--
--  NEM TODA LINHA AQUI É PROBLEMA. "WhatsApp" vai aparecer, e com muitas
--  mensagens: é o rótulo que a ponte põe em toda mensagem enviada pelo
--  aplicativo do WhatsApp em vez de pelo Zorvin. Ela não é de ninguém em
--  particular — o WhatsApp não diz qual atendente escreveu — e não há nada a
--  fazer com ela. O painel já a mostra como "Pelo celular".
-- ------------------------------------------------------------
select coalesce(m.enviado_por, '(sem nome)') as assinatura,
       count(*)                              as mensagens,
       min(m.criado_em)::date                as da_primeira,
       max(m.criado_em)::date                as da_ultima,
       -- Por que ficou órfã: ajuda a decidir o que fazer com ela.
       case when zorvin_sem_acento(m.enviado_por) = 'whatsapp'
              then 'não é gente: saiu pelo aplicativo do WhatsApp — nada a fazer'
            when m.enviado_por_id is not null then 'a conta foi apagada'
            else 'sem id (histórico antigo) e o nome não bate com ninguém'
       end                                   as motivo
  from mensagens m
 where m.origem = 'advogado'
   -- Não acha por id...
   and not exists (select 1 from usuarios u where u.id = m.enviado_por_id)
   -- ...nem por nome...
   and not exists (select 1 from usuarios u
                    where zorvin_sem_acento(u.nome) = zorvin_sem_acento(m.enviado_por))
   -- ...nem já está resolvida no de-para.
   and not exists (select 1 from atendentes_de_para d
                    where zorvin_sem_acento(d.nome_antigo) = zorvin_sem_acento(coalesce(m.enviado_por, '(sem nome)')))
 group by 1, 5
 order by 2 desc;


-- ------------------------------------------------------------
--  PASSO 2 — ARRUMAR
--
--  Troque os dois nomes abaixo e rode: o primeiro é a assinatura como ela
--  aparece no passo 1; o segundo é a pessoa de hoje, como está no cadastro.
--
--  O id sai de `usuarios` por consulta, e não colado à mão: uuid digitado
--  errado não dá erro nenhum, só deixa de casar — e o defeito volta calado.
-- ------------------------------------------------------------
insert into atendentes_de_para (nome_antigo, usuario_id, nome_novo, e_pessoa)
select 'Rodrigo ADMIN',                                    -- <<< a assinatura antiga
       u.id, null, true
  from usuarios u
 where zorvin_sem_acento(u.nome) = zorvin_sem_acento('Rodrigo Sousa')  -- <<< a pessoa de hoje
 limit 1
on conflict (nome_antigo) do update
   set usuario_id = excluded.usuario_id,
       nome_novo  = excluded.nome_novo,
       e_pessoa   = excluded.e_pessoa;


-- ------------------------------------------------------------
--  CONFERÊNCIA — rode e leia
--
--  Tem de sair uma linha, com o nome de hoje ao lado da assinatura antiga.
--  Nenhuma linha quer dizer que o nome do passo 2 não bateu com ninguém em
--  `usuarios` — confira como ele está escrito no cadastro.
-- ------------------------------------------------------------
select d.nome_antigo         as assinatura_antiga,
       coalesce(u.nome, d.nome_novo, '(não aponta para ninguém)') as vira,
       d.e_pessoa
  from atendentes_de_para d
  left join usuarios u on u.id = d.usuario_id
 order by d.nome_antigo;
