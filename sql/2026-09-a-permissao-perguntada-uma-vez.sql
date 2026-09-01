-- ============================================================
--  A PERMISSÃO PERGUNTADA UMA VEZ, E NÃO MIL E CENTO E DEZOITO
--
--  >>> RODAR NO SUPABASE DO **ZORVIN** (o das conversas). <<<
--
--  Este arquivo não muda quem enxerga o quê. Ele muda QUANTAS VEZES o banco
--  refaz a mesma conferência — e a parte 3 existe justamente para provar, com
--  os dados do escritório, que a resposta continua idêntica para cada pessoa e
--  cada telefone. Não aplique a parte 4 sem ler o resultado da parte 3.
--
--  ------------------------------------------------------------
--  O QUE FOI MEDIDO, em 01/09/2026
--
--  O banco é pequeno: 19.653 mensagens, 1.118 conversas, 832 contatos, com
--  todos os índices no lugar e válidos. E mesmo assim o Zorvin estava lento em
--  toda parte — a busca que "nunca aparece", o painel arrastado, as mensagens
--  que demoram a abrir. O `pg_stat_statements`, acumulando desde 20/08 (doze
--  dias), mostrou onde o tempo ia:
--
--    consulta                                    vezes      média    total
--    ----------------------------------------  ---------  --------  --------
--    nao_lidas_por_telefone (os selos)            86.993   3.465 ms  83,7 h
--    contar não lidas de UM telefone           2.210.430     116 ms  71,5 h
--    ler as etiquetas de umas conversas          277.376     305 ms  23,5 h
--
--  Cento e setenta e oito horas de banco de dados em doze dias, em três
--  consultas. O banco vivia ocupado, e tudo o que chegava entrava numa fila
--  que já estava cheia.
--
--  E O ABSURDO ESTÁ NA PRIMEIRA LINHA. Contar quantas conversas não lidas cada
--  telefone tem, numa tabela de 1.118 linhas, custava 3,4 SEGUNDOS. A mesma
--  contagem, rodada como administrador (que não passa pelas regras de acesso):
--
--      Execution Time: 0.776 ms      -- 39 páginas, índice usado, tudo certo
--
--  Quatro mil quatrocentas e sessenta e cinco vezes mais rápida. Ou seja:
--  99,98% do tempo não era ler os dados. Era conferir se podia lê-los.
--
--  ------------------------------------------------------------
--  POR QUE ISSO ACONTECE
--
--  A regra de leitura de `conversas` é `pode_ver_conversa(advogado_id)`. O
--  argumento MUDA a cada linha, então o Postgres chama a função uma vez para
--  cada linha lida — 1.118 vezes. E cada chamada faz, por dentro:
--
--    * `zorvin_admin()`, que é outra função, que lê `usuarios`;
--    * `auth.uid()`, que abre e interpreta o JSON do crachá de quem chamou;
--    * uma consulta a `permissoes` com junção em `advogados`.
--
--  1.118 × (duas funções + três leituras) ≈ 3,4 segundos. A conta fecha.
--
--  A FUNÇÃO ESTÁ CERTA, e é importante dizer isso: ela é `stable`, é
--  `security definer`, e responde exatamente o que deve responder. `stable`
--  promete "a mesma resposta para o mesmo argumento dentro da mesma consulta"
--  — e o Postgres honra essa promessa, mas ela não o autoriza a PULAR a
--  chamada quando o argumento é outro. E aqui o argumento é outro a cada
--  linha... só que não de verdade:
--
--      1.118 conversas, e apenas 16 telefones.
--
--  São 16 respostas possíveis, calculadas 1.118 vezes. Mil cento e duas dessas
--  chamadas são a repetição de uma conta já feita.
--
--  ------------------------------------------------------------
--  O CONSERTO, EM UMA FRASE
--
--  Em vez de perguntar "posso ver a conversa desta linha?" mil vezes, perguntar
--  UMA vez "quais telefones eu posso ver?" e depois só conferir se o telefone
--  da linha está na lista. A conferência de pertencer a uma lista de 16 itens
--  é uma comparação de memória: nanossegundos, sem tocar em tabela nenhuma.
--
--  ------------------------------------------------------------
--  ISTO FOI MEDIDO, E NÃO DEDUZIDO
--
--  Antes de te mandar este arquivo eu montei uma réplica deste esquema num
--  Postgres 16 de verdade — as mesmas funções (copiadas de `pg_get_functiondef`),
--  as mesmas regras de acesso, 1.118 conversas, 16 telefones, 8 departamentos —
--  e cinco pessoas com recortes diferentes de permissão: um administrador, uma
--  com um departamento inteiro, uma com dois telefones avulsos MAIS uma
--  permissão curinga, um com um departamento e um telefone de fora dele, e uma
--  sem permissão nenhuma.
--
--  QUANTAS VEZES A PERMISSÃO É CONFERIDA (contado pelo `pg_stat_user_functions`,
--  numa única contagem de conversas):
--
--      antes    pode_ver_conversa 1.118x, zorvin_admin 1.118x   (49 ms + 38 ms)
--      depois   meus_telefones 1x,        zorvin_admin 1x        (0 ms)
--
--  E O QUE CADA PESSOA ENXERGA, que é o que não pode mudar:
--
--      pessoa                        antes   depois    tempo antes → depois
--      ---------------------------  ------  -------   ---------------------
--      administrador                 1.118    1.118      40,8 ms →  1,46 ms
--      um departamento inteiro         140      140      46,5 ms →  1,95 ms
--      dois telefones + curinga      1.118    1.118      47,3 ms →  1,89 ms
--      um departamento + um avulso     210      210      42,3 ms →  1,98 ms
--      sem permissão nenhuma             0        0      46,1 ms →  2,41 ms
--
--  Mesmo acesso, linha por linha, para todo mundo. Vinte e cinco vezes mais
--  rápido.
--
--  E DUAS COISAS QUEBRARAM NESSE TESTE, o que é a razão de ele existir. A
--  primeira versão deste arquivo usava `= any ((select meus_telefones()))` sem
--  o `::uuid[]`, nas regras E na conferência. O Postgres lê aquilo como
--  "qualquer LINHA desta subconsulta", tenta comparar um uuid com um vetor de
--  uuid, e responde:
--
--      ERROR: operator does not exist: uuid = uuid[]
--
--  Ou seja: eu teria te mandado um arquivo que morre na primeira linha que
--  importa. O `::uuid[]` faz o Postgres ler "qualquer ITEM deste vetor", que é
--  o que se quer — e foi a réplica que contou isso, não eu.
--
--  ------------------------------------------------------------
--  O `(select ...)` em volta da chamada é o que faz a diferença, e não é
--  enfeite: ele transforma a chamada num `InitPlan`, que o Postgres executa
--  UMA VEZ, antes de varrer a tabela, e cujo resultado ele guarda. Sem os
--  parênteses e o `select`, a expressão volta a ser avaliada linha por linha e
--  o conserto inteiro se perde — silenciosamente, sem erro nenhum, com a tela
--  funcionando igual e a lentidão de volta.
-- ============================================================


-- ------------------------------------------------------------
--  1) QUAIS TELEFONES ESTA PESSOA PODE VER
--
--     A MESMA REGRA da `pode_ver_conversa`, virada do avesso: em vez de
--     responder "sim/não" para um telefone, devolve a lista inteira de uma vez.
--     As duas condições — departamento e telefone — estão escritas aqui
--     exatamente como estão lá, e a parte 3 confere isso linha por linha em vez
--     de acreditar em mim.
--
--     O ADMINISTRADOR FICA DE FORA desta lista de propósito. Na regra ele
--     entra por um `or` separado, como já entrava, para que o comportamento
--     dele continue idêntico ao de hoje — inclusive numa conversa cujo
--     telefone não exista mais em `advogados`.
-- ------------------------------------------------------------
create or replace function public.meus_telefones()
returns uuid[]
language sql
stable
security definer
set search_path to 'public', 'auth'
as $function$
  select coalesce(array_agg(distinct a.id), '{}'::uuid[])
    from advogados a
    join permissoes p
      on p.usuario_id = auth.uid()
     and (p.departamento_id is null or p.departamento_id = a.departamento_id)
     and (p.telefone_id     is null or p.telefone_id     = a.id);
$function$;

comment on function public.meus_telefones() is
  'Os telefones que quem está chamando pode ver, numa lista só. É a mesma '
  'regra da pode_ver_conversa, perguntada uma vez em vez de uma por linha.';

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'grant execute on function public.meus_telefones() to authenticated';
  end if;
end $$;


-- ------------------------------------------------------------
--  2) O ÍNDICE QUE A CONTAGEM DOS SELOS PEDE
--
--     Ela já usa um (`conversas_nao_lidas_por_telefone`, visto no plano). Esta
--     linha é `if not exists`: se ele estiver lá, não faz nada.
-- ------------------------------------------------------------
create index if not exists conversas_nao_lidas_por_telefone
  on public.conversas (advogado_id)
  where nao_lidas > 0;


-- ------------------------------------------------------------
--  3) A CONFERÊNCIA — RODE ISTO E LEIA ANTES DE SEGUIR
--
--     Para CADA pessoa e CADA telefone, a resposta de hoje e a resposta nova.
--     São 16 telefones e um punhado de usuários: a consulta é instantânea.
--
--     `divergencias` TEM DE SER ZERO em todas as linhas. Se não for, PARE: a
--     regra nova daria a alguém um acesso diferente do que ela tem hoje, e isso
--     não é uma otimização, é um incidente. Me mande a tabela e eu corrijo.
--
--     Nada foi alterado até aqui. As regras de acesso continuam as de sempre.
-- ------------------------------------------------------------
with pares as (
  select u.id as usuario_id, u.nome as pessoa, a.id as telefone_id,
         -- COMO É HOJE: a `pode_ver_conversa` escrita por extenso, com o
         -- usuário como parâmetro em vez de `auth.uid()` — é a única mudança,
         -- e é o que permite conferir todo mundo de uma vez.
         (
           coalesce((select uu.admin and uu.ativo from public.usuarios uu
                      where uu.id = u.id), false)
           or exists (
             select 1 from public.permissoes p
               join public.advogados aa on aa.id = a.id
              where p.usuario_id = u.id
                and (p.departamento_id is null or p.departamento_id = aa.departamento_id)
                and (p.telefone_id     is null or p.telefone_id     = a.id))
         ) as hoje,
         -- COMO FICA: administrador por fora, o resto pela lista.
         (
           coalesce((select uu.admin and uu.ativo from public.usuarios uu
                      where uu.id = u.id), false)
           -- O `::uuid[]` NÃO É ENFEITE. Sem ele o Postgres lê `any (…)` como
           -- "qualquer LINHA desta subconsulta" e tenta comparar um uuid com
           -- um vetor de uuid — erro na cara, e a consulta inteira não roda.
           -- Com ele, lê "qualquer ITEM deste vetor", que é o que se quer.
           or a.id = any ((
             select coalesce(array_agg(distinct aa.id), '{}'::uuid[])
               from public.advogados aa
               join public.permissoes p
                 on p.usuario_id = u.id
                and (p.departamento_id is null or p.departamento_id = aa.departamento_id)
                and (p.telefone_id     is null or p.telefone_id     = aa.id))::uuid[])
         ) as depois
    from public.usuarios u
   cross join public.advogados a
)
select pessoa,
       count(*)                                     as telefones_conferidos,
       count(*) filter (where hoje)                 as ve_hoje,
       count(*) filter (where depois)               as ve_depois,
       count(*) filter (where hoje is distinct from depois) as divergencias
  from pares
 group by pessoa
 order by divergencias desc, pessoa;


-- ------------------------------------------------------------
--  4) A TROCA — só depois de a parte 3 dar ZERO em toda a coluna
--
--     `alter policy ... using` reescreve a condição da regra que já existe. A
--     regra não é apagada em momento nenhum: não há um instante sequer em que
--     a tabela fique sem proteção.
-- ------------------------------------------------------------
alter policy conversas_leitura on public.conversas
  using (
    (select public.zorvin_admin())
    or advogado_id = any ((select public.meus_telefones())::uuid[])
  );

alter policy conversas_escrita on public.conversas
  using (
    (select public.zorvin_admin())
    or advogado_id = any ((select public.meus_telefones())::uuid[])
  );


-- ------------------------------------------------------------
--  5) A MEDIÇÃO DE DEPOIS
--
--     Antes: 3.465 ms (o que o aplicativo gastava).
--     Sem as regras de acesso: 0,776 ms (o piso, o custo de ler os dados).
--     Aqui: o quanto sobrou de distância entre os dois.
-- ------------------------------------------------------------
explain (analyze, buffers)
select * from public.nao_lidas_por_telefone(
  (select id::text from public.advogados order by nome limit 1),
  (select array_agg(id::text) from public.advogados));


-- ------------------------------------------------------------
--  6) E ZERAR AS ESTATÍSTICAS, para a próxima medição ser limpa
--
--     As 178 horas foram acumuladas desde 20/08, e uma parte delas é de antes
--     de outros consertos. Zerando aqui, o retrato de amanhã é o retrato do
--     sistema como ele está hoje, e não uma média com o passado dentro.
-- ------------------------------------------------------------
select extensions.pg_stat_statements_reset();


-- ------------------------------------------------------------
--  COMO DESFAZER, se algo parecer errado
--
--     Volta as duas regras ao que eram. A função `meus_telefones` pode ficar
--     onde está: sem ninguém chamá-la, ela não faz nada.
--
--       alter policy conversas_leitura on public.conversas
--         using (pode_ver_conversa(advogado_id));
--       alter policy conversas_escrita on public.conversas
--         using (pode_ver_conversa(advogado_id));
-- ------------------------------------------------------------
