-- ------------------------------------------------------------
--  1. O QUE VAI SER JUNTADO  (consulta — não altera nada)
--
--  Agora com o NONO DÍGITO na chave: "+55 31 99945-6790" e "+55 31 9945-6790"
--  são o mesmo celular, e a conferência anterior não os enxergava — foi por
--  isso que ela voltou vazia.
--
--  Só celular ganha o 9. Fixo tem 8 dígitos começando em 2..5, e pôr um 9 nele
--  inventaria um número que não existe.
--
--  FICA quem tem a conversa mais recente: é o número por onde o cliente está
--  falando hoje, e é para ele que as próximas mensagens vão chegar.
--
--  Rode INTEIRO e confira a lista ANTES de rodar o script que junta.
-- ------------------------------------------------------------
with limpos as (
  select id, nome, numero,
         regexp_replace(coalesce(numero, ''), '[^0-9]', '', 'g') as dig
    from contatos
),
nacionais as (
  select id, nome, numero,
         case when dig like '55%' and length(dig) in (12, 13) then substr(dig, 3) else dig end as nac
    from limpos
),
chaves as (
  select id, nome, numero,
         case when length(nac) = 10 and substr(nac, 3, 1) in ('6','7','8','9')
              then substr(nac, 1, 2) || '9' || substr(nac, 3)
              else nac end as chave
    from nacionais
   where length(nac) between 10 and 11
),
grupos as (
  select chave from chaves group by chave having count(*) > 1
),
atividade as (
  select c.id, c.nome, c.numero, c.chave,
         (select max(v.ultima_atividade) from conversas v where v.contato_id = c.id) as visto,
         (select count(*) from conversas v where v.contato_id = c.id)                as conversas,
         (select count(*) from mensagens m join conversas v on v.id = m.conversa_id
           where v.contato_id = c.id)                                               as mensagens
    from chaves c join grupos g on g.chave = c.chave
)
select chave                                          as celular,
       case when id = first_value(id) over (
              partition by chave order by visto desc nulls last, id)
            then 'FICA' else 'some (vai para o que FICA)' end as destino,
       nome, numero, conversas, mensagens,
       to_char(visto, 'DD/MM/YYYY HH24:MI')           as ultima_atividade
  from atividade
 order by chave, destino, numero;
