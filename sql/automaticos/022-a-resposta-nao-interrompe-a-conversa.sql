-- ============================================================
--  A RESPOSTA AUTOMÁTICA NÃO INTERROMPE UMA CONVERSA EM ANDAMENTO
--
--  >>> RODAR NO SUPABASE DO **ZORVIN** (o das conversas). <<<
--  A ponte aplica sozinha ao subir (sql/automaticos). Pode rodar de novo sem
--  medo — na ordem da pasta, como diz a regra 5 do LEIA-ME.
--
--  ------------------------------------------------------------
--  O PEDIDO
--
--  Rodrigo, em 09/10, no mesmo dia em que a resposta automática (021) foi
--  ligada e testada: "se eu estiver conversando com o contato antes ou após
--  o horário do expediente, a mensagem automática não pode aparecer".
--
--  O 021 já cuidava de metade: se alguém da equipe escreveu na conversa
--  DEPOIS do fechamento, ela não sai — quem fez hora extra, ou chegou cedo,
--  está atendendo. Faltava a conversa que vem de ANTES do fechamento:
--
--      17:55  nós   "Vou conferir e já te digo."
--      18:00        o escritório fecha
--      18:05  ele   "Obrigado, fico no aguardo"
--             → o 021 respondia "Recebemos sua mensagem. Nosso horário é
--               das 8h às 18h…", no meio da conversa.
--
--  ------------------------------------------------------------
--  A REGRA NOVA: A CONVERSA EM ANDAMENTO
--
--  A resposta também não sai se a equipe agiu nesta conversa nos 30 minutos
--  antes da mensagem do cliente, de qualquer lado do fechamento.
--
--  OS 30 MINUTOS NÃO SÃO UM NÚMERO NOVO. São `zorvin_carencia_da_espera()`,
--  do 006: quanto tempo depois da nossa última ação a mensagem do cliente
--  ainda é o "rabicho" da conversa atendida, e não uma espera nova. É a
--  mesma pergunta — "o cliente ainda está respondendo àquela conversa?" —, e
--  duas réguas para ela divergiriam no primeiro ajuste: a fila diria que o
--  cliente não está esperando, e a resposta automática diria a ele que
--  ninguém está ali. Trocar o número lá vale aqui também.
--
--  "A EQUIPE AGIU" SÃO DUAS COISAS, e a segunda é a que não é óbvia:
--
--    - a mensagem nossa já gravada em `mensagens` — inclusive a que alguém
--      escreveu pelo CELULAR, que também chega como `advogado`;
--    - o pedido que ainda está na `fila_envio`. Quem apertou Enviar dois
--      segundos antes de o cliente escrever está conversando, e a mensagem
--      dele só entra em `mensagens` depois que o WhatsApp aceita — a ponte
--      lê a fila a cada 3 segundos. Sem isto, mensagens que se cruzam (os
--      dois digitando ao mesmo tempo) dariam a resposta automática logo
--      depois da nossa.
--
--  A AGENDADA NÃO CONTA enquanto espera a hora: mensagem marcada para amanhã
--  não é conversa agora. Depois que sai, ela está em `mensagens` como
--  qualquer outra nossa.
--
--  ------------------------------------------------------------
--  O QUE CONTINUA DE FORA, DE PROPÓSITO
--
--  O cliente que escreve PRIMEIRO, fora do horário, recebe a resposta na
--  hora — mesmo que alguém da equipe esteja no escritório e vá responder um
--  minuto depois. O banco não tem como saber que essa pessoa vai responder.
--  Se a equipe costuma chegar antes ou sair depois, o ajuste é o horário do
--  departamento, na tela.
--
--  ------------------------------------------------------------
--  O QUE ESTE SCRIPT FAZ
--
--  Recria `zorvin_responder_fora_do_horario` — a mesma do 021, com a regra
--  nova logo depois da regra de quem escreveu depois do fechamento, e com o
--  motivo próprio (`conversa_em_andamento`) para o log separar uma da outra.
--  Pela regra 5 do LEIA-ME, ESTE é, daqui para a frente, a versão de
--  referência da decisão.
--
--  A carência é lida DENTRO de um bloco protegido (a lição da auditoria de
--  07/10, no 020): num banco sem o 006 a função não existe, e um "function
--  does not exist" que escapasse daqui faria a PONTE achar que o 021 não foi
--  rodado e desligar a resposta automática até reiniciar — calada. Sem a
--  função, valem os mesmos 30 minutos.
--
--  DEPENDE DE JÁ TER RODADO
--    o 021 (a decisão e as tabelas dela) e a `fila_envio`. Sem eles — um
--    banco limpo, a prova 51l-bis —, não faz nada e diz isso.
-- ============================================================

do $andamento$
declare
  v_janela text;
begin
  -- A TABELA DA CONFERÊNCIA NASCE ANTES DE TUDO — a lição do 006 e do 007.
  drop table if exists zorvin_conferencia_022;
  create temp table zorvin_conferencia_022 (item text, resposta text);

  -- ----------------------------------------------------------
  --  A GUARDA
  -- ----------------------------------------------------------
  if to_regprocedure('public.zorvin_responder_fora_do_horario(uuid,text)') is null
     or to_regclass('public.zorvin_fora_do_horario') is null
     or to_regclass('public.zorvin_respostas_automaticas') is null
     or to_regclass('public.fila_envio') is null
     or to_regclass('public.mensagens') is null then
    insert into zorvin_conferencia_022
      values ('sem a resposta automática do 021, ou sem a fila de envio', 'nada a mudar');
    raise notice 'Zorvin: sem a resposta automática do 021 (ou sem a fila de envio) — o script 022 não mudou nada.';
    return;
  end if;

  execute $x$
    create or replace function public.zorvin_responder_fora_do_horario(
      p_conversa uuid, p_id_uazapi text)
    returns jsonb language plpgsql security definer set search_path = public as $f$
    declare
      v_msg      record;
      v_conv     record;
      v_cfg      public.zorvin_fora_do_horario;
      v_horario  jsonb;
      v_ate      timestamptz;
      v_fechou   timestamptz;
      v_nossa    timestamptz;
      v_carencia interval := interval '30 minutes';
      v_id       uuid;
    begin
      select m.origem, m.criado_em into v_msg
        from public.mensagens m
       where m.conversa_id = p_conversa and m.id_uazapi = p_id_uazapi
       limit 1;
      if not found then
        return jsonb_build_object('responde', false, 'motivo', 'mensagem_nao_achada');
      end if;
      if v_msg.origem is distinct from 'contato' then
        return jsonb_build_object('responde', false, 'motivo', 'nao_e_do_cliente');
      end if;
      -- O PASSADO NÃO SE RESPONDE: importação de histórico, reenvio atrasado.
      if v_msg.criado_em < now() - interval '30 minutes' then
        return jsonb_build_object('responde', false, 'motivo', 'mensagem_antiga');
      end if;

      -- `a.ativo` PELO NOME, e nunca `to_jsonb(a)`: `advogados` guarda a
      -- chave da Uazapi em colunas fechadas (a régua do 012). SÓ O `false`
      -- EXPLÍCITO desativa — a régua da fila de envio.
      select c.id, ct.numero, a.departamento_id,
             coalesce(a.ativo = false, false) as desativada
        into v_conv
        from public.conversas c
        join public.contatos ct on ct.id = c.contato_id
        join public.advogados a on a.id = c.advogado_id
       where c.id = p_conversa;
      if not found then
        return jsonb_build_object('responde', false, 'motivo', 'conversa_nao_achada');
      end if;
      if v_conv.numero like 'grupo:%' then
        return jsonb_build_object('responde', false, 'motivo', 'grupo');
      end if;
      if v_conv.desativada then
        return jsonb_build_object('responde', false, 'motivo', 'linha_desativada');
      end if;
      if v_conv.departamento_id is null then
        return jsonb_build_object('responde', false, 'motivo', 'sem_departamento');
      end if;

      select * into v_cfg from public.zorvin_fora_do_horario
       where departamento_id = v_conv.departamento_id;
      if not found or not v_cfg.ligada or btrim(v_cfg.texto) = '' then
        return jsonb_build_object('responde', false, 'motivo', 'desligada');
      end if;

      v_horario := public.zorvin_horario_de(v_cfg.semana, v_cfg.fuso, v_msg.criado_em);
      if (v_horario ->> 'aberto')::boolean then
        return jsonb_build_object('responde', false, 'motivo', 'no_horario');
      end if;
      v_ate := (v_horario ->> 'abre_em')::timestamptz;
      v_fechou := (v_horario ->> 'fechou_em')::timestamptz;
      if v_ate is null then
        return jsonb_build_object('responde', false, 'motivo', 'sem_dia_aberto');
      end if;

      -- QUANDO A EQUIPE AGIU POR ÚLTIMO NESTA CONVERSA: a mensagem nossa já
      -- gravada (inclui quem respondeu pelo celular, que também é
      -- `advogado`) ou o pedido que ainda está na fila — quem apertou Enviar
      -- há dois segundos está conversando, e a mensagem dele ainda não
      -- chegou a `mensagens`. A agendada que espera a hora não conta; a
      -- coluna é lida por `to_jsonb` porque nasceu no 013, e a fila de uma
      -- base sem ele não tem a coluna.
      select greatest(
               (select max(m.criado_em) from public.mensagens m
                 where m.conversa_id = p_conversa and m.origem = 'advogado'),
               (select max(f.criado_em) from public.fila_envio f
                 where f.conversa_id = p_conversa
                   and (to_jsonb(f) ->> 'agendada_para') is null))
        into v_nossa;

      -- ALGUÉM DA EQUIPE ESCREVEU DEPOIS DO FECHAMENTO: a conversa está
      -- sendo atendida (quem fez hora extra, ou chegou antes de abrir). Sem
      -- fechamento conhecido, as últimas 12 horas. (A regra do 021.)
      if v_nossa >= coalesce(v_fechou, v_msg.criado_em - interval '12 hours') then
        return jsonb_build_object('responde', false, 'motivo', 'equipe_respondeu');
      end if;

      -- A CONVERSA EM ANDAMENTO: a equipe agiu nos 30 minutos antes desta
      -- mensagem, mesmo que antes do fechamento — o cliente está respondendo
      -- àquela conversa. (A regra do 022.) A carência é a do 006, lida aqui
      -- dentro e protegida: sem a função valem os mesmos 30 minutos, e um
      -- "function does not exist" que escapasse faria a ponte desligar a
      -- resposta automática achando que o 021 não existe.
      begin
        v_carencia := coalesce(public.zorvin_carencia_da_espera(), interval '30 minutes');
      exception when undefined_function then
        v_carencia := interval '30 minutes';
      end;
      if v_nossa >= v_msg.criado_em - v_carencia then
        return jsonb_build_object('responde', false, 'motivo', 'conversa_em_andamento');
      end if;

      -- A RESERVA DA VEZ: uma por período fechado e por conversa. Quem chega
      -- depois esbarra na chave e não manda.
      insert into public.zorvin_respostas_automaticas
             (conversa_id, id_uazapi_cliente, ate, texto)
      values (p_conversa, p_id_uazapi, v_ate, v_cfg.texto)
      on conflict (conversa_id, ate) do nothing
      returning id into v_id;
      if v_id is null then
        return jsonb_build_object('responde', false, 'motivo', 'ja_respondida');
      end if;
      return jsonb_build_object('responde', true, 'id', v_id, 'texto', v_cfg.texto, 'ate', v_ate);
    end
    $f$
  $x$;

  -- O `create or replace` guarda as permissões que a função já tinha, e
  -- estas linhas existem para a pasta rodada do zero dizer a mesma coisa:
  -- quem manda a resposta é SÓ a ponte.
  execute 'revoke all on function public.zorvin_responder_fora_do_horario(uuid, text) from public';
  if exists (select 1 from pg_roles where rolname = 'anon') then
    execute 'revoke all on function public.zorvin_responder_fora_do_horario(uuid, text) from anon';
  end if;
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'revoke all on function public.zorvin_responder_fora_do_horario(uuid, text) from authenticated';
  end if;
  if exists (select 1 from pg_roles where rolname = 'service_role') then
    execute 'grant execute on function public.zorvin_responder_fora_do_horario(uuid, text) to service_role';
  end if;

  -- A JANELA, LIDA POR `execute`: escrita direto aqui, a chamada seria
  -- resolvida ao preparar o `insert` — e num banco sem o 006 o script
  -- inteiro morreria por causa de uma linha de conferência.
  begin
    execute 'select public.zorvin_carencia_da_espera()::text' into v_janela;
  exception when undefined_function then
    v_janela := '00:30:00 (sem a função do 006)';
  end;

  insert into zorvin_conferencia_022
  select 'a resposta automática respeita a conversa em andamento',
         (position('conversa_em_andamento' in
            pg_get_functiondef('public.zorvin_responder_fora_do_horario(uuid,text)'::regprocedure)) > 0)::text
  union all
  select 'a janela da conversa em andamento (a mesma da fila de espera)', v_janela
  union all
  select 'só a ponte manda a resposta (quem entrou não chama a função)',
         (not exists (select 1 from pg_roles where rolname = 'authenticated')
          or not has_function_privilege('authenticated',
               'public.zorvin_responder_fora_do_horario(uuid,text)', 'execute'))::text;
end
$andamento$;

-- A RESPOSTA DE "DEU CERTO?", na última linha, que é a que o editor mostra.
select * from zorvin_conferencia_022;
