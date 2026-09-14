-- ============================================================
--  O DEPÓSITO DE ANEXOS — o que muda, e o que fica como está
--
--  >>> RODAR NO SUPABASE DO **ZORVIN** (o das conversas). <<<
--  Dashboard → SQL Editor → New query → cole tudo → Run.
--  Pode rodar de novo sem medo.
--
--  ------------------------------------------------------------
--  PRIMEIRO: O QUE ESTE ARQUIVO **NÃO** FAZ, E POR QUÊ
--
--  Ele NÃO fecha o balde `anexos`. A etapa 9 do plano de diagnóstico dizia
--  "anexos privados", e a medição de 14/09 mostrou que o conserto óbvio
--  recriaria a queda de 21/08:
--
--      4.187 arquivos, 1.996 MB guardados, ~40 MB entrando por dia
--
--  Fechar o balde obriga a endereço assinado, e endereço assinado leva um
--  bilhete que MUDA a cada vez que é gerado. Para o navegador é outro endereço
--  — então o cache de um ano (`CACHE_DA_MIDIA`, com `immutable`) deixa de
--  valer e cada foto é rebaixada de novo, por cada pessoa, a cada expiração.
--
--  Foi exatamente isso que zerou a franquia de banda em 21/08 e suspendeu o
--  workspace, derrubando o atendimento. O `immutable` É o conserto daquilo; o
--  endereço assinado o desfaz por construção.
--
--  E O QUE SE GANHARIA É MENOR DO QUE PARECE. O endereço é
--  `anexos/recebidos/{id da mensagem}`, com 18 a 32 caracteres — não se
--  adivinha. Isto não é a vista `equipe`, onde foram MEDIDAS 21 linhas abertas
--  a qualquer um: aqui é preciso já ter o link. A exposição real é "quem tem o
--  endereço", e os endereços vivem no banco (protegido) e no navegador de quem
--  já tem acesso.
--
--  Se um dia isto precisar mudar — exigência de cliente, auditoria, LGPD com
--  parecer diferente — o caminho NÃO é trocar por endereço assinado e torcer.
--  É medir a banda primeiro, e provavelmente servir os arquivos pela ponte,
--  com sessão conferida e cache longo preservado.
--
--  ------------------------------------------------------------
--  O QUE ELE FAZ, ENTÃO
--
--  Duas coisas que a mesma medição achou, e que não custam nada:
--
--  1. TIRA O PODER DE APAGAR. A política `anexos_atendentes` é `ALL` — inclui
--     DELETE. Nada no código apaga arquivo (conferido nos dois repositórios),
--     e o que está guardado é procuração, contrato, laudo. Uma porta sem uso
--     que só serve para o dia em que alguém errar o clique — ou para uma
--     sessão roubada apagar o acervo do escritório.
--
--  2. TENTA FECHAR O BALDE `avatares`, que é público: 10 arquivos, 167 kB, de
--     24/07. Só fecha SE nenhuma foto de perfil apontar para ele.
--
--     >>> RODADO EM 14/09: ELE NÃO FECHOU, e estava certo. <<<
--
--     A conferência achou 7 das 35 fotos de perfil apontando para lá. Sem ela,
--     o `update` teria passado e sete rostos sumiriam da tela sem nenhuma
--     mensagem — o defeito que este projeto passou o mês caçando.
--
--     Decidido deixar como está: são fotos DA EQUIPE, não de cliente, e mover
--     os arquivos reapontando os endereços é risco real por uma porta pequena.
--     O bloco fica aqui porque ele continua certo: no dia em que aquelas sete
--     fotos mudarem de lugar, rodar isto de novo fecha o balde sozinho.
-- ============================================================

-- ------------------------------------------------------------
--  1) ANTES — o retrato, para comparar depois
-- ------------------------------------------------------------
select name as balde, public as e_publico from storage.buckets order by name;

select policyname as regra, roles as para_quem, cmd as no_que, qual as usando
  from pg_policies
 where schemaname = 'storage' and tablename = 'objects'
 order by policyname;


-- ------------------------------------------------------------
--  2) APAGAR ARQUIVO DEIXA DE SER COISA DE QUEM ATENDE
--
--  As três operações que o código realmente usa continuam:
--    - SELECT: ler pela API (o painel também lê pelo endereço público, que
--      não passa por aqui);
--    - INSERT: o painel mandando um anexo;
--    - UPDATE: o mesmo envio, que usa `upsert`.
--
--  DELETE sai. Se um dia for preciso apagar — um anexo mandado por engano, um
--  pedido de exclusão —, que seja por uma porta com nome, e não por todo mundo
--  o tempo inteiro.
-- ------------------------------------------------------------
drop policy if exists "anexos_atendentes" on storage.objects;

create policy "anexos_atendentes_leem"
  on storage.objects for select to authenticated
  using (bucket_id = 'anexos');

create policy "anexos_atendentes_mandam"
  on storage.objects for insert to authenticated
  with check (bucket_id = 'anexos');

-- O `upsert` do painel precisa das duas metades: achar a linha (`using`) e
-- gravar por cima (`with check`).
create policy "anexos_atendentes_regravam"
  on storage.objects for update to authenticated
  using      (bucket_id = 'anexos')
  with check (bucket_id = 'anexos');


-- ------------------------------------------------------------
--  3) O BALDE `avatares`, SE NINGUÉM ESTIVER USANDO
--
--  TENTA E DIZ. Se alguma foto de perfil apontar para lá, fechá-lo quebraria
--  a foto na tela — e o pior é que quebraria em silêncio, que é o defeito que
--  este projeto passou o mês inteiro caçando.
-- ------------------------------------------------------------
do $$
declare
  em_uso integer;
begin
  select count(*) into em_uso from (
    select foto_url from public.advogados where foto_url like '%/avatares/%'
    union all
    select foto_url from public.usuarios  where foto_url like '%/avatares/%'
  ) x;

  if em_uso > 0 then
    raise notice 'O balde "avatares" NÃO foi fechado: % foto(s) de perfil ainda '
                 'apontam para ele. Fechá-lo quebraria essas fotos.', em_uso;
  else
    update storage.buckets set public = false where id = 'avatares';
    raise notice 'O balde "avatares" foi fechado (nenhuma foto de perfil aponta para ele).';
  end if;
end $$;


-- ------------------------------------------------------------
--  4) CONFERÊNCIA — rode e leia
-- ------------------------------------------------------------
select 'quem atende continua LENDO os anexos' as item,
       exists (select 1 from pg_policies
                where schemaname = 'storage' and tablename = 'objects'
                  and policyname = 'anexos_atendentes_leem') as ok
union all
select 'e continua MANDANDO anexo',
       exists (select 1 from pg_policies
                where schemaname = 'storage' and tablename = 'objects'
                  and policyname = 'anexos_atendentes_mandam')
union all
select 'e regravando (o upsert do envio)',
       exists (select 1 from pg_policies
                where schemaname = 'storage' and tablename = 'objects'
                  and policyname = 'anexos_atendentes_regravam')
union all
select 'mas NÃO pode mais apagar arquivo',
       not exists (select 1 from pg_policies
                    where schemaname = 'storage' and tablename = 'objects'
                      and cmd in ('DELETE', 'ALL') and roles::text ~ 'authenticated')
union all
select 'o balde dos anexos continua público (de propósito — ver o topo)',
       (select public from storage.buckets where id = 'anexos');


-- ------------------------------------------------------------
--  DEPOIS DE RODAR — a conferência que o SQL não faz
--
--  Entre no painel e MANDE UM ANEXO numa conversa de teste. É o único jeito de
--  saber que o envio continua passando: a política nova é avaliada em nome de
--  quem está logado, e esta janela não tem sessão.
--
--  Desfazer, se o envio parar:
--
--    drop policy if exists "anexos_atendentes_leem"     on storage.objects;
--    drop policy if exists "anexos_atendentes_mandam"   on storage.objects;
--    drop policy if exists "anexos_atendentes_regravam" on storage.objects;
--    create policy "anexos_atendentes" on storage.objects
--      for all to authenticated using (bucket_id = 'anexos');
-- ------------------------------------------------------------
