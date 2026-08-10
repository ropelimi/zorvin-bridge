-- ------------------------------------------------------------
--  1. OS PARES SUSPEITOS  (consulta — não altera nada)
--
--  Acha os contatos que são O MESMO TELEFONE escrito de formas diferentes:
--  com máscara, sem o 55, ou as duas coisas. É o estrago que o caminho do
--  cadastro do Vantoro deixou antes da correção.
--
--  A chave de comparação é a mesma que o Zorvin usa: só dígitos, e sem o 55
--  quando ele está lá. Assim "(11) 93404-2997", "11934042997" e
--  "5511934042997" caem todos no mesmo grupo.
--
--  Grupos do WhatsApp (id de 18 dígitos) ficam de fora: eles nunca colidem
--  com telefone, e entrariam só para poluir a lista.
--
--  A coluna FORMA diz qual manter: o CANÔNICO é o que o WhatsApp usa, e é
--  para ele que as mensagens novas vão chegar.
-- ------------------------------------------------------------
with limpos as (
  select id, nome, numero,
         regexp_replace(coalesce(numero, ''), '[^0-9]', '', 'g') as dig
    from contatos
),
chaves as (
  select id, nome, numero, dig,
         case when dig like '55%' and length(dig) in (12, 13)
              then substr(dig, 3) else dig end as chave
    from limpos
   where length(dig) between 10 and 13
),
grupos as (
  select chave from chaves group by chave having count(*) > 1
)
select c.chave                                            as telefone,
       case when c.numero = '55' || c.chave
            then 'CANONICO (manter)' else 'torto' end     as forma,
       c.nome,
       c.numero,
       c.id                                               as contato_id,
       (select count(*) from conversas v
         where v.contato_id = c.id)                       as conversas,
       (select count(*) from mensagens m
          join conversas v on v.id = m.conversa_id
         where v.contato_id = c.id)                       as mensagens
  from chaves c
  join grupos g on g.chave = c.chave
 order by c.chave, forma, c.numero;
