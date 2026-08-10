-- ------------------------------------------------------------
--  2. ARRUMAR OS QUE NÃO TÊM GÊMEO  (altera — mas não junta nada)
--
--  Põe na forma canônica ("55" + DDD + número, só dígitos) todo contato que
--  está torto E que NÃO tem um gêmeo no banco. Sem gêmeo não há o que juntar:
--  é só o mesmo contato escrito errado, e arrumar a escrita impede que a
--  próxima mensagem do cliente crie um segundo contato.
--
--  QUEM TEM GÊMEO FICA DE FORA, de propósito. Ali existem duas conversas com
--  histórico dividido, e juntar histórico não é trabalho de UPDATE: é preciso
--  mover mensagens, notas e etiquetas e apagar a conversa vazia. O Zorvin já
--  faz isso certo em "Juntar duas conversas" (menu do topo, só administrador),
--  e essa tela ainda mostra QUAL conversa vai sumir antes de confirmar.
--
--  Tentar arrumar os dois aqui daria erro de chave única de qualquer forma —
--  a coluna `numero` não aceita repetido.
--
--  Só telefone entra: um id de grupo tem 18 dígitos e não leva 55 na frente.
--  E a conta só vale quando sobram 10 ou 11 dígitos, que é o tamanho de um
--  número brasileiro; qualquer outro tamanho é estrangeiro ou lixo, e sai
--  intocado em vez de virar "55" + coisa errada.
--
--  Rode INTEIRO no SQL Editor do Supabase. É um comando só, e rodar de novo
--  não faz mal (na segunda vez ele não acha mais nada para mudar).
-- ------------------------------------------------------------
with limpos as (
  select id, numero,
         regexp_replace(coalesce(numero, ''), '[^0-9]', '', 'g') as dig
    from contatos
),
chaves as (
  select id, numero, dig,
         case when dig like '55%' and length(dig) in (12, 13)
              then substr(dig, 3) else dig end as chave
    from limpos
   where length(dig) between 10 and 13
),
alvo as (
  select c.id, '55' || c.chave as certo
    from chaves c
   where length(c.chave) in (10, 11)
     and c.numero <> '55' || c.chave
     and not exists (select 1 from chaves g
                      where g.chave = c.chave and g.id <> c.id)
)
update contatos c
   set numero = a.certo
  from alvo a
 where c.id = a.id;
