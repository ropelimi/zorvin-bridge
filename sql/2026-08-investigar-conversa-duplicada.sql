-- ------------------------------------------------------------
--  DE ONDE VEIO A CONVERSA DUPLICADA  (consulta — não altera nada)
--
--  A busca por números escritos de formas diferentes não achou nada. Então a
--  duplicação do print veio de outro lugar, e este script pergunta as quatro
--  coisas que restam. Cada bloco devolve uma ou mais linhas; o que não tiver
--  problema devolve "—".
--
--  Rode INTEIRO no SQL Editor do Supabase e me mande a tabela.
-- ------------------------------------------------------------

-- 1. A CLIENTE DO PRINT, exatamente como está no banco.
--    Se aparecer mais de uma linha aqui, são dois contatos mesmo — e o número
--    de um deles não casa com o do outro nem depois de tirar máscara e DDI.
select '1. contatos com 93404-2997' as pergunta,
       c.id::text                   as contato_id,
       coalesce(c.nome, '(sem nome)') as nome,
       c.numero,
       (select count(*) from conversas v where v.contato_id = c.id)::text as conversas,
       (select count(*) from mensagens m join conversas v on v.id = m.conversa_id
         where v.contato_id = c.id)::text as mensagens
  from contatos c
 where regexp_replace(coalesce(c.numero, ''), '[^0-9]', '', 'g') like '%934042997%'

union all

-- 2. O MESMO CONTATO COM DUAS CONVERSAS NO MESMO TELEFONE.
--    Não deveria existir: a chave única de `conversas` impede. Se aparecer, é
--    a chave que está faltando — e aí a duplicação é essa.
select '2. duas conversas, mesmo contato e telefone',
       v.contato_id::text,
       coalesce(c.nome, '(sem nome)'),
       c.numero,
       count(*)::text,
       string_agg(v.id::text, ' + ')
  from conversas v
  join contatos c on c.id = v.contato_id
 group by v.contato_id, v.advogado_id, c.nome, c.numero
having count(*) > 1

union all

-- 3. CONTATOS COM O MESMO NOME e números diferentes.
--    É o caso que sobra: a mesma pessoa cadastrada duas vezes com telefones
--    que realmente não são iguais (um dígito a mais, o 9 que falta, outro
--    aparelho). O nome é a única pista de que são a mesma.
select '3. mesmo nome, números diferentes',
       string_agg(c.id::text, ' + '),
       c.nome,
       string_agg(c.numero, ' | '),
       count(*)::text,
       '—'
  from contatos c
 where coalesce(c.nome, '') <> ''
 group by c.nome
having count(*) > 1

union all

-- 4. AS CHAVES ÚNICAS EXISTEM MESMO?
--    Se alguma destas duas não aparecer, o banco aceita a duplicata em
--    silêncio, e nenhuma correção no Zorvin resolve sozinha.
select '4. chave única existente',
       '—', conname, pg_get_constraintdef(oid), '—', '—'
  from pg_constraint
 where conrelid in ('contatos'::regclass, 'conversas'::regclass)
   and contype in ('u', 'p')

order by 1, 3;
